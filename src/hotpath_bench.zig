//! Synthetic CPU hot paths, with no network, display, or persistent database.
const std = @import("std");
const u = @import("common.zig");
const Db = @import("relay/Sqlite.zig");
const Json = @import("protocol/Json.zig");
const c = @import("client/c.zig").api;
const samples = 15;

fn clock() f64 {
    var ts: u.c.struct_timespec = undefined;
    _ = u.c.clock_gettime(u.c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) * 1_000_000 + @as(f64, @floatFromInt(ts.tv_nsec)) / 1000;
}
fn stats(values: *[samples]f64) struct { p50_us: f64, p95_us: f64 } {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return .{ .p50_us = values[samples / 2], .p95_us = values[samples - 1] };
}
pub fn main(init: std.process.Init) !void {
    const db = try Db.open(":memory:", false);
    defer db.close();
    try db.exec("CREATE TABLE bench(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO bench VALUES(1,'synthetic')");
    const bytes = try init.arena.allocator().alloc(u8, 65536);
    @memset(bytes, 'a');
    bytes[0] = '"';
    bytes[bytes.len - 1] = '"';
    const body = "Opaque text, é 👩‍💻 and Unicode fallback.\n" ** 6;
    const layout = c.zc_text_new_with_options(body.ptr, body.len, 16, 480, 1.25, 0, 1) orelse return error.LayoutFailed;
    defer c.zc_text_free(layout);
    const height = @min(2048, c.zc_text_height(layout));
    var sql: [samples]f64 = undefined;
    var json: [samples]f64 = undefined;
    var raster: [samples]f64 = undefined;
    // One discarded warm-up batch, then amortize the timer over many calls.
    for (0..samples + 1) |sample| {
        var started = clock();
        for (0..10000) |_| {
            var query = try db.prepare("SELECT value FROM bench WHERE id=?");
            defer query.close();
            try query.bind(&.{.{ .int = 1 }});
            if (!try query.step() or !u.eq(query.bytes(0), "synthetic")) return error.IncorrectQuery;
        }
        const sql_us = (clock() - started) / 10000;
        started = clock();
        for (0..500) |i| {
            bytes[1] = @as(u8, @intCast(i % 26)) + 'a';
            try Json.check(bytes, bytes.len, 32);
        }
        const json_us = (clock() - started) / 500;
        started = clock();
        for (0..100) |_| {
            if (c.zc_text_pixels_on(layout, 0xffffffff, 0, 0, 0, height, 0x202020ff) == null) return error.RasterFailed;
            c.zc_text_clear_pixels(layout);
        }
        const raster_us = (clock() - started) / 100;
        if (sample > 0) {
            sql[sample - 1] = sql_us;
            json[sample - 1] = json_us;
            raster[sample - 1] = raster_us;
        }
    }
    const result = try u.json(init.arena.allocator(), .{ .samples = samples, .json_bytes = bytes.len, .sql_lookup = stats(&sql), .json_check = stats(&json), .opaque_text_raster = stats(&raster) });
    _ = u.c.write(1, result.ptr, result.len);
    _ = u.c.write(1, "\n", 1);
}
