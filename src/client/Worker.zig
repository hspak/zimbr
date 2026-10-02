const std = @import("std");
const log = std.log.scoped(.client_worker);
const a = std.heap.page_allocator;

const json_bounds = @import("../protocol.zig").json;
const url_format = @import("../protocol.zig").url;
const content = @import("content.zig");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const c = @import("c.zig").api;
const Config = @import("Config.zig");
const Store = @import("Store.zig");
const Sse = @import("Sse.zig");
const Notification = @import("Notification.zig");
const SharedSnapshot = @import("SharedSnapshot.zig");
const outgoing = @import("outgoing.zig");
const Worker = @This();

io: std.Io,
config: Config,
mutex: std.Io.Mutex = .init,
commands: std.ArrayList(Command) = .empty,
notifications: std.ArrayList(*Notification) = .empty,
batch_notifications: std.ArrayList(*Notification) = .empty,
view: ?*View = null,
on_ready: ?*const fn () callconv(.c) void = null,
stop: std.atomic.Value(bool) = .init(false),
thread: ?std.Thread = null,
wake_pipe: [2]c_int = .{ -1, -1 },
store: Store = undefined,
net: ?*c.ZcNet = null,
sse: Sse = .{},
selected: []const u8 = "",
redirect_from: []const u8 = "",
viewed: bool = false,
status: []const u8 = "Opening cached messages…",
online: bool = false,
send_direct: bool = false,
reply_existing: bool = false,
send_attachments: bool = false,
preparation: ?outgoing.Preparation = null,
upload: ?outgoing.Upload = null,
upload_retry_at: i64 = 0,
upload_published_at: i64 = 0,
attachment_error: []const u8 = "",
command_serial: u64 = 0,
dirty: bool = true,
content_dirty: bool = true,
shared: ?*SharedSnapshot = null,
content_generation: u64 = 0,
credential_generation: u64 = 0,
generation: u64 = 0,
ack: u64 = 0,
reset: Reset = .idle,
reset_epoch: []const u8 = "",
job: enum {
    idle,
    status,
    sync,
    chats,
    identities,
    history,
    preview,
    send,
    recover,
    enrichment,
    hydrate,
    reset_status,
    reset,
} = .idle,
// The complete URL must fit this capacity, so any accepted path fits too.
job_path: [c.ZC_REQUEST_URL_CAPACITY]u8 = undefined,
job_path_len: usize = 0,
job_key: []const u8 = "",
enrichment_request: ?Command = null,
enrichment_after: []const u8 = "",
hydration_request: ?Command = null,
hydration_at: i64 = 0,
text_first_history: bool = false,
identities_before: ?[]const u8 = null,
// Keep brief live updates visible across publication coalescing and UI frames.
contacts_sync_until: i64 = 0,
preview_at: i64 = 0,
recover_row: i64 = 0,
need_history: bool = false,
older: bool = false,
job_older: bool = false,
need_sync: bool = false,
stream_active: bool = false,
want_identities: bool = false,
stream_verified: bool = false,
extension_rejected: bool = false,
retry_at: i64 = 0,
// Start reconnect attempts one second apart; failures double this up to 30 seconds.
backoff: i64 = 1000,
status_at: i64 = 0,
recovery_at: i64 = 0,
expiry_at: i64 = 0,
auth_blocked: bool = false,
last_published: i64 = 0,
last_status_ms: i64 = 0,
last_event_ms: i64 = 0,
last_response_ms: i64 = 0,
last_http_status: i64 = 0,
transport_error: c.ZcError = std.mem.zeroes(c.ZcError),
identity: c.ZcIdentity = std.mem.zeroes(c.ZcIdentity),

const EventBatch = struct {
    worker: *Worker,
    events: usize = 0,
    contacts: usize = 0,
};
pub const Reset = enum { idle, pending, failed, complete };
pub const Command = struct {
    kind: enum {
        select,
        draft,
        attach,
        remove_attachment,
        cancel_preparation,
        cancel_upload,
        send,
        older,
        reconnect,
        check,
        viewed,
        hide,
        unhide,
        enrichment,
        hydrate,
        reset,
    },
    key: []const u8 = "",
    text: []const u8 = "",
    recipient: []const u8 = "",
    // Optional GUI ordering token; publication acknowledges processed commands.
    serial: u64 = 0,
};
pub const Readiness = struct {
    ready: bool = false,
    reason: []const u8 = "",
    permission: ?[]const u8 = null,
    stale: bool = false,
    last_refresh_ms: ?i64 = null,
};
pub const RelayStatus = struct {
    sync_activity: t.SyncActivity = .{},
    event_extensions: []const []const u8 = &.{},
    enrichment_readiness: struct {
        identity_directory_v1: Readiness = .{},
        image_assets_v1: Readiness = .{},
        image_attachments_v1: Readiness = .{},
        stored_link_previews_v1: Readiness = .{},
        reactions_v1: Readiness = .{},
        contact_avatars_v1: Readiness = .{},
    } = .{},
    api_version: []const u8,
    server_epoch: []const u8,
    adapter_ready: bool,
    capabilities: struct {
        state_reset_v1: bool = false,
        send_direct: bool,
        reply_existing: bool,
        send_attachments_v1: bool = false,
        attachment_uploads_v1: bool = false,
        read_history: bool = false,
        live_messages: bool = false,
        attachments: bool = false,
        identity_directory_v1: bool = false,
        image_assets_v1: bool = false,
        image_attachments_v1: bool = false,
        stored_link_previews_v1: bool = false,
        reactions_v1: bool = false,
        contact_avatars_v1: bool = false,
        text_first_history_v1: bool = false,
        group_creation: bool = false,
    },
    degraded_reasons: []const []const u8,
};
pub const Diagnostics = struct {
    transport: SharedSnapshot.Transport = .{},
    server: ?RelayStatus = null,
    cursor: []const u8 = "",
    job: []const u8 = "idle",
    bootstrapped: bool = false,
    stream_active: bool = false,
    auth_blocked: bool = false,
    retry_at: i64 = 0,
    last_status_ms: i64 = 0,
    last_event_ms: i64 = 0,
    last_response_ms: i64 = 0,
    last_http_status: i64 = 0,
    cached_messages: i64 = 0,
    saved_drafts: i64 = 0,
    pending_sends: i64 = 0,
};
pub const View = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: Store.Snapshot,
    status: []const u8,
    online: bool,
    sync_activity: t.SyncActivity = .{},
    send_direct: bool,
    reply_existing: bool,
    send_attachments: bool = false,
    preparing_attachments: bool = false,
    preparing_draft: bool = false,
    command_serial: u64 = 0,
    attachment_error: []const u8 = "",
    upload: outgoing.Upload.Progress = .{},
    generation: u64,
    ack: u64,
    loading_history: bool = false,
    cache_unavailable: bool = false,
    redirect_from: []const u8 = "",
    diagnostics: Diagnostics = .{},
    shared: ?*SharedSnapshot = null,
    content_generation: ?u64 = null,
    credential_generation: u64 = 0,
    reset: Reset = .idle,
    pub fn destroy(v: *View) void {
        if (v.shared) |shared| shared.release();
        v.arena.deinit();
        a.destroy(v);
    }
};

pub const StartError = std.Thread.SpawnError || error{
    WorkerWakeUnavailable,
};
pub const PushError = u.Allocator.Error || error{Busy};

pub fn start(s: *Worker) StartError!void {
    // The caller holds Config.lockCache() for the lifetime of the worker.
    if (u.c.pipe(&s.wake_pipe) != 0) return error.WorkerWakeUnavailable;
    errdefer {
        for (s.wake_pipe) |fd| _ = u.c.close(fd);
        s.wake_pipe = .{ -1, -1 };
    }
    for (s.wake_pipe) |fd| {
        if (u.c.fcntl(fd, u.c.F_SETFL, @as(c_int, u.c.O_NONBLOCK)) < 0 or u.c.fcntl(
            fd,
            u.c.F_SETFD,
            @as(c_int, u.c.FD_CLOEXEC),
        ) < 0) return error.WorkerWakeUnavailable;
    }
    s.thread = try std.Thread.spawn(.{}, run, .{s});
}
fn wake(s: *Worker) void {
    if (s.wake_pipe[1] >= 0) _ = u.c.write(s.wake_pipe[1], "x", 1);
}
pub fn shutdown(s: *Worker) void {
    s.stop.store(true, .release);
    s.wake();
    if (s.thread) |th| th.join();
    a.free(s.reset_epoch);
    for (s.wake_pipe) |fd| if (fd >= 0) {
        _ = u.c.close(fd);
    };
    s.wake_pipe = .{ -1, -1 };
    if (s.view) |v| v.destroy();
    if (s.shared) |shared| shared.release();
    for (s.commands.items) |cmd| freeCommand(cmd);
    s.commands.deinit(a);
    for (s.notifications.items) |n| n.destroy();
    s.notifications.deinit(a);
    for (s.batch_notifications.items) |n| n.destroy();
    s.batch_notifications.deinit(a);
}
pub fn takeNotification(s: *Worker) ?*Notification {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return if (s.notifications.items.len > 0) s.notifications.orderedRemove(0) else null;
}
pub fn push(s: *Worker, cmd: Command) PushError!void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    // Bound pending UI commands so a stalled worker cannot accumulate unlimited requests.
    if (s.commands.items.len >= 64) return error.Busy;
    const key = try a.dupe(u8, cmd.key);
    errdefer a.free(key);
    const text = try a.dupe(u8, cmd.text);
    errdefer a.free(text);
    const recipient = try a.dupe(u8, cmd.recipient);
    errdefer a.free(recipient);
    try s.commands.append(a, .{
        .kind = cmd.kind,
        .key = key,
        .text = text,
        .recipient = recipient,
        .serial = cmd.serial,
    });
    s.wake();
}
fn freeCommand(cmd: Command) void {
    a.free(cmd.key);
    a.free(cmd.text);
    a.free(cmd.recipient);
}
pub fn take(s: *Worker) ?*View {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const v = s.view;
    s.view = null;
    return v;
}
fn run(s: *Worker) void {
    s.work() catch |err| {
        log.err("client worker: {s}", .{@errorName(err)});
        s.status = "Client cache unavailable. Check the data directory and restart.";
        if (s.reset == .pending) s.reset = .failed;
        s.online = false;
        const v = a.create(View) catch return;
        v.* = .{
            .arena = std.heap.ArenaAllocator.init(a),
            .snapshot = .{
                .chats = &.{},
                .messages = &.{},
                .pending = &.{},
                .selected = "",
                .draft = "",
                .epoch = "",
                .more = false,
            },
            .status = s.status,
            .reset = s.reset,
            .cache_unavailable = true,
            .online = false,
            .send_direct = false,
            .reply_existing = false,
            .generation = s.generation + 1,
            .ack = s.ack,
        };
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.view) |old| old.destroy();
        s.view = v;
    };
}
fn work(s: *Worker) !void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{s.config.data}, 0);
    defer a.free(path);
    s.store = try Store.open(path);
    defer s.store.close();
    s.preparation = .{ .io = s.io, .data = s.config.data, .parent_wake = s.wake_pipe[1] };
    s.preparation.?.start() catch |err| {
        log.warn("Attachment storage unavailable: {s}", .{@errorName(err)});
        s.preparation = null;
        s.attachment_error = "Private attachment storage is unavailable.";
    };
    defer if (s.preparation) |*preparation| preparation.shutdown();
    s.selected = try s.store.get(a, "selected");
    {
        const stamp = try s.store.get(a, "server_checked_at");
        defer a.free(stamp);
        s.last_status_ms = std.fmt.parseInt(i64, stamp, 10) catch 0;
    }
    defer if (s.selected.len > 0) a.free(s.selected);
    defer {
        s.stopUpload();
        if (s.net) |n| c.zc_net_free(n);
        s.sse.reset();
        a.free(s.job_key);
        if (s.enrichment_request) |cmd| freeCommand(cmd);
        a.free(s.enrichment_after);
        if (s.hydration_request) |cmd| freeCommand(cmd);
        if (s.identities_before) |before| a.free(before);
        a.free(s.redirect_from);
    }
    try s.expireUnknown();
    try s.publish();
    while (true) {
        s.expireContactSync(u.now());
        try s.expireUnknown();
        try s.preparedFiles();
        try s.drain();
        if (s.reset == .idle) try s.resolveDirect();
        if (s.stop.load(.acquire)) break;
        if (s.net == null and !s.auth_blocked) try s.connect();
        if (s.net) |n| {
            if (c.zc_net_poll(n) == 0) return error.TransportFailure;
            if (c.zc_net_done(n, 0) != 0) try s.complete();
            if (c.zc_net_done(n, 1) != 0) {
                const status = c.zc_net_status(n, 1);
                c.zc_net_error(n, 1, &s.transport_error);
                s.last_http_status = status;
                s.last_response_ms = u.now();
                c.zc_net_ack(n, 1);
                s.stream_active = false;
                s.sse.reset();
                if (s.transport_error.curl_code == 0 and (status == 409 or status == 410)) {
                    log.info("Live sync cursor expired; restarting bootstrap (HTTP {d})", .{
                        status,
                    });
                    s.need_sync = true;
                    s.status = "Refreshing expired history…";
                    s.online = false;
                    s.retry_at = 0;
                } else {
                    s.disconnected(status);
                    if (s.extension_rejected) s.status = "Relay did not accept the requested event extension · check relay version, then Reconnect";
                }
            }
            if (!s.auth_blocked and s.stream_active and !s.online and c.zc_net_status(n, 1) == 200) {
                s.verifyStream() catch {
                    s.auth_blocked = true;
                    s.disconnected(0);
                    s.status = "Relay did not accept the requested event extension · check relay version, then Reconnect";
                    continue;
                };
                s.online = true;
                log.info("Live sync connected: contacts={}", .{s.want_identities});
                s.backoff = 1000;
                s.transport_error = std.mem.zeroes(c.ZcError);
                s.status = if (s.send_direct or s.reply_existing) "Connected" else "Connected · relay cannot send; run relay doctor on the Mac";
                s.dirty = true;
            }
            if (s.job == .idle and !s.auth_blocked and s.reset != .complete and u.now() >= s.retry_at) try s.schedule();
            try s.uploadFiles();
        }
        // Coalesce snapshots to roughly 60 Hz while the worker is busy.
        if (s.dirty and u.now() - s.last_published >= 16) try s.publish();
        // Network activity and commands wake immediately; timers only bound
        // publication coalescing and maintenance, rather than every request.
        const now = u.now();
        // Publish dirty snapshots after 16 ms; otherwise wake at least once a second.
        var delay: i64 = if (s.dirty) @max(0, 16 - (now - s.last_published)) else 1000;
        // Refresh active upload progress at most 100 ms apart.
        if (s.upload != null) delay = @min(delay, 100);
        delay = @min(delay, @max(0, s.expiry_at - now));
        if (s.contacts_sync_until != 0) delay = @min(delay, @max(0, s.contacts_sync_until - now));
        if (!s.auth_blocked and s.job == .idle and s.reset != .complete) {
            if (!s.online and !s.stream_active) delay = @min(delay, @max(0, s.retry_at - now));
            if (s.online) delay = @min(
                delay,
                @max(0, @min(s.status_at, @min(s.recovery_at, s.preview_at)) - now),
            );
        }
        if (c.zc_net_wait(s.net, s.wake_pipe[0], @intCast(delay)) == 0) return error.TransportFailure;
    }
}
fn connect(s: *Worker) !void {
    s.credential_generation +%= 1;
    s.net = c.zc_net_new(
        s.config.relay_url,
        s.config.ca_file,
        s.config.client_cert_file,
        s.config.client_key_file,
        receive,
        s,
        &s.transport_error,
        &s.identity,
    );
    if (s.net == null) {
        s.disconnected(0);
        if (s.reset == .pending) s.resetError("Could not connect to reset the relay. Local data was kept; retry after fixing the connection.");
        return;
    }
    s.status = "Connecting with mTLS…";
    s.retry_at = 0;
    s.dirty = true;
}
fn receive(ctx: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) c_int {
    const s: *Worker = @ptrCast(@alignCast(ctx.?));
    s.receiveBatch(bytes[0..len]) catch |err| {
        log.warn("Live sync batch rejected: {s}; reconnecting from saved cursor", .{
            @errorName(err),
        });
        s.status = "Invalid event stream · reconnecting from saved progress";
        s.dirty = true;
        return 0;
    };
    return 1;
}
fn verifyStream(s: *Worker) !void {
    if (s.stream_verified) return;
    const accepted = std.mem.span(c.zc_net_extensions(s.net.?));
    if (!u.eq(accepted, if (s.want_identities) "identity-v1" else "")) {
        s.auth_blocked = true;
        s.extension_rejected = true;
        return error.ExtensionNotAccepted;
    }
    try s.store.set("accepted_extensions", accepted);
    s.stream_verified = true;
}
fn receiveBatch(s: *Worker, bytes: []const u8) !void {
    // Tests feed the parser directly; transport deliveries require negotiation
    // before even the first event/cursor can enter the database.
    if (s.net != null) try s.verifyStream();
    defer {
        for (s.batch_notifications.items) |n| n.destroy();
        s.batch_notifications.clearRetainingCapacity();
    }
    // Commit complete frames from one network delivery together. A malformed
    // frame or failed commit rolls back records, unread state, and cursor;
    // reconnect replays from the last durable cursor.
    try s.store.db.exec("BEGIN IMMEDIATE");
    errdefer s.store.db.exec("ROLLBACK") catch {};
    var batch = EventBatch{ .worker = s };
    try s.sse.feed(event, &batch, bytes);
    try s.store.db.exec("COMMIT");
    // Keep brief contact activity visible for 1.2 seconds across snapshot publication.
    if (batch.contacts > 0) s.contacts_sync_until = u.now() + 1200;
    if (batch.events > 0) log.debug("Live sync committed: events={d} contacts={d} bytes={d}", .{
        batch.events,
        batch.contacts,
        bytes.len,
    });
    // Never publish side effects for a rolled-back frame or cursor update.
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (s.batch_notifications.items) |n| {
        // Keep the newest 64 notifications during delivery stalls.
        if (s.notifications.items.len == 64) s.notifications.orderedRemove(0).destroy();
        s.notifications.append(a, n) catch n.destroy();
    }
    s.batch_notifications.clearRetainingCapacity();
}
fn event(batch: *EventBatch, arena: u.Allocator, raw: []const u8, id: []const u8, kind: []const u8) !void {
    const s = batch.worker;
    if (try s.store.eventNotification(arena, raw, id, kind, if (s.viewed) s.selected else "")) |message| {
        const notification = Notification.create(s.store, message) catch null;
        if (notification) |n| {
            // Bound alerts accumulated during a sync batch to the same 64-entry delivery limit.
            if (s.batch_notifications.items.len == 64) s.batch_notifications.orderedRemove(0).destroy();
            s.batch_notifications.append(a, n) catch n.destroy();
        }
    }
    batch.events += 1;
    if (u.eq(kind, "identity.upsert")) batch.contacts += 1;
    if (u.eq(kind, "conversation.upsert") and s.selected.len > 0) {
        if (try s.store.nextPage(arena, try s.store.threadKey(arena, s.selected))) |next| if (next.len == 0) {
            s.need_history = true;
            s.older = false;
        };
    }
    s.last_event_ms = u.now();
    s.dirty = true;
    s.content_dirty = true;
}
fn expireContactSync(s: *Worker, now: i64) void {
    if (s.contacts_sync_until == 0 or now < s.contacts_sync_until) return;
    s.contacts_sync_until = 0;
    s.dirty = true;
}
fn request(
    s: *Worker,
    job: @FieldType(Worker, "job"),
    comptime format: []const u8,
    args: anytype,
    body: ?[]const u8,
) !void {
    std.debug.assert(s.job == .idle);
    const url = std.fmt.bufPrintZ(&s.job_path, format, args) catch
        return error.RequestPathTooLong;
    if (c.zc_net_start(s.net.?, 0, url, if (body) |b| b.ptr else null, if (body) |b| b.len else 0) == 0)
        return error.TransportFailure;
    s.job_path_len = url.len;
    s.job = job;
    s.dirty = true;
}
fn setJobKey(s: *Worker, key: []const u8) !void {
    const next_job_key = try a.dupe(u8, key);
    a.free(s.job_key);
    s.job_key = next_job_key;
}
fn disconnected(s: *Worker, status: c_long) void {
    s.online = false;
    s.dirty = true;
    const kind = s.transport_error.kind;
    s.auth_blocked = s.auth_blocked or kind == c.ZC_SERVER_TRUST or kind == c.ZC_CREDENTIALS or kind == c.ZC_CLIENT_REJECTED or kind == c.ZC_CONFIG or status == 401 or status == 403 or (status >= 300 and status < 400);
    s.status = switch (kind) {
        c.ZC_SERVER_TRUST => "Server identity verification failed · check the CA, hostname and expiry, then Reconnect",
        c.ZC_CREDENTIALS => "Local credentials need repair · see Details, then Reconnect",
        c.ZC_CLIENT_REJECTED => "Client certificate rejected · check enrollment and validity on the Mac, then Reconnect",
        c.ZC_CONFIG => "Connection configuration failed · see Details, then Reconnect",
        c.ZC_TLS => "TLS connection failed · check relay TLS settings and device enrollment; see Details. Retrying.",
        c.ZC_HTTP => if (s.auth_blocked) "Relay HTTP error · check endpoint and access on the Mac, then Reconnect" else "Relay HTTP error · see Details; retrying",
        else => "Offline · cached messages and drafts available. Check the network and relay.",
    };
    if (s.auth_blocked) s.retry_at = 0 else {
        // Add up to 250 ms of jitter to spread reconnects after a shared outage.
        s.retry_at = u.now() + s.backoff + @mod(u.now(), 251);
        // Exponential backoff tops out at 30 seconds so recovery remains timely.
        s.backoff = @min(s.backoff * 2, 30000);
    }
    if (s.auth_blocked) {
        log.err("Sync blocked: HTTP {d}, curl {d}; {s}", .{
            status,
            s.transport_error.curl_code,
            s.status,
        });
    } else log.warn("Sync disconnected: HTTP {d}, curl {d}, retry_in_ms={d}", .{
        status,
        s.transport_error.curl_code,
        @max(0, s.retry_at - u.now()),
    });
    if (s.stream_active) {
        c.zc_net_cancel_stream(s.net.?);
        s.stream_active = false;
        s.sse.reset();
    }
}
fn expireUnknown(s: *Worker) !void {
    const now = u.now();
    if (now < s.expiry_at) return;
    const removed = try s.store.expireUnknown(now);
    // Expire unresolved outbox entries once per second instead of querying on every iteration.
    s.expiry_at = now + 1000;
    if (removed) {
        s.content_dirty = true;
        s.dirty = true;
    }
}
fn unresolved(s: *Worker) !bool {
    return try s.store.db.scalar("SELECT count(*) FROM outbox WHERE epoch=(SELECT value FROM meta WHERE key='epoch') AND record IS NULL AND state IN ('sending','unknown')") > 0;
}
fn preparedFiles(s: *Worker) !void {
    const preparation = if (s.preparation) |*value| value else return;
    while (preparation.take()) |task| {
        defer task.destroy();
        if (task.cancelled.load(.acquire)) {
            if (task.file_id) |id| {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                try outgoing.removeDraft(s.store, arena.allocator(), task.key, &id);
            }
        } else if (task.failure) |err| {
            s.attachment_error = switch (err) {
                error.AttachmentTooLarge => "Attachments may use 100 MiB per file and 200 MiB per message.",
                error.TooManyAttachments => "A message can contain at most 16 attachments.",
                error.AttachmentStorageFull => "Local attachment storage is full. Remove unused files or completed drafts.",
                error.AttachmentSourceChanged => "The file changed while being copied. Drop it again when it has finished changing.",
                error.AttachmentSourceUnavailable => "Cannot read this file. Drop a local regular file, not a folder or symlink.",
                error.AttachmentCanceled => "File preparation cancelled.",
                error.InvalidRequest => "This filename cannot be sent. Rename the file and try again.",
                error.OutOfMemory => return error.OutOfMemory,
                else => "Could not save the attachment. Check available disk space and try again.",
            };
        }
        s.content_dirty = true;
        s.dirty = true;
    }
}

fn stopUpload(s: *Worker) void {
    if (s.upload) |*upload| upload.deinit(s.net.?);
    s.upload = null;
}

fn attachmentsReady(s: *const Worker) bool {
    return s.send_attachments and s.preparation != null and s.preparation.?.health.load(.acquire) == .ready;
}

fn uploadFiles(s: *Worker) !void {
    const preparation = if (s.preparation) |*value| value else return;
    if (s.reset != .idle or !s.online or s.auth_blocked) {
        s.stopUpload();
        return;
    }
    const net = s.net orelse return;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    if (s.upload) |*upload| {
        if (!u.eq(upload.input.server_epoch, try s.store.get(ar, "epoch"))) {
            s.stopUpload();
            return;
        }
        const finished = upload.poll(net, s.store, preparation.files) catch |err| finished: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.warn("Attachment upload delayed: {s}", .{@errorName(err)});
            try s.store.outcome(upload.input.request_id, if (upload.may_submit) "failed" else "unknown", if (upload.may_submit)
                "Could not verify the attachment upload. Originals are retained; review the files and connection."
            else
                "Submission response interrupted. Checking the original request ID; no automatic resend.");
            break :finished true;
        };
        if (finished) {
            const failure = upload.transport_error;
            const status = upload.http_status;
            s.stopUpload();
            // Wait five seconds before retrying transient upload failures.
            s.upload_retry_at = u.now() + 5000;
            s.content_dirty = true;
            s.dirty = true;
            if (failure.kind != c.ZC_OK and failure.kind != c.ZC_HTTP or status == 401 or status == 403) {
                s.transport_error = failure;
                s.disconnected(status);
            }
        } else if (u.now() - s.upload_published_at >= 100) {
            // Publish upload progress at 10 Hz to avoid rebuilding the UI snapshot per chunk.
            s.upload_published_at = u.now();
            s.dirty = true;
        }
        return;
    }
    if (!s.attachmentsReady() or u.now() < s.upload_retry_at) return;
    const q = try s.store.db.prepare("SELECT payload,state FROM outbox WHERE epoch=(SELECT value FROM meta WHERE key='epoch') AND record IS NULL AND state IN ('uploading','sending','unknown') AND json_array_length(payload,'$.attachments')>0 ORDER BY rowid LIMIT 1");
    defer q.close();
    if (try q.step()) {
        s.upload = try outgoing.Upload.init(a, net, q.bytes(0), u.eq(q.bytes(1), "uploading"));
        s.dirty = true;
    }
}
fn unresolvedText(s: *Worker) !bool {
    return try s.store.db.scalar("SELECT count(*) FROM outbox WHERE epoch=(SELECT value FROM meta WHERE key='epoch') AND record IS NULL AND state IN ('sending','unknown') AND coalesce(json_array_length(payload,'$.attachments'),0)=0") > 0;
}
fn schedule(s: *Worker) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    if (s.reset == .pending) {
        if (s.reset_epoch.len == 0) {
            try s.request(.reset_status, "/v1/status", .{}, null);
        } else try s.request(.reset, "/v1/reset", .{}, try u.json(ar, .{ .server_epoch = s.reset_epoch }));
        return;
    }
    if (s.reset != .idle) return;
    // Contact bootstrap retains its cursor and extension handshake, but text
    // history can run between pages or preempt an in-flight directory GET.
    if (!s.need_sync) if (s.identities_before) |before| {
        if (s.need_history and s.selected.len > 0 and !std.mem.startsWith(u8, s.selected, "new:")) {
            try s.requestHistory(ar);
        } else try s.request(
            .identities,
            "/v1/identities?limit=200{s}{f}",
            .{ if (before.len > 0) "&before=" else "", url_format.escaped(before) },
            null,
        );
        return;
    };
    if (!s.online) {
        if (s.stream_active) return;
        if (s.need_sync) {
            s.need_sync = false;
            try s.request(.sync, "/v1/sync", .{}, null);
        } else try s.request(.status, "/v1/status", .{}, null);
    } else if (try s.unresolvedText() and u.now() >= s.recovery_at) {
        const q = try s.store.db.prepare("SELECT id FROM outbox WHERE epoch=(SELECT value FROM meta WHERE key='epoch') AND record IS NULL AND state IN ('sending','unknown') AND coalesce(json_array_length(payload,'$.attachments'),0)=0 ORDER BY rowid LIMIT 1");
        defer q.close();
        if (try q.step()) {
            try s.setJobKey(q.bytes(0));
            // Poll unresolved sends every five seconds while awaiting relay observation.
            s.recovery_at = u.now() + 5000;
            try s.request(
                .recover,
                "/v1/send-requests/{s}",
                .{s.job_key},
                null,
            );
        }
    } else if (u.now() >= s.hydration_at and try s.hydrateSend()) {
        // A linked echo can arrive through reconciliation before its request.
        // Fetch that one message even when its conversation is not cached.
    } else if (s.need_history and s.selected.len > 0 and !std.mem.startsWith(u8, s.selected, "new:")) {
        try s.requestHistory(ar);
    } else if (s.enrichment_request) |cmd| {
        const next = try s.store.enrichmentNext(ar, cmd.key, cmd.recipient, cmd.text);
        if (next) |after| {
            const next_enrichment_after = try a.dupe(u8, after);
            a.free(s.enrichment_after);
            s.enrichment_after = next_enrichment_after;
            try s.request(.enrichment, "/v1/messages/{f}/enrichment?section={f}&revision={f}&limit=200{s}{f}", .{
                url_format.escaped(cmd.key),
                url_format.escaped(cmd.text),
                url_format.escaped(cmd.recipient),
                if (after.len > 0) "&after=" else "",
                url_format.escaped(after),
            }, null);
        } else {
            freeCommand(cmd);
            s.enrichment_request = null;
        }
    } else if (u.now() >= s.status_at) {
        try s.request(.status, "/v1/status", .{}, null);
    } else if (u.now() >= s.recovery_at) {
        // Poll unresolved sends every five seconds while awaiting relay observation.
        s.recovery_at = u.now() + 5000;
        const q = try s.store.db.prepare("SELECT id,rowid FROM outbox WHERE epoch=? AND state IN ('sending','unknown','queued','dispatching','submitted') AND (record IS NOT NULL OR coalesce(json_array_length(payload,'$.attachments'),0)=0) AND rowid>? ORDER BY rowid LIMIT 1");
        defer q.close();
        try q.bind(&.{ .{ .text = try s.store.get(ar, "epoch") }, .{ .int = s.recover_row } });
        if (try q.step()) {
            s.recover_row = q.int(1);
            try s.setJobKey(q.bytes(0));
            try s.request(
                .recover,
                "/v1/send-requests/{s}",
                .{s.job_key},
                null,
            );
        } else s.recover_row = 0;
    } else if (u.now() >= s.hydration_at and try s.hydrate(ar)) {
        // One visible message per cancellable request, after text and recovery.
    } else if (u.now() >= s.preview_at) {
        // Space preview refreshes by 100 ms while there is active work.
        s.preview_at = u.now() + 100;
        const q = try s.store.db.prepare("SELECT c.id FROM records c WHERE c.kind='conversation' AND NOT EXISTS(SELECT 1 FROM records m WHERE m.kind='message' AND m.chat=c.id) AND NOT EXISTS(SELECT 1 FROM previews p WHERE p.chat=c.id) ORDER BY c.sort_key DESC LIMIT 1");
        defer q.close();
        if (try q.step()) {
            try s.setJobKey(q.bytes(0));
            try s.request(
                .preview,
                "/v1/conversations/{f}/messages?limit=1{s}",
                .{ url_format.escaped(s.job_key), if (s.text_first_history) "&content=text" else "" },
                null,
            );
        } else s.preview_at = u.now() + 30000; // Idle previews can wait 30 seconds before another query.
    }
}
fn requestHistory(s: *Worker, ar: u.Allocator) !void {
    s.need_history = false;
    try s.setJobKey(s.selected);
    s.job_older = s.older;
    const next = if (s.older) try s.store.nextPage(ar, s.selected) else @as(?[]const u8, "");
    s.older = false;
    if (next) |cursor| try s.request(.history, "/v1/conversations/{f}/messages?limit={d}{s}{f}{s}", .{
        url_format.escaped(s.selected),
        Store.recent_history_limit,
        if (cursor.len > 0) "&before=" else "",
        url_format.escaped(cursor),
        if (s.text_first_history) "&content=text" else "",
    }, null);
}
fn hydrateSend(s: *Worker) !bool {
    const q = try s.store.db.prepare("SELECT id FROM (" ++ Store.send_echoes_query ++ ") echoes WHERE epoch=(SELECT value FROM meta WHERE key='epoch') AND id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM records m WHERE m.kind='message' AND m.id=echoes.id) ORDER BY position DESC LIMIT 1");
    defer q.close();
    if (!try q.step()) return false;
    try s.setJobKey(q.bytes(0));
    // Throttle metadata retries for five seconds after a response or transient failure.
    s.hydration_at = u.now() + 5000;
    try s.request(
        .hydrate,
        "/v1/messages/{f}",
        .{url_format.escaped(s.job_key)},
        null,
    );
    return true;
}
fn hydrate(s: *Worker, ar: u.Allocator) !bool {
    const cmd = s.hydration_request orelse return false;
    if (!u.eq(cmd.key, s.selected)) return false;
    const ids = try std.json.parseFromSliceLeaky([]const []const u8, ar, cmd.text, .{});
    // Match the server's 64-message hydration batch limit.
    for (ids[0..@min(ids.len, 64)]) |id| {
        const q = try s.store.db.prepare("SELECT json_extract(record,'$.metadata_deferred') FROM records WHERE kind='message' AND id=?");
        defer q.close();
        try q.bind(&.{.{ .text = id }});
        if (!try q.step() or q.int(0) != 1) continue;
        try s.setJobKey(id);
        try s.request(
            .hydrate,
            "/v1/messages/{f}",
            .{url_format.escaped(id)},
            null,
        );
        return true;
    }
    return false;
}
fn attach(s: *Worker, ar: u.Allocator) !void {
    if (s.stream_active) return;
    const cursor = try s.store.get(ar, "cursor");
    var buffer: [c.ZC_REQUEST_URL_CAPACITY]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &buffer,
        "/v1/events?after={f}{s}",
        .{ url_format.escaped(cursor), if (s.want_identities) "&extensions=identity-v1" else "" },
    ) catch return error.RequestPathTooLong;
    if (c.zc_net_start(s.net.?, 1, path, null, 0) == 0) return error.TransportFailure;
    s.stream_verified = false;
    s.stream_active = true;
    s.status = "Synchronizing live messages…";
    s.dirty = true;
}
fn complete(s: *Worker) !void {
    const n = s.net.?;
    const http_status = c.zc_net_status(n, 0);
    var request_error: c.ZcError = undefined;
    c.zc_net_error(n, 0, &request_error);
    // Keep an explicit SSE/configuration failure visible until Reconnect even
    // if an already-running API request finishes afterwards.
    if (!s.auth_blocked) s.transport_error = request_error;
    // A partial HTTP 200 must never be treated as a complete response.
    const status = if (request_error.curl_code == 0) http_status else 0;
    s.last_http_status = http_status;
    s.last_response_ms = u.now();
    var len: usize = 0;
    const ptr = c.zc_net_take_body(n, &len);
    defer std.c.free(ptr);
    const raw = if (ptr == null) "" else ptr[0..len];
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    c.zc_net_ack(n, 0);
    const job = s.job;
    if (request_error.curl_code == 0 and http_status >= 200 and http_status < 300) {
        log.debug("{s} response: HTTP {d}, {d} bytes", .{
            s.job_path[0..s.job_path_len],
            http_status,
            len,
        });
    } else {
        log.warn("{s} response: HTTP {d}, curl {d}, {d} bytes", .{
            s.job_path[0..s.job_path_len],
            http_status,
            request_error.curl_code,
            len,
        });
    }
    s.job = .idle;
    if (job == .reset or job == .reset_status) {
        if (status != 200) {
            s.resetError(if (status == 404 or status == 405)
                "This relay does not support reset yet. Update the relay on the Mac, then retry. Local data was kept."
            else
                "Relay reset was not confirmed. Local data was kept; check the connection and retry.");
            return;
        }
        s.handleResponse(ar, job, raw) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.warn("{s} response rejected: {s}", .{ @tagName(job), @errorName(err) });
            s.resetError("Invalid relay reset response. Local data was kept; update the relay and retry.");
        };
        s.dirty = true;
        return;
    }
    if (job != .status) s.content_dirty = true;
    if (status < 200 or status >= 300) {
        if (job == .hydrate and status != 401 and status != 403 and (status != 0 or request_error.kind == c.ZC_NETWORK)) {
            // Optional metadata failures leave text and the live stream usable.
            // Throttle metadata retries for five seconds after a response or transient failure.
            s.hydration_at = u.now() + 5000;
            s.dirty = true;
            return;
        }
        if (job == .enrichment) {
            if (s.enrichment_request) |cmd| freeCommand(cmd);
            s.enrichment_request = null;
            if (status == 409 or status == 404) {
                s.need_history = true;
                s.status = "Message changed · refreshing its content";
                s.dirty = true;
                return;
            }
        }
        if (job == .history and u.eq(s.job_key, s.selected)) {
            s.need_history = true;
            s.older = s.job_older;
        }
        if (job == .send) {
            // Transport failures and server errors may follow durable acceptance.
            const definite = status == 400 or status == 401 or status == 403 or status == 409 or status == 413;
            try s.store.outcome(
                s.job_key,
                if (definite) "failed" else "unknown",
                if (definite) "Relay rejected this submission. Copy it to the composer to edit." else "Outcome uncertain. Checking the original request ID; no automatic resend.",
            );
        } else if (job == .recover and status == 404) {
            try s.store.outcome(
                s.job_key,
                "unconfirmed",
                "The relay has no record of this request. It will not be resent automatically.",
            );
            s.dirty = true;
            return;
        }
        if (try requiresSync(ar, status, raw)) {
            log.info("Relay requested sync: job={s}, HTTP {d}", .{ @tagName(job), status });
            s.need_sync = true;
            s.disconnected(status);
            s.retry_at = 0;
        } else if ((job == .history or job == .preview) and status == 404) {
            s.need_history = false;
            s.status = "Conversation no longer available. Saved drafts and sends remain on this device.";
            s.dirty = true;
        } else s.disconnected(status);
        return;
    }
    if (s.auth_blocked and job != .send and job != .recover) return;
    s.handleResponse(ar, job, raw) catch |err| {
        log.warn("{s} response could not be applied: {s}", .{ @tagName(job), @errorName(err) });
        if (job == .hydrate) {
            // Throttle metadata retries for five seconds after a response or transient failure.
            s.hydration_at = u.now() + 5000;
            s.dirty = true;
            return;
        }
        if (job == .history and u.eq(s.job_key, s.selected)) {
            s.need_history = true;
            s.older = s.job_older;
        }
        if (job == .send) try s.store.outcome(
            s.job_key,
            "unknown",
            "Response interrupted. Checking the original request ID; no automatic resend.",
        );
        s.disconnected(0);
        s.status = if (err == error.InvalidEpoch)
            "Relay uses incompatible IDs · use Reset client and relay in Settings"
        else
            "Invalid relay response · saved messages remain available";
    };
    s.dirty = true;
}
fn handleResponse(s: *Worker, ar: u.Allocator, job: @FieldType(Worker, "job"), raw: []const u8) !void {
    // Bound token work as well as bytes before decoding an aggregate history response.
    try json_bounds.check(raw, t.max_history_bytes, 512 * 1024);
    switch (job) {
        .reset_status => {
            const v = try std.json.parseFromSliceLeaky(
                struct { server_epoch: []const u8 },
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            // Recovery accepts the old epoch as an opaque conditional token.
            if (v.server_epoch.len == 0 or v.server_epoch.len > 128) return error.InvalidEpoch;
            const epoch = try a.dupe(u8, v.server_epoch);
            a.free(s.reset_epoch);
            s.reset_epoch = epoch;
        },
        .reset => {
            const v = try std.json.parseFromSliceLeaky(
                struct { server_epoch: []const u8, cursor: []const u8 },
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            if (!t.validId(v.server_epoch) or u.eq(v.server_epoch, s.reset_epoch)) return error.InvalidEpoch;
            _ = try t.parseCursor(v.cursor, v.server_epoch);
            s.reset = .complete;
            s.status = "Relay reset complete · clearing local data…";
        },
        .status => {
            const v = try std.json.parseFromSliceLeaky(
                RelayStatus,
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            // Persist only the documented status fields, never credentials or
            // arbitrary HTTP response headers, for offline diagnostics.
            try s.store.set("relay_status", try u.json(ar, v));
            s.last_status_ms = u.now();
            try s.store.set(
                "server_checked_at",
                try std.fmt.allocPrint(ar, "{d}", .{s.last_status_ms}),
            );
            if (!u.eq(v.api_version, "1")) {
                s.auth_blocked = true;
                s.online = false;
                s.status = "Unsupported relay API version";
                return;
            }
            if (!t.validId(v.server_epoch)) {
                if (s.stream_active) c.zc_net_cancel_stream(s.net.?);
                s.stream_active = false;
                s.sse.reset();
                s.auth_blocked = true;
                s.online = false;
                s.status = "Relay uses incompatible IDs · use Reset client and relay in Settings";
                return;
            }
            var identities = false;
            for (v.event_extensions) |extension| if (u.eq(extension, "identity-v1")) {
                identities = v.capabilities.identity_directory_v1;
            };
            const changed_extension = identities != s.want_identities;
            s.want_identities = identities;
            s.text_first_history = v.capabilities.text_first_history_v1;
            if (!identities) try s.store.set("identity_bootstrapped", "0");
            const contacts = v.enrichment_readiness.identity_directory_v1;
            const blocked = !identities or (if (contacts.permission) |p| !u.eq(p, "authorized") else false);
            const old_blocked = u.eq(try s.store.get(ar, "contacts_blocked"), "1");
            // After denial, do not reveal older replayed names until the relay
            // has completed a successful reconciliation. Query failures retain
            // previously cached presentation, marked stale in Details.
            const gate = blocked or (old_blocked and !contacts.ready);
            try s.store.set("contacts_blocked", if (gate) "1" else "0");
            if (gate != old_blocked) log.info("Contact presentation changed: blocked={}, permission={s}, reason={s}", .{
                gate,
                contacts.permission orelse "unspecified",
                contacts.reason,
            });
            s.content_dirty = s.content_dirty or gate != old_blocked;
            if (changed_extension and s.stream_active) {
                c.zc_net_cancel_stream(s.net.?);
                s.stream_active = false;
                s.sse.reset();
                s.online = false;
            }
            s.send_direct = v.capabilities.send_direct;
            s.reply_existing = v.capabilities.reply_existing;
            s.send_attachments = v.capabilities.send_attachments_v1 and v.capabilities.attachment_uploads_v1;
            // Poll status each second during sync and every five seconds while idle.
            s.status_at = u.now() + @as(i64, if (v.sync_activity.active()) 1000 else 5000);
            const epoch_changed = !u.eq(v.server_epoch, try s.store.get(ar, "epoch"));
            if (epoch_changed or !u.eq(
                try s.store.get(ar, "bootstrapped"),
                "1",
            )) {
                if (s.stream_active) {
                    c.zc_net_cancel_stream(s.net.?);
                    s.stream_active = false;
                    s.sse.reset();
                }
                s.online = false;
                log.info("Status requested bootstrap: epoch_changed={}", .{epoch_changed});
                try s.request(.sync, "/v1/sync", .{}, null);
            } else if (identities and !u.eq(try s.store.get(ar, "identity_bootstrapped"), "1")) {
                // Enabling Contacts does not invalidate message history or its cursor.
                // Snapshot the directory, then replay from the saved cursor to cover overlap.
                if (s.stream_active) {
                    c.zc_net_cancel_stream(s.net.?);
                    s.stream_active = false;
                    s.sse.reset();
                }
                s.online = false;
                s.identities_before = try a.dupe(u8, "");
                s.status = "Downloading contact names…";
                log.info("Contact bootstrap started; retaining message cache and cursor", .{});
            } else {
                try s.attach(ar);
                if (s.online) s.status = if (!v.adapter_ready) "Relay reachable · Messages unavailable; run relay doctor on the Mac" else if (!s.send_direct and !s.reply_existing) "Connected · sending unavailable; check Messages Automation permission" else "Connected";
            }
        },
        .sync => {
            if (s.identities_before) |before| a.free(before);
            s.identities_before = null;
            const v = try std.json.parseFromSliceLeaky(
                struct { server_epoch: []const u8, cursor: []const u8 },
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            try s.store.beginSync(v.server_epoch, v.cursor);
            log.info("Sync bootstrap started: contacts={}", .{s.want_identities});
            s.status = "Downloading conversations…";
            try s.request(.chats, "/v1/conversations?limit=200&previews=1", .{}, null);
        },
        .chats => {
            const v = try std.json.parseFromSliceLeaky(
                struct {
                    conversations: []const json_bounds.Decoded(t.Conversation),
                    next: ?[]const u8,
                    previews: ?[]const json_bounds.Decoded(t.ConversationPreview) = null,
                },
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            if (v.conversations.len > t.max_page or (if (v.previews) |items| items.len else 0) > t.max_page) return error.InvalidRecord;
            try s.store.db.exec("BEGIN IMMEDIATE");
            errdefer s.store.db.exec("ROLLBACK") catch {};
            for (v.conversations) |chat| _ = try s.store.upsertDecoded(ar, .{ .conversation = chat });
            if (v.previews) |previews| {
                for (previews) |preview| try s.store.savePreviewDecoded(preview);
                // An empty chat was also covered by this page. Older relays
                // omit projections and keep the existing preview fallback.
                for (v.conversations) |chat| {
                    try s.store.exec(
                        "INSERT OR IGNORE INTO previews(chat) VALUES(?)",
                        &.{.{ .text = chat.value.id }},
                    );
                }
            }
            try s.store.db.exec("COMMIT");
            log.debug("Conversation page committed: conversations={d} previews={d} more={}", .{
                v.conversations.len,
                if (v.previews) |items| items.len else 0,
                v.next != null,
            });
            if (v.next) |next| try s.request(
                .chats,
                "/v1/conversations?limit=200&previews=1&before={f}",
                .{url_format.escaped(next)},
                null,
            ) else {
                log.info("Conversation bootstrap complete", .{});
                if (s.want_identities) {
                    s.status = "Downloading contact names…";
                    s.identities_before = try a.dupe(u8, "");
                    s.need_history = s.selected.len > 0;
                } else try s.finishBootstrap(ar);
            }
        },
        .identities => {
            const v = try std.json.parseFromSliceLeaky(
                struct { identities: []const json_bounds.Decoded(t.Identity), next: ?[]const u8 },
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            if (v.identities.len > t.max_page) return error.InvalidRecord;
            try s.store.db.exec("BEGIN IMMEDIATE");
            errdefer s.store.db.exec("ROLLBACK") catch {};
            for (v.identities) |identity| _ = try s.store.upsertDecoded(ar, .{ .identity = identity });
            if (v.next == null) try s.store.set("identity_bootstrapped", "1");
            try s.store.db.exec("COMMIT");
            log.debug("Contact page committed: identities={d} more={}", .{
                v.identities.len,
                v.next != null,
            });
            if (v.next == null) log.info("Contact bootstrap complete", .{});
            if (s.identities_before) |before| a.free(before);
            s.identities_before = null;
            if (v.next) |next| {
                s.identities_before = try a.dupe(u8, next);
            } else try s.finishBootstrap(ar);
        },
        .history, .preview => {
            const v = try std.json.parseFromSliceLeaky(
                struct { messages: []const json_bounds.Decoded(t.Message), next: ?[]const u8 },
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            if (v.messages.len > t.max_page) return error.InvalidRecord;
            try s.store.db.exec("BEGIN IMMEDIATE");
            errdefer s.store.db.exec("ROLLBACK") catch {};
            for (v.messages) |message| _ = try s.store.upsertDecoded(ar, .{ .message = message });
            if (job == .history) try s.store.page(s.job_key, v.next) else try s.store.exec(
                "INSERT OR IGNORE INTO previews(chat) VALUES(?)",
                &.{.{ .text = s.job_key }},
            );
            try s.store.db.exec("COMMIT");
            log.debug("{s} page committed: messages={d} more={}", .{
                @tagName(job),
                v.messages.len,
                v.next != null,
            });
        },
        .enrichment => {
            const cmd = s.enrichment_request orelse return;
            defer {
                freeCommand(cmd);
                s.enrichment_request = null;
            }
            const applied = try s.store.enrichmentPage(
                ar,
                raw,
                cmd.key,
                cmd.recipient,
                std.meta.stringToEnum(content.Section, cmd.text) orelse return error.InvalidSection,
                s.enrichment_after,
            );
            log.debug("Message metadata page: section={s} applied={}", .{ cmd.text, applied });
        },
        .hydrate => {
            const message = try std.json.parseFromSliceLeaky(
                json_bounds.Decoded(t.Message),
                ar,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            if (!u.eq(message.value.id, s.job_key) or message.value.metadata_deferred) return error.InvalidRecord;
            try s.store.db.exec("BEGIN IMMEDIATE");
            errdefer s.store.db.exec("ROLLBACK") catch {};
            const updated = try s.store.upsertDecoded(ar, .{ .message = message });
            try s.store.db.exec("COMMIT");
            log.debug("Message hydration committed: updated={}", .{updated});
        },
        .send, .recover => {
            _ = try s.store.upsert(ar, "request", raw);
            s.recovery_at = u.now() + 1000;
        },
        .idle => {},
    }
}
fn requiresSync(ar: u.Allocator, status: c_long, raw: []const u8) !bool {
    if (status != 409 and status != 410) return false;
    const response = std.json.parseFromSliceLeaky(
        struct { error_info: struct { code: []const u8 } },
        ar,
        raw,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    return u.eq(response.error_info.code, "resync_required");
}
fn finishBootstrap(s: *Worker, ar: u.Allocator) !void {
    try s.store.set("bootstrapped", "1");
    log.info("Sync bootstrap complete; attaching live stream", .{});
    s.need_history = true;
    try s.attach(ar);
}
fn resetError(s: *Worker, message: []const u8) void {
    s.reset = .failed;
    s.status = message;
    s.auth_blocked = true;
    s.online = false;
    s.dirty = true;
}
fn drain(s: *Worker) !void {
    // A send can preempt an idempotent background GET. A POST is never
    // cancelled or repeated here: its result must remain authoritative.
    while (true) {
        s.mutex.lockUncancelable(s.io);
        if (s.commands.items.len == 0) {
            s.mutex.unlock(s.io);
            break;
        }
        if (s.reset == .idle and s.commands.items[0].kind == .send and s.job != .idle and !s.stop.load(.acquire)) {
            if (s.online and (s.job == .history or s.job == .preview or s.job == .status or s.job == .recover or s.job == .enrichment or s.job == .hydrate)) {
                switch (s.job) {
                    .history => {
                        s.need_history = true;
                        s.older = s.job_older;
                    },
                    .enrichment, .hydrate => {},
                    .preview => s.preview_at = 0,
                    .status => s.status_at = 0,
                    .recover => {
                        s.recovery_at = 0;
                        s.recover_row = 0;
                    },
                    else => unreachable,
                }
                c.zc_net_cancel_request(s.net.?);
                s.job = .idle;
            } else {
                s.mutex.unlock(s.io);
                break;
            }
        }
        const cmd = s.commands.orderedRemove(0);
        s.mutex.unlock(s.io);
        defer freeCommand(cmd);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        s.command_serial = @max(s.command_serial, cmd.serial);
        if (cmd.serial != 0) s.dirty = true;
        if (s.reset != .idle and cmd.kind != .reset and cmd.kind != .reconnect and cmd.kind != .draft) continue;
        if ((cmd.kind == .select or cmd.kind == .older) and (s.job == .hydrate or s.job == .enrichment or s.job == .preview or s.job == .identities or (cmd.kind == .select and s.job == .history))) {
            c.zc_net_cancel_request(s.net.?);
            s.job = .idle;
        }
        switch (cmd.kind) {
            .reset => {
                if (s.reset == .pending or s.reset == .complete) continue;
                if (s.job == .send) try s.store.outcome(
                    s.job_key,
                    "unknown",
                    "Relay reset requested; the original send may already have reached Messages.",
                );
                s.stopUpload();
                if (s.net) |n| c.zc_net_free(n);
                s.net = null;
                s.job = .idle;
                s.stream_active = false;
                s.sse.reset();
                s.online = false;
                s.auth_blocked = false;
                s.retry_at = 0;
                s.reset = .pending;
                s.status = "Resetting relay data…";
                s.dirty = true;
            },
            .hydrate => {
                if (!u.eq(cmd.key, s.selected)) continue;
                const ids = std.json.parseFromSliceLeaky([]const []const u8, ar, cmd.text, .{}) catch continue;
                if (ids.len > 64) continue;
                if (s.job == .hydrate) {
                    const visible = for (ids) |id| {
                        if (u.eq(id, s.job_key)) break true;
                    } else false;
                    if (!visible) {
                        c.zc_net_cancel_request(s.net.?);
                        s.job = .idle;
                    }
                }
                const key = try a.dupe(u8, cmd.key);
                errdefer a.free(key);
                const text = try a.dupe(u8, cmd.text);
                if (s.hydration_request) |previous| freeCommand(previous);
                s.hydration_request = .{
                    .kind = .hydrate,
                    .key = key,
                    .text = text,
                };
                continue;
            },
            .enrichment => {
                if (s.enrichment_request == null and std.meta.stringToEnum(
                    content.Section,
                    cmd.text,
                ) != null) {
                    s.enrichment_request = .{
                        .kind = .enrichment,
                        .key = try a.dupe(u8, cmd.key),
                        .text = try a.dupe(u8, cmd.text),
                        .recipient = try a.dupe(u8, cmd.recipient),
                    };
                }
            },
            .hide, .unhide => {
                try s.store.setHidden(cmd.key, cmd.kind == .hide);
                s.content_dirty = true;
            },
            .select => {
                if (s.hydration_request) |previous| freeCommand(previous);
                s.hydration_request = null;
                s.hydration_at = 0;
                if (s.enrichment_request) |previous| freeCommand(previous);
                s.enrichment_request = null;
                s.content_dirty = true;
                a.free(s.redirect_from);
                s.redirect_from = "";
                const next_selected = try a.dupe(u8, cmd.key);
                a.free(s.selected);
                s.selected = next_selected;
                s.viewed = !u.eq(cmd.text, "no");
                try s.store.set("selected", cmd.key);
                if (s.viewed) try s.store.read(cmd.key);
                s.need_history = cmd.key.len > 0;
                s.older = false;
            },
            .draft => {
                try s.store.saveDraft(cmd.key, cmd.text);
                // Draft-only entries can appear/disappear in the sidebar;
                // normal conversation drafts do not alter any cached records.
                const q = try s.store.db.prepare("SELECT 1 FROM records WHERE kind='conversation' AND id=?");
                defer q.close();
                try q.bind(&.{.{ .text = cmd.key }});
                if (!try q.step()) s.content_dirty = true;
            },
            .attach => {
                if (cmd.key.len == 0 or cmd.text.len == 0 or cmd.text.len > 4096) continue;
                if (s.preparation) |*preparation| {
                    if (preparation.health.load(.acquire) != .failed) {
                        preparation.push(try s.store.threadKey(ar, cmd.key), cmd.text) catch |err| {
                            if (err == error.OutOfMemory) return err;
                            s.attachment_error = "Too many files are being prepared. Wait, then try again.";
                            continue;
                        };
                        s.attachment_error = "";
                    } else s.attachment_error = "Attachment preparation is unavailable. Restart the client.";
                } else s.attachment_error = "Private attachment storage is unavailable.";
            },
            .remove_attachment => {
                try outgoing.removeDraft(s.store, ar, cmd.key, cmd.text);
                if (s.preparation) |*preparation| preparation.wake();
                s.content_dirty = true;
                s.attachment_error = "";
            },
            .cancel_preparation => if (s.preparation) |*preparation| {
                preparation.cancel(try s.store.threadKey(ar, cmd.key));
            },
            .cancel_upload => {
                const q = try s.store.db.prepare("SELECT state FROM outbox WHERE id=? AND record IS NULL");
                defer q.close();
                try q.bind(&.{.{ .text = cmd.key }});
                if (try q.step() and u.eq(q.bytes(0), "uploading")) {
                    if (s.upload) |upload| if (u.eq(upload.input.request_id, cmd.key)) s.stopUpload();
                    try s.store.outcome(cmd.key, "cancelled", "Upload cancelled before submission. The original files are retained on this device.");
                    s.content_dirty = true;
                } else s.attachment_error = "This request may already have been submitted. Check its status before sending again.";
            },
            .viewed => {
                s.viewed = u.eq(cmd.text, "yes");
                if (s.viewed) {
                    try s.store.read(s.selected);
                    s.content_dirty = s.content_dirty or u.c.sqlite3_changes(s.store.db.handle) > 0;
                }
            },
            .older => {
                s.older = true;
                s.need_history = true;
            },
            .reconnect => {
                if (s.reset == .pending or s.reset == .complete) continue;
                s.reset = .idle;
                a.free(s.reset_epoch);
                s.reset_epoch = "";
                if (s.identities_before) |before| a.free(before);
                s.identities_before = null;
                if (s.job == .send) {
                    try s.store.outcome(
                        s.job_key,
                        "unknown",
                        "Connection changed. Checking the original request ID before any new submission.",
                    );
                    s.content_dirty = true;
                }
                if (s.job == .history) {
                    s.need_history = true;
                    s.older = s.job_older;
                }
                s.recovery_at = 0;
                s.recover_row = 0;
                s.auth_blocked = false;
                s.extension_rejected = false;
                s.retry_at = 0;
                s.backoff = 1000;
                s.status_at = 0;
                s.online = false;
                s.stopUpload();
                s.upload_retry_at = 0;
                if (s.net) |n| {
                    c.zc_net_free(n);
                    s.net = null;
                    s.job = .idle;
                    s.stream_active = false;
                    s.sse.reset();
                }
            },
            .check => {
                s.recovery_at = 0;
            },
            .send => {
                s.content_dirty = true;
                const files = try outgoing.draft(s.store, ar, cmd.key);
                const preparing = if (s.preparation) |*preparation| preparation.busy("") else false;
                if (preparing) {
                    try s.store.saveDraft(cmd.key, cmd.text);
                    s.attachment_error = "Wait for file preparation to finish before sending.";
                } else if (!s.online or s.stop.load(.acquire)) {
                    try s.store.saveDraft(cmd.key, cmd.text);
                    s.status = "Offline · message kept as a draft";
                } else if (try s.unresolved()) {
                    try s.store.saveDraft(cmd.key, cmd.text);
                    s.recovery_at = 0;
                    s.status = "Checking the previous send's original request ID · new message kept as a draft";
                } else {
                    const target: t.Target = if (std.mem.startsWith(u8, cmd.key, "new:")) .{ .recipient = .{ .address = cmd.recipient, .service = "imessage" } } else try s.store.sendTarget(
                        ar,
                        cmd.key,
                    );
                    const direct = target.recipient != null;
                    if ((direct and !s.send_direct) or (!direct and !s.reply_existing) or (files.len != 0 and !s.attachmentsReady())) {
                        s.status = "Sending unavailable · message kept as a draft";
                        try s.store.saveDraft(cmd.key, cmd.text);
                    } else {
                        const input = t.SendInput{
                            .request_id = try u.id(ar),
                            .server_epoch = try s.store.get(ar, "epoch"),
                            .target = target,
                            .text = cmd.text,
                            .attachments = files,
                        };
                        try s.store.persistSend(ar, cmd.key, input);
                        if (files.len == 0) {
                            try s.setJobKey(input.request_id);
                            try s.request(.send, "/v1/messages", .{}, try u.json(ar, input));
                        } else s.upload_retry_at = 0;
                    }
                }
                s.ack += 1;
            },
        }
        s.dirty = true;
    }
}
fn resolveDirect(s: *Worker) !void {
    if (s.selected.len == 0 or (!s.content_dirty and !std.mem.startsWith(u8, s.selected, "new:"))) return;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const canonical = try s.store.threadKey(ar, s.selected);
    if (!u.eq(canonical, s.selected)) {
        try s.store.set("selected", canonical);
        if (s.viewed) try s.store.read(canonical);
        const next_redirect_from = try a.dupe(u8, s.selected);
        errdefer a.free(next_redirect_from);
        const next_selected = try a.dupe(u8, canonical);
        a.free(s.redirect_from);
        s.redirect_from = next_redirect_from;
        a.free(s.selected);
        s.selected = next_selected;
        s.need_history = true;
        s.older = false;
        s.dirty = true;
        s.content_dirty = true;
    }
    if (!std.mem.startsWith(u8, s.selected, "new:")) return;
    if ((try s.store.draft(ar, s.selected)).len > 0) return;
    if ((try outgoing.draft(s.store, ar, s.selected)).len != 0) return;
    const q = try s.store.db.prepare("SELECT m.chat FROM outbox o LEFT JOIN json_each(o.record,'$.parts') part JOIN records m ON m.kind='message' AND m.id=coalesce(json_extract(o.record,'$.message_id'),json_extract(part.value,'$.message_id')) WHERE o.draft_key=? AND o.epoch=? LIMIT 1");
    defer q.close();
    try q.bind(&.{ .{ .text = s.selected }, .{ .text = try s.store.get(ar, "epoch") } });
    if (!try q.step()) return;
    const chat = try q.text(ar, 0);
    try s.store.exec(
        "UPDATE outbox SET draft_key=? WHERE draft_key=?",
        &.{ .{ .text = chat }, .{ .text = s.selected } },
    );
    try s.store.exec(
        "INSERT OR IGNORE INTO hidden_chats SELECT ? WHERE EXISTS(SELECT 1 FROM hidden_chats WHERE key=?)",
        &.{ .{ .text = chat }, .{ .text = s.selected } },
    );
    try s.store.setHidden(s.selected, false);
    try s.store.set("selected", chat);
    const next_redirect_from = try a.dupe(u8, s.selected);
    errdefer a.free(next_redirect_from);
    const next_selected = try a.dupe(u8, chat);
    a.free(s.redirect_from);
    s.redirect_from = next_redirect_from;
    a.free(s.selected);
    s.selected = next_selected;
    s.need_history = true;
    s.dirty = true;
    s.content_dirty = true;
}
fn publish(s: *Worker) !void {
    if (s.content_dirty or s.shared == null) {
        const shared = try SharedSnapshot.create(
            s.store,
            s.selected,
            s.content_generation + 1,
            s.shared,
        );
        if (s.shared) |old| old.release();
        s.shared = shared;
        s.content_generation += 1;
        s.content_dirty = false;
    }
    const shared = s.shared.?.retain();
    errdefer shared.release();
    const v = try a.create(View);
    errdefer a.destroy(v);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    s.generation += 1;
    v.* = .{
        .arena = arena,
        .snapshot = shared.snapshot,
        .shared = shared,
        .content_generation = shared.generation,
        .credential_generation = s.credential_generation,
        .status = try arena.allocator().dupe(u8, s.status),
        .online = s.online,
        .send_direct = s.send_direct,
        .reply_existing = s.reply_existing,
        .send_attachments = s.attachmentsReady(),
        .preparing_attachments = if (s.preparation) |*preparation| preparation.busy("") else false,
        .preparing_draft = if (s.preparation) |*preparation| preparation.busy(s.selected) else false,
        .command_serial = s.command_serial,
        .attachment_error = try arena.allocator().dupe(u8, s.attachment_error),
        .generation = s.generation,
        .ack = s.ack,
        .reset = s.reset,
        .loading_history = s.need_history or s.job == .history,
        .redirect_from = try arena.allocator().dupe(u8, s.redirect_from),
    };
    const ar = arena.allocator();
    v.snapshot.draft = try s.store.draft(ar, s.selected);
    v.snapshot.draft_attachments = try outgoing.draft(s.store, ar, s.selected);
    if (s.upload) |*upload| {
        v.upload = upload.progress(s.net.?);
        v.upload.request_id = try ar.dupe(u8, v.upload.request_id);
        v.upload.filename = try ar.dupe(u8, v.upload.filename);
    }
    const server = try s.store.get(ar, "relay_status");
    // Warn 30 days before expiry to leave time for certificate renewal.
    const expiring = s.identity.expires_at > 0 and s.identity.expires_at - @divTrunc(u.now(), 1000) <= 30 * 86400;
    if (expiring and s.online) v.status = try std.fmt.allocPrint(
        ar,
        "{s} · client certificate expires {s}; renew and Reconnect",
        .{ s.status, std.mem.sliceTo(&s.identity.expires, 0) },
    );
    v.diagnostics = .{
        .transport = .{
            .failure = switch (s.transport_error.kind) {
                c.ZC_OK => "none",
                c.ZC_NETWORK => "network",
                c.ZC_SERVER_TRUST => "server_trust",
                c.ZC_CREDENTIALS => "credentials",
                c.ZC_CLIENT_REJECTED => "client_rejected",
                c.ZC_TLS => "tls",
                c.ZC_HTTP => "http",
                else => "configuration",
            },
            .curl_code = s.transport_error.curl_code,
            .verify_result = s.transport_error.verify_result,
            .detail = try ar.dupe(u8, std.mem.sliceTo(&s.transport_error.message, 0)),
            .fingerprint = try ar.dupe(u8, std.mem.sliceTo(&s.identity.fingerprint, 0)),
            .expires = try ar.dupe(u8, std.mem.sliceTo(&s.identity.expires, 0)),
            .expiring = expiring,
        },
        .server = if (server.len > 0) (try std.json.parseFromSlice(
            RelayStatus,
            ar,
            server,
            .{ .ignore_unknown_fields = true },
        )).value else null,
        .cursor = try s.store.get(ar, "cursor"),
        .job = @tagName(s.job),
        .bootstrapped = u.eq(try s.store.get(ar, "bootstrapped"), "1"),
        .stream_active = s.stream_active,
        .auth_blocked = s.auth_blocked,
        .retry_at = s.retry_at,
        .last_status_ms = s.last_status_ms,
        .last_event_ms = s.last_event_ms,
        .last_response_ms = s.last_response_ms,
        .last_http_status = s.last_http_status,
        .cached_messages = shared.cached_messages,
        .saved_drafts = try s.store.db.scalar("SELECT count(*) FROM drafts WHERE length(text)>0"),
        .pending_sends = shared.pending_sends,
    };
    v.sync_activity = s.syncActivity(v.diagnostics.server);
    // Arena state changes during snapshot construction: retain the final state.
    v.arena = arena;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.view) |old| old.destroy();
    s.view = v;
    s.dirty = false;
    s.last_published = u.now();
    if (s.on_ready) |ready| ready();
}

fn syncActivity(s: *const Worker, server: ?RelayStatus) t.SyncActivity {
    if (s.auth_blocked or s.reset != .idle or u.now() < s.retry_at) return .{};
    var activity: t.SyncActivity = if (s.online and server != null)
        server.?.sync_activity
    else
        .{};
    activity.contacts = activity.contacts or s.identities_before != null or
        (s.online and s.contacts_sync_until != 0);
    activity.messages = activity.messages or (s.online and s.need_history and
        s.selected.len > 0 and !std.mem.startsWith(u8, s.selected, "new:"));
    switch (s.job) {
        .sync, .chats, .history, .preview => activity.messages = true,
        .identities => activity.contacts = true,
        .enrichment, .hydrate => activity.media = true,
        .idle, .status, .send, .recover, .reset_status, .reset => {},
    }
    return activity;
}

test "lazy metadata upgrades a text snapshot without changing its revision or losing newer text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const store = try Store.open(":memory:");
    defer store.close();
    const History = @import("MessageHistory.zig");
    var message = t.Message{
        .id = "message",
        .revision = "1",
        .conversation_id = "chat",
        .sender = "peer",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .attachment,
        .text = "Caption 👋",
        .decoding = .plain,
        .observed_status = .received,
        .metadata_deferred = true,
    };
    const projection = try u.json(ar, message);
    _ = try store.upsert(ar, "message", projection);
    const text = try History.create(store, "chat", null);
    defer text.release();
    try std.testing.expectEqualStrings("Caption 👋", text.presentations[0].text);
    message.metadata_deferred = false;
    message.attachments = &.{.{
        .id = "photo",
        .name = "Photo",
        .mime_type = "image/png",
        .bytes = "1",
    }};
    const full = try u.json(ar, message);
    _ = try store.upsert(ar, "message", full);
    const rich = try History.create(store, "chat", text);
    defer rich.release();
    try std.testing.expect(rich != text);
    try std.testing.expectEqual(@as(usize, 1), rich.messages[0].attachments.len);
    try std.testing.expect(text.messages[0].metadata_deferred);
    try std.testing.expect(!rich.messages[0].metadata_deferred);
    _ = try store.upsert(ar, "message", projection);
    const repeated = try History.create(store, "chat", rich);
    defer repeated.release();
    try std.testing.expectEqual(rich, repeated);
    message.revision = "2";
    message.text = "Edited caption";
    message.metadata_deferred = true;
    message.attachments = &.{};
    _ = try store.upsert(ar, "message", try u.json(ar, message));
    _ = try store.upsert(ar, "message", full);
    const edited = try History.create(store, "chat", rich);
    defer edited.release();
    try std.testing.expectEqualStrings("Edited caption", edited.messages[0].text.?);
    try std.testing.expect(edited.messages[0].metadata_deferred);
}

test "worker shuts down before making its first request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
        0,
    );
    defer std.testing.allocator.free(data);
    var worker = Worker{
        .io = std.testing.io,
        .config = .{ .data = data },
        .auth_blocked = true,
    };
    try worker.start();
    worker.shutdown();
    try std.testing.expectEqual(@as(u64, 1), worker.generation);
    try std.testing.expectEqual(.idle, worker.job);
}

test "oversized request paths are rejected before starting transport" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    const path = "/" ++ "x" ** (c.ZC_REQUEST_URL_CAPACITY - 1);
    try std.testing.expectError(error.RequestPathTooLong, worker.request(.history, "{s}", .{path}, null));
    try std.testing.expectEqual(.idle, worker.job);
    try std.testing.expectEqual(@as(usize, 0), worker.job_path_len);
}

test "metadata views share immutable history while edited records replace it" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    worker.selected = "chat";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    _ = try worker.store.upsert(ar, "conversation", "{\"id\":\"chat\",\"service\":\"imessage\"}");
    var message = t.Message{
        .id = "message",
        .conversation_id = "chat",
        .sender = "peer",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = "Original",
        .decoding = .plain,
        .observed_status = .received,
    };
    _ = try worker.store.upsert(ar, "message", try u.json(ar, message));
    try worker.publish();
    const first = worker.take().?;
    defer first.destroy();
    try worker.push(.{
        .kind = .draft,
        .key = "chat",
        .text = "New draft",
    });
    try worker.drain();
    try worker.publish();
    const metadata = worker.take().?;
    defer metadata.destroy();
    try std.testing.expectEqual(first.shared, metadata.shared);
    try std.testing.expectEqual(first.content_generation, metadata.content_generation);
    try std.testing.expectEqualStrings("New draft", metadata.snapshot.draft);
    try std.testing.expectEqualStrings("", first.snapshot.draft);
    try worker.push(.{ .kind = .hide, .key = "chat" });
    try worker.drain();
    try worker.publish();
    const hidden = worker.take().?;
    defer hidden.destroy();
    try std.testing.expect(hidden.snapshot.chats[0].hidden);
    try std.testing.expect(!metadata.snapshot.chats[0].hidden);
    try std.testing.expectEqual(metadata.shared.?.history, hidden.shared.?.history);
    try std.testing.expectEqualStrings("New draft", hidden.snapshot.draft);
    try worker.push(.{ .kind = .unhide, .key = "chat" });
    try worker.drain();
    try worker.publish();
    const visible = worker.take().?;
    defer visible.destroy();
    try std.testing.expect(!visible.snapshot.chats[0].hidden);
    message.text = "Edited";
    message.revision = "1";
    _ = try worker.store.upsert(ar, "message", try u.json(ar, message));
    worker.content_dirty = true;
    try worker.publish();
    const changed = worker.take().?;
    defer changed.destroy();
    try std.testing.expect(first.shared != changed.shared);
    try std.testing.expectEqualStrings("Original", first.snapshot.messages[0].text.?);
    try std.testing.expectEqualStrings("Edited", changed.snapshot.messages[0].text.?);
}

test "contact sync is published only after commit and expires without changing content" {
    const epoch = "EjRWeBI0EjQSNBI0VniQEg";
    var worker = Worker{
        .io = std.testing.io,
        .config = .{ .data = "" },
        .online = true,
    };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    defer worker.sse.deinit();
    try worker.store.beginSync(epoch, epoch ++ ":0");
    try worker.store.set("accepted_extensions", "identity-v1");
    const frame = "id: " ++ epoch ++ ":1\nevent: identity.upsert\ndata: {\"cursor\":\"" ++
        epoch ++ ":1\",\"sequence\":\"1\",\"type\":\"identity.upsert\",\"origin\":\"reconciliation\"," ++
        "\"record\":{\"id\":\"peer\",\"revision\":\"1\",\"service\":\"imessage\"," ++
        "\"address\":\"peer@example.invalid\",\"match_state\":\"matched\",\"display_name\":\"Updated\"}}\n\n";
    try std.testing.expectError(error.InvalidFrame, worker.receiveBatch(frame ++ "data: invalid\n\n"));
    try std.testing.expect(!worker.syncActivity(null).contacts);
    worker.sse.reset();
    // Fail the outer commit after the contact record and cursor were applied.
    try worker.store.db.exec(
        "PRAGMA foreign_keys=ON; CREATE TABLE commit_parent(id TEXT PRIMARY KEY);" ++
            "CREATE TABLE commit_guard(id TEXT REFERENCES commit_parent(id) DEFERRABLE INITIALLY DEFERRED);" ++
            "CREATE TRIGGER reject_contact AFTER INSERT ON identities BEGIN INSERT INTO commit_guard VALUES('missing'); END;",
    );
    try std.testing.expectError(error.DatabaseFailure, worker.receiveBatch(frame));
    try std.testing.expect(!worker.syncActivity(null).contacts);
    try worker.store.db.exec("DROP TRIGGER reject_contact; DROP TABLE commit_guard; DROP TABLE commit_parent");
    worker.sse.reset();
    try worker.receiveBatch(frame);
    try worker.publish();
    const syncing = worker.take().?;
    defer syncing.destroy();
    try std.testing.expect(syncing.sync_activity.contacts);
    worker.online = false;
    try std.testing.expect(!worker.syncActivity(null).contacts);
    worker.online = true;
    worker.expireContactSync(worker.contacts_sync_until - 1);
    try std.testing.expect(!worker.dirty);
    worker.expireContactSync(worker.contacts_sync_until);
    try std.testing.expect(worker.dirty);
    try worker.publish();
    const idle = worker.take().?;
    defer idle.destroy();
    try std.testing.expect(!idle.sync_activity.active());
    try std.testing.expectEqual(syncing.shared, idle.shared);
}

test "an invalid frame rolls back the complete network batch for safe replay" {
    const epoch = "EjRWeBI0EjQSNBI0VniQEg";
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    defer worker.sse.deinit();
    try worker.store.beginSync(epoch, epoch ++ ":0");
    const frame = "id: " ++ epoch ++ ":1\nevent: conversation.upsert\ndata: {\"cursor\":\"" ++ epoch ++ ":1\",\"sequence\":\"1\",\"type\":\"conversation.upsert\",\"origin\":\"live\",\"record\":{\"id\":\"chat\",\"service\":\"imessage\"}}\n\n";
    try std.testing.expectError(
        error.InvalidFrame,
        worker.receiveBatch(frame ++ "data: invalid\n\n"),
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        try worker.store.db.scalar("SELECT count(*) FROM records"),
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        epoch ++ ":0",
        try worker.store.get(arena.allocator(), "cursor"),
    );
    worker.sse.reset();
    try worker.store.db.exec("CREATE TRIGGER reject_cursor BEFORE UPDATE ON meta WHEN NEW.key='cursor' BEGIN SELECT RAISE(ABORT,'failure'); END");
    try std.testing.expectError(error.DatabaseFailure, worker.receiveBatch(frame));
    try std.testing.expectEqual(
        @as(i64, 0),
        try worker.store.db.scalar("SELECT count(*) FROM records"),
    );
    try std.testing.expectEqualStrings(
        epoch ++ ":0",
        try worker.store.get(arena.allocator(), "cursor"),
    );
    try worker.store.db.exec("DROP TRIGGER reject_cursor");
    worker.sse.reset();
    try worker.receiveBatch(frame);
    try std.testing.expectEqual(
        @as(i64, 1),
        try worker.store.db.scalar("SELECT count(*) FROM records"),
    );
    try std.testing.expectEqualStrings(
        epoch ++ ":1",
        try worker.store.get(arena.allocator(), "cursor"),
    );
}

test "notifications follow committed live events, never replay, history, outgoing or viewed messages" {
    const epoch = "EjRWeBI0EjQSNBI0VniQEg";
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    defer worker.sse.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try worker.store.beginSync(epoch, epoch ++ ":0");
    _ = try worker.store.upsert(
        ar,
        "conversation",
        "{\"id\":\"chat\",\"title\":\"Friends 👋\",\"service\":\"imessage\"}",
    );
    var message = t.Message{
        .id = "first",
        .conversation_id = "chat",
        .sender = "peer",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = "Hello <b>literal</b> & 👋",
        .decoding = .plain,
        .observed_status = .received,
    };
    const frame = try notificationFrame(ar, epoch, 1, "live", message);
    try std.testing.expectError(
        error.InvalidFrame,
        worker.receiveBatch(try std.mem.concat(ar, u8, &.{ frame, "data: invalid\n\n" })),
    );
    try std.testing.expect(worker.takeNotification() == null);
    worker.sse.reset();
    try worker.store.db.exec("CREATE TRIGGER reject_cursor BEFORE UPDATE ON meta WHEN NEW.key='cursor' BEGIN SELECT RAISE(ABORT,'failure'); END");
    try std.testing.expectError(error.DatabaseFailure, worker.receiveBatch(frame));
    try std.testing.expect(worker.takeNotification() == null);
    try worker.store.db.exec("DROP TRIGGER reject_cursor");
    worker.sse.reset();
    try worker.receiveBatch(frame);
    // Replacing snapshots must not consume or duplicate a queued alert.
    try worker.publish();
    try worker.publish();
    const first = worker.takeNotification().?;
    defer first.destroy();
    try std.testing.expectEqualStrings("Friends 👋", first.summary);
    try std.testing.expectEqualStrings("Hello <b>literal</b> & 👋", first.body);
    try std.testing.expectEqualStrings("chat", first.chat);
    try worker.receiveBatch(frame);
    message.revision = "2";
    try worker.receiveBatch(try notificationFrame(ar, epoch, 2, "live", message));
    message.id = "history";
    try worker.receiveBatch(try notificationFrame(ar, epoch, 3, "historical_import", message));
    message.revision = "4";
    try worker.receiveBatch(try notificationFrame(ar, epoch, 4, "live", message));
    message.id = "outgoing";
    message.direction = .outgoing;
    try worker.receiveBatch(try notificationFrame(ar, epoch, 5, "live", message));
    message.id = "viewed";
    message.direction = .incoming;
    worker.viewed = true;
    worker.selected = "chat";
    try worker.receiveBatch(try notificationFrame(ar, epoch, 6, "live", message));
    worker.viewed = false;
    try worker.receiveBatch(try notificationFrame(ar, epoch, 7, "live", message));
    try std.testing.expect(worker.takeNotification() == null);
    // Loading an HTTP history page ahead of a live SSE event must not swallow it.
    message.id = "history-race";
    message.text = null;
    message.kind = .attachment;
    _ = try worker.store.upsert(ar, "message", try u.json(ar, message));
    try worker.receiveBatch(try notificationFrame(ar, epoch, 8, "live", message));
    const attachment = worker.takeNotification().?;
    defer attachment.destroy();
    try std.testing.expectEqualStrings("Attachment", attachment.body);
    try std.testing.expect(worker.takeNotification() == null);
}

fn notificationFrame(
    ar: u.Allocator,
    epoch: []const u8,
    sequence: i64,
    origin: []const u8,
    message: t.Message,
) ![]const u8 {
    const cursor = try t.cursor(ar, epoch, sequence);
    const payload = try u.json(ar, .{
        .cursor = cursor,
        .sequence = try std.fmt.allocPrint(ar, "{d}", .{sequence}),
        .type = "message.upsert",
        .origin = origin,
        .record = message,
    });
    return std.fmt.allocPrint(
        ar,
        "id: {s}\nevent: message.upsert\ndata: {s}\n\n",
        .{ cursor, payload },
    );
}

test "an unresolved submission holds new text until the original ID has an authoritative outcome" {
    const epoch = "EjRWeBI0EjQSNBI0VniQEg";
    var worker = Worker{
        .io = std.testing.io,
        .config = .{ .data = "/tmp/unused" },
        .online = true,
        .reply_existing = true,
    };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try worker.store.beginSync(epoch, epoch ++ ":0");
    const input = t.SendInput{
        .request_id = epoch,
        .server_epoch = epoch,
        .target = .{ .conversation_id = epoch },
        .text = "Original submission",
    };
    try worker.store.persistSend(ar, "chat", input);
    try worker.store.outcome(epoch, "unknown", "Connection interrupted");
    // Even with the stream back online, submitting must not allocate a new UUID
    // or clear the new text before lookup resolves the original submission.
    try worker.push(.{
        .kind = .send,
        .key = "chat",
        .text = "Keep this new draft",
    });
    try worker.drain();
    try std.testing.expectEqual(
        @as(i64, 1),
        try worker.store.db.scalar("SELECT count(*) FROM outbox"),
    );
    try std.testing.expectEqualStrings("Keep this new draft", try worker.store.draft(ar, "chat"));
    try std.testing.expect(try worker.unresolved());
    try worker.handleResponse(ar, .recover, try u.json(ar, t.SendRequest{
        .request_id = epoch,
        .server_epoch = epoch,
        .target = input.target,
        .text = input.text,
        .state = .submitted,
    }));
    try std.testing.expect(!try worker.unresolved());
    try std.testing.expectEqualStrings("Keep this new draft", try worker.store.draft(ar, "chat"));
}

test "history pages preserve wire records and roll back invalid batches" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    try worker.setJobKey("chat");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const raw = "{ \"id\":\"first\",\"revision\":\"1\",\"conversation_id\":\"chat\",\"sender\":\"peer\",\"direction\":\"incoming\",\"service\":\"imessage\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"kind\":\"text\",\"text\":\"é\\ntext\",\"decoding\":\"plain\",\"observed_status\":\"received\",\"future\":1.234567890123456789 }";
    const body = try ar.dupe(u8, "{\"messages\":[" ++ raw ++ "],\"next\":\"more\"}");
    try worker.handleResponse(ar, .history, body);
    @memset(body, 'x');
    const query = try worker.store.db.prepare("SELECT record FROM records WHERE id='first'");
    defer query.close();
    try std.testing.expect(try query.step());
    try std.testing.expectEqualStrings(raw, query.bytes(0));
    const valid = try std.json.parseFromSliceLeaky(t.Message, ar, raw, .{ .ignore_unknown_fields = true });
    var second = valid;
    second.id = "second";
    var invalid = valid;
    invalid.id = "invalid";
    invalid.text = "bad\x00text";
    const rejected = try u.json(ar, .{ .messages = &.{ second, invalid }, .next = @as(?[]const u8, null) });
    try std.testing.expectError(error.InvalidRecord, worker.handleResponse(ar, .history, rejected));
    try std.testing.expectEqual(@as(i64, 1), try worker.store.db.scalar("SELECT count(*) FROM records"));
    try std.testing.expectEqualStrings("more", (try worker.store.nextPage(ar, "chat")).?);
}
