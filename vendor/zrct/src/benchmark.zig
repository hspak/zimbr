//! Bounded, allocation-free observation during a measured interval.
//! Times use CLOCK_MONOTONIC; completed frames precede presentation.
const std = @import("std");
const registry = @import("registry.zig");

pub const Spec = struct {
    name: []const u8,
    start: enum { action, launch } = .action,
    id: []const u8 = "",
    role: []const u8 = "",
    text: ?[]const u8 = null,
    text_contains: ?[]const u8 = null,
    value: ?[]const u8 = null,
    status: ?[]const u8 = null,
    selected: ?bool = null,
    enabled: ?bool = null,
    frames: bool = true,
};

test "measurement retains first action and stops at the first matching frame" {
    const a = std.testing.allocator;
    var snapshot = registry.Registry.init(a);
    defer snapshot.deinit();
    const observer = try Observer.create(a, "{\"name\":\"open\",\"id\":\"ready\"}", 0);
    defer observer.destroy(a);
    observer.action(8, 100);
    observer.action(9, 200);
    observer.frame(&snapshot, 300, 50);
    try snapshot.add(.{ .id = "ready", .role = "button", .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } });
    snapshot.frame_id = 2;
    observer.frame(&snapshot, 400, 50);
    observer.frame(&snapshot, 500, 50);
    try std.testing.expectEqual(100, observer.started_ns);
    try std.testing.expectEqual(400, observer.completed_ns);
    try std.testing.expectEqual(8, observer.action_id);
    try std.testing.expectEqual(2, observer.count);
}

test "overflow and ambiguous endpoints invalidate rather than dropping evidence" {
    const a = std.testing.allocator;
    var snapshot = registry.Registry.init(a);
    defer snapshot.deinit();
    const observer = try Observer.create(a, "{\"name\":\"open\",\"id\":\"ready\"}", 0);
    defer observer.destroy(a);
    observer.action(1, 1);
    for (0..2049) |i| observer.frame(&snapshot, @intCast(i + 2), 1);
    try std.testing.expectEqualStrings("TelemetryOverflow", observer.failure.?);
    try std.testing.expectEqual(2048, observer.count);
    const target = registry.Target{ .id = "ready", .role = "button", .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } };
    try snapshot.add(target);
    try snapshot.add(target);
    try std.testing.expectError(error.AmbiguousTarget, observer.matches(&snapshot));
}
pub const Frame = struct { frame_id: u64, completed_ns: i64, hooks_ns: i64 };
pub const Observer = struct {
    spec: std.json.Parsed(Spec),
    state: enum { armed, running, complete, invalid } = .armed,
    failure: ?[]const u8 = null,
    started_ns: i64 = 0,
    completed_ns: i64 = 0,
    frame_id: u64 = 0,
    action_id: ?u64 = null,
    frames: [2048]Frame = undefined,
    count: usize = 0,

    pub fn create(a: std.mem.Allocator, raw: []const u8, launch_ns: i64) !*Observer {
        const parsed = try std.json.parseFromSlice(Spec, a, raw, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const spec = parsed.value;
        if (spec.name.len == 0 or spec.name.len > 128 or (spec.id.len == 0 and spec.role.len == 0)) return error.InvalidMeasurement;
        if (spec.text != null and spec.text_contains != null) return error.InvalidMeasurement;
        const observer = try a.create(Observer);
        observer.* = .{ .spec = parsed };
        if (spec.start == .launch) {
            if (launch_ns <= 0) {
                a.destroy(observer);
                return error.MissingLaunchTimestamp;
            }
            observer.state = .running;
            observer.started_ns = launch_ns;
        }
        return observer;
    }
    pub fn destroy(self: *Observer, a: std.mem.Allocator) void {
        self.spec.deinit();
        a.destroy(self);
    }
    pub fn active(self: *const Observer) bool {
        return self.state == .armed or self.state == .running;
    }
    pub fn invalidate(self: *Observer, reason: []const u8) void {
        self.state = .invalid;
        self.failure = reason;
    }
    pub fn action(self: *Observer, id: u64, timestamp: i64) void {
        if (self.state != .armed) return;
        self.started_ns = timestamp;
        self.action_id = id;
        self.state = .running;
    }
    pub fn matches(self: *const Observer, snapshot: *const registry.Registry) !bool {
        if (snapshot.overflow) return error.IncompleteSnapshot;
        const spec = self.spec.value;
        var found: ?registry.Target = null;
        for (snapshot.targets.items) |target| {
            if (spec.id.len > 0 and !std.mem.eql(u8, target.id, spec.id)) continue;
            if (spec.role.len > 0 and !std.mem.eql(u8, target.role, spec.role)) continue;
            if (spec.text) |text| {
                if (target.strings.label.truncated) return error.TruncatedProperty;
                if (!std.mem.eql(u8, target.label, text)) continue;
            }
            if (spec.text_contains) |text| if (std.mem.find(u8, target.label, text) == null) continue;
            if (found != null) return error.AmbiguousTarget;
            found = target;
        }
        const target = found orelse return false;
        if (!target.visible or target.obscured) return false;
        inline for (.{ "value", "status" }) |field| {
            if (@field(spec, field)) |expected| {
                if (@field(target.strings, field).truncated) return error.TruncatedProperty;
                if (!std.mem.eql(u8, @field(target, field), expected)) return false;
            }
        }
        if (spec.selected) |expected| if (target.selected != expected) return false;
        if (spec.enabled) |expected| if (target.enabled != expected) return false;
        return true;
    }
    pub fn frame(self: *Observer, snapshot: *const registry.Registry, timestamp: i64, hooks_ns: i64) void {
        if (self.state != .running) return;
        if (self.spec.value.frames) {
            if (self.count == self.frames.len) return self.invalidate("TelemetryOverflow");
            self.frames[self.count] = .{ .frame_id = snapshot.frame_id, .completed_ns = timestamp, .hooks_ns = hooks_ns };
            self.count += 1;
        }
        const matched = self.matches(snapshot) catch |err| return self.invalidate(@errorName(err));
        if (matched) {
            self.completed_ns = timestamp;
            self.frame_id = snapshot.frame_id;
            self.state = .complete;
        }
    }
};
