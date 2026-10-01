const std = @import("std");
const desktop = @import("desktop.zig");
const Point = @import("geometry.zig").Point;
const Rect = @import("geometry.zig").Rect;
const theme = @import("theme.zig");
const shapes = @import("shapes.zig");
const Scrollbar = @This();

dragging: bool = false,
grab: f32 = 0,

// A 16-pixel target is easier to grab than the narrow visible thumb.
pub const gutter: f32 = 16;
// A 25% multiplier makes wheel navigation cover more content per notch.
pub const wheel_scale: f32 = 1.25;

pub const Input = struct {
    mouse: Point,
    pressed: bool,
    down: bool,
};
pub const Geometry = struct {
    track: Rect,
    thumb: Rect,
    limit: f64,
};

pub fn geometry(viewport: Rect, content: f64, offset: f64) ?Geometry {
    if (viewport.height <= 0 or content <= viewport.height) return null;
    const track = Rect{
        .x = viewport.x + viewport.width - gutter,
        .y = viewport.y,
        .width = gutter,
        .height = viewport.height,
    };
    // Leave room to drag even in a one-line editor's short track.
    const min_thumb = @min(24, track.height / 2);
    const height = @min(
        track.height,
        @max(min_thumb, @as(f32, @floatCast(@as(f64, track.height) * viewport.height / content))),
    );
    const limit = content - viewport.height;
    return .{
        .track = track,
        .thumb = .{
            // Center a six-pixel thumb in the 16-pixel hit target.
            .x = track.x + 5,
            .y = track.y + (track.height - height) * @as(
                f32,
                @floatCast(std.math.clamp(offset / limit, 0, 1)),
            ),
            .width = 6,
            .height = height,
        },
        .limit = limit,
    };
}

// Keep pointer capture until release, including when it leaves the track.
// Store the grab point as a fraction so resizing or deferred history layout
// can change the thumb's height without losing the user's place on it.
pub fn update(s: *Scrollbar, viewport: Rect, content: f64, offset: f64, input: Input) ?f64 {
    const g = geometry(viewport, content, offset) orelse {
        s.dragging = false;
        return null;
    };
    if (!input.down) {
        s.dragging = false;
        return null;
    }
    if (input.pressed and g.track.contains(input.mouse)) {
        s.dragging = true;
        s.grab = if (input.mouse.y >= g.thumb.y and input.mouse.y <= g.thumb.y + g.thumb.height)
            (input.mouse.y - g.thumb.y) / g.thumb.height
        else
            0.5;
    }
    if (!s.dragging) return null;
    const travel = g.track.height - g.thumb.height;
    if (travel <= 0) return 0;
    return std.math.clamp(
        @as(f64, input.mouse.y - g.track.y - s.grab * g.thumb.height) / travel,
        0,
        1,
    ) * g.limit;
}

pub fn draw(s: Scrollbar, viewport: Rect, content: f64, offset: f64) void {
    const g = geometry(viewport, content, offset) orelse return;
    shapes.drawRectangle(.{
        // Center the four-pixel rail beneath the six-pixel thumb.
        .x = g.track.x + 6,
        .y = g.track.y,
        .width = 4,
        .height = g.track.height,
    }, 2, theme.colors.line);
    const hot = g.track.contains(desktop.mouse());
    shapes.drawRectangle(
        g.thumb,
        3,
        if (s.dragging or hot) theme.colors.accent else theme.colors.muted,
    );
}

test "scrollbars jump, drag outside the track, release, and clamp after resizing" {
    const viewport = Rect{
        .x = 20,
        .y = 40,
        .width = 300,
        .height = 200,
    };
    var bar = Scrollbar{};
    const midpoint = bar.update(viewport, 1000, 0, .{
        .mouse = .{ .x = 312, .y = 140 },
        .pressed = true,
        .down = true,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 400), midpoint, 0.001);
    // A grab away from the thumb's center does not jump on mouse-down.
    _ = bar.update(viewport, 1000, midpoint, .{
        .mouse = .{ .x = 312, .y = 126 },
        .pressed = false,
        .down = false,
    });
    const grabbed = bar.update(viewport, 1000, midpoint, .{
        .mouse = .{ .x = 312, .y = 126 },
        .pressed = true,
        .down = true,
    }).?;
    try std.testing.expectApproxEqAbs(midpoint, grabbed, 0.001);
    try std.testing.expectEqual(@as(f64, 800), bar.update(viewport, 1000, grabbed, .{
        .mouse = .{ .x = -50, .y = 400 },
        .pressed = false,
        .down = true,
    }).?);
    try std.testing.expectEqual(@as(f64, 0), bar.update(viewport, 1000, 800, .{
        .mouse = .{ .x = -50, .y = -40 },
        .pressed = false,
        .down = true,
    }).?);
    try std.testing.expect(bar.update(viewport, 1000, 0, .{
        .mouse = .{ .x = 312, .y = 140 },
        .pressed = false,
        .down = false,
    }) == null);
    try std.testing.expect(!bar.dragging);
    try std.testing.expect(bar.update(viewport, 100, 800, .{
        .mouse = .{ .x = 312, .y = 140 },
        .pressed = true,
        .down = true,
    }) == null);
    try std.testing.expect(geometry(viewport, 200, 0) == null);
    const long = geometry(viewport, 1e9, 1e9).?;
    try std.testing.expectEqual(@as(f32, 24), long.thumb.height);
    try std.testing.expectEqual(viewport.y + viewport.height, long.thumb.y + long.thumb.height);
}
