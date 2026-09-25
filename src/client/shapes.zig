//! Rounded UI geometry rendered into the multisampled window framebuffer.
const std = @import("std");
const rl = @import("raylib");

/// Fills bounds, with roundness clamped to 0–1 as in raylib.
pub fn drawRectangle(bounds: rl.Rectangle, roundness: f32, color: rl.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0) return;
    const radius = @min(bounds.width, bounds.height) * std.math.clamp(roundness, 0, 1) / 2;
    rl.drawRectangleRounded(bounds, roundness, cornerSegments(radius, rl.getWindowScaleDPI()), color);
}

/// Draws an outline outside bounds, with thickness measured in logical pixels.
pub fn drawRectangleLines(bounds: rl.Rectangle, roundness: f32, thickness: f32, color: rl.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0 or thickness <= 0) return;
    const radius = @min(bounds.width, bounds.height) * std.math.clamp(roundness, 0, 1) / 2;
    if (radius == 0) {
        rl.drawRectangleLinesEx(.{
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
    const centers = [_]rl.Vector2{
        .{ .x = left, .y = top },
        .{ .x = right, .y = top },
        .{ .x = right, .y = bottom },
        .{ .x = left, .y = bottom },
    };
    const angles = [_]f32{
        180,
        270,
        0,
        90,
    };
    const segments = cornerSegments(radius + thickness, rl.getWindowScaleDPI());
    // Raylib's thin rounded outlines use GL_LINES, whose one-pixel width does
    // not follow the display transform. Filled ring sectors scale with the UI.
    for (centers, angles) |center, angle| {
        rl.drawRing(center, radius, radius + thickness, angle, angle + 90, segments, color);
    }
    const edges = [_]rl.Rectangle{
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
    for (edges) |edge| rl.drawRectangleRec(edge, color);
}

/// Fills a circle without rounding its center to integer coordinates.
pub fn drawCircle(center: rl.Vector2, radius: f32, color: rl.Color) void {
    if (radius <= 0) return;
    const segments = 4 * cornerSegments(radius, rl.getWindowScaleDPI());
    rl.drawCircleSector(center, radius, 0, 360, segments, color);
}

/// Centers an outline on radius, with thickness measured in logical pixels.
pub fn drawCircleLines(center: rl.Vector2, radius: f32, thickness: f32, color: rl.Color) void {
    if (radius <= 0 or thickness <= 0) return;
    const outer = radius + thickness / 2;
    const segments = 4 * cornerSegments(outer, rl.getWindowScaleDPI());
    rl.drawRing(center, @max(0, radius - thickness / 2), outer, 0, 360, segments, color);
}

fn cornerSegments(radius: f32, dpi: rl.Vector2) i32 {
    const physical_radius = radius * @max(1, @max(dpi.x, dpi.y));
    // Bound each chord's deviation from the curve to 1/8 of a physical pixel:
    // r * (1 - cos(pi / (4*n))) <= r * pi² / (32*n²).
    return @intFromFloat(@max(8, @ceil(std.math.pi / 2.0 * @sqrt(physical_radius))));
}

test "rounded outlines retain their thickness and smooth edges under display scaling" {
    rl.setTraceLogLevel(.none);
    rl.setConfigFlags(.{ .window_highdpi = true, .msaa_4x_hint = true });
    rl.initWindow(640, 480, "Zimbr rounded shape checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    for (0..4) |_| {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.black);
        rl.endDrawing();
    }

    for ([_]f32{
        1,
        1.25,
        2,
    }) |zoom| {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.black);
        rl.beginMode2D(.{
            .offset = .{ .x = 0, .y = 0 },
            .target = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .zoom = zoom,
        });
        drawRectangleLines(.{
            .x = 20,
            .y = 20,
            .width = 120,
            .height = 60,
        }, 0.5, 1, rl.Color.white);
        drawCircleLines(.{ .x = 200, .y = 40 }, 10, 1, rl.Color.white);
        drawRectangle(.{
            .x = 20,
            .y = 100,
            .width = 80,
            .height = 28,
        }, 1, rl.Color.white);
        drawCircle(.{ .x = 120, .y = 110 }, 3, rl.Color.white);
        rl.endMode2D();
        rl.gl.rlDrawRenderBatchActive();
        const shot = try rl.loadImageFromScreen();
        rl.endDrawing();
        defer rl.unloadImage(shot);

        // BeginMode2D replaces the window transform, so zoom is the physical scale.
        const scale = zoom;
        var top_coverage: f32 = 0;
        var side_coverage: f32 = 0;
        var ring_coverage: f32 = 0;
        var p: i32 = @intFromFloat(@floor(16 * scale));
        while (p < @as(i32, @intFromFloat(@ceil(24 * scale)))) : (p += 1) {
            const top = rl.getImageColor(shot, @intFromFloat(80 * scale), p);
            const side = rl.getImageColor(shot, p, @intFromFloat(50 * scale));
            top_coverage += @as(f32, @floatFromInt(top.r)) / 255;
            side_coverage += @as(f32, @floatFromInt(side.r)) / 255;
        }
        p = @intFromFloat(@floor(26 * scale));
        while (p < @as(i32, @intFromFloat(@ceil(34 * scale)))) : (p += 1) {
            const ring = rl.getImageColor(shot, @intFromFloat(200 * scale), p);
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
                const red = rl.getImageColor(shot, x, y).r;
                if (red > 0 and red < 255) blended += 1;
            }
        }
        try std.testing.expect(blended > 0);
        try std.testing.expectEqual(rl.Color.white, rl.getImageColor(
            shot,
            @intFromFloat(60 * scale),
            @intFromFloat(114 * scale),
        ));
        try std.testing.expectEqual(rl.Color.black, rl.getImageColor(
            shot,
            @intFromFloat(20 * scale),
            @intFromFloat(100 * scale),
        ));
    }
}
