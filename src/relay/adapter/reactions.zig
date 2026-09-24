//! Source format candidates are fixture-tested independently of rollout. Native
//! capability remains gated until the recorded Mac's operation/deletion cases
//! have been observed. Unknown types never acquire an invented reaction value.
const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol/types.zig");
pub const Observation = struct {
    target_guid: ?[]const u8 = null,
    source_part: ?u32 = null,
    bubble: bool = false,
    range_location: ?i64 = null,
    range_length: ?i64 = null,
    event: t.ReactionEvent,
};
pub fn candidate(code: i64) bool {
    return code == 1000 or (code >= 2000 and code < 4000);
}
pub fn decode(a: u.Allocator, code: i64, target: []const u8, emoji: []const u8, actor: t.ReactionActor) !?Observation {
    if (!candidate(code)) return null; // ordinary replies also carry GUIDs
    var value = Observation{ .event = .{ .actor = actor, .operation = .unknown, .resolution = .unsupported } };
    const base = if (code >= 3000) code - 3000 else code - 2000;
    if (base >= 0 and base <= 6) {
        value.event.operation = if (code >= 3000) .remove else .add;
        if (base < 6) {
            const keys = [_][]const u8{ "heart", "like", "dislike", "laugh", "emphasize", "question" };
            const symbols = [_][]const u8{ "❤️", "👍", "👎", "😂", "‼️", "❓" };
            value.event.key = keys[@intCast(base)];
            value.event.emoji = symbols[@intCast(base)];
        } else if (emoji.len > 0 and emoji.len <= 256 and std.unicode.utf8ValidateSlice(emoji)) {
            // Preserve the entire supplied sequence, including ZWJ, selectors,
            // skin modifiers, and flags; no byte/codepoint truncation.
            for (emoji) |byte| if (byte < 32 or byte == 127) return value;
            value.event.key = try std.fmt.allocPrint(a, "emoji:{s}", .{emoji});
            value.event.emoji = try a.dupe(u8, emoji);
        } else return value;
        value.event.resolution = .pending;
    }
    var guid = target;
    if (std.mem.startsWith(u8, target, "p:")) {
        const separator = std.mem.indexOfScalar(u8, target, '/') orelse {
            value.event.resolution = .malformed;
            return value;
        };
        const index = target[2..separator];
        if (index.len == 0 or index.len > 10) {
            value.event.resolution = .malformed;
            return value;
        }
        for (index) |byte| if (!std.ascii.isDigit(byte)) {
            value.event.resolution = .malformed;
            return value;
        };
        value.source_part = std.fmt.parseInt(u32, index, 10) catch {
            value.event.resolution = .malformed;
            return value;
        };
        guid = target[separator + 1 ..];
    } else if (std.mem.startsWith(u8, target, "bp:")) {
        value.bubble = true;
        guid = target[3..];
    }
    if (!t.uuid(guid)) {
        value.event.resolution = .malformed;
        return value;
    }
    value.target_guid = try a.dupe(u8, guid);
    if (!actor.is_self and (actor.address == null or actor.address.?.len == 0)) value.event.resolution = .unavailable;
    return value;
}

test "reaction mapping preserves emoji sequences and rejects replies, stickers, and malformed targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target = "p:2/12345678-1234-1234-1234-123456789abc";
    const actor: t.ReactionActor = .{ .service = "imessage", .address = "fixture@example.invalid" };
    const expected = [_][]const u8{ "heart", "like", "dislike", "laugh", "emphasize", "question" };
    for (expected, 0..) |key, i| {
        const add = (try decode(a, 2000 + @as(i64, @intCast(i)), target, "", actor)).?;
        const remove = (try decode(a, 3000 + @as(i64, @intCast(i)), target, "", actor)).?;
        try std.testing.expectEqualStrings(key, add.event.key.?);
        try std.testing.expectEqual(add.event.key, remove.event.key);
        try std.testing.expectEqual(.remove, remove.event.operation);
        try std.testing.expectEqual(@as(?u32, 2), add.source_part);
    }
    try std.testing.expectEqualStrings("👩🏽‍💻", (try decode(a, 2006, target, "👩🏽‍💻", actor)).?.event.emoji.?);
    try std.testing.expect((try decode(a, 0, target, "", actor)) == null);
    try std.testing.expectEqual(.unsupported, (try decode(a, 2007, target, "", actor)).?.event.resolution);
    try std.testing.expectEqual(.malformed, (try decode(a, 2001, "p:bad/not-a-guid", "", actor)).?.event.resolution);
}
