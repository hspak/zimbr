//! Opt-in instrumentation. Poll on the UI thread before consumers; publish before swap.
const options = @import("zrct_options");
const engine = @import("engine.zig");
pub const Rect = @import("registry.zig").Rect;
pub const Target = @import("registry.zig").Target;
pub const enabled = options.enabled;
pub const Renderer = @import("host_sdl.zig").Renderer;
/// Native SDL consumers supply drawing hooks and their window when using SDL_Renderer.
/// Capture reads the SDL renderer target or the current OpenGL back buffer.
pub fn setRenderer(renderer: Renderer) void {
    if (comptime enabled and options.native_sdl) @import("host_sdl.zig").renderer = renderer;
}
pub const DropHandler = engine.DropHandler;

/// Register the application's ordinary file-drop delivery callback when it owns
/// native drops outside the window backend. Paths are borrowed for the call.
pub fn setDropHandler(handler: DropHandler) void {
    if (comptime enabled) engine.drop_handler = handler;
}

pub fn init(application: []const u8, version: []const u8) !void {
    if (comptime enabled) try engine.init(application, version);
}
pub fn deinit() void {
    if (comptime enabled) engine.deinit();
}
/// Existing idle loops must call this at their ordinary bounded poll cadence.
pub fn poll() bool {
    return if (comptime enabled) engine.poll() else false;
}
pub fn shouldClose() bool {
    return if (comptime enabled) engine.closing else false;
}
pub fn beginFrame() void {
    if (comptime enabled) engine.beginFrame();
}
pub fn add(target: Target) void {
    if (comptime enabled) engine.add(target);
}
/// Call after all drawing and before presentation. The driver flushes pending batches.
pub fn endFrame() void {
    if (comptime enabled) engine.endFrame();
}
