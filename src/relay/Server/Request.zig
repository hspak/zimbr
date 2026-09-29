//! One HTTP/2 stream. Its arenas own the request, response, and current SSE batch.
const std = @import("std");
const u = @import("../../common.zig");
const protocol = @import("../http2.zig");
const Connection = @import("Connection.zig");
const uploads = @import("../uploads.zig");
const Request = @This();

connection: *Connection,
id: i32,
arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
batch: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
head: Head = .{},
headers: std.ArrayList(std.http.Header) = .empty,
body: std.ArrayList(u8) = .empty,
response: []const u8 = "",
offset: usize = 0,
ready: bool = false,
ended: bool = false,
responded: bool = false,
rejected: ?RejectError = null,
deadline: i64,
events: ?Events = null,
asset_permit: bool = false,
upload_route: bool = false,
upload_permit: bool = false,
upload_deadline: i64 = 0,
upload: ?struct {
    lease: uploads.Lease,
    transfer: ?uploads.Files.Transfer = null,
} = null,

pub const RejectError = uploads.ClaimError || uploads.Files.BeginError ||
    uploads.Files.OpenError || uploads.Files.Transfer.SealError || error{
    BodyTooLarge,
    CertificateExpired,
    RelayCacheResetRequired,
};

pub const Head = struct {
    method: std.http.Method = .GET,
    target: []const u8 = "",
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
};
pub const Events = struct {
    start: []const u8,
    sequence: i64,
    identities: bool,
    heartbeat: i64,
    observed: ?u32 = null,
    check_at: i64 = 0,
};
pub const RespondOptions = struct {
    status: std.http.Status = .ok,
    extra_headers: []const std.http.Header = &.{},
};
pub const HeaderIterator = struct {
    remaining: []const std.http.Header,
    pub fn next(self: *HeaderIterator) ?std.http.Header {
        if (self.remaining.len == 0) return null;
        const header = self.remaining[0];
        self.remaining = self.remaining[1..];
        return header;
    }
};

pub fn iterateHeaders(self: *const Request) HeaderIterator {
    return .{ .remaining = self.headers.items };
}

/// Borrows body until stream closure; headers are copied by the protocol engine.
pub fn respond(self: *Request, body: []const u8, options: RespondOptions) protocol.Error!void {
    var length: [20]u8 = undefined;
    const count = std.fmt.bufPrint(&length, "{d}", .{body.len}) catch unreachable;
    var headers: [16]std.http.Header = undefined;
    if (options.extra_headers.len >= headers.len) return error.HeaderListTooLarge;
    @memcpy(headers[0..options.extra_headers.len], options.extra_headers);
    var len = options.extra_headers.len;
    if (self.events == null and options.status != .not_modified and options.status != .no_content) {
        headers[len] = .{ .name = "content-length", .value = count };
        len += 1;
    }
    try self.connection.engine.respond(self.id, @intFromEnum(options.status), headers[0..len], self.events != null or body.len != 0);
    self.responded = true;
    self.response = body;
    self.offset = 0;
    self.deadline = u.c.zr_monotonic_ms() + 10000;
}

pub fn deinit(self: *Request) void {
    if (self.upload) |*upload| {
        // Files close before the lease is released for another writer.
        if (upload.transfer) |*transfer| transfer.deinit();
        const core = self.connection.server.core;
        core.lock();
        defer core.unlock();
        core.releaseUpload(upload.lease);
    }
    if (self.upload_permit) _ = self.connection.server.uploads_active.fetchSub(1, .acq_rel);
    if (self.events != null) _ = self.connection.server.core.streams.fetchSub(1, .acq_rel);
    if (self.asset_permit) _ = self.connection.server.asset_responses.fetchSub(1, .acq_rel);
    self.batch.deinit();
    self.arena.deinit();
    self.* = undefined;
}
