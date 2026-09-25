//! Generation-based notification: capture before checking work, then wait.
//! A notification between the check and wait cannot be lost; all subscribers
//! wake independently, with a timeout for maintenance and recovery.
const std = @import("std");
const Signal = @This();

generation: std.atomic.Value(u32) = .init(0),

pub fn observe(s: *const Signal) u32 {
    return s.generation.load(.acquire);
}
pub fn notify(s: *Signal, io: std.Io) void {
    _ = s.generation.fetchAdd(1, .release);
    io.futexWake(u32, &s.generation.raw, std.math.maxInt(u32));
}
pub fn wait(s: *Signal, io: std.Io, observed: u32, milliseconds: i64) void {
    io.futexWaitTimeout(
        u32,
        &s.generation.raw,
        observed,
        .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } },
    ) catch {};
}

test "notification between observing and waiting is retained" {
    var signal = Signal{};
    const before = signal.observe();
    signal.notify(std.testing.io);
    signal.wait(std.testing.io, before, 60000);
    try std.testing.expect(signal.observe() != before);
}
