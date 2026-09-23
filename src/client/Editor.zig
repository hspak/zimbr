const std = @import("std");
const u = @import("../common.zig");
const c = @import("c.zig").api;
const t = @import("../protocol/types.zig");
const Self = @This();
const a = std.heap.page_allocator;
text: std.ArrayList(u8) = .empty,
caret: usize = 0,
anchor: usize = 0,
undo: std.ArrayList(State) = .empty,
redo: std.ArrayList(State) = .empty,
revision: u64 = 0,
const State = struct { text: []const u8, caret: usize, anchor: usize };
pub fn deinit(s: *Self) void {
    s.text.deinit(a);
    clear(&s.undo);
    clear(&s.redo);
}
fn clear(stack: *std.ArrayList(State)) void {
    for (stack.items) |v| a.free(v.text);
    stack.deinit(a);
    stack.* = .empty;
}
pub fn set(s: *Self, text: []const u8) !void {
    if (text.len > t.max_text or !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    s.text.clearRetainingCapacity();
    try s.text.appendSlice(a, text);
    s.caret = text.len;
    s.anchor = s.caret;
    clear(&s.undo);
    clear(&s.redo);
    s.revision += 1;
}
pub fn selected(s: Self) []const u8 {
    return s.text.items[@min(s.caret, s.anchor)..@max(s.caret, s.anchor)];
}
fn checkpoint(s: *Self) !void {
    const state = State{ .text = try a.dupe(u8, s.text.items), .caret = s.caret, .anchor = s.anchor };
    errdefer a.free(state.text);
    try s.undo.append(a, state);
    if (s.undo.items.len > 100) a.free(s.undo.orderedRemove(0).text);
    clear(&s.redo);
}
pub fn insert(s: *Self, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
    const start = @min(s.caret, s.anchor);
    const end = @max(s.caret, s.anchor);
    if (s.text.items.len - (end - start) + value.len > t.max_text) return error.TextTooLarge;
    try s.checkpoint();
    try s.text.replaceRange(a, start, end - start, value);
    s.caret = start + value.len;
    s.anchor = s.caret;
    s.revision += 1;
}
pub fn move(s: *Self, direction: c_int, select: bool) void {
    if (!select and s.anchor != s.caret) s.caret = if (direction < 0) @min(s.caret, s.anchor) else @max(s.caret, s.anchor) else s.caret = c.zc_text_boundary(s.text.items.ptr, s.text.items.len, s.caret, direction);
    if (!select) s.anchor = s.caret;
}
pub fn delete(s: *Self, back: bool) !void {
    if (s.anchor == s.caret) s.anchor = c.zc_text_boundary(s.text.items.ptr, s.text.items.len, s.caret, if (back) -1 else 1);
    if (s.anchor != s.caret) try s.insert("");
}
pub fn history(s: *Self, forward: bool) !void {
    const from = if (forward) &s.redo else &s.undo;
    const to = if (forward) &s.undo else &s.redo;
    if (from.items.len == 0) return;
    try to.append(a, .{ .text = try a.dupe(u8, s.text.items), .caret = s.caret, .anchor = s.anchor });
    const v = from.pop().?;
    defer a.free(v.text);
    s.text.clearRetainingCapacity();
    try s.text.appendSlice(a, v.text);
    s.caret = v.caret;
    s.anchor = v.anchor;
    s.revision += 1;
}
