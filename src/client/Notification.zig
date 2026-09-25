//! Owned, bounded notification content, independent of replaceable UI snapshots.
const std = @import("std");
const t = @import("../protocol.zig").types;
const display = @import("display.zig");
const Store = @import("Store.zig");
const Notification = @This();
const a = std.heap.page_allocator;

arena: std.heap.ArenaAllocator,
chat: [:0]const u8,
summary: [:0]const u8,
body: [:0]const u8,

pub const CreateError = std.json.ParseError(std.json.Scanner) || error{
    DatabaseBusy,
    DatabaseFailure,
    DatabaseUnavailable,
    SchemaUnsupported,
};

pub fn create(store: Store, message: t.Message) CreateError!*Notification {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const ar = arena.allocator();
    const q = try store.db.prepare("SELECT record FROM records WHERE kind='conversation' AND id=?");
    defer q.close();
    try q.bind(&.{.{ .text = message.conversation_id }});
    const directory = try store.directory(ar);
    var title = directory.name(message.service, message.sender);
    if (try q.step()) {
        const chat = (try std.json.parseFromSlice(
            t.Conversation,
            ar,
            q.bytes(0),
            .{ .ignore_unknown_fields = true },
        )).value;
        title = directory.conversation(ar, chat);
    }
    const summary = try ar.dupeZ(
        u8,
        display.prefix(if (title.len > 0) title else "New message", 256, 1),
    );
    const body = try ar.dupeZ(u8, display.prefix(display.summary(ar, message), 1024, 4));
    const chat = try ar.dupeZ(u8, try store.threadKey(ar, message.conversation_id));
    const result = try a.create(Notification);
    result.* = .{
        .arena = arena,
        .chat = chat,
        .summary = summary,
        .body = body,
    };
    return result;
}
pub fn destroy(s: *Notification) void {
    s.arena.deinit();
    a.destroy(s);
}

test "notification previews bound UTF8, lines and NUL without changing source content" {
    const store = try Store.open(":memory:");
    defer store.close();
    const source = "👋" ** 400;
    var message = t.Message{
        .id = "id",
        .conversation_id = "chat",
        .sender = "Sender\nsecond line",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "",
        .kind = .text,
        .text = source,
        .decoding = .plain,
        .observed_status = .received,
    };
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

test "new notifications resolve names, preserve captions and titles, and respect permission loss" {
    const store = try Store.open(":memory:");
    defer store.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const u = @import("../common.zig");
    const identity = t.Identity{
        .id = "person",
        .revision = "1",
        .service = "imessage",
        .address = "peer@example.invalid",
        .display_name = "Zoë 👋",
        .match_state = .matched,
    };
    _ = try store.upsert(ar, "identity", try u.json(ar, identity));
    var conversation = t.Conversation{
        .id = "chat",
        .revision = "1",
        .service = "imessage",
        .participants = &.{identity.address},
    };
    _ = try store.upsert(ar, "conversation", try u.json(ar, conversation));
    const photo = t.Attachment{
        .id = "photo",
        .name = "photo.png",
        .mime_type = "image/png",
        .bytes = "123",
    };
    var message = t.Message{
        .id = "message",
        .conversation_id = "chat",
        .sender = identity.address,
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "",
        .kind = .attachment,
        .text = "A caption 👋",
        .decoding = .plain,
        .observed_status = .received,
        .attachments = &.{ photo, photo },
    };
    const caption = try create(store, message);
    defer caption.destroy();
    try std.testing.expectEqualStrings(identity.display_name.?, caption.summary);
    try std.testing.expectEqualStrings(message.text.?, caption.body);
    message.text = "\u{fffc}\n\u{fffc}";
    const multiple = try create(store, message);
    defer multiple.destroy();
    try std.testing.expectEqualStrings("2 photos", multiple.body);
    message.attachments = &.{photo};
    try store.set("contacts_blocked", "1");
    const denied = try create(store, message);
    defer denied.destroy();
    try std.testing.expectEqualStrings(identity.address, denied.summary);
    try std.testing.expectEqualStrings("Photo", denied.body);
    // Already queued notifications own their summaries; metadata is not resent.
    try std.testing.expectEqualStrings(identity.display_name.?, caption.summary);
    conversation.revision = "2";
    conversation.title = "Our title";
    _ = try store.upsert(ar, "conversation", try u.json(ar, conversation));
    const titled = try create(store, message);
    defer titled.destroy();
    try std.testing.expectEqualStrings("Our title", titled.summary);
}
