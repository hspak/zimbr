//! Editable settings and the first-launch gate. The active Config is replaced
//! only after all fields pass local validation and the database save succeeds.
const std = @import("std");
const Config = @import("Config.zig");
const Editor = @import("Editor.zig");
const c = @import("c.zig").api;
const Settings = @This();

fields: [4]Editor = @splat(.{}),
enter_to_send: bool = true,
visible: bool = false,
required: bool = false,
failure: c.ZcError = std.mem.zeroes(c.ZcError),

pub const field_names = .{
    "relay_url",
    "ca_file",
    "client_cert_file",
    "client_key_file",
};

pub fn init(config: Config) std.mem.Allocator.Error!Settings {
    var settings: Settings = .{ .enter_to_send = config.enter_to_send };
    errdefer settings.deinit();
    settings.required = !config.check(&settings.failure);
    settings.visible = settings.required or config.settings;
    inline for (field_names, 0..) |field, index| {
        settings.fields[index].set(@field(config, field)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidText => {}, // Invalid saved bytes remain empty for repair.
        };
    }
    return settings;
}
pub fn deinit(s: *Settings) void {
    for (&s.fields) |*field| field.deinit();
    s.* = undefined;
}

/// All returned strings belong to the caller's arena, independently of editors.
pub fn toConfig(s: *const Settings, a: std.mem.Allocator, base: Config) std.mem.Allocator.Error!Config {
    var candidate = base;
    inline for (field_names, 0..) |field, index| {
        @field(candidate, field) = try a.dupeZ(u8, std.mem.trim(u8, s.fields[index].text.items, " \t"));
    }
    candidate.enter_to_send = s.enter_to_send;
    candidate.overrides = .{};
    candidate.settings = false;
    candidate.details = false;
    return candidate;
}

/// The required pane stays open until the caller applies a successfully saved config.
pub fn close(s: *Settings) void {
    if (!s.required) s.visible = false;
}

test "missing and invalid settings cannot dismiss the first-launch pane" {
    var settings = try Settings.init(.{ .data = "", .details = true });
    defer settings.deinit();
    try std.testing.expect(settings.visible and settings.required);
    settings.close();
    try std.testing.expect(settings.visible);
    try settings.fields[0].set("http://relay.example");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidate = try settings.toConfig(arena.allocator(), .{ .data = "" });
    try std.testing.expect(!candidate.check(&settings.failure));
    settings.close();
    try std.testing.expect(settings.visible);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&settings.failure.message, 0), "HTTPS") != null);
}

test "settings edits own their text and do not change the active configuration" {
    const active = Config{ .data = "/state", .relay_url = "https://original.example" };
    var settings = try Settings.init(active);
    defer settings.deinit();
    try settings.fields[0].set(" https://new.example ");
    settings.enter_to_send = false;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidate = try settings.toConfig(arena.allocator(), active);
    try settings.fields[0].set("https://third.example");
    try std.testing.expectEqualStrings("https://new.example", candidate.relay_url);
    try std.testing.expectEqualStrings("https://original.example", active.relay_url);
    try std.testing.expect(!candidate.enter_to_send);
    settings.required = false;
    settings.close();
    try std.testing.expect(!settings.visible);
}
