const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol/types.zig");
const Core = @import("Core.zig");
const Transport = @import("Transport.zig");
const Self = @This();
core: *Core,
token_path: [:0]const u8,
port: u16 = 8731,
pub fn run(self: *Self) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
    var listener = try address.listen(self.core.io, .{ .reuse_address = true });
    defer listener.deinit(self.core.io);
    while (!self.core.stop.load(.acquire)) {
        const stream = try listener.accept(self.core.io);
        if (self.core.connections.fetchAdd(1, .acq_rel) >= 32) {
            _ = self.core.connections.fetchSub(1, .acq_rel);
            stream.close(self.core.io);
            continue;
        }
        const thread = std.Thread.spawn(.{}, connection, .{ self, stream }) catch {
            stream.close(self.core.io);
            _ = self.core.connections.fetchSub(1, .acq_rel);
            continue;
        };
        thread.detach();
    }
}
fn connection(self: *Self, stream: std.Io.net.Stream) void {
    defer _ = self.core.connections.fetchSub(1, .acq_rel);
    defer stream.close(self.core.io);
    u.c.zr_socket_timeout(stream.socket.handle);
    var read_buf: [16384]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = Transport.Reader.init(stream.socket.handle, &read_buf);
    var writer = Transport.Writer.init(stream.socket.handle, &write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = server.receiveHead() catch return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    self.handle(arena.allocator(), &req, stream.socket.handle) catch |err| {
        if (err == error.WriteFailed or err == error.ReadFailed or err == error.EndOfStream) return;
        const mapping = mapError(err);
        const body = u.json(arena.allocator(), .{ .error_info = t.SafeError{ .code = mapping.code, .message = mapping.message } }) catch return;
        respond(&req, body, mapping.status) catch {};
    };
}
fn token(self: *Self) ![64]u8 {
    var buf: [66]u8 = undefined;
    const n = u.c.zr_read_secret(self.token_path, &buf, buf.len);
    if (n < 0) return error.ConfigurationRequired;
    const value = std.mem.trim(u8, buf[0..@intCast(n)], "\r\n");
    if (value.len != 64) return error.ConfigurationRequired;
    for (value) |ch| if (!std.ascii.isHex(ch)) return error.ConfigurationRequired;
    return value[0..64].*;
}
fn handle(self: *Self, a: u.Allocator, req: *std.http.Server.Request, fd: c_int) !void {
    var auth: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            if (auth != null) return error.Unauthorized;
            auth = h.value;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "last-event-id")) {
            if (last != null) return error.InvalidRequest;
            last = try a.dupe(u8, h.value);
        }
    }
    const expected = try self.token();
    const authorization = auth orelse return error.Unauthorized;
    if (authorization.len != 71 or !std.mem.startsWith(u8, authorization, "Bearer ") or !std.crypto.timing_safe.eql([64]u8, authorization[7..71].*, expected)) return error.Unauthorized;
    if (req.head.transfer_compression != .identity) return error.InvalidRequest;
    if ((req.head.content_length orelse 0) > t.max_body) return error.BodyTooLarge;
    const target = try a.dupe(u8, req.head.target);
    const split = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..split];
    const query = if (split < target.len) target[split + 1 ..] else "";
    if (req.head.method == .GET and u.eq(path, "/v1/events")) {
        const after = try param(a, query, "after");
        if (after != null and last != null and !u.eq(after.?, last.?)) return error.InvalidRequest;
        const cursor = after orelse last orelse return error.InvalidRequest;
        try self.events(req, cursor, expected, fd);
        return;
    }
    var input: ?t.SendInput = null;
    if (req.head.method == .POST and u.eq(path, "/v1/messages")) {
        if (req.head.content_type == null or !std.mem.startsWith(u8, req.head.content_type.?, "application/json")) return error.InvalidRequest;
        var body_buf: [8192]u8 = undefined;
        const body_reader = try req.readerExpectContinue(&body_buf);
        const body = body_reader.allocRemaining(a, .limited(t.max_body)) catch |err| return if (err == error.StreamTooLong) error.BodyTooLarge else error.InvalidRequest;
        input = (std.json.parseFromSlice(t.SendInput, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.InvalidRequest).value;
    } else if (req.head.method != .GET) return error.NotFound;
    var response: []const u8 = undefined;
    var status: std.http.Status = .ok;
    {
        self.core.lock();
        defer self.core.unlock();
        const j = self.core.journal;
        if (input) |v| {
            const accepted = try j.accept(a, v, self.core.read_ready and self.core.automation_ready and u.now() - self.core.last_scan_ms < 5000);
            response = accepted.record;
            status = if (accepted.fresh) .accepted else .ok;
        } else if (u.eq(path, "/v1/status")) {
            response = try u.json(a, .{ .api_version = t.api_version, .server_epoch = try j.epoch(a), .adapter_ready = self.core.read_ready, .capabilities = .{ .read_history = self.core.read_ready, .live_messages = self.core.read_ready, .send_direct = self.core.read_ready and self.core.automation_ready, .reply_existing = self.core.read_ready and self.core.automation_ready, .attachments = false, .group_creation = false }, .degraded_reasons = if (self.core.degraded.len == 0) @as([]const []const u8, &.{}) else &.{self.core.degraded} });
        } else if (u.eq(path, "/v1/sync")) {
            const epoch = try j.epoch(a);
            response = try u.json(a, .{ .server_epoch = epoch, .cursor = try t.cursor(a, epoch, try j.sequence()) });
        } else if (u.eq(path, "/v1/conversations")) {
            const p = try j.page(a, null, try param(a, query, "before"), try pageLimit(a, query));
            response = try u.json(a, .{ .conversations = p.records, .next = p.next });
        } else if (std.mem.startsWith(u8, path, "/v1/conversations/") and std.mem.endsWith(u8, path, "/messages")) {
            const id = path[18 .. path.len - 9];
            if (!t.uuid(id)) return error.InvalidRequest;
            if (try j.getRecord(a, .conversation, id) == null) return error.NotFound;
            try j.execute("INSERT OR IGNORE INTO reconcile_chats(conversation_id) VALUES(?)", &.{.{ .text = id }});
            const p = try j.page(a, id, try param(a, query, "before"), try pageLimit(a, query));
            response = try u.json(a, .{ .messages = p.records, .next = p.next });
        } else if (std.mem.startsWith(u8, path, "/v1/send-requests/")) {
            const id = path[18..];
            if (!t.uuid(id)) return error.InvalidRequest;
            response = (try j.getRecord(a, .request, id)) orelse return error.NotFound;
        } else return error.NotFound;
    }
    try respond(req, response, status);
}
fn events(self: *Self, req: *std.http.Server.Request, start: []const u8, initial_token: [64]u8, fd: c_int) !void {
    if (self.core.streams.fetchAdd(1, .acq_rel) >= 8) {
        _ = self.core.streams.fetchSub(1, .acq_rel);
        return error.TooManyStreams;
    }
    defer _ = self.core.streams.fetchSub(1, .acq_rel);
    var seq: i64 = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.core.lock();
        defer self.core.unlock();
        seq = try self.core.journal.checkCursor(arena.allocator(), start);
    }
    var buffer: [8192]u8 = undefined;
    var stream = try req.respondStreaming(&buffer, .{ .respond_options = .{ .keep_alive = false, .transfer_encoding = .none, .extra_headers = &.{ .{ .name = "content-type", .value = "text/event-stream" }, .{ .name = "cache-control", .value = "no-cache" }, .{ .name = "x-accel-buffering", .value = "no" } } } });
    // Once headers are sent, close on errors; do not write a second HTTP response.
    stream.writer.writeAll(": connected\n\n") catch return;
    stream.writer.flush() catch return;
    stream.flush() catch return;
    var heartbeat = u.now();
    while (!self.core.stop.load(.acquire)) {
        if (u.c.zr_socket_closed(fd) != 0) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const frames = blk: {
            self.core.lock();
            defer self.core.unlock();
            const j = self.core.journal;
            const epoch = j.epoch(a) catch return;
            if (!std.mem.startsWith(u8, start, epoch)) return;
            const current = t.cursor(a, epoch, seq) catch return;
            _ = j.checkCursor(a, current) catch return;
            break :blk j.events(a, seq) catch return;
        };
        for (frames) |frame| {
            stream.writer.writeAll(frame.frame) catch return;
            stream.writer.flush() catch return;
            stream.flush() catch return;
            seq = frame.sequence;
        }
        if (u.now() - heartbeat >= 15000) {
            const current_token = self.token() catch return;
            if (!std.crypto.timing_safe.eql([64]u8, current_token, initial_token)) return;
            stream.writer.writeAll(": heartbeat\n\n") catch return;
            stream.writer.flush() catch return;
            stream.flush() catch return;
            heartbeat = u.now();
        }
        self.core.sleep(if (frames.len == 100) 1 else 250);
    }
}
fn respond(req: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    try req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } } });
}
fn pageLimit(a: u.Allocator, query: []const u8) !usize {
    const value = (try param(a, query, "limit")) orelse return t.default_page;
    const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRequest;
    if (n == 0 or n > t.max_page) return error.InvalidRequest;
    return n;
}
fn param(a: u.Allocator, query: []const u8, key: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    var found: ?[]const u8 = null;
    while (it.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!u.eq(part[0..split], key)) continue;
        if (found != null) return error.InvalidRequest;
        const raw = part[split + 1 ..];
        const out = try a.alloc(u8, raw.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '%') {
                if (i + 2 >= raw.len) return error.InvalidRequest;
                out[n] = std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16) catch return error.InvalidRequest;
                i += 2;
            } else out[n] = raw[i];
            n += 1;
        }
        found = out[0..n];
    }
    return found;
}
const ErrorMapping = struct { status: std.http.Status, code: []const u8, message: []const u8 };
fn mapError(err: anyerror) ErrorMapping {
    return switch (err) {
        error.Unauthorized => .{ .status = .unauthorized, .code = "unauthorized", .message = "A valid bearer token is required." },
        error.InvalidRequest => .{ .status = .bad_request, .code = "invalid_request", .message = "The request is invalid." },
        error.UnsupportedTarget => .{ .status = .bad_request, .code = "unsupported_target", .message = "Only explicit iMessage targets are supported." },
        error.RequestConflict => .{ .status = .conflict, .code = "request_conflict", .message = "This request ID already has a different payload." },
        error.ResyncRequired => .{ .status = .conflict, .code = "resync_required", .message = "Obtain a new snapshot and cursor before continuing." },
        error.CursorExpired => .{ .status = .gone, .code = "resync_required", .message = "This event cursor has expired. Synchronize again." },
        error.BodyTooLarge, error.TextTooLarge => .{ .status = .payload_too_large, .code = "invalid_request", .message = "The request exceeds the relay size limit." },
        error.NotFound => .{ .status = .not_found, .code = "not_found", .message = "The requested resource does not exist." },
        error.TooManyStreams => .{ .status = .service_unavailable, .code = "stream_limit", .message = "The event stream limit has been reached." },
        else => .{ .status = .service_unavailable, .code = "adapter_unavailable", .message = "The relay is temporarily unavailable. Check relay doctor." },
    };
}
