//! Native menu callbacks. The service publishes its core once; UI work reads it under its lock.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const Core = @import("Core.zig");
const Tls = @import("Tls.zig");
const settings = @import("settings.zig");
const contacts = @import("adapter/contacts.zig");
const u = @import("../common.zig");
const c = @cImport({
    @cInclude("relay/menu.h");
});
const Menu = @This();

config_path: [:0]const u8,
data_path: [:0]const u8,
core: std.atomic.Value(?*Core) = .init(null),
failure: std.atomic.Value(?[*:0]const u8) = .init(null),
listening: std.atomic.Value(bool) = .init(false),
// Written before publishing core; immutable for the lifetime of that service.
expires_unix: i64 = 0,

pub const available = builtin.os.tag == .macos and !options.fake;

/// Runs on the main thread. The receiver and its paths must outlive the event loop.
pub fn run(self: *Menu, show_settings: bool) void {
    if (comptime available) {
        const bridge = self.callbacks();
        c.zr_menu_run(&bridge, self.config_path, self.data_path, @intFromBool(show_settings));
    }
}

fn callbacks(self: *Menu) c.ZrMenu {
    return .{
        .name = options.relay_display_name ++ "\x00",
        .bundle_id = options.relay_bundle_id ++ "\x00",
        .default_port = options.relay_default_port,
        .relay = self,
        .read_config = readConfig,
        .save_config = saveConfig,
        .status = status,
    };
}

/// Asks the existing menu instance to reveal Settings; carries no configuration or commands.
pub fn reopen(config_path: [:0]const u8) void {
    if (comptime available) c.zr_menu_reopen(config_path, options.relay_bundle_id ++ "\x00");
}

pub const RelaunchError = error{ InvalidArguments, RestartHandoffFailed };

/// Removes a private relaunch prefix after the previous process exits.
/// The returned argument slices borrow the caller's storage.
pub fn resumeRestart(args: []const [:0]const u8) RelaunchError![]const [:0]const u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[1], "menu-relaunch")) return args;
    if (comptime !available) return error.InvalidArguments;
    if (args.len < 4) return error.InvalidArguments;
    const pid = std.fmt.parseInt(c_int, args[2], 10) catch return error.InvalidArguments;
    if (pid <= 1) return error.InvalidArguments;
    if (c.zr_menu_wait_for_exit(pid) != 0) return error.RestartHandoffFailed;
    return args[3..];
}

fn readConfig(raw: ?*anyopaque, out: [*c]u8, capacity: usize) callconv(.c) c_int {
    const self: *Menu = @ptrCast(@alignCast(raw.?));
    return Tls.c.zr_tls_read_config(self.config_path, out, capacity);
}

fn saveConfig(
    raw: ?*anyopaque,
    expected: [*c]const u8,
    expected_length: usize,
    bytes: [*c]const u8,
    length: usize,
    diagnostic: [*c]u8,
    capacity: usize,
) callconv(.c) c_int {
    const self: *Menu = @ptrCast(@alignCast(raw.?));
    const result = settings.save(
        std.heap.page_allocator,
        self.config_path,
        if (expected == null) null else expected[0..expected_length],
        bytes[0..length],
    ) catch |err| {
        _ = copy(diagnostic, capacity, @errorName(err));
        return -1;
    };
    return switch (result) {
        .saved => 0,
        .durability_unconfirmed => 1,
    };
}

fn status(raw: ?*anyopaque, out: [*c]u8, capacity: usize) callconv(.c) c_int {
    const self: *Menu = @ptrCast(@alignCast(raw.?));
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const bytes = self.snapshot(arena.allocator()) catch return -1;
    return copy(out, capacity, bytes);
}

fn snapshot(self: *Menu, a: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    if (self.failure.load(.acquire)) |failure| return u.json(a, .{
        .summary = "Relay needs attention",
        .detail = std.mem.span(failure),
        .warning = true,
    });
    const core = self.core.load(.acquire) orelse return u.json(a, .{
        .summary = "Starting relay…",
        .detail = "Loading settings and message history",
        .warning = false,
    });
    core.lock();
    defer core.unlock();
    const health = describe(
        self.listening.load(.acquire),
        core.read_ready,
        core.automation_ready,
        core.last_scan_ms,
        self.expires_unix,
        u.now(),
    );
    return u.json(a, .{
        .summary = health.summary,
        .detail = if (!core.read_ready) core.degraded else if (!core.automation_ready)
            core.automation_error
        else
            "",
        .warning = health.warning,
        .messages_readable = core.read_ready,
        .sending_available = core.read_ready and core.automation_ready,
        .contacts_permission = contacts.permission(),
        .contacts_phone_region = core.contacts_phone_region,
    });
}

const Health = struct { summary: []const u8, warning: bool };

fn describe(
    listening: bool,
    read_ready: bool,
    automation_ready: bool,
    last_scan_ms: i64,
    expires_unix: i64,
    now_ms: i64,
) Health {
    if (!listening) return .{ .summary = "Starting listener…", .warning = false };
    if (!read_ready) return .{ .summary = "Messages unavailable", .warning = true };
    if (now_ms - last_scan_ms >= 5000) return .{ .summary = "Message sync delayed", .warning = true };
    if (!automation_ready) return .{ .summary = "Running · Sending unavailable", .warning = true };
    const remaining = expires_unix - @divTrunc(now_ms, 1000);
    if (remaining <= 0) return .{ .summary = "Certificate expired", .warning = true };
    if (remaining <= 30 * 86400) return .{ .summary = "Running · Certificate expiring", .warning = true };
    return .{ .summary = "Running · Messages available", .warning = false };
}

fn copy(out: [*c]u8, capacity: usize, bytes: []const u8) c_int {
    if (bytes.len >= capacity) return -1;
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0;
    return @intCast(bytes.len);
}

test "menu distinguishes delayed ingestion and unavailable sending from healthy service" {
    const expect = std.testing.expect;
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expect(!describe(true, true, true, 9000, 9999999, 10000).warning);
    try expectEqualStrings("Messages unavailable", describe(true, false, true, 9000, 9999999, 10000).summary);
    try expectEqualStrings("Message sync delayed", describe(true, true, true, 5000, 9999999, 10000).summary);
    try expectEqualStrings("Running · Sending unavailable", describe(true, true, false, 9000, 9999999, 10000).summary);
    try expectEqualStrings("Starting listener…", describe(false, true, true, 9000, 9999999, 10000).summary);
    try expectEqualStrings("Certificate expired", describe(true, true, true, 9000, 10, 10000).summary);
    try expectEqualStrings("Running · Certificate expiring", describe(true, true, true, 9000, 11, 10000).summary);
}

test "menu reports startup failures through its native callback without a running core" {
    var menu: Menu = .{ .config_path = "/unused/relay.json", .data_path = "/unused" };
    const bridge = menu.callbacks();
    var buffer: [8192]u8 = undefined;
    const starting_length = bridge.status.?(bridge.relay, &buffer, buffer.len);
    try std.testing.expect(starting_length > 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..@intCast(starting_length)], "Starting relay") != null);
    menu.failure.store(@errorName(error.InvalidTlsConfiguration), .release);
    const length = bridge.status.?(bridge.relay, &buffer, buffer.len);
    try std.testing.expect(length > 0);
    try std.testing.expectEqual(@as(u8, 0), buffer[@intCast(length)]);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buffer[0..@intCast(length)], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Relay needs attention", parsed.value.object.get("summary").?.string);
    try std.testing.expectEqualStrings("InvalidTlsConfiguration", parsed.value.object.get("detail").?.string);
    try std.testing.expect(parsed.value.object.get("warning").?.bool);
    try std.testing.expectEqual(@as(c_int, -1), bridge.status.?(bridge.relay, &buffer, 1));
}
