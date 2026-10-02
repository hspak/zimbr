//! Bound presentation work without modifying stored messages or copied text.
const std = @import("std");
const t = @import("../protocol.zig").types;
const bridge = @import("c.zig").api;
// Limit preview shaping to 4 KiB; copying still exposes the complete message.
pub const max_bytes = 4096;
// 64 lines prevents a single multiline preview from dominating layout work.
pub const max_lines = 64;
pub const shortened = "\n… Preview shortened · select and Ctrl+C to copy full text";
pub const unavailable = "Text preview unavailable · select and Ctrl+C to copy";

/// Formats all active categories into caller-owned storage, or returns empty when idle.
pub fn syncLabel(activity: t.SyncActivity, buffer: *[96]u8) []const u8 {
    if (!activity.active()) return "";
    const label_prefix = "Syncing ";
    @memcpy(buffer[0..label_prefix.len], label_prefix);
    var end: usize = label_prefix.len;
    inline for (.{
        .{ "messages", "Messages" },
        .{ "contacts", "Contacts" },
        .{ "images", "Images" },
        .{ "media", "Media" },
    }) |category| {
        if (@field(activity, category[0])) {
            if (end > label_prefix.len) {
                @memcpy(buffer[end..][0..2], ", ");
                end += 2;
            }
            @memcpy(buffer[end..][0..category[1].len], category[1]);
            end += category[1].len;
        }
    }
    @memcpy(buffer[end..][0.."…".len], "…");
    return buffer[0 .. end + "…".len];
}

// Allow 30 seconds for an uncertain send to be reconciled before showing recovery actions.
pub const unknown_grace_ms = 30_000;
pub const MessageStatus = union(enum) {
    none,
    label: []const u8,
    checks: Checks,

    pub const Checks = enum {
        sent,
        group_sent,
        delivered,
    };
};

// Use the original send time so snapshots, echo matching, navigation, and
// restarts cannot restart the grace period. Missing dates must not hide a
// potentially stuck send indefinitely.
fn deferUnknown(timestamp: []const u8, now_ms: i64) bool {
    var sent_ms: i64 = undefined;
    if (bridge.zc_timestamp_ms(timestamp.ptr, timestamp.len, &sent_ms) == 0) return false;
    return now_ms < sent_ms + unknown_grace_ms;
}

pub fn messageStatus(m: t.Message, is_group: bool, now_ms: i64) MessageStatus {
    if (m.direction != .outgoing) return .none;
    return switch (m.observed_status) {
        .sent => .{ .checks = if (is_group) .group_sent else .sent },
        .delivered => .{ .checks = .delivered },
        .unknown => if (deferUnknown(m.timestamp, now_ms)) .none else .{ .label = "unknown" },
        .received, .failed => .{ .label = @tagName(m.observed_status) },
    };
}

/// Borrow unchanged labels and inputs; formatted text uses the caller's arena.
/// Partial allocations on error share that arena's lifetime.
pub fn pendingStatus(
    a: std.mem.Allocator,
    state: []const u8,
    detail: []const u8,
    sent_at: []const u8,
    now_ms: i64,
) std.mem.Allocator.Error![]const u8 {
    if (std.mem.eql(u8, state, "uploading")) return if (detail.len > 0) detail else "Uploading attachments…";
    const uncertain = std.mem.eql(u8, state, "unknown") or std.mem.eql(u8, state, "unconfirmed");
    // Relay phases can change before the echo arrives. Keep their presentation
    // stable until the send fails or needs recovery, including uncertain details.
    if (!std.mem.eql(u8, state, "delivered") and !canCopyPending(state, sent_at, now_ms)) return "Sending…";
    const status = if (uncertain) "Uncertain · not automatically resent" else if (std.mem.eql(
        u8,
        state,
        "failed",
    )) "Failed" else if (std.mem.eql(
        u8,
        state,
        "sending",
    )) "Saving / submitting…" else if (std.mem.eql(u8, state, "cancelled")) "Upload cancelled" else state;
    return if (detail.len > 0) try std.fmt.allocPrint(a, "{s} · {s}", .{ status, try label(a, detail) }) else status;
}

pub fn canCopyPending(state: []const u8, sent_at: []const u8, now_ms: i64) bool {
    if (std.mem.eql(u8, state, "uploading") or std.mem.eql(u8, state, "delivered")) return false;
    return std.mem.eql(u8, state, "failed") or std.mem.eql(u8, state, "cancelled") or !deferUnknown(sent_at, now_ms);
}

pub fn attachmentStatus(send_request: ?t.SendRequest, id: []const u8) []const u8 {
    const request = send_request orelse return "Saved on this device";
    for (request.parts) |part| if (part.attachment_id != null and std.mem.eql(u8, part.attachment_id.?, id)) {
        return switch (part.state) {
            .queued => "Waiting to send",
            .dispatching => "Submitting…",
            .invoked => "Awaiting confirmation",
            .submitted => "Sent",
            .delivered => "Delivered",
            .failed => "Failed",
            .unknown => "Uncertain · check before sending again",
            .skipped => "Not sent",
        };
    };
    return "Saved on this device";
}

pub fn captionMayHaveSent(send_request: ?t.SendRequest, state: []const u8) bool {
    if (std.mem.eql(u8, state, "uploading") or std.mem.eql(u8, state, "cancelled")) return false;
    if (send_request) |request| if (request.parts.len > 0) {
        for (request.parts) |part| if (part.kind == .text) return switch (part.state) {
            .queued, .failed, .skipped => false,
            .dispatching, .invoked, .submitted, .delivered, .unknown => true,
        };
        return false;
    };
    return !std.mem.eql(u8, state, "failed");
}

test "caption recovery distinguishes partial dispatch from cancelled or rejected uploads" {
    try std.testing.expect(!captionMayHaveSent(null, "cancelled"));
    try std.testing.expect(!captionMayHaveSent(null, "failed"));
    try std.testing.expect(captionMayHaveSent(null, "unconfirmed"));
    var parts = [_]t.SendPart{
        .{ .kind = .text, .state = .delivered },
        .{
            .kind = .attachment,
            .attachment_id = "file",
            .state = .failed,
        },
    };
    const request: t.SendRequest = .{
        .request_id = "request",
        .server_epoch = "epoch",
        .target = .{ .conversation_id = "chat" },
        .text = "Caption",
        .state = .failed,
        .parts = &parts,
    };
    try std.testing.expect(captionMayHaveSent(request, "failed"));
    try std.testing.expectEqualStrings("Failed", attachmentStatus(request, "file"));
    parts[0].state = .failed;
    parts[1].state = .skipped;
    try std.testing.expect(!captionMayHaveSent(request, "failed"));
    try std.testing.expectEqualStrings("Not sent", attachmentStatus(request, "file"));
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
    try std.testing.expect(messageStatus(m, false, sent_ms) == .none);
    try std.testing.expect(messageStatus(m, false, sent_ms + 29_999) == .none);
    // No record update is needed for a stalled message to become visible.
    try std.testing.expectEqualStrings("unknown", messageStatus(m, false, sent_ms + 30_000).label);
    try std.testing.expectEqualStrings("unknown", messageStatus(m, false, sent_ms + 60_000).label);
    try std.testing.expectEqual(.unknown, m.observed_status);
    m.observed_status = .sent;
    try std.testing.expectEqual(.sent, messageStatus(m, false, sent_ms + 1).checks);
    try std.testing.expectEqual(.sent, messageStatus(m, false, sent_ms + 30_000).checks);
    try std.testing.expectEqual(.group_sent, messageStatus(m, true, sent_ms + 1).checks);
    try std.testing.expectEqual(.group_sent, messageStatus(m, true, sent_ms + 30_000).checks);
    try std.testing.expectEqual(.sent, m.observed_status);
    m.observed_status = .delivered;
    try std.testing.expectEqual(.delivered, messageStatus(m, false, sent_ms + 1).checks);
    try std.testing.expectEqual(.delivered, messageStatus(m, false, sent_ms + 30_000).checks);
    try std.testing.expectEqual(.delivered, messageStatus(m, true, sent_ms + 1).checks);
    m.observed_status = .failed;
    try std.testing.expectEqualStrings("failed", messageStatus(m, false, sent_ms + 1).label);
    try std.testing.expectEqualStrings("failed", messageStatus(m, true, sent_ms + 1).label);
    m.observed_status = .unknown;
    try std.testing.expect(messageStatus(m, true, sent_ms + 1) == .none);
    try std.testing.expectEqualStrings("unknown", messageStatus(m, true, sent_ms + 30_000).label);
    m.direction = .incoming;
    try std.testing.expect(messageStatus(m, false, sent_ms + 30_000) == .none);
    try std.testing.expect(messageStatus(m, true, sent_ms + 30_000) == .none);
    m.direction = .outgoing;
    for ([_][]const u8{
        "2025-12-31T23:59:00Z",
        "",
        "invalid",
    }) |stamp| {
        m.timestamp = stamp;
        try std.testing.expectEqualStrings("unknown", messageStatus(m, false, sent_ms).label);
    }
}

test "pending uncertainty and its details share a grace period based on the original send time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sent_ms: i64 = 1767225600000;
    // Both supported timestamp precisions and timezone offsets describe the
    // same send, so importing an echo must not change the deadline.
    for ([_][]const u8{
        "2026-01-01T00:00:00Z",
        "2026-01-01T00:00:00.000000000Z",
        "2025-12-31T16:00:00-08:00",
    }) |stamp| {
        for ([_][]const u8{ "unknown", "unconfirmed" }) |state| {
            try std.testing.expectEqualStrings(
                "Sending…",
                try pendingStatus(a, state, "Outcome uncertain", stamp, sent_ms + 29_999),
            );
            try std.testing.expectEqualStrings(
                "Uncertain · not automatically resent · Outcome uncertain",
                try pendingStatus(a, state, "Outcome uncertain", stamp, sent_ms + 30_000),
            );
        }
        try std.testing.expectEqualStrings(
            "Failed · Rejected",
            try pendingStatus(a, "failed", "Rejected", stamp, sent_ms),
        );
        for ([_][]const u8{
            "sending",
            "queued",
            "dispatching",
            "submitted",
        }) |state| {
            try std.testing.expectEqualStrings("Sending…", try pendingStatus(a, state, "", stamp, sent_ms));
        }
        try std.testing.expectEqualStrings("delivered", try pendingStatus(a, "delivered", "", stamp, sent_ms));
    }
    try std.testing.expectEqualStrings(
        "Uncertain · not automatically resent",
        try pendingStatus(a, "unknown", "", "", sent_ms),
    );
}

test "copy to draft waits thirty seconds for pending sends but confirmed failures remain actionable" {
    const sent_ms: i64 = 1767225600000;
    for ([_][]const u8{
        "sending",
        "queued",
        "dispatching",
        "submitted",
        "unknown",
        "unconfirmed",
    }) |state| {
        for ([_][]const u8{
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:00:00.000000000Z",
            "2025-12-31T16:00:00-08:00",
        }) |stamp| {
            try std.testing.expect(!canCopyPending(state, stamp, sent_ms));
            try std.testing.expect(!canCopyPending(state, stamp, sent_ms + 29_999));
            try std.testing.expect(canCopyPending(state, stamp, sent_ms + 30_000));
            try std.testing.expect(canCopyPending(state, stamp, sent_ms + 60_000));
        }
        try std.testing.expect(canCopyPending(state, "", sent_ms));
        try std.testing.expect(canCopyPending(state, "invalid", sent_ms));
    }
    try std.testing.expect(canCopyPending("failed", "2026-01-01T00:00:00Z", sent_ms));
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

// U+FFFC is the attributed-text object replacement character, not user-visible text.
pub const object_marker = "\u{fffc}";

/// Attachment anchors are structural text, not a user-visible caption. Keep
/// source strings intact because part offsets and whole-message copying use them.
/// Borrow value when unchanged, return static empty text when only anchors remain,
/// or return an allocator-owned copy. Errors release temporary storage.
pub fn withoutObjectMarkers(a: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    // Skip bytes that cannot start an anchor before comparing the UTF-8 sequence.
    // Most long messages contain no anchors and need no allocation or rewriting.
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, value, start, object_marker[0])) |candidate| {
        if (std.mem.startsWith(u8, value[candidate..], object_marker)) break;
        start = candidate + 1;
    } else return value;
    const text = try std.mem.replaceOwned(u8, a, value, object_marker, "");
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        a.free(text);
        return "";
    }
    return text;
}

/// Borrow unchanged input; shortened or cleaned text uses the caller's arena.
/// Partial allocations on error share that arena's lifetime.
pub fn message(a: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    const text = try withoutObjectMarkers(a, value);
    const visible = prefix(text, max_bytes, max_lines);
    if (visible.len == text.len) return text;
    return std.mem.concat(a, u8, &.{ visible, shortened });
}

/// Borrow message text or static labels; formatted text uses the caller's arena.
/// Partial allocations on error share that arena's lifetime.
pub fn record(a: std.mem.Allocator, m: t.Message) std.mem.Allocator.Error![]const u8 {
    return message(a, try content(a, m));
}
fn content(a: std.mem.Allocator, m: t.Message) std.mem.Allocator.Error![]const u8 {
    const text = try withoutObjectMarkers(a, m.text orelse "");
    if (m.reaction_event) |event| {
        const state = switch (event.resolution) {
            .pending => "Target not available yet",
            .resolved => "Target message is not loaded yet",
            .unavailable => "Target unavailable",
            .unsupported => "Unsupported reaction",
            .malformed => "Reaction target could not be decoded",
        };
        return std.fmt.allocPrint(a, "Reaction {s} · {s}{s}{s}", .{
            event.emoji orelse event.key orelse "",
            state,
            if (text.len > 0) "\n" else "",
            text,
        });
    }
    if (text.len > 0) {
        if (m.kind == .text or m.kind == .attachment) return text;
        if (m.kind == .reaction or m.kind == .system or m.kind == .unsupported)
            return std.fmt.allocPrint(
                a,
                "{s} · {s}",
                .{ if (m.kind == .reaction) "Reaction" else if (m.kind == .system) "Conversation update" else "Unsupported content", text },
            );
    }
    if (m.attachments.len > 0) return std.fmt.allocPrint(a, "Attachment · {s}\n{s} · {s} bytes\nDownloads are not available yet.", .{
        m.attachments[0].name,
        m.attachments[0].mime_type,
        m.attachments[0].bytes,
    });
    return switch (m.kind) {
        .attachment => "Attachment · preview unavailable",
        .reaction => "Reaction · unsupported content",
        .system => "Conversation update · unsupported content",
        .empty => "Empty message",
        .text, .unsupported => "Unsupported message · content could not be decoded",
    };
}

/// Borrow value when it fits; otherwise return an allocator-owned shortened copy.
pub fn label(a: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    const visible = prefix(value, 256, 1);
    if (visible.len == value.len) return value;
    return std.mem.concat(a, u8, &.{ visible, "…" });
}

test "display limits preserve UTF8 and never change full message content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const normal = "Café é 👩‍💻 🇺🇸\nשלום مرحبا <b>literal text</b>";
    try std.testing.expectEqualStrings(normal, try message(a, normal));
    try std.testing.expectEqualStrings(normal, try message(a, object_marker ++ normal ++ object_marker));
    try std.testing.expectEqualStrings("", try message(a, object_marker ++ "\n" ++ object_marker));
    const long = try std.mem.concat(a, u8, &.{
        "x" ** (max_bytes - 1),
        "👩‍💻",
        "tail",
    });
    const preview = try message(a, long);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview));
    try std.testing.expect(std.mem.endsWith(u8, preview, shortened));
    try std.testing.expect(std.mem.endsWith(u8, long, "👩‍💻tail"));
    try std.testing.expect((try message(a, "\n" ** 1000)).len < 200);
    try std.testing.expect((try message(a, "before\x00after")).len < 100);
    try std.testing.expect(std.unicode.utf8ValidateSlice(try message(a, "bad\xff")));
    try std.testing.expect((try label(a, "url" ** 1000)).len <= 259);
    try std.testing.expectEqualStrings("a" ** 32, prefix("a" ** 32 ++ "\ntrailing", 64, 1));
    try std.testing.expectEqualStrings("a" ** 32, prefix("a" ** 32 ++ "\u{2028}trailing", 64, 1));
    try std.testing.expectEqualStrings("a" ** 32, prefix("a" ** 32 ++ "\x00trailing", 64, 2));
}

test "object marker removal preserves other Unicode and incomplete byte sequences" {
    const unchanged = [_][]const u8{
        "",
        "Ordinary ASCII " ** 4096,
        "\u{feff}Café \u{fffd} 👩‍💻",
        "trailing\xef",
        "trailing\xef\xbf",
        "\xef\xef\xbf",
    };
    for (unchanged) |input| {
        const result = try withoutObjectMarkers(std.testing.failing_allocator, input);
        try std.testing.expectEqual(input.ptr, result.ptr);
        try std.testing.expectEqualStrings(input, result);
    }
    const cases = .{
        .{ "\u{fffd}" ++ object_marker ++ "\u{feff}", "\u{fffd}\u{feff}" },
        .{ "x" ** 31 ++ object_marker ++ "tail", "x" ** 31 ++ "tail" },
        .{ object_marker ++ object_marker ++ "caption" ++ object_marker, "caption" },
        .{ "\xef" ++ object_marker ++ "\xef\xbf", "\xef\xef\xbf" },
        .{ " \t" ++ object_marker ++ "\r\n", "" },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqualStrings(case[1], try withoutObjectMarkers(arena.allocator(), case[0]));
    }
}

/// Captions always win; image arrival never changes notification eligibility.
/// Borrow message text or static labels; formatted text uses the caller's arena.
/// Partial allocations on error share that arena's lifetime.
pub fn summary(a: std.mem.Allocator, m: t.Message) std.mem.Allocator.Error![]const u8 {
    const text = try withoutObjectMarkers(a, m.text orelse "");
    if (text.len > 0) return text;
    var photos: usize = 0;
    for (m.attachments) |item| if (!item.preview_artwork and (item.image != null or std.mem.startsWith(
        u8,
        item.mime_type,
        "image/",
    ))) {
        photos += 1;
    };
    if (photos == 1) return "Photo";
    if (photos > 1) return std.fmt.allocPrint(a, "{d} photos", .{photos});
    return switch (m.kind) {
        .attachment => "Attachment",
        .reaction => "Reaction",
        .system => "Conversation update",
        .empty => "Empty message",
        .text, .unsupported => "Unsupported message",
    };
}

pub fn resolvedReaction(m: t.Message) bool {
    const event = m.reaction_event orelse return false;
    return event.resolution == .resolved and event.target_message_id != null;
}

test "presentation helpers propagate allocation failures" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    const cleaned: std.mem.Allocator.Error![]const u8 = withoutObjectMarkers(a, "Caption" ++ object_marker);
    try std.testing.expectError(error.OutOfMemory, cleaned);
    const preview: std.mem.Allocator.Error![]const u8 = message(a, "x" ** (max_bytes + 1));
    try std.testing.expectError(error.OutOfMemory, preview);
    const caption: std.mem.Allocator.Error![]const u8 = label(a, "x" ** 257);
    try std.testing.expectError(error.OutOfMemory, caption);
    const status: std.mem.Allocator.Error![]const u8 = pendingStatus(a, "failed", "Rejected", "", 0);
    try std.testing.expectError(error.OutOfMemory, status);
}
