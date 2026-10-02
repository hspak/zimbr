//! Correlate multipart sends against bounded source snapshots and original-byte
//! hashes. File I/O runs on this worker, outside the journal mutex and sender.
const std = @import("std");
const Hash = std.crypto.hash.sha2.Sha256;
const log = std.log.scoped(.send_observation);
const u = @import("../../common.zig");
const protocol = @import("../../protocol.zig");
const t = protocol.types;
const Core = @import("../Core.zig");
const Journal = @import("../Journal.zig");
const Source = @import("../adapter/MessagesDb.zig");
const sends = @import("../sends.zig");
const uploads = @import("../uploads.zig");
const options = @import("options");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("relay/media.h");
});

// Inspect 64 send candidates per pass to keep observation work bounded.
const max_rows = 64;
// Stop after 4,096 source rows so a busy conversation cannot cause an unbounded scan.
const max_source_rows = 4096;
const hash_budget = protocol.attachments.max_send_bytes;
const Work = struct {
    request: t.SendRequest,
    position: usize,
    time: i64,
    floor: i64,
    mode: []const u8,
    route: []const u8,
    source_identity: []const u8,
};
const Candidate = struct {
    row: i64,
    date: i64,
    guid: []const u8,
    text: []const u8,
    has_attachments: bool,
    status: @FieldType(t.Message, "observed_status"),
    filename: ?[]const u8,
};
const Snapshot = struct {
    fingerprint: [32]u8,
    candidates: []const Candidate,
    complete: bool,
};
const Proof = struct { digest: [32]u8, fingerprint: c.ZrMediaFingerprint };
const Cache = struct {
    // Retain 512 verified file hashes to avoid repeatedly reading the same attachment bytes.
    entries: [512]?Proof = @splat(null),
    next: usize = 0,

    fn get(self: *const Cache, fingerprint: *const c.ZrMediaFingerprint) ?Proof {
        for (&self.entries) |*entry| if (entry.*) |*proof| {
            if (c.zr_media_same(&proof.fingerprint, fingerprint) != 0) return proof.*;
        };
        return null;
    }
    fn put(self: *Cache, proof: Proof) void {
        self.entries[self.next] = proof;
        self.next = (self.next + 1) % self.entries.len;
    }
};

pub fn loop(core: *Core) void {
    u.c.zr_thread_qos(0);
    var cache: Cache = .{};
    var last_error: i64 = 0;
    while (!core.stop.load(.acquire)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const worked = step(core, arena.allocator(), &cache) catch |err| worked: {
            // Report persistent observation failures at most once a minute to avoid log flooding.
            if (u.now() - last_error > 60000) {
                log.warn("Multipart observation delayed: {s}", .{@errorName(err)});
                last_error = u.now();
            }
            break :worked false;
        };
        arena.deinit();
        // A quarter-second idle poll keeps send feedback responsive without a busy loop.
        if (!worked) core.sleep(250);
    }
}

fn prepare(core: *Core, a: u.Allocator) !?Work {
    core.lock();
    defer core.unlock();
    // Only match against a source scan from the last five seconds.
    if (!core.read_ready or core.reset_required or u.now() - core.last_scan_ms > 5000) return null;
    const j = core.journal;
    const q = try j.db.prepare("SELECT r.record,p.position,p.dispatch_ms,p.source_floor,p.mode,p.route FROM send_parts p JOIN send_requests r ON r.id=p.request_id LEFT JOIN send_part_observations o ON o.request_id=p.request_id AND o.position=p.position WHERE p.state IN ('invoked','unknown','submitted') AND p.dispatch_ms IS NOT NULL AND r.epoch=(SELECT epoch FROM relay_meta) AND coalesce(o.attempt_ms,0)<? ORDER BY coalesce(o.attempt_ms,0),p.dispatch_ms,p.position LIMIT 1");
    defer q.close();
    try q.bind(&.{.{ .int = u.now() - 1000 }});
    if (!try q.step()) return null;
    const work: Work = .{
        .request = try std.json.parseFromSliceLeaky(t.SendRequest, a, q.bytes(0), .{ .allocate = .alloc_always }),
        .position = @intCast(q.int(1)),
        .time = q.int(2),
        .floor = q.int(3),
        .mode = try q.text(a, 4),
        .route = try q.text(a, 5),
        .source_identity = (try j.progress(a, "identity")) orelse return null,
    };
    // After a minute without an echo, switch to roughly 30-second retries to reduce rescans.
    const old_unconfirmed = work.request.parts[work.position].message_id == null and u.now() - work.time > 60000;
    const next_attempt = u.now() + if (old_unconfirmed) @as(i64, 29000) else 0;
    try j.execute("INSERT INTO send_part_observations VALUES(?,?,?) ON CONFLICT(request_id,position) DO UPDATE SET attempt_ms=excluded.attempt_ms", &.{
        .{ .text = work.request.request_id },
        .{ .int = @intCast(work.position) },
        .{ .int = next_attempt },
    });
    return work;
}

fn fileFor(work: Work) ?protocol.attachments.Upload {
    const part = work.request.parts[work.position];
    if (part.kind == .text) return null;
    for (work.request.attachments) |file| if (u.eq(file.id, part.attachment_id.?)) return file;
    unreachable; // Acceptance creates parts from exactly these upload references.
}

fn snapshot(core: *Core, a: u.Allocator, work: Work) !?Snapshot {
    var source = try Source.open(a, core.source_path);
    defer source.close();
    if (!u.eq(source.identity, work.source_identity)) return null;
    try source.db.exec("BEGIN");
    defer source.db.exec("ROLLBACK") catch {};
    // The source is read-only and may have no date index. Refuse an unbounded
    // historical scan rather than repeatedly walking every row after an old
    // uncertain send. Gaps in source row IDs do not consume this row budget.
    const overflow = try source.db.prepare("SELECT ROWID FROM message WHERE ROWID>? ORDER BY ROWID LIMIT 1 OFFSET " ++ std.fmt.comptimePrint("{d}", .{max_source_rows}));
    defer overflow.close();
    try overflow.bind(&.{.{ .int = work.floor }});
    if (try overflow.step()) return null;
    // Unjoined outgoing rows are included: a delayed chat/attachment join must
    // not make a second possible echo disappear from the uniqueness check.
    const q = try source.db.prepare("SELECT m.ROWID FROM message m WHERE m.ROWID>? AND m.is_from_me=1 AND m.service='iMessage' AND m.date BETWEEN ? AND ? AND (NOT EXISTS(SELECT 1 FROM chat_message_join WHERE message_id=m.ROWID) OR EXISTS(SELECT 1 FROM chat_message_join j JOIN chat c ON c.ROWID=j.chat_id WHERE j.message_id=m.ROWID AND c.service_name='iMessage' AND ((?='chat' AND c.guid=?) OR (?='direct' AND (SELECT count(*) FROM chat_handle_join WHERE chat_id=c.ROWID)=1 AND EXISTS(SELECT 1 FROM chat_handle_join h JOIN handle p ON p.ROWID=h.handle_id WHERE h.chat_id=c.ROWID AND p.id=?))))) ORDER BY m.ROWID LIMIT " ++ std.fmt.comptimePrint("{d}", .{max_rows + 1}));
    defer q.close();
    try q.bind(&.{
        .{ .int = work.floor },
        // Allow two seconds of skew, then convert Unix milliseconds to Apple's 2001 epoch
        // nanoseconds.
        .{ .int = (work.time - 2000 - 978307200000) * 1000000 },
        .{ .int = (work.time + sends.observation_window_ms - 978307200000) * 1000000 },
        .{ .text = work.mode },
        .{ .text = work.route },
        .{ .text = work.mode },
        .{ .text = work.route },
    });
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const file = fileFor(work);
    var candidates: std.ArrayList(Candidate) = .empty;
    var fingerprint: Hash = .init(.{});
    var complete = true;
    var rows: usize = 0;
    while (try q.step()) {
        if (rows == max_rows) return null;
        rows += 1;
        // Retain ordinary decode scratch space but release memory from unusually large candidates.
        _ = scratch.reset(.{ .retain_with_limit = 256 * 1024 });
        const row_a = scratch.allocator();
        const message = (try source.message(row_a, q.int(0))) orelse return null;
        fingerprint.update(try u.json(row_a, message));
        if (message.value.kind == .reaction or message.value.kind == .system) continue;
        const undecodable = switch (message.value.decoding) {
            .plain, .attributed, .empty => false,
            .unsupported, .malformed, .oversized => true,
        };
        const oversized = if (message.value.enrichment) |enrichment| enrichment.state == .oversized else false;
        if (message.pending or undecodable or oversized) {
            complete = false;
            continue;
        }
        var filename: ?[]const u8 = null;
        if (file) |expected| {
            // Messages' total_bytes can differ from the original file's length.
            // Select by name here; prove length and content from the file below.
            if (message.value.attachments.len != 1) {
                for (message.value.attachments) |attachment| {
                    if (u.eq(attachment.name, expected.name)) complete = false;
                }
                continue;
            }
            const attachment = message.value.attachments[0];
            if (!u.eq(attachment.name, expected.name)) continue;
            if (message.attachment_sources.len != 1) {
                complete = false;
                continue;
            }
            filename = try a.dupe(u8, message.attachment_sources[0].filename);
        } else if (!u.eq(message.value.text orelse "", work.request.text)) continue;
        try candidates.append(a, .{
            .row = message.row,
            .date = message.date,
            .guid = try a.dupe(u8, message.source),
            .text = try a.dupe(u8, message.value.text orelse ""),
            .has_attachments = message.value.attachments.len != 0,
            .status = message.value.observed_status,
            .filename = filename,
        });
    }
    var digest: [32]u8 = undefined;
    fingerprint.final(&digest);
    return .{
        .fingerprint = digest,
        .candidates = candidates.items,
        .complete = complete,
    };
}

fn relative(root: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null or path.len > 4096) return null;
    const home_root = "~/Library/Messages/Attachments/";
    if (comptime !options.fake) {
        if (std.mem.startsWith(u8, path, home_root)) return path[home_root.len..];
    }
    if (root.len != 0 and std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') return path[root.len + 1 ..];
    return null;
}

fn open(core: *Core, a: u.Allocator, filename: []const u8, fingerprint: *c.ZrMediaFingerprint) !?c_int {
    const path = relative(core.attachment_root, filename) orelse return null;
    const root = c.zr_media_directory(try a.dupeZ(u8, core.attachment_root), 0);
    if (root < 0) return null;
    defer _ = u.c.close(root);
    const fd = c.zr_media_source(root, try a.dupeZ(u8, path), fingerprint);
    return if (fd < 0) null else fd;
}

fn hashFile(core: *Core, a: u.Allocator, cache: *Cache, file: protocol.attachments.Upload, filename: []const u8, budget: *u64) !?Proof {
    var before: c.ZrMediaFingerprint = undefined;
    const fd = (try open(core, a, filename, &before)) orelse return null;
    defer _ = u.c.close(fd);
    const storage = core.upload_files orelse return null;
    const original = storage.open(a, file) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer _ = u.c.close(original);
    var staged: c.ZrMediaFingerprint = undefined;
    if (c.zr_media_fingerprint(original, &staged) != 0 or
        (staged.device == before.device and staged.inode == before.inode)) return null;
    if (cache.get(&before)) |proof| return proof;
    if (before.bytes > budget.*) return null;
    budget.* -= before.bytes;
    // 64 KiB batches file hashing without allocating space for an entire attachment.
    var buffer: [64 * 1024]u8 = undefined;
    var hash: Hash = .init(.{});
    var remaining = before.bytes;
    while (remaining != 0) {
        if (core.stop.load(.acquire)) return null;
        const count = u.c.read(fd, &buffer, @min(buffer.len, remaining));
        if (count < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return null;
        }
        if (count == 0) return null;
        const length: usize = @intCast(count);
        hash.update(buffer[0..length]);
        remaining -= length;
    }
    var after: c.ZrMediaFingerprint = undefined;
    if (c.zr_media_fingerprint(fd, &after) != 0 or c.zr_media_same(&before, &after) == 0) return null;
    var proof: Proof = .{ .digest = undefined, .fingerprint = after };
    hash.final(&proof.digest);
    cache.put(proof);
    return proof;
}

fn step(core: *Core, a: u.Allocator, cache: *Cache) !bool {
    const work = (try prepare(core, a)) orelse return false;
    if (work.request.parts[work.position].message_id) |mid| return receipt(core, a, work, mid);
    const before = (try snapshot(core, a, work)) orelse return publish(core, a, work, null);
    const file = fileFor(work);
    var budget: u64 = hash_budget;
    var complete = before.complete;
    var found: ?Candidate = null;
    var proof: ?Proof = null;
    var matches: usize = 0;
    for (before.candidates) |candidate| {
        if (file) |expected| {
            const verified = (try hashFile(core, a, cache, expected, candidate.filename.?, &budget)) orelse {
                complete = false;
                continue;
            };
            if (verified.fingerprint.bytes != try protocol.attachments.validate(expected) or
                !u.eq(&std.fmt.bytesToHex(verified.digest, .lower), expected.sha256)) continue;
            proof = verified;
        }
        matches += 1;
        found = candidate;
    }
    if (!complete or matches != 1) return publish(core, a, work, null);
    const after = (try snapshot(core, a, work)) orelse return publish(core, a, work, null);
    if (!std.mem.eql(u8, &before.fingerprint, &after.fingerprint)) return publish(core, a, work, null);
    if (proof) |verified| {
        var fingerprint: c.ZrMediaFingerprint = undefined;
        const fd = (try open(core, a, found.?.filename.?, &fingerprint)) orelse return publish(core, a, work, null);
        defer _ = u.c.close(fd);
        if (c.zr_media_same(&verified.fingerprint, &fingerprint) == 0) return publish(core, a, work, null);
    }
    return publish(core, a, work, found);
}

fn receipt(core: *Core, a: u.Allocator, work: Work, mid: []const u8) !bool {
    const anchor = anchor: {
        core.lock();
        defer core.unlock();
        const q = try core.journal.db.prepare("SELECT source,source_row FROM messages WHERE id=?");
        defer q.close();
        try q.bind(&.{.{ .text = mid }});
        if (!try q.step()) return true;
        break :anchor .{ .guid = try q.text(a, 0), .row = q.int(1) };
    };
    // The committed association already proves which payload Messages copied.
    // Follow that source identity for receipts even after newer history grows
    // beyond the discovery budget or Messages evicts its local attachment.
    const echo: Candidate = echo: {
        var source = try Source.open(a, core.source_path);
        defer source.close();
        if (!u.eq(source.identity, work.source_identity)) return true;
        try source.db.exec("BEGIN");
        defer source.db.exec("ROLLBACK") catch {};
        const message = (try source.message(a, anchor.row)) orelse return true;
        if (!u.eq(message.source, anchor.guid) or message.value.direction != .outgoing or
            !u.eq(message.value.service, "imessage")) return true;
        break :echo .{
            .row = message.row,
            .date = message.date,
            .guid = message.source,
            .text = message.value.text orelse "",
            .has_attachments = message.value.attachments.len != 0,
            .status = message.value.observed_status,
            .filename = null,
        };
    };
    return publish(core, a, work, echo);
}

fn publish(core: *Core, a: u.Allocator, work: Work, candidate: ?Candidate) !bool {
    core.lock();
    defer core.unlock();
    const j = core.journal;
    if (!core.read_ready or !u.eq(work.request.server_epoch, try j.epoch(a)) or
        !u.eq(work.source_identity, (try j.progress(a, "identity")) orelse "")) return true;
    var request = try std.json.parseFromSliceLeaky(t.SendRequest, a, (try j.getRecord(a, .request, work.request.request_id)).?, .{});
    const part = &request.parts[work.position];
    switch (part.state) {
        .invoked, .unknown, .submitted => {},
        .queued, .dispatching, .delivered, .failed, .skipped => return true,
    }
    var matched: ?[]const u8 = null;
    if (candidate) |echo| {
        const message = try j.db.prepare("SELECT m.id,m.status FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.source=? AND m.source_row=? AND m.date_ns=? AND m.text=? AND ((?='chat' AND c.route=?) OR (?='direct' AND (SELECT count(*) FROM participants WHERE conversation_id=c.id)=1 AND EXISTS(SELECT 1 FROM participants WHERE conversation_id=c.id AND address=?)))");
        defer message.close();
        try message.bind(&.{
            .{ .text = echo.guid },
            .{ .int = echo.row },
            .{ .int = echo.date },
            .{ .text = echo.text },
            .{ .text = work.mode },
            .{ .text = work.route },
            .{ .text = work.mode },
            .{ .text = work.route },
        });
        if (try message.step() and u.eq(message.bytes(1), @tagName(echo.status))) {
            const mid = try message.text(a, 0);
            if (part.message_id != null or try available(j, a, work, echo, mid)) matched = mid;
        }
    }
    if (part.message_id) |previous| {
        // A confirmed association may follow receipts for only that identity.
        if (!u.eq(previous, matched orelse "")) return true;
    }
    const confirmed = matched != null and u.now() >= work.time + sends.observation_window_ms;
    if (!confirmed and u.eq(part.candidate_message_id orelse "", matched orelse "")) return true;
    if (confirmed and part.state == .submitted and candidate.?.status != .delivered and candidate.?.status != .failed) return true;
    try j.begin();
    errdefer j.rollback();
    if (confirmed) {
        sends.observe(&request, work.position, matched.?, switch (candidate.?.status) {
            .delivered => .delivered,
            .failed => .failed,
            .sent, .unknown => .submitted,
            .received => unreachable, // The source snapshot includes outgoing messages only.
        });
    } else part.candidate_message_id = matched;
    _ = try j.updateRequest(a, request);
    if (confirmed and part.kind == .attachment and part.state == .delivered) {
        // Discovery requires an independent original-byte copy in Messages'
        // attachment root. A committed association preserves that proof for a
        // later delivery receipt; automation returning never supplies it.
        try uploads.releasePart(j, request.request_id, part.attachment_id.?);
    }
    try j.commit();
    return true;
}

fn available(j: Journal, a: u.Allocator, work: Work, candidate: Candidate, mid: []const u8) !bool {
    const claimed = try j.db.prepare("SELECT 1 FROM send_requests WHERE message_id=? UNION ALL SELECT 1 FROM send_parts WHERE message_id=? AND (request_id!=? OR position!=?) LIMIT 1");
    defer claimed.close();
    try claimed.bind(&.{
        .{ .text = mid },
        .{ .text = mid },
        .{ .text = work.request.request_id },
        .{ .int = @intCast(work.position) },
    });
    if (try claimed.step()) return false;
    const text = try j.db.prepare("SELECT 1 FROM send_requests r JOIN messages m ON m.id=? JOIN conversations c ON c.id=m.conversation_id WHERE r.epoch=? AND r.state IN ('dispatching','unknown','submitted') AND r.message_id IS NULL AND m.source_row>r.source_floor AND m.text=json_extract(r.record,'$.text') AND m.date_ns BETWEEN (r.dispatch_ms-2000-978307200000)*1000000 AND (r.dispatch_ms+?-978307200000)*1000000 AND ((r.mode='chat' AND c.route=r.route) OR (r.mode='direct' AND (SELECT count(*) FROM participants WHERE conversation_id=c.id)=1 AND EXISTS(SELECT 1 FROM participants WHERE conversation_id=c.id AND address=r.route))) LIMIT 1");
    defer text.close();
    try text.bind(&.{
        .{ .text = mid },
        .{ .text = work.request.server_epoch },
        .{ .int = sends.observation_window_ms },
    });
    if (try text.step()) return false;
    const q = try j.db.prepare("SELECT r.record,p.position FROM send_parts p JOIN send_requests r ON r.id=p.request_id JOIN messages m ON m.id=? JOIN conversations c ON c.id=m.conversation_id WHERE r.epoch=? AND (p.request_id!=? OR p.position!=?) AND p.state IN ('dispatching','invoked','unknown','submitted') AND p.message_id IS NULL AND m.source_row>p.source_floor AND m.date_ns BETWEEN (p.dispatch_ms-2000-978307200000)*1000000 AND (p.dispatch_ms+?-978307200000)*1000000 AND ((p.mode='chat' AND c.route=p.route) OR (p.mode='direct' AND (SELECT count(*) FROM participants WHERE conversation_id=c.id)=1 AND EXISTS(SELECT 1 FROM participants WHERE conversation_id=c.id AND address=p.route))) LIMIT 257");
    defer q.close();
    try q.bind(&.{
        .{ .text = mid },
        .{ .text = work.request.server_epoch },
        .{ .text = work.request.request_id },
        .{ .int = @intCast(work.position) },
        .{ .int = sends.observation_window_ms },
    });
    var count: usize = 0;
    while (try q.step()) {
        if (count == 256) return false;
        count += 1;
        const other = try std.json.parseFromSliceLeaky(t.SendRequest, a, q.bytes(0), .{});
        const part = other.parts[@intCast(q.int(1))];
        switch (part.kind) {
            .text => if (u.eq(other.text, candidate.text)) return false,
            .attachment => {
                if (!candidate.has_attachments) continue;
                const file = fileFor(work) orelse return false;
                for (other.attachments) |upload| {
                    if (!u.eq(upload.id, part.attachment_id.?)) continue;
                    if (u.eq(file.name, upload.name) and u.eq(file.bytes, upload.bytes) and
                        u.eq(file.sha256, upload.sha256)) return false;
                }
            },
        }
    }
    return true;
}
