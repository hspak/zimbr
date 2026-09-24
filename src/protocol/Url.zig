//! Shared HTTP(S) activation policy for stored metadata and the client.
const std = @import("std");
pub fn safe(url: []const u8) bool {
    if (url.len == 0 or url.len > 4096 or !std.unicode.utf8ValidateSlice(url)) return false;
    for (url) |byte| if (byte <= 32 or byte == 127 or byte == '\\') return false;
    var codepoints = (std.unicode.Utf8View.init(url) catch return false).iterator();
    while (codepoints.nextCodepoint()) |cp| switch (cp) {
        // Directional controls can hide the destination in confirmation UI.
        0x061c, 0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069 => return false,
        else => {},
    };
    const parsed = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "https") and !std.ascii.eqlIgnoreCase(parsed.scheme, "http")) return false;
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
