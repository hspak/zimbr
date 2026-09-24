//! Presentation only: exact service/address keys never alter routing or actors.
const std = @import("std");
const t = @import("../protocol/types.zig");
const Self = @This();
const Key = struct { service: []const u8, address: []const u8 };
const Context = struct {
    pub fn hash(_: @This(), key: Key) u64 {
        return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, key.service), key.address);
    }
    pub fn eql(_: @This(), x: Key, y: Key) bool {
        return std.mem.eql(u8, x.service, y.service) and std.mem.eql(u8, x.address, y.address);
    }
};
entries: std.HashMapUnmanaged(Key, t.Identity, Context, 80) = .empty,
available: bool = true,
revision_key: u64 = 0,

// Owned by the snapshot arena, independently of immutable message records.
pub fn put(s: *Self, a: std.mem.Allocator, identity: t.Identity) !void {
    const key = Key{ .service = identity.service, .address = identity.address };
    const entry = try s.entries.getOrPut(a, key);
    if (entry.found_existing) s.revision_key ^= identityKey(entry.value_ptr.*);
    entry.value_ptr.* = identity;
    s.revision_key ^= identityKey(identity);
}
pub fn get(s: Self, service: []const u8, address: []const u8) ?t.Identity {
    if (!s.available) return null;
    return s.entries.get(.{ .service = service, .address = address });
}
fn identityKey(identity: t.Identity) u64 {
    return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, identity.id), identity.revision);
}
pub fn presentationKey(s: Self, service: []const u8, address: []const u8) u64 {
    const identity = s.get(service, address) orelse return 0;
    return identityKey(identity);
}
pub fn fingerprint(s: Self) u64 {
    return if (s.available) s.revision_key else 0;
}
pub fn name(s: Self, service: []const u8, address: []const u8) []const u8 {
    if (s.get(service, address)) |identity| if (identity.match_state == .matched) {
        if (identity.display_name) |value| if (value.len > 0) return value;
    };
    return if (address.len > 0) address else "Unknown sender";
}
pub fn avatar(s: Self, service: []const u8, address: []const u8) ?t.AssetRef {
    const identity = s.get(service, address) orelse return null;
    return if (identity.match_state == .matched) identity.avatar else null;
}
pub fn actor(s: Self, value: t.ReactionActor) []const u8 {
    return if (value.is_self) "You" else s.name(value.service, value.address orelse "");
}
pub fn conversation(s: Self, a: std.mem.Allocator, chat: t.Conversation) []const u8 {
    if (chat.is_self) return "You";
    if (chat.title.len > 0) return chat.title;
    if (chat.participants.len == 0) return "Conversation";
    if (chat.participants.len == 1) return s.name(chat.service, chat.participants[0]);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    for (chat.participants[0..@min(3, chat.participants.len)]) |address|
        names.append(a, s.name(chat.service, address)) catch return "Group conversation";
    const joined = std.mem.join(a, ", ", names.items) catch return "Group conversation";
    if (chat.participants.len <= 3) return joined;
    return std.fmt.allocPrint(a, "{s} +{d}", .{ joined, chat.participants.len - 3 }) catch joined;
}
pub fn matches(s: Self, chat: t.Conversation, query: []const u8) bool {
    if (chat.is_self and contains("You", query)) return true;
    if (query.len == 0 or contains(chat.title, query)) return true;
    for (chat.participants) |address| {
        if (contains(address, query) or contains(s.name(chat.service, address), query)) return true;
    }
    return false;
}
fn contains(value: []const u8, query: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(value, query) != null;
}

test "directory preserves routes, explicit titles, ambiguity and permission clearing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Self = .{};
    try s.put(a, .{ .id = "1", .service = "imessage", .address = "+14155550123", .display_name = "Zoë 👋", .match_state = .matched });
    const chat = t.Conversation{ .service = "imessage", .participants = &.{"+14155550123"} };
    try std.testing.expectEqualStrings("Zoë 👋", s.conversation(a, chat));
    try std.testing.expect(s.matches(chat, "Zoë") and s.matches(chat, "5550123"));
    try std.testing.expectEqualStrings("+14155550123", s.name("sms", "+14155550123"));
    var titled = chat;
    titled.title = "Our title";
    try std.testing.expectEqualStrings("Our title", s.conversation(a, titled));
    s.available = false;
    try std.testing.expectEqualStrings("+14155550123", s.conversation(a, chat));
    s.available = true;
    try s.put(a, .{ .id = "1", .service = "imessage", .address = "+14155550123", .display_name = "Do not show", .match_state = .ambiguous });
    try std.testing.expectEqualStrings("+14155550123", s.conversation(a, chat));
    try std.testing.expectEqualStrings("You", s.actor(.{ .service = "imessage", .is_self = true }));
}
