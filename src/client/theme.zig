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
pub const colors = Palette{
    .ink = color(0xebeaf5ff),
    .muted = color(0xa9aec9ff),
    .accent = color(0x6366c4ff),
    .accent_hover = color(0x7073d1ff),
    .paper = color(0x171824ff),
    .sidebar = color(0x1c1e2dff),
    .line = color(0x34384fff),
    .incoming = color(0x292c41ff),
    .selected = color(0x303654ff),
    .avatar = color(0x363d58ff),
    .focus = color(0x9798e5ff),
    .danger = color(0xe3aa8dff),
};

pub const Participant = struct { bubble: rl.Color, label: rl.Color };
const participant_colors = [_]Participant{
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
    const index = if (found) rank % participant_colors.len else std.hash.Wyhash.hash(0, sender) % participant_colors.len;
    return participant_colors[index];
}

test "group participant tints survive membership ordering" {
    const members = [_][]const u8{ "alice", "bob", "carol" };
    const reordered = [_][]const u8{ "carol", "alice", "bob" };
    for (members, 0..) |sender, i| {
        const style = participant(sender, &members);
        try std.testing.expectEqual(style, participant(sender, &reordered));
        for (members[0..i]) |other| try std.testing.expect(!std.meta.eql(style.bubble, participant(other, &members).bubble));
    }
}
