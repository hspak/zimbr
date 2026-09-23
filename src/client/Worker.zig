const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol/types.zig");
const c = @import("c.zig").api;
const Config = @import("Config.zig");
const Store = @import("Store.zig");
const Sse = @import("Sse.zig");
const Self = @This();
const SharedSnapshot = @import("SharedSnapshot.zig");
const a = std.heap.page_allocator;
pub const Command = struct { kind: enum { select, draft, send, older, reconnect, check, viewed, appearance }, key: []const u8 = "", text: []const u8 = "", recipient: []const u8 = "" };
pub const RelayStatus = struct {
    api_version: []const u8,
    server_epoch: []const u8,
    adapter_ready: bool,
    capabilities: struct {
        send_direct: bool,
        reply_existing: bool,
        read_history: bool = false,
        live_messages: bool = false,
        attachments: bool = false,
        group_creation: bool = false,
    },
    degraded_reasons: []const []const u8,
};
pub const Diagnostics = struct {
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
    send_direct: bool,
    reply_existing: bool,
    generation: u64,
    ack: u64,
    loading_history: bool = false,
    redirect_from: []const u8 = "",
    dark_mode: bool = false,
    diagnostics: Diagnostics = .{},
    shared: ?*SharedSnapshot = null,
    content_generation: ?u64 = null,
    pub fn destroy(v: *View) void {
        if (v.shared) |shared| shared.release();
        v.arena.deinit();
        a.destroy(v);
    }
};
io: std.Io,
config: Config,
mutex: std.Io.Mutex = .init,
commands: std.ArrayList(Command) = .empty,
view: ?*View = null,
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
dirty: bool = true,
content_dirty: bool = true,
shared: ?*SharedSnapshot = null,
content_generation: u64 = 0,
generation: u64 = 0,
ack: u64 = 0,
job: enum { idle, status, sync, chats, history, preview, send, recover } = .idle,
job_key: []const u8 = "",
preview_at: i64 = 0,
recover_row: i64 = 0,
need_history: bool = false,
older: bool = false,
job_older: bool = false,
need_sync: bool = false,
stream_active: bool = false,
retry_at: i64 = 0,
backoff: i64 = 1000,
status_at: i64 = 0,
recovery_at: i64 = 0,
auth_blocked: bool = false,
last_published: i64 = 0,
last_status_ms: i64 = 0,
last_event_ms: i64 = 0,
last_response_ms: i64 = 0,
last_http_status: i64 = 0,
pub fn start(s: *Self) !void {
    if (u.c.pipe(&s.wake_pipe) != 0) return error.WorkerWakeUnavailable;
    errdefer {
        for (s.wake_pipe) |fd| _ = u.c.close(fd);
        s.wake_pipe = .{ -1, -1 };
    }
    for (s.wake_pipe) |fd| {
        if (u.c.fcntl(fd, u.c.F_SETFL, @as(c_int, u.c.O_NONBLOCK)) < 0 or u.c.fcntl(fd, u.c.F_SETFD, @as(c_int, u.c.FD_CLOEXEC)) < 0) return error.WorkerWakeUnavailable;
    }
    s.thread = try std.Thread.spawn(.{}, run, .{s});
}
fn wake(s: *Self) void {
    if (s.wake_pipe[1] >= 0) _ = u.c.write(s.wake_pipe[1], "x", 1);
}
pub fn shutdown(s: *Self) void {
    s.stop.store(true, .release);
    s.wake();
    if (s.thread) |th| th.join();
    for (s.wake_pipe) |fd| if (fd >= 0) {
        _ = u.c.close(fd);
    };
    s.wake_pipe = .{ -1, -1 };
    if (s.view) |v| v.destroy();
    if (s.shared) |shared| shared.release();
    for (s.commands.items) |cmd| freeCommand(cmd);
    s.commands.deinit(a);
}
pub fn push(s: *Self, cmd: Command) !void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.commands.items.len >= 64) return error.Busy;
    const key = try a.dupe(u8, cmd.key);
    errdefer a.free(key);
    const text = try a.dupe(u8, cmd.text);
    errdefer a.free(text);
    const recipient = try a.dupe(u8, cmd.recipient);
    errdefer a.free(recipient);
    try s.commands.append(a, .{ .kind = cmd.kind, .key = key, .text = text, .recipient = recipient });
    s.wake();
}
fn freeCommand(cmd: Command) void {
    a.free(cmd.key);
    a.free(cmd.text);
    a.free(cmd.recipient);
}
pub fn take(s: *Self) ?*View {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const v = s.view;
    s.view = null;
    return v;
}
fn run(s: *Self) void {
    s.work() catch |err| {
        std.log.err("client worker: {s}", .{@errorName(err)});
        s.status = "Client cache unavailable. Check the data directory and restart.";
        s.online = false;
        const v = a.create(View) catch return;
        v.* = .{ .arena = std.heap.ArenaAllocator.init(a), .snapshot = .{ .chats = &.{}, .messages = &.{}, .pending = &.{}, .selected = "", .draft = "", .epoch = "", .more = false }, .status = if (err == error.ClientAlreadyRunning) "This cache is already open in another Zimbr window." else s.status, .online = false, .send_direct = false, .reply_existing = false, .generation = s.generation + 1, .ack = s.ack };
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.view) |old| old.destroy();
        s.view = v;
    };
}
fn work(s: *Self) !void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{s.config.data}, 0);
    defer a.free(path);
    const lockpath = try std.fmt.allocPrintSentinel(a, "{s}/client.lock", .{s.config.data}, 0);
    defer a.free(lockpath);
    const lock = u.c.zr_lock(lockpath);
    if (lock < 0) return error.ClientAlreadyRunning;
    defer _ = u.c.close(lock);
    // Own the cache before running schema migrations or opening a writer.
    s.store = try Store.open(path);
    defer s.store.close();
    s.selected = try s.store.get(a, "selected");
    {
        const stamp = try s.store.get(a, "server_checked_at");
        defer a.free(stamp);
        s.last_status_ms = std.fmt.parseInt(i64, stamp, 10) catch 0;
    }
    defer if (s.selected.len > 0) a.free(s.selected);
    defer {
        if (s.net) |n| c.zc_net_free(n);
        s.sse.deinit();
        a.free(s.job_key);
        a.free(s.redirect_from);
    }
    try s.publish();
    while (true) {
        try s.drain();
        try s.resolveDirect();
        if (s.stop.load(.acquire)) break;
        if (s.net == null and !s.auth_blocked) try s.connect();
        if (s.net) |n| {
            if (c.zc_net_poll(n) == 0) return error.TransportFailure;
            if (c.zc_net_done(n, 0) != 0) try s.complete();
            if (c.zc_net_done(n, 1) != 0) {
                const status = c.zc_net_status(n, 1);
                c.zc_net_ack(n, 1);
                s.stream_active = false;
                s.sse.deinit();
                if (status == 409 or status == 410) {
                    s.need_sync = true;
                    s.status = "Refreshing expired history…";
                    s.online = false;
                    s.retry_at = 0;
                } else s.disconnected(status);
            }
            if (s.stream_active and !s.online and c.zc_net_status(n, 1) == 200) {
                s.online = true;
                s.backoff = 1000;
                s.status = if (s.send_direct or s.reply_existing) "Connected" else "Connected · relay cannot send; run relay doctor on the Mac";
                s.dirty = true;
            }
            if (s.job == .idle and !s.auth_blocked and u.now() >= s.retry_at) try s.schedule();
        }
        if (s.dirty and u.now() - s.last_published >= 16) try s.publish();
        // Network activity and commands wake immediately; timers only bound
        // publication coalescing and maintenance, rather than every request.
        const now = u.now();
        var delay: i64 = if (s.dirty) @max(0, 16 - (now - s.last_published)) else 1000;
        if (!s.auth_blocked and s.job == .idle) {
            if (!s.online and !s.stream_active) delay = @min(delay, @max(0, s.retry_at - now));
            if (s.online) delay = @min(delay, @max(0, @min(s.status_at, @min(s.recovery_at, s.preview_at)) - now));
        }
        if (c.zc_net_wait(s.net, s.wake_pipe[0], @intCast(delay)) == 0) return error.TransportFailure;
    }
}
fn connect(s: *Self) !void {
    var token: [67]u8 = undefined;
    const len = u.c.zr_read_secret(s.config.token_path, &token, 66);
    if (len < 0) {
        s.status = "Setup needed · token file missing or not private (chmod 600). Then Reconnect.";
        s.auth_blocked = true;
        s.dirty = true;
        return;
    }
    const value = std.mem.trim(u8, token[0..@intCast(len)], "\r\n");
    if (value.len != 64) {
        s.status = "Setup needed · invalid relay token file. Then Reconnect.";
        s.auth_blocked = true;
        s.dirty = true;
        return;
    }
    for (value) |ch| if (!std.ascii.isHex(ch)) {
        s.auth_blocked = true;
        s.status = "Setup needed · invalid relay token file.";
        s.dirty = true;
        return;
    };
    token[64] = 0;
    defer @memset(&token, 0);
    s.net = c.zc_net_new(&token, s.config.port, receive, s) orelse return error.TransportUnavailable;
    s.status = "Connecting to relay…";
    s.retry_at = 0;
    s.dirty = true;
}
fn receive(ctx: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) c_int {
    const s: *Self = @ptrCast(@alignCast(ctx.?));
    s.receiveBatch(bytes[0..len]) catch {
        s.status = "Invalid event stream · reconnecting from saved progress";
        s.dirty = true;
        return 0;
    };
    return 1;
}
fn receiveBatch(s: *Self, bytes: []const u8) !void {
    // Commit complete frames from one network delivery together. A malformed
    // frame or failed commit rolls back records, unread state, and cursor;
    // reconnect replays from the last durable cursor.
    try s.store.db.exec("BEGIN IMMEDIATE");
    errdefer s.store.db.exec("ROLLBACK") catch {};
    try s.sse.feed(bytes, s, event);
    try s.store.db.exec("COMMIT");
}
fn event(s: *Self, arena: u.Allocator, raw: []const u8, id: []const u8, kind: []const u8) !void {
    try s.store.event(arena, raw, id, kind, if (s.viewed) s.selected else "");
    s.last_event_ms = u.now();
    s.dirty = true;
    s.content_dirty = true;
}
fn request(s: *Self, job: @FieldType(Self, "job"), path: []const u8, body: ?[]const u8) !void {
    const url = try a.dupeZ(u8, path);
    defer a.free(url);
    const data = if (body) |b| try a.dupeZ(u8, b) else null;
    defer if (data) |d| a.free(d);
    if (c.zc_net_start(s.net.?, 0, url, if (data) |d| d.ptr else null) == 0) return error.TransportFailure;
    s.job = job;
    s.dirty = true;
}
fn setJobKey(s: *Self, key: []const u8) !void {
    a.free(s.job_key);
    s.job_key = try a.dupe(u8, key);
}
fn disconnected(s: *Self, status: c_long) void {
    s.online = false;
    s.dirty = true;
    if (status == 401) {
        s.auth_blocked = true;
        s.status = "Authentication rejected · update the token file, then Reconnect";
    } else {
        s.status = "Offline · cached messages and drafts available. Check the SSH tunnel.";
        s.retry_at = u.now() + s.backoff + @mod(u.now(), 251);
        s.backoff = @min(s.backoff * 2, 30000);
    }
    if (s.stream_active) {
        c.zc_net_cancel_stream(s.net.?);
        s.stream_active = false;
        s.sse.deinit();
    }
}
fn schedule(s: *Self) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    if (!s.online) {
        if (s.stream_active) return;
        if (s.need_sync) {
            s.need_sync = false;
            try s.request(.sync, "/v1/sync", null);
        } else try s.request(.status, "/v1/status", null);
    } else if (s.need_history and s.selected.len > 0 and !std.mem.startsWith(u8, s.selected, "new:")) {
        s.need_history = false;
        try s.setJobKey(s.selected);
        s.job_older = s.older;
        const next = if (s.older) try s.store.nextPage(ar, s.selected) else @as(?[]const u8, "");
        s.older = false;
        if (next) |cursor| try s.request(.history, try std.fmt.allocPrint(ar, "/v1/conversations/{s}/messages?limit=100{s}{s}", .{ s.selected, if (cursor.len > 0) "&before=" else "", try encode(ar, cursor) }), null);
    } else if (u.now() >= s.status_at) {
        try s.request(.status, "/v1/status", null);
    } else if (u.now() >= s.recovery_at) {
        s.recovery_at = u.now() + 5000;
        var q = try s.store.db.prepare("SELECT id,rowid FROM outbox WHERE epoch=? AND state IN ('sending','unknown','queued','dispatching','submitted') AND rowid>? ORDER BY rowid LIMIT 1");
        defer q.close();
        try q.bind(&.{ .{ .text = try s.store.get(ar, "epoch") }, .{ .int = s.recover_row } });
        if (try q.step()) {
            s.recover_row = q.int(1);
            try s.setJobKey(q.bytes(0));
            try s.request(.recover, try std.fmt.allocPrint(ar, "/v1/send-requests/{s}", .{s.job_key}), null);
        } else s.recover_row = 0;
    } else if (u.now() >= s.preview_at) {
        s.preview_at = u.now() + 100;
        var q = try s.store.db.prepare("SELECT c.id FROM records c WHERE c.kind='conversation' AND NOT EXISTS(SELECT 1 FROM records m WHERE m.kind='message' AND m.chat=c.id) AND NOT EXISTS(SELECT 1 FROM previews p WHERE p.chat=c.id) ORDER BY c.sort_key DESC LIMIT 1");
        defer q.close();
        if (try q.step()) {
            try s.setJobKey(q.bytes(0));
            try s.request(.preview, try std.fmt.allocPrint(ar, "/v1/conversations/{s}/messages?limit=1", .{s.job_key}), null);
        } else s.preview_at = u.now() + 30000;
    }
}
fn attach(s: *Self, ar: u.Allocator) !void {
    if (s.stream_active) return;
    const cursor = try s.store.get(ar, "cursor");
    const path = try std.fmt.allocPrintSentinel(ar, "/v1/events?after={s}", .{try encode(ar, cursor)}, 0);
    if (c.zc_net_start(s.net.?, 1, path, null) == 0) return error.TransportFailure;
    s.stream_active = true;
    s.status = "Synchronizing live messages…";
    s.dirty = true;
}
fn complete(s: *Self) !void {
    const n = s.net.?;
    const status = c.zc_net_status(n, 0);
    s.last_http_status = status;
    s.last_response_ms = u.now();
    var len: usize = 0;
    const ptr = c.zc_net_body(n, &len);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const raw = try ar.dupe(u8, if (ptr == null) "" else ptr[0..len]);
    c.zc_net_ack(n, 0);
    const job = s.job;
    s.job = .idle;
    if (job != .status) s.content_dirty = true;
    if (status < 200 or status >= 300) {
        if (job == .history and u.eq(s.job_key, s.selected)) {
            s.need_history = true;
            s.older = s.job_older;
        }
        if (job == .send) {
            // Transport failures and server errors may follow durable acceptance.
            const definite = status == 400 or status == 401 or status == 409 or status == 413;
            try s.store.outcome(s.job_key, if (definite) "failed" else "unknown", if (definite) "Relay rejected this submission. Copy it to the composer to edit." else "Outcome uncertain. Checking the original request ID; no automatic resend.");
        } else if (job == .recover and status == 404) {
            try s.store.outcome(s.job_key, "unconfirmed", "The relay has no record of this request. It will not be resent automatically.");
            s.dirty = true;
            return;
        }
        if (status == 409 or status == 410) {
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
    s.handleResponse(ar, job, raw) catch |err| {
        std.log.warn("client response: {s}", .{@errorName(err)});
        if (job == .history and u.eq(s.job_key, s.selected)) {
            s.need_history = true;
            s.older = s.job_older;
        }
        if (job == .send) try s.store.outcome(s.job_key, "unknown", "Response interrupted. Checking the original request ID; no automatic resend.");
        s.disconnected(0);
        s.status = "Invalid relay response · saved messages remain available";
    };
    s.dirty = true;
}
fn handleResponse(s: *Self, ar: u.Allocator, job: @FieldType(Self, "job"), raw: []const u8) !void {
    switch (job) {
        .status => {
            const v = (try std.json.parseFromSlice(RelayStatus, ar, raw, .{ .ignore_unknown_fields = true })).value;
            // Persist only the documented status fields, never credentials or
            // arbitrary HTTP response headers, for offline diagnostics.
            try s.store.set("relay_status", try u.json(ar, v));
            s.last_status_ms = u.now();
            try s.store.set("server_checked_at", try std.fmt.allocPrint(ar, "{d}", .{s.last_status_ms}));
            if (!u.eq(v.api_version, "1")) {
                s.auth_blocked = true;
                s.online = false;
                s.status = "Unsupported relay API version";
                return;
            }
            s.send_direct = v.capabilities.send_direct;
            s.reply_existing = v.capabilities.reply_existing;
            s.status_at = u.now() + 15000;
            if (!u.eq(v.server_epoch, try s.store.get(ar, "epoch")) or !u.eq(try s.store.get(ar, "bootstrapped"), "1")) {
                if (s.stream_active) {
                    c.zc_net_cancel_stream(s.net.?);
                    s.stream_active = false;
                    s.sse.deinit();
                }
                s.online = false;
                try s.request(.sync, "/v1/sync", null);
            } else {
                try s.attach(ar);
                if (s.online) s.status = if (!v.adapter_ready) "Relay reachable · Messages unavailable; run relay doctor on the Mac" else if (!s.send_direct and !s.reply_existing) "Connected · sending unavailable; check Messages Automation permission" else "Connected";
            }
        },
        .sync => {
            const v = (try std.json.parseFromSlice(struct { server_epoch: []const u8, cursor: []const u8 }, ar, raw, .{ .ignore_unknown_fields = true })).value;
            try s.store.beginSync(v.server_epoch, v.cursor);
            s.status = "Downloading conversations…";
            try s.request(.chats, "/v1/conversations?limit=200&previews=1", null);
        },
        .chats => {
            const v = (try std.json.parseFromSlice(struct { conversations: []const std.json.Value, next: ?[]const u8, previews: ?[]const std.json.Value = null }, ar, raw, .{ .ignore_unknown_fields = true })).value;
            try s.store.db.exec("BEGIN IMMEDIATE");
            errdefer s.store.db.exec("ROLLBACK") catch {};
            for (v.conversations) |chat| _ = try s.store.upsert(ar, "conversation", try u.json(ar, chat));
            if (v.previews) |previews| {
                for (previews) |preview| try s.store.savePreview(ar, try u.json(ar, preview));
                // An empty chat was also covered by this page. Older relays
                // omit projections and keep the existing preview fallback.
                for (v.conversations) |chat| try s.store.exec("INSERT OR IGNORE INTO previews(chat) VALUES(?)", &.{.{ .text = chat.object.get("id").?.string }});
            }
            try s.store.db.exec("COMMIT");
            if (v.next) |next| try s.request(.chats, try std.fmt.allocPrint(ar, "/v1/conversations?limit=200&previews=1&before={s}", .{try encode(ar, next)}), null) else {
                try s.store.set("bootstrapped", "1");
                s.need_history = true;
                try s.attach(ar);
            }
        },
        .history, .preview => {
            const v = (try std.json.parseFromSlice(struct { messages: []const std.json.Value, next: ?[]const u8 }, ar, raw, .{ .ignore_unknown_fields = true })).value;
            try s.store.db.exec("BEGIN IMMEDIATE");
            errdefer s.store.db.exec("ROLLBACK") catch {};
            for (v.messages) |message| _ = try s.store.upsert(ar, "message", try u.json(ar, message));
            if (job == .history) try s.store.page(s.job_key, v.next) else try s.store.exec("INSERT OR IGNORE INTO previews(chat) VALUES(?)", &.{.{ .text = s.job_key }});
            try s.store.db.exec("COMMIT");
        },
        .send, .recover => {
            _ = try s.store.upsert(ar, "request", raw);
            s.recovery_at = u.now() + 1000;
        },
        .idle => {},
    }
}
fn drain(s: *Self) !void {
    // A send can preempt an idempotent background GET. A POST is never
    // cancelled or repeated here: its result must remain authoritative.
    while (true) {
        s.mutex.lockUncancelable(s.io);
        if (s.commands.items.len == 0) {
            s.mutex.unlock(s.io);
            break;
        }
        if (s.commands.items[0].kind == .send and s.job != .idle and !s.stop.load(.acquire)) {
            if (s.online and (s.job == .history or s.job == .preview or s.job == .status or s.job == .recover)) {
                switch (s.job) {
                    .history => {
                        s.need_history = true;
                        s.older = s.job_older;
                    },
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
        switch (cmd.kind) {
            .appearance => {
                if (u.eq(cmd.text, "dark") or u.eq(cmd.text, "light")) try s.store.set("theme", cmd.text);
            },
            .select => {
                s.content_dirty = true;
                a.free(s.redirect_from);
                s.redirect_from = "";
                if (s.selected.len > 0) a.free(s.selected);
                s.selected = try a.dupe(u8, cmd.key);
                s.viewed = true;
                try s.store.set("selected", cmd.key);
                try s.store.read(cmd.key);
                s.need_history = true;
            },
            .draft => {
                try s.store.saveDraft(cmd.key, cmd.text);
                // Draft-only entries can appear/disappear in the sidebar;
                // normal conversation drafts do not alter any cached records.
                var q = try s.store.db.prepare("SELECT 1 FROM records WHERE kind='conversation' AND id=?");
                defer q.close();
                try q.bind(&.{.{ .text = cmd.key }});
                if (!try q.step()) s.content_dirty = true;
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
                s.auth_blocked = false;
                s.retry_at = 0;
                s.backoff = 1000;
                s.status_at = 0;
                s.online = false;
                if (s.net) |n| {
                    c.zc_net_free(n);
                    s.net = null;
                    s.job = .idle;
                    s.stream_active = false;
                    s.sse.deinit();
                }
            },
            .check => {
                s.recovery_at = 0;
            },
            .send => {
                s.content_dirty = true;
                if (!s.online or s.stop.load(.acquire)) {
                    try s.store.saveDraft(cmd.key, cmd.text);
                    s.status = "Offline · message kept as a draft";
                } else {
                    const direct = std.mem.startsWith(u8, cmd.key, "new:");
                    if ((direct and !s.send_direct) or (!direct and !s.reply_existing)) {
                        s.status = "Sending unavailable · message kept as a draft";
                        try s.store.saveDraft(cmd.key, cmd.text);
                    } else {
                        const input = t.SendInput{ .request_id = try u.id(ar), .server_epoch = try s.store.get(ar, "epoch"), .target = if (direct) .{ .recipient = .{ .address = cmd.recipient, .service = "imessage" } } else .{ .conversation_id = cmd.key }, .text = cmd.text };
                        try s.store.persistSend(ar, cmd.key, input);
                        try s.setJobKey(input.request_id);
                        try s.request(.send, "/v1/messages", try u.json(ar, input));
                    }
                }
                s.ack += 1;
            },
        }
        s.dirty = true;
    }
}
fn resolveDirect(s: *Self) !void {
    if (!std.mem.startsWith(u8, s.selected, "new:")) return;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    if ((try s.store.draft(ar, s.selected)).len > 0) return;
    var q = try s.store.db.prepare("SELECT m.chat FROM outbox o JOIN records m ON m.kind='message' AND m.id=json_extract(o.record,'$.message_id') WHERE o.draft_key=? AND o.epoch=? LIMIT 1");
    defer q.close();
    try q.bind(&.{ .{ .text = s.selected }, .{ .text = try s.store.get(ar, "epoch") } });
    if (!try q.step()) return;
    const chat = try q.text(ar, 0);
    try s.store.exec("UPDATE outbox SET draft_key=? WHERE draft_key=?", &.{ .{ .text = chat }, .{ .text = s.selected } });
    try s.store.set("selected", chat);
    a.free(s.redirect_from);
    s.redirect_from = try a.dupe(u8, s.selected);
    a.free(s.selected);
    s.selected = try a.dupe(u8, chat);
    s.need_history = true;
    s.dirty = true;
    s.content_dirty = true;
}
fn publish(s: *Self) !void {
    if (s.content_dirty or s.shared == null) {
        const shared = try SharedSnapshot.create(s.store, s.selected, s.content_generation + 1, s.shared);
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
    v.* = .{ .arena = arena, .snapshot = shared.snapshot, .shared = shared, .content_generation = shared.generation, .status = try arena.allocator().dupe(u8, s.status), .online = s.online, .send_direct = s.send_direct, .reply_existing = s.reply_existing, .generation = s.generation, .ack = s.ack, .loading_history = s.need_history or s.job == .history, .redirect_from = try arena.allocator().dupe(u8, s.redirect_from) };
    const ar = arena.allocator();
    v.snapshot.draft = try s.store.draft(ar, s.selected);
    v.dark_mode = u.eq(try s.store.get(ar, "theme"), "dark");
    const server = try s.store.get(ar, "relay_status");
    v.diagnostics = .{
        .server = if (server.len > 0) (try std.json.parseFromSlice(RelayStatus, ar, server, .{ .ignore_unknown_fields = true })).value else null,
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
    // Arena state changes during snapshot construction: retain the final state.
    v.arena = arena;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.view) |old| old.destroy();
    s.view = v;
    s.dirty = false;
    s.last_published = u.now();
}
pub fn encode(ar: u.Allocator, raw: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (raw) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-_.~", ch) != null) try result.append(ar, ch) else try result.appendSlice(ar, &.{ '%', hex[ch >> 4], hex[ch & 15] });
    }
    return result.items;
}

test "metadata views share immutable history while edited records replace it" {
    var worker = Self{ .io = std.testing.io, .config = .{ .data = "/tmp/unused", .token_path = "/tmp/unused/token" } };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    worker.selected = "chat";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    _ = try worker.store.upsert(ar, "conversation", "{\"id\":\"chat\",\"service\":\"imessage\"}");
    var message = t.Message{ .id = "message", .conversation_id = "chat", .sender = "peer", .direction = .incoming, .service = "imessage", .timestamp = "2026-01-01T00:00:00Z", .kind = .text, .text = "Original", .decoding = .plain, .observed_status = .received };
    _ = try worker.store.upsert(ar, "message", try u.json(ar, message));
    try worker.publish();
    const first = worker.take().?;
    defer first.destroy();
    try worker.push(.{ .kind = .draft, .key = "chat", .text = "New draft" });
    try worker.drain();
    try worker.publish();
    const metadata = worker.take().?;
    defer metadata.destroy();
    try std.testing.expectEqual(first.shared, metadata.shared);
    try std.testing.expectEqual(first.content_generation, metadata.content_generation);
    try std.testing.expectEqualStrings("New draft", metadata.snapshot.draft);
    try std.testing.expectEqualStrings("", first.snapshot.draft);
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

test "an invalid frame rolls back the complete network batch for safe replay" {
    const epoch = "12345678-1234-1234-1234-123456789012";
    var worker = Self{ .io = std.testing.io, .config = .{ .data = "/tmp/unused", .token_path = "/tmp/unused/token" } };
    worker.store = try Store.open(":memory:");
    defer worker.store.close();
    defer worker.shutdown();
    defer worker.sse.deinit();
    try worker.store.beginSync(epoch, epoch ++ ":0");
    const frame = "id: " ++ epoch ++ ":1\nevent: conversation.upsert\ndata: {\"cursor\":\"" ++ epoch ++ ":1\",\"sequence\":\"1\",\"type\":\"conversation.upsert\",\"origin\":\"live\",\"record\":{\"id\":\"chat\",\"service\":\"imessage\"}}\n\n";
    try std.testing.expectError(error.InvalidFrame, worker.receiveBatch(frame ++ "data: invalid\n\n"));
    try std.testing.expectEqual(@as(i64, 0), try worker.store.db.scalar("SELECT count(*) FROM records"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(epoch ++ ":0", try worker.store.get(arena.allocator(), "cursor"));
    worker.sse.deinit();
    try worker.store.db.exec("CREATE TRIGGER reject_cursor BEFORE UPDATE ON meta WHEN NEW.key='cursor' BEGIN SELECT RAISE(ABORT,'failure'); END");
    try std.testing.expectError(error.DatabaseFailure, worker.receiveBatch(frame));
    try std.testing.expectEqual(@as(i64, 0), try worker.store.db.scalar("SELECT count(*) FROM records"));
    try std.testing.expectEqualStrings(epoch ++ ":0", try worker.store.get(arena.allocator(), "cursor"));
    try worker.store.db.exec("DROP TRIGGER reject_cursor");
    worker.sse.deinit();
    try worker.receiveBatch(frame);
    try std.testing.expectEqual(@as(i64, 1), try worker.store.db.scalar("SELECT count(*) FROM records"));
    try std.testing.expectEqualStrings(epoch ++ ":1", try worker.store.get(arena.allocator(), "cursor"));
}
