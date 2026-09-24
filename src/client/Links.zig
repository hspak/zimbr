const std = @import("std");
const t = @import("../protocol/types.zig");
const c = @import("c.zig").api;
const display = @import("display.zig");
pub const Target = struct { url: [:0]const u8, hostname: []const u8 };
pub fn parse(a: std.mem.Allocator, value: []const u8) ?Target {
    if (!@import("../protocol/Url.zig").safe(value)) return null;
    const url = a.dupeZ(u8, value) catch return null;
    var host: [512]u8 = undefined;
    if (c.zc_url_host(url, &host, host.len) == 0) return null;
    return .{ .url = url, .hostname = a.dupe(u8, std.mem.sliceTo(&host, 0)) catch return null };
}
pub fn target(a: std.mem.Allocator, card: t.LinkPreview) ?Target {
    if (card.original_url) |url| if (parse(a, url)) |result| return result;
    return parse(a, card.metadata_url orelse "");
}
pub fn open(value: Target) bool {
    return @import("../protocol/Url.zig").safe(value.url) and c.zc_url_open(value.url) != 0;
}
pub fn inText(a: std.mem.Allocator, value: []const u8) ![]const Target {
    var result: std.ArrayList(Target) = .empty;
    // Attachment anchors delimit links; they are neither URL characters nor
    // a reason to join the text on either side into a different destination.
    var spans = std.mem.splitSequence(u8, value, display.object_marker);
    while (spans.next()) |span| {
        var words = std.mem.tokenizeAny(u8, span, " \r\n\t<>\"");
        while (words.next()) |word| {
            if (result.items.len == 32) return result.items;
            const trimmed = if (word.len > 2 and word[0] == '(' and word[word.len - 1] == ')') word[1 .. word.len - 1] else word;
            if (parse(a, trimmed)) |link| try result.append(a, link);
        }
    }
    return result.items;
}
test "links choose the original destination and reject unsafe activation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const card = t.LinkPreview{ .id = "p", .part_id = "p", .original_url = "https://original.example/path", .metadata_url = "https://other.example/" };
    try std.testing.expectEqualStrings("original.example", target(a, card).?.hostname);
    for ([_][]const u8{ "file:///tmp/a", "javascript:alert(1)", "https://user@host.example/", "https://host.example\\@evil.example/", "https:///", "https://host.example/\narg", "https://host.example/\x00tail", "https://%65xample.invalid/", "https://host.example/\u{202e}txt", "https://host.example/\xff" }) |url| try std.testing.expect(parse(a, url) == null);
    try std.testing.expectEqual(@as(usize, 2), (try inText(a, "First https://one.example/ and https://two.example/.")).len);
    try std.testing.expectEqualStrings("https://one.example/path(a)!", (try inText(a, "https://one.example/path(a)!"))[0].url);
    const attached = try inText(a, "\u{fffc}https://one.example/👋\u{fffc}https://two.example/\u{fffc}");
    try std.testing.expectEqual(@as(usize, 2), attached.len);
    try std.testing.expectEqualStrings("https://one.example/👋", attached[0].url);
    try std.testing.expectEqualStrings("https://two.example/", attached[1].url);
}
