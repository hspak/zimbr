//! Lossless RGBA PNGs using zlib's fast native compressor, including in Debug builds.
const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn compressBound(c_ulong) c_ulong;
extern fn compress2([*]u8, *c_ulong, [*]const u8, c_ulong, c_int) c_int;

pub const EncodeError = Allocator.Error || error{ InvalidPixels, CompressionFailed };

/// Encode tightly packed, top-to-bottom RGBA8 pixels. The caller owns the result.
pub fn encode(allocator: Allocator, width: u32, height: u32, pixels: []const u8) EncodeError![]u8 {
    const count = @as(u64, width) * height;
    if (count == 0 or count > 64_000_000 or count * 4 != pixels.len) return error.InvalidPixels;
    const stride: usize = @as(usize, width) * 4;
    const rows = try allocator.alloc(u8, (stride + 1) * height);
    defer allocator.free(rows);
    for (0..height) |y| {
        const offset = y * (stride + 1);
        rows[offset] = 0; // PNG filter None preserves bytes without per-pixel UI-thread work.
        @memcpy(rows[offset + 1 ..][0..stride], pixels[y * stride ..][0..stride]);
    }
    var size = compressBound(@intCast(rows.len));
    const compressed = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(compressed);
    if (compress2(compressed.ptr, &size, rows.ptr, @intCast(rows.len), 1) != 0)
        return error.CompressionFailed;

    const output = try allocator.alloc(u8, @as(usize, @intCast(size)) + 57);
    @memcpy(output[0..8], "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 6, 0, 0, 0 };
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    var offset = chunk(output, 8, "IHDR", &header);
    offset = chunk(output, offset, "IDAT", compressed[0..@intCast(size)]);
    offset = chunk(output, offset, "IEND", &.{});
    std.debug.assert(offset == output.len);
    return output;
}

fn chunk(output: []u8, offset: usize, kind: *const [4]u8, data: []const u8) usize {
    const destination = output[offset..];
    std.mem.writeInt(u32, destination[0..4], @intCast(data.len), .big);
    @memcpy(destination[4..8], kind);
    @memcpy(destination[8..][0..data.len], data);
    const end = data.len + 8;
    std.mem.writeInt(u32, destination[end..][0..4], std.hash.Crc32.hash(destination[4..end]), .big);
    return offset + end + 4;
}

test "PNG preserves row order and every RGBA channel with valid chunk checksums" {
    const pixels = [_]u8{ 255, 0, 1, 0, 2, 128, 254, 255, 10, 20, 30, 40, 0, 255, 0, 128 };
    const encoded = try encode(std.testing.allocator, 2, 2, &pixels);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", encoded[0..8]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[20..24], .big));
    try std.testing.expectEqualSlices(u8, &.{ 8, 6, 0, 0, 0 }, encoded[24..29]);
    var offset: usize = 8;
    var count: usize = 0;
    while (offset < encoded.len) : (count += 1) {
        const length = std.mem.readInt(u32, encoded[offset..][0..4], .big);
        const end = offset + 8 + length;
        try std.testing.expectEqual(std.hash.Crc32.hash(encoded[offset + 4 .. end]), std.mem.readInt(u32, encoded[end..][0..4], .big));
        if (std.mem.eql(u8, encoded[offset + 4 ..][0..4], "IDAT")) {
            // Decode with Zig's independent implementation, not the encoding library.
            var input = std.Io.Reader.fixed(encoded[offset + 8 .. end]);
            var history: [std.compress.flate.max_window_len]u8 = undefined;
            var decoder = std.compress.flate.Decompress.init(&input, .zlib, &history);
            var decoded: [18]u8 = undefined;
            try decoder.reader.readSliceAll(&decoded);
            try std.testing.expectEqual(@as(u8, 0), decoded[0]);
            try std.testing.expectEqual(@as(u8, 0), decoded[9]);
            try std.testing.expectEqualSlices(u8, pixels[0..8], decoded[1..9]);
            try std.testing.expectEqualSlices(u8, pixels[8..16], decoded[10..18]);
        }
        offset = end + 4;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "PNG rejects invalid dimensions and incomplete pixel buffers before allocation" {
    const allocator = std.testing.failing_allocator;
    try std.testing.expectError(error.InvalidPixels, encode(allocator, 0, 1, &.{}));
    try std.testing.expectError(error.InvalidPixels, encode(allocator, 1, 1, &.{ 0, 0, 0 }));
    try std.testing.expectError(error.InvalidPixels, encode(allocator, 0xffffffff, 0xffffffff, &.{}));
}
