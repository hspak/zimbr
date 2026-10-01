//! Independent authenticated media lane. Only this worker touches downloads and
//! decoding; the GUI receives at most one bounded decoded image at a time.
const std = @import("std");
const builtin = @import("builtin");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const attachments = @import("../protocol.zig").attachments;
const c = @import("c.zig").api;
const Config = @import("Config.zig");
pub const Key = @import("Media/Key.zig");
pub const DiskCache = @import("Media/DiskCache.zig");
const Media = @This();
const a = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;
const log = std.log.scoped(.client_media);
const asset_path_capacity = capacity: {
    var variant_length: usize = 0;
    for (std.meta.fieldNames(@FieldType(t.AssetRef, "variant"))) |name|
        variant_length = @max(variant_length, name.len);
    break :capacity "/v1/assets///".len + 2 * t.id_length + variant_length + 1;
};
// 512 MiB retains recently viewed media without allowing unlimited cache growth.
pub const disk_budget = 512 * 1024 * 1024;
// 64 MiB bounds GPU image storage separately from compressed files on disk.
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
// A full SHA-256 trust-root digest isolates cached media between credential contexts.
ca_digest: [32]u8 = @splat(0),
online: bool = false,
avatars: bool = true,
evict_avatars: bool = false,
dir: c_int = -1,

pub const Result = struct {
    key: Key,
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
    // Bound copied display diagnostics to 128 bytes while preserving C string termination.
    reason: [128:0]u8 = @splat(0),
    pub fn destroy(r: *Result) void {
        c.zc_pixels_free(&r.pixels);
        a.destroy(r);
    }
};
const Request = struct {
    id: [t.id_length]u8,
    version: [t.id_length]u8,
    variant: @FieldType(t.AssetRef, "variant"),
    retired: bool,
    expected_bytes: usize,
    key: Key,
    generation: u64,
    wanted_at: i64,
    local: bool = false,
    fd: c_int = -1,
    // The native tmp- plus 32-hex-digit name fits within the cache-key-sized storage.
    temporary: [64:0]u8 = @splat(0),
    fn destroy(r: *Request, dir: c_int) void {
        if (r.fd >= 0) _ = u.c.close(r.fd);
        if (r.temporary[0] != 0) c.zc_cache_remove(dir, &r.temporary);
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
    log.debug("Image context changed: epoch={}, conversation={}, credentials={}, online={}, avatars={}", .{
        !u.eq(epoch, s.epoch),
        !u.eq(chat, s.chat),
        credentials != s.credential_generation,
        online,
        avatars,
    });
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
pub fn key(s: *Media, asset: t.AssetRef) Key {
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
    // SHA-256 output is 32 bytes, rendered as two hex digits per byte.
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .init(digest, switch (asset.variant) {
        .avatar => .avatar,
        .inline_image => .inline_image,
        .viewer => .viewer,
    });
}
pub const RequestError = u.Allocator.Error || error{InvalidAssetReference};
pub const LocalRequestError = u.Allocator.Error || attachments.ValidateError;

/// Local preview identity includes the private storage root and immutable bytes.
pub fn localKey(s: *Media, file: attachments.Upload) Key {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{
        s.config.data,
        file.id,
        file.sha256,
    }) |part| {
        hash.update(part);
        hash.update(&.{0});
    }
    // SHA-256 output is 32 bytes, rendered as two hex digits per byte.
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .init(digest, .local);
}

/// Queue a bounded preview of a staged original, including while offline.
/// The caller retains all metadata strings; decoding runs on the media worker.
pub fn requestLocal(s: *Media, file: attachments.Upload) LocalRequestError!void {
    const bytes = try attachments.validate(file);
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    try s.enqueue(.{
        .id = file.id[0..t.id_length].*,
        .version = @splat(0),
        .variant = .inline_image,
        .retired = false,
        .expected_bytes = @intCast(bytes),
        .key = s.localKey(file),
        .generation = s.generation,
        .wanted_at = u.now(),
        .local = true,
    });
}

/// Copy the download fields into the bounded queue. Asset IDs and versions must
/// be canonical Base64url UUIDs; the caller retains ownership of all asset strings.
pub fn request(s: *Media, asset: t.AssetRef) RequestError!void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.epoch.len == 0 or (!s.avatars and asset.variant == .avatar)) return;
    if (!t.validId(asset.id) or !t.validId(asset.version)) return error.InvalidAssetReference;
    try s.enqueue(.{
        .id = asset.id[0..t.id_length].*,
        .version = asset.version[0..t.id_length].*,
        .variant = asset.variant,
        .retired = asset.availability == .retired,
        .expected_bytes = if (asset.bytes) |bytes| std.fmt.parseInt(usize, bytes, 10) catch 0 else 0,
        .key = s.key(asset),
        .generation = s.generation,
        .wanted_at = u.now(),
    });
}

// The caller holds the queue mutex; requests copy only fixed-size metadata.
fn enqueue(s: *Media, request_value: Request) u.Allocator.Error!void {
    const cache_key = request_value.key;
    for (s.active) |active| if (active) |r| if (r.generation == s.generation and r.key.eql(cache_key)) {
        r.wanted_at = u.now();
        return;
    };
    for (s.queue.items) |r| if (r.key.eql(cache_key)) {
        r.wanted_at = u.now();
        return;
    };
    if (s.result) |r| if (r.generation == s.generation and r.key.eql(cache_key)) return;
    // 128 queued requests absorbs visible-row bursts while bounding stale offscreen work.
    if (s.queue.items.len >= 128) return;
    const r = try a.create(Request);
    errdefer a.destroy(r);
    r.* = request_value;
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

/// Snapshot of work for the current GUI context; stale generations are excluded.
pub fn syncing(s: *Media) bool {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (!s.online or s.stop.load(.acquire)) return false;
    if (s.queue.items.len > 0) return true;
    for (s.active) |active| if (active) |request_value| {
        if (request_value.generation == s.generation) return true;
    };
    return false;
}
pub fn release(s: *Media, result: *Result) void {
    result.destroy();
    s.mutex.lockUncancelable(s.io);
    s.delivering = false;
    s.mutex.unlock(s.io);
    s.wake();
}
fn deliver(s: *Media, request_value: *Request, result: *Result, lane: usize) void {
    if (result.state != .ready) log.debug("Image {s}: {s} ({s})", .{
        result.key.hex(),
        @tagName(result.state),
        std.mem.sliceTo(&result.reason, 0),
    });
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
    defer s.stop.store(true, .release);
    s.work() catch |err| log.err("Image worker stopped: {s}", .{@errorName(err)});
}
fn work(s: *Media) !void {
    var net: ?*c.ZcNet = null;
    defer if (net) |n| c.zc_net_free(n);
    var net_generation: u64 = 0;
    defer {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (&s.active) |*active| if (active.*) |r| {
            r.destroy(s.dir);
            active.* = null;
        };
    }
    // Leave room for both 8 MiB download lanes and trim in batches near the cap.
    var disk = DiskCache.init(s.dir, .{
        // Reserve 16 MiB below the disk cap for in-flight downloads.
        .bytes = disk_budget - 16 * 1024 * 1024,
        // Reclaim 64 MiB of headroom per trim to avoid pruning after every download.
        .trim_bytes = disk_budget - 64 * 1024 * 1024,
        // Bound directory scans even when many cached images are tiny.
        .entries = 8192,
        // Remove 512 entries per full-directory trim to give the cache growth headroom.
        .trim_entries = 7680,
    });
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
                log.debug("Image {s}: transfer cancelled after context change", .{r.key.hex()});
                r.destroy(s.dir);
                active.* = null;
            };
            net_generation = generation;
        }
        for (&s.active, 0..) |*active, lane| if (active.*) |r| {
            // Drop media no longer requested for two seconds so scrolling reprioritizes downloads.
            if (u.now() - r.wanted_at > 2000) {
                log.debug("Image {s}: transfer cancelled after leaving view", .{r.key.hex()});
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
                    if (failure.curl_code == 0) {
                        log.debug("Image {s}: download response HTTP {d}", .{ r.key.hex(), status });
                    } else {
                        log.debug("Image {s}: download response HTTP {d}, curl {d}", .{
                            r.key.hex(),
                            status,
                            failure.curl_code,
                        });
                    }
                    if (failure.curl_code == 0 and status == 200) {
                        const installed = if (c.zc_image_read(s.dir, &r.temporary, &result.pixels) == 1) installed: {
                            const ok = c.zc_cache_install(s.dir, &r.temporary, &r.key.hex(), r.fd) == 1;
                            // The transport verified the declared length, or enforced 8 MiB
                            // when no length was advertised. Count even a late fsync failure.
                            disk.downloaded(if (r.expected_bytes != 0) r.expected_bytes else 8 * 1024 * 1024);
                            break :installed ok;
                        } else false;
                        if (installed) {
                            result.state = .ready;
                            log.debug("Image {s}: download saved to disk cache", .{r.key.hex()});
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
                                        // Keep server-directed retries between two and 30 seconds
                                        // to avoid spins or long stalls.
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
                        // Give transient network/service failures five seconds to recover.
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
                if (r.local) {
                    s.localPreview(r, result);
                    s.deliver(r, result, lane);
                    break;
                }
                if (r.retired) {
                    result.state = .retired;
                    setReason(result, "Photo changed · refreshing message");
                    c.zc_cache_remove(s.dir, &r.key.hex());
                    s.deliver(r, result, lane);
                    break;
                }
                const cached = c.zc_image_read(s.dir, &r.key.hex(), &result.pixels);
                if (cached == 1) {
                    log.debug("Image {s}: disk cache hit ({s})", .{ r.key.hex(), @tagName(r.variant) });
                    result.state = .ready;
                    s.deliver(r, result, lane);
                    break;
                }
                if (cached < 0) {
                    log.debug("Image {s}: disk cache file rejected; removing", .{r.key.hex()});
                    c.zc_cache_remove(s.dir, &r.key.hex());
                } else log.debug("Image {s}: disk cache miss ({s})", .{ r.key.hex(), @tagName(r.variant) });
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
                var path_buffer: [asset_path_capacity]u8 = undefined;
                const path = std.fmt.bufPrintZ(&path_buffer, "/v1/assets/{s}/{s}/{s}", .{
                    r.id,
                    r.version,
                    @tagName(r.variant),
                }) catch unreachable; // UUIDs are validated before enqueueing.
                if (r.fd < 0 or c.zc_net_start_file(net.?, @intCast(lane), path, r.fd, r.expected_bytes) == 0) {
                    s.deliver(r, result, lane);
                    break;
                }
                log.debug("Image {s}: downloading {s} version {s} ({s})", .{
                    r.key.hex(),
                    r.id,
                    r.version,
                    @tagName(r.variant),
                });
                result.destroy();
            }
        }
        // Recheck download demand every 50 ms while still responding immediately to wakeups.
        _ = c.zc_net_wait(net, s.wake_pipe[0], 50);
    }
}
fn localPreview(s: *Media, request_value: *Request, result: *Result) void {
    setReason(result, "No local preview");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "{s}/outgoing", .{s.config.data}) catch return;
    const directory = u.c.open(path, u.c.O_RDONLY | u.c.O_DIRECTORY | u.c.O_NOFOLLOW | u.c.O_CLOEXEC);
    if (directory < 0) return;
    defer _ = u.c.close(directory);
    var id: [t.id_length:0]u8 = undefined;
    @memcpy(id[0..t.id_length], &request_value.id);
    id[t.id_length] = 0;
    const fd = c.zc_outgoing_open(directory, &id, request_value.expected_bytes);
    if (fd < 0) return;
    defer _ = u.c.close(fd);
    if (c.zc_image_read_fd(fd, &result.pixels) == 1) result.state = .ready;
}

fn setReason(result: *Result, reason: []const u8) void {
    @memset(&result.reason, 0);
    const length = @min(reason.len, result.reason.len);
    @memcpy(result.reason[0..length], reason[0..length]);
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
    // The native tmp- plus 32-hex-digit name fits within the cache-key-sized storage.
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
    // Original previews borrow descriptors, including ones positioned at EOF.
    var before: c.ZcOutgoingFingerprint = undefined;
    try std.testing.expectEqual(@as(c_int, 1), c.zc_outgoing_fingerprint(fd, &before));
    try std.testing.expectEqual(@as(c_int, 1), c.zc_image_read_fd(fd, &pixels));
    c.zc_pixels_free(&pixels);
    try std.testing.expectEqual(@as(i64, png.len), u.c.lseek(fd, 0, u.c.SEEK_CUR));
    var after: c.ZcOutgoingFingerprint = undefined;
    try std.testing.expectEqual(@as(c_int, 1), c.zc_outgoing_fingerprint(fd, &after));
    try std.testing.expectEqualDeep(before, after);
    const key_value = "b" ** 64;
    try std.testing.expectEqual(@as(c_int, 1), c.zc_cache_install(dir, &temporary, key_value, fd));
    try std.testing.expectEqual(@as(c_int, 0), c.zc_image_read(dir, &temporary, &pixels));
    try std.testing.expectEqual(@as(c_int, 1), c.zc_image_read(dir, key_value, &pixels));
    c.zc_pixels_free(&pixels);
    try std.testing.expectEqual(@as(c_int, -1), c.zc_image_read(dir, "../escape", &pixels));
    c.zc_cache_clear_avatars(dir);
    try std.testing.expectEqual(@as(c_int, 1), c.zc_image_read(dir, key_value, &pixels));
    c.zc_pixels_free(&pixels);
    var usage: c.ZcCacheUsage = undefined;
    try std.testing.expectEqual(@as(c_int, 1), c.zc_cache_prune(dir, 0, 8192, 0, &usage));
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

test "queued media owns only validated download fields and survives caller reuse" {
    var media = Media{ .io = std.testing.io, .config = .{ .data = "" } };
    defer media.shutdown();
    _ = try media.context("epoch", "chat", 0, false, true);
    var id = "EjRWeBI0EjQSNBI0VniQEg".*;
    var version = "q83vq6vNq82rzavN76vN7w".*;
    var asset = t.AssetRef{
        .id = &id,
        .version = &version,
        .variant = .inline_image,
        .bytes = "12345",
        .availability = .retired,
    };
    try media.request(asset);
    try media.request(asset);
    try std.testing.expectEqual(@as(usize, 1), media.queue.items.len);
    @memset(&id, 'x');
    @memset(&version, 'y');
    const queued = media.queue.items[0];
    try std.testing.expectEqualStrings("EjRWeBI0EjQSNBI0VniQEg", &queued.id);
    try std.testing.expectEqualStrings("q83vq6vNq82rzavN76vN7w", &queued.version);
    try std.testing.expectEqual(@as(usize, 12345), queued.expected_bytes);
    try std.testing.expect(queued.retired);
    try std.testing.expectError(error.InvalidAssetReference, media.request(asset));
    asset.id = &queued.id;
    try std.testing.expectError(error.InvalidAssetReference, media.request(asset));
    try std.testing.expectEqual(@as(usize, 1), media.queue.items.len);
    _ = try media.context("epoch", "other", 0, false, true);
    try std.testing.expectEqual(@as(usize, 0), media.queue.items.len);
}

test "sync activity excludes offline queues and cancelled media generations" {
    var media = Media{ .io = std.testing.io, .config = .{ .data = "" } };
    defer media.shutdown();
    const asset = t.AssetRef{
        .id = "EjRWeBI0EjQSNBI0VniQEg",
        .version = "q83vq6vNq82rzavN76vN7w",
        .variant = .inline_image,
    };
    _ = try media.context("epoch", "chat", 0, false, true);
    try media.request(asset);
    try std.testing.expect(!media.syncing());
    _ = try media.context("epoch", "chat", 0, true, true);
    try std.testing.expect(!media.syncing());
    try media.request(asset);
    try std.testing.expect(media.syncing());
    const request_value = media.queue.orderedRemove(0);
    defer request_value.destroy(media.dir);
    media.active[0] = request_value;
    defer media.active[0] = null;
    try std.testing.expect(media.syncing());
    _ = try media.context("epoch", "other", 0, true, true);
    try std.testing.expect(!media.syncing());
    try media.request(asset);
    try std.testing.expect(media.syncing());
    media.stop.store(true, .release);
    try std.testing.expect(!media.syncing());
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
    try std.testing.expect(!first.eql(media.key(asset)));
    media.epoch = "epoch-1";
    media.config.relay_url = "https://two.invalid";
    try std.testing.expect(!first.eql(media.key(asset)));
    media.config.relay_url = "https://one.invalid";
    var second = asset;
    second.version = "2";
    try std.testing.expect(!first.eql(media.key(second)));
    second = asset;
    second.variant = .avatar;
    try std.testing.expect(!first.eql(media.key(second)));
    try std.testing.expect(media.key(second).isAvatar());
}

test {
    _ = DiskCache;
}

test {
    _ = Key;
}
