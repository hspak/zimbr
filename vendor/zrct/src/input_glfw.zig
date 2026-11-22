//! GLFW callbacks dispatch directly into the application's ordinary input consumers.
const std = @import("std");
const CharCallback = *const fn (?*anyopaque, c_uint) callconv(.c) void;
const DropCallback = *const fn (?*anyopaque, c_int, [*c]const [*c]const u8) callconv(.c) void;
extern fn glfwGetCurrentContext() ?*anyopaque;
extern fn glfwPollEvents() void;
extern fn glfwGetProcAddress([*:0]const u8) ?*const anyopaque;
extern fn glfwSetCharCallback(?*anyopaque, ?CharCallback) ?CharCallback;
extern fn glfwSetDropCallback(?*anyopaque, ?DropCallback) ?DropCallback;

pub const queued = false;
pub const getProcAddress = glfwGetProcAddress;

pub fn text(bytes: []const u8) !usize {
    const window = glfwGetCurrentContext();
    const callback = glfwSetCharCallback(window, null);
    _ = glfwSetCharCallback(window, callback);
    const character = callback orelse return error.CharacterCallbackUnavailable;
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < bytes.len and count < 16) : (count += 1) {
        const length = try std.unicode.utf8ByteSequenceLength(bytes[offset]);
        character(window, try std.unicode.utf8Decode(bytes[offset..][0..length]));
        offset += length;
    }
    return offset;
}

pub fn frame() void {
    // Dispatch native input without resetting raylib's input arrays.
    glfwPollEvents();
}

pub fn drop(count: c_int, paths: [*c]const [*c]const u8, _: f32, _: f32) !void {
    const window = glfwGetCurrentContext();
    const callback = glfwSetDropCallback(window, null);
    _ = glfwSetDropCallback(window, callback);
    const deliver = callback orelse return error.DropCallbackUnavailable;
    deliver(window, count, paths);
}
