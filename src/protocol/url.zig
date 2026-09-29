//! Shared HTTP(S) activation policy and request-component formatting.
const std = @import("std");

/// Format one raw path segment or query value with RFC 3986 percent encoding.
/// The formatter borrows raw and writes directly into the destination.
pub fn escaped(raw: []const u8) std.fmt.Alt(std.Uri.Component, std.Uri.Component.formatEscaped) {
    return std.fmt.alt(std.Uri.Component{ .raw = raw }, .formatEscaped);
}

test "escaped components cannot inject path or query delimiters" {
    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buffer, "/messages/{f}?before={f}", .{
        escaped("a/b?x=1&y=%"),
        escaped("é :+\x00"),
    });
    try std.testing.expectEqualStrings("/messages/a%2Fb%3Fx%3D1%26y%3D%25?before=%C3%A9%20%3A%2B%00", path);
    try std.testing.expectEqual(@as(u8, 0), path[path.len]);
    try std.testing.expectEqualStrings("AZaz09-_.~", try std.fmt.bufPrint(&buffer, "{f}", .{escaped("AZaz09-_.~")}));
    try std.testing.expectError(error.NoSpaceLeft, std.fmt.bufPrintZ(buffer[0..3], "{f}", .{escaped("/ ")}));
}

pub fn safe(url: []const u8) bool {
    // A 4 KiB cap allows ordinary links while bounding parser and stored-preview work.
    if (url.len == 0 or url.len > 4096 or !std.unicode.utf8ValidateSlice(url)) return false;
    for (url) |byte| if (byte <= 32 or byte == 127 or byte == '\\') return false;
    var codepoints = (std.unicode.Utf8View.init(url) catch return false).iterator();
    while (codepoints.nextCodepoint()) |cp| switch (cp) {
        // Directional controls can hide the destination in confirmation UI.
        0x061c, 0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069 => return false,
        else => {},
    };
    const parsed = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "https") and !std.ascii.eqlIgnoreCase(
        parsed.scheme,
        "http",
    )) return false;
    if (parsed.user != null or parsed.password != null or parsed.host == null) return false;
    const host = parsed.host.?.percent_encoded;
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '%') != null) return false;
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return false;
        _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return false;
    } else {
        for (host) |byte| if (byte < 128 and !std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return false;
        if (host[0] == '.' or std.mem.indexOf(u8, host, "..") != null) return false;
    }
    return true;
}
