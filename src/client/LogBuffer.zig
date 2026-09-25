//! Bounded session logs shared by background workers and the GUI. Snapshots own
//! their copies so rendering and clipboard access never hold the writer lock.
const std = @import("std");
const u = @import("../common.zig");
const LogBuffer = @This();

mutex: std.Io.Mutex = .init,
entries: [capacity]Entry = undefined,
start: usize = 0,
count: usize = 0,
serial: u64 = 0,

pub const capacity = 200;
pub const Entry = struct {
    serial: u64,
    storage: [768]u8,
    length: usize,

    pub fn text(entry: *const Entry) []const u8 {
        return entry.storage[0..entry.length];
    }
};

/// Appends without allocating; long entries end with a truncation marker.
pub fn append(
    s: *LogBuffer,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var entry: Entry = .{ .serial = 0, .storage = undefined, .length = 0 };
    const marker = " … [truncated]";
    var writer = std.Io.Writer.fixed(entry.storage[0 .. entry.storage.len - marker.len]);
    var timestamp: [22]u8 = undefined;
    writer.print("{s} {s}({s}): ", .{
        formatTimestamp(&timestamp, u.now()),
        level.asText(),
        @tagName(scope),
    }) catch unreachable;
    const truncated = if (writer.print(format, args)) false else |_| true;
    entry.length = writer.end;
    // Truncation must not leave a partial UTF-8 character in the text layout.
    while (!std.unicode.utf8ValidateSlice(entry.text()) and entry.length > 0) entry.length -= 1;
    if (truncated) {
        @memcpy(entry.storage[entry.length..][0..marker.len], marker);
        entry.length += marker.len;
    }
    for (entry.storage[0..entry.length]) |*byte| {
        if (byte.* < 32 and byte.* != '\n' and byte.* != '\t') byte.* = ' ';
    }
    s.mutex.lockUncancelable(std.Options.debug_io);
    defer s.mutex.unlock(std.Options.debug_io);
    s.serial += 1;
    entry.serial = s.serial;
    const index = (s.start + s.count) % capacity;
    s.entries[index] = entry;
    if (s.count < capacity) s.count += 1 else s.start = (s.start + 1) % capacity;
}

fn localTime(ms: i64) ?u.c.struct_tm {
    const seconds: u.c.time_t = @intCast(@divFloor(ms, 1000));
    var local: u.c.struct_tm = undefined;
    return if (u.c.localtime_r(&seconds, &local) != null) local else null;
}

fn formatTimestamp(buffer: *[22]u8, ms: i64) []const u8 {
    const local = localTime(ms) orelse return "Time unavailable";
    if (u.c.strftime(buffer, buffer.len, "%Y-%m-%d:%H:%M:%S", &local) != 19) return "Time unavailable";
    const hundredths: u8 = @intCast(@divTrunc(@mod(ms, 1000), 10));
    buffer[19] = '0' + hundredths / 10;
    buffer[20] = '0' + hundredths % 10;
    buffer[21] = 0;
    return buffer[0..21];
}

/// Formats the host's current timezone abbreviation and UTC offset into buffer.
/// Falls back to a static label if the host cannot provide the timezone.
pub fn timeZone(buffer: []u8) []const u8 {
    const local = localTime(u.now()) orelse return "Local time";
    const length = u.c.strftime(buffer.ptr, buffer.len, "%Z (%z)", &local);
    return if (length > 0) buffer[0..length] else "Local time";
}

/// The caller owns the returned entries; they remain valid after appends/clear.
pub fn snapshot(s: *LogBuffer, gpa: std.mem.Allocator) std.mem.Allocator.Error![]Entry {
    s.mutex.lockUncancelable(std.Options.debug_io);
    defer s.mutex.unlock(std.Options.debug_io);
    const entries = try gpa.alloc(Entry, s.count);
    for (entries, 0..) |*entry, i| entry.* = s.entries[(s.start + i) % capacity];
    return entries;
}

pub fn clear(s: *LogBuffer) void {
    s.mutex.lockUncancelable(std.Options.debug_io);
    defer s.mutex.unlock(std.Options.debug_io);
    s.start = 0;
    s.count = 0;
}

/// Returns caller-owned, newline-separated text with a clipboard sentinel.
pub fn copy(s: *LogBuffer, gpa: std.mem.Allocator) std.mem.Allocator.Error![:0]u8 {
    const entries = try s.snapshot(gpa);
    defer gpa.free(entries);
    var length: usize = 0;
    for (entries) |*entry| length += entry.length + 1;
    const result = try gpa.allocSentinel(u8, length, 0);
    var offset: usize = 0;
    for (entries) |*entry| {
        @memcpy(result[offset..][0..entry.length], entry.text());
        offset += entry.length;
        result[offset] = '\n';
        offset += 1;
    }
    return result;
}

test "session logs retain newest entries in order and snapshots survive clear" {
    var logs: LogBuffer = .{};
    for (0..capacity + 7) |i| logs.append(.info, .test_log, "event {d}", .{i});
    const entries = try logs.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(capacity, entries.len);
    try std.testing.expect(std.mem.endsWith(u8, entries[0].text(), "info(test_log): event 7"));
    try std.testing.expectEqual(capacity + 7, entries[capacity - 1].serial);
    logs.clear();
    logs.append(.warn, .test_log, "after clear", .{});
    const copied = try logs.copy(std.testing.allocator);
    defer std.testing.allocator.free(copied);
    try std.testing.expect(std.mem.endsWith(u8, copied, "warning(test_log): after clear\n"));
    try std.testing.expect(std.mem.indexOf(u8, copied, "event") == null);
    try std.testing.expect(std.mem.endsWith(u8, entries[0].text(), "event 7"));
}

test "session logs bound long Unicode entries and preserve multiline text" {
    var logs: LogBuffer = .{};
    logs.append(.info, .test_log, "{s}", .{"👩‍💻" ** 1000});
    logs.append(.info, .test_log, "first\nsecond\x00third", .{});
    const entries = try logs.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expect(std.unicode.utf8ValidateSlice(entries[0].text()));
    try std.testing.expect(std.mem.endsWith(u8, entries[0].text(), " … [truncated]"));
    try std.testing.expect(std.mem.endsWith(u8, entries[1].text(), "first\nsecond third"));
}

test "log timestamps use the local calendar and two fractional second digits" {
    // mktime supplies a host-local instant independently of the formatter.
    // Run in a non-UTC TZ as well to detect accidental UTC formatting.
    var local = std.mem.zeroes(u.c.struct_tm);
    local.tm_year = 2026 - 1900;
    local.tm_mon = 0;
    local.tm_mday = 1;
    local.tm_isdst = -1;
    const seconds = u.c.mktime(&local);
    try std.testing.expect(seconds != -1);
    var buffer: [22]u8 = undefined;
    try std.testing.expectEqualStrings("2026-01-01:00:00:0000", formatTimestamp(&buffer, seconds * 1000));
    try std.testing.expectEqualStrings("2026-01-01:00:00:0000", formatTimestamp(&buffer, seconds * 1000 + 9));
    try std.testing.expectEqualStrings("2026-01-01:00:00:0001", formatTimestamp(&buffer, seconds * 1000 + 10));
    try std.testing.expectEqualStrings("2025-12-31:23:59:5999", formatTimestamp(&buffer, seconds * 1000 - 1));
}

test "concurrent session log writers publish complete entries" {
    var logs: LogBuffer = .{};
    const Writer = struct {
        fn run(buffer: *LogBuffer) void {
            for (0..100) |_| buffer.append(.info, .test_log, "complete worker entry", .{});
        }
    };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{&logs});
    defer thread.join();
    Writer.run(&logs);
    const entries = try logs.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(entries);
    for (entries, 0..) |*entry, i| {
        try std.testing.expect(std.mem.endsWith(u8, entry.text(), "info(test_log): complete worker entry"));
        if (i > 0) try std.testing.expectEqual(entries[i - 1].serial + 1, entry.serial);
    }
}
