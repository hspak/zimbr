//! The current composer query and keyboard selection. All catalog slices are static.

const std = @import("std");
const Editor = @import("../Editor.zig");
const emoji = @import("../emoji.zig");
const Completion = @This();

revision: ?u64 = null,
caret: usize = 0,
range: Editor.Range = .{ .start = 0, .end = 0 },
items: []const emoji.Entry = &.{},
selected: usize = 0,
dismissed: bool = false,

pub fn update(s: *Completion, editor: *const Editor, enabled: bool) void {
    if (!enabled or editor.preedit.items.len > 0 or editor.anchor != editor.caret) {
        s.* = .{};
        return;
    }
    if (s.revision == editor.revision and s.caret == editor.caret) return;
    s.* = .{ .revision = editor.revision, .caret = editor.caret };
    s.range = emoji.query(editor.text.items, editor.caret) orelse return;
    s.items = emoji.matches(editor.text.items[s.range.start + 1 .. editor.caret]);
}

pub fn visible(s: Completion) bool {
    return !s.dismissed and s.items.len > 0;
}

pub fn cycle(s: *Completion, backwards: bool) void {
    if (!s.visible()) return;
    s.selected = (s.selected + if (backwards) s.items.len - 1 else 1) % s.items.len;
}

test "emoji completion cycles all results and dismissal lasts until the query changes" {
    var editor: Editor = .{};
    defer editor.deinit();
    try editor.set(":sm");
    var completion: Completion = .{};
    completion.update(&editor, true);
    try std.testing.expect(completion.visible());
    completion.cycle(true);
    try std.testing.expectEqual(completion.items.len - 1, completion.selected);
    completion.cycle(false);
    try std.testing.expectEqual(@as(usize, 0), completion.selected);
    completion.dismissed = true;
    completion.update(&editor, true);
    try std.testing.expect(!completion.visible());
    try editor.insert("i");
    completion.update(&editor, true);
    try std.testing.expect(completion.visible());
    try editor.setPreedit("한", 1, 0);
    completion.update(&editor, true);
    try std.testing.expect(!completion.visible());
    editor.cancelPreedit();
    completion.update(&editor, true);
    try std.testing.expect(completion.visible());
    completion.update(&editor, false);
    try std.testing.expect(!completion.visible());
}
