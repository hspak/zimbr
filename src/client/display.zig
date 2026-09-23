//! Bound presentation work without modifying stored messages or copied text.
const std = @import("std");
const t = @import("../protocol/types.zig");
pub const max_bytes = 4096;
pub const max_lines = 64;
pub const shortened = "\n… Preview shortened · select and Ctrl+C to copy full text";
pub const unavailable = "Text preview unavailable · select and Ctrl+C to copy";

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

pub fn message(a: std.mem.Allocator, value: []const u8) []const u8 {
    const visible = prefix(value, max_bytes, max_lines);
    if (visible.len == value.len) return value;
    return std.mem.concat(a, u8, &.{ visible, shortened }) catch unavailable;
}

pub fn record(a: std.mem.Allocator, m: t.Message) []const u8 {
    return message(a, content(a, m));
}
fn content(a: std.mem.Allocator, m: t.Message) []const u8 {
    if (m.text) |text| if (text.len > 0) {
        if (m.kind == .text) return text;
        if (m.kind == .reaction or m.kind == .system or m.kind == .unsupported)
            return std.fmt.allocPrint(a, "{s} · {s}", .{ if (m.kind == .reaction) "Reaction" else if (m.kind == .system) "Conversation update" else "Unsupported content", text }) catch text;
    };
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
