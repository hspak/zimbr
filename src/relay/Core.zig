const std = @import("std");
const log = std.log.scoped(.relay_core);

const contacts = @import("adapter/contacts.zig");
const Assets = @import("Assets.zig");
const uploads = @import("uploads.zig");
const sends = @import("sends.zig");
const Mutex = @import("Mutex.zig");
const fake_adapter = @import("adapter/fake.zig");
const macos_adapter = @import("adapter/macos.zig");
const Sqlite = @import("Sqlite.zig");
const options = @import("options");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const Journal = @import("Journal.zig");
const MessagesDb = @import("adapter/MessagesDb.zig");
const reactions = @import("reactions.zig");
const Signal = @import("../Signal.zig");
const adapter_api = if (options.fake) fake_adapter else macos_adapter;
const fake = options.fake;
const observation_window_ms = 10000;
const initial_import_limit = 1000;
const Core = @This();

io: std.Io,
journal: Journal,
source_path: [:0]const u8,
contacts_phone_region: []const u8 = "",
contacts_status: contacts.Status = .{},
source_features: adapter_api.Source.Features = .{},
assets_service: ?Assets = null,
upload_files: ?uploads.Files = null,
upload_releases: [uploads.max_reservations]?uploads.Release = @splat(null),
assets_reason: []const u8 = "starting",
mutex: Mutex = .init,
read_ready: bool = false,
reset_required: bool = false,
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
    RelayCacheResetRequired,
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

/// Caller holds the Core mutex. Reads bounded queue/progress probes, not record counts.
pub fn syncActivity(self: *Core) Journal.QueryError!t.SyncActivity {
    if (self.reset_required) return .{};
    const j = self.journal;
    const directory = contacts.currentStatus(self.contacts_status);
    const contact_ready = directory.permission == .authorized and !directory.stale and
        !u.eq(directory.reason, "contacts_persistence_failure");
    const images = try j.db.prepare(
        "SELECT EXISTS(SELECT 1 FROM asset_work w JOIN asset_sources s ON s.id=w.asset_id AND s.version=w.version WHERE w.attempt_ms<=? AND (s.kind!='contact' OR ?) AND EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=s.id))",
    );
    defer images.close();
    try images.bind(&.{ .{ .int = u.now() }, .{ .int = @intFromBool(contact_ready) } });
    _ = try images.step();
    return .{
        .messages = self.read_ready and (try j.position("backfill") > 0 or
            try j.db.scalar("SELECT EXISTS(SELECT 1 FROM reconcile_chats)") != 0),
        .contacts = contact_ready and (directory.refreshing or
            u.eq(directory.reason, "reconciling") or
            try j.db.scalar("SELECT EXISTS(SELECT 1 FROM identity_work) OR NOT EXISTS(SELECT 1 FROM ingestion_progress WHERE key='identity_backfill_v1' AND value='complete')") != 0),
        .images = self.assets_service != null and images.int(0) != 0,
        .media = self.read_ready and
            try j.db.scalar("SELECT NOT EXISTS(SELECT 1 FROM ingestion_progress WHERE key='enrichment_backfill_v1' AND value='complete')") != 0,
    };
}
pub fn ingestLoop(self: *Core) void {
    u.c.zr_thread_qos(0);
    var tick: usize = 0;
    const watch = u.c.zr_watch_open(self.source_path);
    defer u.c.zr_watch_close(watch);
    var settle = false;
    var maintenance: i64 = 0;
    var upload_maintenance: i64 = 0;
    while (!self.stop.load(.acquire)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.lock();
        const was_ready = self.read_ready;
        const started = u.c.zr_monotonic_ms();
        self.ingest(arena.allocator()) catch |err| {
            if (was_ready or tick % 60 == 0) {
                if (err == error.DatabaseBusy) {
                    log.warn("Message ingestion delayed: {s}", .{@errorName(err)});
                } else log.err("Message ingestion stopped: {s}", .{@errorName(err)});
            }
            self.read_ready = false;
            self.degraded = switch (err) {
                error.SchemaUnsupported => "schema_unsupported",
                error.DatabaseBusy => "database_busy",
                error.DatabaseUnavailable => "database_access_required",
                error.RelayCacheResetRequired => "relay_cache_reset_required",
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
        if (u.now() >= upload_maintenance) {
            self.cleanupUploads(arena.allocator()) catch |err| {
                log.warn("Upload cleanup delayed: {s}", .{@errorName(err)});
            };
            upload_maintenance = u.now() + 1000;
        }
        arena.deinit();
        tick += 1;
        // Drain bounded backfill/live pages promptly. Notifications may precede
        // SQLite's commit, so take one short settling pass, then keep the full
        // periodic scan as recovery for missed/coalesced filesystem events.
        const changed = u.c.zr_watch_wait(watch, if (pending) 1 else if (settle) 50 else 1000) != 0;
        settle = changed;
    }
}
fn cleanupUploads(self: *Core, a: u.Allocator) !void {
    const files = self.upload_files orelse return;
    var ids: [32][]const u8 = undefined;
    var count: usize = 0;
    {
        self.lock();
        defer self.unlock();
        for (&self.upload_releases) |*slot| if (slot.*) |release| {
            release.apply(self.journal) catch continue;
            slot.* = null;
        };
        try uploads.expire(self.journal, u.now());
        const q = try self.journal.db.prepare("SELECT id FROM uploads WHERE state='deleting' LIMIT 32");
        defer q.close();
        while (try q.step()) {
            ids[count] = try q.text(a, 0);
            count += 1;
        }
    }
    // Only this worker reclaims retired directories; HTTP cancellation merely
    // retires rows, preventing a cleanup race with recreation of the same ID.
    for (ids[0..count]) |id| {
        files.remove(id) catch continue;
        self.lock();
        defer self.unlock();
        try uploads.purge(self.journal, id);
    }
}

/// Caller holds the journal mutex and has already closed the transfer's files.
/// Failed releases survive request destruction and retry in the cleanup worker.
pub fn releaseUpload(self: *Core, lease: uploads.Lease) void {
    const release = uploads.Release.init(lease);
    release.apply(self.journal) catch {
        for (&self.upload_releases) |*slot| if (slot.* == null) {
            slot.* = release;
            return;
        };
        // A failed release retains its reservation. Each ID has one writer and
        // the queue can hold every reservation, so another entry cannot exist.
        unreachable;
    };
}
pub fn ingest(self: *Core, a: u.Allocator) IngestError!void {
    if (self.reset_required) return error.RelayCacheResetRequired;
    var source = try adapter_api.open(a, self.source_path);
    defer source.close();
    self.source_features = source.features;
    try source.db.exec("BEGIN");
    defer source.db.exec("ROLLBACK") catch {};
    var batch = ImportBatch{ .source = source };
    defer batch.scratch.deinit();
    var row_buffer: [MessagesDb.row_batch_size]i64 = undefined;
    const high = try source.high();
    const j = self.journal;
    try j.begin();
    errdefer j.rollback();
    const stored_identity = try j.progress(a, "identity");
    var live = try j.position("live");
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
                    try j.setPosition("live", live);
                    try j.setPosition("rolling", 0);
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
        try j.setPosition("live", live);
        try j.setPosition("backfill", high);
        try j.setProgress("anchor", (try source.guid(a, high)) orelse "");
        // New imports already normalize identities and metadata. The separate
        // upgrade passes are only needed for records from older relay versions.
        try j.setProgress("identity_backfill_v1", "complete");
        try j.setProgress("enrichment_backfill_v1", "complete");
    }
    var backfill = try j.position("backfill");
    const complete = backfill == 0;
    const chat_after = try j.position("chats");
    const chats = try source.chatRows(&row_buffer, chat_after);
    for (chats) |row| {
        _ = try self.importChat(a, &batch, row, "reconciliation", complete);
    }
    try j.setPosition("chats", if (chats.len == 0) 0 else chats[chats.len - 1]);
    const live_rows = try source.rowsFor(&row_buffer, .live, live, 0);
    for (live_rows) |row| {
        try self.importRow(a, &batch, row, "live", complete);
        live = row;
    }
    try j.setPosition("live", live);
    try j.setProgress("anchor", (try source.guid(a, live)) orelse "");
    var backfill_rows: usize = 0;
    if (backfill > 0) {
        // Initial import favors throughput: amortize source setup, conversation
        // queries, and durable commits across more rows. Live scans stay small.
        var initial_rows: [initial_import_limit]i64 = undefined;
        const old = try source.rowsFor(&initial_rows, .backfill, backfill, 0);
        backfill_rows = old.len;
        for (old) |row| try self.importRow(a, &batch, row, "historical_import", false);
        backfill = if (old.len == 0) 0 else old[old.len - 1] - 1;
        try j.setPosition("backfill", backfill);
    }
    // Retry unresolved source rows independently of insertion progress, fairly.
    var pending_rows: [50]i64 = undefined;
    const pending = try j.db.prepare("SELECT source_row FROM pending_source ORDER BY attempt_ms,source_row LIMIT ?");
    defer pending.close();
    try pending.bind(&.{.{ .int = pending_rows.len }});
    var pending_count: usize = 0;
    while (try pending.step()) : (pending_count += 1) pending_rows[pending_count] = pending.int(0);
    for (pending_rows[0..pending_count]) |row| try self.importRow(a, &batch, row, "reconciliation", complete);
    for (try source.rowsFor(&row_buffer, .recent, high, 0)) |row| try self.importRow(
        a,
        &batch,
        row,
        "reconciliation",
        complete,
    );
    // Backfill visits every older row. Start periodic edit reconciliation after
    // it finishes, retaining recent and requested-chat checks during import.
    if (complete) {
        const rolling = try j.position("rolling");
        const older = try source.rowsFor(&row_buffer, .rolling, rolling, 0);
        for (older) |row| try self.importRow(a, &batch, row, "reconciliation", complete);
        try j.setPosition("rolling", if (older.len == 0) 0 else older[older.len - 1]);
    }
    // History requests schedule bounded reconciliation, serviced alongside live scans.
    const rq = try j.db.prepare("SELECT r.conversation_id,r.after_row,c.source_row FROM reconcile_chats r JOIN conversations c ON c.id=r.conversation_id ORDER BY r.rowid LIMIT 1");
    defer rq.close();
    if (try rq.step()) {
        const cid = try rq.text(a, 0);
        const rows = try source.rowsFor(&row_buffer, .chat, rq.int(1), rq.int(2));
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
    var enrichment_rows: ?usize = null;
    if (!u.eq(enrichment_backfill, "complete")) {
        const position = std.fmt.parseInt(i64, enrichment_backfill, 10) catch 0;
        const rows = try source.rowsFor(&row_buffer, .rolling, position, 0);
        enrichment_rows = rows.len;
        for (rows) |row| try self.importRow(a, &batch, row, "reconciliation", complete);
        if (rows.len == 0) try j.setProgress("enrichment_backfill_v1", "complete") else try j.setPosition(
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
    if (reset) log.warn("Messages source changed; relay journal reset and sync restarted", .{});
    if (stored_identity == null or reset) {
        log.info("Message backfill initialized: source_high={d}", .{high});
    }
    if (live_rows.len > 0 or !complete) log.debug(
        "Message batch committed: live_rows={d} backfill_rows={d} backfill_before={d}",
        .{
            live_rows.len,
            backfill_rows,
            backfill,
        },
    );
    if (!complete and backfill == 0) log.info("Message backfill complete", .{});
    if (enrichment_rows) |count| {
        if (count == 0) {
            log.info("Media metadata backfill complete", .{});
        } else log.debug("Media metadata batch committed: source_rows={d}", .{count});
    }
    self.read_ready = true;
    self.degraded = if (self.automation_ready) "" else self.automation_error;
    self.last_scan_ms = u.now();
    self.send_ready.notify(self.io);
    // The final import page still needs a prompt pass to publish complete chats.
    self.ingest_pending = high > live or !complete or
        chats.len == MessagesDb.row_batch_size or
        try j.db.scalar("SELECT EXISTS(SELECT 1 FROM reconcile_chats)") != 0;
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
        var event_origin = remembered orelse if (u.eq(origin, "reconciliation") and
            row > try j.position("live")) "live" else origin;
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
const Work = struct { v: t.SendRequest, route: Journal.Route, part: ?usize };
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
    const live = try j.position("live");
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
    const part = if (v.parts.len != 0) sends.next(v).? else null;
    if (part) |position| sends.start(&v, position) else v.state = .dispatching;
    _ = try j.updateRequest(a, v);
    const boundary: [5]Sqlite.Parameter = .{
        .{ .int = u.now() },
        .{ .int = high },
        .{ .text = r.mode },
        .{ .text = r.destination },
        .{ .text = v.request_id },
    };
    if (part) |position| {
        try j.execute("UPDATE send_parts SET dispatch_ms=?,source_floor=?,mode=?,route=? WHERE request_id=? AND position=?", &(boundary ++ [_]Sqlite.Parameter{.{ .int = @intCast(position) }}));
    } else try j.execute("UPDATE send_requests SET dispatch_ms=?,source_floor=?,mode=?,route=? WHERE id=?", &boundary);
    try j.commit();
    return .{ .v = v, .route = r, .part = part };
}
fn dispatchOne(self: *Core, a: u.Allocator) !bool {
    const work = (try self.prepareSend(a)) orelse return false;
    const started = u.c.zr_monotonic_ms();
    var v = work.v;
    if (work.part) |position| {
        const outcome = try self.invokePart(a, work, position);
        self.lock();
        defer self.unlock();
        const j = self.journal;
        if (!u.eq(v.server_epoch, try j.epoch(a))) return true;
        // Observation can advance an earlier part while automation is running.
        // Apply only this result to the latest record, never to the old snapshot.
        v = try std.json.parseFromSliceLeaky(t.SendRequest, a, (try j.getRecord(a, .request, v.request_id)).?, .{});
        sends.finish(&v, position, outcome);
        try j.begin();
        errdefer j.rollback();
        _ = try j.updateRequest(a, v);
        try j.commit();
        log.info("send request={s} part={d} state={s} duration_ms={d}", .{
            v.request_id,
            position,
            @tagName(v.parts[position].state),
            u.c.zr_monotonic_ms() - started,
        });
        return true;
    }
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

fn invokePart(self: *Core, a: u.Allocator, work: Work, position: usize) !sends.Outcome {
    const files = self.upload_files orelse return .{ .unstarted = "upload_storage_unavailable" };
    // Check every staged file before starting the first operation, including a
    // caption. A missing original must not silently become a text-only request.
    if (position == 0) for (work.v.attachments) |file| {
        const fd = files.open(a, file) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .unstarted = "upload_file_unavailable" };
        };
        _ = u.c.close(fd);
    };
    const part = work.v.parts[position];
    switch (part.kind) {
        .text => return self.invokeText(a, work.route, work.v.text),
        .attachment => {
            const file = for (work.v.attachments) |file| {
                if (u.eq(file.id, part.attachment_id.?)) break file;
            } else unreachable; // Accepted parts refer to exactly one pinned upload.
            const fd = files.open(a, file) catch |err| {
                if (err == error.OutOfMemory) return err;
                return .{ .unstarted = "upload_file_unavailable" };
            };
            defer _ = u.c.close(fd);
            if (comptime fake) {
                fake_adapter.dispatchFile(a, self.source_path, work.route, file, fd) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return if (err == error.Rejected) .{ .unstarted = "dispatch_unstarted" } else .{ .uncertain = "automation_uncertain" };
                };
            } else {
                const mode = if (u.eq(work.route.mode, "direct")) "direct-file" else "chat-file";
                adapter_api.automation(a, mode, work.route.destination, try files.path(a, file)) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return automationOutcome(err);
                };
            }
            return .invoked;
        },
    }
}

fn invokeText(self: *Core, a: u.Allocator, route: Journal.Route, text: []const u8) !sends.Outcome {
    if (comptime fake) {
        fake_adapter.dispatch(a, self.source_path, route, text) catch |err| {
            if (err == error.OutOfMemory) return err;
            return if (err == error.Rejected) .{ .unstarted = "dispatch_unstarted" } else .{ .uncertain = "automation_uncertain" };
        };
    } else {
        adapter_api.automation(a, route.mode, route.destination, text) catch |err| {
            if (err == error.OutOfMemory) return err;
            return automationOutcome(err);
        };
    }
    return .invoked;
}

fn automationOutcome(err: macos_adapter.AutomationError) sends.Outcome {
    const code = macos_adapter.automationReason(err);
    return if (err == error.AutomationUncertain) .{ .uncertain = code } else .{ .unstarted = code };
}
fn rejectQueued(self: *Core, a: u.Allocator, value: t.SendRequest, code: []const u8) !void {
    var v = value;
    if (v.parts.len != 0) {
        const position = sends.next(v).?;
        sends.start(&v, position);
        sends.finish(&v, position, .{ .unstarted = code });
    } else {
        v.state = .failed;
        v.error_info = .{ .code = code, .message = "The saved target is no longer available." };
    }
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
        const q = try j.db.prepare("SELECT m.id,m.status FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.source_row>? AND m.direction='outgoing' AND c.service='imessage' AND m.text=? AND m.date_ns BETWEEN ? AND ? AND ((?='chat' AND c.route=?) OR (?='direct' AND (SELECT count(*) FROM participants WHERE conversation_id=c.id)=1 AND EXISTS(SELECT 1 FROM participants WHERE conversation_id=c.id AND address=?))) AND NOT EXISTS(SELECT 1 FROM send_requests WHERE message_id=m.id) AND NOT EXISTS(SELECT 1 FROM send_parts WHERE message_id=m.id) LIMIT 2");
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
        if (unique) {
            const parts = try j.db.prepare("SELECT 1 FROM send_parts p JOIN send_requests r ON r.id=p.request_id JOIN messages m ON m.id=? JOIN conversations c ON c.id=m.conversation_id WHERE r.epoch=? AND p.state IN ('dispatching','invoked','unknown','submitted') AND p.message_id IS NULL AND json_extract(r.record,'$.parts['||p.position||'].kind')='text' AND m.source_row>p.source_floor AND m.text=json_extract(r.record,'$.text') AND m.date_ns BETWEEN (p.dispatch_ms-2000-978307200000)*1000000 AND (p.dispatch_ms+?-978307200000)*1000000 AND ((p.mode='chat' AND c.route=p.route) OR (p.mode='direct' AND (SELECT count(*) FROM participants WHERE conversation_id=c.id)=1 AND EXISTS(SELECT 1 FROM participants WHERE conversation_id=c.id AND address=p.route))) LIMIT 1");
            defer parts.close();
            try parts.bind(&.{
                .{ .text = mid.? },
                .{ .text = v.server_epoch },
                .{ .int = observation_window_ms },
            });
            unique = !try parts.step();
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

test "sync activity follows durable backfills and runnable asset work" {
    if (comptime !fake) return error.SkipZigTest;
    const j = try Journal.open(":memory:");
    defer j.close();
    var core = Core{
        .io = std.testing.io,
        .journal = j,
        .source_path = "",
        .read_ready = true,
        .contacts_status = .{
            .permission = .authorized,
            .ready = true,
            .reason = "",
        },
    };
    try j.setPosition("backfill", 200);
    var activity = try core.syncActivity();
    try std.testing.expect(activity.messages and activity.contacts and activity.media);
    try std.testing.expect(!activity.images);
    try j.setPosition("backfill", 0);
    try j.setProgress("identity_backfill_v1", "complete");
    try j.setProgress("enrichment_backfill_v1", "complete");
    try std.testing.expect(!(try core.syncActivity()).active());

    core.contacts_status.refreshing = true;
    try std.testing.expect((try core.syncActivity()).contacts);
    core.contacts_status.refreshing = false;
    core.contacts_status.permission = .denied;
    try j.setProgress("identity_backfill_v1", "cursor");
    try std.testing.expect(!(try core.syncActivity()).contacts);

    core.assets_service = .{
        .root_path = "",
        .cache_fd = -1,
        .helper_path = "",
    };
    try j.db.exec(
        "INSERT INTO asset_sources(id,kind,source_key,path,version) VALUES('image','attachment','image','','v1');" ++
            "INSERT INTO asset_owners VALUES('image','message','message');" ++
            "INSERT INTO asset_work VALUES('image','v1','inline_image',0);",
    );
    activity = try core.syncActivity();
    try std.testing.expect(activity.images);
    try j.execute("UPDATE asset_work SET attempt_ms=?", &.{.{ .int = u.now() + 30000 }});
    try std.testing.expect(!(try core.syncActivity()).images);
    try j.db.exec("UPDATE asset_work SET attempt_ms=0,version='old'");
    try std.testing.expect(!(try core.syncActivity()).images);
    try j.db.exec("DELETE FROM asset_work");
    core.reset_required = true;
    try std.testing.expect(!(try core.syncActivity()).active());
}
