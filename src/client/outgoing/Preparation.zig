//! One file owner prepares private originals and collects retired files while
//! the main client worker continues polling live events and network requests.
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.client_preparation);
const a = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;
const u = @import("../../common.zig");
const c = @import("../c.zig").api;
const Store = @import("../Store.zig");
const Files = @import("Files.zig");
const Preparation = @This();

io: std.Io,
data: []const u8,
parent_wake: c_int,
files: Files = undefined,
thread: ?std.Thread = null,
mutex: std.Io.Mutex = .init,
stop: std.atomic.Value(bool) = .init(false),
health: std.atomic.Value(enum(u8) { starting, ready, failed }) = .init(.starting),
wake_pipe: [2]c_int = .{ -1, -1 },
pending: ?*Task = null,
results: ?*Task = null,
active: ?*Task = null,
count: usize = 0,

pub const StartError = Files.InitError || std.Thread.SpawnError || error{AttachmentWakeUnavailable};
pub const PushError = u.Allocator.Error || error{TooManyPreparations};
pub const Task = struct {
    key: []const u8,
    path: []const u8,
    cancelled: std.atomic.Value(bool) = .init(false),
    next: ?*Task = null,
    file_id: ?[u.id_length]u8 = null,
    failure: ?Files.StageError = null,

    pub fn destroy(self: *Task) void {
        a.free(self.key);
        a.free(self.path);
        a.destroy(self);
    }
};

pub fn start(self: *Preparation) StartError!void {
    self.files = try Files.init(a, self.data);
    errdefer self.files.deinit();
    if (u.c.pipe(&self.wake_pipe) != 0) return error.AttachmentWakeUnavailable;
    errdefer for (self.wake_pipe) |fd| {
        _ = u.c.close(fd);
    };
    for (self.wake_pipe) |fd| {
        if (u.c.fcntl(fd, u.c.F_SETFL, @as(c_int, u.c.O_NONBLOCK)) < 0 or
            u.c.fcntl(fd, u.c.F_SETFD, @as(c_int, u.c.FD_CLOEXEC)) < 0)
            return error.AttachmentWakeUnavailable;
    }
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn shutdown(self: *Preparation) void {
    self.mutex.lockUncancelable(self.io);
    self.stop.store(true, .release);
    if (self.active) |task| task.cancelled.store(true, .release);
    self.mutex.unlock(self.io);
    self.wake();
    if (self.thread) |thread| thread.join();
    while (pop(&self.pending)) |task| task.destroy();
    while (pop(&self.results)) |task| task.destroy();
    for (self.wake_pipe) |fd| _ = u.c.close(fd);
    self.files.deinit();
    self.* = undefined;
}

pub fn push(self: *Preparation, key: []const u8, path: []const u8) PushError!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.count == 32) return error.TooManyPreparations;
    const task = try a.create(Task);
    errdefer a.destroy(task);
    const owned_key = try a.dupe(u8, key);
    errdefer a.free(owned_key);
    task.* = .{ .key = owned_key, .path = try a.dupe(u8, path) };
    append(&self.pending, task);
    self.count += 1;
    self.wake();
}

pub fn busy(self: *Preparation, key: []const u8) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (key.len == 0) return self.count != 0;
    if (self.active) |task| if (u.eq(task.key, key)) return true;
    for ([_]?*Task{ self.pending, self.results }) |head| {
        var next = head;
        while (next) |task| : (next = task.next) if (u.eq(task.key, key)) return true;
    }
    return false;
}

pub fn cancel(self: *Preparation, key: []const u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.active) |task| if (u.eq(task.key, key)) task.cancelled.store(true, .release);
    for ([_]?*Task{ self.pending, self.results }) |head| {
        var next = head;
        while (next) |task| : (next = task.next) {
            if (u.eq(task.key, key)) task.cancelled.store(true, .release);
        }
    }
    self.wake();
}

/// Transfer a completed task to the caller. A canceled task can still contain a
/// committed file ID when cancellation raced publication; retire that draft file.
pub fn take(self: *Preparation) ?*Task {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const task = pop(&self.results) orelse return null;
    self.count -= 1;
    return task;
}

pub fn wake(self: *Preparation) void {
    if (self.wake_pipe[1] >= 0) _ = u.c.write(self.wake_pipe[1], "f", 1);
}

fn append(head: *?*Task, task: *Task) void {
    var tail = head;
    while (tail.*) |item| tail = &item.next;
    tail.* = task;
}
fn pop(head: *?*Task) ?*Task {
    const task = head.* orelse return null;
    head.* = task.next;
    task.next = null;
    return task;
}
fn run(self: *Preparation) void {
    self.work() catch |err| {
        log.warn("Attachment preparation unavailable: {s}", .{@errorName(err)});
        self.mutex.lockUncancelable(self.io);
        while (pop(&self.pending)) |task| {
            task.failure = error.AttachmentStorageUnavailable;
            append(&self.results, task);
        }
        self.health.store(.failed, .release);
        self.mutex.unlock(self.io);
        _ = u.c.write(self.parent_wake, "f", 1);
    };
}
fn work(self: *Preparation) !void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{self.data}, 0);
    defer a.free(path);
    const store = try Store.open(path);
    defer store.close();
    try self.files.collect(store, true);
    self.health.store(.ready, .release);
    _ = u.c.write(self.parent_wake, "f", 1);
    while (!self.stop.load(.acquire)) {
        self.mutex.lockUncancelable(self.io);
        const next = pop(&self.pending);
        self.active = next;
        self.mutex.unlock(self.io);
        if (next) |task| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            if (self.files.stage(arena.allocator(), store, task.key, .{
                .path = task.path,
                .cancel = &task.cancelled,
            })) |file| {
                task.file_id = file.id[0..u.id_length].*;
            } else |err| task.failure = err;
            self.mutex.lockUncancelable(self.io);
            self.active = null;
            append(&self.results, task);
            self.mutex.unlock(self.io);
            _ = u.c.write(self.parent_wake, "f", 1);
        } else {
            self.files.collect(store, false) catch |err| {
                log.warn("Attachment cleanup delayed: {s}", .{@errorName(err)});
            };
            _ = c.zc_net_wait(null, self.wake_pipe[0], 1000);
        }
    }
}

test "preparation startup failure completes queued files instead of blocking future sends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const database = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{root}, 0);
    defer a.free(database);
    try std.testing.expectEqual(@as(c_int, 0), u.c.mkdir(database, 0o700));
    var preparation: Preparation = .{
        .io = std.testing.io,
        .data = root,
        .parent_wake = -1,
    };
    try preparation.push("chat", "/file.bin");
    try preparation.start();
    defer preparation.shutdown();
    const deadline = u.now() + 5000;
    while (preparation.health.load(.acquire) != .failed and u.now() < deadline)
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    try std.testing.expectEqual(.failed, preparation.health.load(.acquire));
    const task = preparation.take() orelse return error.TestUnexpectedResult;
    defer task.destroy();
    try std.testing.expectEqualStrings("chat", task.key);
    try std.testing.expectEqual(error.AttachmentStorageUnavailable, task.failure.?);
    try std.testing.expect(task.file_id == null);
    try std.testing.expect(!preparation.busy(""));
}
