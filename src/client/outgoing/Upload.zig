//! One outgoing network lane. Recover the request before reserving or streaming
//! immutable originals; durable submission intent is never replayed automatically.
const std = @import("std");
const u = @import("../../common.zig");
const protocol = @import("../../protocol.zig");
const t = protocol.types;
const attachments = protocol.attachments;
const c = @import("../c.zig").api;
const Store = @import("../Store.zig");
const Files = @import("Files.zig");
const Upload = @This();

arena: std.heap.ArenaAllocator,
input: t.SendInput,
may_submit: bool,
phase: enum { lookup, reserve, transfer, submit } = .lookup,
index: usize = 0,
completed_bytes: u64 = 0,
total_bytes: u64,
fd: c_int = -1,
transport_error: c.ZcError = std.mem.zeroes(c.ZcError),
http_status: c_long = 0,

pub const Error = Store.UpsertError || Store.RecordError || Files.OpenError || error{
    InvalidUploadResponse,
    TransportFailure,
};
pub const Progress = struct {
    request_id: []const u8 = "",
    filename: []const u8 = "",
    bytes: u64 = 0,
    total: u64 = 0,
    phase: []const u8 = "",
};
const Record = struct {
    server_epoch: []const u8,
    file: attachments.Upload,
    phase: enum { reserved, receiving, ready, pinned },
};

/// Own an arena copy of this outbox payload and start an authoritative lookup.
/// The caller keeps the network alive until deinit, including cancellation.
pub fn init(gpa: u.Allocator, net: *c.ZcNet, payload: []const u8, may_submit: bool) Error!Upload {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const input = try std.json.parseFromSliceLeaky(t.SendInput, a, payload, .{ .allocate = .alloc_always });
    t.validate(input) catch return error.InvalidUploadResponse;
    try attachments.validateSet(input.attachments);
    if (input.attachments.len == 0) return error.InvalidUploadResponse;
    var total: u64 = 0;
    for (input.attachments) |file| total += try attachments.validate(file);
    const path = try std.fmt.allocPrintSentinel(a, "/v1/send-requests/{s}", .{input.request_id}, 0);
    if (c.zc_net_start(net, 4, path, null, 0) == 0) return error.TransportFailure;
    return .{
        .arena = arena,
        .input = input,
        .may_submit = may_submit,
        .total_bytes = total,
    };
}

pub fn deinit(self: *Upload, net: *c.ZcNet) void {
    c.zc_net_ack(net, 4);
    if (self.fd >= 0) _ = u.c.close(self.fd);
    self.arena.deinit();
    self.* = undefined;
}

pub fn progress(self: *const Upload, net: *c.ZcNet) Progress {
    return .{
        .request_id = self.input.request_id,
        .filename = if (self.index < self.input.attachments.len) self.input.attachments[self.index].name else "",
        .bytes = self.completed_bytes + if (self.phase == .transfer) @min(c.zc_net_upload_progress(net), self.total_bytes - self.completed_bytes) else 0,
        .total = self.total_bytes,
        .phase = @tagName(self.phase),
    };
}

/// Consume a response and start the next bounded operation. true ends this
/// attempt; retryable pre-submission work remains in the uploading outbox state.
pub fn poll(self: *Upload, net: *c.ZcNet, store: Store, files: Files) Error!bool {
    if (c.zc_net_done(net, 4) == 0) return false;
    var length: usize = 0;
    const body = c.zc_net_take_slot_body(net, 4, &length);
    defer if (body != null) u.c.free(body);
    const raw = if (body == null) "" else body[0..length];
    self.http_status = c.zc_net_status(net, 4);
    c.zc_net_error(net, 4, &self.transport_error);
    c.zc_net_ack(net, 4);
    if (self.fd >= 0) {
        _ = u.c.close(self.fd);
        self.fd = -1;
    }
    const status = if (self.transport_error.curl_code == 0) self.http_status else 0;
    if (self.phase == .lookup and status == 404) {
        if (!self.may_submit) {
            try store.outcome(self.input.request_id, "unconfirmed", "The relay has no record of this request. Its files are retained; it will not be sent again automatically.");
            return true;
        }
        try self.reserve(net);
        return false;
    }
    if (status < 200 or status >= 300) {
        const busy = busy: {
            if (status != 409) break :busy false;
            try protocol.json.check(raw, t.max_body, 256);
            const failure = try std.json.parseFromSliceLeaky(struct { error_info: t.SafeError }, self.arena.allocator(), raw, .{ .ignore_unknown_fields = true });
            break :busy u.eq(failure.error_info.code, "upload_busy");
        };
        const rejected = status == 400 or status == 401 or status == 403 or (status == 409 and !busy) or status == 410 or status == 413;
        try store.outcome(
            self.input.request_id,
            if (rejected) "failed" else if (self.may_submit) "uploading" else "unknown",
            if (rejected) "Attachment request rejected. Originals are retained; review the connection or copy the files into a new draft." else if (self.may_submit) "Upload interrupted. Retrying the same attachment IDs." else "Outcome uncertain. Checking the original request ID; no automatic resend.",
        );
        return true;
    }
    // 512 KiB and 32,768 tokens bound reservation responses before typed parsing.
    try protocol.json.check(raw, 512 * 1024, 32768);
    const a = self.arena.allocator();
    switch (self.phase) {
        .lookup, .submit => {
            const record = try std.json.parseFromSliceLeaky(t.SendRequest, a, raw, .{ .ignore_unknown_fields = true });
            if (!u.eq(record.request_id, self.input.request_id) or !u.eq(record.server_epoch, self.input.server_epoch))
                return error.InvalidUploadResponse;
            _ = try store.upsert(a, "request", raw);
            return true;
        },
        .reserve, .transfer => {
            const record = try std.json.parseFromSliceLeaky(Record, a, raw, .{ .ignore_unknown_fields = true });
            if (!u.eq(record.server_epoch, self.input.server_epoch) or
                !u.eq(try u.json(a, record.file), try u.json(a, self.input.attachments[self.index])))
                return error.InvalidUploadResponse;
            switch (record.phase) {
                .ready => {
                    self.completed_bytes += try attachments.validate(record.file);
                    self.index += 1;
                    if (self.index < self.input.attachments.len) {
                        try self.reserve(net);
                    } else {
                        // Persist intent before the first possible POST byte. A
                        // crash from here requires lookup, never automatic replay.
                        try store.outcome(self.input.request_id, "sending", "Submitting attachments…");
                        self.may_submit = false;
                        self.phase = .submit;
                        const payload = try u.json(a, self.input);
                        if (c.zc_net_start(net, 4, "/v1/messages", payload.ptr, payload.len) == 0)
                            return error.TransportFailure;
                    }
                },
                .reserved => {
                    if (self.phase != .reserve) return error.InvalidUploadResponse;
                    self.fd = try files.open(record.file);
                    const path = try std.fmt.allocPrintSentinel(a, "/v1/uploads/{s}", .{record.file.id}, 0);
                    const epoch = try a.dupeZ(u8, self.input.server_epoch);
                    self.phase = .transfer;
                    if (c.zc_net_upload(net, path, epoch, self.fd, try attachments.validate(record.file)) == 0)
                        return error.TransportFailure;
                },
                .receiving => {
                    try store.outcome(self.input.request_id, "uploading", "Waiting for the interrupted upload to close…");
                    return true;
                },
                .pinned => return error.InvalidUploadResponse,
            }
            return false;
        },
    }
}

fn reserve(self: *Upload, net: *c.ZcNet) !void {
    self.phase = .reserve;
    const body = try u.json(self.arena.allocator(), .{
        .server_epoch = self.input.server_epoch,
        .file = self.input.attachments[self.index],
    });
    if (c.zc_net_start(net, 4, "/v1/uploads", body.ptr, body.len) == 0) return error.TransportFailure;
}
