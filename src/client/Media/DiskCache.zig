//! Amortized disk maintenance for the media worker, the cache's sole writer.
const std = @import("std");
const u = @import("../../common.zig");
const c = @import("../c.zig").api;
const DiskCache = @This();

dir: c_int,
limits: Limits,
usage: ?c.ZcCacheUsage,

pub const Limits = struct {
    bytes: usize,
    trim_bytes: usize,
    entries: usize,
    trim_entries: usize,
};

/// Borrow dir until the owner closes it. Assume no downloads have started and
/// no other process writes this directory; all temporary files are orphans.
pub fn init(dir: c_int, limits: Limits) DiskCache {
    std.debug.assert(limits.trim_bytes < limits.bytes);
    std.debug.assert(limits.trim_entries < limits.entries and limits.entries <= 8192);
    var cache: DiskCache = .{ .dir = dir, .limits = limits, .usage = null };
    cache.trim(true);
    return cache;
}

/// Account for a completed download, including an installation that failed its
/// final fsync. Assume bytes bounds the encoded file size. Replacements, later
/// removals and active temporaries can overcount usage until the next scan.
pub fn downloaded(cache: *DiskCache, bytes: usize) void {
    if (cache.usage) |*usage| {
        usage.bytes +|= bytes;
        usage.entries +|= 1;
        if (usage.bytes <= cache.limits.bytes and usage.entries <= cache.limits.entries) return;
    }
    cache.trim(false);
}

fn trim(cache: *DiskCache, startup: bool) void {
    var usage: c.ZcCacheUsage = undefined;
    cache.usage = if (c.zc_cache_prune(
        cache.dir,
        cache.limits.trim_bytes,
        cache.limits.trim_entries,
        @intFromBool(startup),
        &usage,
    ) == 1) usage else null;
}

test "disk maintenance batches eviction and distinguishes orphan and active downloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/media", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path);
    const dir = c.zc_cache_open(path);
    try std.testing.expect(dir >= 0);
    defer _ = u.c.close(dir);
    const first = "1" ** 64;
    const second = "2" ** 64;
    const third = "3" ** 64;
    const fourth = "4" ** 64;
    const fifth = "5" ** 64;
    const temporary = "tmp-" ++ "a" ** 32;
    try writeFixture(dir, first, 10, 1);
    try writeFixture(dir, second, 10, 2);
    try writeFixture(dir, third, 10, 3);
    try writeFixture(dir, temporary, 7, u.c.time(null));
    var cache = DiskCache.init(dir, .{
        .bytes = 30,
        .trim_bytes = 20,
        .entries = 5,
        .trim_entries = 3,
    });
    try std.testing.expect(!exists(dir, temporary));
    try std.testing.expect(!exists(dir, first));
    try std.testing.expect(exists(dir, second) and exists(dir, third));
    try std.testing.expectEqual(@as(usize, 20), cache.usage.?.bytes);

    try writeFixture(dir, fourth, 8, 4);
    cache.downloaded(8);
    // Usage can grow above the trim target without rescanning or evicting.
    try std.testing.expectEqual(@as(usize, 28), cache.usage.?.bytes);
    try std.testing.expect(exists(dir, second));
    // Even an old active temporary belongs to this owner until it cancels it.
    try writeFixture(dir, temporary, 3, 1);
    c.zc_cache_remove(dir, second);
    try writeFixture(dir, fifth, 10, 5);
    cache.downloaded(10);
    try std.testing.expect(exists(dir, temporary) and exists(dir, fifth));
    try std.testing.expect(!exists(dir, third) and !exists(dir, fourth));
    try std.testing.expectEqual(@as(usize, 13), cache.usage.?.bytes);
    try std.testing.expectEqual(@as(usize, 1), cache.usage.?.entries);

    // Replacing an entry overcounts until trimming; it never creates free space.
    try writeFixture(dir, fifth, 10, 6);
    cache.downloaded(10);
    try std.testing.expectEqual(@as(usize, 23), cache.usage.?.bytes);
    try std.testing.expectEqual(@as(usize, 2), cache.usage.?.entries);
    const restarted = DiskCache.init(dir, cache.limits);
    try std.testing.expect(!exists(dir, temporary) and exists(dir, fifth));
    try std.testing.expectEqual(@as(usize, 10), restarted.usage.?.bytes);
    try std.testing.expectEqual(@as(usize, 1), restarted.usage.?.entries);
}

test "disk maintenance caps small file counts and retries failed scans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/media", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path);
    const dir = c.zc_cache_open(path);
    try std.testing.expect(dir >= 0);
    defer _ = u.c.close(dir);
    var cache = DiskCache.init(-1, .{
        .bytes = 100,
        .trim_bytes = 80,
        .entries = 4,
        .trim_entries = 2,
    });
    try std.testing.expect(cache.usage == null);
    cache.downloaded(1);
    try std.testing.expect(cache.usage == null);
    cache.dir = dir;
    const first = "1" ** 64;
    try writeFixture(dir, first, 1, 1);
    cache.downloaded(1);
    try std.testing.expectEqual(@as(usize, 1), cache.usage.?.entries);
    for (2..5) |i| {
        var key: [65]u8 = undefined;
        try writeFixture(dir, try std.fmt.bufPrintZ(&key, "{d:0>64}", .{i}), 1, @intCast(i));
        cache.downloaded(1);
    }
    try std.testing.expectEqual(@as(usize, 4), cache.usage.?.entries);
    try std.testing.expect(exists(dir, first));
    const newest = "5" ** 64;
    try writeFixture(dir, newest, 1, 5);
    cache.downloaded(1);
    try std.testing.expect(!exists(dir, first) and exists(dir, newest));
    try std.testing.expectEqual(@as(usize, 2), cache.usage.?.entries);
    try std.testing.expectEqual(@as(usize, 2), cache.usage.?.bytes);
}

test "disk scan bounds its entry storage for an oversized directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/media", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path);
    const dir = c.zc_cache_open(path);
    try std.testing.expect(dir >= 0);
    defer _ = u.c.close(dir);
    for (0..8200) |i| {
        var key: [65]u8 = undefined;
        try writeFixture(dir, try std.fmt.bufPrintZ(&key, "{x:0>64}", .{i}), 1, @intCast(i));
    }
    const cache = DiskCache.init(dir, .{
        .bytes = 10000,
        .trim_bytes = 9000,
        .entries = 8192,
        .trim_entries = 7680,
    });
    try std.testing.expectEqual(@as(usize, 7680), cache.usage.?.entries);
    try std.testing.expectEqual(@as(usize, 7680), cache.usage.?.bytes);
    var remaining: usize = 0;
    for (0..8200) |i| {
        var key: [65]u8 = undefined;
        if (exists(dir, try std.fmt.bufPrintZ(&key, "{x:0>64}", .{i}))) remaining += 1;
    }
    try std.testing.expectEqual(@as(usize, 7680), remaining);
}

fn writeFixture(dir: c_int, name: [:0]const u8, bytes: usize, modified: i64) !void {
    const fd = u.c.openat(dir, name, @as(c_int, u.c.O_WRONLY | u.c.O_CREAT | u.c.O_TRUNC | u.c.O_NOFOLLOW), @as(c_uint, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = u.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), u.c.ftruncate(fd, @intCast(bytes)));
    const times = [2]u.c.timespec{ .{ .tv_sec = modified, .tv_nsec = 0 }, .{ .tv_sec = modified, .tv_nsec = 0 } };
    try std.testing.expectEqual(@as(c_int, 0), u.c.futimens(fd, &times));
}

fn exists(dir: c_int, name: [:0]const u8) bool {
    return u.c.faccessat(dir, name, u.c.F_OK, u.c.AT_SYMLINK_NOFOLLOW) == 0;
}
