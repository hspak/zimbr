//! Authenticated upload routes and the streaming request lifecycle.
const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol.zig").types;
const attachments = @import("../../protocol.zig").attachments;
const json_bounds = @import("../../protocol.zig").json;
const uploads = @import("../uploads.zig");
const Server = @import("../Server.zig");
const Request = @import("Request.zig");
const Tls = @import("../Tls.zig");
const http2 = @import("../http2.zig");

pub const Error = Request.RejectError || uploads.ReserveError || uploads.CancelError ||
    uploads.CompleteError || http2.Error || error{NotFound};

/// Validate and claim the upload before reading bytes or sending 100 Continue.
/// Request owns the lease even if file preparation subsequently fails.
pub fn begin(server: *Server, req: *Request, peer: *Tls.c.ZrTls) Request.RejectError!void {
    if (!std.ascii.eqlIgnoreCase(req.head.content_type orelse "", "application/octet-stream"))
        return error.InvalidRequest;
    const length = req.head.content_length orelse return error.InvalidRequest;
    if (length > attachments.max_file_bytes) return error.BodyTooLarge;
    const id = try uploadId(req.head.target);
    const epoch = try requestEpoch(req);
    const files = server.core.upload_files orelse return error.UploadStorageUnavailable;
    var owner: [65]u8 = undefined;
    if (Tls.c.zr_tls_peer_fingerprint(peer, &owner) != 0) return error.CertificateExpired;
    if (server.uploads_active.fetchAdd(1, .acq_rel) >= 4) {
        _ = server.uploads_active.fetchSub(1, .acq_rel);
        return error.UploadBusy;
    }
    req.upload_permit = true;
    const a = req.arena.allocator();
    const claimed = claimed: {
        server.core.lock();
        defer server.core.unlock();
        if (server.core.reset_required) return error.RelayCacheResetRequired;
        const found = try uploads.lookup(server.core.journal, a, owner[0..64], epoch, id);
        if (length != try attachments.validate(found.file)) return error.UploadLengthMismatch;
        break :claimed try uploads.claim(server.core.journal, a, owner[0..64], epoch, id);
    };
    switch (claimed) {
        .complete => |record| {
            const fd = try files.open(a, record.file);
            _ = u.c.close(fd);
            // A completed PUT retry is answered without rewriting its bytes.
            // Defer response serialization to handle(), outside HTTP/2 callbacks.
            req.response = try u.json(a, record);
            req.ready = true;
        },
        .write => |lease| {
            req.upload = .{ .lease = lease };
            req.upload.?.transfer = try files.begin(a, lease);
        },
    }
    const now = u.c.zr_monotonic_ms();
    req.upload_deadline = now + 15 * 60 * 1000;
    req.deadline = now + 30000;
}

/// Finish a body or serve a small upload command. The connection owns this call.
pub fn handle(server: *Server, a: u.Allocator, req: *Request, peer: *Tls.c.ZrTls) Error!void {
    if (server.core.upload_files == null) return error.UploadStorageUnavailable;
    var owner: [65]u8 = undefined;
    if (Tls.c.zr_tls_peer_fingerprint(peer, &owner) != 0) return error.CertificateExpired;
    if (req.head.method == .PUT) {
        if (!req.upload_route) return error.InvalidRequest;
        if (req.upload) |*upload| {
            if (!req.ended) return error.InvalidRequest;
            try upload.transfer.?.seal();
            if (Tls.c.zr_tls_valid(peer) == 0) return error.CertificateExpired;
            {
                server.core.lock();
                defer server.core.unlock();
                try uploads.complete(server.core.journal, a, upload.lease);
            }
            upload.transfer.?.publish();
            try respond(req, try u.json(a, uploads.Record{
                .server_epoch = upload.lease.server_epoch,
                .file = upload.lease.file,
                .phase = .ready,
            }), .ok);
        } else try respond(req, req.response, .ok);
        return;
    }
    server.core.lock();
    defer server.core.unlock();
    if (server.core.reset_required) return error.RelayCacheResetRequired;
    if (req.head.method == .POST and u.eq(req.head.target, "/v1/uploads")) {
        if (!std.ascii.eqlIgnoreCase(req.head.content_type orelse "", "application/json"))
            return error.InvalidRequest;
        json_bounds.check(req.body.items, t.max_body, 256) catch return error.InvalidRequest;
        const value = std.json.parseFromSliceLeaky(struct {
            server_epoch: []const u8,
            file: attachments.Upload,
        }, a, req.body.items, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidRequest;
        };
        const record = try uploads.reserve(server.core.journal, a, owner[0..64], value.server_epoch, value.file, u.now());
        try respond(req, try u.json(a, record), .ok);
        return;
    }
    const id = try uploadId(req.head.target);
    const epoch = try requestEpoch(req);
    switch (req.head.method) {
        .GET => try respond(req, try u.json(a, try uploads.lookup(server.core.journal, a, owner[0..64], epoch, id)), .ok),
        .DELETE => {
            if (req.body.items.len != 0 or (req.head.content_length orelse 0) != 0) return error.InvalidRequest;
            uploads.cancel(server.core.journal, a, owner[0..64], epoch, id) catch |err| switch (err) {
                error.UploadNotFound, error.UploadExpired => {},
                else => return err,
            };
            try respond(req, "", .no_content);
        },
        else => return error.NotFound,
    }
}

fn uploadId(target: []const u8) error{InvalidRequest}![]const u8 {
    if (!std.mem.startsWith(u8, target, "/v1/uploads/")) return error.InvalidRequest;
    const id = target[12..];
    if (!t.validId(id)) return error.InvalidRequest;
    return id;
}

fn requestEpoch(req: *const Request) error{InvalidRequest}![]const u8 {
    var epoch: ?[]const u8 = null;
    for (req.headers.items) |header| if (u.eq(header.name, "zimbr-server-epoch")) {
        if (epoch != null or !t.validId(header.value)) return error.InvalidRequest;
        epoch = header.value;
    };
    return epoch orelse error.InvalidRequest;
}

fn respond(req: *Request, bytes: []const u8, status: std.http.Status) http2.Error!void {
    try req.respond(bytes, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}
