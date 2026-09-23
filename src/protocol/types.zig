const std = @import("std");
const u = @import("../common.zig");
pub const max_body = 64 * 1024;
pub const max_text = 16 * 1024;
pub const max_decode = 1024 * 1024;
pub const max_page = 200;
pub const default_page = 50;
pub const api_version = "1";
pub const Conversation = struct {
    id: []const u8 = "",
    revision: []const u8 = "0",
    participants: []const []const u8 = &.{},
    title: []const u8 = "",
    service: []const u8,
    last_activity: ?[]const u8 = null,
    history_complete: bool = false,
    sendable: bool = false,
};
pub const Attachment = struct { id: []const u8, name: []const u8, mime_type: []const u8, bytes: []const u8 };
// A sidebar projection, never a replacement for the canonical message record.
pub const ConversationPreview = struct { conversation_id: []const u8, message_id: []const u8, revision: []const u8, timestamp: []const u8, kind: []const u8, text: []const u8 };
pub const Message = struct {
    id: []const u8 = "",
    revision: []const u8 = "0",
    conversation_id: []const u8 = "",
    sender: []const u8,
    direction: enum { incoming, outgoing },
    service: []const u8,
    timestamp: []const u8,
    kind: enum { text, attachment, reaction, system, unsupported, empty },
    text: ?[]const u8 = null,
    decoding: enum { plain, attributed, empty, unsupported, malformed, oversized },
    attachments: []const Attachment = &.{},
    observed_status: enum { received, sent, delivered, failed, unknown },
};
pub const Target = struct {
    conversation_id: ?[]const u8 = null,
    recipient: ?struct { address: []const u8, service: []const u8 } = null,
};
pub const SendInput = struct { request_id: []const u8, server_epoch: []const u8, target: Target, text: []const u8 };
pub const SendState = enum { queued, dispatching, submitted, delivered, failed, unknown };
pub const SafeError = struct { code: []const u8, message: []const u8, outcome: enum { unstarted, uncertain } = .unstarted };
pub const SendRequest = struct {
    request_id: []const u8,
    server_epoch: []const u8,
    revision: []const u8 = "0",
    target: Target,
    text: []const u8,
    state: SendState = .queued,
    message_id: ?[]const u8 = null,
    error_info: ?SafeError = null,
};
pub fn uuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return false;
        } else if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}
pub fn validAddress(s: []const u8) bool {
    if (s.len < 3 or s.len > 254) return false;
    if (s[0] == '+') {
        if (s.len < 8 or s.len > 16 or s[1] == '0') return false;
        for (s[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
        return true;
    }
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1 or std.mem.indexOfScalar(u8, s[at + 1 ..], '@') != null) return false;
    if (std.mem.indexOfScalar(u8, s[at + 1 ..], '.') == null) return false;
    for (s) |ch| if (ch <= 32 or ch >= 127 or std.mem.indexOfScalar(u8, "<>\\\"(),;:", ch) != null) return false;
    return true;
}
pub fn validate(v: SendInput) !void {
    if (!uuid(v.request_id) or !uuid(v.server_epoch)) return error.InvalidRequest;
    if (v.text.len > max_text) return error.TextTooLarge;
    if (v.text.len == 0 or !std.unicode.utf8ValidateSlice(v.text) or std.mem.indexOfScalar(u8, v.text, 0) != null) return error.InvalidRequest;
    if ((v.target.conversation_id != null) == (v.target.recipient != null)) return error.InvalidRequest;
    if (v.target.conversation_id) |id| {
        if (!uuid(id)) return error.InvalidRequest;
    }
    if (v.target.recipient) |r| {
        if (!u.eq(r.service, "imessage")) return error.UnsupportedTarget;
        if (!validAddress(r.address)) return error.InvalidRequest;
    }
}
pub fn cursor(a: u.Allocator, epoch: []const u8, seq: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ epoch, seq });
}
pub fn parseCursor(s: []const u8, epoch: []const u8) !i64 {
    if (s.len < 38 or s[36] != ':' or !u.eq(s[0..36], epoch)) return error.ResyncRequired;
    const seq = std.fmt.parseInt(i64, s[37..], 10) catch return error.InvalidRequest;
    if (seq < 0) return error.InvalidRequest;
    return seq;
}
test "send input validation never guesses a service or address" {
    try std.testing.expect(validAddress("+14155550123"));
    try std.testing.expect(validAddress("test@example.invalid"));
    try std.testing.expect(!validAddress("4155550123"));
    try std.testing.expect(!validAddress("Alice"));
    try std.testing.expect(!validAddress("+00012345678"));
}
test "cursor binds sequence to epoch without floating point" {
    const e = "12345678-1234-1234-1234-123456789012";
    try std.testing.expectEqual(@as(i64, 9007199254740993), try parseCursor(e ++ ":9007199254740993", e));
    try std.testing.expectError(error.ResyncRequired, parseCursor(e ++ ":1", "other"));
}

/// UUID spelling is normalized before idempotency lookup; changing letter case
/// cannot turn the same client identity into another dispatch.
pub fn normalize(a: u.Allocator, value: SendInput) !SendInput {
    try validate(value);
    var v = value;
    v.request_id = try std.ascii.allocLowerString(a, v.request_id);
    v.server_epoch = try std.ascii.allocLowerString(a, v.server_epoch);
    if (v.target.conversation_id) |id| v.target.conversation_id = try std.ascii.allocLowerString(a, id);
    return v;
}
