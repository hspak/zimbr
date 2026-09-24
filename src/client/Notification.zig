//! Owned, bounded notification content, independent of replaceable UI snapshots.
const std = @import("std");
const t = @import("../protocol/types.zig");
const display = @import("display.zig");
const Store = @import("Store.zig");
const Self = @This();
const a = std.heap.page_allocator;
arena: std.heap.ArenaAllocator,
chat: [:0]const u8,
summary: [:0]const u8,
body: [:0]const u8,

pub fn create(store: Store, message: t.Message) !*Self {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const ar = arena.allocator();
    var q = try store.db.prepare("SELECT record FROM records WHERE kind='conversation' AND id=?");
    defer q.close();
    try q.bind(&.{.{ .text = message.conversation_id }});
    var title = message.sender;
    if (try q.step()) {
        const chat = (try std.json.parseFromSlice(t.Conversation, ar, q.bytes(0), .{ .ignore_unknown_fields = true })).value;
        if (chat.title.len > 0) title = chat.title;
    }
    const summary = try ar.dupeZ(u8, display.prefix(if (title.len > 0) title else "New message", 256, 1));
    const body = try ar.dupeZ(u8, display.prefix(message.text orelse switch (message.kind) {
        .attachment => "Attachment",
        .reaction => "Reaction",
        .system => "Conversation update",
        .empty => "Empty message",
        else => "Unsupported message",
    }, 1024, 4));
    const chat = try ar.dupeZ(u8, message.conversation_id);
    const result = try a.create(Self);
    result.* = .{ .arena = arena, .chat = chat, .summary = summary, .body = body };
    return result;
}
pub fn destroy(s: *Self) void {
    s.arena.deinit();
    a.destroy(s);
}

test "notification previews bound UTF8, lines and NUL without changing source content" {
    const store = try Store.open(":memory:");
    defer store.close();
    const source = "👋" ** 400;
    var message = t.Message{ .id = "id", .conversation_id = "chat", .sender = "Sender\nsecond line", .direction = .incoming, .service = "imessage", .timestamp = "", .kind = .text, .text = source, .decoding = .plain, .observed_status = .received };
    const long = try create(store, message);
    defer long.destroy();
    try std.testing.expectEqualStrings("Sender", long.summary);
    try std.testing.expect(long.body.len <= 1024);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.body));
    try std.testing.expectEqualStrings(source, message.text.?);
    message.text = "before\x00after";
    const nul = try create(store, message);
    defer nul.destroy();
    try std.testing.expectEqualStrings("before", nul.body);
}
