//! Packed media identity. The high nibble retains the disk cache's variant prefix.
const std = @import("std");
const Key = @This();

bytes: [32]u8,

pub const Kind = enum(u4) { avatar = 10, inline_image = 11, viewer = 12, local = 13 };

pub fn init(digest: [32]u8, kind: Kind) Key {
    var key: Key = .{ .bytes = digest };
    key.bytes[0] = (key.bytes[0] & 15) | (@as(u8, @intFromEnum(kind)) << 4);
    return key;
}
pub fn isAvatar(key: Key) bool {
    return key.bytes[0] >> 4 == @intFromEnum(Kind.avatar);
}
/// The existing disk filename, including its C terminator. No cache migration is needed.
pub fn hex(key: Key) [64:0]u8 {
    var name: [64:0]u8 = undefined;
    @memcpy(name[0..64], &std.fmt.bytesToHex(key.bytes, .lower));
    name[64] = 0;
    return name;
}
pub fn eql(key: Key, other: Key) bool {
    return std.mem.eql(u8, &key.bytes, &other.bytes);
}

test "packed media identities retain all disk nibbles and variant isolation" {
    const digest = [_]u8{0x12} ** 32;
    const avatar = Key.init(digest, .avatar);
    const photo = Key.init(digest, .inline_image);
    try std.testing.expectEqualStrings("a2" ++ "12" ** 31, &avatar.hex());
    try std.testing.expectEqualStrings("b2" ++ "12" ** 31, &photo.hex());
    try std.testing.expect(avatar.isAvatar() and !photo.isAvatar());
    try std.testing.expect(!avatar.eql(photo));
    var last = digest;
    last[31] = 0x13;
    try std.testing.expect(!photo.eql(.init(last, .inline_image)));
}
