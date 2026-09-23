const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol/types.zig");
const Db = @import("Sqlite.zig");
const Self = @This();
db: Db,
changed: ?struct { signal: *@import("../Signal.zig"), io: std.Io } = null,
pub fn open(path: [:0]const u8) !Self {
    const db = try Db.open(path, false);
    errdefer db.close();
    try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
    try db.exec(@embedFile("schema.sql"));
    if (try db.scalar("SELECT count(*) FROM relay_meta") == 0) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var s = try db.prepare("INSERT INTO relay_meta VALUES(1,1,?,0,0)");
        defer s.close();
        try s.bind(&.{.{ .text = try u.id(arena.allocator()) }});
        _ = try s.step();
    }
    if (try db.scalar("SELECT version FROM relay_meta") != 1) return error.SchemaUnsupported;
    return .{ .db = db };
}
pub fn close(self: Self) void {
    self.db.close();
}
pub fn begin(self: Self) !void {
    try self.db.exec("BEGIN IMMEDIATE");
}
pub fn commit(self: Self) !void {
    try self.db.exec("COMMIT");
    if (self.changed) |change| change.signal.notify(change.io);
}
pub fn rollback(self: Self) void {
    self.db.exec("ROLLBACK") catch {};
}
pub fn execute(self: Self, sql: [:0]const u8, args: []const Db.Value) !void {
    var s = try self.db.prepare(sql);
    defer s.close();
    try s.bind(args);
    _ = try s.step();
}
pub fn epoch(self: Self, a: u.Allocator) ![]const u8 {
    var s = try self.db.prepare("SELECT epoch FROM relay_meta");
    defer s.close();
    _ = try s.step();
    return s.text(a, 0);
}
pub fn sequence(self: Self) !i64 {
    return self.db.scalar("SELECT sequence FROM relay_meta");
}
pub fn next(self: Self) !i64 {
    try self.db.exec("UPDATE relay_meta SET sequence=sequence+1");
    return self.sequence();
}
pub fn progress(self: Self, a: u.Allocator, key: []const u8) !?[]const u8 {
    var s = try self.db.prepare("SELECT value FROM ingestion_progress WHERE key=?");
    defer s.close();
    try s.bind(&.{.{ .text = key }});
    return if (try s.step()) try s.text(a, 0) else null;
}
pub fn position(self: Self, a: u.Allocator, key: []const u8) !i64 {
    return std.fmt.parseInt(i64, (try self.progress(a, key)) orelse "0", 10) catch error.DatabaseFailure;
}
pub fn setProgress(self: Self, key: []const u8, value: []const u8) !void {
    try self.execute("INSERT INTO ingestion_progress VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", &.{ .{ .text = key }, .{ .text = value } });
}
pub fn setPosition(self: Self, a: u.Allocator, key: []const u8, n: i64) !void {
    try self.setProgress(key, try u.decimal(a, n));
}
pub fn event(self: Self, seq: i64, kind: []const u8, record: []const u8, origin: []const u8) !void {
    try self.execute("INSERT INTO events(sequence,type,record,origin,created_ms) VALUES(?,?,?,?,?)", &.{ .{ .int = seq }, .{ .text = kind }, .{ .text = record }, .{ .text = origin }, .{ .int = u.now() } });
}
pub fn conversation(self: Self, a: u.Allocator, source: []const u8, row: i64, route: []const u8, value: t.Conversation, origin: []const u8) ![]const u8 {
    var v = value;
    var find = try self.db.prepare("SELECT id,content,source_row,route,service FROM conversations WHERE source=?");
    defer find.close();
    try find.bind(&.{.{ .text = source }});
    const exists = try find.step();
    v.id = if (exists) try find.text(a, 0) else try u.id(a);
    v.revision = "0";
    const content = try u.json(a, v);
    if (exists and u.eq(find.bytes(1), content)) {
        if (find.int(2) != row or !u.eq(find.bytes(3), route) or !u.eq(find.bytes(4), v.service))
            try self.execute("UPDATE conversations SET source_row=?,route=?,service=? WHERE id=?", &.{ .{ .int = row }, .{ .text = route }, .{ .text = v.service }, .{ .text = v.id } });
        return v.id;
    }
    const seq = try self.next();
    v.revision = try u.decimal(a, seq);
    const record = try u.json(a, v);
    try self.execute("INSERT INTO conversations(id,source,source_row,route,service,content,record) VALUES(?,?,?,?,?,?,?) ON CONFLICT(source) DO UPDATE SET source_row=excluded.source_row,route=excluded.route,service=excluded.service,content=excluded.content,record=excluded.record", &.{ .{ .text = v.id }, .{ .text = source }, .{ .int = row }, .{ .text = route }, .{ .text = v.service }, .{ .text = content }, .{ .text = record } });
    try self.execute("DELETE FROM participants WHERE conversation_id=?", &.{.{ .text = v.id }});
    for (v.participants) |address| try self.execute("INSERT OR IGNORE INTO participants VALUES(?,?)", &.{ .{ .text = v.id }, .{ .text = address } });
    try self.event(seq, "conversation.upsert", record, origin);
    return v.id;
}
pub fn message(self: Self, a: u.Allocator, source: []const u8, row: i64, date: i64, value: t.Message, origin: []const u8) !void {
    var v = value;
    var find = try self.db.prepare("SELECT id,content,source_row FROM messages WHERE source=?");
    defer find.close();
    try find.bind(&.{.{ .text = source }});
    const exists = try find.step();
    v.id = if (exists) try find.text(a, 0) else try u.id(a);
    v.revision = "0";
    const content = try u.json(a, v);
    if (exists and u.eq(find.bytes(1), content)) {
        if (find.int(2) != row) try self.execute("UPDATE messages SET source_row=? WHERE id=?", &.{ .{ .int = row }, .{ .text = v.id } });
        return;
    }
    const seq = try self.next();
    v.revision = try u.decimal(a, seq);
    const record = try u.json(a, v);
    try self.execute("INSERT INTO messages(id,source,source_row,conversation_id,date_ns,direction,text,status,content,record) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(source) DO UPDATE SET source_row=excluded.source_row,conversation_id=excluded.conversation_id,date_ns=excluded.date_ns,direction=excluded.direction,text=excluded.text,status=excluded.status,content=excluded.content,record=excluded.record", &.{ .{ .text = v.id }, .{ .text = source }, .{ .int = row }, .{ .text = v.conversation_id }, .{ .int = date }, .{ .text = @tagName(v.direction) }, .{ .text = v.text orelse "" }, .{ .text = @tagName(v.observed_status) }, .{ .text = content }, .{ .text = record } });
    try self.event(seq, "message.upsert", record, origin);
}
pub fn getRecord(self: Self, a: u.Allocator, kind: enum { conversation, request }, id: []const u8) !?[]const u8 {
    var s = try self.db.prepare(if (kind == .conversation) "SELECT record FROM conversations WHERE id=?" else "SELECT record FROM send_requests WHERE id=?");
    defer s.close();
    try s.bind(&.{.{ .text = id }});
    return if (try s.step()) try s.text(a, 0) else null;
}
pub const Route = struct { mode: []const u8, destination: []const u8 };
pub fn getRoute(self: Self, a: u.Allocator, target: t.Target) !Route {
    if (target.recipient) |r| return .{ .mode = "direct", .destination = r.address };
    var s = try self.db.prepare("SELECT route,service FROM conversations WHERE id=?");
    defer s.close();
    try s.bind(&.{.{ .text = target.conversation_id.? }});
    if (!try s.step() or !u.eq(s.bytes(1), "imessage")) return error.UnsupportedTarget;
    return .{ .mode = "chat", .destination = try s.text(a, 0) };
}
pub fn accept(self: Self, a: u.Allocator, raw_input: t.SendInput, ready: bool) !struct { record: []const u8, fresh: bool } {
    const input = try t.normalize(a, raw_input);
    try self.begin();
    errdefer self.rollback();
    if (!u.eq(input.server_epoch, try self.epoch(a))) return error.ResyncRequired;
    const payload = try u.json(a, input);
    var s = try self.db.prepare("SELECT payload,record FROM send_requests WHERE id=?");
    defer s.close();
    try s.bind(&.{.{ .text = input.request_id }});
    if (try s.step()) {
        if (!u.eq(s.bytes(0), payload)) return error.RequestConflict;
        const existing = try s.text(a, 1);
        try self.commit();
        return .{ .record = existing, .fresh = false };
    }
    if (!ready) return error.AdapterUnavailable;
    const r = try self.getRoute(a, input.target);
    const v: t.SendRequest = .{ .request_id = input.request_id, .server_epoch = input.server_epoch, .target = input.target, .text = input.text };
    try self.execute("INSERT INTO send_requests(id,epoch,payload,record,state,mode,route,accepted_ms) VALUES(?,?,?,?,'queued',?,?,?)", &.{ .{ .text = input.request_id }, .{ .text = input.server_epoch }, .{ .text = payload }, .{ .text = try u.json(a, v) }, .{ .text = r.mode }, .{ .text = r.destination }, .{ .int = u.now() } });
    const record_json = try self.updateRequest(a, v);
    try self.commit();
    return .{ .record = record_json, .fresh = true };
}
pub fn updateRequest(self: Self, a: u.Allocator, value: t.SendRequest) ![]const u8 {
    var v = value;
    const seq = try self.next();
    v.revision = try u.decimal(a, seq);
    const record_json = try u.json(a, v);
    try self.execute("UPDATE send_requests SET state=?,record=?,message_id=? WHERE id=?", &.{ .{ .text = @tagName(v.state) }, .{ .text = record_json }, if (v.message_id) |m| .{ .text = m } else .null_value, .{ .text = v.request_id } });
    try self.event(seq, "send_request.updated", record_json, "reconciliation");
    return record_json;
}
pub fn recover(self: Self, a: u.Allocator) !void {
    try self.begin();
    errdefer self.rollback();
    var s = try self.db.prepare("SELECT record FROM send_requests WHERE state='dispatching'");
    defer s.close();
    var items: std.ArrayList(t.SendRequest) = .empty;
    while (try s.step()) try items.append(a, (try std.json.parseFromSlice(t.SendRequest, a, s.bytes(0), .{ .allocate = .alloc_always })).value);
    for (items.items) |item| {
        var v = item;
        v.state = .unknown;
        v.error_info = .{ .code = "interrupted_dispatch", .message = "Dispatch was interrupted; delivery is uncertain.", .outcome = .uncertain };
        _ = try self.updateRequest(a, v);
    }
    try self.commit();
}
pub fn reset(self: Self, a: u.Allocator) !void {
    // Caller owns a transaction. Preserve all idempotency identities, hold queued sends.
    var s = try self.db.prepare("SELECT record FROM send_requests WHERE state IN ('queued','dispatching','submitted','unknown')");
    defer s.close();
    var items: std.ArrayList(t.SendRequest) = .empty;
    while (try s.step()) try items.append(a, (try std.json.parseFromSlice(t.SendRequest, a, s.bytes(0), .{ .allocate = .alloc_always })).value);
    try self.execute("UPDATE relay_meta SET epoch=?,sequence=0,pruned_through=0", &.{.{ .text = try u.id(a) }});
    try self.db.exec("DELETE FROM events; DELETE FROM participants; DELETE FROM messages; DELETE FROM conversations; DELETE FROM ingestion_progress; DELETE FROM pending_source; DELETE FROM reconcile_chats;");
    for (items.items) |item| {
        var v = item;
        v.state = .unknown;
        v.message_id = null;
        v.error_info = .{ .code = "source_reset", .message = "Source changed; this request is held for review.", .outcome = .uncertain };
        _ = try self.updateRequest(a, v);
    }
}
pub fn checkCursor(self: Self, a: u.Allocator, cursor: []const u8) !i64 {
    const seq = try t.parseCursor(cursor, try self.epoch(a));
    if (seq > try self.sequence()) return error.ResyncRequired;
    if (seq < try self.db.scalar("SELECT pruned_through FROM relay_meta")) return error.CursorExpired;
    return seq;
}
pub fn prune(self: Self, count_limit: i64) !void {
    try self.begin();
    errdefer self.rollback();
    var s = try self.db.prepare("SELECT coalesce(max(sequence),0) FROM events WHERE created_ms<? OR sequence<=(SELECT sequence FROM relay_meta)-?");
    defer s.close();
    try s.bind(&.{ .{ .int = u.now() - 7 * 24 * 60 * 60 * 1000 }, .{ .int = count_limit } });
    _ = try s.step();
    const cut = s.int(0);
    try self.execute("UPDATE relay_meta SET pruned_through=max(pruned_through,?)", &.{.{ .int = cut }});
    try self.execute("DELETE FROM events WHERE sequence<=?", &.{.{ .int = cut }});
    try self.commit();
}
pub const Page = struct { records: []std.json.Value, next: ?[]const u8 };
pub fn page(self: Self, a: u.Allocator, conversation_id: ?[]const u8, before: ?[]const u8, limit: usize) !Page {
    var s = try self.db.prepare(if (conversation_id != null)
        "SELECT record,date_ns,id FROM messages WHERE conversation_id=? AND (date_ns<? OR (date_ns=? AND id<?)) ORDER BY date_ns DESC,id DESC LIMIT ?"
    else
        "SELECT record,0,id FROM conversations WHERE id<? ORDER BY id DESC LIMIT ?");
    defer s.close();
    if (conversation_id) |id| {
        var date: i64 = std.math.maxInt(i64);
        var key: []const u8 = "~";
        if (before) |b| {
            const split = std.mem.indexOfScalar(u8, b, ':') orelse return error.InvalidRequest;
            date = std.fmt.parseInt(i64, b[0..split], 10) catch return error.InvalidRequest;
            key = b[split + 1 ..];
            if (!t.uuid(key)) return error.InvalidRequest;
        }
        try s.bind(&.{ .{ .text = id }, .{ .int = date }, .{ .int = date }, .{ .text = key }, .{ .int = @intCast(limit + 1) } });
    } else try s.bind(&.{ .{ .text = before orelse "~" }, .{ .int = @intCast(limit + 1) } });
    var items: std.ArrayList(std.json.Value) = .empty;
    var next_key: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    while (try s.step()) {
        if (items.items.len == limit) {
            next_key = last;
            break;
        }
        try items.append(a, (try std.json.parseFromSlice(std.json.Value, a, s.bytes(0), .{ .allocate = .alloc_always })).value);
        last = if (conversation_id != null) try std.fmt.allocPrint(a, "{d}:{s}", .{ s.int(1), s.bytes(2) }) else try s.text(a, 2);
    }
    return .{ .records = try items.toOwnedSlice(a), .next = next_key };
}
pub const Frame = struct { sequence: i64, frame: []const u8 };
pub fn previews(self: Self, a: u.Allocator, before: ?[]const u8, limit: usize) ![]t.ConversationPreview {
    // The same conversation page, with one indexed latest-message lookup per
    // chat. Keep payloads small without ever truncating canonical messages.
    var q = try self.db.prepare("SELECT m.conversation_id,m.id,json_extract(m.record,'$.revision'),json_extract(m.record,'$.timestamp'),json_extract(m.record,'$.kind'),substr(m.text,1,256) FROM conversations c LEFT JOIN messages m ON m.id=(SELECT id FROM messages WHERE conversation_id=c.id ORDER BY date_ns DESC,id DESC LIMIT 1) WHERE c.id<? ORDER BY c.id DESC LIMIT ?");
    defer q.close();
    try q.bind(&.{ .{ .text = before orelse "~" }, .{ .int = @intCast(limit) } });
    var result: std.ArrayList(t.ConversationPreview) = .empty;
    while (try q.step()) {
        if (q.bytes(1).len == 0) continue;
        try result.append(a, .{ .conversation_id = try q.text(a, 0), .message_id = try q.text(a, 1), .revision = try q.text(a, 2), .timestamp = try q.text(a, 3), .kind = try q.text(a, 4), .text = try q.text(a, 5) });
    }
    return result.toOwnedSlice(a);
}
pub fn events(self: Self, a: u.Allocator, after: i64) ![]const Frame {
    var s = try self.db.prepare("SELECT sequence,type,record,origin FROM events WHERE sequence>? ORDER BY sequence LIMIT 100");
    defer s.close();
    try s.bind(&.{.{ .int = after }});
    var items: std.ArrayList(Frame) = .empty;
    const e = try self.epoch(a);
    while (try s.step()) {
        const seq = s.int(0);
        const cur = try t.cursor(a, e, seq);
        const record_value = (try std.json.parseFromSlice(std.json.Value, a, s.bytes(2), .{ .allocate = .alloc_always })).value;
        const data = try u.json(a, .{ .cursor = cur, .sequence = try u.decimal(a, seq), .type = s.bytes(1), .record = record_value, .origin = s.bytes(3) });
        try items.append(a, .{ .sequence = seq, .frame = try std.fmt.allocPrint(a, "id: {s}\nevent: {s}\ndata: {s}\n\n", .{ cur, s.bytes(1), data }) });
    }
    return items.toOwnedSlice(a);
}

test "subscribers are notified only after a successful durable commit" {
    var signal = @import("../Signal.zig"){};
    var j = try Self.open(":memory:");
    defer j.close();
    j.changed = .{ .signal = &signal, .io = std.testing.io };
    const before = signal.observe();
    try j.begin();
    try j.db.exec("PRAGMA defer_foreign_keys=ON; INSERT INTO participants VALUES('missing','fixture')");
    try std.testing.expectError(error.DatabaseFailure, j.commit());
    try std.testing.expectEqual(before, signal.observe());
    j.rollback();
    try j.begin();
    try j.commit();
    try std.testing.expect(signal.observe() != before);
}

test "atomic ingestion rollback preserves progress, records, and event sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Self.open(":memory:");
    defer j.close();
    try j.begin();
    _ = try j.conversation(a, "private-chat", 1, "iMessage;-;fixture", .{ .service = "imessage" }, "historical_import");
    try j.setPosition(a, "live", 99);
    j.rollback();
    try std.testing.expectEqual(@as(i64, 0), try j.sequence());
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM conversations"));
    try std.testing.expectEqual(@as(i64, 0), try j.position(a, "live"));
    try j.begin();
    const id = try j.conversation(a, "private-chat", 1, "iMessage;-;fixture", .{ .service = "imessage" }, "historical_import");
    try j.commit();
    const seq = try j.sequence();
    try j.begin();
    const same = try j.conversation(a, "private-chat", 2, "iMessage;-;fixture", .{ .service = "imessage" }, "reconciliation");
    try j.commit();
    try std.testing.expectEqualStrings(id, same);
    try std.testing.expectEqual(@as(i64, 2), try j.db.scalar("SELECT source_row FROM conversations"));
    try std.testing.expectEqual(seq, try j.sequence());
    const value = t.Message{ .conversation_id = id, .sender = "fixture", .direction = .incoming, .service = "imessage", .timestamp = "2026-01-01T00:00:00Z", .kind = .text, .text = "Fixture", .decoding = .plain, .observed_status = .received };
    try j.message(a, "private-message", 3, 1, value, "historical_import");
    const message_seq = try j.sequence();
    try j.message(a, "private-message", 4, 1, value, "reconciliation");
    try std.testing.expectEqual(@as(i64, 4), try j.db.scalar("SELECT source_row FROM messages"));
    try std.testing.expectEqual(message_seq, try j.sequence());
    const changes = u.c.sqlite3_total_changes64(j.db.handle);
    _ = try j.conversation(a, "private-chat", 2, "iMessage;-;fixture", .{ .service = "imessage" }, "reconciliation");
    try j.message(a, "private-message", 4, 1, value, "reconciliation");
    try std.testing.expectEqual(changes, u.c.sqlite3_total_changes64(j.db.handle));
}
test "durable sends retain idempotency after recovery and event pruning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Self.open(":memory:");
    defer j.close();
    var input: t.SendInput = .{ .request_id = try u.id(a), .server_epoch = try j.epoch(a), .target = .{ .recipient = .{ .address = "fixture@example.invalid", .service = "imessage" } }, .text = "hello\n👩‍💻" };
    try std.testing.expect((try j.accept(a, input, true)).fresh);
    try std.testing.expect(!(try j.accept(a, input, false)).fresh);
    const original = input.text;
    input.text = "changed";
    try std.testing.expectError(error.RequestConflict, j.accept(a, input, true));
    input.text = original;
    var v = (try std.json.parseFromSlice(t.SendRequest, a, (try j.getRecord(a, .request, input.request_id)).?, .{})).value;
    try j.begin();
    v.state = .dispatching;
    _ = try j.updateRequest(a, v);
    try j.commit();
    try j.recover(a);
    const recovered = (try std.json.parseFromSlice(t.SendRequest, a, (try j.getRecord(a, .request, input.request_id)).?, .{})).value;
    try std.testing.expectEqual(t.SendState.unknown, recovered.state);
    try j.prune(0);
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM events"));
    try std.testing.expect(!(try j.accept(a, input, true)).fresh);
    const old = try t.cursor(a, input.server_epoch, 0);
    try std.testing.expectError(error.CursorExpired, j.checkCursor(a, old));
    try j.begin();
    try j.reset(a);
    try j.commit();
    try std.testing.expectError(error.ResyncRequired, j.accept(a, input, true));
    try std.testing.expectEqual(@as(i64, 1), try j.db.scalar("SELECT count(*) FROM send_requests"));
}
test "failed journal acceptance never leaves a queued send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Self.open(":memory:");
    defer j.close();
    try j.db.exec("CREATE TRIGGER fail_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'injected failure'); END");
    const input: t.SendInput = .{ .request_id = try u.id(a), .server_epoch = try j.epoch(a), .target = .{ .recipient = .{ .address = "fixture@example.invalid", .service = "imessage" } }, .text = "never dispatched" };
    try std.testing.expectError(error.DatabaseFailure, j.accept(a, input, true));
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM send_requests"));
    try std.testing.expectEqual(@as(i64, 0), try j.sequence());
}
