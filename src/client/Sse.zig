const std = @import("std");
const u = @import("../common.zig");
const Sse = @This();

// Frames are committed only at a blank line. A disconnect discards the partial
// frame and resumes from the store's committed cursor.
buffer: std.ArrayList(u8) = .empty,
line_start: usize = 0,

pub fn deinit(s: *Sse) void {
    s.buffer.deinit(std.heap.page_allocator);
    s.* = undefined;
}

/// Discard an incomplete frame before resuming from the committed cursor.
pub fn reset(s: *Sse) void {
    s.deinit();
    s.* = .{};
}
pub fn FeedError(comptime Accept: type) type {
    return std.mem.Allocator.Error || error{ FrameTooLarge, InvalidFrame } ||
        @typeInfo(@typeInfo(Accept).@"fn".return_type.?).error_union.error_set;
}

pub fn feed(s: *Sse, comptime accept: anytype, context: anytype, bytes: []const u8) FeedError(@TypeOf(accept))!void {
    const a = std.heap.page_allocator;
    for (bytes) |byte| {
        if (s.buffer.items.len >= 1024 * 1024) return error.FrameTooLarge;
        try s.buffer.append(a, byte);
        if (byte == '\n') {
            const line = std.mem.trimEnd(
                u8,
                s.buffer.items[s.line_start .. s.buffer.items.len - 1],
                "\r",
            );
            if (line.len == 0) {
                try parse(accept, context, s.buffer.items);
                s.buffer.clearRetainingCapacity();
                s.line_start = 0;
            } else s.line_start = s.buffer.items.len;
        }
    }
}
fn parse(comptime accept: anytype, context: anytype, frame: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var id: []const u8 = "";
    var event: []const u8 = "";
    var data: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == ':') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const key = line[0..colon];
        var value = if (colon < line.len) line[colon + 1 ..] else "";
        if (std.mem.startsWith(u8, value, " ")) value = value[1..];
        if (u.eq(key, "id")) id = value else if (u.eq(key, "event")) event = value else if (u.eq(
            key,
            "data",
        )) {
            if (data.items.len > 0) try data.append(a, '\n');
            try data.appendSlice(a, value);
        }
    }
    if (data.items.len == 0) return;
    if (id.len == 0 or event.len == 0 or !std.unicode.utf8ValidateSlice(data.items)) return error.InvalidFrame;
    try accept(context, a, data.items, id, event);
}
