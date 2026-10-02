//! Production chat rendering with synthetic data and per-frame wall/CPU timings.
const std = @import("std");
const builtin = @import("builtin");
const u = @import("common.zig");
const graphics = @import("client/graphics.zig");
const desktop = @import("client/desktop.zig");
const RenderFixture = @import("client_main.zig").RenderFixture;
const c = desktop.c;
const Pacing = enum { unpaced, vsync, timer, capped_vsync };

const Sample = struct {
    interval_ns: u64,
    draw_ns: u64,
    present_ns: u64,
    cpu_ns: u64,
    measured_rows: usize,
    layout_pending: bool,
    reflow_started: bool,
    width: i32,
    height: i32,
};

fn cpuTime() !u64 {
    var ts: u.c.struct_timespec = undefined;
    if (u.c.clock_gettime(u.c.CLOCK_PROCESS_CPUTIME_ID, &ts) != 0) return error.ClockUnavailable;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn output(gpa: std.mem.Allocator, value: anytype) !void {
    const json = try u.json(gpa, value);
    defer gpa.free(json);
    var written: usize = 0;
    while (written < json.len) {
        const count = u.c.write(1, json.ptr + written, json.len - written);
        if (count <= 0) return error.OutputUnavailable;
        written += @intCast(count);
    }
    if (u.c.write(1, "\n", 1) != 1) return error.OutputUnavailable;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const count = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 600;
    const avatars = if (args.len > 2)
        std.meta.stringToEnum(RenderFixture.Avatars, args[2]) orelse return error.InvalidArguments
    else
        .shared;
    const workload_filter: ?RenderFixture.Workload = if (args.len > 3 and !std.mem.eql(u8, args[3], "all"))
        std.meta.stringToEnum(RenderFixture.Workload, args[3]) orelse return error.InvalidArguments
    else
        null;
    const pacing = if (args.len > 4)
        std.meta.stringToEnum(Pacing, args[4]) orelse return error.InvalidArguments
    else
        .unpaced;
    if (args.len > 5 or count < 100 or count > 100000) return error.InvalidArguments;
    try desktop.open(1120, 780, "Zimbr rendering benchmark");
    defer desktop.close();
    try graphics.init();
    defer graphics.deinit();
    const renderer = c.SDL_GetRenderer(desktop.window());
    if (!c.SDL_SetRenderVSync(renderer, if (pacing == .vsync or pacing == .capped_vsync) 1 else 0))
        return error.VsyncUnavailable;
    desktop.poll();
    const name = c.SDL_GetRendererName(renderer) orelse return error.RendererUnavailable;
    const gpu_device = c.SDL_GetPointerProperty(c.SDL_GetRendererProperties(renderer), "SDL.renderer.gpu.device", null);
    var vsync: c_int = undefined;
    if (!c.SDL_GetRenderVSync(renderer, &vsync)) return error.VsyncUnavailable;
    try output(gpa, .{
        .kind = "metadata",
        .schema = 1,
        .renderer = std.mem.span(name),
        .gpu_driver = if (gpu_device) |device| std.mem.span(c.SDL_GetGPUDeviceDriver(@ptrCast(device))) else null,
        .sdl_version = c.SDL_GetVersion(),
        .sdl_revision = std.mem.span(c.SDL_GetRevision()),
        .zig_version = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .vsync = vsync,
        .pacing = @tagName(pacing),
        .window = desktop.Metrics.current(),
        .samples = count,
        .warmup_frames = 120,
        .messages = 1000,
        .chats = 32,
        .avatars = @tagName(avatars),
        .workload = if (workload_filter) |workload| @tagName(workload) else null,
    });
    const pixels = try gpa.alloc(u8, 512 * 512 * 4);
    for (pixels, 0..) |*byte, i| byte.* = if (i % 4 == 3) 255 else @truncate(i / 4);
    const samples = try gpa.alloc(Sample, count);
    inline for (std.meta.tags(RenderFixture.Workload)) |workload| {
        if (workload_filter == null or workload_filter.? == workload) {
            desktop.setSize(1120, 780);
            var fixture: RenderFixture = undefined;
            try fixture.init(init.io, avatars, workload);
            defer fixture.deinit();
            for (0..2000) |_| {
                desktop.poll();
                fixture.draw(.cached, 0);
                graphics.endFrame();
                if (fixture.settled()) break;
            } else return error.LayoutDidNotSettle;
            var last_start = desktop.ticks();
            for (0..120 + count) |frame| {
                if (pacing == .timer or pacing == .capped_vsync) {
                    const deadline = last_start + desktop.Metrics.current().refresh_interval_ns;
                    while (desktop.ticks() < deadline) {
                        _ = desktop.waitNs(deadline -| desktop.ticks());
                        desktop.poll();
                        while (desktop.nextEvent() != null) {}
                    }
                }
                desktop.poll();
                while (desktop.nextEvent() != null) {}
                if (desktop.shouldClose()) return error.BenchmarkInterrupted;
                const cpu_start = try cpuTime();
                const start = desktop.ticks();
                const reflow_started = workload == .reflow and fixture.settled();
                fixture.draw(workload, frame);
                const texture = if (workload == .image_upload) try graphics.upload(pixels.ptr, 512, 512, .linear) else null;
                if (texture) |photo| {
                    graphics.drawTexture(photo, .{
                        .x = 450,
                        .y = 150,
                        .width = 512,
                        .height = 512,
                    });
                    // Include retirement and any flush it causes in the upload workload.
                    graphics.destroyTexture(photo);
                }
                const drawn = desktop.ticks();
                if (!c.SDL_RenderPresent(renderer)) return error.PresentationUnavailable;
                const presented = desktop.ticks();
                const cpu_end = try cpuTime();
                if (frame >= 120) samples[frame - 120] = .{
                    .interval_ns = start - last_start,
                    .draw_ns = drawn - start,
                    .present_ns = presented - drawn,
                    .cpu_ns = cpu_end - cpu_start,
                    .measured_rows = fixture.measuredRows(),
                    .layout_pending = !fixture.settled(),
                    .reflow_started = reflow_started,
                    .width = desktop.width(),
                    .height = desktop.height(),
                };
                last_start = start;
            }
            try output(gpa, .{ .kind = "workload", .name = @tagName(workload), .frames = samples });
        }
    }
}
