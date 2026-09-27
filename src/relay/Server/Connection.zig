//! A single thread owns TLS, the HTTP/2 engine, and up to sixteen independent streams.
const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol.zig").types;
const protocol = @import("../http2.zig");
const Tls = @import("../Tls.zig");
const Server = @import("../Server.zig");
pub const Request = @import("Request.zig");
const Connection = @This();

server: *Server,
peer: *Tls.c.ZrTls,
engine: protocol.Session(Connection) = undefined,
requests: [16]?*Request = @splat(null),
accepted: usize = 0,
last_id: i32 = 0,
idle_deadline: i64,

pub const RunError = protocol.Error || error{ ReadFailed, WriteFailed };

/// Borrows server and peer for the connection lifetime; releases all stream storage on exit.
pub fn run(self: *Connection) RunError!void {
    try self.engine.init(std.heap.page_allocator, self, .{ .streams = self.requests.len });
    defer {
        self.engine.deinit();
        for (self.requests) |item| if (item) |req| {
            req.deinit();
            std.heap.page_allocator.destroy(req);
        };
    }
    var input: [16384]u8 = undefined;
    while (!self.server.core.stop.load(.acquire) and Tls.c.zr_tls_valid(self.peer) != 0) {
        const now = u.c.zr_monotonic_ms();
        var active = false;
        for (self.requests) |item| {
            const req = item orelse continue;
            active = true;
            if ((req.events == null or req.offset < req.response.len) and now >= req.deadline) {
                try self.engine.reset(req.id);
                continue;
            }
            if (req.ready and !req.responded) {
                self.server.handle(req.arena.allocator(), req, self.peer) catch |err| {
                    if (err == error.CertificateExpired) return;
                    self.server.respondError(req, err) catch return;
                };
            }
            if (req.events != null and req.offset == req.response.len) {
                self.server.pollEvents(req) catch {
                    try self.engine.reset(req.id);
                    continue;
                };
            }
        }
        // Flush a bounded batch, then service input/window updates and other streams.
        var sent: usize = 0;
        while (sent < 256 * 1024) {
            const bytes = try self.engine.output();
            if (bytes.len == 0) break;
            if (Tls.c.zr_tls_write(self.peer, bytes.ptr, bytes.len) != 0) return error.WriteFailed;
            sent += bytes.len;
        }
        if (!self.engine.wantsRead()) return;
        if (active) self.idle_deadline = now + 10000 else if (now >= self.idle_deadline) return;
        const ready = if (sent >= 256 * 1024) 1 else Tls.c.zr_tls_poll(self.peer, 50);
        if (ready < 0) return error.ReadFailed;
        if (ready > 0) {
            const count = Tls.c.zr_tls_receive(self.peer, &input, input.len);
            if (count == -2) continue;
            if (count <= 0) return error.ReadFailed;
            const received: usize = @intCast(count);
            if (try self.engine.receive(input[0..received]) != received) return error.Protocol;
        }
    }
}

fn find(self: *Connection, id: i32) ?*Request {
    for (self.requests) |item| if (item) |req| {
        if (req.id == id) return req;
    };
    return null;
}

pub fn begin(self: *Connection, id: i32, trailers: bool) protocol.Error!void {
    // The API has no trailer fields; rejecting them avoids ambiguous request metadata.
    if (trailers) return error.Protocol;
    if (self.accepted >= 64) return error.RefusedStream;
    for (&self.requests) |*slot| {
        if (slot.* != null) continue;
        const req = try std.heap.page_allocator.create(Request);
        req.* = .{
            .connection = self,
            .id = id,
            .deadline = u.c.zr_monotonic_ms() + 10000,
        };
        slot.* = req;
        self.accepted += 1;
        self.last_id = id;
        if (self.accepted == 64) try self.engine.shutdown(self.last_id);
        return;
    }
    return error.RefusedStream;
}

pub fn header(self: *Connection, id: i32, name: []const u8, value: []const u8) protocol.Error!void {
    const req = self.find(id) orelse return error.Protocol;
    const a = req.arena.allocator();
    if (u.eq(name, ":method")) {
        req.head.method = std.meta.stringToEnum(std.http.Method, value) orelse return error.Protocol;
    } else if (u.eq(name, ":path")) {
        if (value.len == 0 or value[0] != '/' or std.mem.startsWith(u8, value, "//")) return error.Protocol;
        req.head.target = try a.dupe(u8, value);
    } else if (u.eq(name, ":scheme")) {
        if (!u.eq(value, "https")) return error.Protocol;
    } else if (u.eq(name, "content-length")) {
        if (req.head.content_length != null) return error.Protocol;
        req.head.content_length = std.fmt.parseInt(u64, value, 10) catch return error.Protocol;
    } else if (u.eq(name, "content-type")) {
        if (req.head.content_type != null) return error.Protocol;
        req.head.content_type = try a.dupe(u8, value);
    } else if (name[0] != ':') {
        if (u.eq(name, "content-encoding") and !u.eq(value, "identity")) req.rejected = error.InvalidRequest;
        try req.headers.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) });
    }
}

pub fn head(self: *Connection, id: i32, _: bool) protocol.Error!void {
    const req = self.find(id) orelse return error.Protocol;
    if (req.head.target.len == 0) return error.Protocol;
    if ((req.head.content_length orelse 0) > t.max_body) req.rejected = error.BodyTooLarge;
    if (req.rejected != null) {
        req.ready = true;
        return;
    }
    for (req.headers.items) |h| if (u.eq(h.name, "expect")) {
        if (std.ascii.eqlIgnoreCase(h.value, "100-continue")) try self.engine.inform(id) else return error.Protocol;
    };
}

pub fn body(self: *Connection, id: i32, bytes: []const u8) protocol.Error!void {
    const req = self.find(id) orelse return error.Protocol;
    if (bytes.len > t.max_body - req.body.items.len) {
        req.rejected = error.BodyTooLarge;
        req.ready = true;
    }
    if (req.rejected == null) try req.body.appendSlice(req.arena.allocator(), bytes);
    // The request body has a separate hard cap, so credit only after copying or discarding it.
    try self.engine.consume(id, bytes.len);
}

pub fn end(self: *Connection, id: i32) protocol.Error!void {
    const req = self.find(id) orelse return error.Protocol;
    req.ended = true;
    req.ready = true;
}

pub fn produce(self: *Connection, id: i32, destination: []u8) protocol.Error!?usize {
    const req = self.find(id) orelse return error.Protocol;
    const bytes = req.response[req.offset..];
    if (bytes.len == 0 and req.events != null) return null;
    const count = @min(bytes.len, destination.len);
    @memcpy(destination[0..count], bytes[0..count]);
    req.offset += count;
    return count;
}

pub fn producedEnd(self: *Connection, id: i32) bool {
    const req = self.find(id) orelse return false;
    return req.events == null and req.offset == req.response.len;
}

pub fn responseEnd(self: *Connection, id: i32) protocol.Error!void {
    const req = self.find(id) orelse return;
    if (!req.ended) try self.engine.finishInput(id);
}

pub fn closed(self: *Connection, id: i32, _: u32) void {
    for (&self.requests) |*slot| if (slot.*) |req| {
        if (req.id != id) continue;
        req.deinit();
        std.heap.page_allocator.destroy(req);
        slot.* = null;
        return;
    };
}
