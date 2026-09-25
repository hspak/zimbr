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
    clear(a, &s.undo);
    clear(a, &s.redo);
    s.revision += 1;
}
pub fn selected(s: Editor) []const u8 {
    return s.text.items[@min(s.caret, s.anchor)..@max(s.caret, s.anchor)];
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
    s.revision += 1;
}
pub fn move(s: *Editor, direction: c_int, select: bool) void {
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
