const std = @import("std");
const rl = @import("raylib");
pub fn color(hex: u32) rl.Color {
    return .{
        .r = @intCast(hex >> 24),
        .g = @intCast((hex >> 16) & 255),
        .b = @intCast((hex >> 8) & 255),
        .a = @intCast(hex & 255),
    };
}
pub const Palette = struct {
    ink: rl.Color,
    muted: rl.Color,
    disabled: rl.Color,
    accent: rl.Color,
    accent_hover: rl.Color,
    on_accent: rl.Color,
    paper: rl.Color,
    sidebar: rl.Color,
    line: rl.Color,
    incoming: rl.Color,
    selected: rl.Color,
    selection: rl.Color,
    avatar: rl.Color,
    focus: rl.Color,
    danger: rl.Color,
    rail: rl.Color,
    surface: rl.Color,
    success: rl.Color,
};
pub const colors = Palette{
    .ink = color(0xf1eef6ff),
    .muted = color(0xb8b1c4ff),
    .disabled = color(0x817a8eff),
    // The logo's illuminated lavender carries actions and interaction feedback.
    .accent = color(0xc4a3e6ff),
    .accent_hover = color(0xd5b9efff),
    .on_accent = color(0x241b30ff),
    .focus = color(0xd0b6eaff),
    .selected = color(0x393148ff),
    .selection = color(0xc4a3e650),
    // Graphite surfaces share a violet undertone, with the rail deepest in the stack.
    .rail = color(0x141219ff),
    .paper = color(0x19181fff),
    .sidebar = color(0x211f2aff),
    .surface = color(0x24212dff),
    .incoming = color(0x2a2635ff),
    .avatar = color(0x30283dff),
    .line = color(0x494253ff),
    // Sage and apricot remain reserved for status feedback.
    .success = color(0x90c8b0ff),
    .danger = color(0xeeb099ff),
};

pub const Participant = struct { bubble: rl.Color, label: rl.Color };
// Reserved for read-only conversation avatars; never part of the participant palette.
pub const read_only_avatar = Participant{
    .bubble = color(0x302d36ff),
    .label = color(0xa39baeff),
};
const participant_colors = [_]Participant{
    .{ .bubble = color(0x30324aff), .label = color(0xb6c3eeff) },
    .{ .bubble = color(0x382d47ff), .label = color(0xd2b6edff) },
    .{ .bubble = color(0x40312cff), .label = color(0xe5bc9eff) },
    .{ .bubble = color(0x293b36ff), .label = color(0xa8d2bfff) },
    .{ .bubble = color(0x412d39ff), .label = color(0xe7b2c9ff) },
    .{ .bubble = color(0x293b40ff), .label = color(0xa6cbd8ff) },
    .{ .bubble = color(0x3c382bff), .label = color(0xd8c89eff) },
    .{ .bubble = color(0x312e46ff), .label = color(0xc2bbeaff) },
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
    const members = [_][]const u8{
        "alice",
        "bob",
        "carol",
    };
    const reordered = [_][]const u8{
        "carol",
        "alice",
        "bob",
    };
    for (members, 0..) |sender, i| {
        const style = participant(sender, &members);
        try std.testing.expectEqual(style, participant(sender, &reordered));
        for (members[0..i]) |other| try std.testing.expect(!std.meta.eql(
            style.bubble,
            participant(other, &members).bubble,
        ));
    }
}
