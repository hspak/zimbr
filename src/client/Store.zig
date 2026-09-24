const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol/types.zig");
const Sqlite = @import("../relay/Sqlite.zig");
const Directory = @import("IdentityDirectory.zig");
const display = @import("display.zig");
const Self = @This();
db: Sqlite,
pub fn open(path: [:0]const u8) !Self {
    const db = try Sqlite.open(path, false);
    errdefer db.close();
    try db.exec(
        \\PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        \\CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        \\CREATE TABLE IF NOT EXISTS enrichment_cache(message_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,record TEXT NOT NULL,serial INTEGER NOT NULL);
        \\CREATE TABLE IF NOT EXISTS enrichment_pages(message_id TEXT NOT NULL,section TEXT NOT NULL,revision TEXT NOT NULL,items TEXT NOT NULL,next TEXT,PRIMARY KEY(message_id,section));
        \\CREATE TABLE IF NOT EXISTS identities(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,service TEXT NOT NULL,address TEXT NOT NULL,record TEXT NOT NULL,UNIQUE(service,address));
        \\CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,chat TEXT NOT NULL,sort_key TEXT NOT NULL,record TEXT NOT NULL,PRIMARY KEY(kind,id));
        \\CREATE INDEX IF NOT EXISTS history ON records(kind,chat,sort_key,id);
        \\CREATE TABLE IF NOT EXISTS drafts(key TEXT PRIMARY KEY,text TEXT NOT NULL);
        \\CREATE TABLE IF NOT EXISTS unread(chat TEXT PRIMARY KEY,count INTEGER NOT NULL);
        \\CREATE TABLE IF NOT EXISTS hidden_chats(key TEXT PRIMARY KEY);
        \\CREATE TABLE IF NOT EXISTS live_seen(id TEXT PRIMARY KEY);
        \\CREATE TABLE IF NOT EXISTS pages(chat TEXT PRIMARY KEY,cursor TEXT);
        \\CREATE TABLE IF NOT EXISTS previews(chat TEXT PRIMARY KEY);
        \\CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY,epoch TEXT NOT NULL,draft_key TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,detail TEXT NOT NULL DEFAULT '',record TEXT);
    );
    if (try db.scalar("SELECT count(*) FROM pragma_table_info('previews') WHERE name='record'") == 0) try db.exec("ALTER TABLE previews ADD COLUMN record TEXT");
    if (try db.scalar("SELECT count(*) FROM pragma_table_info('outbox') WHERE name='sent_at'") == 0) {
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {};
        try db.exec("ALTER TABLE outbox ADD COLUMN sent_at TEXT NOT NULL DEFAULT ''");
        // Older clients did not save send times. Estimate once from a linked
        // echo or nearby records in the relay's revision sequence, then keep
        // that position stable across status updates and restarts.
        try db.exec(
            \\UPDATE outbox SET sent_at=coalesce(
            \\ (SELECT sort_key FROM records WHERE kind='message' AND id=coalesce(json_extract(outbox.record,'$.message_id'),json_extract(outbox.record,'$.candidate_message_id'))),
            \\ (SELECT sort_key FROM records WHERE kind='message' AND chat=outbox.draft_key
            \\   AND outbox.epoch=(SELECT value FROM meta WHERE key='epoch')
            \\   AND revision<=CAST(json_extract(outbox.record,'$.revision') AS INTEGER) ORDER BY revision DESC,sort_key DESC LIMIT 1),
            \\ (SELECT sort_key FROM records WHERE kind='message' AND chat=outbox.draft_key
            \\   AND outbox.epoch=(SELECT value FROM meta WHERE key='epoch')
            \\   AND revision>CAST(json_extract(outbox.record,'$.revision') AS INTEGER) ORDER BY revision,sort_key LIMIT 1),
            \\ (SELECT sort_key FROM records WHERE kind='message' AND chat=outbox.draft_key ORDER BY sort_key DESC LIMIT 1),
            \\ strftime('%Y-%m-%dT%H:%M:%f000000Z','now'))
        );
        try db.exec("COMMIT");
    }
    return .{ .db = db };
}
pub fn close(s: Self) void {
    s.db.close();
}
pub fn exec(s: Self, sql: [:0]const u8, values: []const Sqlite.Value) !void {
    var q = try s.db.prepare(sql);
    defer q.close();
    try q.bind(values);
    _ = try q.step();
}
pub fn get(s: Self, a: u.Allocator, key: []const u8) ![]const u8 {
    var q = try s.db.prepare("SELECT value FROM meta WHERE key=?");
    defer q.close();
    try q.bind(&.{.{ .text = key }});
    return if (try q.step()) try q.text(a, 0) else "";
}
pub fn set(s: Self, key: []const u8, value: []const u8) !void {
    try s.exec("INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", &.{ .{ .text = key }, .{ .text = value } });
}
pub fn draft(s: Self, a: u.Allocator, key: []const u8) ![]const u8 {
    var q = try s.db.prepare("SELECT text FROM drafts WHERE key=?");
    defer q.close();
    try q.bind(&.{.{ .text = key }});
    return if (try q.step()) try q.text(a, 0) else "";
}
pub fn saveDraft(s: Self, key: []const u8, value: []const u8) !void {
    if (value.len > t.max_text or !std.unicode.utf8ValidateSlice(value)) return error.InvalidDraft;
    try s.exec("INSERT INTO drafts VALUES(?,?) ON CONFLICT(key) DO UPDATE SET text=excluded.text", &.{ .{ .text = key }, .{ .text = value } });
}
pub fn read(s: Self, chat: []const u8) !void {
    try s.exec("DELETE FROM unread WHERE chat=?", &.{.{ .text = chat }});
}
pub fn setHidden(s: Self, key: []const u8, hidden: bool) !void {
    if (key.len == 0) return error.InvalidConversation;
    try s.exec(if (hidden) "INSERT OR IGNORE INTO hidden_chats VALUES(?)" else "DELETE FROM hidden_chats WHERE key=?", &.{.{ .text = key }});
}
pub fn beginSync(s: Self, epoch: []const u8, cursor: []const u8) !void {
    if (!t.uuid(epoch)) return error.InvalidEpoch;
    _ = try t.parseCursor(cursor, epoch);
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    // Drafts and original outbox identities survive reset. Old messages are kept
    // visible while offline; once a fresh sync begins only reconciled records show.
    try s.db.exec("DELETE FROM enrichment_pages; DELETE FROM enrichment_cache; DELETE FROM identities; DELETE FROM records; DELETE FROM unread; DELETE FROM live_seen; DELETE FROM pages; DELETE FROM previews;");
    try s.exec("UPDATE outbox SET state='unknown',detail='Relay changed. This request will not be sent again automatically.' WHERE epoch!=? AND state NOT IN ('delivered','failed')", &.{.{ .text = epoch }});
    try s.set("epoch", epoch);
    try s.set("cursor", cursor);
    try s.set("bootstrapped", "0");
    try s.set("identity_bootstrapped", "0");
    try s.set("accepted_extensions", "");
    try s.db.exec("COMMIT");
}
pub fn upsert(s: Self, a: u.Allocator, kind: []const u8, raw: []const u8) !bool {
    if (u.eq(kind, "identity")) {
        const v = try std.json.parseFromSliceLeaky(t.Identity, a, raw, .{ .ignore_unknown_fields = true });
        const revision = try std.fmt.parseInt(i64, v.revision, 10);
        if (revision < 0 or v.id.len == 0 or v.service.len == 0 or v.address.len == 0) return error.InvalidRecord;
        try s.exec("INSERT INTO identities VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,record=excluded.record WHERE excluded.revision>identities.revision AND excluded.service=identities.service AND excluded.address=identities.address", &.{ .{ .text = v.id }, .{ .int = revision }, .{ .text = v.service }, .{ .text = v.address }, .{ .text = raw } });
        return u.c.sqlite3_changes(s.db.handle) > 0;
    }
    var id: []const u8 = undefined;
    var rev: []const u8 = undefined;
    var chat: []const u8 = "";
    var sort: []const u8 = "";
    if (u.eq(kind, "conversation")) {
        const v = (try std.json.parseFromSlice(t.Conversation, a, raw, .{ .ignore_unknown_fields = true })).value;
        id = v.id;
        rev = v.revision;
        sort = v.last_activity orelse "";
    } else if (u.eq(kind, "message")) {
        const v = (try std.json.parseFromSlice(t.Message, a, raw, .{ .ignore_unknown_fields = true })).value;
        id = v.id;
        rev = v.revision;
        chat = v.conversation_id;
        sort = v.timestamp;
    } else if (u.eq(kind, "request")) {
        const v = (try std.json.parseFromSlice(t.SendRequest, a, raw, .{ .ignore_unknown_fields = true })).value;
        id = v.request_id;
        rev = v.revision;
        chat = v.target.conversation_id orelse "";
        const epoch = try s.get(a, "epoch");
        if (!u.eq(epoch, v.server_epoch)) return false;
    } else return error.InvalidRecord;
    const revision = try std.fmt.parseInt(i64, rev, 10);
    if (revision < 0 or id.len == 0) return error.InvalidRecord;
    var existing = try s.db.prepare("SELECT revision,record FROM records WHERE kind=? AND id=?");
    defer existing.close();
    try existing.bind(&.{ .{ .text = kind }, .{ .text = id } });
    const fresh = !(try existing.step());
    if (!fresh and existing.int(0) >= revision) {
        if (u.eq(kind, "request")) try s.requestState(a, existing.bytes(1));
        return false;
    }
    try s.exec("INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision,chat=excluded.chat,sort_key=excluded.sort_key,record=excluded.record", &.{ .{ .text = kind }, .{ .text = id }, .{ .int = revision }, .{ .text = chat }, .{ .text = sort }, .{ .text = raw } });
    if (u.eq(kind, "message")) {
        try s.exec("DELETE FROM enrichment_cache WHERE message_id=?", &.{.{ .text = id }});
        try s.exec("DELETE FROM enrichment_pages WHERE message_id=?", &.{.{ .text = id }});
    }
    if (u.eq(kind, "request")) try s.requestState(a, raw);
    return fresh;
}
fn requestState(s: Self, a: u.Allocator, raw: []const u8) !void {
    const v = (try std.json.parseFromSlice(t.SendRequest, a, raw, .{ .ignore_unknown_fields = true })).value;
    try s.exec("UPDATE outbox SET state=?,detail=?,record=? WHERE id=?", &.{ .{ .text = @tagName(v.state) }, .{ .text = if (v.error_info) |e| e.message else "" }, .{ .text = raw }, .{ .text = v.request_id } });
}
pub const Event = struct { cursor: []const u8, sequence: []const u8, type: []const u8, origin: []const u8, record: std.json.Value };
pub fn event(s: Self, a: u.Allocator, raw: []const u8, frame_id: []const u8, frame_type: []const u8, viewed: []const u8) !void {
    _ = try s.eventNotification(a, raw, frame_id, frame_type, viewed);
}
// The returned message is only eligible for delivery AFTER the caller's batch
// transaction commits. Its strings belong to a, just like parsed event records.
pub fn eventNotification(s: Self, a: u.Allocator, raw: []const u8, frame_id: []const u8, frame_type: []const u8, viewed: []const u8) !?t.Message {
    const e = (try std.json.parseFromSlice(Event, a, raw, .{ .ignore_unknown_fields = true })).value;
    const epoch = try s.get(a, "epoch");
    const seq = try t.parseCursor(e.cursor, epoch);
    if (!u.eq(e.cursor, frame_id) or !u.eq(e.type, frame_type) or seq != try std.fmt.parseInt(i64, e.sequence, 10)) return error.InvalidEvent;
    if (seq <= try t.parseCursor(try s.get(a, "cursor"), epoch)) return null;
    const kind = if (u.eq(e.type, "conversation.upsert")) "conversation" else if (u.eq(e.type, "message.upsert")) "message" else if (u.eq(e.type, "send_request.updated")) "request" else if (u.eq(e.type, "identity.upsert") and u.eq(try s.get(a, "accepted_extensions"), "identity-v1")) "identity" else return error.UnknownEvent;
    const record = try u.json(a, e.record);
    // The network worker may own a batch transaction. Standalone callers keep
    // the same atomic record/cursor guarantee for an individual event.
    const owns_transaction = u.c.sqlite3_get_autocommit(s.db.handle) != 0;
    if (owns_transaction) try s.db.exec("BEGIN IMMEDIATE");
    errdefer if (owns_transaction) s.db.exec("ROLLBACK") catch {};
    _ = try s.upsert(a, kind, record);
    var notification: ?t.Message = null;
    if (u.eq(kind, "message")) {
        const m = (try std.json.parseFromSlice(t.Message, a, record, .{ .ignore_unknown_fields = true })).value;
        if (m.direction == .incoming and m.kind != .reaction and m.reaction_event == null) {
            try s.exec("INSERT OR IGNORE INTO live_seen VALUES(?)", &.{.{ .text = m.id }});
            const first = u.c.sqlite3_changes(s.db.handle) > 0;
            if (first and u.eq(e.origin, "live") and !u.eq(m.conversation_id, viewed)) {
                try s.exec("INSERT INTO unread VALUES(?,1) ON CONFLICT(chat) DO UPDATE SET count=count+1", &.{.{ .text = m.conversation_id }});
                notification = m;
            }
        }
    }
    try s.set("cursor", e.cursor);
    if (owns_transaction) try s.db.exec("COMMIT");
    return notification;
}
pub fn persistSend(s: Self, a: u.Allocator, key: []const u8, input: t.SendInput) !void {
    try t.validate(input);
    if (!u.eq(input.server_epoch, try s.get(a, "epoch"))) return error.StaleEpoch;
    const payload = try u.json(a, input);
    const sent_at = try u.timestamp(a, (u.now() - 978307200000) * 1000000);
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    try s.exec("INSERT INTO outbox(id,epoch,draft_key,payload,state,sent_at) VALUES(?,?,?,?,'sending',?)", &.{ .{ .text = input.request_id }, .{ .text = input.server_epoch }, .{ .text = key }, .{ .text = payload }, .{ .text = sent_at } });
    try s.saveDraft(key, "");
    try s.db.exec("COMMIT");
}
pub fn outcome(s: Self, id: []const u8, state: []const u8, detail: []const u8) !void {
    // A late HTTP failure must not overwrite a request already received via SSE.
    try s.exec("UPDATE outbox SET state=?,detail=? WHERE id=? AND record IS NULL", &.{ .{ .text = state }, .{ .text = detail }, .{ .text = id } });
}
pub fn page(s: Self, chat: []const u8, cursor: ?[]const u8) !void {
    try s.exec("INSERT INTO pages VALUES(?,?) ON CONFLICT(chat) DO UPDATE SET cursor=excluded.cursor", &.{ .{ .text = chat }, if (cursor) |v| .{ .text = v } else .null_value });
}
pub fn savePreview(s: Self, a: u.Allocator, raw: []const u8) !void {
    const value = (try std.json.parseFromSlice(t.ConversationPreview, a, raw, .{ .ignore_unknown_fields = true })).value;
    const revision = std.fmt.parseInt(i64, value.revision, 10) catch return error.InvalidRecord;
    if (revision < 0 or value.conversation_id.len == 0 or value.message_id.len == 0 or value.text.len > 1024) return error.InvalidRecord;
    try s.exec("INSERT INTO previews(chat,record) VALUES(?,?) ON CONFLICT(chat) DO UPDATE SET record=excluded.record WHERE previews.record IS NULL OR CAST(json_extract(excluded.record,'$.revision') AS INTEGER)>CAST(json_extract(previews.record,'$.revision') AS INTEGER)", &.{ .{ .text = value.conversation_id }, .{ .text = raw } });
}
pub fn nextPage(s: Self, a: u.Allocator, chat: []const u8) !?[]const u8 {
    var q = try s.db.prepare("SELECT cursor FROM pages WHERE chat=?");
    defer q.close();
    try q.bind(&.{.{ .text = chat }});
    if (!try q.step()) return "";
    return if (q.bytes(0).len == 0) null else try q.text(a, 0);
}
pub const Chat = struct { value: t.Conversation, preview: []const u8, unread: i64, hidden: bool = false };
pub const Pending = struct { input: t.SendInput, state: []const u8, detail: []const u8, record: ?t.SendRequest, sent_at: []const u8 };
pub const Snapshot = struct {
    chats: []const Chat,
    messages: []const t.Message,
    pending: []const Pending,
    selected: []const u8,
    draft: []const u8,
    epoch: []const u8,
    more: bool,
    directory: Directory = .{},
};
pub fn snapshot(s: Self, a: u.Allocator, selected: []const u8) !Snapshot {
    return s.snapshotWithMessages(a, selected, null);
}
// A shared history owns these immutable messages for at least this snapshot's
// lifetime. Other callers can still request a fully arena-owned snapshot.
pub fn snapshotWithMessages(s: Self, a: u.Allocator, selected: []const u8, shared_messages: ?[]const t.Message) !Snapshot {
    var chats: std.ArrayList(Chat) = .empty;
    var messages: std.ArrayList(t.Message) = .empty;
    var pending: std.ArrayList(Pending) = .empty;
    var q = try s.db.prepare("SELECT c.record,coalesce(u.count,0),(SELECT m.record FROM records m WHERE m.kind='message' AND m.chat=c.id AND coalesce(json_extract(m.record,'$.reaction_event.resolution'),'')!='resolved' ORDER BY m.sort_key DESC,m.id DESC LIMIT 1),p.record,EXISTS(SELECT 1 FROM hidden_chats h WHERE h.key=c.id) FROM records c LEFT JOIN unread u ON c.id=u.chat LEFT JOIN previews p ON p.chat=c.id WHERE c.kind='conversation' ORDER BY c.sort_key DESC,c.id DESC");
    defer q.close();
    while (try q.step()) {
        const v = (try std.json.parseFromSlice(t.Conversation, a, q.bytes(0), .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value;
        var preview: []const u8 = if (v.last_activity != null) "History not loaded" else "No messages yet";
        var latest: ?t.Message = null;
        if (q.bytes(2).len > 0) {
            const m = (try std.json.parseFromSlice(t.Message, a, q.bytes(2), .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value;
            latest = m;
            preview = display.summary(a, m);
        }
        if (q.bytes(3).len > 0) {
            const p = (try std.json.parseFromSlice(t.ConversationPreview, a, q.bytes(3), .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
            const newer_position = latest == null or std.mem.order(u8, p.timestamp, latest.?.timestamp) == .gt or
                (u.eq(p.timestamp, latest.?.timestamp) and std.mem.order(u8, p.message_id, latest.?.id) == .gt);
            const newer_revision = latest != null and u.eq(p.message_id, latest.?.id) and (try std.fmt.parseInt(i64, p.revision, 10)) > (try std.fmt.parseInt(i64, latest.?.revision, 10));
            if (newer_position or newer_revision) preview = if (p.text.len > 0) p.text else p.kind;
        }
        try chats.append(a, .{ .value = v, .preview = preview, .unread = q.int(1), .hidden = q.int(4) != 0 });
    }
    // Local drafts without a current server conversation remain discoverable
    // after an epoch reset or while composing a new direct conversation.
    var drafts = try s.db.prepare("SELECT key,EXISTS(SELECT 1 FROM hidden_chats h WHERE h.key=local.key) FROM (SELECT key FROM drafts WHERE text!='' UNION SELECT draft_key AS key FROM outbox WHERE state!='delivered') local WHERE NOT EXISTS(SELECT 1 FROM records WHERE kind='conversation' AND id=local.key)");
    defer drafts.close();
    while (try drafts.step()) {
        const key = try drafts.text(a, 0);
        try chats.append(a, .{ .value = .{ .id = key, .title = if (std.mem.startsWith(u8, key, "new:")) key[4..] else "Recovered draft", .service = "imessage" }, .preview = "Saved locally · drafts and send history", .unread = 0, .hidden = drafts.int(1) != 0 });
    }
    // Separate chat history from linked send echoes so SQLite can use the
    // ordered history index instead of scanning every cached conversation.
    if (shared_messages == null) {
        var ms = try s.db.prepare(history_query);
        defer ms.close();
        try ms.bind(&.{ .{ .text = selected }, .{ .text = selected }, .{ .text = selected } });
        while (try ms.step()) try messages.append(a, (try std.json.parseFromSlice(t.Message, a, ms.bytes(0), .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value);
    }
    // The observed echo supplies the sole visible status, including while the
    // relay finishes checking a provisional match. Keep the durable request
    // unchanged so withdrawing the hint restores its unresolved bubble.
    var ps = try s.db.prepare("SELECT payload,state,detail,record,sent_at FROM outbox WHERE draft_key=? AND NOT EXISTS(SELECT 1 FROM records m WHERE m.kind='message' AND m.id=" ++ echo_id_sql ++ ") ORDER BY rowid");
    defer ps.close();
    try ps.bind(&.{.{ .text = selected }});
    while (try ps.step()) {
        const record = if (ps.bytes(3).len > 0) (try std.json.parseFromSlice(t.SendRequest, a, ps.bytes(3), .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value else null;
        try pending.append(a, .{ .input = (try std.json.parseFromSlice(t.SendInput, a, ps.bytes(0), .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value, .state = try ps.text(a, 1), .detail = try ps.text(a, 2), .record = record, .sent_at = try ps.text(a, 4) });
    }
    return .{ .chats = chats.items, .messages = shared_messages orelse messages.items, .pending = pending.items, .selected = try a.dupe(u8, selected), .draft = try s.draft(a, selected), .epoch = try s.get(a, "epoch"), .more = (try s.nextPage(a, selected)) != null, .directory = try s.directory(a) };
}
const echo_id_sql = "coalesce(json_extract(outbox.record,'$.message_id'),CASE WHEN outbox.state='unknown' AND outbox.epoch=(SELECT value FROM meta WHERE key='epoch') THEN json_extract(outbox.record,'$.candidate_message_id') END)";
const enriched_record = "coalesce((SELECT e.record FROM enrichment_cache e WHERE e.message_id=records.id AND e.revision=records.revision),record)";
const enrichment_serial = "coalesce((SELECT e.serial FROM enrichment_cache e WHERE e.message_id=records.id AND e.revision=records.revision),0)";
pub const history_query = "SELECT " ++ enriched_record ++ ",id,revision,sort_key," ++ enrichment_serial ++ " FROM records WHERE kind='message' AND chat=? UNION ALL SELECT " ++ enriched_record ++ ",id,revision,sort_key," ++ enrichment_serial ++ " FROM records WHERE kind='message' AND chat!=? AND id IN (SELECT " ++ echo_id_sql ++ " FROM outbox WHERE draft_key=? AND record IS NOT NULL) ORDER BY sort_key,id";
pub const history_versions_query = "SELECT NULL,id,revision,sort_key," ++ enrichment_serial ++ " FROM records WHERE kind='message' AND chat=? UNION ALL SELECT NULL,id,revision,sort_key," ++ enrichment_serial ++ " FROM records WHERE kind='message' AND chat!=? AND id IN (SELECT " ++ echo_id_sql ++ " FROM outbox WHERE draft_key=? AND record IS NOT NULL) ORDER BY sort_key,id";
pub const message_query = "SELECT " ++ enriched_record ++ " FROM records WHERE kind='message' AND id=?";

pub fn enrichmentNext(s: Self, a: u.Allocator, id: []const u8, revision: []const u8, section: []const u8) !?[]const u8 {
    var q = try s.db.prepare("SELECT next FROM enrichment_pages WHERE message_id=? AND revision=? AND section=?");
    defer q.close();
    try q.bind(&.{ .{ .text = id }, .{ .text = revision }, .{ .text = section } });
    if (!try q.step()) return "";
    return if (q.bytes(0).len == 0) null else try q.text(a, 0);
}
pub fn enrichmentPage(s: Self, a: u.Allocator, raw: []const u8, id: []const u8, revision: []const u8, section: @import("Content.zig").Section, after: []const u8) !bool {
    const Page = struct { message_id: []const u8, revision: []const u8, section: @import("Content.zig").Section, items: []const std.json.Value, total: usize, next: ?[]const u8 };
    const page_value = try std.json.parseFromSliceLeaky(Page, a, raw, .{ .ignore_unknown_fields = true });
    if (!u.eq(page_value.message_id, id) or !u.eq(page_value.revision, revision) or page_value.section != section or (page_value.next != null and (u.eq(page_value.next.?, after) or page_value.items.len == 0))) return error.InvalidEnrichmentPage;
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    var q = try s.db.prepare(message_query);
    defer q.close();
    try q.bind(&.{.{ .text = id }});
    var m: t.Message = if (try q.step()) try std.json.parseFromSliceLeaky(t.Message, a, q.bytes(0), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) else return error.MissingMessage;
    if (!u.eq(m.revision, revision)) {
        try s.db.exec("ROLLBACK");
        return false;
    }
    const expected = try s.enrichmentNext(a, id, revision, @tagName(section));
    if (expected == null or !u.eq(expected.?, after)) {
        try s.db.exec("ROLLBACK");
        return false;
    }
    var items: std.ArrayList(std.json.Value) = .empty;
    if (after.len > 0) {
        var previous = try s.db.prepare("SELECT items FROM enrichment_pages WHERE message_id=? AND section=? AND revision=?");
        defer previous.close();
        try previous.bind(&.{ .{ .text = id }, .{ .text = @tagName(section) }, .{ .text = revision } });
        if (!try previous.step()) return error.InvalidEnrichmentPage;
        try items.appendSlice(a, try std.json.parseFromSliceLeaky([]const std.json.Value, a, previous.bytes(0), .{ .allocate = .alloc_always }));
    }
    try items.appendSlice(a, page_value.items);
    if (items.items.len > page_value.total or (page_value.next == null and items.items.len != page_value.total)) return error.InvalidEnrichmentPage;
    const encoded = try u.json(a, items.items);
    if (m.enrichment == null) return error.InvalidEnrichmentPage;
    switch (section) {
        inline else => |selected| {
            const field = comptime if (selected == .previews) "link_previews" else @tagName(selected);
            const T = comptime switch (selected) {
                .attachments => t.Attachment,
                .previews => t.LinkPreview,
                .reactions => t.Reaction,
                .parts => t.MessagePart,
            };
            const values = try std.json.parseFromSliceLeaky([]const T, a, encoded, .{ .ignore_unknown_fields = true });
            const current: []const T = if (selected == .attachments) m.attachments else @field(m, field) orelse &.{};
            if (values.len >= current.len or page_value.next == null) @field(m, field) = values;
            @field(m.enrichment.?, @tagName(selected)) = .{ .total = page_value.total, .complete = page_value.next == null };
        },
    }
    try s.exec("INSERT INTO enrichment_pages VALUES(?,?,?,?,?) ON CONFLICT(message_id,section) DO UPDATE SET revision=excluded.revision,items=excluded.items,next=excluded.next", &.{ .{ .text = id }, .{ .text = @tagName(section) }, .{ .text = revision }, .{ .text = encoded }, if (page_value.next) |next| .{ .text = next } else .null_value });
    try s.exec("INSERT INTO enrichment_cache VALUES(?,?,?,1) ON CONFLICT(message_id) DO UPDATE SET revision=excluded.revision,record=excluded.record,serial=enrichment_cache.serial+1", &.{ .{ .text = id }, .{ .int = try std.fmt.parseInt(i64, revision, 10) }, .{ .text = try u.json(a, m) } });
    try s.db.exec("COMMIT");
    return true;
}

pub fn directory(s: Self, a: u.Allocator) !Directory {
    var result = Directory{ .available = !u.eq(try s.get(a, "contacts_blocked"), "1") };
    var q = try s.db.prepare("SELECT record FROM identities");
    defer q.close();
    while (try q.step()) try result.put(a, try std.json.parseFromSliceLeaky(t.Identity, a, q.bytes(0), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }));
    return result;
}
