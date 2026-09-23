const std = @import("std");
pub const c = @cImport({
    @cInclude("platform.h");
});
pub const Allocator = std.mem.Allocator;
pub fn json(a: Allocator, v: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}
pub fn id(a: Allocator) ![]const u8 {
    var b: [16]u8 = undefined;
    if (c.zr_random(&b, b.len) != 0) return error.RandomUnavailable;
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}
pub fn decimal(a: Allocator, n: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}
pub fn timestamp(a: Allocator, n: i64) ![]const u8 {
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
