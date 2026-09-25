//! macOS automation boundary. The database reader also accepts synthetic
//! fixtures on Linux, but only this adapter contains the AppleScript operation.
const builtin = @import("builtin");
const u = @import("../../common.zig");
pub const Source = @import("MessagesDb.zig");
pub const open = Source.open;
pub const AutomationError = u.Allocator.Error || error{
    UnsupportedPlatform,
    DispatchUnstarted,
    PermissionRequired,
    UnsupportedAccount,
    UnsupportedTarget,
    AdapterUnavailable,
    AutomationUncertain,
};

pub fn automation(a: u.Allocator, mode: []const u8, route: []const u8, text: []const u8) AutomationError!void {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const rc = u.c.zr_spawn(
        @embedFile("send.applescript"),
        try a.dupeZ(u8, mode),
        try a.dupeZ(u8, route),
        try a.dupeZ(u8, text),
        15000,
    );
    switch (rc) {
        0 => {},
        -2 => return error.DispatchUnstarted,
        1 => return error.PermissionRequired,
        2 => return error.UnsupportedAccount,
        3 => return error.UnsupportedTarget,
        4 => return error.AdapterUnavailable,
        else => return error.AutomationUncertain,
    }
}

pub fn automationReason(err: AutomationError) []const u8 {
    return switch (err) {
        error.PermissionRequired => "automation_permission_required",
        error.UnsupportedAccount => "unsupported_account_configuration",
        error.UnsupportedTarget => "unsupported_target",
        error.DispatchUnstarted => "automation_launch_failed",
        error.AdapterUnavailable => "messages_unavailable",
        else => "automation_timeout_or_uncertain",
    };
}
