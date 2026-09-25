//! Independent authenticated media lane. Only this worker touches downloads and
//! decoding; the GUI receives at most one bounded decoded image at a time.
const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const c = @import("c.zig").api;
const Config = @import("Config.zig");
const Media = @This();
const a = std.heap.c_allocator;
pub const disk_budget = 512 * 1024 * 1024;
pub const texture_budget = 64 * 1024 * 1024;

io: std.Io,
config: Config,
mutex: std.Io.Mutex = .init,
stop: std.atomic.Value(bool) = .init(false),
thread: ?std.Thread = null,
wake_pipe: [2]c_int = .{ -1, -1 },
queue: std.ArrayList(*Request) = .empty,
active: [2]?*Request = .{ null, null },
result: ?*Result = null,
on_ready: ?*const fn () callconv(.c) void = null,
delivering: bool = false,
generation: u64 = 0,
epoch: []const u8 = "",
chat: []const u8 = "",
credential_generation: u64 = 0,
ca_digest: [32]u8 = @splat(0),
online: bool = false,
avatars: bool = true,
evict_avatars: bool = false,
dir: c_int = -1,

pub const Result = struct {
    key: [64:0]u8,
    generation: u64,
    pixels: c.ZcPixels = std.mem.zeroes(c.ZcPixels),
    state: enum {
        ready,
        offline,
        pending,
        failed,
        retired,
        denied,
    } = .failed,
    retry_at: i64 = 0,
    reason: [128:0]u8 = @splat(0),
    pub fn destroy(r: *Result) void {
        c.zc_pixels_free(&r.pixels);
        a.destroy(r);
    }
};
const Request = struct {
    arena: std.heap.ArenaAllocator,
    asset: t.AssetRef,
    key: [64:0]u8,
    generation: u64,
    wanted_at: i64,
    fd: c_int = -1,
    temporary: [64:0]u8 = @splat(0),
    fn destroy(r: *Request, dir: c_int) void {
        if (r.fd >= 0) _ = u.c.close(r.fd);
        if (r.temporary[0] != 0) c.zc_cache_remove(dir, &r.temporary);
        r.arena.deinit();
        a.destroy(r);
    }
};

pub const StartError = std.Thread.SpawnError || error{
    MediaWakeUnavailable,
    PrivateMediaCacheUnavailable,
};

pub fn start(s: *Media) StartError!void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/media", .{s.config.data}, 0);
    defer a.free(path);
    s.dir = c.zc_cache_open(path);
    if (s.dir < 0) return error.PrivateMediaCacheUnavailable;
    errdefer _ = u.c.close(s.dir);
    if (u.c.pipe(&s.wake_pipe) != 0) return error.MediaWakeUnavailable;
    errdefer for (s.wake_pipe) |fd| {
        _ = u.c.close(fd);
    };
    for (s.wake_pipe) |fd| {
        _ = u.c.fcntl(fd, u.c.F_SETFL, @as(c_int, u.c.O_NONBLOCK));
        _ = u.c.fcntl(fd, u.c.F_SETFD, @as(c_int, u.c.FD_CLOEXEC));
    }
    s.thread = try std.Thread.spawn(.{}, run, .{s});
}
pub fn shutdown(s: *Media) void {
    s.stop.store(true, .release);
    s.wake();
    if (s.thread) |thread| thread.join();
    for (s.queue.items) |queued| queued.destroy(s.dir);
    s.queue.deinit(a);
    if (s.result) |result| result.destroy();
    if (s.dir >= 0) _ = u.c.close(s.dir);
    for (s.wake_pipe) |fd| if (fd >= 0) {
        _ = u.c.close(fd);
    };
    a.free(s.epoch);
    a.free(s.chat);
}
fn wake(s: *Media) void {
    if (s.wake_pipe[1] >= 0) {
        _ = u.c.write(s.wake_pipe[1], "m", 1);
    }
}
/// GUI thread only. All generations cancel old transfers and queued work.
pub fn context(
    s: *Media,
    epoch: []const u8,
    chat: []const u8,
    credentials: u64,
    online: bool,
    avatars: bool,
) u.Allocator.Error!bool {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const changed = !u.eq(epoch, s.epoch) or !u.eq(chat, s.chat) or credentials != s.credential_generation or online != s.online or avatars != s.avatars;
    if (!changed) return false;
    const next_epoch = try a.dupe(u8, epoch);
    errdefer a.free(next_epoch);
    const next_chat = try a.dupe(u8, chat);
    if (s.generation == 0 or credentials != s.credential_generation) {
        var bytes: [*c]u8 = null;
        var length: usize = 0;
        if (c.zc_private_read(s.config.ca_file, &bytes, &length) == 1) {
            defer c.zc_private_free(bytes, length);
            std.crypto.hash.sha2.Sha256.hash(bytes[0..length], &s.ca_digest, .{});
        }
    }
    a.free(s.epoch);
    a.free(s.chat);
    s.epoch = next_epoch;
    s.chat = next_chat;
    s.credential_generation = credentials;
    s.online = online;
    s.evict_avatars = s.evict_avatars or (s.avatars and !avatars);
    s.avatars = avatars;
    s.generation +%= 1;
    for (s.queue.items) |queued| queued.destroy(s.dir);
    s.queue.clearRetainingCapacity();
    if (s.result) |result| result.destroy();
    s.result = null;
    s.wake();
    return true;
}
/// Cache keys are scoped to the configured relay, CA and epoch. Variant has a
/// reserved first nibble so permission loss can evict all private avatar bytes.
pub fn key(s: *Media, asset: t.AssetRef) [64:0]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{
        s.config.relay_url,
        &s.ca_digest,
        s.epoch,
        asset.id,
        asset.version,
        @tagName(asset.variant),
    }) |part| {
        hash.update(part);
        hash.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var output: [64:0]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        output[2 * i] = hex[byte >> 4];
        output[2 * i + 1] = hex[byte & 15];
    }
    output[0] = switch (asset.variant) {
        .avatar => 'a',
        .inline_image => 'b',
        .viewer => 'c',
    };
    output[64] = 0;
    return output;
}
pub fn request(s: *Media, asset: t.AssetRef) std.json.ParseError(std.json.Scanner)!void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.epoch.len == 0 or (!s.avatars and asset.variant == .avatar)) return;
    const cache_key = s.key(asset);
    for (s.active) |active| if (active) |r| if (r.generation == s.generation and u.eq(
        &r.key,
        &cache_key,
    )) {
        r.wanted_at = u.now();
        return;
    };
    for (s.queue.items) |r| if (u.eq(&r.key, &cache_key)) {
        r.wanted_at = u.now();
        return;
    };
    if (s.result) |r| if (r.generation == s.generation and u.eq(&r.key, &cache_key)) return;
    if (s.queue.items.len >= 128) return;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = try std.json.parseFromSliceLeaky(
        t.AssetRef,
        arena.allocator(),
        try u.json(arena.allocator(), asset),
        .{},
    );
    const r = try a.create(Request);
    errdefer a.destroy(r);
    r.* = .{
        .arena = arena,
        .asset = owned,
        .key = cache_key,
        .generation = s.generation,
        .wanted_at = u.now(),
    };
    try s.queue.append(a, r);
    s.wake();
}
pub fn take(s: *Media) ?*Result {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const result = s.result;
    s.result = null;
    s.delivering = result != null;
    s.wake();
    return result;
}
pub fn release(s: *Media, result: *Result) void {
    result.destroy();
    s.mutex.lockUncancelable(s.io);
    s.delivering = false;
    s.mutex.unlock(s.io);
    s.wake();
}
fn deliver(s: *Media, request_value: *Request, result: *Result, lane: usize) void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    s.active[lane] = null;
    if (result.generation == s.generation and s.result == null) {
        s.result = result;
        if (s.on_ready) |ready| ready();
    } else result.destroy();
    request_value.destroy(s.dir);
}
fn resultFor(r: *Request, message: []const u8) !*Result {
    const result = try a.create(Result);
    result.* = .{ .key = r.key, .generation = r.generation };
    const size = @min(message.len, result.reason.len);
    @memcpy(result.reason[0..size], message[0..size]);
    return result;
}
fn run(s: *Media) void {
    s.work() catch {};
}
fn work(s: *Media) !void {
    var net: ?*c.ZcNet = null;
    defer if (net) |n| c.zc_net_free(n);
    var net_generation: u64 = 0;
    defer for (&s.active) |*active| if (active.*) |r| {
        r.destroy(s.dir);
        active.* = null;
    };
    c.zc_cache_prune(s.dir, disk_budget - 16 * 1024 * 1024);
    while (!s.stop.load(.acquire)) {
        s.mutex.lockUncancelable(s.io);
        const generation = s.generation;
        const online = s.online;
        const have_result = s.result != null or s.delivering;
        const evict = s.evict_avatars;
        s.evict_avatars = false;
        if (net_generation != generation) {
            if (net) |n| c.zc_net_free(n);
            net = null;
            for (&s.active) |*active| if (active.*) |r| {
                r.destroy(s.dir);
                active.* = null;
            };
            net_generation = generation;
        }
        for (&s.active, 0..) |*active, lane| if (active.*) |r| {
            if (u.now() - r.wanted_at > 2000) {
                if (net) |n| c.zc_net_ack(n, @intCast(lane + 2));
                r.destroy(s.dir);
                active.* = null;
            }
        };
        s.mutex.unlock(s.io);
        if (evict) c.zc_cache_clear_avatars(s.dir);
        if (net) |n| {
            _ = c.zc_net_poll(n);
        }
        if (!have_result) {
            for (0..2) |lane| {
                s.mutex.lockUncancelable(s.io);
                const active = s.active[lane];
                s.mutex.unlock(s.io);
                if (active) |r| {
                    if (net == null or c.zc_net_done(net.?, @intCast(lane + 2)) == 0) continue;
                    const result = try resultFor(r, "Image unavailable · retry");
                    var failure: c.ZcError = undefined;
                    c.zc_net_error(net.?, @intCast(lane + 2), &failure);
                    const status = c.zc_net_status(net.?, @intCast(lane + 2));
                    if (failure.curl_code == 0 and status == 200) {
                        if (c.zc_image_read(s.dir, &r.temporary, &result.pixels) == 1 and c.zc_cache_install(
                            s.dir,
                            &r.temporary,
                            &r.key,
                            r.fd,
                        ) == 1) {
                            result.state = .ready;
                            c.zc_cache_prune(s.dir, disk_budget - 16 * 1024 * 1024);
                        } else {
                            c.zc_pixels_free(&result.pixels);
                            setReason(result, "Invalid or oversized image · retry");
                        }
                    } else if (status == 410) {
                        result.state = .retired;
                        setReason(result, "Photo changed · refreshing message");
                    } else if (status == 401 or status == 403 or failure.kind == c.ZC_SERVER_TRUST or failure.kind == c.ZC_CREDENTIALS or failure.kind == c.ZC_CLIENT_REJECTED or failure.kind == c.ZC_CONFIG) {
                        result.state = .denied;
                        setReason(
                            result,
                            "Image access unavailable · Reconnect after fixing credentials",
                        );
                    } else if (status == 409) {
                        var len: usize = 0;
                        const ptr = c.zc_net_media_body(net.?, @intCast(lane), &len);
                        if (ptr != null) {
                            const parsed = std.json.parseFromSlice(struct {
                                retryable: bool = false,
                                retry_after: ?u32 = null,
                                asset: ?t.AssetRef = null,
                            }, a, ptr[0..len], .{ .ignore_unknown_fields = true }) catch null;
                            if (parsed) |data| {
                                defer data.deinit();
                                if (data.value.retryable) {
                                    result.state = .pending;
                                    result.retry_at = u.now() + @as(
                                        i64,
                                        @intCast(std.math.clamp(data.value.retry_after orelse 2, 2, 30)),
                                    ) * 1000;
                                    setReason(result, "Preparing image…");
                                }
                                if (data.value.asset) |asset| setReason(result, switch (asset.availability) {
                                    .pending => "Preparing image…",
                                    .not_local => "Not on the Mac · open Messages there, then retry",
                                    .unsupported => "Image format not supported",
                                    .oversized => "Image is too large to preview",
                                    .retired => "Photo changed · refreshing message",
                                    .ready, .unavailable => if (data.value.retryable) "Image temporarily unavailable · retrying" else "Image unavailable · retry",
                                });
                            }
                        }
                    } else if (status == 503 or status == 0 or failure.curl_code != 0 or status >= 500) {
                        result.retry_at = u.now() + 5000;
                        setReason(result, "Image transfer interrupted · retrying");
                    }
                    c.zc_net_ack(net.?, @intCast(lane + 2));
                    s.deliver(r, result, lane);
                    break;
                }
                s.mutex.lockUncancelable(s.io);
                if (generation != s.generation) {
                    s.mutex.unlock(s.io);
                    break;
                }
                const queued = if (s.queue.items.len > 0) s.queue.orderedRemove(0) else null;
                s.active[lane] = queued;
                s.mutex.unlock(s.io);
                const r = queued orelse continue;
                const result = try resultFor(r, "Image unavailable · retry");
                if (r.asset.availability == .retired) {
                    result.state = .retired;
                    setReason(result, "Photo changed · refreshing message");
                    c.zc_cache_remove(s.dir, &r.key);
                    s.deliver(r, result, lane);
                    break;
                }
                const cached = c.zc_image_read(s.dir, &r.key, &result.pixels);
                if (cached == 1) {
                    result.state = .ready;
                    s.deliver(r, result, lane);
                    break;
                }
                if (cached < 0) c.zc_cache_remove(s.dir, &r.key);
                if (!online) {
                    result.state = .offline;
                    setReason(result, "Photo not cached · reconnect to load");
                    s.deliver(r, result, lane);
                    break;
                }
                if (net == null) {
                    var failure: c.ZcError = undefined;
                    var identity: c.ZcIdentity = undefined;
                    net = c.zc_net_new(
                        s.config.relay_url,
                        s.config.ca_file,
                        s.config.client_cert_file,
                        s.config.client_key_file,
                        null,
                        null,
                        &failure,
                        &identity,
                    );
                }
                if (net == null) {
                    result.state = .denied;
                    setReason(result, "Image credentials unavailable · Reconnect");
                    s.deliver(r, result, lane);
                    break;
                }
                r.fd = c.zc_cache_temp(s.dir, &r.temporary, r.temporary.len);
                const path = try std.fmt.allocPrintSentinel(r.arena.allocator(), "/v1/assets/{s}/{s}/{s}", .{
                    try encode(r.arena.allocator(), r.asset.id),
                    try encode(r.arena.allocator(), r.asset.version),
                    @tagName(r.asset.variant),
                }, 0);
                const expected = if (r.asset.bytes) |bytes| std.fmt.parseInt(usize, bytes, 10) catch 0 else 0;
                if (r.fd < 0 or c.zc_net_start_file(net.?, @intCast(lane), path, r.fd, expected) == 0) {
                    s.deliver(r, result, lane);
                    break;
                }
                result.destroy();
            }
        }
        _ = c.zc_net_wait(net, s.wake_pipe[0], 50);
    }
}
fn setReason(result: *Result, reason: []const u8) void {
    @memset(&result.reason, 0);
    const length = @min(reason.len, result.reason.len);
    @memcpy(result.reason[0..length], reason[0..length]);
}
fn encode(ar: u.Allocator, raw: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (raw) |byte| if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
        try result.append(ar, byte);
    } else {
        try result.appendSlice(ar, &.{
            '%',
            hex[byte >> 4],
            hex[byte & 15],
        });
    };
    return result.items;
}

test "media cache validates files and pixels, installs atomically, and evicts private avatars" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ar = std.testing.allocator;
    const path = try std.fmt.allocPrintSentinel(ar, ".zig-cache/tmp/{s}/media", .{tmp.sub_path}, 0);
    defer ar.free(path);
    const dir = c.zc_cache_open(path);
    try std.testing.expect(dir >= 0);
    defer _ = u.c.close(dir);
    const png = [_]u8{
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
        8,
        6,
        0,
        0,
        0,
        31,
        21,
        196,
        137,
        0,
        0,
        0,
        11,
        73,
        68,
        65,
        84,
        120,
        156,
        99,
        96,
        0,
        2,
        0,
        0,
        5,
        0,
        1,
        122,
        94,
        171,
        63,
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130,
    };
    var temporary: [64:0]u8 = @splat(0);
    const fd = c.zc_cache_temp(dir, &temporary, temporary.len);
    try std.testing.expect(fd >= 0);
    defer _ = u.c.close(fd);
    try std.testing.expectEqual(@as(isize, png.len), u.c.write(fd, &png, png.len));
    var pixels: c.ZcPixels = undefined;
    try std.testing.expectEqual(@as(c_int, 1), c.zc_image_read(dir, &temporary, &pixels));
    try std.testing.expectEqual(@as(c_int, 1), pixels.width);
    try std.testing.expectEqual(@as(usize, 4), pixels.bytes);
    try std.testing.expectEqual(@as(u8, 0), pixels.data[3]);
    c.zc_pixels_free(&pixels);
    const key_value = "b" ** 64;
    try std.testing.expectEqual(@as(c_int, 1), c.zc_cache_install(dir, &temporary, key_value, fd));
    try std.testing.expectEqual(@as(c_int, 0), c.zc_image_read(dir, &temporary, &pixels));
    try std.testing.expectEqual(@as(c_int, 1), c.zc_image_read(dir, key_value, &pixels));
    c.zc_pixels_free(&pixels);
    try std.testing.expectEqual(@as(c_int, -1), c.zc_image_read(dir, "../escape", &pixels));
    c.zc_cache_clear_avatars(dir);
    try std.testing.expectEqual(@as(c_int, 1), c.zc_image_read(dir, key_value, &pixels));
    c.zc_pixels_free(&pixels);
    c.zc_cache_prune(dir, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.zc_image_read(dir, key_value, &pixels));
    // Oversized PNG dimensions fail before a large pixel allocation.
    var huge = png;
    std.mem.writeInt(u32, huge[16..20], 50000, .big);
    const crc = std.hash.Crc32.hash(huge[12..29]);
    std.mem.writeInt(u32, huge[29..33], crc, .big);
    const oversized = c.zc_cache_temp(dir, &temporary, temporary.len);
    try std.testing.expect(oversized >= 0);
    defer _ = u.c.close(oversized);
    try std.testing.expectEqual(@as(isize, huge.len), u.c.write(oversized, &huge, huge.len));
    try std.testing.expectEqual(@as(c_int, -1), c.zc_image_read(dir, &temporary, &pixels));
    try std.testing.expect(pixels.data == null);
    c.zc_cache_remove(dir, &temporary);
}

test "asset keys separate relay identities, epochs, versions and variants" {
    var media = Media{
        .io = std.testing.io,
        .config = .{ .data = "", .relay_url = "https://one.invalid" },
        .epoch = "epoch-1",
    };
    const asset = t.AssetRef{
        .id = "asset",
        .version = "1",
        .variant = .inline_image,
    };
    const first = media.key(asset);
    media.epoch = "epoch-2";
    try std.testing.expect(!u.eq(&first, &media.key(asset)));
    media.epoch = "epoch-1";
    media.config.relay_url = "https://two.invalid";
    try std.testing.expect(!u.eq(&first, &media.key(asset)));
    media.config.relay_url = "https://one.invalid";
    var second = asset;
    second.version = "2";
    try std.testing.expect(!u.eq(&first, &media.key(second)));
    second = asset;
    second.variant = .avatar;
    try std.testing.expect(!u.eq(&first, &media.key(second)));
    try std.testing.expectEqual(@as(u8, 'a'), media.key(second)[0]);
}
