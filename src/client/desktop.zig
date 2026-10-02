//! SDL window, ordered events, clipboard, and worker wakeups for the GUI thread.
const std = @import("std");
const log = std.log.scoped(.client_desktop);
const geometry = @import("geometry.zig");
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("desktop.h");
});

pub const wake = c.zc_desktop_wake;
pub fn wait(timeout_ms: c_int) bool {
    return c.zc_desktop_wait(timeout_ms) != 0;
}
/// Wait for events for at most 25 ms, or finish the sub-millisecond frame remainder.
/// Returns whether a worker signaled readiness, just like wait.
pub fn waitNs(timeout_ns: u64) bool {
    if (timeout_ns >= std.time.ns_per_ms)
        return wait(@intCast(@min(25, timeout_ns / std.time.ns_per_ms)));
    // Rounding up SDL's millisecond timeout loses nearly a millisecond per frame.
    if (timeout_ns > 0) c.SDL_DelayNS(timeout_ns);
    return false;
}
pub fn activate(token: [*:0]const u8) bool {
    return c.zc_desktop_activate(token) != 0;
}
/// Borrowed until the next clipboard read or window shutdown. Null indicates an SDL error.
pub fn clipboardText() ?[]const u8 {
    const text = c.zc_desktop_clipboard();
    return if (text != null) std.mem.span(text) else null;
}
pub fn setClipboardText(text: [:0]const u8) void {
    _ = c.zc_desktop_set_clipboard(text);
}
pub fn resetTextInput(enabled: bool) void {
    c.zc_desktop_reset_input(@intFromBool(enabled));
}
/// Position native IME UI beside the visible caret in logical window coordinates.
pub fn textInputArea(caret: geometry.Rect) void {
    const rect = c.SDL_Rect{
        .x = @intFromFloat(@floor(caret.x)),
        .y = @intFromFloat(@floor(caret.y)),
        .w = @intFromFloat(@max(1, @ceil(caret.width))),
        .h = @intFromFloat(@max(1, @ceil(caret.height))),
    };
    _ = c.SDL_SetTextInputArea(window(), &rect, 0);
}

pub const OpenError = error{WindowUnavailable};
pub fn open(w: i32, h: i32, title: [:0]const u8) OpenError!void {
    if (c.zc_desktop_open(w, h, title) == 0) {
        log.err("SDL window: {s}", .{c.SDL_GetError()});
        return error.WindowUnavailable;
    }
    closing = false;
    pointer = .{ .x = 0, .y = 0 };
    buttons = 0;
    keys = .initEmpty();
    key_modifiers = 0;
    refreshMetrics();
}
pub fn close() void {
    for (&cursors) |*cursor| {
        if (cursor.*) |owned| c.SDL_DestroyCursor(owned);
        cursor.* = null;
    }
    c.zc_desktop_close();
}
pub fn window() ?*c.SDL_Window {
    return c.zc_desktop_window();
}
pub fn poll() void {
    if (window() == null) return;
    c.zc_desktop_poll();
    refreshMetrics();
}

pub const Metrics = struct {
    width: i32 = 0,
    height: i32 = 0,
    render_width: i32 = 0,
    render_height: i32 = 0,
    scale: f32 = 1,
    refresh_interval_ns: u64 = std.time.ns_per_s / 120,

    pub fn current() Metrics {
        return metrics;
    }
};
var metrics = Metrics{};
/// Snapshot the logical and physical window sizes once after processing events.
pub fn refreshMetrics() void {
    if (window() == null) return;
    _ = c.SDL_GetWindowSize(window(), &metrics.width, &metrics.height);
    _ = c.SDL_GetWindowSizeInPixels(window(), &metrics.render_width, &metrics.render_height);
    // Fractional framebuffer dimensions are rounded independently. Their ratios
    // vary during resize even on one display, moving geometry and invalidating text.
    metrics.scale = c.SDL_GetWindowDisplayScale(window());
    metrics.refresh_interval_ns = std.time.ns_per_s / 120;
    if (c.SDL_GetCurrentDisplayMode(c.SDL_GetDisplayForWindow(window()))) |mode| {
        const hz = mode.*.refresh_rate;
        if (std.math.isFinite(hz) and hz >= 1 and hz <= 1000)
            metrics.refresh_interval_ns = @intFromFloat(std.time.ns_per_s / @as(f64, hz));
    }
}
pub fn shouldClose() bool {
    return closing;
}
pub fn width() i32 {
    return metrics.width;
}
pub fn height() i32 {
    return metrics.height;
}
pub fn pixelWidth() i32 {
    return metrics.render_width;
}
pub fn pixelHeight() i32 {
    return metrics.render_height;
}
pub fn scale() geometry.Point {
    return .{
        .x = metrics.scale,
        .y = metrics.scale,
    };
}
pub fn setSize(w: i32, h: i32) void {
    _ = c.SDL_SetWindowSize(window(), w, h);
    refreshMetrics();
}
pub fn setMinSize(w: i32, h: i32) void {
    _ = c.SDL_SetWindowMinimumSize(window(), w, h);
}
pub fn focused() bool {
    return c.SDL_GetWindowFlags(window()) & c.SDL_WINDOW_INPUT_FOCUS != 0;
}
pub fn minimized() bool {
    return c.SDL_GetWindowFlags(window()) & c.SDL_WINDOW_MINIMIZED != 0;
}
pub fn restore() void {
    _ = c.SDL_RestoreWindow(window());
}
pub fn raise() void {
    _ = c.SDL_RaiseWindow(window());
}
pub fn time() f64 {
    return @as(f64, @floatFromInt(c.SDL_GetTicksNS())) / 1e9;
}
pub fn sleep(seconds: f64) void {
    c.SDL_DelayNS(@intFromFloat(@max(0, seconds) * 1e9));
}
pub const ticks = c.SDL_GetTicksNS;
/// Present the completed frame. Event processing and waiting belong to the main loop.
pub fn present() void {
    _ = c.SDL_RenderPresent(c.SDL_GetRenderer(window()));
}
pub const Key = enum(c.SDL_Keycode) {
    a = c.SDLK_A,
    b = c.SDLK_B,
    c = c.SDLK_C,
    d = c.SDLK_D,
    e = c.SDLK_E,
    f = c.SDLK_F,
    g = c.SDLK_G,
    h = c.SDLK_H,
    i = c.SDLK_I,
    j = c.SDLK_J,
    k = c.SDLK_K,
    l = c.SDLK_L,
    m = c.SDLK_M,
    n = c.SDLK_N,
    o = c.SDLK_O,
    p = c.SDLK_P,
    q = c.SDLK_Q,
    r = c.SDLK_R,
    s = c.SDLK_S,
    t = c.SDLK_T,
    u = c.SDLK_U,
    v = c.SDLK_V,
    w = c.SDLK_W,
    x = c.SDLK_X,
    y = c.SDLK_Y,
    z = c.SDLK_Z,
    enter = c.SDLK_RETURN,
    escape = c.SDLK_ESCAPE,
    backspace = c.SDLK_BACKSPACE,
    tab = c.SDLK_TAB,
    space = c.SDLK_SPACE,
    comma = c.SDLK_COMMA,
    home = c.SDLK_HOME,
    page_up = c.SDLK_PAGEUP,
    delete = c.SDLK_DELETE,
    end = c.SDLK_END,
    page_down = c.SDLK_PAGEDOWN,
    right = c.SDLK_RIGHT,
    left = c.SDLK_LEFT,
    down = c.SDLK_DOWN,
    up = c.SDLK_UP,
    kp_enter = c.SDLK_KP_ENTER,
    left_control = c.SDLK_LCTRL,
    left_shift = c.SDLK_LSHIFT,
    left_alt = c.SDLK_LALT,
    left_super = c.SDLK_LGUI,
    right_control = c.SDLK_RCTRL,
    right_shift = c.SDLK_RSHIFT,
    right_alt = c.SDLK_RALT,
    right_super = c.SDLK_RGUI,
};
pub const KeyPress = struct {
    code: c.SDL_Keycode,
    modifiers: c.SDL_Keymod,
    repeat: bool,

    pub fn pressed(key: KeyPress, expected: Key) bool {
        return !key.repeat and key.matches(expected);
    }
    pub fn matches(key: KeyPress, expected: Key) bool {
        return key.code == @intFromEnum(expected);
    }
};
pub const Button = enum(u8) { left = c.SDL_BUTTON_LEFT, middle = c.SDL_BUTTON_MIDDLE, right = c.SDL_BUTTON_RIGHT };
var pointer: geometry.Point = .{ .x = 0, .y = 0 };
var buttons: c.SDL_MouseButtonFlags = 0;
var keys: std.StaticBitSet(c.SDL_SCANCODE_COUNT) = .initEmpty();
var key_modifiers: c.SDL_Keymod = 0;
var closing = false;

pub fn mouse() geometry.Point {
    return pointer;
}
pub fn modifiers() c.SDL_Keymod {
    return key_modifiers;
}
pub fn leftDown() bool {
    return buttons & c.SDL_BUTTON_LMASK != 0;
}
/// Held input stays active between motion or key-repeat events, including injected events.
pub fn inputHeld() bool {
    return buttons != 0 or keys.count() > 0;
}
/// Borrow event strings until the next pump. Drain with PeepEvents so an SDL
/// poll sentinel left by WaitEventTimeout cannot hide later injected events.
pub fn nextEvent() ?c.SDL_Event {
    if (window() == null) return null;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PeepEvents(&event, 1, c.SDL_GETEVENT, c.SDL_EVENT_FIRST, c.SDL_EVENT_LAST) > 0) {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => closing = true,
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                key_modifiers = event.key.mod;
                const code = event.key.scancode;
                if (code > c.SDL_SCANCODE_UNKNOWN and code < c.SDL_SCANCODE_COUNT)
                    keys.setValue(@intCast(code), event.type == c.SDL_EVENT_KEY_DOWN);
            },
            c.SDL_EVENT_MOUSE_MOTION => pointer = .{ .x = event.motion.x, .y = event.motion.y },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                pointer = .{ .x = event.button.x, .y = event.button.y };
                if (event.button.button > 0 and event.button.button <= 32) {
                    const mask = @as(u32, 1) << @as(u5, @intCast(event.button.button - 1));
                    if (event.button.down) buttons |= mask else buttons &= ~mask;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => pointer = .{ .x = event.wheel.mouse_x, .y = event.wheel.mouse_y },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                buttons = 0;
                keys = .initEmpty();
                key_modifiers = 0;
            },
            else => {},
        }
        return event;
    }
    return null;
}
pub const Cursor = enum { default, pointing_hand, ibeam };
var cursors: [3]?*c.SDL_Cursor = @splat(null);
pub fn setCursor(cursor: Cursor) void {
    const index = @intFromEnum(cursor);
    if (cursors[index] == null) cursors[index] = c.SDL_CreateSystemCursor(switch (cursor) {
        .default => c.SDL_SYSTEM_CURSOR_DEFAULT,
        .pointing_hand => c.SDL_SYSTEM_CURSOR_POINTER,
        .ibeam => c.SDL_SYSTEM_CURSOR_TEXT,
    });
    if (cursors[index]) |value| _ = c.SDL_SetCursor(value);
}
