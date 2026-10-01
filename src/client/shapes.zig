//! Rounded UI geometry rendered into the multisampled window framebuffer.
const std = @import("std");
const desktop = @import("desktop.zig");
const graphics = @import("graphics.zig");

/// Fills bounds, with roundness clamped to 0–1.
pub fn drawRectangle(bounds: graphics.Rect, roundness: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0) return;
    const radius = @min(bounds.width, bounds.height) * std.math.clamp(roundness, 0, 1) / 2;
    graphics.rounded(bounds, roundness, cornerSegments(radius, desktop.scale()), color);
}

/// Draws an outline outside bounds, with thickness measured in logical pixels.
pub fn drawRectangleLines(bounds: graphics.Rect, roundness: f32, thickness: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0 or thickness <= 0) return;
    const radius = @min(bounds.width, bounds.height) * std.math.clamp(roundness, 0, 1) / 2;
    if (radius == 0) {
        graphics.outline(.{
            .x = bounds.x - thickness,
            .y = bounds.y - thickness,
            .width = bounds.width + 2 * thickness,
            .height = bounds.height + 2 * thickness,
        }, thickness, color);
        return;
    }
    const left = bounds.x + radius;
    const right = bounds.x + bounds.width - radius;
    const top = bounds.y + radius;
    const bottom = bounds.y + bounds.height - radius;
    const centers = [_]graphics.Point{
        .{ .x = left, .y = top },
        .{ .x = right, .y = top },
        .{ .x = right, .y = bottom },
        .{ .x = left, .y = bottom },
    };
    // Quarter-circle starts follow the top-left, top-right, bottom-right, bottom-left corners.
    const angles = [_]f32{
        180,
        270,
        0,
        90,
    };
    const segments = cornerSegments(radius + thickness, desktop.scale());
    // Filled ring sectors retain stroke thickness through the display transform.
    for (centers, angles) |center, angle| {
        graphics.ring(center, radius, radius + thickness, angle, angle + 90, segments, color);
    }
    const edges = [_]graphics.Rect{
        .{
            .x = left,
            .y = bounds.y - thickness,
            .width = right - left,
            .height = thickness,
        },
        .{
            .x = bounds.x + bounds.width,
            .y = top,
            .width = thickness,
            .height = bottom - top,
        },
        .{
            .x = left,
            .y = bounds.y + bounds.height,
            .width = right - left,
            .height = thickness,
        },
        .{
            .x = bounds.x - thickness,
            .y = top,
            .width = thickness,
            .height = bottom - top,
        },
    };
    for (edges) |edge| graphics.rectangle(edge, color);
}

/// Draws evenly spaced round dots outside bounds, in logical pixels.
pub fn drawRectangleDots(bounds: graphics.Rect, roundness: f32, thickness: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0 or thickness <= 0) return;
    const radius = @min(bounds.width, bounds.height) * std.math.clamp(roundness, 0, 1) / 2;
    const path_radius = radius + thickness / 2;
    const horizontal = bounds.width - 2 * radius;
    const vertical = bounds.height - 2 * radius;
    const arc = std.math.pi / 2.0 * path_radius;
    const perimeter = 2 * (horizontal + vertical) + 4 * arc;
    // Three stroke widths between dot centers keeps gaps visible; retain at least four dots.
    const count = @max(4, @ceil(perimeter / (3 * thickness)));
    const spacing = perimeter / count;
    const centers = [_]graphics.Point{
        .{ .x = bounds.x + bounds.width - radius, .y = bounds.y + radius },
        .{ .x = bounds.x + bounds.width - radius, .y = bounds.y + bounds.height - radius },
        .{ .x = bounds.x + radius, .y = bounds.y + bounds.height - radius },
        .{ .x = bounds.x + radius, .y = bounds.y + radius },
    };
    const lengths = [_]f32{
        horizontal,
        vertical,
        horizontal,
        vertical,
    };
    var distance: f32 = spacing / 2;
    for (centers, lengths, 0..) |center, length, side| {
        const angle = (@as(f32, @floatFromInt(side)) - 1) * (std.math.pi / 2.0);
        const radial = graphics.Point{ .x = @cos(angle), .y = @sin(angle) };
        const tangent = graphics.Point{ .x = -radial.y, .y = radial.x };
        const end = center.add(radial.scale(path_radius));
        while (distance < length) : (distance += spacing) {
            drawCircle(end.subtract(tangent.scale(length - distance)), thickness / 2, color);
        }
        distance -= length;
        while (distance < arc) : (distance += spacing) {
            const dot_angle = angle + distance / path_radius;
            drawCircle(center.add(.{
                .x = @cos(dot_angle) * path_radius,
                .y = @sin(dot_angle) * path_radius,
            }), thickness / 2, color);
        }
        distance -= arc;
    }
}

/// Fills a circle without rounding its center to integer coordinates.
pub fn drawCircle(center: graphics.Point, radius: f32, color: graphics.Color) void {
    if (radius <= 0) return;
    const segments = 4 * cornerSegments(radius, desktop.scale());
    graphics.sector(center, radius, 0, 360, segments, color);
}

/// Centers an outline on radius, with thickness measured in logical pixels.
pub fn drawCircleLines(center: graphics.Point, radius: f32, thickness: f32, color: graphics.Color) void {
    if (radius <= 0 or thickness <= 0) return;
    const outer = radius + thickness / 2;
    const segments = 4 * cornerSegments(outer, desktop.scale());
    graphics.ring(center, @max(0, radius - thickness / 2), outer, 0, 360, segments, color);
}

fn cornerSegments(radius: f32, dpi: graphics.Point) i32 {
    const physical_radius = radius * @max(1, @max(dpi.x, dpi.y));
    // Bound each chord's deviation from the curve to 1/8 of a physical pixel:
    // r * (1 - cos(pi / (4*n))) <= r * pi² / (32*n²).
    return @intFromFloat(@max(8, @ceil(std.math.pi / 2.0 * @sqrt(physical_radius))));
}

/// Two rotating arrows, with time supplied by the frame clock in seconds.
pub fn drawRefresh(center: graphics.Point, seconds: f64, color: graphics.Color) void {
    // 300 degrees per second completes a turn in 1.2 seconds for a gentle activity indicator.
    const rotation: f32 = @floatCast(@mod(seconds, 1.2) * 300);
    for ([_]f32{ 0, 180 }) |offset| {
        // Two 135-degree arcs leave gaps for arrowheads instead of forming a solid ring.
        const end = rotation + offset + 135;
        // A 1.5-pixel stroke at radius six fits the status line; 20 segments smooth each arc.
        graphics.ring(center, 4.5, 6, rotation + offset, end, 20, color);
        const angle = std.math.degreesToRadians(end);
        const radial = graphics.Point{ .x = @cos(angle), .y = @sin(angle) };
        const tangent = graphics.Point{ .x = -radial.y, .y = radial.x };
        const tip = center.add(radial.scale(5.25)).add(tangent.scale(2));
        const base = center.add(radial.scale(5.25)).subtract(tangent.scale(1));
        graphics.triangle(tip, base.add(radial.scale(2.5)), base.subtract(radial.scale(2.5)), color);
    }
}

test "refresh arrows visibly rotate at fractional display scales" {
    try openWindow(640, 480, "Zimbr sync animation checks");
    defer closeWindow();
    desktop.poll();
    for (0..4) |_| {
        graphics.beginFrame();
        graphics.clear(graphics.Color.black);
        graphics.endFrame();
    }
    for ([_]f32{
        1,
        1.25,
        2,
    }) |scale| {
        var frames: [2]graphics.Image = undefined;
        for (&frames, [_]f64{ 0, 0.15 }) |*frame, seconds| {
            graphics.beginFrame();
            graphics.clear(graphics.Color.black);
            graphics.setScale(scale);
            drawRefresh(.{ .x = 40, .y = 40 }, seconds, graphics.Color.white);
            graphics.resetScale();
            graphics.flush();
            frame.* = try graphics.capture();
            graphics.endFrame();
        }
        defer for (frames) |frame| graphics.destroyImage(frame);
        var changed: usize = 0;
        var ink: usize = 0;
        var y: i32 = @intFromFloat(30 * scale);
        while (y < @as(i32, @intFromFloat(50 * scale))) : (y += 1) {
            var x: i32 = @intFromFloat(30 * scale);
            while (x < @as(i32, @intFromFloat(50 * scale))) : (x += 1) {
                const first = frames[0].color(x, y);
                const second = frames[1].color(x, y);
                if (first.r > 0) ink += 1;
                if (!std.meta.eql(first, second)) changed += 1;
            }
        }
        try std.testing.expect(ink > 25);
        try std.testing.expect(changed > 20);
    }
}

test "rounded outlines retain their thickness and smooth edges under display scaling" {
    try openWindow(640, 480, "Zimbr rounded shape checks");
    defer closeWindow();
    desktop.poll();
    for (0..4) |_| {
        graphics.beginFrame();
        graphics.clear(graphics.Color.black);
        graphics.endFrame();
    }

    for ([_]f32{
        1,
        1.25,
        2,
    }) |zoom| {
        graphics.beginFrame();
        graphics.clear(graphics.Color.black);
        graphics.setScale(zoom);
        drawRectangleLines(.{
            .x = 20,
            .y = 20,
            .width = 120,
            .height = 60,
        }, 0.5, 1, graphics.Color.white);
        drawCircleLines(.{ .x = 200, .y = 40 }, 10, 1, graphics.Color.white);
        drawRectangle(.{
            .x = 20,
            .y = 100,
            .width = 80,
            .height = 28,
        }, 1, graphics.Color.white);
        drawCircle(.{ .x = 120, .y = 110 }, 3, graphics.Color.white);
        graphics.resetScale();
        graphics.flush();
        const shot = try graphics.capture();
        graphics.endFrame();
        defer graphics.destroyImage(shot);

        // The explicit transform uses zoom as the physical scale.
        const scale = zoom;
        var top_coverage: f32 = 0;
        var side_coverage: f32 = 0;
        var ring_coverage: f32 = 0;
        var p: i32 = @intFromFloat(@floor(16 * scale));
        while (p < @as(i32, @intFromFloat(@ceil(24 * scale)))) : (p += 1) {
            const top = shot.color(@intFromFloat(80 * scale), p);
            const side = shot.color(p, @intFromFloat(50 * scale));
            top_coverage += @as(f32, @floatFromInt(top.r)) / 255;
            side_coverage += @as(f32, @floatFromInt(side.r)) / 255;
        }
        p = @intFromFloat(@floor(26 * scale));
        while (p < @as(i32, @intFromFloat(@ceil(34 * scale)))) : (p += 1) {
            const ring = shot.color(@intFromFloat(200 * scale), p);
            ring_coverage += @as(f32, @floatFromInt(ring.r)) / 255;
        }
        try std.testing.expectApproxEqAbs(scale, top_coverage, 0.3);
        try std.testing.expectApproxEqAbs(scale, side_coverage, 0.3);
        try std.testing.expectApproxEqAbs(scale, ring_coverage, 0.3);

        // Look only at the pill's curved corner, away from straight edges.
        var blended: usize = 0;
        var y: i32 = @intFromFloat(100 * scale);
        while (y < @as(i32, @intFromFloat(114 * scale))) : (y += 1) {
            var x: i32 = @intFromFloat(20 * scale);
            while (x < @as(i32, @intFromFloat(34 * scale))) : (x += 1) {
                const red = shot.color(x, y).r;
                if (red > 0 and red < 255) blended += 1;
            }
        }
        try std.testing.expect(blended > 0);
        try std.testing.expectEqual(graphics.Color.white, shot.color(
            @intFromFloat(60 * scale),
            @intFromFloat(114 * scale),
        ));
        try std.testing.expectEqual(graphics.Color.black, shot.color(
            @intFromFloat(20 * scale),
            @intFromFloat(100 * scale),
        ));
    }
}

fn openWindow(width: i32, height: i32, title: [:0]const u8) !void {
    try desktop.open(width, height, title);
    errdefer desktop.close();
    try graphics.init();
}
fn closeWindow() void {
    graphics.deinit();
    desktop.close();
}
