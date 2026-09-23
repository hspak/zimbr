const std = @import("std");
const Self = @This();
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;

// Own the text so worker snapshots can be replaced during a selection.
id: []const u8 = "",
preview: []const u8 = "",
full: []const u8 = "",
pending: bool = false,
anchor: usize = 0,
caret: usize = 0,
whole: bool = false,
dragging: bool = false,

pub fn clear(s: *Self) void {
    a.free(s.id);
    a.free(s.preview);
    a.free(s.full);
    s.* = .{};
}

pub fn begin(s: *Self, id: []const u8, pending: bool, preview: []const u8, full: []const u8, at: usize) !void {
    const id_copy = try a.dupe(u8, id);
    errdefer a.free(id_copy);
    const preview_copy = try a.dupe(u8, preview);
    errdefer a.free(preview_copy);
    const full_copy = try a.dupe(u8, full);
    s.clear();
    s.* = .{ .id = id_copy, .pending = pending, .preview = preview_copy, .full = full_copy, .anchor = at, .caret = at, .dragging = true };
}

pub fn matches(s: Self, id: []const u8, pending: bool, preview: []const u8) bool {
    return s.id.len > 0 and s.pending == pending and std.mem.eql(u8, s.id, id) and std.mem.eql(u8, s.preview, preview);
}

pub fn selectAll(s: *Self) void {
    s.anchor = 0;
    s.caret = s.preview.len;
    s.whole = true;
    s.dragging = false;
}

pub fn selected(s: Self) []const u8 {
    // Preserve click + Ctrl+C for full messages, including shortened previews.
    if (s.whole or s.anchor == s.caret) return s.full;
    return s.preview[@min(s.anchor, s.caret)..@max(s.anchor, s.caret)];
}

test "message selection owns snapshot text and copies Unicode ranges in either direction" {
    var selection = Self{};
    defer selection.clear();
    var snapshot = "Café 👩‍💻\nשלום".*;
    try selection.begin("message-1", false, &snapshot, &snapshot, "Café ".len);
    @memset(&snapshot, 'x');
    selection.caret = "Café 👩‍💻".len;
    try std.testing.expectEqualStrings("👩‍💻", selection.selected());
    std.mem.swap(usize, &selection.anchor, &selection.caret);
    try std.testing.expectEqualStrings("👩‍💻", selection.selected());
    try std.testing.expect(!selection.matches("message-1", true, selection.preview));
    try std.testing.expect(!selection.matches("message-1", false, "Edited message"));
}

test "whole message copy retains text beyond the rendered preview" {
    var selection = Self{};
    defer selection.clear();
    try selection.begin("pending-1", true, "Visible\n… Preview shortened", "Visible and the rest of the original message", 0);
    try std.testing.expectEqualStrings(selection.full, selection.selected());
    selection.caret = "Visible".len;
    try std.testing.expectEqualStrings("Visible", selection.selected());
    selection.selectAll();
    try std.testing.expectEqualStrings(selection.full, selection.selected());
    selection.clear();
    try std.testing.expectEqualStrings("", selection.selected());
}
