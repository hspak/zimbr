const std = @import("std");
const json_bounds = @import("../protocol.zig").json;
const contact_directory = @import("adapter/contacts.zig");
const enrichment = @import("enrichment.zig");
const reactions = @import("reactions.zig");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const Core = @import("Core.zig");
const Journal = @import("Journal.zig");
const Connection = @import("Server/Connection.zig");
const http2 = @import("http2.zig");
const Request = Connection.Request;
const Tls = @import("Tls.zig");
const Assets = @import("Assets.zig");
const Server = @This();

core: *Core,
tls: Tls,
listening: ?*std.atomic.Value(bool) = null,
handshakes: std.atomic.Value(usize) = .init(0),
asset_responses: std.atomic.Value(usize) = .init(0),

pub const RunError = std.Io.net.Ip6Address.ParseError || std.Io.net.IpAddress.ListenError ||
    std.Io.net.Server.AcceptError;

pub const HandleError = http2.Error || Journal.AcceptError || Journal.CheckCursorError ||
    Journal.ResetError || Assets.LookupError || Assets.EvictedError || enrichment.PageError || std.fmt.ParseIntError || error{
    BodyTooLarge,
    CertificateExpired,
    AssetResponseLimit,
    AssetServiceUnavailable,
    ContactsUnavailable,
    InvalidAsset,
    UnsupportedExtension,
    TooManyStreams,
    RelayCacheResetRequired,
};
pub const PollEventsError = http2.Error || Journal.EventsError || Journal.CheckCursorError ||
    std.Io.Writer.Error;

fn readiness(supported: bool, ready: bool, reason: []const u8) struct { ready: bool, reason: []const u8 } {
    if (!supported) return .{ .ready = false, .reason = "native_acceptance_pending" };
    return .{ .ready = ready, .reason = if (ready) "" else reason };
}
pub fn run(self: *Server) RunError!void {
    const address = try std.Io.net.IpAddress.parse(
        self.tls.config.listen_address,
        self.tls.config.port,
    );
    var listener = try address.listen(self.core.io, .{ .reuse_address = true });
    defer listener.deinit(self.core.io);
    if (self.listening) |ready| ready.store(true, .release);
    defer if (self.listening) |ready| ready.store(false, .release);
    std.debug.print(
        "relay: HTTP/2 mTLS listening on {s}:{d}\n",
        .{ self.tls.config.listen_address, self.tls.config.port },
    );
    while (!self.core.stop.load(.acquire)) {
        const stream = try listener.accept(self.core.io);
        if (self.core.connections.fetchAdd(1, .acq_rel) >= 32) {
            _ = self.core.connections.fetchSub(1, .acq_rel);
            stream.close(self.core.io);
            continue;
        }
        if (self.handshakes.fetchAdd(1, .acq_rel) >= 4) {
            _ = self.handshakes.fetchSub(1, .acq_rel);
            _ = self.core.connections.fetchSub(1, .acq_rel);
            stream.close(self.core.io);
            continue;
        }
        const thread = std.Thread.spawn(.{}, connection, .{ self, stream }) catch {
            stream.close(self.core.io);
            _ = self.handshakes.fetchSub(1, .acq_rel);
            _ = self.core.connections.fetchSub(1, .acq_rel);
            continue;
        };
        thread.detach();
    }
}
fn connection(self: *Server, stream: std.Io.net.Stream) void {
    u.c.zr_thread_qos(1);
    defer _ = self.core.connections.fetchSub(1, .acq_rel);
    defer stream.close(self.core.io);
    const connection_tls = Tls.c.zr_tls_accept(self.tls.context, stream.socket.handle);
    _ = self.handshakes.fetchSub(1, .acq_rel);
    const peer = connection_tls orelse return;
    defer Tls.c.zr_tls_free(peer);
    var session: Connection = .{
        .server = self,
        .peer = peer,
        .idle_deadline = u.c.zr_monotonic_ms() + 10000,
    };
    session.run() catch {};
}
/// Queues a safe API error, or resets a stream whose response has already begun.
pub fn respondError(self: *Server, req: *Request, err: anytype) http2.Error!void {
    _ = self;
    if (req.responded) return req.connection.engine.reset(req.id);
    const mapping = mapError(err);
    const body = try u.json(req.arena.allocator(), .{
        .error_info = t.SafeError{ .code = mapping.code, .message = mapping.message },
    });
    try respond(req, body, mapping.status);
}
/// Dispatches a complete bounded request on its connection owner.
pub fn handle(self: *Server, a: u.Allocator, req: *Request, peer: *Tls.c.ZrTls) HandleError!void {
    var last: ?[]const u8 = null;
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "last-event-id")) {
            if (last != null) return error.InvalidRequest;
            last = try a.dupe(u8, h.value);
        }
    }
    if (req.rejected) |err| return err;
    if (Tls.c.zr_tls_valid(peer) == 0) return error.CertificateExpired;
    if ((req.head.content_length orelse 0) > t.max_body) return error.BodyTooLarge;
    if (req.head.method == .GET and ((req.head.content_length orelse 0) != 0 or req.body.items.len != 0)) return error.InvalidRequest;
    const target = try a.dupe(u8, req.head.target);
    const split = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..split];
    const query = if (split < target.len) target[split + 1 ..] else "";
    const resetting = req.head.method == .POST and u.eq(path, "/v1/reset");
    self.core.lock();
    const reset_required = self.core.reset_required;
    self.core.unlock();
    if (reset_required and !resetting and !(req.head.method == .GET and u.eq(path, "/v1/status")))
        return error.RelayCacheResetRequired;
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/v1/assets/")) {
        // Four media responses leave capacity for SSE and ordinary commands.
        if (self.asset_responses.fetchAdd(1, .acq_rel) >= 4) {
            _ = self.asset_responses.fetchSub(1, .acq_rel);
            return error.AssetResponseLimit;
        }
        req.asset_permit = true;
        try self.asset(a, req, path[11..], peer);
        return;
    }
    if (req.head.method == .GET and u.eq(path, "/v1/events")) {
        const after = try param(a, query, "after");
        if (after != null and last != null and !u.eq(after.?, last.?)) return error.InvalidRequest;
        const cursor = after orelse last orelse return error.InvalidRequest;
        const identities = try identityExtension(try param(a, query, "extensions"));
        try self.events(req, cursor, identities);
        return;
    }
    var input: ?t.SendInput = null;
    var reset_epoch: ?[]const u8 = null;
    if (resetting or (req.head.method == .POST and u.eq(path, "/v1/messages"))) {
        const content_type = req.head.content_type orelse return error.InvalidRequest;
        var media_type = std.mem.splitScalar(u8, content_type, ';');
        if (!std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, media_type.first(), " \t"),
            "application/json",
        )) return error.InvalidRequest;
        const body = req.body.items;
        json_bounds.check(body, t.max_body, 8192) catch return error.InvalidRequest;
        if (resetting) {
            if (query.len != 0) return error.InvalidRequest;
            const value = std.json.parseFromSliceLeaky(
                struct { server_epoch: []const u8 },
                a,
                body,
                .{},
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return error.InvalidRequest;
            };
            if (value.server_epoch.len == 0 or value.server_epoch.len > 128) return error.InvalidRequest;
            reset_epoch = value.server_epoch;
        } else input = (std.json.parseFromSlice(
            t.SendInput,
            a,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidRequest;
        }).value;
    } else if (req.head.method != .GET) return error.NotFound;
    if (Tls.c.zr_tls_valid(peer) == 0) return error.CertificateExpired;
    var response: []const u8 = undefined;
    var status: std.http.Status = .ok;
    {
        self.core.lock();
        defer self.core.unlock();
        const j = self.core.journal;
        if (reset_epoch) |expected| {
            const current = try j.epoch(a);
            const fresh = u.eq(expected, current);
            if (fresh) {
                try j.begin();
                errdefer j.rollback();
                try j.reset(a);
                const epoch = try j.epoch(a);
                response = try u.json(a, .{
                    .server_epoch = epoch,
                    .cursor = try t.cursor(a, epoch, try j.sequence()),
                });
                try j.commit();
                self.core.reset_required = false;
                self.core.read_ready = false;
                self.core.last_scan_ms = 0;
                self.core.ingest_pending = true;
                // The Contacts worker retains its source index across journal resets.
                // Keep its freshness and permission while rebuilding identity matches.
                if (self.core.contacts_status.ready) {
                    self.core.contacts_status.ready = false;
                    self.core.contacts_status.reason = "reconciling";
                }
                self.core.degraded = "rebuilding_cache";
            } else {
                // A lost response or another client's reset must not reset twice.
                if (!t.validId(current)) return error.ResyncRequired;
                response = try u.json(a, .{
                    .server_epoch = current,
                    .cursor = try t.cursor(a, current, try j.sequence()),
                });
            }
        } else if (input) |v| {
            const accepted = try j.accept(
                a,
                v,
                self.core.read_ready and self.core.automation_ready and u.now() - self.core.last_scan_ms < 5000,
            );
            if (accepted.fresh) self.core.send_ready.notify(self.core.io);
            response = accepted.record;
            status = if (accepted.fresh) .accepted else .ok;
        } else if (u.eq(path, "/v1/status")) {
            const contacts = contact_directory.currentStatus(self.core.contacts_status);
            response = try u.json(a, .{
                .api_version = t.api_version,
                .event_extensions = [_][]const u8{"identity-v1"},
                .server_epoch = try j.epoch(a),
                .adapter_ready = self.core.read_ready,
                .sync_activity = try self.core.syncActivity(),
                .source_features = self.core.source_features,
                .capabilities = .{
                    .state_reset_v1 = true,
                    .read_history = self.core.read_ready,
                    .live_messages = self.core.read_ready,
                    .send_direct = self.core.read_ready and self.core.automation_ready,
                    .reply_existing = self.core.read_ready and self.core.automation_ready,
                    .attachments = true,
                    .send_attachments_v1 = false,
                    .group_creation = false,
                    .identity_directory_v1 = true,
                    .image_assets_v1 = true,
                    .image_attachments_v1 = true,
                    .stored_link_previews_v1 = true,
                    .reactions_v1 = true,
                    .contact_avatars_v1 = true,
                    .text_first_history_v1 = true,
                },
                .enrichment_readiness = .{
                    .identity_directory_v1 = contacts,
                    .image_assets_v1 = readiness(
                        true,
                        self.core.assets_service != null,
                        self.core.assets_reason,
                    ),
                    .image_attachments_v1 = readiness(
                        true,
                        self.core.assets_service != null and self.core.read_ready and self.core.source_features.attachment_filename,
                        if (self.core.assets_service == null) self.core.assets_reason else if (!self.core.read_ready) self.core.degraded else "source_columns_unavailable",
                    ),
                    .stored_link_previews_v1 = readiness(
                        true,
                        self.core.read_ready and self.core.source_features.link_payload,
                        if (!self.core.read_ready) self.core.degraded else "source_columns_unavailable",
                    ),
                    .reactions_v1 = readiness(
                        true,
                        self.core.read_ready and self.core.source_features.reaction_target,
                        "source_columns_unavailable",
                    ),
                    .contact_avatars_v1 = readiness(
                        true,
                        contacts.ready and self.core.assets_service != null,
                        if (self.core.assets_service == null) self.core.assets_reason else contacts.reason,
                    ),
                },
                .degraded_reasons = if (self.core.degraded.len == 0) @as([]const []const u8, &.{}) else &.{self.core.degraded},
            });
        } else if (u.eq(path, "/v1/sync")) {
            const epoch = try j.epoch(a);
            response = try u.json(
                a,
                .{ .server_epoch = epoch, .cursor = try t.cursor(a, epoch, try j.sequence()) },
            );
        } else if (u.eq(path, "/v1/conversations")) {
            const before = try param(a, query, "before");
            const limit = try pageLimit(a, query);
            const p = try j.page(a, null, before, limit);
            const previews = if (u.eq((try param(a, query, "previews")) orelse "", "1")) try j.previews(
                a,
                before,
                limit,
            ) else null;
            response = try u.json(a, .{
                .conversations = p.records,
                .next = p.next,
                .previews = previews,
            });
        } else if (u.eq(path, "/v1/identities")) {
            const p = try j.identityPage(a, try param(a, query, "before"), try pageLimit(a, query));
            response = try u.json(a, .{ .identities = p.records, .next = p.next });
        } else if (std.mem.startsWith(u8, path, "/v1/messages/") and std.mem.endsWith(
            u8,
            path,
            "/enrichment",
        )) {
            const id = path[13 .. path.len - 11];
            if (!t.validId(id)) return error.InvalidRequest;
            const name = (try param(a, query, "section")) orelse return error.InvalidRequest;
            const section = std.meta.stringToEnum(enrichment.Section, name) orelse return error.InvalidRequest;
            const revision = (try param(a, query, "revision")) orelse return error.InvalidRequest;
            response = try u.json(
                a,
                try enrichment.page(a, j, id, section, revision, try param(a, query, "after"), try pageLimit(a, query)),
            );
        } else if (std.mem.startsWith(u8, path, "/v1/conversations/") and std.mem.endsWith(
            u8,
            path,
            "/messages",
        )) {
            const id = path[18 .. path.len - 9];
            if (!t.validId(id)) return error.InvalidRequest;
            if (try j.getRecord(a, .conversation, id) == null) return error.NotFound;
            const text_only = u.eq((try param(a, query, "content")) orelse "", "text");
            for (try j.threadMembers(a, id)) |member| {
                try j.execute(
                    "INSERT OR IGNORE INTO reconcile_chats(conversation_id) VALUES(?)",
                    &.{.{ .text = member }},
                );
                if (!text_only) {
                    if (self.core.assets_service != null) try Assets.prioritizeConversation(
                        j,
                        member,
                    );
                    try reactions.prioritize(j, member);
                }
            }
            const p = try j.pageContent(
                a,
                id,
                try param(a, query, "before"),
                try pageLimit(a, query),
                text_only,
            );
            response = try u.json(a, .{ .messages = p.records, .next = p.next });
        } else if (std.mem.startsWith(u8, path, "/v1/messages/")) {
            const id = path[13..];
            if (!t.validId(id)) return error.InvalidRequest;
            const message = try j.db.prepare("SELECT record,source FROM messages WHERE id=?");
            defer message.close();
            try message.bind(&.{.{ .text = id }});
            if (!try message.step()) return error.NotFound;
            response = try message.text(a, 0);
            // Only visible messages request fresh media and reaction metadata.
            if (self.core.assets_service != null) try j.execute(
                "UPDATE asset_sources SET check_ms=0 WHERE id IN(SELECT asset_id FROM asset_owners WHERE owner_id=? AND kind IN('message','preview'))",
                &.{.{ .text = message.bytes(1) }},
            );
            try j.execute(
                "UPDATE reaction_sources SET check_ms=0 WHERE target_guid=? AND retired=0",
                &.{.{ .text = message.bytes(1) }},
            );
        } else if (std.mem.startsWith(u8, path, "/v1/send-requests/")) {
            const id = path[18..];
            if (!t.validId(id)) return error.InvalidRequest;
            response = (try j.getRecord(a, .request, id)) orelse return error.NotFound;
        } else return error.NotFound;
    }
    try respond(req, response, status);
}
fn asset(
    self: *Server,
    a: u.Allocator,
    req: *Request,
    path: []const u8,
    peer: *Tls.c.ZrTls,
) !void {
    const service = self.core.assets_service orelse return error.AssetServiceUnavailable;
    var components = std.mem.splitScalar(u8, path, '/');
    const id = components.next() orelse return error.InvalidRequest;
    const version = components.next() orelse return error.InvalidRequest;
    const variant_name = components.next() orelse return error.InvalidRequest;
    if (!t.validId(id) or !t.validId(version) or components.next() != null) return error.InvalidRequest;
    const variant = std.meta.stringToEnum(Assets.Variant, variant_name) orelse return error.InvalidRequest;
    var if_none_match: ?[]const u8 = null;
    var headers = req.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
        if (if_none_match != null) return error.InvalidRequest;
        if_none_match = header.value;
    };
    const value = value: {
        self.core.lock();
        defer self.core.unlock();
        const j = self.core.journal;
        if (variant == .avatar and !contact_directory.canPresent(self.core.contacts_status)) return error.ContactsUnavailable;
        try j.begin();
        errdefer j.rollback();
        const found = try Assets.lookup(a, j, id, version, variant);
        try j.commit();
        break :value found;
    };
    if (value.ref.availability != .ready or value.file_name == null or value.etag == null) return assetPending(
        a,
        req,
        value.ref,
    );
    const size = std.fmt.parseInt(usize, value.ref.bytes orelse "", 10) catch return error.InvalidAsset;
    if (size > Assets.max_derivative) return error.InvalidAsset;
    const fd = Assets.c.zr_media_cached(service.cache_fd, try a.dupeZ(u8, value.file_name.?), size);
    defer if (fd >= 0) {
        _ = u.c.close(fd);
    };
    const bytes = if (fd >= 0) Assets.readBytes(a, fd, size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidImage => null,
    } else null;
    if (bytes == null or !try Assets.verifyBytes(a, bytes.?, value.etag.?)) {
        {
            self.core.lock();
            defer self.core.unlock();
            const j = self.core.journal;
            try j.begin();
            errdefer j.rollback();
            // Recheck the immutable version after file I/O, including epoch reset.
            if (variant == .avatar and !contact_directory.canPresent(self.core.contacts_status)) return error.ContactsUnavailable;
            _ = try Assets.lookup(a, j, id, version, variant);
            try Assets.evicted(a, j, value);
            try j.commit();
        }
        var ref = value.ref;
        ref.availability = .pending;
        ref.reason = "cache_evicted";
        return assetPending(a, req, ref);
    }
    {
        self.core.lock();
        defer self.core.unlock();
        if (variant == .avatar and !contact_directory.canPresent(self.core.contacts_status)) return error.ContactsUnavailable;
        _ = try Assets.lookup(a, self.core.journal, id, version, variant);
    }
    if (Tls.c.zr_tls_valid(peer) == 0) return error.CertificateExpired;
    const etag = try std.fmt.allocPrint(a, "\"{s}\"", .{value.etag.?});
    const extra = [_]std.http.Header{
        .{ .name = "content-type", .value = value.ref.mime_type orelse return error.InvalidAsset },
        .{ .name = "etag", .value = etag },
        .{ .name = "cache-control", .value = "private, max-age=31536000, immutable" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    const unchanged = if (if_none_match) |tag| u.eq(tag, etag) or u.eq(tag, "*") else false;
    try req.respond(if (unchanged) "" else bytes.?, .{
        .status = if (unchanged) .not_modified else .ok,
        .extra_headers = &extra,
    });
}
fn assetPending(a: u.Allocator, req: *Request, ref: t.AssetRef) !void {
    const can_retry = Assets.retryable(ref);
    const body = try u.json(a, .{
        .error_info = t.SafeError{ .code = ref.reason orelse "asset_unavailable", .message = "The image representation is not currently available." },
        .asset = ref,
        .retryable = can_retry,
        .retry_after = if (can_retry) @as(?u32, 2) else null,
    });
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "retry-after", .value = "2" },
    };
    try req.respond(body, .{
        .status = .conflict,
        .extra_headers = headers[0..if (can_retry) @as(usize, 3) else 2],
    });
}
fn events(self: *Server, req: *Request, start: []const u8, identities: bool) !void {
    if (self.core.streams.fetchAdd(1, .acq_rel) >= 8) {
        _ = self.core.streams.fetchSub(1, .acq_rel);
        return error.TooManyStreams;
    }
    errdefer {
        req.events = null;
        _ = self.core.streams.fetchSub(1, .acq_rel);
    }
    const seq = seq: {
        self.core.lock();
        defer self.core.unlock();
        break :seq try self.core.journal.checkCursor(req.arena.allocator(), start);
    };
    req.events = .{
        .start = start,
        .sequence = seq,
        .identities = identities,
        .heartbeat = u.now(),
    };
    try req.respond(": connected\n\n", .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/event-stream" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "x-accel-buffering", .value = "no" },
        .{ .name = "zimbr-event-extensions", .value = if (identities) "identity-v1" else "" },
    } });
}

/// Produces one journal batch after the previous batch has drained through flow control.
pub fn pollEvents(self: *Server, req: *Request) PollEventsError!void {
    const events_stream = &req.events.?;
    const now = u.now();
    const observed = self.core.changed.observe();
    if (events_stream.observed == observed and now < events_stream.check_at) return;
    _ = req.batch.reset(.free_all);
    req.response = "";
    req.offset = 0;
    const a = req.batch.allocator();
    const frames = frames: {
        self.core.lock();
        defer self.core.unlock();
        const j = self.core.journal;
        const epoch = try j.epoch(a);
        if (!std.mem.startsWith(u8, events_stream.start, epoch)) return error.InvalidRequest;
        const current = try t.cursor(a, epoch, events_stream.sequence);
        _ = try j.checkCursor(a, current);
        break :frames try j.eventsWithIdentities(a, events_stream.sequence, events_stream.identities);
    };
    var bytes: std.Io.Writer.Allocating = .init(a);
    for (frames) |frame| {
        try bytes.writer.writeAll(frame.frame);
        events_stream.sequence = frame.sequence;
    }
    if (now - events_stream.heartbeat >= 15000) {
        try bytes.writer.writeAll(": heartbeat\n\n");
        events_stream.heartbeat = now;
    }
    events_stream.observed = if (frames.len == 0) observed else null;
    events_stream.check_at = now + 1000;
    req.response = bytes.written();
    if (req.response.len > 0) {
        req.deadline = u.c.zr_monotonic_ms() + 10000;
        try req.connection.engine.resumeBody(req.id);
    }
}
fn identityExtension(value: ?[]const u8) !bool {
    const raw = value orelse return false;
    if (raw.len == 0) return false;
    if (u.eq(raw, "identity-v1")) return true;
    return error.UnsupportedExtension;
}
fn respond(req: *Request, body: []const u8, status: std.http.Status) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "retry-after", .value = "2" },
    };
    try req.respond(body, .{
        .status = status,
        .extra_headers = headers[0..if (status == .service_unavailable) @as(usize, 3) else 2],
    });
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
const ErrorMapping = struct {
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
};
fn mapError(err: anytype) ErrorMapping {
    return switch (err) {
        error.RelayCacheResetRequired => .{
            .status = .conflict,
            .code = "relay_cache_reset_required",
            .message = "Reset client and relay data from the client's Settings to rebuild incompatible IDs.",
        },
        error.InvalidRequest => .{
            .status = .bad_request,
            .code = "invalid_request",
            .message = "The request is invalid.",
        },
        error.UnsupportedExtension => .{
            .status = .bad_request,
            .code = "unsupported_extension",
            .message = "The requested event extension is not supported.",
        },
        error.EnrichmentRestartRequired => .{
            .status = .conflict,
            .code = "enrichment_restart_required",
            .message = "Message enrichment changed; refresh the message and restart paging.",
        },
        error.AssetRetired => .{
            .status = .gone,
            .code = "asset_retired",
            .message = "Refresh owner metadata for the current asset version.",
        },
        error.ContactsUnavailable => .{
            .status = .conflict,
            .code = "contacts_unavailable",
            .message = "Contact presentation is currently unavailable.",
        },
        error.AssetQueueFull, error.AssetResponseLimit => .{
            .status = .service_unavailable,
            .code = "asset_busy",
            .message = "The media service is busy; retry shortly.",
        },
        error.AssetServiceUnavailable => .{
            .status = .service_unavailable,
            .code = "asset_service_unavailable",
            .message = "The image service is unavailable.",
        },
        error.UnsupportedTarget => .{
            .status = .bad_request,
            .code = "unsupported_target",
            .message = "Only explicit iMessage targets are supported.",
        },
        error.UnsupportedAttachments => .{
            .status = .bad_request,
            .code = "unsupported_attachments",
            .message = "This relay cannot send attachments.",
        },
        error.RequestConflict => .{
            .status = .conflict,
            .code = "request_conflict",
            .message = "This request ID already has a different payload.",
        },
        error.ResyncRequired => .{
            .status = .conflict,
            .code = "resync_required",
            .message = "Obtain a new snapshot and cursor before continuing.",
        },
        error.CursorExpired => .{
            .status = .gone,
            .code = "resync_required",
            .message = "This event cursor has expired. Synchronize again.",
        },
        error.BodyTooLarge, error.TextTooLarge, error.AttachmentTooLarge, error.TooManyAttachments => .{
            .status = .payload_too_large,
            .code = "invalid_request",
            .message = "The request exceeds the relay size limit.",
        },
        error.NotFound => .{
            .status = .not_found,
            .code = "not_found",
            .message = "The requested resource does not exist.",
        },
        error.TooManyStreams => .{
            .status = .service_unavailable,
            .code = "stream_limit",
            .message = "The event stream limit has been reached.",
        },
        else => .{
            .status = .service_unavailable,
            .code = "adapter_unavailable",
            .message = "The relay is temporarily unavailable. Check relay doctor.",
        },
    };
}

test {
    _ = @import("http2.zig");
}
