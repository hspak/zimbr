const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol.zig").types;
pub const parts = @import("body_parts.zig").decode;
// Exact root object grammars observed on macOS 27, generated independently by
// NSArchiver fixtures. Never search arbitrary archive bytes for printable text.
const prefixes = [_][]const u8{
    "\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+",
    "\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x19NSMutableAttributedString\x00\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x0fNSMutableString\x01\x84\x84\x08NSString\x01\x95\x84\x01+",
};

pub const DecodeError = u.Allocator.Error || error{
    Malformed,
    Oversized,
    Unsupported,
};

/// The caller owns the decoded UTF-8 text; failure releases temporary buffers.
pub fn decode(a: u.Allocator, body: []const u8) DecodeError![]const u8 {
    if (body.len > t.max_decode) return error.Oversized;
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, body, prefix)) continue;
        var pos = prefix.len;
        const length = try readLength(body, &pos);
        if (length > t.max_body) return error.Oversized;
        if (length > body.len - pos or pos + length >= body.len or body[pos + length] != 0x86) return error.Malformed;
        const text = body[pos..][0..length];
        if (std.mem.startsWith(u8, text, "\xff\xfe")) {
            if (text.len % 2 != 0) return error.Malformed;
            const units = try a.alloc(u16, (text.len - 2) / 2);
            defer a.free(units);
            for (units, 0..) |*unit, i| unit.* = std.mem.readInt(
                u16,
                text[2 + i * 2 ..][0..2],
                .little,
            );
            const decoded = std.unicode.utf16LeToUtf8Alloc(a, units) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DanglingSurrogateHalf, error.ExpectedSecondSurrogateHalf, error.UnexpectedSecondSurrogateHalf => return error.Malformed,
            };
            if (decoded.len > t.max_body) {
                a.free(decoded);
                return error.Oversized;
            }
            if (std.mem.indexOfScalar(u8, decoded, 0) != null) {
                a.free(decoded);
                return error.Malformed;
            }
            return decoded;
        }
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.Malformed;
        return a.dupe(u8, text);
    }
    return error.Unsupported;
}
fn readLength(b: []const u8, pos: *usize) !usize {
    if (pos.* >= b.len) return error.Malformed;
    const lead = b[pos.*];
    pos.* += 1;
    if (lead <= 0x7f) return lead;
    const size: usize = switch (lead) {
        0x81 => 2,
        0x82 => 4,
        else => return error.Malformed,
    };
    if (size > b.len - pos.*) return error.Malformed;
    const n: usize = if (size == 2) std.mem.readInt(u16, b[pos.*..][0..2], .little) else std.mem.readInt(
        u32,
        b[pos.*..][0..4],
        .little,
    );
    pos.* += size;
    return n;
}
test "typed string preserves multiline emoji without arbitrary byte extraction" {
    const a = std.testing.allocator;
    const text = "\nHello e\xcc\x81 👩‍💻\n";
    for (prefixes) |p| {
        const fixture = try std.mem.concat(a, u8, &.{
            p,
            &.{text.len},
            text,
            "\x86",
        });
        defer a.free(fixture);
        const decoded = try decode(a, fixture);
        defer a.free(decoded);
        try std.testing.expectEqualStrings(text, decoded);
        try std.testing.expectError(error.Malformed, decode(a, fixture[0 .. fixture.len - 1]));
    }
    try std.testing.expectError(error.Unsupported, decode(a, "junk NSString printable bytes"));
}
test "typed string bounds and UTF16" {
    const a = std.testing.allocator;
    const fixture = prefixes[0] ++ "\x06\xff\xfe\x3d\xd8\x00\xde\x86";
    const decoded = try decode(a, fixture);
    defer a.free(decoded);
    try std.testing.expectEqualStrings("😀", decoded);
    try std.testing.expectError(error.Oversized, decode(a, prefixes[0] ++ "\x82\xff\xff\xff\xff"));
    try std.testing.expectError(error.Malformed, decode(a, prefixes[0] ++ "\x81\xff"));
    try std.testing.expectError(error.Malformed, decode(a, prefixes[0] ++ "\x03a\x00b\x86"));
    try std.testing.expectError(
        error.Malformed,
        decode(a, prefixes[0] ++ "\x04\xff\xfe\x00\x00\x86"),
    );
}

test "independent Foundation archive fixtures" {
    const a = std.testing.allocator;
    inline for (.{ "0", "1" }) |i| {
        const value = try decode(a, @embedFile("fixtures/foundation-" ++ i ++ ".bin"));
        defer a.free(value);
        try std.testing.expectEqualStrings(@embedFile("fixtures/foundation-" ++ i ++ ".txt"), value);
    }
}

test "UTF16 expansion cannot exceed the decoded UTF8 byte limit" {
    const a = std.testing.allocator;
    const prefix = prefixes[0];
    const length = 65534;
    const fixture = try a.alloc(u8, prefix.len + 3 + length + 1);
    defer a.free(fixture);
    @memcpy(fixture[0..prefix.len], prefix);
    fixture[prefix.len] = 0x81;
    std.mem.writeInt(u16, fixture[prefix.len + 1 ..][0..2], length, .little);
    const text = fixture[prefix.len + 3 ..][0..length];
    text[0] = 0xff;
    text[1] = 0xfe;
    // U+4E00 takes two UTF16 bytes but three UTF8 bytes.
    var i: usize = 2;
    while (i < text.len) : (i += 2) std.mem.writeInt(u16, text[i..][0..2], 0x4e00, .little);
    fixture[fixture.len - 1] = 0x86;
    try std.testing.expectError(error.Oversized, decode(a, fixture));
}

fn checkUtf16AllocationFailures(a: u.Allocator) !void {
    const fixture = prefixes[0] ++ "\x06\xff\xfe\x3d\xd8\x00\xde\x86";
    const decoded = try decode(a, fixture);
    defer a.free(decoded);
    try std.testing.expectEqualStrings("😀", decoded);
}

test "UTF16 decoding preserves allocation errors" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkUtf16AllocationFailures,
        .{},
    );
}
