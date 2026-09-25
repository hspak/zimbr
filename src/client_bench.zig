//! Synthetic storage/publication benchmark. No relay, account, or real cache.
const std = @import("std");
const u = @import("common.zig");
const t = @import("protocol.zig").types;
const Store = @import("client.zig").Store;
const SharedSnapshot = @import("client.zig").SharedSnapshot;
const samples = 15;

fn clock() f64 {
    var ts: u.c.struct_timespec = undefined;
    _ = u.c.clock_gettime(u.c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) * 1000 + @as(f64, @floatFromInt(ts.tv_nsec)) / 1_000_000;
}
fn record(store: Store, index: usize, revision: usize, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const message = t.Message{
        .id = try std.fmt.allocPrint(a, "m{d:0>8}", .{index}),
        .revision = try std.fmt.allocPrint(a, "{d}", .{revision}),
        .conversation_id = "bench",
        .sender = "fixture@example.invalid",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = text,
        .decoding = .plain,
        .observed_status = .received,
    };
    _ = try store.upsert(a, "message", try u.json(a, message));
}
fn stats(values: *[samples]f64) struct { p50_ms: f64, p95_ms: f64 } {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return .{ .p50_ms = values[samples / 2], .p95_ms = values[samples - 1] };
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const count = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 25000;
    const bytes = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 1024;
    if (count == 0 or count > 200000 or bytes == 0 or bytes > t.max_text) return error.InvalidFixtureSize;
    const body = try init.arena.allocator().alloc(u8, bytes);
    @memset(body, 'x');
    const store = try Store.open(":memory:");
    defer store.close();
    try store.db.exec("BEGIN");
    for (0..count) |i| try record(store, i, 1, body);
    try store.db.exec("COMMIT");
    const started = clock();
    var previous = try SharedSnapshot.create(store, "bench", 1, null);
    defer previous.release();
    const cold = clock() - started;
    var unchanged: [samples]f64 = undefined;
    var edits: [samples]f64 = undefined;
    var appends: [samples]f64 = undefined;
    for (0..samples) |i| {
        for (0..3) |scenario| {
            if (scenario == 1) try record(store, count / 2, i + 2, "Edited synthetic message 👋");
            if (scenario == 2) try record(store, count + i, 1, body);
            const begin = clock();
            const next = try SharedSnapshot.create(store, "bench", i * 3 + scenario + 2, previous);
            previous.release();
            previous = next;
            const elapsed = clock() - begin;
            switch (scenario) {
                0 => unchanged[i] = elapsed,
                1 => edits[i] = elapsed,
                2 => appends[i] = elapsed,
                else => unreachable,
            }
        }
    }
    if (previous.snapshot.messages.len != count + samples) return error.IncorrectMessageCount;
    const result = try u.json(init.arena.allocator(), .{
        .messages = count,
        .text_bytes = bytes,
        .samples = samples,
        .cold_ms = cold,
        .unchanged = stats(&unchanged),
        .edit = stats(&edits),
        .append = stats(&appends),
    });
    _ = u.c.write(1, result.ptr, result.len);
    _ = u.c.write(1, "\n", 1);
}
