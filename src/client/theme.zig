const std = @import("std");
const rl = @import("raylib");
pub fn color(hex: u32) rl.Color {
    return .{ .r = @intCast(hex >> 24), .g = @intCast((hex >> 16) & 255), .b = @intCast((hex >> 8) & 255), .a = @intCast(hex & 255) };
}
pub const Palette = struct {
    ink: rl.Color,
    muted: rl.Color,
    accent: rl.Color,
    accent_hover: rl.Color,
    on_accent: rl.Color = color(0xffffffff),
    paper: rl.Color,
    sidebar: rl.Color,
    line: rl.Color,
    incoming: rl.Color,
    selected: rl.Color,
    avatar: rl.Color,
    focus: rl.Color,
    danger: rl.Color,
};
pub const light = Palette{
    .ink = color(0x253335ff),
    .muted = color(0x788487ff),
    .accent = color(0x167b69ff),
    .accent_hover = color(0x116b5bff),
    .paper = color(0xffffffff),
    .sidebar = color(0xf5f7f7ff),
    .line = color(0xe6ebebff),
    .incoming = color(0xf0f3f3ff),
    .selected = color(0xe0eeebff),
    .avatar = color(0xdce6e4ff),
    .focus = color(0x95bfb5ff),
    .danger = color(0xaf6538ff),
};
pub const dark = Palette{
    .ink = color(0xe4eceaff),
    .muted = color(0xa1b1acff),
    .accent = color(0x238772ff),
    .accent_hover = color(0x2a967fff),
    .paper = color(0x151b1aff),
    .sidebar = color(0x1b2321ff),
    .line = color(0x303c38ff),
    .incoming = color(0x26312dff),
    .selected = color(0x29463dff),
    .avatar = color(0x344a42ff),
    .focus = color(0x589e88ff),
    .danger = color(0xe3aa79ff),
};
pub var colors = light;
pub var is_dark = false;
pub fn setDark(enabled: bool) void {
    is_dark = enabled;
    colors = if (enabled) dark else light;
}

pub const Participant = struct { bubble: rl.Color, label: rl.Color };
const participant_light = [_]Participant{
    .{ .bubble = color(0xeaf1faff), .label = color(0x42678dff) },
    .{ .bubble = color(0xf2ecf8ff), .label = color(0x785694ff) },
    .{ .bubble = color(0xf8eee7ff), .label = color(0x8d6041ff) },
    .{ .bubble = color(0xeaf3e7ff), .label = color(0x527446ff) },
    .{ .bubble = color(0xf8eaf0ff), .label = color(0x955472ff) },
    .{ .bubble = color(0xe6f2f3ff), .label = color(0x3d727aff) },
    .{ .bubble = color(0xf5f1e2ff), .label = color(0x7d7037ff) },
    .{ .bubble = color(0xeeedfaff), .label = color(0x635e99ff) },
};
const participant_dark = [_]Participant{
    .{ .bubble = color(0x253346ff), .label = color(0x9dbbe0ff) },
    .{ .bubble = color(0x352c43ff), .label = color(0xc2a8deff) },
    .{ .bubble = color(0x3d3028ff), .label = color(0xdab292ff) },
    .{ .bubble = color(0x2a3728ff), .label = color(0xaac89bff) },
    .{ .bubble = color(0x402b35ff), .label = color(0xdaa5beff) },
    .{ .bubble = color(0x23393dff), .label = color(0x94c6ccff) },
    .{ .bubble = color(0x383522ff), .label = color(0xcfc18aff) },
    .{ .bubble = color(0x2e2d43ff), .label = color(0xb3aee3ff) },
};

pub fn participant(sender: []const u8, participants: []const []const u8) Participant {
    // Rank by address, not message order or the server's membership order.
    // Nearby participants get distinct tints; large groups cycle the palette.
    var rank: usize = 0;
    var found = false;
    for (participants) |address| {
        if (std.mem.order(u8, address, sender) == .lt) rank += 1;
        found = found or std.mem.eql(u8, address, sender);
    }
    const index = if (found) rank % participant_light.len else std.hash.Wyhash.hash(0, sender) % participant_light.len;
    return if (is_dark) participant_dark[index] else participant_light[index];
}

test "group participant tints survive membership ordering and theme changes" {
    defer setDark(false);
    const members = [_][]const u8{ "alice", "bob", "carol" };
    const reordered = [_][]const u8{ "carol", "alice", "bob" };
    for ([_]bool{ false, true }) |dark_mode| {
        setDark(dark_mode);
        for (members, 0..) |sender, i| {
            const style = participant(sender, &members);
            try std.testing.expectEqual(style, participant(sender, &reordered));
            for (members[0..i]) |other| try std.testing.expect(!std.meta.eql(style.bubble, participant(other, &members).bubble));
        }
    }
}
