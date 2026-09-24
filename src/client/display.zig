//! Bound presentation work without modifying stored messages or copied text.
const std = @import("std");
const t = @import("../protocol/types.zig");
const bridge = @import("c.zig").api;
pub const max_bytes = 4096;
pub const max_lines = 64;
pub const shortened = "\n… Preview shortened · select and Ctrl+C to copy full text";
pub const unavailable = "Text preview unavailable · select and Ctrl+C to copy";

pub const unknown_grace_ms = 30_000;
pub const MessageStatus = union(enum) { none, label: []const u8, checks: bool };

// Use the original send time so snapshots, echo matching, navigation, and
// restarts cannot restart the grace period. Missing dates must not hide a
// potentially stuck send indefinitely.
fn deferUnknown(timestamp: []const u8, now_ms: i64) bool {
    var sent_ms: i64 = undefined;
    if (bridge.zc_timestamp_ms(timestamp.ptr, timestamp.len, &sent_ms) == 0) return false;
    return now_ms < sent_ms + unknown_grace_ms;
}

pub fn messageStatus(m: t.Message, now_ms: i64) MessageStatus {
    if (m.direction != .outgoing) return .none;
    return switch (m.observed_status) {
        .sent => .{ .checks = false },
        .delivered => .{ .checks = true },
        .unknown => if (deferUnknown(m.timestamp, now_ms)) .none else .{ .label = "unknown" },
        else => .{ .label = @tagName(m.observed_status) },
    };
}

pub fn pendingStatus(a: std.mem.Allocator, state: []const u8, detail: []const u8, sent_at: []const u8, now_ms: i64) []const u8 {
    const uncertain = std.mem.eql(u8, state, "unknown") or std.mem.eql(u8, state, "unconfirmed");
    // Details can also describe uncertainty; defer the entire warning.
    if (uncertain and deferUnknown(sent_at, now_ms)) return "Sending…";
    const status = if (uncertain) "Uncertain · not automatically resent" else if (std.mem.eql(u8, state, "failed")) "Failed" else if (std.mem.eql(u8, state, "sending")) "Saving / submitting…" else state;
    return if (detail.len > 0) std.fmt.allocPrint(a, "{s} · {s}", .{ status, label(a, detail) }) catch status else status;
}

test "unknown delivery status waits thirty seconds while confirmed outcomes appear immediately" {
    const sent_ms: i64 = 1767225600123;
    var m = t.Message{
        .sender = "",
        .service = "imessage",
        .direction = .outgoing,
        .timestamp = "2026-01-01T00:00:00.123000000Z",
        .kind = .text,
        .text = "Hello",
        .decoding = .plain,
        .observed_status = .unknown,
    };
    try std.testing.expect(messageStatus(m, sent_ms) == .none);
    try std.testing.expect(messageStatus(m, sent_ms + 29_999) == .none);
    // No record update is needed for a stalled message to become visible.
    try std.testing.expectEqualStrings("unknown", messageStatus(m, sent_ms + 30_000).label);
    try std.testing.expectEqualStrings("unknown", messageStatus(m, sent_ms + 60_000).label);
    try std.testing.expectEqual(.unknown, m.observed_status);
    m.observed_status = .sent;
    try std.testing.expect(!messageStatus(m, sent_ms + 1).checks);
    try std.testing.expect(!messageStatus(m, sent_ms + 30_000).checks);
    m.observed_status = .delivered;
    try std.testing.expect(messageStatus(m, sent_ms + 1).checks);
    try std.testing.expect(messageStatus(m, sent_ms + 30_000).checks);
    m.observed_status = .failed;
    try std.testing.expectEqualStrings("failed", messageStatus(m, sent_ms + 1).label);
    m.observed_status = .unknown;
    m.direction = .incoming;
    try std.testing.expect(messageStatus(m, sent_ms + 30_000) == .none);
    m.direction = .outgoing;
    for ([_][]const u8{ "2025-12-31T23:59:00Z", "", "invalid" }) |stamp| {
        m.timestamp = stamp;
        try std.testing.expectEqualStrings("unknown", messageStatus(m, sent_ms).label);
    }
}

test "pending uncertainty and its details share a grace period based on the original send time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sent_ms: i64 = 1767225600000;
    // Both supported timestamp precisions and timezone offsets describe the
    // same send, so importing an echo must not change the deadline.
    for ([_][]const u8{ "2026-01-01T00:00:00Z", "2026-01-01T00:00:00.000000000Z", "2025-12-31T16:00:00-08:00" }) |stamp| {
        for ([_][]const u8{ "unknown", "unconfirmed" }) |state| {
            try std.testing.expectEqualStrings("Sending…", pendingStatus(a, state, "Outcome uncertain", stamp, sent_ms + 29_999));
            try std.testing.expectEqualStrings("Uncertain · not automatically resent · Outcome uncertain", pendingStatus(a, state, "Outcome uncertain", stamp, sent_ms + 30_000));
        }
        try std.testing.expectEqualStrings("Failed · Rejected", pendingStatus(a, "failed", "Rejected", stamp, sent_ms));
        try std.testing.expectEqualStrings("Saving / submitting…", pendingStatus(a, "sending", "", stamp, sent_ms));
        try std.testing.expectEqualStrings("queued", pendingStatus(a, "queued", "", stamp, sent_ms));
    }
    try std.testing.expectEqualStrings("Uncertain · not automatically resent", pendingStatus(a, "unknown", "", "", sent_ms));
}

pub fn prefix(value: []const u8, limit: usize, lines: usize) []const u8 {
    var end: usize = 0;
    var line: usize = 1;
    while (end < @min(value.len, limit)) {
        // Skip ordinary ASCII in blocks; UTF-8, line boundaries, and NUL use
        // the exact scalar path below. Long plain-text histories are common.
        if (@min(value.len, limit) - end >= 16) {
            const bytes: @Vector(16, u8) = value[end..][0..16].*;
            const special = (bytes >= @as(@Vector(16, u8), @splat(128))) |
                (bytes == @as(@Vector(16, u8), @splat(0))) |
                (bytes == @as(@Vector(16, u8), @splat('\n'))) |
                (bytes == @as(@Vector(16, u8), @splat('\r')));
            if (!@reduce(.Or, special)) {
                end += 16;
                continue;
            }
        }
        const n = std.unicode.utf8ByteSequenceLength(value[end]) catch break;
        if (n > @min(value.len, limit) - end) break;
        const cp = std.unicode.utf8Decode(value[end..][0..n]) catch break;
        if (cp == 0) break;
        if (cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029) {
            if (line >= lines) break;
            line += 1;
        }
        end += n;
    }
    return value[0..end];
}

pub const object_marker = "\u{fffc}";

/// Attachment anchors are structural text, not a user-visible caption. Keep
/// source strings intact because part offsets and whole-message copying use them.
pub fn withoutObjectMarkers(a: std.mem.Allocator, value: []const u8) []const u8 {
    if (std.mem.indexOf(u8, value, object_marker) == null) return value;
    const text = std.mem.replaceOwned(u8, a, value, object_marker, "") catch return unavailable;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        a.free(text);
        return "";
    }
    return text;
}

pub fn message(a: std.mem.Allocator, value: []const u8) []const u8 {
    const text = withoutObjectMarkers(a, value);
    const visible = prefix(text, max_bytes, max_lines);
    if (visible.len == text.len) return text;
    return std.mem.concat(a, u8, &.{ visible, shortened }) catch unavailable;
}

pub fn record(a: std.mem.Allocator, m: t.Message) []const u8 {
    return message(a, content(a, m));
}
fn content(a: std.mem.Allocator, m: t.Message) []const u8 {
    const text = withoutObjectMarkers(a, m.text orelse "");
    if (m.reaction_event) |event| {
        const state = switch (event.resolution) {
            .pending => "Target not available yet",
            .resolved => "Target message is not loaded yet",
            .unavailable => "Target unavailable",
            .unsupported => "Unsupported reaction",
            .malformed => "Reaction target could not be decoded",
        };
        return std.fmt.allocPrint(a, "Reaction {s} · {s}{s}{s}", .{ event.emoji orelse event.key orelse "", state, if (text.len > 0) "\n" else "", text }) catch state;
    }
    if (text.len > 0) {
        if (m.kind == .text or m.kind == .attachment) return text;
        if (m.kind == .reaction or m.kind == .system or m.kind == .unsupported)
            return std.fmt.allocPrint(a, "{s} · {s}", .{ if (m.kind == .reaction) "Reaction" else if (m.kind == .system) "Conversation update" else "Unsupported content", text }) catch text;
    }
    if (m.attachments.len > 0) return std.fmt.allocPrint(a, "Attachment · {s}\n{s} · {s} bytes\nDownloads are not available yet.", .{ m.attachments[0].name, m.attachments[0].mime_type, m.attachments[0].bytes }) catch "Attachment";
    return switch (m.kind) {
        .attachment => "Attachment · preview unavailable",
        .reaction => "Reaction · unsupported content",
        .system => "Conversation update · unsupported content",
        .empty => "Empty message",
        else => "Unsupported message · content could not be decoded",
    };
}

pub fn label(a: std.mem.Allocator, value: []const u8) []const u8 {
    const visible = prefix(value, 256, 1);
    if (visible.len == value.len) return value;
    return std.mem.concat(a, u8, &.{ visible, "…" }) catch "…";
}

test "display limits preserve UTF8 and never change full message content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const normal = "Café é 👩‍💻 🇺🇸\nשלום مرحبا <b>literal text</b>";
    try std.testing.expectEqualStrings(normal, message(a, normal));
    try std.testing.expectEqualStrings(normal, message(a, object_marker ++ normal ++ object_marker));
    try std.testing.expectEqualStrings("", message(a, object_marker ++ "\n" ++ object_marker));
    const long = try std.mem.concat(a, u8, &.{ "x" ** (max_bytes - 1), "👩‍💻", "tail" });
    const preview = message(a, long);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview));
    try std.testing.expect(std.mem.endsWith(u8, preview, shortened));
    try std.testing.expect(std.mem.endsWith(u8, long, "👩‍💻tail"));
    try std.testing.expect(message(a, "\n" ** 1000).len < 200);
    try std.testing.expect(message(a, "before\x00after").len < 100);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message(a, "bad\xff")));
    try std.testing.expect(label(a, "url" ** 1000).len <= 259);
    try std.testing.expectEqualStrings("a" ** 32, prefix("a" ** 32 ++ "\ntrailing", 64, 1));
    try std.testing.expectEqualStrings("a" ** 32, prefix("a" ** 32 ++ "\u{2028}trailing", 64, 1));
    try std.testing.expectEqualStrings("a" ** 32, prefix("a" ** 32 ++ "\x00trailing", 64, 2));
}

/// Captions always win; image arrival never changes notification eligibility.
pub fn summary(a: std.mem.Allocator, m: t.Message) []const u8 {
    const text = withoutObjectMarkers(a, m.text orelse "");
    if (text.len > 0) return text;
    var photos: usize = 0;
    for (m.attachments) |item| if (!item.preview_artwork and (item.image != null or std.mem.startsWith(u8, item.mime_type, "image/"))) {
        photos += 1;
    };
    if (photos == 1) return "Photo";
    if (photos > 1) return std.fmt.allocPrint(a, "{d} photos", .{photos}) catch "Photos";
    return switch (m.kind) {
        .attachment => "Attachment",
        .reaction => "Reaction",
        .system => "Conversation update",
        .empty => "Empty message",
        else => "Unsupported message",
    };
}

pub fn resolvedReaction(m: t.Message) bool {
    const event = m.reaction_event orelse return false;
    return event.resolution == .resolved and event.target_message_id != null;
}
