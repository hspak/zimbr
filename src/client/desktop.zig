//! SDL window, input batches, clipboard, and worker wakeups for the GUI thread.
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
/// Consume this event batch's committed UTF-8. Borrowed until the next event poll.
pub fn takeText() []const u8 {
    var length: usize = 0;
    const text = c.zc_desktop_take_text(&length);
    return text[0..length];
}
pub fn discardText() void {
    _ = takeText();
}
pub fn textRejected() bool {
    return c.zc_desktop_text_error() != 0;
}
pub fn composing() bool {
    return c.zc_desktop_composing() != 0;
}
pub const Preedit = struct {
    text: []const u8,
    start: i32,
    length: i32,
};
/// The last composition update in this batch, borrowed until the next poll.
/// An empty update cancels preedit; null leaves the existing preedit unchanged.
pub fn preedit() ?Preedit {
    if (c.zc_desktop_preedit_changed() == 0) return null;
    var length: usize = 0;
    var start: c_int = 0;
    var selection: c_int = 0;
    const text = c.zc_desktop_preedit(&length, &start, &selection);
    return .{
        .text = text[0..length],
        .start = start,
        .length = selection,
    };
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
    target_seconds = 0;
    frame_seconds = 0;
    frame_start = time();
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
pub const poll = c.zc_desktop_poll;
pub fn shouldClose() bool {
    return c.zc_desktop_closing() != 0;
}
pub fn resized() bool {
    return c.zc_desktop_resized() != 0;
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
pub fn pixelWidth() i32 {
    var n: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window(), &n, null);
    return n;
}
pub fn pixelHeight() i32 {
    var n: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window(), null, &n);
    return n;
}
pub fn scale() geometry.Point {
    return .{
        .x = @as(f32, @floatFromInt(pixelWidth())) / @as(f32, @floatFromInt(@max(1, width()))),
        .y = @as(f32, @floatFromInt(pixelHeight())) / @as(f32, @floatFromInt(@max(1, height()))),
    };
}
pub fn setSize(w: i32, h: i32) void {
    _ = c.SDL_SetWindowSize(window(), w, h);
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
var target_seconds: f64 = 0;
var frame_start: f64 = 0;
var frame_seconds: f64 = 0;
pub fn setFrameLimit(limit: u32) void {
    target_seconds = if (limit == 0) 0 else 1 / @as(f64, @floatFromInt(limit));
}
pub fn fps() i32 {
    return if (frame_seconds > 0) @intFromFloat(@round(1 / frame_seconds)) else 0;
}
pub fn present() void {
    _ = c.SDL_GL_SwapWindow(window());
    const elapsed = time() - frame_start;
    if (elapsed < target_seconds) sleep(target_seconds - elapsed);
    const now = time();
    frame_seconds = now - frame_start;
    frame_start = now;
    poll();
}
pub const Key = enum(c_int) {
    a = 4,
    b = 5,
    c = 6,
    d = 7,
    e = 8,
    f = 9,
    g = 10,
    h = 11,
    i = 12,
    j = 13,
    k = 14,
    l = 15,
    m = 16,
    n = 17,
    o = 18,
    p = 19,
    q = 20,
    r = 21,
    s = 22,
    t = 23,
    u = 24,
    v = 25,
    w = 26,
    x = 27,
    y = 28,
    z = 29,
    enter = 40,
    escape = 41,
    backspace = 42,
    tab = 43,
    space = 44,
    comma = 54,
    home = 74,
    page_up = 75,
    delete = 76,
    end = 77,
    page_down = 78,
    right = 79,
    left = 80,
    down = 81,
    up = 82,
    kp_enter = 88,
    left_control = 224,
    left_shift = 225,
    left_alt = 226,
    left_super = 227,
    right_control = 228,
    right_shift = 229,
    right_alt = 230,
    right_super = 231,
};
pub fn keyDown(key: Key) bool {
    return c.zc_desktop_key(@intFromEnum(key), 0) != 0;
}
pub fn keyPressed(key: Key) bool {
    return c.zc_desktop_key(@intFromEnum(key), 1) != 0;
}
pub fn keyRepeated(key: Key) bool {
    return c.zc_desktop_key(@intFromEnum(key), 3) != 0;
}
pub const Button = enum(c_int) { left = 1, middle = 2, right = 3 };
pub fn buttonDown(button: Button) bool {
    return c.zc_desktop_button(@intFromEnum(button), 0) != 0;
}
pub fn buttonPressed(button: Button) bool {
    return c.zc_desktop_button(@intFromEnum(button), 1) != 0;
}
pub fn buttonReleased(button: Button) bool {
    return c.zc_desktop_button(@intFromEnum(button), 2) != 0;
}
pub fn mouse() geometry.Point {
    var p: geometry.Point = undefined;
    c.zc_desktop_mouse(&p.x, &p.y);
    return p;
}
pub const wheel = c.zc_desktop_wheel;
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
