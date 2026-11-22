//! Native SDL input and capture, with SDL_Renderer and OpenGL window support.
const std = @import("std");
const registry = @import("registry.zig");
const c = @import("desktop_c");
const a = std.heap.page_allocator;
pub const Renderer = struct {
    /// Borrowed SDL_Window for consumers without a current OpenGL context.
    window: ?*anyopaque = null,
    flush: ?*const fn () void = null,
    overlay: ?*const fn (registry.Rect, []const u8) void = null,
};
pub var renderer: ?Renderer = null;
pub const queued = true;
pub const Key = @import("keys.zig").Key;
pub fn window() ?*c.SDL_Window {
    if (renderer) |hooks| if (hooks.window) |handle| return @ptrCast(handle);
    return c.SDL_GL_GetCurrentWindow();
}
pub fn width() i32 {
    var n: c_int = 0;
    _ = c.SDL_GetWindowSize(window(), &n, null);
    return n;
}
pub fn height() i32 {
    var n: c_int = 0;
    _ = c.SDL_GetWindowSize(window(), null, &n);
    return n;
}
pub fn scale() f32 {
    var n: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window(), &n, null);
    return @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(@max(1, width())));
}
pub fn resize(w: i32, h: i32) !void {
    if (!c.SDL_SetWindowSize(window(), w, h)) return error.ResizeRejected;
}
var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var button_down = false;
var held: [256]bool = @splat(false);

pub fn motion(x: f32, y: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.motion.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.windowID = c.SDL_GetWindowID(window());
    event.motion.x = x;
    event.motion.y = y;
    event.motion.xrel = x - mouse_x;
    event.motion.yrel = y - mouse_y;
    event.motion.state = if (button_down) c.SDL_BUTTON_LMASK else 0;
    try push(&event);
    mouse_x = x;
    mouse_y = y;
}
pub fn button(down: bool) !void {
    return clickButton(down, 1);
}
pub fn clickButton(down: bool, clicks: u8) !void {
    if (down == button_down) return;
    var event = std.mem.zeroes(c.SDL_Event);
    event.button.type = if (down) c.SDL_EVENT_MOUSE_BUTTON_DOWN else c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.windowID = c.SDL_GetWindowID(window());
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.down = down;
    event.button.clicks = clicks;
    event.button.x = mouse_x;
    event.button.y = mouse_y;
    try push(&event);
    button_down = down;
}
var modifiers: c.SDL_Keymod = 0;
pub fn key(value: Key, down: bool) !void {
    return keyEvent(value, down, false);
}
pub fn keyEvent(value: Key, down: bool, repeat: bool) !void {
    const index: usize = @intCast(@backingInt(value));
    if (!repeat and held[index] == down) return;
    if (repeat and !held[index]) return error.KeyNotHeld;
    const bit: c.SDL_Keymod = switch (value) {
        .left_control => c.SDL_KMOD_LCTRL,
        .right_control => c.SDL_KMOD_RCTRL,
        .left_shift => c.SDL_KMOD_LSHIFT,
        .right_shift => c.SDL_KMOD_RSHIFT,
        .left_alt => c.SDL_KMOD_LALT,
        .right_alt => c.SDL_KMOD_RALT,
        .left_super => c.SDL_KMOD_LGUI,
        .right_super => c.SDL_KMOD_RGUI,
        else => 0,
    };
    const next_modifiers = if (down) modifiers | bit else modifiers & ~bit;
    var event = std.mem.zeroes(c.SDL_Event);
    event.key.type = if (down) c.SDL_EVENT_KEY_DOWN else c.SDL_EVENT_KEY_UP;
    event.key.windowID = c.SDL_GetWindowID(window());
    event.key.scancode = @intCast(@backingInt(value));
    event.key.key = c.SDL_GetKeyFromScancode(event.key.scancode, next_modifiers, true);
    event.key.mod = next_modifiers;
    event.key.down = down;
    event.key.repeat = repeat;
    try push(&event);
    modifiers = next_modifiers;
    held[index] = down;
}
pub fn wheel(x: f32, y: f32) !void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.wheel.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.windowID = c.SDL_GetWindowID(window());
    event.wheel.mouse_x = mouse_x;
    event.wheel.mouse_y = mouse_y;
    event.wheel.x = x;
    event.wheel.y = y;
    try push(&event);
}
pub const Image = struct {
    width: i32,
    height: i32,
    pixels: []u8,
    pub fn deinit(image: Image) void {
        a.free(image.pixels);
    }
};
pub fn capture() !Image {
    const hooks = renderer orelse return error.RendererUnavailable;
    if (hooks.flush) |flush| flush();
    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.SDL_GetWindowSizeInPixels(window(), &w, &h) or w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidDimensions;
    if (c.SDL_GetRenderer(window())) |native| return captureRenderer(native);
    const address = c.SDL_GL_GetProcAddress("glReadPixels") orelse return error.CaptureUnavailable;
    const read: *const fn (c_int, c_int, c_int, c_int, c_uint, c_uint, *anyopaque) callconv(.c) void = @ptrCast(address);
    const stride = @as(usize, @intCast(w)) * 4;
    const pixels = try a.alloc(u8, stride * @as(usize, @intCast(h)));
    read(0, 0, w, h, 0x1908, 0x1401, pixels.ptr);
    for (0..@intCast(@divTrunc(h, 2))) |y| {
        const top = pixels[y * stride ..][0..stride];
        const bottom = pixels[(@as(usize, @intCast(h)) - y - 1) * stride ..][0..stride];
        for (top, bottom) |*p, *q| std.mem.swap(u8, p, q);
    }
    var i: usize = 3;
    while (i < pixels.len) : (i += 4) pixels[i] = 255;
    return .{ .width = w, .height = h, .pixels = pixels };
}
pub fn overlay(bounds: registry.Rect, label: []const u8) void {
    if (renderer) |hooks| if (hooks.overlay) |draw| draw(bounds, label);
}

fn captureRenderer(native: *c.SDL_Renderer) !Image {
    if (c.SDL_GetRenderTarget(native) != null) return error.CaptureTargetNotWindow;
    const source: *c.SDL_Surface = c.SDL_RenderReadPixels(native, null) orelse return error.CaptureUnavailable;
    defer c.SDL_DestroySurface(source);
    const rgba: *c.SDL_Surface = c.SDL_ConvertSurface(source, c.SDL_PIXELFORMAT_RGBA32) orelse return error.CaptureUnavailable;
    defer c.SDL_DestroySurface(rgba);
    if (rgba.w <= 0 or rgba.h <= 0 or rgba.w > 16384 or rgba.h > 16384) return error.InvalidDimensions;
    const stride = @as(usize, @intCast(rgba.w)) * 4;
    const row_count: usize = @intCast(rgba.h);
    const pixels = try a.alloc(u8, stride * row_count);
    const bytes: [*]const u8 = @ptrCast(rgba.pixels.?);
    for (0..row_count) |y| @memcpy(pixels[y * stride ..][0..stride], bytes[y * @as(usize, @intCast(rgba.pitch)) ..][0..stride]);
    return .{ .width = rgba.w, .height = rgba.h, .pixels = pixels };
}

pub fn renderingInfo(name: c_uint) ?[]const u8 {
    const native = c.SDL_GetRenderer(window()) orelse return null;
    return switch (name) {
        0x1f00 => "SDL",
        0x1f01 => if (c.SDL_GetRendererName(native)) |value| std.mem.span(value) else "unavailable",
        0x1f02 => "SDL3",
        else => null,
    };
}

fn push(event: *c.SDL_Event) !void {
    if (window() == null) return error.WindowUnavailable;
    if (!c.SDL_PushEvent(event)) return error.EventRejected;
}

pub fn releaseAll() void {
    button(false) catch {};
    inline for (@import("keys.zig").entries) |entry| key(@fromBackingInt(@intCast(entry.scancode)), false) catch {};
}

pub fn reset() void {
    renderer = null;
    mouse_x = 0;
    mouse_y = 0;
    button_down = false;
    held = @splat(false);
    modifiers = 0;
}

pub fn rendering() struct {
    sdl_version: c_int,
    video_driver: []const u8,
    backend: []const u8,
    logical_width: i32,
    logical_height: i32,
    pixel_width: i32,
    pixel_height: i32,
    pixel_format: []const u8,
    red_bits: ?c_int,
    green_bits: ?c_int,
    blue_bits: ?c_int,
    alpha_bits: ?c_int,
    samples: ?c_int,
} {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window(), &w, &h);
    return .{
        .sdl_version = c.SDL_GetVersion(),
        .video_driver = if (c.SDL_GetCurrentVideoDriver()) |name| std.mem.span(name) else "unavailable",
        .backend = if (c.SDL_GetRenderer(window())) |native| std.mem.span(c.SDL_GetRendererName(native)) else "opengl",
        .logical_width = width(),
        .logical_height = height(),
        .pixel_width = w,
        .pixel_height = h,
        .pixel_format = std.mem.span(c.SDL_GetPixelFormatName(c.SDL_GetWindowPixelFormat(window()))),
        .red_bits = glAttribute(c.SDL_GL_RED_SIZE),
        .green_bits = glAttribute(c.SDL_GL_GREEN_SIZE),
        .blue_bits = glAttribute(c.SDL_GL_BLUE_SIZE),
        .alpha_bits = glAttribute(c.SDL_GL_ALPHA_SIZE),
        .samples = glAttribute(c.SDL_GL_MULTISAMPLESAMPLES),
    };
}
fn glAttribute(attribute: c.SDL_GLAttr) ?c_int {
    if (c.SDL_GetRenderer(window()) != null) return null;
    var value: c_int = 0;
    return if (c.SDL_GL_GetAttribute(attribute, &value)) value else null;
}
