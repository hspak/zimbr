const std = @import("std");
const contacts = @import("adapter/contacts.zig");
const Assets = @import("Assets.zig");
const Mutex = @import("Mutex.zig");
const fake_adapter = @import("adapter/fake.zig");
const options = @import("options");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const Journal = @import("Journal.zig");
const reactions = @import("reactions.zig");
const Signal = @import("../Signal.zig");
const log = std.log.scoped(.relay_core);
const adapter_api = if (options.fake) fake_adapter else @import("adapter/macos.zig");
const fake = options.fake;
const observation_window_ms = 10000;
const Core = @This();

io: std.Io,
journal: Journal,
source_path: [:0]const u8,
contacts_phone_region: []const u8 = "",
contacts_status: contacts.Status = .{},
source_features: adapter_api.Source.Features = .{},
assets_service: ?Assets = null,
assets_reason: []const u8 = "starting",
mutex: Mutex = .init,
read_ready: bool = false,
automation_ready: bool = fake,
automation_error: []const u8 = "automation_unverified",
degraded: []const u8 = "starting",
last_scan_ms: i64 = 0,
stop: std.atomic.Value(bool) = .init(false),
connections: std.atomic.Value(usize) = .init(0),
streams: std.atomic.Value(usize) = .init(0),
event_limit: i64 = 100000,
changed: Signal = .{},
send_ready: Signal = .{},
ingest_pending: bool = false,

pub const IngestError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    AmbiguousSourceIdentity,
    InvalidRequest,
    InvalidTimestamp,
    Malformed,
    MetadataItemTooLarge,
    NotFound,
    Oversized,
    RandomUnavailable,
    Unsupported,
    WriteFailed,
};

pub fn lock(self: *Core) void {
    self.mutex.lockUncancelable(self.io);
}
pub fn unlock(self: *Core) void {
    self.mutex.unlock(self.io);
}
pub fn sleep(self: *Core, ms: i64) void {
    std.Io.sleep(self.io, .fromMilliseconds(ms), .awake) catch {};
}
pub fn ingestLoop(self: *Core) void {
    u.c.zr_thread_qos(0);
    var tick: usize = 0;
    const watch = u.c.zr_watch_open(self.source_path);
    defer u.c.zr_watch_close(watch);
    var settle = false;
    var maintenance: i64 = 0;
    while (!self.stop.load(.acquire)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.lock();
        const was_ready = self.read_ready;
        const started = u.c.zr_monotonic_ms();
        self.ingest(arena.allocator()) catch |err| {
            self.read_ready = false;
            self.degraded = switch (err) {
                error.SchemaUnsupported => "schema_unsupported",
                error.DatabaseBusy => "database_busy",
                error.DatabaseUnavailable => "database_access_required",
                else => "persistence_or_source_failure",
            };
        };
        if (was_ready != self.read_ready or tick % 60 == 0) {
            const count = self.journal.db.scalar("SELECT count(*) FROM messages") catch 0;
            log.info("ingestion ready={} code={s} duration_ms={d} records={d}", .{
                self.read_ready,
                self.degraded,
                u.c.zr_monotonic_ms() - started,
                count,
            });
        }
        if (u.now() >= maintenance) {
            self.journal.prune(self.event_limit) catch {};
            maintenance = u.now() + 60000;
        }
        const pending = self.read_ready and self.ingest_pending;
        self.unlock();
        arena.deinit();
        tick += 1;
        // Drain bounded backfill/live pages promptly. Notifications may precede
        // SQLite's commit, so take one short settling pass, then keep the full
        // periodic scan as recovery for missed/coalesced filesystem events.
        const changed = u.c.zr_watch_wait(watch, if (pending) 1 else if (settle) 50 else 1000) != 0;
        settle = changed;
    }
}
pub fn ingest(self: *Core, a: u.Allocator) IngestError!void {
    var source = try adapter_api.open(a, self.source_path);
    defer source.close();
    self.source_features = source.features;
    try source.db.exec("BEGIN");
    defer source.db.exec("ROLLBACK") catch {};
    var batch = ImportBatch{ .source = source };
    defer batch.scratch.deinit();
    const high = try source.high();
    const j = self.journal;
    try j.begin();
    errdefer j.rollback();
    const stored_identity = try j.progress(a, "identity");
    var live = try j.position(a, "live");
    var reset = false;
    if (stored_identity) |identity| {
        const legacy_candidate = !u.eq(identity, source.identity) and live > 0 and source.legacyIdentityCandidate(identity);
        reset = !u.eq(identity, source.identity) and !legacy_candidate;
        const anchors = if (!reset) try reactions.anchorsMatch(a, j, source) else 0;
        if (!reset and anchors == 0 and try j.db.scalar("SELECT count(*) FROM ordinary_anchors") > 0) reset = true;
        if (!reset and live > 0) {
            const current = try source.guid(a, live);
            const saved = try j.progress(a, "anchor");
            const missing = high < live or current == null or saved == null or saved.?.len == 0 or !u.eq(
                current.?,
                saved.?,
            );
            if (missing) {
                if (!legacy_candidate and anchors >= 2 and saved != null and try reactions.deletedAnchor(
                    j,
                    source,
                    live,
                    saved.?,
                )) {
                    const anchor = try j.db.prepare("SELECT coalesce(max(source_row),0) FROM ordinary_anchors WHERE source_row<?");
                    defer anchor.close();
                    try anchor.bind(&.{.{ .int = live }});
                    _ = try anchor.step();
                    live = anchor.int(0);
                    batch.rebased = true;
                    try j.setPosition(a, "live", live);
                    try j.setPosition(a, "rolling", 0);
                } else reset = true;
            }
        }
        if (reset) {
            try j.reset(a);
            live = 0;
        } else if (legacy_candidate) {
            try j.setProgress("identity", source.identity);
        }
    }
    if (stored_identity == null or reset) {
        live = high;
        try j.setProgress("identity", source.identity);
        try j.setPosition(a, "live", live);
        try j.setPosition(a, "backfill", high);
        try j.setProgress("anchor", (try source.guid(a, high)) orelse "");
    }
    var backfill = try j.position(a, "backfill");
    const complete = backfill == 0;
    const chat_after = try j.position(a, "chats");
    const chats = try source.chatRows(a, chat_after);
    for (chats) |row| {
        _ = try self.importChat(a, &batch, row, "reconciliation", complete);
    }
    try j.setPosition(a, "chats", if (chats.len == 0) 0 else chats[chats.len - 1]);
    const live_rows = try source.rowsFor(a, .live, live, 0);
    for (live_rows) |row| {
        try self.importRow(a, &batch, row, "live", complete);
        live = row;
    }
    try j.setPosition(a, "live", live);
    try j.setProgress("anchor", (try source.guid(a, live)) orelse "");
    if (backfill > 0) {
        const old = try source.rowsFor(a, .backfill, backfill, 0);
        for (old) |row| try self.importRow(a, &batch, row, "historical_import", false);
        backfill = if (old.len == 0) 0 else old[old.len - 1] - 1;
        try j.setPosition(a, "backfill", backfill);
    }
    // Retry unresolved source rows independently of insertion progress, fairly.
    const pending = try j.db.prepare("SELECT source_row FROM pending_source ORDER BY attempt_ms,source_row LIMIT 50");
    defer pending.close();
    var pending_rows: std.ArrayList(i64) = .empty;
    while (try pending.step()) try pending_rows.append(a, pending.int(0));
    for (pending_rows.items) |row| try self.importRow(a, &batch, row, "reconciliation", complete);
    for (try source.rowsFor(a, .recent, high, 0)) |row| try self.importRow(
        a,
        &batch,
        row,
        "reconciliation",
        complete,
    );
    const rolling = try j.position(a, "rolling");
    const older = try source.rowsFor(a, .rolling, rolling, 0);
    for (older) |row| try self.importRow(a, &batch, row, "reconciliation", complete);
    try j.setPosition(a, "rolling", if (older.len == 0) 0 else older[older.len - 1]);
    // History requests schedule bounded reconciliation, serviced alongside live scans.
    const rq = try j.db.prepare("SELECT r.conversation_id,r.after_row,c.source_row FROM reconcile_chats r JOIN conversations c ON c.id=r.conversation_id ORDER BY r.rowid LIMIT 1");
    defer rq.close();
    if (try rq.step()) {
        const cid = try rq.text(a, 0);
        const rows = try source.rowsFor(a, .chat, rq.int(1), rq.int(2));
        for (rows) |row| try self.importRow(a, &batch, row, "reconciliation", complete);
        if (rows.len == 0) try j.execute(
            "DELETE FROM reconcile_chats WHERE conversation_id=?",
            &.{.{ .text = cid }},
        ) else try j.execute(
            "UPDATE reconcile_chats SET after_row=? WHERE conversation_id=?",
            &.{ .{ .int = rows[rows.len - 1] }, .{ .text = cid } },
        );
    }
    try self.reconcile(a, &batch, complete);
    // Existing journals receive a distinct resumable enrichment pass. Recent
    // and requested chats above remain prioritized while this drains.
    const enrichment_backfill = (try j.progress(a, "enrichment_backfill_v1")) orelse "0";
    if (!u.eq(enrichment_backfill, "complete")) {
        const position = std.fmt.parseInt(i64, enrichment_backfill, 10) catch 0;
        const rows = try source.rowsFor(a, .rolling, position, 0);
        for (rows) |row| try self.importRow(a, &batch, row, "reconciliation", complete);
        if (rows.len == 0) try j.setProgress("enrichment_backfill_v1", "complete") else try j.setPosition(
            a,
            "enrichment_backfill_v1",
            rows[rows.len - 1],
        );
    }
    if (source.features.reaction_target) {
        for (try reactions.trackedRows(a, j, source)) |row| try self.importRow(
            a,
            &batch,
            row,
            "reconciliation",
            complete,
        );
        for (try reactions.missingTargets(a, j, source)) |row| try self.importRow(
            a,
            &batch,
            row,
            "reconciliation",
            complete,
        );
        try reactions.project(a, j);
    }
    try reactions.trimAnchors(j);
    try j.backfillIdentities(a);
    try j.commit();
    self.read_ready = true;
    self.degraded = if (self.automation_ready) "" else self.automation_error;
    self.last_scan_ms = u.now();
    self.send_ready.notify(self.io);
    self.ingest_pending = high > live or backfill > 0 or chats.len == 100 or try j.db.scalar("SELECT count(*) FROM reconcile_chats") > 0;
}
const ImportBatch = struct {
    source: adapter_api.Source,
    scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    rows: std.AutoHashMapUnmanaged(i64, void) = .empty,
    chats: std.AutoHashMapUnmanaged(i64, ?[]const u8) = .empty,
    rebased: bool = false,
};
fn importChat(
    self: *Core,
    a: u.Allocator,
    batch: *ImportBatch,
    row: i64,
    origin: []const u8,
    complete: bool,
) !?[]const u8 {
    if (batch.chats.get(row)) |cached| return cached;
    var result: ?[]const u8 = null;
    if (try batch.source.chat(a, row, complete)) |chat| {
        var value = chat.value;
        if (chat.thread_row) |canonical| if (canonical < row) {
            value.thread_id = try self.importChat(a, batch, canonical, origin, complete);
        };
        result = try self.journal.conversation(a, chat.source, chat.row, chat.route, value, origin);
    }
    try batch.chats.put(a, row, result);
    return result;
}
fn importRow(
    self: *Core,
    batch_a: u.Allocator,
    batch: *ImportBatch,
    row: i64,
    origin: []const u8,
    complete: bool,
) !void {
    if ((try batch.rows.getOrPut(batch_a, row)).found_existing) return;
    // Decoder scratch must not accumulate across an entire import batch.
    // Conversation IDs/maps alone need to live for the batch's duration.
    // Reuse pages across rows, but do not retain an unusually large decoded
    // attachment/archive for the rest of the batch.
    defer _ = batch.scratch.reset(.{ .retain_with_limit = 256 * 1024 });
    const a = batch.scratch.allocator();
    const source = batch.source;
    const j = self.journal;
    if (try source.message(a, row)) |m| {
        const origin_key = try std.fmt.allocPrint(a, "pending:{d}", .{row});
        const remembered = try j.progress(a, origin_key);
        // A recent/rolling scan can discover a new row before the bounded live
        // scan reaches it, including rows inserted between queries. Preserve
        // its live origin so an incoming message can still notify clients.
        var event_origin = remembered orelse if (u.eq(origin, "reconciliation") and row > try j.position(
            a,
            "live",
        )) "live" else origin;
        if (batch.rebased and remembered == null) {
            const known = try j.db.prepare("SELECT 1 FROM messages WHERE source=?");
            defer known.close();
            try known.bind(&.{.{ .text = m.source }});
            if (try known.step()) event_origin = "reconciliation";
        }
        if (m.pending and remembered == null) try j.setProgress(origin_key, event_origin);
        if (m.pending) try j.execute(
            "INSERT INTO pending_source(source_row,attempt_ms) VALUES(?,?) ON CONFLICT(source_row) DO UPDATE SET attempt_ms=excluded.attempt_ms",
            &.{ .{ .int = row }, .{ .int = u.now() } },
        ) else try j.execute(
            "DELETE FROM pending_source WHERE source_row=?",
            &.{.{ .int = row }},
        );
        if (m.chat_row == 0 or m.source.len == 0) return;
        if (try self.importChat(batch_a, batch, m.chat_row, event_origin, complete)) |cid| {
            var v = m.value;
            v.conversation_id = cid;
            if (self.assets_service != null and source.features.attachment_filename) try Assets.attach(
                a,
                j,
                m.source,
                &v,
                m.attachment_sources,
            );
            if (self.assets_service != null) try Assets.previews(a, j, m.source, &v, m.link_artwork);
            if (m.reaction) |obs| v.reaction_event = try reactions.observe(
                a,
                j,
                m.source,
                m.row,
                m.date,
                cid,
                obs,
            );
            if (source.features.reaction_target and m.value.kind != .reaction) v.reaction_event = try reactions.noLongerReaction(
                a,
                j,
                m.source,
            );
            try j.sourceMessage(a, m.source, m.row, m.date, v, event_origin);
            if (m.value.kind != .reaction) {
                try reactions.anchor(j, m.source, m.row);
                try reactions.targetImported(j, m.source, cid);
            }
            if (!m.pending) try j.execute(
                "DELETE FROM ingestion_progress WHERE key=?",
                &.{.{ .text = origin_key }},
            );
        }
    } else try j.execute("DELETE FROM pending_source WHERE source_row=?", &.{.{ .int = row }});
}
pub fn senderLoop(self: *Core) void {
    u.c.zr_thread_qos(1);
    var last_check: i64 = 0;
    var recovery_needed = false;
    while (!self.stop.load(.acquire)) {
        const observed = self.send_ready.observe();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const a = arena.allocator();
        self.lock();
        const can_probe = self.read_ready;
        self.unlock();
        if (can_probe and u.now() - last_check > 60000) {
            // The bounded automation probe runs outside the journal lock.
            var reason: []const u8 = "";
            const ready = if (comptime fake) true else ready: {
                adapter_api.automation(a, "check", "", "") catch |err| {
                    reason = adapter_api.automationReason(err);
                    break :ready false;
                };
                break :ready true;
            };
            self.lock();
            self.automation_ready = ready;
            self.automation_error = reason;
            if (self.read_ready) self.degraded = reason;
            self.unlock();
            last_check = u.now();
        }
        // This worker is the only dispatcher, so after dispatchOne returns no
        // external operation remains active here. A failed result transaction
        // can leave its durable state at dispatching even though the child was
        // reaped. Recover that uncertainty before starting another operation.
        if (recovery_needed) {
            self.lock();
            if (self.journal.recover(a)) |_| {
                recovery_needed = false;
            } else |_| {}
            self.unlock();
        }
        const dispatched = if (!recovery_needed) self.dispatchOne(a) catch dispatched: {
            recovery_needed = true;
            break :dispatched false;
        } else false;
        arena.deinit();
        if (!dispatched) self.send_ready.wait(self.io, observed, 1000);
    }
}
const Work = struct { v: t.SendRequest, route: Journal.Route };
fn prepareSend(self: *Core, a: u.Allocator) !?Work {
    self.lock();
    defer self.unlock();
    if (!self.read_ready or !self.automation_ready or u.now() - self.last_scan_ms > 5000) return null;
    const j = self.journal;
    const s = try j.db.prepare("SELECT record,epoch FROM send_requests WHERE state='queued' ORDER BY accepted_ms,id LIMIT 1");
    defer s.close();
    if (!try s.step()) return null;
    var v = (try std.json.parseFromSlice(
        t.SendRequest,
        a,
        s.bytes(0),
        .{ .allocate = .alloc_always },
    )).value;
    if (!u.eq(s.bytes(1), try j.epoch(a))) return error.ResyncRequired;
    const r = j.getRoute(a, v.target) catch |err| {
        if (err != error.UnsupportedTarget) return err;
        try self.rejectQueued(a, v, "unsupported_target");
        return null;
    };
    // Revalidate source identity immediately before dispatch; ingestion handles resets.
    var source = try adapter_api.open(a, self.source_path);
    defer source.close();
    if (!u.eq(source.identity, (try j.progress(a, "identity")) orelse "")) {
        self.read_ready = false;
        return error.ResyncRequired;
    }
    const high = try source.high();
    const live = try j.position(a, "live");
    const anchor = (try source.guid(a, live)) orelse "";
    if (high < live or !u.eq(anchor, (try j.progress(a, "anchor")) orelse "")) {
        self.read_ready = false;
        return error.ResyncRequired;
    }
    source.validateRoute(r.mode, r.destination) catch |err| {
        if (err != error.UnsupportedTarget) return err;
        try self.rejectQueued(a, v, "unsupported_target");
        return null;
    };
    try j.begin();
    errdefer j.rollback();
    v.state = .dispatching;
    _ = try j.updateRequest(a, v);
    try j.execute("UPDATE send_requests SET dispatch_ms=?,source_floor=?,mode=?,route=? WHERE id=?", &.{
        .{ .int = u.now() },
        .{ .int = high },
        .{ .text = r.mode },
        .{ .text = r.destination },
        .{ .text = v.request_id },
    });
    try j.commit();
    return .{ .v = v, .route = r };
}
fn dispatchOne(self: *Core, a: u.Allocator) !bool {
    const work = (try self.prepareSend(a)) orelse return false;
    const started = u.c.zr_monotonic_ms();
    var v = work.v;
    if (comptime fake) {
        fake_adapter.dispatch(a, self.source_path, work.route, v.text) catch |err| {
            v.state = if (err == error.Rejected) .failed else .unknown;
        };
    } else {
        adapter_api.automation(a, work.route.mode, work.route.destination, v.text) catch |err| {
            v.state = if (err == error.AutomationUncertain) .unknown else .failed;
            v.error_info = .{
                .code = adapter_api.automationReason(err),
                .message = "Messages automation could not complete the request.",
                .outcome = if (v.state == .failed) .unstarted else .uncertain,
            };
        };
    }
    if (v.state == .dispatching) v.state = .unknown;
    if (v.error_info == null) v.error_info = if (v.state == .failed) .{ .code = "dispatch_unstarted", .message = "Messages did not accept this operation." } else .{
        .code = "awaiting_observation",
        .message = "Awaiting an unambiguous outgoing Messages record.",
        .outcome = .uncertain,
    };
    self.lock();
    defer self.unlock();
    const j = self.journal;
    // A reset during automation must not overwrite its held state.
    if (!u.eq(v.server_epoch, try j.epoch(a))) return true;
    try j.begin();
    errdefer j.rollback();
    _ = try j.updateRequest(a, v);
    try j.commit();
    log.info("send request={s} state={s} code={s} duration_ms={d}", .{
        v.request_id,
        @tagName(v.state),
        if (v.error_info) |e| e.code else "none",
        u.c.zr_monotonic_ms() - started,
    });
    return true;
}
fn rejectQueued(self: *Core, a: u.Allocator, value: t.SendRequest, code: []const u8) !void {
    var v = value;
    v.state = .failed;
    v.error_info = .{ .code = code, .message = "The saved target is no longer available." };
    try self.journal.begin();
    errdefer self.journal.rollback();
    _ = try self.journal.updateRequest(a, v);
    try self.journal.commit();
}
fn reconcile(self: *Core, a: u.Allocator, batch: *ImportBatch, complete: bool) !void {
    const j = self.journal;
    const s = try j.db.prepare("SELECT r.record,r.dispatch_ms,r.source_floor,r.mode,r.route FROM send_requests r LEFT JOIN send_observations o ON o.request_id=r.id WHERE r.state IN ('submitted','unknown') AND r.dispatch_ms IS NOT NULL AND r.epoch=(SELECT epoch FROM relay_meta) ORDER BY coalesce(o.attempt_ms,0),r.dispatch_ms LIMIT 100");
    defer s.close();
    const Pending = struct {
        v: t.SendRequest,
        time: i64,
        floor: i64,
        mode: []const u8,
        route: []const u8,
    };
    var items: std.ArrayList(Pending) = .empty;
    while (try s.step()) try items.append(a, .{
        .v = (try std.json.parseFromSlice(
            t.SendRequest,
            a,
            s.bytes(0),
            .{ .allocate = .alloc_always },
        )).value,
        .time = s.int(1),
        .floor = s.int(2),
        .mode = try s.text(a, 3),
        .route = try s.text(a, 4),
    });
    for (items.items) |p| {
        var v = p.v;
        try j.execute(
            "INSERT INTO send_observations VALUES(?,?) ON CONFLICT(request_id) DO UPDATE SET attempt_ms=excluded.attempt_ms",
            &.{ .{ .text = v.request_id }, .{ .int = u.now() } },
        );
        if (v.message_id) |mid| {
            const refresh = try j.db.prepare("SELECT source_row FROM messages WHERE id=?");
            defer refresh.close();
            try refresh.bind(&.{.{ .text = mid }});
            if (try refresh.step()) try self.importRow(
                a,
                batch,
                refresh.int(0),
                "reconciliation",
                complete,
            );
            const q = try j.db.prepare("SELECT status FROM messages WHERE id=?");
            defer q.close();
            try q.bind(&.{.{ .text = mid }});
            if (try q.step()) {
                if (u.eq(q.bytes(0), "delivered")) {
                    v.state = .delivered;
                    v.error_info = null;
                    _ = try j.updateRequest(a, v);
                } else if (u.eq(q.bytes(0), "failed")) {
                    v.state = .failed;
                    v.error_info = .{
                        .code = "observed_failure",
                        .message = "Messages reported failure.",
                        .outcome = .uncertain,
                    };
                    _ = try j.updateRequest(a, v);
                }
            }
            continue;
        }
        // Publish a provisional echo for display as soon as it is observed.
        // Confirmation still waits for the complete observation window, and a
        // later second candidate withdraws the hint without confirming the send.
        const q = try j.db.prepare("SELECT m.id,m.status FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.source_row>? AND m.direction='outgoing' AND c.service='imessage' AND m.text=? AND m.date_ns BETWEEN ? AND ? AND ((?='chat' AND c.route=?) OR (?='direct' AND (SELECT count(*) FROM participants WHERE conversation_id=c.id)=1 AND EXISTS(SELECT 1 FROM participants WHERE conversation_id=c.id AND address=?))) AND NOT EXISTS(SELECT 1 FROM send_requests WHERE message_id=m.id) LIMIT 2");
        defer q.close();
        const start = (p.time - 2000 - 978307200000) * 1000000;
        const end = (p.time + observation_window_ms - 978307200000) * 1000000;
        try q.bind(&.{
            .{ .int = p.floor },
            .{ .text = v.text },
            .{ .int = start },
            .{ .int = end },
            .{ .text = p.mode },
            .{ .text = p.route },
            .{ .text = p.mode },
            .{ .text = p.route },
        });
        const found = try q.step();
        const mid = if (found) try q.text(a, 0) else null;
        const status = if (found) try q.text(a, 1) else "";
        var unique = found and !try q.step();
        if (unique) {
            // One echo cannot account for two overlapping identical sends,
            // including a direct target and an existing chat for that recipient.
            const competing = try j.db.prepare("SELECT 1 FROM send_requests r JOIN messages m ON m.id=? JOIN conversations c ON c.id=m.conversation_id WHERE r.id!=? AND r.epoch=? AND r.state IN ('dispatching','unknown','submitted') AND r.message_id IS NULL AND m.source_row>r.source_floor AND m.text=json_extract(r.record,'$.text') AND m.date_ns BETWEEN (r.dispatch_ms-2000-978307200000)*1000000 AND (r.dispatch_ms+?-978307200000)*1000000 AND ((r.mode='chat' AND c.route=r.route) OR (r.mode='direct' AND (SELECT count(*) FROM participants WHERE conversation_id=c.id)=1 AND EXISTS(SELECT 1 FROM participants WHERE conversation_id=c.id AND address=r.route))) LIMIT 1");
            defer competing.close();
            try competing.bind(&.{
                .{ .text = mid.? },
                .{ .text = v.request_id },
                .{ .text = v.server_epoch },
                .{ .int = observation_window_ms },
            });
            unique = !try competing.step();
        }
        const candidate = if (unique) mid else null;
        if (!unique or u.now() < p.time + observation_window_ms) {
            if (!u.eq(v.candidate_message_id orelse "", candidate orelse "")) {
                v.candidate_message_id = candidate;
                _ = try j.updateRequest(a, v);
            }
            continue;
        }
        v.message_id = mid;
        v.candidate_message_id = null;
        v.state = if (u.eq(status, "delivered")) .delivered else if (u.eq(status, "failed")) .failed else .submitted;
        v.error_info = if (v.state == .failed) .{
            .code = "observed_failure",
            .message = "Messages reported failure.",
            .outcome = .uncertain,
        } else null;
        _ = try j.updateRequest(a, v);
    }
}
