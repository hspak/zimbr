//! Shared ceiling for request and SSE arenas, including responses held by slow
//! readers. The backing allocator must support concurrent allocation and free.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Memory = @This();

backing: Allocator,
limit: usize,
used: std.atomic.Value(usize) = .init(0),

/// Borrow this budget at its final address until all allocations are freed.
/// Exhaustion reports OutOfMemory; freeing another stream restores capacity.
pub fn allocator(self: *Memory) Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = allocate,
        .resize = Allocator.noResize,
        .remap = Allocator.noRemap,
        .free = free,
    } };
}

fn allocate(pointer: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Memory = @ptrCast(@alignCast(pointer));
    var used = self.used.load(.monotonic);
    while (true) {
        if (len > self.limit - used) return null;
        used = self.used.cmpxchgWeak(used, used + len, .monotonic, .monotonic) orelse break;
    }
    return self.backing.rawAlloc(len, alignment, ret_addr) orelse {
        _ = self.used.fetchSub(len, .monotonic);
        return null;
    };
}

fn free(pointer: *anyopaque, bytes: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Memory = @ptrCast(@alignCast(pointer));
    self.backing.rawFree(bytes, alignment, ret_addr);
    _ = self.used.fetchSub(bytes.len, .monotonic);
}

test "failed backing allocations return quota and realloc charges peak storage" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var budget: Memory = .{ .backing = failing.allocator(), .limit = 64 };
    const a = budget.allocator();
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 64));
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.monotonic));
    failing.fail_index = std.math.maxInt(usize);
    const bytes = try a.dupe(u8, "x" ** 32);
    defer a.free(bytes);
    try std.testing.expectError(error.OutOfMemory, a.realloc(bytes, 33));
    try std.testing.expectEqualStrings("x" ** 32, bytes);
    try std.testing.expectEqual(@as(usize, 32), budget.used.load(.monotonic));
    const remaining = try a.alloc(u8, 32);
    a.free(remaining);
}
