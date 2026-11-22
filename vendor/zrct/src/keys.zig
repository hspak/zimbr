//! Canonical physical key names, SDL scancodes and Linux evdev codes.
const std = @import("std");
const source = @embedFile("keys.tsv");
const count = std.mem.count(u8, source, "\n");
pub const Entry = struct { name: [:0]const u8, scancode: c_int, evdev: u16 };
pub const entries: [count]Entry = blk: {
    @setEvalBranchQuota(20000);
    var result: [count]Entry = undefined;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    var i = 0;
    while (lines.next()) |line| : (i += 1) {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        result[i] = .{
            .name = fields.next().? ++ "",
            .scancode = std.fmt.parseInt(c_int, fields.next().?, 10) catch unreachable,
            .evdev = std.fmt.parseInt(u16, fields.next().?, 10) catch unreachable,
        };
    }
    break :blk result;
};
pub const Key = blk: {
    var names: [count + 1][:0]const u8 = undefined;
    var values: [count + 1]c_int = undefined;
    names[0] = "null";
    values[0] = 0;
    for (entries, 1..) |entry, i| {
        names[i] = entry.name;
        values[i] = entry.scancode;
    }
    break :blk @Enum(c_int, .exhaustive, &names, &values);
};

test "editing keys map to SDL scancodes and Linux evdev" {
    try std.testing.expectEqual(42, @backingInt(Key.backspace));
    try std.testing.expectEqual(77, @backingInt(Key.end));
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "backspace")) try std.testing.expectEqual(14, entry.evdev);
    }
}
