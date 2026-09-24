const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol/types.zig");
const Core = @import("Core.zig");
const Transport = @import("Transport.zig");
const Tls = @import("Tls.zig");
const Assets = @import("Assets.zig");
const Self = @This();
fn readiness(supported: bool, ready: bool, reason: []const u8) struct { ready: bool, reason: []const u8 } {
    if (!supported) return .{ .ready = false, .reason = "native_acceptance_pending" };
    return .{ .ready = ready, .reason = if (ready) "" else reason };
}
core: *Core,
tls: Tls,
handshakes: std.atomic.Value(usize) = .init(0),
asset_responses: std.atomic.Value(usize) = .init(0),
pub fn run(self: *Self) !void {
    const address = try std.Io.net.IpAddress.parse(self.tls.config.listen_address, self.tls.config.port);
    var listener = try address.listen(self.core.io, .{ .reuse_address = true });
    defer listener.deinit(self.core.io);
    std.debug.print("relay: HTTPS mTLS listening on {s}:{d}\n", .{ self.tls.config.listen_address, self.tls.config.port });
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
fn connection(self: *Self, stream: std.Io.net.Stream) void {
    defer _ = self.core.connections.fetchSub(1, .acq_rel);
    defer stream.close(self.core.io);
    const connection_tls = Tls.c.zr_tls_accept(self.tls.context, stream.socket.handle);
    _ = self.handshakes.fetchSub(1, .acq_rel);
    const peer = connection_tls orelse return;
    defer Tls.c.zr_tls_free(peer);
    var read_buf: [16384]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = Transport.Reader.init(peer, &read_buf);
    var writer = Transport.Writer.init(peer, &write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    // Reuse authenticated HTTP connections across bounded requests. Each
    // request still gets fresh authorization, a deadline, and its own arena.
    for (0..64) |request_index| {
        reader.deadline = u.c.zr_monotonic_ms() + 10000;
        if (Tls.c.zr_tls_valid(peer) == 0) return;
        var req = server.receiveHead() catch return;
        if (Tls.c.zr_tls_valid(peer) == 0) return;
        if (request_index == 63) req.head.keep_alive = false;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.handle(arena.allocator(), &req, peer, &writer) catch |err| {
            if (err == error.WriteFailed or err == error.ReadFailed or err == error.EndOfStream or err == error.CertificateExpired) return;
            const mapping = mapError(err);
            const body = u.json(arena.allocator(), .{ .error_info = t.SafeError{ .code = mapping.code, .message = mapping.message } }) catch return;
            req.head.keep_alive = false;
            respond(&req, body, mapping.status) catch {};
            return;
        };
        if (!req.head.keep_alive or server.reader.state != .ready) return;
    }
}
fn handle(self: *Self, a: u.Allocator, req: *std.http.Server.Request, peer: *Tls.c.ZrTls, writer: *Transport.Writer) !void {
    var last: ?[]const u8 = null;
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "last-event-id")) {
            if (last != null) return error.InvalidRequest;
            last = try a.dupe(u8, h.value);
        }
    }
    if (req.head.version != .@"HTTP/1.1") return error.InvalidRequest;
    if (req.head.transfer_compression != .identity) return error.InvalidRequest;
    if ((req.head.content_length orelse 0) > t.max_body) return error.BodyTooLarge;
    if (req.head.method == .GET and ((req.head.content_length orelse 0) != 0 or req.head.transfer_encoding == .chunked)) return error.InvalidRequest;
    const target = try a.dupe(u8, req.head.target);
    const split = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..split];
    const query = if (split < target.len) target[split + 1 ..] else "";
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/v1/assets/")) {
        // Four media responses leave capacity for SSE and ordinary commands.
        if (self.asset_responses.fetchAdd(1, .acq_rel) >= 4) {
            _ = self.asset_responses.fetchSub(1, .acq_rel);
            return error.AssetResponseLimit;
        }
        defer _ = self.asset_responses.fetchSub(1, .acq_rel);
        req.head.keep_alive = false;
        writer.deadline = u.c.zr_monotonic_ms() + 15000;
        try self.asset(a, req, path[11..], peer);
        return;
    }
    if (req.head.method == .GET and u.eq(path, "/v1/events")) {
        const after = try param(a, query, "after");
        if (after != null and last != null and !u.eq(after.?, last.?)) return error.InvalidRequest;
        const cursor = after orelse last orelse return error.InvalidRequest;
        const identities = try identityExtension(try param(a, query, "extensions"));
        try self.events(req, cursor, peer, identities);
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
    if (Tls.c.zr_tls_valid(peer) == 0) return error.CertificateExpired;
    var response: []const u8 = undefined;
    var status: std.http.Status = .ok;
    {
        self.core.lock();
        defer self.core.unlock();
        const j = self.core.journal;
        if (input) |v| {
            const accepted = try j.accept(a, v, self.core.read_ready and self.core.automation_ready and u.now() - self.core.last_scan_ms < 5000);
            if (accepted.fresh) self.core.send_ready.notify(self.core.io);
            response = accepted.record;
            status = if (accepted.fresh) .accepted else .ok;
        } else if (u.eq(path, "/v1/status")) {
            const contacts = @import("adapter/Contacts.zig").currentStatus(self.core.contacts_status);
            response = try u.json(a, .{
                .api_version = t.api_version,
                .event_extensions = [_][]const u8{"identity-v1"},
                .server_epoch = try j.epoch(a),
                .adapter_ready = self.core.read_ready,
                .source_features = self.core.source_features,
                .capabilities = .{
                    .read_history = self.core.read_ready,
                    .live_messages = self.core.read_ready,
                    .send_direct = self.core.read_ready and self.core.automation_ready,
                    .reply_existing = self.core.read_ready and self.core.automation_ready,
                    .attachments = true,
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
                    .image_assets_v1 = readiness(true, self.core.assets_service != null, self.core.assets_reason),
                    .image_attachments_v1 = readiness(true, self.core.assets_service != null and self.core.read_ready and self.core.source_features.attachment_filename, if (self.core.assets_service == null) self.core.assets_reason else if (!self.core.read_ready) self.core.degraded else "source_columns_unavailable"),
                    .stored_link_previews_v1 = readiness(true, self.core.read_ready and self.core.source_features.link_payload, if (!self.core.read_ready) self.core.degraded else "source_columns_unavailable"),
                    .reactions_v1 = readiness(true, self.core.read_ready and self.core.source_features.reaction_target, "source_columns_unavailable"),
                    .contact_avatars_v1 = readiness(true, contacts.ready and self.core.assets_service != null, if (self.core.assets_service == null) self.core.assets_reason else contacts.reason),
                },
                .degraded_reasons = if (self.core.degraded.len == 0) @as([]const []const u8, &.{}) else &.{self.core.degraded},
            });
        } else if (u.eq(path, "/v1/sync")) {
            const epoch = try j.epoch(a);
            response = try u.json(a, .{ .server_epoch = epoch, .cursor = try t.cursor(a, epoch, try j.sequence()) });
        } else if (u.eq(path, "/v1/conversations")) {
            const before = try param(a, query, "before");
            const limit = try pageLimit(a, query);
            const p = try j.page(a, null, before, limit);
            const previews = if (u.eq((try param(a, query, "previews")) orelse "", "1")) try j.previews(a, before, limit) else null;
            response = try u.json(a, .{ .conversations = p.records, .next = p.next, .previews = previews });
        } else if (u.eq(path, "/v1/identities")) {
            const p = try j.identityPage(a, try param(a, query, "before"), try pageLimit(a, query));
            response = try u.json(a, .{ .identities = p.records, .next = p.next });
        } else if (std.mem.startsWith(u8, path, "/v1/messages/") and std.mem.endsWith(u8, path, "/enrichment")) {
            const id = path[13 .. path.len - 11];
            if (!t.uuid(id)) return error.InvalidRequest;
            const name = (try param(a, query, "section")) orelse return error.InvalidRequest;
            const section = std.meta.stringToEnum(@import("Enrichment.zig").Section, name) orelse return error.InvalidRequest;
            const revision = (try param(a, query, "revision")) orelse return error.InvalidRequest;
            response = try u.json(a, try @import("Enrichment.zig").page(j, a, id, section, revision, try param(a, query, "after"), try pageLimit(a, query)));
        } else if (std.mem.startsWith(u8, path, "/v1/conversations/") and std.mem.endsWith(u8, path, "/messages")) {
            const id = path[18 .. path.len - 9];
            if (!t.uuid(id)) return error.InvalidRequest;
            if (try j.getRecord(a, .conversation, id) == null) return error.NotFound;
            const text_only = u.eq((try param(a, query, "content")) orelse "", "text");
            for (try j.threadMembers(a, id)) |member| {
                try j.execute("INSERT OR IGNORE INTO reconcile_chats(conversation_id) VALUES(?)", &.{.{ .text = member }});
                if (!text_only) {
                    if (self.core.assets_service != null) try Assets.prioritizeConversation(j, member);
                    try @import("Reactions.zig").prioritize(j, member);
                }
            }
            const p = try j.pageContent(a, id, try param(a, query, "before"), try pageLimit(a, query), text_only);
            response = try u.json(a, .{ .messages = p.records, .next = p.next });
        } else if (std.mem.startsWith(u8, path, "/v1/messages/")) {
            const id = path[13..];
            if (!t.uuid(id)) return error.InvalidRequest;
            var message = try j.db.prepare("SELECT record,source FROM messages WHERE id=?");
            defer message.close();
            try message.bind(&.{.{ .text = id }});
            if (!try message.step()) return error.NotFound;
            response = try message.text(a, 0);
            // Only visible messages request fresh media and reaction metadata.
            if (self.core.assets_service != null) try j.execute("UPDATE asset_sources SET check_ms=0 WHERE id IN(SELECT asset_id FROM asset_owners WHERE owner_id=? AND kind IN('message','preview'))", &.{.{ .text = message.bytes(1) }});
            try j.execute("UPDATE reaction_sources SET check_ms=0 WHERE target_guid=? AND retired=0", &.{.{ .text = message.bytes(1) }});
        } else if (std.mem.startsWith(u8, path, "/v1/send-requests/")) {
            const id = path[18..];
            if (!t.uuid(id)) return error.InvalidRequest;
            response = (try j.getRecord(a, .request, id)) orelse return error.NotFound;
        } else return error.NotFound;
    }
    try respond(req, response, status);
}
fn asset(self: *Self, a: u.Allocator, req: *std.http.Server.Request, path: []const u8, peer: *Tls.c.ZrTls) !void {
    const service = self.core.assets_service orelse return error.AssetServiceUnavailable;
    var components = std.mem.splitScalar(u8, path, '/');
    const id = components.next() orelse return error.InvalidRequest;
    const version = components.next() orelse return error.InvalidRequest;
    const variant_name = components.next() orelse return error.InvalidRequest;
    if (!t.uuid(id) or !t.uuid(version) or components.next() != null) return error.InvalidRequest;
    const variant = std.meta.stringToEnum(Assets.Variant, variant_name) orelse return error.InvalidRequest;
    var if_none_match: ?[]const u8 = null;
    var headers = req.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
        if (if_none_match != null) return error.InvalidRequest;
        if_none_match = header.value;
    };
    const value = blk: {
        self.core.lock();
        defer self.core.unlock();
        const j = self.core.journal;
        if (variant == .avatar and !@import("adapter/Contacts.zig").canPresent(self.core.contacts_status)) return error.ContactsUnavailable;
        try j.begin();
        errdefer j.rollback();
        const found = try Assets.lookup(j, a, id, version, variant);
        try j.commit();
        break :blk found;
    };
    if (value.ref.availability != .ready or value.file_name == null or value.etag == null) return assetPending(a, req, value.ref);
    const size = std.fmt.parseInt(usize, value.ref.bytes orelse "", 10) catch return error.InvalidAsset;
    if (size > Assets.max_derivative) return error.InvalidAsset;
    const fd = Assets.c.zr_media_cached(service.cache_fd, try a.dupeZ(u8, value.file_name.?), size);
    defer if (fd >= 0) {
        _ = u.c.close(fd);
    };
    const bytes = if (fd >= 0) Assets.readBytes(a, fd, size) catch null else null;
    if (bytes == null or !try Assets.verifyBytes(a, bytes.?, value.etag.?)) {
        {
            self.core.lock();
            defer self.core.unlock();
            const j = self.core.journal;
            try j.begin();
            errdefer j.rollback();
            // Recheck the immutable version after file I/O, including epoch reset.
            if (variant == .avatar and !@import("adapter/Contacts.zig").canPresent(self.core.contacts_status)) return error.ContactsUnavailable;
            _ = try Assets.lookup(j, a, id, version, variant);
            try Assets.evicted(j, a, value);
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
        if (variant == .avatar and !@import("adapter/Contacts.zig").canPresent(self.core.contacts_status)) return error.ContactsUnavailable;
        _ = try Assets.lookup(self.core.journal, a, id, version, variant);
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
    try req.respond(if (unchanged) "" else bytes.?, .{ .status = if (unchanged) .not_modified else .ok, .keep_alive = false, .extra_headers = &extra });
}
fn assetPending(a: u.Allocator, req: *std.http.Server.Request, ref: t.AssetRef) !void {
    const can_retry = Assets.retryable(ref);
    const body = try u.json(a, .{ .error_info = t.SafeError{ .code = ref.reason orelse "asset_unavailable", .message = "The image representation is not currently available." }, .asset = ref, .retryable = can_retry, .retry_after = if (can_retry) @as(?u32, 2) else null });
    const headers = [_]std.http.Header{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" }, .{ .name = "retry-after", .value = "2" } };
    try req.respond(body, .{ .status = .conflict, .keep_alive = false, .extra_headers = headers[0..if (can_retry) @as(usize, 3) else 2] });
}
fn events(self: *Self, req: *std.http.Server.Request, start: []const u8, peer: *Tls.c.ZrTls, identities: bool) !void {
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
    var stream = try req.respondStreaming(&buffer, .{ .respond_options = .{ .keep_alive = false, .transfer_encoding = .none, .extra_headers = &.{ .{ .name = "content-type", .value = "text/event-stream" }, .{ .name = "cache-control", .value = "no-cache" }, .{ .name = "x-accel-buffering", .value = "no" }, .{ .name = "zimbr-event-extensions", .value = if (identities) "identity-v1" else "" } } } });
    // Once headers are sent, close on errors; do not write a second HTTP response.
    stream.writer.writeAll(": connected\n\n") catch return;
    stream.writer.flush() catch return;
    stream.flush() catch return;
    var heartbeat = u.now();
    while (!self.core.stop.load(.acquire)) {
        const observed = self.core.changed.observe();
        if (Tls.c.zr_tls_closed(peer) != 0 or Tls.c.zr_tls_valid(peer) == 0) return;
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
            break :blk j.eventsWithIdentities(a, seq, identities) catch return;
        };
        for (frames) |frame| {
            stream.writer.writeAll(frame.frame) catch return;
            seq = frame.sequence;
        }
        if (frames.len > 0) {
            stream.writer.flush() catch return;
            stream.flush() catch return;
        }
        if (u.now() - heartbeat >= 15000) {
            stream.writer.writeAll(": heartbeat\n\n") catch return;
            stream.writer.flush() catch return;
            stream.flush() catch return;
            heartbeat = u.now();
        }
        if (frames.len == 0) self.core.changed.wait(self.core.io, observed, 1000);
    }
}
fn identityExtension(value: ?[]const u8) !bool {
    const raw = value orelse return false;
    if (raw.len == 0) return false;
    if (u.eq(raw, "identity-v1")) return true;
    return error.UnsupportedExtension;
}
fn respond(req: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    const headers = [_]std.http.Header{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" }, .{ .name = "retry-after", .value = "2" } };
    try req.respond(body, .{ .status = status, .keep_alive = req.head.keep_alive, .extra_headers = headers[0..if (status == .service_unavailable) @as(usize, 3) else 2] });
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
        error.InvalidRequest => .{ .status = .bad_request, .code = "invalid_request", .message = "The request is invalid." },
        error.UnsupportedExtension => .{ .status = .bad_request, .code = "unsupported_extension", .message = "The requested event extension is not supported." },
        error.EnrichmentRestartRequired => .{ .status = .conflict, .code = "enrichment_restart_required", .message = "Message enrichment changed; refresh the message and restart paging." },
        error.AssetRetired => .{ .status = .gone, .code = "asset_retired", .message = "Refresh owner metadata for the current asset version." },
        error.ContactsUnavailable => .{ .status = .conflict, .code = "contacts_unavailable", .message = "Contact presentation is currently unavailable." },
        error.AssetQueueFull, error.AssetResponseLimit => .{ .status = .service_unavailable, .code = "asset_busy", .message = "The media service is busy; retry shortly." },
        error.AssetServiceUnavailable => .{ .status = .service_unavailable, .code = "asset_service_unavailable", .message = "The image service is unavailable." },
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
