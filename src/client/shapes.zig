//! Antialiased logical UI paths submitted as indexed SDL geometry.
const std = @import("std");
const desktop = @import("desktop.zig");
const graphics = @import("graphics.zig");

const Path = struct {
    // At most 64 chords per quarter circle; shared endpoints also join straight edges.
    points: [260]graphics.Point = undefined,
    normals: [260]graphics.Point = undefined,
    count: usize = 0,
    closed: bool = true,

    fn arc(path: *Path, center: graphics.Point, radius: f32, start: f32, end: f32, segments: usize) void {
        for (0..segments + 1) |i| {
            const angle = start + (end - start) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const normal = graphics.Point{ .x = @cos(angle), .y = @sin(angle) };
            path.points[path.count] = center.add(normal.scale(radius));
            path.normals[path.count] = normal;
            path.count += 1;
        }
    }
};

fn cornerSegments(radius: f32) usize {
    const scale = graphics.scale();
    const physical_radius = radius * @max(scale.x, scale.y);
    // Bound chord deviation to 1/8 pixel for ordinary UI radii.
    return @intFromFloat(std.math.clamp(@ceil(std.math.pi / 2.0 * @sqrt(physical_radius)), 8, 64));
}

fn roundedPath(bounds: graphics.Rect, requested_radius: f32) Path {
    const radius = std.math.clamp(requested_radius, 0, @min(bounds.width, bounds.height) / 2);
    const centers = [_]graphics.Point{
        .{ .x = bounds.x + radius, .y = bounds.y + radius },
        .{ .x = bounds.x + bounds.width - radius, .y = bounds.y + radius },
        .{ .x = bounds.x + bounds.width - radius, .y = bounds.y + bounds.height - radius },
        .{ .x = bounds.x + radius, .y = bounds.y + bounds.height - radius },
    };
    var path = Path{};
    for (centers, 0..) |center, i| {
        const start = std.math.pi + @as(f32, @floatFromInt(i)) * std.math.pi / 2.0;
        path.arc(center, radius, start, start + std.math.pi / 2.0, cornerSegments(radius));
    }
    return path;
}

fn expanded(bounds: graphics.Rect, amount: f32) graphics.Rect {
    return .{
        .x = bounds.x - amount,
        .y = bounds.y - amount,
        .width = bounds.width + 2 * amount,
        .height = bounds.height + 2 * amount,
    };
}

/// Fill bounds with a corner radius measured in logical pixels, clamped to half the shorter side.
pub fn drawRectangle(bounds: graphics.Rect, radius: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0) return;
    if (radius <= 0) return graphics.rectangle(bounds, color);
    paint(roundedPath(bounds, radius), null, color);
}

/// Draw an outline outside bounds. Radius and thickness are logical pixels.
pub fn drawRectangleLines(bounds: graphics.Rect, radius: f32, thickness: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0 or thickness <= 0) return;
    paint(roundedPath(expanded(bounds, thickness / 2), radius + thickness / 2), thickness, color);
}

// Each contour has a half-pixel coverage fringe on either side of its geometric
// boundary. SDL interpolates coverage in vertex alpha, independent of backend MSAA.
fn paint(path: Path, stroke: ?f32, color: graphics.Color) void {
    var vertices: [1041]graphics.Vertex = undefined;
    var indices: [6240]u16 = undefined;
    const scale = graphics.scale();
    const n = path.count;
    const bands: usize = if (stroke != null) 4 else 2;
    for (path.points[0..n], path.normals[0..n], 0..) |point, normal, i| {
        const physical_normal = graphics.Point{ .x = normal.x / scale.x, .y = normal.y / scale.y };
        const fringe = physical_normal.scale(0.5);
        for (0..bands) |band| {
            var tint = color;
            const position = if (stroke) |width| position: {
                const outer = band >= 2;
                const covered = band == 1 or band == 2;
                const half = normal.scale(width / 2);
                const edge = if (outer) point.add(half) else point.subtract(half);
                if (!covered) tint.a = 0;
                break :position if (band == 0 or band == 2) edge.subtract(fringe) else edge.add(fringe);
            } else position: {
                if (band == 1) tint.a = 0;
                break :position if (band == 0) point.subtract(fringe) else point.add(fringe);
            };
            vertices[band * n + i] = graphics.vertex(position, .{ .x = 0, .y = 0 }, tint);
        }
    }
    var count: usize = 0;
    const edges = if (path.closed) n else n - 1;
    for (0..bands - 1) |band| for (0..edges) |i| {
        const next = (i + 1) % n;
        const a: u16 = @intCast(band * n + i);
        const b: u16 = @intCast(band * n + next);
        const c: u16 = @intCast((band + 1) * n + i);
        const d: u16 = @intCast((band + 1) * n + next);
        indices[count..][0..6].* = .{
            a,
            b,
            d,
            a,
            d,
            c,
        };
        count += 6;
    };
    if (stroke == null) {
        var center = graphics.Point{ .x = 0, .y = 0 };
        for (path.points[0..n]) |point| center = center.add(point.scale(1 / @as(f32, @floatFromInt(n))));
        vertices[bands * n] = graphics.vertex(center, .{ .x = 0, .y = 0 }, color);
        for (0..n) |i| {
            indices[count..][0..3].* = .{
                @intCast(bands * n),
                @intCast(i),
                @intCast((i + 1) % n),
            };
            count += 3;
        }
    }
    graphics.mesh(null, vertices[0 .. bands * n + @intFromBool(stroke == null)], indices[0..count]);
}

/// Fill a circle without rounding its center to integer coordinates.
pub fn drawCircle(center: graphics.Point, radius: f32, color: graphics.Color) void {
    if (radius <= 0) return;
    var path = Path{};
    path.arc(center, radius, 0, 2 * std.math.pi, 4 * cornerSegments(radius));
    paint(path, null, color);
}

/// Center an outline on radius, with thickness measured in logical pixels.
pub fn drawCircleLines(center: graphics.Point, radius: f32, thickness: f32, color: graphics.Color) void {
    if (radius <= 0 or thickness <= 0) return;
    if (thickness >= 2 * radius) return drawCircle(center, radius + thickness / 2, color);
    var path = Path{};
    path.arc(center, radius, 0, 2 * std.math.pi, 4 * cornerSegments(radius));
    paint(path, thickness, color);
}

/// Draws evenly spaced round dots outside bounds, in logical pixels.
pub fn drawRectangleDots(bounds: graphics.Rect, requested_radius: f32, thickness: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0 or thickness <= 0) return;
    const radius = std.math.clamp(requested_radius, 0, @min(bounds.width, bounds.height) / 2);
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

/// Two rotating arrows, with time supplied by the frame clock in seconds.
pub fn drawRefresh(center: graphics.Point, seconds: f64, color: graphics.Color) void {
    // 300 degrees per second completes a turn in 1.2 seconds for a gentle activity indicator.
    const rotation: f32 = @floatCast(@mod(seconds, 1.2) * 300);
    for ([_]f32{ 0, 180 }) |offset| {
        // Two 135-degree arcs leave gaps for arrowheads instead of forming a solid ring.
        const end = rotation + offset + 135;
        // A 1.5-pixel stroke at radius six fits the status line; 20 segments smooth each arc.
        var path = Path{ .closed = false };
        path.arc(center, 5.25, std.math.degreesToRadians(rotation + offset), std.math.degreesToRadians(end), 20);
        paint(path, 1.5, color);
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
                const first = graphics.imageColor(frames[0], x, y);
                const second = graphics.imageColor(frames[1], x, y);
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
        }, 15, 1, graphics.Color.white);
        drawCircleLines(.{ .x = 200, .y = 40 }, 10, 1, graphics.Color.white);
        drawRectangle(.{
            .x = 20,
            .y = 100,
            .width = 80,
            .height = 28,
        }, 14, graphics.Color.white);
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
            const top = graphics.imageColor(shot, @intFromFloat(80 * scale), p);
            const side = graphics.imageColor(shot, p, @intFromFloat(50 * scale));
            top_coverage += @as(f32, @floatFromInt(top.r)) / 255;
            side_coverage += @as(f32, @floatFromInt(side.r)) / 255;
        }
        p = @intFromFloat(@floor(26 * scale));
        while (p < @as(i32, @intFromFloat(@ceil(34 * scale)))) : (p += 1) {
            const ring = graphics.imageColor(shot, @intFromFloat(200 * scale), p);
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
                const red = graphics.imageColor(shot, x, y).r;
                if (red > 0 and red < 255) blended += 1;
            }
        }
        try std.testing.expect(blended > 0);
        try std.testing.expectEqual(graphics.Color.white, graphics.imageColor(
            shot,
            @intFromFloat(60 * scale),
            @intFromFloat(114 * scale),
        ));
        try std.testing.expectEqual(graphics.Color.black, graphics.imageColor(
            shot,
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
