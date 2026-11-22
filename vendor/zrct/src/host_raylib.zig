//! Existing raylib consumers retain their native snapshot and rendering boundary.
const std = @import("std");
const rl = @import("raylib");
const registry = @import("registry.zig");
pub const Key = rl.KeyboardKey;
pub const queued = false;
pub fn width() i32 {
    return rl.getScreenWidth();
}
pub fn height() i32 {
    return rl.getScreenHeight();
}
pub fn scale() f32 {
    return rl.getWindowScaleDPI().x;
}
pub fn resize(w: i32, h: i32) !void {
    rl.setWindowSize(w, h);
}
fn event(kind: u32, p0: i32, p1: i32) void {
    rl.playAutomationEvent(.{ .frame = 0, .type = kind, .params = .{ p0, p1, 0, 0 } });
}
pub fn motion(x: f32, y: f32) !void {
    event(7, @intFromFloat(x), @intFromFloat(y));
}
pub fn button(down: bool) !void {
    event(if (down) 6 else 5, 0, 0);
}
pub fn key(value: Key, down: bool) !void {
    event(if (down) 2 else 1, @backingInt(value), 0);
}
pub fn wheel(x: f32, y: f32) !void {
    event(8, @intFromFloat(x), @intFromFloat(y));
}
pub const Image = struct {
    image: rl.Image,
    width: i32,
    height: i32,
    pixels: []const u8,
    pub fn deinit(image: Image) void {
        rl.unloadImage(image.image);
    }
};
pub fn capture() !Image {
    rl.gl.rlDrawRenderBatchActive();
    const shot = try rl.loadImageFromScreen();
    errdefer rl.unloadImage(shot);
    if (shot.width <= 0 or shot.height <= 0 or shot.format != .uncompressed_r8g8b8a8) return error.InvalidCapture;
    const pixels: [*]const u8 = @ptrCast(shot.data);
    return .{ .image = shot, .width = shot.width, .height = shot.height, .pixels = pixels[0 .. @as(usize, @intCast(shot.width)) * @as(usize, @intCast(shot.height)) * 4] };
}
pub fn overlay(bounds: registry.Rect, label: []const u8) void {
    rl.drawRectangleLines(@intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.width), @intFromFloat(bounds.height), .green);
    const text = std.heap.page_allocator.dupeSentinel(u8, label, 0) catch return;
    defer std.heap.page_allocator.free(text);
    rl.drawText(text, @intFromFloat(bounds.x), @intFromFloat(bounds.y), 12, .yellow);
}
