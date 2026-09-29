const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const c = @cImport({
    // Zig 0.16 cannot translate glibc's fortified open/openat wrappers.
    // This only affects bindings; compiled C sources retain fortification.
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("platform.h");
});

pub const IdError = Allocator.Error || error{RandomUnavailable};
pub const TimestampError = Allocator.Error || error{InvalidTimestamp};
// UUID identifiers carry 128 bits; Base64url determines the encoded width.
pub const id_length = std.base64.url_safe_no_pad.Encoder.calcSize(16);
// Preserve all 256 SHA-256 bits rather than truncating opaque source identities.
pub const hash_id_length = std.base64.url_safe_no_pad.Encoder.calcSize(32);

pub fn json(a: Allocator, v: anytype) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}
pub fn id(a: Allocator) IdError![]const u8 {
    // A UUID occupies exactly 16 bytes.
    var b: [16]u8 = undefined;
    if (c.zr_random(&b, b.len) != 0) return error.RandomUnavailable;
    // Set the UUID v4 version nibble and RFC variant bits without changing other entropy.
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    return a.dupe(u8, &encodeId(b));
}
/// Encode all UUID bytes as canonical, case-sensitive, unpadded Base64url.
pub fn encodeId(bytes: [16]u8) [id_length]u8 {
    var result: [id_length]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&result, &bytes);
    return result;
}
/// Hash an opaque source identifier and encode the complete SHA-256 digest.
pub fn hashId(bytes: []const u8) [hash_id_length]u8 {
    // SHA-256 produces a 32-byte digest.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var result: [hash_id_length]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&result, &digest);
    return result;
}
pub fn decimal(a: Allocator, n: i64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}
pub fn timestamp(a: Allocator, n: i64) TimestampError![]const u8 {
    // Leave room for the native UTC timestamp, fractional seconds, and terminating NUL.
    var buf: [48]u8 = undefined;
    const len = c.zr_timestamp(n, &buf, buf.len);
    if (len < 0) return error.InvalidTimestamp;
    return a.dupe(u8, buf[0..@intCast(len)]);
}
pub fn now() i64 {
    return c.zr_now_ms();
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "compact IDs preserve UUID bytes and the complete source hash" {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, 0x00112233445566778899aabbccddeeff, .big);
    try std.testing.expectEqualStrings("ABEiM0RVZneImaq7zN3u_w", &encodeId(bytes));
    try std.testing.expectEqualStrings(
        "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0",
        &hashId("abc"),
    );
}

test "generated compact IDs retain UUID version and variant bits" {
    const encoded = try id(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 22), encoded.len);
    var bytes: [16]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&bytes, encoded);
    try std.testing.expectEqual(@as(u8, 4), bytes[6] >> 4);
    try std.testing.expectEqual(@as(u8, 2), bytes[8] >> 6);
}
