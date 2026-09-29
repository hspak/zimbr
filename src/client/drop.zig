//! Bounded local file-manager offers. URI parsing precedes GLFW's path callback
//! so authorities, escapes and path lengths cannot be lost by the backend.
const std = @import("std");
const c = @import("c.zig").api;

/// Whether a file offer is over the window, before it is dropped or leaves.
/// Read only on the GUI thread.
pub fn hovered() bool {
    return c.zc_drop_hovered() != 0;
}

/// Consume a backend rejection once, on the GUI thread.
pub fn rejected() bool {
    return c.zc_drop_take_error() != 0;
}

test "file drops decode local Unicode paths without accepting authorities or malformed URIs" {
    var result: c.ZcDrop = undefined;
    const valid = "# comment\r\nfile:///tmp/photo%20%F0%9F%91%8B.png\r\nfile://localhost/tmp/a%23b%3Fc%25.txt\nfile:/tmp/empty\n";
    try std.testing.expectEqual(@as(c_int, 1), c.zc_drop_parse(valid, valid.len, &result));
    try std.testing.expectEqual(@as(c_int, 3), result.count);
    try std.testing.expectEqualStrings("/tmp/photo 👋.png", std.mem.sliceTo(&result.paths[0], 0));
    try std.testing.expectEqualStrings("/tmp/a#b?c%.txt", std.mem.sliceTo(&result.paths[1], 0));
    try std.testing.expectEqualStrings("/tmp/empty", std.mem.sliceTo(&result.paths[2], 0));
    for ([_][]const u8{
        "file://remote/tmp/file",
        "file://remote",
        "file://",
        "https://example.invalid/photo.png",
        "/tmp/plain-path",
        "file:///tmp/truncated%",
        "file:///tmp/bad%0G",
        "file:///tmp/hidden%00.txt",
        "file:///tmp/line%0A.txt",
        "file:///tmp/file?query",
        "file:///tmp/file#fragment",
        "file:///tmp/hidden\x00.txt",
        "file:///" ++ "x" ** 4095,
        "file:///tmp/one\n" ** 17,
    }) |invalid| {
        try std.testing.expectEqual(@as(c_int, 0), c.zc_drop_parse(invalid.ptr, invalid.len, &result));
        try std.testing.expectEqual(@as(c_int, 0), result.count);
        try std.testing.expect(rejected());
        try std.testing.expect(!rejected());
    }
    const boundary = "file:///tmp/file\n" ** 16;
    try std.testing.expectEqual(@as(c_int, 1), c.zc_drop_parse(boundary, boundary.len, &result));
    try std.testing.expectEqual(@as(c_int, 16), result.count);
}
