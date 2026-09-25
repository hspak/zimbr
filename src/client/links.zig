const std = @import("std");
const url_policy = @import("../protocol.zig").url;
const t = @import("../protocol.zig").types;
const c = @import("c.zig").api;
const display = @import("display.zig");
pub const Target = struct { url: [:0]const u8, hostname: []const u8 };
/// Return null for an unsafe or invalid URL. The caller owns both target strings.
pub fn parse(a: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error!?Target {
    if (!url_policy.safe(value)) return null;
    const url = try a.dupeZ(u8, value);
    errdefer a.free(url);
    var host: [512]u8 = undefined;
    if (c.zc_url_host(url, &host, host.len) == 0) {
        a.free(url);
        return null;
    }
    return .{ .url = url, .hostname = try a.dupe(u8, std.mem.sliceTo(&host, 0)) };
}
/// Prefer a safe original URL. The caller owns both strings when a target exists.
pub fn target(a: std.mem.Allocator, card: t.LinkPreview) std.mem.Allocator.Error!?Target {
    if (card.original_url) |url| if (try parse(a, url)) |result| return result;
    return parse(a, card.metadata_url orelse "");
}
pub fn open(value: Target) bool {
    return url_policy.safe(value.url) and c.zc_url_open(value.url) != 0;
}
/// The caller owns the returned slice and both strings in each target.
/// Allocation failure releases every partial target.
pub fn inText(a: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const Target {
    var result: std.ArrayList(Target) = .empty;
    errdefer {
        for (result.items) |item| {
            a.free(item.url);
            a.free(item.hostname);
        }
        result.deinit(a);
    }
    // Attachment anchors delimit links; they are neither URL characters nor
    // a reason to join the text on either side into a different destination.
    var spans = std.mem.splitSequence(u8, value, display.object_marker);
    while (spans.next()) |span| {
        var words = std.mem.tokenizeAny(u8, span, " \r\n\t<>\"");
        while (words.next()) |word| {
            if (result.items.len == 32) return result.toOwnedSlice(a);
            const trimmed = if (word.len > 2 and word[0] == '(' and word[word.len - 1] == ')') word[1 .. word.len - 1] else word;
            if (try parse(a, trimmed)) |link| {
                errdefer a.free(link.url);
                errdefer a.free(link.hostname);
                try result.append(a, link);
            }
        }
    }
    return result.toOwnedSlice(a);
}
test "links choose the original destination and reject unsafe activation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const card = t.LinkPreview{
        .id = "p",
        .part_id = "p",
        .original_url = "https://original.example/path",
        .metadata_url = "https://other.example/",
    };
    try std.testing.expectEqualStrings("original.example", (try target(a, card)).?.hostname);
    for ([_][]const u8{
        "file:///tmp/a",
        "javascript:alert(1)",
        "https://user@host.example/",
        "https://host.example\\@evil.example/",
        "https:///",
        "https://host.example/\narg",
        "https://host.example/\x00tail",
        "https://%65xample.invalid/",
        "https://host.example/\u{202e}txt",
        "https://host.example/\xff",
    }) |url| try std.testing.expect((try parse(a, url)) == null);
    try std.testing.expectEqual(
        @as(usize, 2),
        (try inText(a, "First https://one.example/ and https://two.example/.")).len,
    );
    try std.testing.expectEqualStrings(
        "https://one.example/path(a)!",
        (try inText(a, "https://one.example/path(a)!"))[0].url,
    );
    const attached = try inText(
        a,
        "\u{fffc}https://one.example/👋\u{fffc}https://two.example/\u{fffc}",
    );
    try std.testing.expectEqual(@as(usize, 2), attached.len);
    try std.testing.expectEqualStrings("https://one.example/👋", attached[0].url);
    try std.testing.expectEqualStrings("https://two.example/", attached[1].url);
}

fn checkLinkAllocationFailures(a: std.mem.Allocator) !void {
    const targets = try inText(a, "https://example.invalid/path");
    defer {
        for (targets) |item| {
            a.free(item.url);
            a.free(item.hostname);
        }
        a.free(targets);
    }
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("example.invalid", targets[0].hostname);
}

test "link extraction preserves allocation errors and releases partial targets" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLinkAllocationFailures,
        .{},
    );
}
