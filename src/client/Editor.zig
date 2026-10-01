const std = @import("std");
const builtin = @import("builtin");
const u = @import("../common.zig");
const c = @import("c.zig").api;
const t = @import("../protocol.zig").types;
const Editor = @This();

allocator: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator,
text: std.ArrayList(u8) = .empty,
caret: usize = 0,
anchor: usize = 0,
undo: std.ArrayList(Checkpoint) = .empty,
redo: std.ArrayList(Checkpoint) = .empty,
revision: u64 = 0,
preedit: std.ArrayList(u8) = .empty,
preedit_start: usize = 0,
preedit_end: usize = 0,
preedit_revision: u64 = 0,

pub const Range = struct { start: usize, end: usize };
pub const Display = struct {
    text: []const u8,
    caret: usize,
    selection: Range,
    composition: ?Range,
};

const Checkpoint = struct {
    text: []const u8,
    caret: usize,
    anchor: usize,
};

pub const SetError = u.Allocator.Error || error{InvalidText};
pub const InsertError = u.Allocator.Error || error{ InvalidText, TextTooLarge };
pub const DeleteError = u.Allocator.Error || error{ InvalidText, TextTooLarge };

pub fn deinit(s: *Editor) void {
    const a = s.allocator;
    s.text.deinit(a);
    s.preedit.deinit(a);
    clear(a, &s.undo);
    clear(a, &s.redo);
    s.* = undefined;
}
fn clear(a: u.Allocator, stack: *std.ArrayList(Checkpoint)) void {
    for (stack.items) |v| a.free(v.text);
    stack.deinit(a);
    stack.* = .empty;
}
pub fn set(s: *Editor, text: []const u8) SetError!void {
    const a = s.allocator;
    if (text.len > t.max_text or !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    try s.text.ensureTotalCapacity(a, text.len);
    s.text.clearRetainingCapacity();
    s.text.appendSliceAssumeCapacity(text);
    s.caret = text.len;
    s.anchor = s.caret;
    s.cancelPreedit();
    clear(a, &s.undo);
    clear(a, &s.redo);
    s.revision += 1;
}
pub fn selected(s: Editor) []const u8 {
    return s.text.items[@min(s.caret, s.anchor)..@max(s.caret, s.anchor)];
}
/// Replace temporary IME text without changing the document, selection, or undo stack.
/// SDL cursor and selection lengths count Unicode codepoints. Unknown offsets use the end.
pub fn setPreedit(s: *Editor, text: []const u8, start: i32, length: i32) InsertError!void {
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null)
        return error.InvalidText;
    if (text.len > t.max_text - (s.text.items.len - s.selected().len)) return error.TextTooLarge;
    try s.preedit.ensureTotalCapacity(s.allocator, text.len);
    s.preedit.clearRetainingCapacity();
    s.preedit.appendSliceAssumeCapacity(text);
    s.preedit_start = if (start < 0) text.len else characterOffset(text, @intCast(start));
    s.preedit_end = s.preedit_start + characterOffset(text[s.preedit_start..], @intCast(@max(0, length)));
    s.preedit_revision += 1;
}
fn characterOffset(text: []const u8, count: usize) usize {
    var offset: usize = 0;
    var remaining = count;
    while (remaining > 0 and offset < text.len) : (remaining -= 1) {
        offset += std.unicode.utf8ByteSequenceLength(text[offset]) catch unreachable;
    }
    return offset;
}
pub fn cancelPreedit(s: *Editor) void {
    if (s.preedit.items.len == 0) return;
    s.preedit.clearRetainingCapacity();
    s.preedit_revision += 1;
}
/// Confirm visible preedit as one undoable replacement. On error it remains available.
pub fn commitPreedit(s: *Editor) InsertError!void {
    if (s.preedit.items.len > 0) try s.insert(s.preedit.items);
}
/// Build the visible document in caller-owned scratch space. Committed text is borrowed
/// directly when there is no preedit. All returned offsets are UTF-8 byte offsets.
pub fn display(s: *const Editor, buffer: *[t.max_text]u8) Display {
    const start = @min(s.caret, s.anchor);
    const end = @max(s.caret, s.anchor);
    if (s.preedit.items.len == 0) return .{
        .text = s.text.items,
        .caret = s.caret,
        .selection = .{ .start = start, .end = end },
        .composition = null,
    };
    const preedit_end = start + s.preedit.items.len;
    const length = preedit_end + s.text.items.len - end;
    @memcpy(buffer[0..start], s.text.items[0..start]);
    @memcpy(buffer[start..preedit_end], s.preedit.items);
    @memcpy(buffer[preedit_end..length], s.text.items[end..]);
    return .{
        .text = buffer[0..length],
        .caret = start + s.preedit_start,
        .selection = .{ .start = start + s.preedit_start, .end = start + s.preedit_end },
        .composition = .{ .start = start, .end = preedit_end },
    };
}
fn checkpoint(s: *Editor) !void {
    const a = s.allocator;
    const state = Checkpoint{
        .text = try a.dupe(u8, s.text.items),
        .caret = s.caret,
        .anchor = s.anchor,
    };
    errdefer a.free(state.text);
    try s.undo.append(a, state);
    if (s.undo.items.len > 100) a.free(s.undo.orderedRemove(0).text);
    clear(a, &s.redo);
}
pub fn insert(s: *Editor, value: []const u8) InsertError!void {
    const a = s.allocator;
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
    const start = @min(s.caret, s.anchor);
    const end = @max(s.caret, s.anchor);
    if (s.text.items.len - (end - start) + value.len > t.max_text) return error.TextTooLarge;
    try s.text.ensureTotalCapacity(a, s.text.items.len - (end - start) + value.len);
    try s.checkpoint();
    s.text.replaceRangeAssumeCapacity(start, end - start, value);
    s.caret = start + value.len;
    s.anchor = s.caret;
    s.cancelPreedit();
    s.revision += 1;
}
pub fn move(s: *Editor, direction: c_int, select: bool) void {
    s.cancelPreedit();
    if (!select and s.anchor != s.caret) s.caret = if (direction < 0) @min(s.caret, s.anchor) else @max(
        s.caret,
        s.anchor,
    ) else s.caret = c.zc_text_boundary(
        s.text.items.ptr,
        s.text.items.len,
        s.caret,
        direction,
    );
    if (!select) s.anchor = s.caret;
}
pub fn delete(s: *Editor, back: bool) DeleteError!void {
    const anchor = s.anchor;
    errdefer s.anchor = anchor;
    if (s.anchor == s.caret) s.anchor = c.zc_text_boundary(
        s.text.items.ptr,
        s.text.items.len,
        s.caret,
        if (back) -1 else 1,
    );
    if (s.anchor != s.caret) try s.insert("");
}
pub fn history(s: *Editor, forward: bool) u.Allocator.Error!void {
    const a = s.allocator;
    const from = if (forward) &s.redo else &s.undo;
    const to = if (forward) &s.undo else &s.redo;
    if (from.items.len == 0) return;
    try s.text.ensureTotalCapacity(a, from.items[from.items.len - 1].text.len);
    try to.ensureUnusedCapacity(a, 1);
    const text = try a.dupe(u8, s.text.items);
    to.appendAssumeCapacity(.{
        .text = text,
        .caret = s.caret,
        .anchor = s.anchor,
    });
    const v = from.pop().?;
    defer a.free(v.text);
    s.text.clearRetainingCapacity();
    s.text.appendSliceAssumeCapacity(v.text);
    s.caret = v.caret;
    s.anchor = v.anchor;
    s.cancelPreedit();
    s.revision += 1;
}

test "failed replacement preserves text selection and undo history" {
    var editor: Editor = .{ .allocator = std.testing.allocator };
    defer editor.deinit();
    try editor.set("original");
    editor.caret = editor.text.items.len;
    editor.anchor = 2;
    const revision = editor.revision;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    editor.allocator = failing.allocator();
    defer editor.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, editor.set("replacement" ** 100));
    try std.testing.expectEqualStrings("original", editor.text.items);
    try std.testing.expectEqual(@as(usize, 8), editor.caret);
    try std.testing.expectEqual(@as(usize, 2), editor.anchor);
    try std.testing.expectEqual(revision, editor.revision);
}

test "Korean preedit replaces a selection visually and commits as one undo step" {
    const testing = std.testing;
    var editor: Editor = .{};
    defer editor.deinit();
    try editor.set("👋 old 뒤");
    editor.anchor = "👋 ".len;
    editor.caret = "👋 old".len;
    const revision = editor.revision;
    var buffer: [t.max_text]u8 = undefined;
    for ([_][]const u8{
        "ㅎ",
        "하",
        "한",
    }) |syllable| {
        try editor.setPreedit(syllable, 1, 0);
        const visible = editor.display(&buffer);
        try testing.expectEqualStrings("👋 old 뒤", editor.text.items);
        try testing.expectEqualStrings(syllable, visible.text["👋 ".len .. visible.text.len - " 뒤".len]);
        try testing.expectEqual("👋 한".len, visible.caret);
        try testing.expectEqual(revision, editor.revision);
        try testing.expectEqual(@as(usize, 0), editor.undo.items.len);
    }
    editor.cancelPreedit();
    try testing.expectEqualStrings("👋 old 뒤", editor.display(&buffer).text);
    try testing.expectEqualStrings("old", editor.selected());
    try editor.setPreedit("한글", 1, 1);
    const visible = editor.display(&buffer);
    try testing.expectEqualStrings("👋 한글 뒤", visible.text);
    try testing.expectEqualStrings("글", visible.text[visible.selection.start..visible.selection.end]);
    try editor.commitPreedit();
    try testing.expectEqualStrings("👋 한글 뒤", editor.text.items);
    try testing.expectEqual(@as(usize, 0), editor.preedit.items.len);
    try editor.history(false);
    try testing.expectEqualStrings("👋 old 뒤", editor.text.items);
    try testing.expectEqualStrings("old", editor.selected());
    try editor.history(true);
    try testing.expectEqualStrings("👋 한글 뒤", editor.text.items);
}

test "preedit validates encoding and replacement budget before changing the display" {
    const testing = std.testing;
    var editor: Editor = .{};
    defer editor.deinit();
    try editor.set("x" ** (t.max_text - 3));
    try editor.setPreedit("한", -1, -1);
    try testing.expectEqual(@as(usize, "한".len), editor.preedit_start);
    try testing.expectError(error.TextTooLarge, editor.setPreedit("한글", 2, 0));
    try testing.expectError(error.InvalidText, editor.setPreedit("\xff", 0, 0));
    try testing.expectEqualStrings("한", editor.preedit.items);
    editor.anchor = 0;
    try editor.setPreedit("한글", 999, 999);
    var buffer: [t.max_text]u8 = undefined;
    try testing.expectEqualStrings("한글", editor.display(&buffer).text);
    try testing.expectEqual(@as(usize, "한글".len), editor.preedit_start);
    try testing.expectEqual(editor.preedit_start, editor.preedit_end);
}

test "failed preedit update and commit preserve the composition and selected text" {
    const testing = std.testing;
    var editor: Editor = .{};
    defer editor.deinit();
    try editor.set("original");
    editor.anchor = 0;
    try editor.setPreedit("한", 1, 0);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    editor.allocator = failing.allocator();
    defer editor.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, editor.setPreedit("한" ** 100, 1, 0));
    try testing.expectError(error.OutOfMemory, editor.commitPreedit());
    try testing.expectEqualStrings("original", editor.selected());
    try testing.expectEqualStrings("한", editor.preedit.items);
    try testing.expectEqual(@as(usize, 0), editor.undo.items.len);
}
