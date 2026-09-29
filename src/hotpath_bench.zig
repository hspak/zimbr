//! Synthetic CPU and cache-maintenance hot paths, with no network or display.
const std = @import("std");
const u = @import("common.zig");
const Db = @import("relay.zig").Sqlite;
const Journal = @import("relay.zig").Journal;
const t = @import("protocol.zig").types;
const json_bounds = @import("protocol.zig").json;
const c = @import("client.zig").c.api;
const Media = @import("client.zig").Media;
const Store = @import("client.zig").Store;
const Sse = @import("client.zig").Sse;
// Match the storage benchmark's sample count for comparable median and upper-tail summaries.
const samples = 15;
const Timing = struct { p50_us: f64, p95_us: f64 };

fn clock() f64 {
    var ts: u.c.struct_timespec = undefined;
    _ = u.c.clock_gettime(u.c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) * 1_000_000 + @as(f64, @floatFromInt(ts.tv_nsec)) / 1000;
}
fn stats(values: *[samples]f64) Timing {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return .{ .p50_us = values[samples / 2], .p95_us = values[samples - 1] };
}
fn accept(store: Store, a: u.Allocator, raw: []const u8, id: []const u8, kind: []const u8) !void {
    try store.event(a, raw, id, kind, "");
}

fn diskMaintenance(initial_entries: usize) !struct {
    initial_entries: usize,
    file_bytes: usize,
    measured_downloads: usize,
    startup_us: f64,
    mean_us: f64,
    batch: Timing,
} {
    // 64 KiB sparse files model moderate encoded images without timing payload writes.
    const file_bytes = 64 * 1024;
    // Average 64 installations per sample to reduce timer noise in cache maintenance.
    const batch_size = 64;
    const total_files = initial_entries + (samples + 1) * batch_size;
    var path = "/tmp/zimbr-cache-bench-XXXXXX".*;
    if (u.c.mkdtemp(&path) == null) return error.TemporaryDirectoryUnavailable;
    defer _ = u.c.rmdir(&path);
    const dir = c.zc_cache_open(&path);
    if (dir < 0) return error.CacheUnavailable;
    defer _ = u.c.close(dir);
    defer for (0..total_files) |i| {
        // Use production-shaped 64-character cache keys plus NUL.
        var key: [65]u8 = undefined;
        const name = std.fmt.bufPrintZ(&key, "{x:0>64}", .{i}) catch unreachable;
        c.zc_cache_remove(dir, name);
    };
    for (0..initial_entries) |i| try cacheFile(dir, i, file_bytes);
    // Keep the fixture runnable in the saved baseline, whose worker pruned on
    // every installation. Both branches call that revision's production path.
    const Cache = if (@hasDecl(Media, "DiskCache")) Media.DiskCache else struct {};
    const started = clock();
    var cache = if (@hasDecl(Media, "DiskCache")) Cache.init(dir, .{
        .bytes = Media.disk_budget - 16 * 1024 * 1024,
        .trim_bytes = Media.disk_budget - 64 * 1024 * 1024,
        .entries = 8192,
        .trim_entries = 7680,
    }) else Cache{};
    if (!@hasDecl(Media, "DiskCache")) c.zc_cache_prune(dir, Media.disk_budget - 16 * 1024 * 1024);
    const startup_us = clock() - started;
    var timings: [samples]f64 = undefined;
    var elapsed: f64 = 0;
    for (0..samples + 1) |sample| {
        var batch_us: f64 = 0;
        for (0..batch_size) |i| {
            try cacheFile(dir, initial_entries + sample * batch_size + i, file_bytes);
            const before = clock();
            if (@hasDecl(Media, "DiskCache")) {
                cache.downloaded(file_bytes);
            } else {
                c.zc_cache_prune(dir, Media.disk_budget - 16 * 1024 * 1024);
            }
            std.mem.doNotOptimizeAway(&cache);
            batch_us += clock() - before;
        }
        if (sample > 0) {
            timings[sample - 1] = batch_us / batch_size;
            elapsed += batch_us;
        }
    }
    if (@hasDecl(Media, "DiskCache")) {
        const usage = cache.usage orelse return error.CacheMaintenanceFailed;
        if (usage.bytes > cache.limits.bytes or usage.entries > cache.limits.entries)
            return error.CacheMaintenanceFailed;
    }
    return .{
        .initial_entries = initial_entries,
        .file_bytes = file_bytes,
        .measured_downloads = samples * batch_size,
        .startup_us = startup_us,
        .mean_us = elapsed / (samples * batch_size),
        .batch = stats(&timings),
    };
}

fn cacheFile(dir: c_int, index: usize, bytes: usize) !void {
    // Use production-shaped 64-character cache keys plus NUL.
    var key: [65]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&key, "{x:0>64}", .{index});
    const fd = u.c.openat(dir, name, @as(c_int, u.c.O_WRONLY | u.c.O_CREAT | u.c.O_EXCL | u.c.O_NOFOLLOW), @as(c_uint, 0o600));
    if (fd < 0) return error.CacheFileUnavailable;
    defer _ = u.c.close(fd);
    // Sparse files model encoded sizes; payload writes, decoding and fsync are
    // outside this maintenance-only measurement.
    if (u.c.ftruncate(fd, @intCast(bytes)) != 0) return error.CacheFileUnavailable;
}

pub fn main(init: std.process.Init) !void {
    const db = try Db.open(":memory:", false);
    defer db.close();
    try db.exec("CREATE TABLE bench(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO bench VALUES(1,'synthetic')");
    // Exercise JSON checking at the 64 KiB request-body limit.
    const bytes = try init.arena.allocator().alloc(u8, 65536);
    @memset(bytes, 'a');
    bytes[0] = '"';
    bytes[bytes.len - 1] = '"';
    // Repeat mixed Unicode across six lines to exercise shaping, fallback, and rasterization.
    const body = "Opaque text, é 👩‍💻 and Unicode fallback.\n" ** 6;
    const layout = c.zc_text_new_with_options(body.ptr, body.len, 16, 480, 1.25, 0, 1) orelse return error.LayoutFailed;
    defer c.zc_text_free(layout);
    const height = @min(2048, c.zc_text_height(layout));
    var sql: [samples]f64 = undefined;
    var client_sql: [samples]f64 = undefined;
    var json: [samples]f64 = undefined;
    var raster: [samples]f64 = undefined;
    var media_queue: [samples]f64 = undefined;
    var history_page: [samples]f64 = undefined;
    var relay_events: [samples]f64 = undefined;
    var client_events: [samples]f64 = undefined;
    var media = Media{ .io = init.io, .config = .{ .data = "" } };
    defer media.shutdown();
    // Fill the media request queue to its 128-entry production bound.
    var asset_ids: [128][t.id_length]u8 = undefined;
    for (&asset_ids, 0..) |*id, i| {
        // Encode the counter as a full 128-bit UUID-shaped ID for production key paths.
        var id_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &id_bytes, i, .big);
        id.* = u.encodeId(id_bytes);
    }
    const journal = try Journal.open(":memory:");
    defer journal.close();
    const fixture = init.arena.allocator();
    const chat = try journal.conversation(fixture, "bench", 1, "route", .{ .service = "imessage" }, "historical_import");
    for (&asset_ids, 0..) |*id, i| try journal.message(fixture, id, @intCast(i + 1), @intCast(i), t.Message{
        .conversation_id = chat,
        .sender = "fixture@example.invalid",
        .service = "imessage",
        .direction = .incoming,
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = "x" ** 1024,
        .decoding = .plain,
        .observed_status = .received,
    }, "historical_import");
    // Exercise the live path, including cache writes, previews and unread markers.
    try journal.db.exec("UPDATE events SET origin='live'");
    const frames = try journal.events(fixture, 0);
    const epoch = try journal.epoch(fixture);
    const cursor = try t.cursor(fixture, epoch, 0);
    const store = try Store.open(":memory:");
    defer store.close();
    try store.db.exec("CREATE TABLE bench(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO bench VALUES(1,'synthetic')");
    // One discarded warm-up batch, then amortize the timer over many calls.
    for (0..samples + 1) |sample| {
        var started = clock();
        for (0..10000) |_| {
            const query = try db.prepare("SELECT value FROM bench WHERE id=?");
            defer query.close();
            try query.bind(&.{.{ .int = 1 }});
            if (!try query.step() or !u.eq(query.bytes(0), "synthetic")) return error.IncorrectQuery;
        }
        const sql_us = (clock() - started) / 10000;
        started = clock();
        for (0..10000) |_| {
            const query = try store.db.prepare("SELECT value FROM bench WHERE id=?");
            defer query.close();
            try query.bind(&.{.{ .int = 1 }});
            if (!try query.step() or !u.eq(query.bytes(0), "synthetic")) return error.IncorrectQuery;
        }
        const client_sql_us = (clock() - started) / 10000;
        started = clock();
        for (0..500) |i| {
            bytes[1] = @as(u8, @intCast(i % 26)) + 'a';
            try json_bounds.check(bytes, bytes.len, 32);
        }
        const json_us = (clock() - started) / 500;
        started = clock();
        for (0..100) |_| {
            if (c.zc_text_pixels_on(layout, 0xffffffff, 0, 0, 0, height, 0x202020ff) == null) return error.RasterFailed;
            c.zc_text_clear_pixels(layout);
        }
        const raster_us = (clock() - started) / 100;
        started = clock();
        for (0..32) |batch| {
            _ = try media.context("epoch", if (batch % 2 == 0) "one" else "two", 0, false, true);
            for (&asset_ids) |*id| try media.request(.{
                .id = id,
                .version = "EjRWeBI0EjQSNBI0VniQEg",
                .variant = .inline_image,
                .availability = .ready,
                .mime_type = "image/png",
                .bytes = "65536",
                .width = 256,
                .height = 256,
            });
            if (media.queue.items.len != asset_ids.len) return error.IncorrectQueueLength;
        }
        const media_queue_us = (clock() - started) / (32 * asset_ids.len);
        started = clock();
        for (0..20) |_| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const page = try journal.page(arena.allocator(), chat, null, asset_ids.len);
            if (page.records.len != asset_ids.len or page.next != null) return error.IncorrectHistoryPage;
            const response = try u.json(arena.allocator(), .{ .messages = page.records, .next = page.next });
            std.mem.doNotOptimizeAway(response);
        }
        const history_page_us = (clock() - started) / 20;
        started = clock();
        for (0..20) |_| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const batch = try journal.events(arena.allocator(), 0);
            if (batch.len != frames.len) return error.IncorrectEventBatch;
            std.mem.doNotOptimizeAway(batch);
        }
        const relay_events_us = (clock() - started) / 20;
        var client_events_us: f64 = 0;
        for (0..10) |_| {
            try store.beginSync(epoch, cursor);
            var stream: Sse = .{};
            defer stream.deinit();
            started = clock();
            try store.db.exec("BEGIN IMMEDIATE");
            for (frames) |frame| try stream.feed(accept, store, frame.frame);
            try store.db.exec("COMMIT");
            client_events_us += clock() - started;
            if (try store.db.scalar("SELECT count(*) FROM records WHERE kind='message'") != frames.len - 2)
                return error.IncorrectEventRecords;
        }
        client_events_us /= 10;
        if (sample > 0) {
            sql[sample - 1] = sql_us;
            client_sql[sample - 1] = client_sql_us;
            json[sample - 1] = json_us;
            raster[sample - 1] = raster_us;
            media_queue[sample - 1] = media_queue_us;
            history_page[sample - 1] = history_page_us;
            relay_events[sample - 1] = relay_events_us;
            client_events[sample - 1] = client_events_us;
        }
    }
    const cache_below_budget = try diskMaintenance(4096);
    const cache_near_budget = try diskMaintenance(7936);
    const result = try u.json(init.arena.allocator(), .{
        .samples = samples,
        .json_bytes = bytes.len,
        .sql_lookup = stats(&sql),
        .client_sql_lookup = stats(&client_sql),
        .json_check = stats(&json),
        .opaque_text_raster = stats(&raster),
        .media_enqueue = stats(&media_queue),
        .media_request_bytes = @sizeOf(@TypeOf(media.queue.items[0].*)),
        .relay_history_page = stats(&history_page),
        .event_batch_records = frames.len,
        .relay_event_batch = stats(&relay_events),
        .client_event_batch = stats(&client_events),
        .cache_below_budget = cache_below_budget,
        .cache_near_budget = cache_near_budget,
    });
    _ = u.c.write(1, result.ptr, result.len);
    _ = u.c.write(1, "\n", 1);
}
