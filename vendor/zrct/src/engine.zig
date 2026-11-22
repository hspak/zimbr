//! Bounded, nonblocking UI-thread server. Input is replayed through the application's consumers.
const std = @import("std");
const builtin = @import("builtin");
const host = if (options.native_sdl) @import("host_sdl.zig") else @import("host_raylib.zig");
const options = @import("zrct_options");
const input = switch (options.backend) {
    .glfw => @import("input_glfw.zig"),
    .sdl3 => @import("input_sdl.zig"),
};
const registry = @import("registry.zig");
const benchmark = @import("benchmark.zig");
const png = @import("png.zig");
const c = @import("posix_c");
const a = std.heap.page_allocator;
extern fn accept4(c_int, ?*c.struct_sockaddr, ?*c.socklen_t, c_int) c_int;
pub const DropHandler = *const fn (c_int, [*c]const [*c]const u8) callconv(.c) void;
pub var drop_handler: ?DropHandler = null;

const Request = struct {
    version: u32 = 0,
    id: u64 = 0,
    op: []const u8 = "",
    target: []const u8 = "",
    frame_id: u64 = 0,
    text: []const u8 = "",
    path: []const u8 = "",
    paths: []const []const u8 = &.{},
    dx: f32 = 0,
    dy: f32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    frames: u32 = 8,
    field: []const u8 = "value",
    max_bytes: usize = registry.Registry.content_limit,
    to_target: []const u8 = "",
    start: i32 = 0,
    length: i32 = 0,
    measurement: ?benchmark.Spec = null,
    query: registry.Registry.Query = .{},
};
const Client = struct {
    fd: c_int = -1,
    input: [65536]u8 = undefined,
    length: usize = 0,
    output: ?[]u8 = null,
    written: usize = 0,
    deadline: i64 = 0,
};
const Pending = struct {
    request: std.json.Parsed(Request),
    client: usize,
    stage: u32 = 0,
    text_offset: usize = 0,
    point: struct { x: f32 = 0, y: f32 = 0 } = .{},
    keys: [8]host.Key = undefined,
    key_count: usize = 0,
    done: bool = false,
    consumed_ns: i64 = 0,
    advanced_frame: ?u64 = null,
    end_point: ?registry.Registry.Point = null,
};
const Server = struct {
    listener: c_int,
    path: [:0]u8,
    application: []const u8,
    version: []const u8,
    clients: [8]Client = @splat(.{}),
    current: registry.Registry,
    next: registry.Registry,
    pending: ?Pending = null,
    frame_id: u64 = 0,
    frame_ns: i64 = 0,
    overlay: bool = false,
    recording: ?[:0]u8 = null,
    record_file: ?*c.FILE = null,
    record_frames: u32 = 0,
    record_bytes: u64 = 0,
    record_complete: bool = true,
    measurement: ?*benchmark.Observer = null,
    begin_ns: i64 = 0,
    window_bounds: registry.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};
var server: ?*Server = null;
pub var closing = false;
const operations = [_][]const u8{ "inspect", "query", "resolve", "resolve_scroll", "content", "frame", "click", "press", "type_text", "drag", "scroll", "resize", "screenshot", "close", "drop", "record_start", "record_stop", "record_status", "overlay", "measure_start", "measure_status", "measure_cancel" } ++ (if (options.native_sdl) [_][]const u8{ "key_down", "key_up", "key_repeat", "double_click", "text_editing", "rendering" } else [_][]const u8{});

fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}
pub fn init(application: []const u8, version: []const u8) !void {
    const raw = c.getenv("ZRCT_SOCKET") orelse return;
    const path = std.mem.span(raw);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len == 0 or path.len >= address.sun_path.len) return error.SocketPathTooLong;
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketUnavailable;
    errdefer _ = c.close(fd);
    if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.SocketBindFailed;
    errdefer _ = c.unlink(raw);
    _ = c.chmod(raw, 0o600);
    if (c.listen(fd, 8) != 0) return error.SocketListenFailed;
    const s = try a.create(Server);
    errdefer a.destroy(s);
    s.* = .{ .listener = fd, .path = try a.dupeSentinel(u8, path, 0), .application = application, .version = version, .current = .init(a), .next = .init(a) };
    errdefer a.free(s.path);
    if (c.getenv("ZRCT_BENCHMARK_START")) |raw_spec| {
        if (c.getenv("ZRCT_RECORD_DIR") != null) return error.RecordingDuringBenchmark;
        const raw_ns = c.getenv("ZRCT_BENCHMARK_LAUNCH_NS") orelse return error.MissingLaunchTimestamp;
        const launch_ns = try std.fmt.parseInt(i64, std.mem.span(raw_ns), 10);
        if (launch_ns <= 0 or launch_ns > now()) return error.InvalidLaunchTimestamp;
        s.measurement = try benchmark.Observer.create(a, std.mem.span(raw_spec), launch_ns);
    }
    closing = false;
    server = s;
    if (c.getenv("ZRCT_RECORD_DIR")) |directory| {
        if (!startRecording(s, std.mem.span(directory))) {
            server = null;
            return error.RecordingUnavailable;
        }
    }
}
pub fn deinit() void {
    const s = server orelse return;
    releaseInput(s);
    if (s.pending) |*pending| pending.request.deinit();
    if (s.measurement) |measurement| measurement.destroy(a);
    stopRecording(s);
    for (&s.clients) |*client| closeClient(client);
    _ = c.close(s.listener);
    _ = c.unlink(s.path.ptr);
    a.free(s.path);
    s.current.deinit();
    s.next.deinit();
    a.destroy(s);
    server = null;
    drop_handler = null;
    if (comptime options.native_sdl) host.reset();
}
fn closeClient(client: *Client) void {
    if (client.fd >= 0) _ = c.close(client.fd);
    if (client.output) |output| a.free(output);
    client.* = .{};
}
fn flush(client: *Client) void {
    const output = client.output orelse return;
    const n = c.send(client.fd, output.ptr + client.written, output.len - client.written, c.MSG_NOSIGNAL | c.MSG_DONTWAIT);
    if (n > 0) client.written += @intCast(n);
    if (client.written == output.len) closeClient(client);
}
fn respond(s: *Server, index: usize, id: u64, result: anytype) void {
    const body = std.json.Stringify.valueAlloc(a, .{ .version = 1, .id = id, .result = result }, .{}) catch {
        closeClient(&s.clients[index]);
        return;
    };
    defer a.free(body);
    queue(s, index, id, body);
}
fn fail(s: *Server, index: usize, id: u64, code: []const u8, message: []const u8) void {
    const body = std.json.Stringify.valueAlloc(a, .{ .version = 1, .id = id, .frame_id = s.frame_id, .@"error" = .{ .code = code, .message = message } }, .{}) catch {
        closeClient(&s.clients[index]);
        return;
    };
    defer a.free(body);
    queue(s, index, id, body);
}
fn queue(s: *Server, index: usize, id: u64, body: []const u8) void {
    if (body.len >= 1024 * 1024) {
        fail(s, index, id, "response_limit", "Snapshot exceeds 1 MiB");
        return;
    }
    const client = &s.clients[index];
    client.output = a.alloc(u8, body.len + 1) catch {
        closeClient(client);
        return;
    };
    @memcpy(client.output.?[0..body.len], body);
    client.output.?[body.len] = '\n';
    flush(client);
}
fn glString(name: c_uint) []const u8 {
    if (comptime options.native_sdl) if (host.renderingInfo(name)) |value| return value;
    const address = input.getProcAddress("glGetString") orelse return "unavailable";
    const get_string: *const fn (c_uint) callconv(.c) ?[*:0]const u8 = @ptrCast(address);
    return if (get_string(name)) |value| std.mem.span(value) else "unavailable";
}
fn snapshot(s: *Server) struct { frame_id: u64, time_ns: i64, targets: []const registry.Target, truncated: bool, window: struct { width: i32, height: i32, scale: f32 } } {
    return .{ .frame_id = s.frame_id, .time_ns = s.frame_ns, .targets = s.current.targets.items, .truncated = s.current.overflow, .window = .{ .width = host.width(), .height = host.height(), .scale = host.scale() } };
}
pub fn poll() bool {
    const s = server orelse return false;
    for (&s.clients) |*client| {
        if (client.fd >= 0) continue;
        const fd = accept4(s.listener, null, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
        if (fd < 0) break;
        client.* = .{ .fd = fd, .deadline = now() + 10_000_000_000 };
    }
    for (&s.clients, 0..) |*client, index| {
        if (client.fd < 0) continue;
        if (now() > client.deadline) {
            if (s.pending) |*pending| {
                if (pending.client == index) {
                    releaseInput(s);
                    pending.request.deinit();
                    s.pending = null;
                }
            }
            closeClient(client);
            continue;
        }
        if (client.output != null) {
            flush(client);
            continue;
        }
        if (s.pending != null and s.pending.?.client == index) {
            var byte: [1]u8 = undefined;
            if (c.recv(client.fd, &byte, 1, c.MSG_PEEK | c.MSG_DONTWAIT) == 0) {
                releaseInput(s);
                s.pending.?.request.deinit();
                s.pending = null;
                closeClient(client);
            }
            continue;
        }
        const count = c.recv(client.fd, &client.input[client.length], client.input.len - client.length, c.MSG_DONTWAIT);
        if (count == 0) {
            closeClient(client);
            continue;
        }
        if (count < 0) continue;
        client.length += @intCast(count);
        if (std.mem.findScalar(u8, client.input[0..client.length], '\n')) |end| {
            dispatch(s, index, client.input[0..end]);
        } else if (client.length == client.input.len) {
            fail(s, index, 0, "request_limit", "Request exceeds 64 KiB");
        }
    }
    if (s.pending != null) {
        advance(s);
        return true;
    }
    return false;
}
fn dispatch(s: *Server, index: usize, raw: []const u8) void {
    const parsed = std.json.parseFromSlice(Request, a, raw, .{ .allocate = .alloc_always }) catch {
        fail(s, index, 0, "malformed", "Invalid request JSON or fields");
        return;
    };
    var retained = false;
    defer if (!retained) parsed.deinit();
    const r = parsed.value;
    if (r.version != 1) return fail(s, index, r.id, "version", "Protocol version 1 required");
    if (std.mem.eql(u8, r.op, "hello")) {
        return respond(s, index, r.id, .{ .protocol_version = 1, .application = s.application, .build = s.version, .optimization = @tagName(builtin.optimize), .benchmark_version = 2, .clock = "CLOCK_MONOTONIC", .time_ns = now(), .operations = operations, .window = .{ .width = host.width(), .height = host.height(), .scale = host.scale() }, .renderer = .{ .vendor = glString(0x1f00), .device = glString(0x1f01), .version = glString(0x1f02) }, .boundary = if (options.native_sdl) "sdl3_events" else "application_input", .backend = @tagName(options.backend), .keys = @import("keys.zig").entries, .drop_boundary = if (drop_handler != null) "application_drop_handler" else if (options.backend == .sdl3) "sdl3_drop_events" else "glfw_drop_callback", .rendering = if (options.native_sdl) host.rendering() else null, .limits = .{ .text_bytes = 32768, .preview_bytes = registry.Registry.preview_limit, .content_bytes = registry.Registry.content_limit }, .limitations = if (options.native_sdl) &[_][]const u8{ "gestures", "compositor_input", "system_ime", "polled_device_state" } else &[_][]const u8{ "key_repeat", "gestures", "fractional_wheel", "compositor_input" } });
    }
    if (std.mem.eql(u8, r.op, "inspect")) return respond(s, index, r.id, snapshot(s));
    if (std.mem.eql(u8, r.op, "query")) {
        var result = snapshot(s);
        result.targets = s.current.select(parsed.arena.allocator(), r.query) catch return fail(s, index, r.id, "memory", "Allocation failed");
        return respond(s, index, r.id, result);
    }
    if (comptime options.native_sdl) if (std.mem.eql(u8, r.op, "rendering")) return respond(s, index, r.id, host.rendering());
    if (std.mem.eql(u8, r.op, "resolve") or std.mem.eql(u8, r.op, "resolve_scroll")) {
        const point = (if (std.mem.eql(u8, r.op, "resolve_scroll")) s.current.resolveScroll(r.target) else s.current.resolve(r.target)) catch |err| return fail(s, index, r.id, "target", @errorName(err));
        return respond(s, index, r.id, .{ .frame_id = s.frame_id, .point = point });
    }
    if (std.mem.eql(u8, r.op, "content")) {
        if (r.max_bytes > registry.Registry.content_limit) return fail(s, index, r.id, "range", "Content limit exceeds 64 KiB");
        const value = s.current.content(r.target, r.field, r.max_bytes) catch |err| return fail(s, index, r.id, "content", @errorName(err));
        return respond(s, index, r.id, .{ .frame_id = s.frame_id, .field = r.field, .text = value, .bytes = value.len });
    }
    if (std.mem.eql(u8, r.op, "record_status")) return respond(s, index, r.id, .{ .frame_id = s.frame_id, .recorded_frames = s.record_frames, .recording_complete = s.record_complete });
    if (std.mem.eql(u8, r.op, "measure_status")) {
        const m = s.measurement orelse return fail(s, index, r.id, "measurement", "No measurement is armed");
        return respond(s, index, r.id, .{ .state = @tagName(m.state), .failure = m.failure, .name = m.spec.value.name, .started_ns = m.started_ns, .completed_ns = m.completed_ns, .frame_id = m.frame_id, .action_id = m.action_id, .frames = m.frames[0..if (m.active()) 0 else m.count] });
    }
    if (std.mem.eql(u8, r.op, "measure_cancel")) {
        if (s.measurement) |m| m.destroy(a);
        s.measurement = null;
        return respond(s, index, r.id, .{ .cancelled = true });
    }
    if (std.mem.eql(u8, r.op, "measure_start")) {
        if (s.pending != null or s.recording != null or s.overlay) return fail(s, index, r.id, "measurement", "Measurement requires no pending action, recording or overlay");
        if (s.measurement) |m| if (m.active()) return fail(s, index, r.id, "measurement", "Measurement is already active");
        const spec = r.measurement orelse return fail(s, index, r.id, "measurement", "Missing measurement specification");
        if (spec.start != .action) return fail(s, index, r.id, "measurement", "Launch measurements must be armed before process creation");
        const raw_spec = std.json.Stringify.valueAlloc(a, spec, .{}) catch return fail(s, index, r.id, "memory", "Allocation failed");
        defer a.free(raw_spec);
        const m = benchmark.Observer.create(a, raw_spec, 0) catch |err| return fail(s, index, r.id, "measurement", @errorName(err));
        const matched = m.matches(&s.current) catch |err| {
            m.destroy(a);
            return fail(s, index, r.id, "measurement", @errorName(err));
        };
        if (matched) {
            m.destroy(a);
            return fail(s, index, r.id, "measurement", "Completion condition is already true");
        }
        if (s.measurement) |old| old.destroy(a);
        s.measurement = m;
        return respond(s, index, r.id, .{ .armed = true });
    }
    if (s.measurement) |m| {
        if (m.active() and (std.mem.eql(u8, r.op, "screenshot") or std.mem.eql(u8, r.op, "record_start") or std.mem.eql(u8, r.op, "overlay")))
            return fail(s, index, r.id, "measurement", "Capture and overlays are forbidden during a measurement");
    }
    const supported = for (operations) |op| {
        if (std.mem.eql(u8, op, r.op)) break true;
    } else false;
    if (!supported) return fail(s, index, r.id, "unsupported", "Operation is not supported");
    if (s.pending != null) return fail(s, index, r.id, "busy", "An input action is still in progress");
    var pending = Pending{ .request = parsed, .client = index };
    if (r.frame_id > s.frame_id or (r.frame_id != 0 and s.frame_id - r.frame_id > 120))
        return fail(s, index, r.id, "stale", "Snapshot is stale; inspect again");
    if (r.target.len > 0 and !std.mem.eql(u8, r.op, "screenshot")) {
        const point = (if (std.mem.eql(u8, r.op, "scroll")) s.current.resolveScroll(r.target) else s.current.resolve(r.target)) catch |err| return fail(s, index, r.id, "target", @errorName(err));
        pending.point = .{ .x = point.x, .y = point.y };
    } else if (std.mem.eql(u8, r.op, "click") or std.mem.eql(u8, r.op, "double_click") or std.mem.eql(u8, r.op, "drag") or std.mem.eql(u8, r.op, "scroll") or std.mem.eql(u8, r.op, "drop")) {
        return fail(s, index, r.id, "target", "This action requires a semantic target");
    }
    if (r.to_target.len > 0) {
        if (!std.mem.eql(u8, r.op, "drag")) return fail(s, index, r.id, "range", "to_target requires drag");
        pending.end_point = s.current.resolve(r.to_target) catch |err| return fail(s, index, r.id, "target", @errorName(err));
    }
    if (std.mem.findScalar(u8, r.text, 0) != null) return fail(s, index, r.id, "text", "Text cannot contain NUL");
    if (!std.math.isFinite(r.dx) or !std.math.isFinite(r.dy) or @abs(r.dx) > 10000 or @abs(r.dy) > 10000)
        return fail(s, index, r.id, "range", "Input delta is out of range");
    if (!options.native_sdl and std.mem.eql(u8, r.op, "scroll") and (@trunc(r.dx) != r.dx or @trunc(r.dy) != r.dy))
        return fail(s, index, r.id, "unsupported", "Fractional wheel deltas are unsupported");
    if (std.mem.eql(u8, r.op, "resize") and (r.width < 100 or r.height < 100 or r.width > 4096 or r.height > 4096))
        return fail(s, index, r.id, "range", "Window dimensions must be between 100 and 4096");
    if (r.frames == 0 or r.frames > 120) return fail(s, index, r.id, "range", "Action frames must be 1..120");
    if (!std.unicode.utf8ValidateSlice(r.text)) return fail(s, index, r.id, "text", "Text must be valid UTF-8");
    if (r.text.len > 32768) return fail(s, index, r.id, "range", "Text exceeds 32768 UTF-8 bytes; split the input");
    if (std.mem.eql(u8, r.op, "text_editing") and (r.start < 0 or r.length < 0 or r.text.len > 4096)) return fail(s, index, r.id, "range", "Invalid preedit range or text length");
    if (std.mem.eql(u8, r.op, "text_editing")) {
        const characters = std.unicode.utf8CountCodepoints(r.text) catch unreachable;
        if (@as(u64, @intCast(r.start)) + @as(u64, @intCast(r.length)) > characters)
            return fail(s, index, r.id, "range", "Preedit selection exceeds character count");
    }
    if (std.mem.eql(u8, r.op, "press") or std.mem.startsWith(u8, r.op, "key_") or ((std.mem.eql(u8, r.op, "scroll") or std.mem.eql(u8, r.op, "drag")) and r.text.len > 0)) {
        var keys = std.mem.splitScalar(u8, r.text, '+');
        while (keys.next()) |name| {
            if (pending.key_count == pending.keys.len) return fail(s, index, r.id, "key", "Chord has too many keys");
            const key = std.meta.stringToEnum(host.Key, name) orelse return fail(s, index, r.id, "key", "Use key names, e.g. left_control+s");
            if (key == .null) return fail(s, index, r.id, "key", "Null is not a key");
            for (pending.keys[0..pending.key_count]) |previous| if (previous == key) return fail(s, index, r.id, "key", "Duplicate chord key");
            pending.keys[pending.key_count] = key;
            pending.key_count += 1;
        }
    }
    retained = true;
    s.pending = pending;
}
fn releaseInput(s: *Server) void {
    if (comptime options.native_sdl) return host.releaseAll();
    host.button(false) catch {};
    if (s.pending) |pending| for (pending.keys[0..pending.key_count]) |key| host.key(key, false) catch {};
}
fn advance(s: *Server) void {
    const p = &s.pending.?;
    if (p.done or p.advanced_frame == s.frame_id) return;
    p.advanced_frame = s.frame_id;
    const r = p.request.value;
    if (p.stage == 0) if (s.measurement) |m| {
        if (m.state == .armed and !std.mem.eql(u8, r.op, "frame") and !std.mem.eql(u8, r.op, "close") and !std.mem.startsWith(u8, r.op, "record_"))
            m.action(r.id, now());
    };
    if (std.mem.eql(u8, r.op, "click") or std.mem.eql(u8, r.op, "double_click") or std.mem.eql(u8, r.op, "drag")) {
        var x = p.point.x;
        var y = p.point.y;
        if (std.mem.eql(u8, r.op, "drag")) {
            const fraction = @min(1, @as(f32, @floatFromInt(p.stage)) / @as(f32, @floatFromInt(r.frames)));
            x += (if (p.end_point) |end| end.x - x else r.dx) * fraction;
            y += (if (p.end_point) |end| end.y - y else r.dy) * fraction;
        }
        host.motion(x, y) catch |err| return failPending(s, "input", @errorName(err));
        const double = std.mem.eql(u8, r.op, "double_click");
        const last: u32 = if (double) 3 else if (std.mem.eql(u8, r.op, "click")) 1 else r.frames;
        for (p.keys[0..p.key_count]) |key| host.key(key, p.stage < last) catch |err| return failPending(s, "input", @errorName(err));
        if (comptime options.native_sdl) {
            host.clickButton(if (double) p.stage < last and p.stage % 2 == 0 else p.stage < last, if (double and p.stage >= 2) 2 else 1) catch |err| return failPending(s, "input", @errorName(err));
        } else host.button(p.stage < last) catch |err| return failPending(s, "input", @errorName(err));
        p.done = p.stage >= last + @intFromBool(host.queued);
    } else if (std.mem.eql(u8, r.op, "press")) {
        for (p.keys[0..p.key_count]) |key| host.key(key, p.stage == 0) catch |err| return failPending(s, "input", @errorName(err));
        p.done = p.stage > @intFromBool(host.queued);
    } else if (std.mem.eql(u8, r.op, "type_text")) {
        if (p.text_offset == r.text.len) {
            p.done = true;
        } else {
            p.text_offset += input.text(r.text[p.text_offset..]) catch |err|
                return failPending(s, "input", @errorName(err));
            // SDL input is consumed by the application's poll after this draw.
            // Acknowledge only after the following update and completed frame.
            p.done = !input.queued and p.text_offset == r.text.len;
        }
    } else if (std.mem.eql(u8, r.op, "scroll")) {
        host.motion(p.point.x, p.point.y) catch |err| return failPending(s, "input", @errorName(err));
        for (p.keys[0..p.key_count]) |key| host.key(key, p.stage == 0) catch |err| return failPending(s, "input", @errorName(err));
        if (p.stage == 0) host.wheel(r.dx, r.dy) catch |err| return failPending(s, "input", @errorName(err));
        p.done = p.stage > @intFromBool(host.queued);
    } else if (std.mem.eql(u8, r.op, "resize")) {
        if (p.stage == 0) host.resize(r.width, r.height) catch |err| return failPending(s, "input", @errorName(err));
        p.done = host.width() == r.width and host.height() == r.height;
    } else if (std.mem.eql(u8, r.op, "frame")) {
        input.frame();
        p.done = !input.queued or p.stage > 0;
    } else if (std.mem.eql(u8, r.op, "drop")) {
        host.motion(p.point.x, p.point.y) catch |err| return failPending(s, "input", @errorName(err));
        if (r.paths.len == 0 or r.paths.len > 16) return failPending(s, "range", "Drop requires 1..16 paths");
        if (p.stage == 0) {
            var paths: [16][*c]const u8 = @splat(null);
            var allocated: usize = 0;
            defer for (paths[0..allocated]) |path| a.free(std.mem.span(path));
            for (r.paths, 0..) |path, i| {
                if (std.mem.findScalar(u8, path, 0) != null) return failPending(s, "range", "Drop path contains NUL");
                paths[i] = (a.dupeSentinel(u8, path, 0) catch return failPending(s, "memory", "Allocation failed")).ptr;
                allocated += 1;
            }
            if (drop_handler) |deliver| deliver(@intCast(r.paths.len), &paths) else input.drop(@intCast(r.paths.len), &paths, p.point.x, p.point.y) catch |err|
                return failPending(s, "unsupported", @errorName(err));
        }
        p.done = drop_handler != null or !input.queued or p.stage > 0;
    } else if (comptime options.native_sdl) {
        if (std.mem.startsWith(u8, r.op, "key_")) {
            if (p.stage == 0) for (p.keys[0..p.key_count]) |key| {
                host.keyEvent(key, !std.mem.eql(u8, r.op, "key_up"), std.mem.eql(u8, r.op, "key_repeat")) catch |err| return failPending(s, "input", @errorName(err));
            };
            p.done = p.stage > 0;
        } else if (std.mem.eql(u8, r.op, "text_editing")) {
            if (p.stage == 0) input.edit(r.text, r.start, r.length) catch |err| return failPending(s, "input", @errorName(err));
            p.done = p.stage > 0;
        } else p.done = true;
    } else {
        p.done = true;
    }
    p.stage += 1;
    p.consumed_ns = now();
}
fn failPending(s: *Server, code: []const u8, message: []const u8) void {
    const p = s.pending orelse return;
    if (s.measurement) |m| if (m.active()) m.invalidate("ActionFailed");
    releaseInput(s);
    fail(s, p.client, p.request.value.id, code, message);
    p.request.deinit();
    s.pending = null;
}
pub fn beginFrame() void {
    const s = server orelse return;
    if (s.measurement) |m| if (m.state == .running) {
        s.begin_ns = now();
    };
    s.next.clear(s.frame_id + 1);
    s.window_bounds = .{ .x = 0, .y = 0, .width = @floatFromInt(host.width()), .height = @floatFromInt(host.height()) };
}
pub fn add(target: registry.Target) void {
    const s = server orelse return;
    var clipped = target;
    clipped.clip = if (target.clip) |clip| clip.intersection(s.window_bounds) else s.window_bounds;
    s.next.add(clipped) catch {
        s.next.overflow = true;
    };
}
fn capture(path: []const u8) bool {
    const filename = a.dupeSentinel(u8, path, 0) catch return false;
    defer a.free(filename);
    const shot = host.capture() catch return false;
    defer shot.deinit();
    const encoded = png.encode(a, @intCast(shot.width), @intCast(shot.height), shot.pixels) catch return false;
    defer a.free(encoded);
    const file = c.fopen(filename, "wb") orelse return false;
    const written = c.fwrite(encoded.ptr, 1, encoded.len, file);
    const closed = c.fclose(file);
    if (written == encoded.len and closed == 0) return true;
    _ = c.unlink(filename);
    return false;
}
pub fn endFrame() void {
    const s = server orelse return;
    std.mem.swap(registry.Registry, &s.current, &s.next);
    s.frame_id += 1;
    s.frame_ns = now();
    if (s.measurement) |m| m.frame(&s.current, s.frame_ns, if (s.begin_ns > 0) s.frame_ns - s.begin_ns else 0);
    if (s.overlay) for (s.current.targets.items) |t| {
        if (!t.visible) continue;
        const bounds = t.visibleBounds();
        host.overlay(bounds, t.id);
    };
    if (s.recording != null) recordFrame(s);
    const p = s.pending orelse return;
    if (!p.done) return;
    const r = p.request.value;
    if (std.mem.eql(u8, r.op, "screenshot")) {
        var bounds: ?registry.Rect = null;
        if (r.target.len > 0) {
            for (s.current.targets.items) |target| {
                if (std.mem.eql(u8, target.id, r.target) and target.visible) {
                    if (bounds != null) return failPending(s, "target", "Ambiguous screenshot target");
                    bounds = target.visibleBounds();
                }
            }
            if (bounds == null) return failPending(s, "target", "Screenshot target is not visible in this frame");
        }
        if (!capture(r.path)) return failPending(s, "capture", "PNG capture failed");
        respond(s, p.client, r.id, .{ .frame_id = s.frame_id, .time_ns = s.frame_ns, .bounds = bounds, .window = .{ .width = host.width(), .height = host.height(), .scale = host.scale() } });
        p.request.deinit();
        s.pending = null;
        return;
    }
    if (std.mem.eql(u8, r.op, "record_start")) {
        if (s.recording != null) return failPending(s, "recording", "Recording already active");
        if (!startRecording(s, r.path)) return failPending(s, "capture", "Recording directory is not writable");
    }
    if (std.mem.eql(u8, r.op, "record_stop")) stopRecording(s);
    if (std.mem.eql(u8, r.op, "overlay")) s.overlay = std.mem.eql(u8, r.text, "on");
    respond(s, p.client, r.id, .{ .frame_id = s.frame_id, .time_ns = s.frame_ns, .injected_ns = p.consumed_ns, .consumed_ns = s.frame_ns, .drawn = true, .recorded_frames = s.record_frames, .recording_complete = s.record_complete });
    if (std.mem.eql(u8, r.op, "close")) closing = true;
    p.request.deinit();
    s.pending = null;
}
fn recordFrame(s: *Server) void {
    if (s.record_frames >= 1200 or s.record_bytes >= 512 * 1024 * 1024) {
        s.record_complete = false;
        return;
    }
    const start = now();
    const path = a.printSentinel("{s}/{d:0>6}.png", .{ s.recording.?, s.record_frames }, 0) catch {
        s.record_complete = false;
        return;
    };
    defer a.free(path);
    const ok = capture(path);
    if (!ok) s.record_complete = false;
    var stat: c.struct_stat = undefined;
    if (ok and c.stat(path, &stat) == 0) s.record_bytes += @intCast(@max(0, stat.st_size));
    const line = std.json.Stringify.valueAlloc(a, .{
        .index = s.record_frames,
        .frame_id = s.frame_id,
        .time_ns = s.frame_ns,
        .capture_ns = now() - start,
        .ok = ok,
        .targets = s.current.targets.items,
        .truncated = s.current.overflow,
        .window = .{ .width = host.width(), .height = host.height(), .scale = host.scale() },
    }, .{}) catch {
        s.record_complete = false;
        return;
    };
    defer a.free(line);
    if (s.record_file) |file| {
        if (c.fwrite(line.ptr, 1, line.len, file) != line.len or c.fputc('\n', file) < 0 or c.fflush(file) != 0) s.record_complete = false;
    }
    s.record_frames += 1;
}
fn stopRecording(s: *Server) void {
    if (s.record_file) |file| _ = c.fclose(file);
    s.record_file = null;
    if (s.recording) |path| a.free(path);
    s.recording = null;
}

fn startRecording(s: *Server, path: []const u8) bool {
    const directory = a.dupeSentinel(u8, path, 0) catch return false;
    const log = a.printSentinel("{s}/frames.jsonl", .{directory}, 0) catch {
        a.free(directory);
        return false;
    };
    defer a.free(log);
    const file = c.fopen(log, "w") orelse {
        a.free(directory);
        return false;
    };
    s.recording = directory;
    s.record_file = file;
    s.record_frames = 0;
    s.record_bytes = 0;
    s.record_complete = true;
    return true;
}
