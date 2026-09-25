//! Validated, optimistic configuration replacement shared by the CLI and native settings window.
const std = @import("std");
const Tls = @import("Tls.zig");

pub const SaveError = Tls.LoadError || error{ ConfigurationChanged, ConfigurationWriteDenied };
pub const SaveResult = enum { saved, durability_unconfirmed };

/// The caller owns expected and bytes. Null expected requires an absent destination;
/// otherwise the file must still match the exact bytes read when editing began.
/// Validation failures leave the destination untouched. A durability warning means
/// replacement succeeded but the containing directory could not be synchronized.
pub fn save(
    gpa: std.mem.Allocator,
    path: []const u8,
    expected: ?[]const u8,
    bytes: []const u8,
) SaveError!SaveResult {
    if (bytes.len >= 65536) return error.ConfigurationWriteDenied;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var candidate = try Tls.loadBytes(a, bytes);
    defer candidate.deinit();
    const terminated_path = try a.dupeZ(u8, path);
    return switch (Tls.c.zr_tls_replace_config(
        terminated_path,
        if (expected) |original| original.ptr else null,
        if (expected) |original| original.len else 0,
        bytes.ptr,
        bytes.len,
    )) {
        0 => .saved,
        1 => .durability_unconfirmed,
        -2 => error.ConfigurationChanged,
        else => error.ConfigurationWriteDenied,
    };
}
