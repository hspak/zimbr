//! Queue input for the application's existing SDL event consumer. Never drain its queue.
const std = @import("std");
const options = @import("zrct_options");
const c = @import("desktop_c");

pub const queued = true;
// SDL copies event structs, but user-supplied strings remain borrowed. Actions
// are serialized and these buffers survive the ordinary poll following a draw,
// including cancellation/disconnect. Reuse only after that poll has completed.
var text_bytes: [2][4097]u8 = undefined;
var text_slot: usize = 0;
var path_bytes: [16][4096]u8 = undefined;

pub fn getProcAddress(name: [*:0]const u8) ?*const anyopaque {
    const address = c.SDL_GL_GetProcAddress(name) orelse return null;
    return @ptrCast(address);
}

fn windowId() !c.SDL_WindowID {
    const window: *c.SDL_Window = if (comptime options.native_sdl)
        @ptrCast(@import("host_sdl.zig").window() orelse return error.WindowUnavailable)
    else
        c.SDL_GL_GetCurrentWindow() orelse return error.WindowUnavailable;
    return c.SDL_GetWindowID(window);
}

pub fn text(bytes: []const u8) !usize {
    const window = try windowId();
    const length = @import("registry.zig").utf8Prefix(bytes, 4096);
    const buffer = &text_bytes[text_slot];
    @memcpy(buffer[0..length], bytes[0..length]);
    buffer[length] = 0;
    var event = std.mem.zeroes(c.SDL_Event);
    event.text.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.windowID = window;
    event.text.text = buffer;
    if (!c.SDL_PushEvent(&event)) return error.EventRejected;
    text_slot = (text_slot + 1) % text_bytes.len;
    return length;
}

pub fn edit(bytes: []const u8, start: i32, length: i32) !void {
    if (bytes.len > 4096) return error.TextTooLong;
    const buffer = &text_bytes[text_slot];
    @memcpy(buffer[0..bytes.len], bytes);
    buffer[bytes.len] = 0;
    var event = std.mem.zeroes(c.SDL_Event);
    event.edit.type = c.SDL_EVENT_TEXT_EDITING;
    event.edit.windowID = try windowId();
    event.edit.text = buffer;
    event.edit.start = start;
    event.edit.length = length;
    if (!c.SDL_PushEvent(&event)) return error.EventRejected;
    text_slot = (text_slot + 1) % text_bytes.len;
}

pub fn frame() void {}

pub fn drop(count: c_int, paths: [*c]const [*c]const u8, x: f32, y: f32) !void {
    const window = try windowId();
    if (!c.SDL_EventEnabled(c.SDL_EVENT_DROP_FILE)) return error.DropEventsDisabled;
    if (count < 1 or count > path_bytes.len) return error.InvalidPathCount;
    const length: usize = @intCast(count);
    for (paths[0..length], 0..) |path, i| {
        const bytes = std.mem.span(path);
        if (bytes.len >= path_bytes[i].len) return error.PathTooLong;
        @memcpy(path_bytes[i][0..bytes.len], bytes);
        path_bytes[i][bytes.len] = 0;
    }
    var event = std.mem.zeroes(c.SDL_Event);
    event.drop.windowID = window;
    event.drop.x = x;
    event.drop.y = y;
    event.type = c.SDL_EVENT_DROP_BEGIN;
    if (!c.SDL_PushEvent(&event)) return error.EventRejected;
    for (0..length) |i| {
        event.type = c.SDL_EVENT_DROP_FILE;
        event.drop.data = &path_bytes[i];
        if (!c.SDL_PushEvent(&event)) return error.EventRejected;
    }
    event.type = c.SDL_EVENT_DROP_COMPLETE;
    event.drop.data = null;
    if (!c.SDL_PushEvent(&event)) return error.EventRejected;
}
