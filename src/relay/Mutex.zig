//! Core is shared by dedicated OS threads. Keep this lock at a stable address
//! and unlock on the acquiring thread so macOS can promote a utility worker
//! when a user-initiated request waits for the journal.
const std = @import("std");
const u = @import("../common.zig");
const builtin = @import("builtin");
const macos = builtin.os.tag == .macos;
const c = if (macos) @cImport({
    @cInclude("os/lock.h");
}) else void;
const Mutex = @This();

native: if (macos) c.os_unfair_lock else std.Io.Mutex,

pub const init: Mutex = .{ .native = if (macos) c.OS_UNFAIR_LOCK_INIT else .init };

pub fn lockUncancelable(self: *Mutex, io: std.Io) void {
    if (comptime macos) c.os_unfair_lock_lock(&self.native) else self.native.lockUncancelable(io);
}
pub fn unlock(self: *Mutex, io: std.Io) void {
    if (comptime macos) c.os_unfair_lock_unlock(&self.native) else self.native.unlock(io);
}

const Counter = struct {
    mutex: Mutex = .init,
    count: usize = 0,
    fn run(self: *Counter, priority: c_int) void {
        u.c.zr_thread_qos(priority);
        for (0..2000) |_| {
            self.mutex.lockUncancelable(std.testing.io);
            self.count += 1;
            self.mutex.unlock(std.testing.io);
        }
    }
};

test "journal mutex protects shared state across worker priorities" {
    var state: Counter = .{};
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    state.mutex.lockUncancelable(std.testing.io);
    defer state.mutex.unlock(std.testing.io);
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Counter.run, .{ &state, @as(c_int, @intCast(i % 2)) });
        spawned += 1;
    }
    state.mutex.unlock(std.testing.io);
    for (threads) |thread| thread.join();
    spawned = 0;
    state.mutex.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(usize, 8000), state.count);
}
