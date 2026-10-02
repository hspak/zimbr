//! Persistent client cache. Allocation-taking queries use a caller-owned arena;
//! returned snapshots and any partial allocations share that arena's lifetime.
const std = @import("std");
const json_bounds = @import("../protocol.zig").json;
const Json = @import("../protocol.zig").Json;
const validation = @import("validation.zig");
const content = @import("content.zig");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const Sqlite = @import("../relay.zig").Sqlite;
const Directory = @import("IdentityDirectory.zig");
const display = @import("display.zig");
const bridge = @import("c.zig").api;
const outgoing = @import("outgoing.zig");
const attachments = @import("../protocol.zig").attachments;
const log = std.log.scoped(.client_store);
const Store = @This();
// Keep 100 recent messages ready for display; older history is loaded on demand.
pub const recent_history_limit = 100;

db: Sqlite,

pub const ReadError = Sqlite.QueryError || u.Allocator.Error;
pub const RecordError = Sqlite.QueryError || std.json.ParseError(std.json.Scanner);
pub const SaveDraftError = ReadError || error{InvalidDraft};
pub const SetHiddenError = Sqlite.QueryError || error{InvalidConversation};
pub const BeginSyncError = Sqlite.QueryError || error{
    InvalidEpoch,
    InvalidRequest,
    ResyncRequired,
};
pub const UpsertError = RecordError || error{
    InvalidJson,
    InvalidRecord,
    JsonTooComplex,
    JsonTooDeep,
    JsonTooLarge,
};
pub const EventError = RecordError || error{
    InvalidEvent,
    InvalidJson,
    InvalidRecord,
    InvalidRequest,
    JsonTooComplex,
    JsonTooDeep,
    JsonTooLarge,
    ResyncRequired,
    UnknownEvent,
};
pub const EventNotificationError = RecordError || error{
    InvalidEvent,
    InvalidJson,
    InvalidRecord,
    InvalidRequest,
    JsonTooComplex,
    JsonTooDeep,
    JsonTooLarge,
    ResyncRequired,
    UnknownEvent,
};
pub const PersistSendError = ReadError || t.ValidateError || outgoing.TransferError || error{
    InvalidDraft,
    InvalidRequest,
    InvalidTimestamp,
    StaleEpoch,
    TextTooLarge,
    UnsupportedTarget,
};
pub const SavePreviewError = RecordError || error{InvalidRecord};
pub const SaveDecodedPreviewError = Sqlite.QueryError || error{InvalidRecord};
pub const EnrichmentPageError = RecordError || error{
    InvalidEnrichmentPage,
    InvalidJson,
    InvalidRecord,
    JsonTooComplex,
    JsonTooDeep,
    JsonTooLarge,
    MissingMessage,
};

/// Assume the returned store and its statements are used by one thread at a
/// time. Settings and synchronization use separate connections to this cache.
pub fn open(path: [:0]const u8) ReadError!Store {
    const db = try Sqlite.openConfined(path, false);
    errdefer db.close();
    try db.exec(
        \\PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        \\CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1),relay_url TEXT NOT NULL,ca_file TEXT NOT NULL,client_cert_file TEXT NOT NULL,client_key_file TEXT NOT NULL,enter_to_send INTEGER NOT NULL CHECK(enter_to_send IN (0,1)));
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
        \\CREATE INDEX IF NOT EXISTS outbox_state ON outbox(state);
        \\CREATE TABLE IF NOT EXISTS outgoing_files(id TEXT PRIMARY KEY,draft_key TEXT,request_id TEXT,record TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 104857600),CHECK(draft_key IS NULL OR request_id IS NULL));
        \\CREATE INDEX IF NOT EXISTS outgoing_draft ON outgoing_files(draft_key);
        \\CREATE INDEX IF NOT EXISTS outgoing_request ON outgoing_files(request_id);
    );
    if (try db.scalar("SELECT count(*) FROM pragma_table_info('previews') WHERE name='record'") == 0) try db.exec("ALTER TABLE previews ADD COLUMN record TEXT");
    try db.exec("UPDATE records SET chat=id WHERE kind='conversation' AND chat=''");
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
    const store = Store{ .db = db };
    try store.migrateHistoryCache();
    return store;
}
fn migrateHistoryCache(s: Store) !void {
    if (try s.db.scalar("SELECT count(*) FROM meta WHERE key='lazy_history_cache_v1'") > 0) return;
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    // Older clients copied background reconciliation into the cache. Keep a
    // recent window per displayed thread and every locally linked send echo.
    try s.db.exec(std.fmt.comptimePrint(
        \\CREATE TEMP TABLE cache_prune AS
        \\SELECT id,thread FROM (
        \\ SELECT m.id,coalesce(c.chat,m.chat) AS thread,
        \\ row_number() OVER (PARTITION BY coalesce(c.chat,m.chat) ORDER BY m.sort_key DESC,m.id DESC) AS position
        \\ FROM records m LEFT JOIN records c ON c.kind='conversation' AND c.id=m.chat WHERE m.kind='message'
        \\) WHERE position>{d} AND id NOT IN (
        \\ SELECT json_extract(record,'$.message_id') FROM outbox WHERE json_extract(record,'$.message_id') IS NOT NULL
        \\ UNION SELECT json_extract(record,'$.candidate_message_id') FROM outbox WHERE json_extract(record,'$.candidate_message_id') IS NOT NULL
        \\ UNION SELECT json_extract(part.value,'$.message_id') FROM outbox,json_each(outbox.record,'$.parts') part WHERE json_extract(part.value,'$.message_id') IS NOT NULL
        \\ UNION SELECT json_extract(part.value,'$.candidate_message_id') FROM outbox,json_each(outbox.record,'$.parts') part WHERE json_extract(part.value,'$.candidate_message_id') IS NOT NULL
        \\);
        \\DELETE FROM pages WHERE chat IN (SELECT thread FROM cache_prune)
        \\ OR chat IN (SELECT id FROM records WHERE kind='conversation' AND chat IN (SELECT thread FROM cache_prune));
        \\DELETE FROM enrichment_cache WHERE message_id IN (SELECT id FROM cache_prune);
        \\DELETE FROM enrichment_pages WHERE message_id IN (SELECT id FROM cache_prune);
        \\DELETE FROM records WHERE kind='message' AND id IN (SELECT id FROM cache_prune);
    , .{recent_history_limit}));
    const removed = u.c.sqlite3_changes(s.db.handle) > 0;
    try s.db.exec("DROP TABLE cache_prune");
    try s.set("lazy_history_cache_v1", "1");
    try s.db.exec("COMMIT");
    // Reclaim the old archive's pages once, outside the migration transaction.
    if (removed) s.db.exec("VACUUM") catch {};
}
pub fn close(s: Store) void {
    s.db.close();
}
pub fn exec(s: Store, sql: [:0]const u8, values: []const Sqlite.Parameter) Sqlite.QueryError!void {
    const q = try s.db.prepare(sql);
    defer q.close();
    try q.bind(values);
    _ = try q.step();
}
pub fn get(s: Store, a: u.Allocator, key: []const u8) ReadError![]const u8 {
    const q = try s.db.prepare("SELECT value FROM meta WHERE key=?");
    defer q.close();
    try q.bind(&.{.{ .text = key }});
    return if (try q.step()) try q.text(a, 0) else "";
}
pub fn set(s: Store, key: []const u8, value: []const u8) Sqlite.QueryError!void {
    try s.exec(
        "INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        &.{ .{ .text = key }, .{ .text = value } },
    );
}
pub fn draft(s: Store, a: u.Allocator, key: []const u8) ReadError![]const u8 {
    const q = try s.db.prepare("SELECT text FROM drafts WHERE key=?");
    defer q.close();
    try q.bind(&.{.{ .text = try s.threadKey(a, key) }});
    return if (try q.step()) try q.text(a, 0) else "";
}
pub fn saveDraft(s: Store, key: []const u8, value: []const u8) SaveDraftError!void {
    if (value.len > t.max_text or !std.unicode.utf8ValidateSlice(value)) return error.InvalidDraft;
    const owns_transaction = u.c.sqlite3_get_autocommit(s.db.handle) != 0;
    if (owns_transaction) try s.db.exec("BEGIN IMMEDIATE");
    errdefer if (owns_transaction) s.db.exec("ROLLBACK") catch {};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const canonical = try s.threadKey(arena.allocator(), key);
    // An edit queued under an old alias must not discard the other saved draft.
    if (!u.eq(canonical, key) and value.len > 0) {
        try s.exec(
            "INSERT INTO drafts VALUES(?,?) ON CONFLICT(key) DO UPDATE SET text=excluded.text",
            &.{ .{ .text = key }, .{ .text = value } },
        );
        try s.mergeThreadState(arena.allocator(), canonical);
    } else try s.exec(
        "INSERT INTO drafts VALUES(?,?) ON CONFLICT(key) DO UPDATE SET text=excluded.text",
        &.{ .{ .text = canonical }, .{ .text = value } },
    );
    if (owns_transaction) try s.db.exec("COMMIT");
}
pub fn threadKey(s: Store, a: u.Allocator, key: []const u8) ReadError![]const u8 {
    const q = try s.db.prepare("SELECT c.chat FROM records c JOIN records root ON root.kind='conversation' AND root.id=c.chat WHERE c.kind='conversation' AND c.id=?");
    defer q.close();
    try q.bind(&.{.{ .text = key }});
    return if (try q.step()) try q.text(a, 0) else key;
}
// Members retain their original IDs, message ownership, and send payloads.
// The existing indexed chat column holds the relay's presentation thread ID.
pub const thread_cte = "WITH members AS (SELECT ?1 AS id UNION SELECT id FROM records WHERE kind='conversation' AND chat=coalesce((SELECT chat FROM records WHERE kind='conversation' AND id=?1),?1)) ";
pub fn selfRecipient(chat: t.Conversation) ?[]const u8 {
    if (!chat.is_self or !u.eq(chat.service, "imessage")) return null;
    for (chat.participants) |address| if (t.validAddress(address)) return address;
    return null;
}
pub fn sendTarget(s: Store, a: u.Allocator, key: []const u8) RecordError!t.Target {
    // The merged self thread's display ID may not resolve to an AppleScript
    // chat. Address its most recently active verified member directly instead.
    const q = try s.db.prepare(thread_cte ++ "SELECT record FROM records WHERE kind='conversation' AND id IN (SELECT id FROM members) AND EXISTS(SELECT 1 FROM records selected WHERE selected.kind='conversation' AND selected.id=?1 AND json_extract(selected.record,'$.is_self')=1 AND json_extract(selected.record,'$.service')='imessage') ORDER BY sort_key DESC,id DESC");
    defer q.close();
    try q.bind(&.{.{ .text = key }});
    while (try q.step()) {
        const chat = try std.json.parseFromSliceLeaky(
            t.Conversation,
            a,
            q.bytes(0),
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        if (selfRecipient(chat)) |address| return .{ .recipient = .{ .address = address, .service = "imessage" } };
    }
    return .{ .conversation_id = key };
}
fn mergeThreadState(s: Store, a: u.Allocator, key: []const u8) !void {
    const canonical = try s.threadKey(a, key);
    const q = try s.db.prepare(thread_cte ++ "SELECT d.key,d.text FROM drafts d WHERE d.key IN (SELECT id FROM members) AND d.key!=?1 ORDER BY d.key");
    defer q.close();
    try q.bind(&.{.{ .text = canonical }});
    var aliases: std.ArrayList([]const u8) = .empty;
    var combined = try s.draft(a, canonical);
    while (try q.step()) {
        try aliases.append(a, try q.text(a, 0));
        const other = try q.text(a, 1);
        if (other.len > 0 and !u.eq(combined, other)) combined = if (combined.len == 0) other else try std.fmt.allocPrint(
            a,
            "{s}\n\n{s}",
            .{ combined, other },
        );
    }
    if (aliases.items.len > 0) {
        // Preserve both drafts even if their combined length exceeds the send
        // limit; the composer can shorten them, but migration never truncates.
        try s.exec(
            "INSERT INTO drafts VALUES(?,?) ON CONFLICT(key) DO UPDATE SET text=excluded.text",
            &.{ .{ .text = canonical }, .{ .text = combined } },
        );
        for (aliases.items) |alias| try s.exec(
            "DELETE FROM drafts WHERE key=?",
            &.{.{ .text = alias }},
        );
    }
    try s.exec(
        thread_cte ++ "UPDATE outbox SET draft_key=?1 WHERE draft_key IN (SELECT id FROM members)",
        &.{.{ .text = canonical }},
    );
    try s.exec(
        thread_cte ++ "UPDATE outgoing_files SET draft_key=?1 WHERE draft_key IN (SELECT id FROM members)",
        &.{.{ .text = canonical }},
    );
}
pub fn read(s: Store, chat: []const u8) Sqlite.QueryError!void {
    try s.exec(
        thread_cte ++ "DELETE FROM unread WHERE chat IN (SELECT id FROM members)",
        &.{.{ .text = chat }},
    );
}
pub fn setHidden(s: Store, key: []const u8, hidden: bool) SetHiddenError!void {
    if (key.len == 0) return error.InvalidConversation;
    try s.exec(
        if (hidden) thread_cte ++ "INSERT OR IGNORE INTO hidden_chats SELECT id FROM members" else thread_cte ++ "DELETE FROM hidden_chats WHERE key IN (SELECT id FROM members)",
        &.{.{ .text = key }},
    );
}
pub fn beginSync(s: Store, epoch: []const u8, cursor: []const u8) BeginSyncError!void {
    if (!t.validId(epoch)) return error.InvalidEpoch;
    _ = try t.parseCursor(cursor, epoch);
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    const same_epoch = same_epoch: {
        const q = try s.db.prepare("SELECT 1 FROM meta WHERE key='epoch' AND value=?");
        defer q.close();
        try q.bind(&.{.{ .text = epoch }});
        break :same_epoch try q.step();
    };
    // Replay expiry changes coverage, not record identity. Keep offline history,
    // names, avatar references and unread deduplication until fresher revisions arrive.
    // A new epoch has unrelated IDs/revisions; only drafts and outbox identities survive.
    if (!same_epoch) try s.db.exec("DELETE FROM enrichment_pages; DELETE FROM enrichment_cache; DELETE FROM identities; DELETE FROM records; DELETE FROM unread; DELETE FROM live_seen;");
    try s.db.exec("DELETE FROM pages; DELETE FROM previews;");
    try s.exec(
        "UPDATE outbox SET state='unknown',detail='Relay changed. This request will not be sent again automatically.' WHERE epoch!=? AND state NOT IN ('delivered','failed')",
        &.{.{ .text = epoch }},
    );
    try s.set("epoch", epoch);
    try s.set("cursor", cursor);
    try s.set("bootstrapped", "0");
    try s.set("identity_bootstrapped", "0");
    try s.set("accepted_extensions", "");
    try s.db.exec("COMMIT");
    log.info("Cache sync started: epoch_changed={}, cached_records_retained={}", .{ !same_epoch, same_epoch });
}
pub const Incoming = union(enum) {
    conversation: json_bounds.Decoded(t.Conversation),
    message: json_bounds.Decoded(t.Message),
    request: json_bounds.Decoded(t.SendRequest),
    identity: json_bounds.Decoded(t.Identity),
};

pub fn upsert(s: Store, a: u.Allocator, kind: []const u8, raw: []const u8) UpsertError!bool {
    try json_bounds.check(raw, validation.max_record_bytes, 32768);
    inline for (std.meta.fields(Incoming)) |field| {
        if (u.eq(kind, field.name)) {
            const decoded = try std.json.parseFromSliceLeaky(
                field.type,
                a,
                raw,
                .{ .ignore_unknown_fields = true },
            );
            return s.writeRecord(a, @unionInit(Incoming, field.name, decoded));
        }
    }
    return error.InvalidRecord;
}

/// Persist a decoded wire record without parsing it again. Assume value and raw
/// came from the same Decoded parser result. Record validation and byte bounds
/// are still checked.
/// The caller retains ownership; SQLite copies the record before returning.
pub fn upsertDecoded(s: Store, a: u.Allocator, record: Incoming) UpsertError!bool {
    const raw = switch (record) {
        inline else => |v| v.raw,
    };
    try json_bounds.check(raw, validation.max_record_bytes, 32768);
    return s.writeRecord(a, record);
}

fn writeRecord(s: Store, a: u.Allocator, record: Incoming) UpsertError!bool {
    const kind = @tagName(record);
    const raw = switch (record) {
        inline else => |v| v.raw,
    };
    if (record == .identity) {
        const v = record.identity.value;
        const revision = try std.fmt.parseInt(i64, v.revision, 10);
        if (revision < 0 or v.id.len == 0 or v.service.len == 0 or v.address.len == 0) return error.InvalidRecord;
        try s.exec("INSERT INTO identities VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,record=excluded.record WHERE excluded.revision>identities.revision AND excluded.service=identities.service AND excluded.address=identities.address", &.{
            .{ .text = v.id },
            .{ .int = revision },
            .{ .text = v.service },
            .{ .text = v.address },
            .{ .text = raw },
        });
        return u.c.sqlite3_changes(s.db.handle) > 0;
    }
    var id: []const u8 = undefined;
    var rev: []const u8 = undefined;
    var chat: []const u8 = "";
    var sort: []const u8 = "";
    var metadata_deferred = false;
    switch (record) {
        .conversation => |decoded| {
            const v = decoded.value;
            id = v.id;
            rev = v.revision;
            sort = v.last_activity orelse "";
            chat = if (v.is_self and v.thread_id != null and t.validId(v.thread_id.?)) v.thread_id.? else v.id;
        },
        .message => |decoded| {
            const v = decoded.value;
            try validation.message(v);
            id = v.id;
            rev = v.revision;
            chat = v.conversation_id;
            sort = v.timestamp;
            metadata_deferred = v.metadata_deferred;
        },
        .request => |decoded| {
            const v = decoded.value;
            try validation.request(v);
            id = v.request_id;
            rev = v.revision;
            chat = v.target.conversation_id orelse "";
            const epoch = try s.get(a, "epoch");
            if (!u.eq(epoch, v.server_epoch)) return false;
            try outgoing.validateRequest(s, a, v);
        },
        .identity => unreachable, // The separate directory write returned above.
    }
    const revision = try std.fmt.parseInt(i64, rev, 10);
    if (revision < 0 or id.len == 0) return error.InvalidRecord;
    const owns_transaction = record == .request and u.c.sqlite3_get_autocommit(s.db.handle) != 0;
    if (owns_transaction) try s.db.exec("BEGIN IMMEDIATE");
    errdefer if (owns_transaction) s.db.exec("ROLLBACK") catch {};
    const existing = try s.db.prepare("SELECT revision,record,chat FROM records WHERE kind=? AND id=?");
    defer existing.close();
    try existing.bind(&.{ .{ .text = kind }, .{ .text = id } });
    const fresh = !(try existing.step());
    // A full record may upgrade a text projection at the same revision. A
    // delayed projection can never erase metadata already received via SSE.
    const upgrade = !fresh and u.eq(kind, "message") and !metadata_deferred and existing.int(0) == revision and
        (try std.json.parseFromSliceLeaky(
            struct { metadata_deferred: bool = false },
            a,
            existing.bytes(1),
            .{ .ignore_unknown_fields = true },
        )).metadata_deferred;
    if (!fresh and existing.int(0) >= revision and !upgrade) {
        if (record == .request) try s.requestState(try std.json.parseFromSliceLeaky(
            t.SendRequest,
            a,
            existing.bytes(1),
            .{ .ignore_unknown_fields = true },
        ), existing.bytes(1));
        if (owns_transaction) try s.db.exec("COMMIT");
        return false;
    }
    const regrouped = u.eq(kind, "conversation") and (fresh or !u.eq(existing.bytes(2), chat));
    try s.exec("INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision,chat=excluded.chat,sort_key=excluded.sort_key,record=excluded.record", &.{
        .{ .text = kind },
        .{ .text = id },
        .{ .int = revision },
        .{ .text = chat },
        .{ .text = sort },
        .{ .text = raw },
    });
    if (u.eq(kind, "message")) {
        try s.exec("DELETE FROM enrichment_cache WHERE message_id=?", &.{.{ .text = id }});
        try s.exec("DELETE FROM enrichment_pages WHERE message_id=?", &.{.{ .text = id }});
        // Invalidate immutable history reuse even though the relay revision
        // did not change. Later overflow pages keep incrementing this serial.
        if (upgrade) try s.exec("INSERT INTO enrichment_cache VALUES(?,?,?,1)", &.{
            .{ .text = id },
            .{ .int = revision },
            .{ .text = raw },
        });
    }
    if (record == .request) try s.requestState(record.request.value, raw);
    if (regrouped) {
        try s.exec(
            thread_cte ++ "DELETE FROM pages WHERE chat IN (SELECT id FROM members)",
            &.{.{ .text = id }},
        );
        try s.mergeThreadState(a, id);
    }
    if (owns_transaction) try s.db.exec("COMMIT");
    return fresh;
}
fn requestState(s: Store, v: t.SendRequest, raw: []const u8) !void {
    try s.exec("UPDATE outbox SET state=?,detail=?,record=? WHERE id=?", &.{
        .{ .text = @tagName(v.state) },
        .{ .text = if (v.error_info) |e| e.message else "" },
        .{ .text = raw },
        .{ .text = v.request_id },
    });
    if (v.state == .delivered) try outgoing.delivered(s, v.request_id);
}
pub const Event = struct {
    cursor: []const u8,
    sequence: []const u8,
    type: []const u8,
    origin: []const u8,
    record: Json,
};
pub fn event(
    s: Store,
    a: u.Allocator,
    raw: []const u8,
    frame_id: []const u8,
    frame_type: []const u8,
    viewed: []const u8,
) EventError!void {
    _ = try s.eventNotification(a, raw, frame_id, frame_type, viewed);
}
// The returned message is only eligible for delivery AFTER the caller's batch
// transaction commits. Its strings belong to a, just like parsed event records.
pub fn eventNotification(
    s: Store,
    a: u.Allocator,
    raw: []const u8,
    frame_id: []const u8,
    frame_type: []const u8,
    viewed: []const u8,
) EventNotificationError!?t.Message {
    try json_bounds.check(raw, 1024 * 1024, 65536);
    const e = try std.json.parseFromSliceLeaky(Event, a, raw, .{ .ignore_unknown_fields = true });
    const epoch = try s.get(a, "epoch");
    const seq = try t.parseCursor(e.cursor, epoch);
    if (!u.eq(e.cursor, frame_id) or !u.eq(e.type, frame_type) or seq != try std.fmt.parseInt(
        i64,
        e.sequence,
        10,
    )) return error.InvalidEvent;
    if (seq <= try t.parseCursor(try s.get(a, "cursor"), epoch)) return null;
    const kind = if (u.eq(e.type, "conversation.upsert")) "conversation" else if (u.eq(
        e.type,
        "message.upsert",
    )) "message" else if (u.eq(
        e.type,
        "send_request.updated",
    )) "request" else if (u.eq(
        e.type,
        "identity.upsert",
    ) and u.eq(
        try s.get(a, "accepted_extensions"),
        "identity-v1",
    )) "identity" else return error.UnknownEvent;
    const record = e.record.bytes;
    // The network worker may own a batch transaction. Standalone callers keep
    // the same atomic record/cursor guarantee for an individual event.
    const owns_transaction = u.c.sqlite3_get_autocommit(s.db.handle) != 0;
    if (owns_transaction) try s.db.exec("BEGIN IMMEDIATE");
    errdefer if (owns_transaction) s.db.exec("ROLLBACK") catch {};
    var notification: ?t.Message = null;
    if (u.eq(kind, "message")) {
        try json_bounds.check(record, validation.max_record_bytes, 32768);
        const decoded = try std.json.parseFromSliceLeaky(
            json_bounds.Decoded(t.Message),
            a,
            record,
            .{ .ignore_unknown_fields = true },
        );
        const m = decoded.value;
        try validation.message(m);
        if (u.eq(e.origin, "live") or try s.cacheBackgroundMessage(m))
            _ = try s.writeRecord(a, .{ .message = decoded });
        if (!display.resolvedReaction(m)) {
            const preview = t.ConversationPreview{
                .conversation_id = m.conversation_id,
                .message_id = m.id,
                .revision = m.revision,
                .timestamp = m.timestamp,
                .kind = @tagName(m.kind),
                .text = display.prefix(display.summary(a, m), 1024, 1),
            };
            try s.writePreview(preview, try u.json(a, preview));
        }
        if (m.direction == .incoming and m.kind != .reaction and m.reaction_event == null) {
            try s.exec("INSERT OR IGNORE INTO live_seen VALUES(?)", &.{.{ .text = m.id }});
            const first = u.c.sqlite3_changes(s.db.handle) > 0;
            if (first and u.eq(e.origin, "live") and !u.eq(
                try s.threadKey(a, m.conversation_id),
                try s.threadKey(a, viewed),
            )) {
                try s.exec(
                    "INSERT INTO unread VALUES(?,1) ON CONFLICT(chat) DO UPDATE SET count=count+1",
                    &.{.{ .text = m.conversation_id }},
                );
                notification = m;
            }
        }
    } else _ = try s.upsert(a, kind, record);
    try s.set("cursor", e.cursor);
    if (owns_transaction) try s.db.exec("COMMIT");
    return notification;
}
fn cacheBackgroundMessage(s: Store, m: t.Message) !bool {
    const existing = try s.db.prepare("SELECT 1 FROM records WHERE kind='message' AND id=?");
    defer existing.close();
    try existing.bind(&.{.{ .text = m.id }});
    if (try existing.step()) return true;
    // Reconciliation may discover a recent message between history requests.
    // It must not extend the cache backwards into unrequested older history.
    const recent = try s.db.prepare(thread_cte ++ std.fmt.comptimePrint(
        "SELECT 1 FROM (SELECT sort_key,id FROM records WHERE kind='message' AND chat IN (SELECT id FROM members) ORDER BY sort_key DESC,id DESC LIMIT {d}) WHERE (sort_key,id)<=(?2,?3) LIMIT 1",
        .{recent_history_limit},
    ));
    defer recent.close();
    try recent.bind(&.{
        .{ .text = m.conversation_id },
        .{ .text = m.timestamp },
        .{ .text = m.id },
    });
    return try recent.step();
}
pub fn persistSend(s: Store, a: u.Allocator, key: []const u8, input: t.SendInput) PersistSendError!void {
    try t.validate(input);
    if (!u.eq(input.server_epoch, try s.get(a, "epoch"))) return error.StaleEpoch;
    const payload = try u.json(a, input);
    const sent_at = try u.timestamp(a, (u.now() - 978307200000) * 1000000);
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    try outgoing.transfer(s, a, key, input);
    try s.exec("INSERT INTO outbox(id,epoch,draft_key,payload,state,sent_at) VALUES(?,?,?,?,?,?)", &.{
        .{ .text = input.request_id },
        .{ .text = input.server_epoch },
        .{ .text = key },
        .{ .text = payload },
        .{ .text = if (input.attachments.len == 0) "sending" else "uploading" },
        .{ .text = sent_at },
    });
    try s.saveDraft(key, "");
    try s.db.exec("COMMIT");
}
pub fn outcome(s: Store, id: []const u8, state: []const u8, detail: []const u8) Sqlite.QueryError!void {
    // A late HTTP failure must not overwrite a request already received via SSE.
    try s.exec("UPDATE outbox SET state=?,detail=? WHERE id=? AND record IS NULL", &.{
        .{ .text = state },
        .{ .text = detail },
        .{ .text = id },
    });
}
/// Remove unknown pending sends five minutes after their saved send time, across
/// all relay epochs. Attachment sends retain their originals and review history.
/// Returns whether entries were removed; message history stays.
pub fn expireUnknown(s: Store, now_ms: i64) Sqlite.QueryError!bool {
    try s.exec(
        "DELETE FROM outbox WHERE state='unknown' AND coalesce(json_array_length(payload,'$.attachments'),0)=0 AND julianday(sent_at)<=julianday(? / 1000.0,'unixepoch')",
        &.{.{ .int = now_ms - 5 * 60 * 1000 }},
    );
    return u.c.sqlite3_changes(s.db.handle) > 0;
}
pub fn page(s: Store, chat: []const u8, cursor: ?[]const u8) Sqlite.QueryError!void {
    try s.exec(
        "INSERT INTO pages VALUES(?,?) ON CONFLICT(chat) DO UPDATE SET cursor=excluded.cursor",
        &.{ .{ .text = chat }, if (cursor) |v| .{ .text = v } else .null_value },
    );
}
pub fn savePreview(s: Store, a: u.Allocator, raw: []const u8) SavePreviewError!void {
    const value = try std.json.parseFromSliceLeaky(
        t.ConversationPreview,
        a,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    return s.writePreview(value, raw);
}

/// Assume value and raw came from the same Decoded parser result. Validate the
/// preview and copy its original bytes into SQLite; the caller retains ownership.
pub fn savePreviewDecoded(
    s: Store,
    preview: json_bounds.Decoded(t.ConversationPreview),
) SaveDecodedPreviewError!void {
    return s.writePreview(preview.value, preview.raw);
}

fn writePreview(s: Store, value: t.ConversationPreview, raw: []const u8) SaveDecodedPreviewError!void {
    const revision = std.fmt.parseInt(i64, value.revision, 10) catch return error.InvalidRecord;
    if (revision < 0 or value.conversation_id.len == 0 or value.message_id.len == 0 or value.text.len > 1024) return error.InvalidRecord;
    try s.exec(
        "INSERT INTO previews(chat,record) VALUES(?,?) ON CONFLICT(chat) DO UPDATE SET record=excluded.record WHERE previews.record IS NULL OR (json_extract(excluded.record,'$.timestamp'),json_extract(excluded.record,'$.message_id'))>(json_extract(previews.record,'$.timestamp'),json_extract(previews.record,'$.message_id')) OR (json_extract(excluded.record,'$.message_id')=json_extract(previews.record,'$.message_id') AND CAST(json_extract(excluded.record,'$.revision') AS INTEGER)>CAST(json_extract(previews.record,'$.revision') AS INTEGER))",
        &.{ .{ .text = value.conversation_id }, .{ .text = raw } },
    );
}
pub fn nextPage(s: Store, a: u.Allocator, chat: []const u8) ReadError!?[]const u8 {
    const q = try s.db.prepare("SELECT cursor FROM pages WHERE chat=?");
    defer q.close();
    try q.bind(&.{.{ .text = chat }});
    if (!try q.step()) return "";
    return if (q.bytes(0).len == 0) null else try q.text(a, 0);
}
pub const Chat = struct {
    value: t.Conversation,
    preview: []const u8,
    unread: i64,
    hidden: bool = false,
};
pub const Pending = struct {
    input: t.SendInput,
    state: []const u8,
    detail: []const u8,
    record: ?t.SendRequest,
    sent_at: []const u8,
};
pub const Snapshot = struct {
    chats: []const Chat,
    messages: []const t.Message,
    pending: []const Pending,
    selected: []const u8,
    draft: []const u8,
    draft_attachments: []const attachments.Upload = &.{},
    epoch: []const u8,
    more: bool,
    directory: Directory = .{},
};
pub fn snapshot(s: Store, a: u.Allocator, selected: []const u8) RecordError!Snapshot {
    return s.snapshotWithMessages(a, selected, null);
}
// A shared history owns these immutable messages for at least this snapshot's
// lifetime. Other callers can still request a fully arena-owned snapshot.
pub fn snapshotWithMessages(
    s: Store,
    a: u.Allocator,
    selected_key: []const u8,
    shared_messages: ?[]const t.Message,
) RecordError!Snapshot {
    const selected = try s.threadKey(a, selected_key);
    var chats: std.ArrayList(Chat) = .empty;
    var messages: std.ArrayList(t.Message) = .empty;
    var pending: std.ArrayList(Pending) = .empty;
    const q = try s.db.prepare("SELECT c.record,coalesce(u.count,0),(SELECT m.record FROM records m WHERE m.kind='message' AND m.chat=c.id AND coalesce(json_extract(m.record,'$.reaction_event.resolution'),'')!='resolved' ORDER BY m.sort_key DESC,m.id DESC LIMIT 1),p.record,EXISTS(SELECT 1 FROM hidden_chats h WHERE h.key=c.id) FROM records c LEFT JOIN unread u ON c.id=u.chat LEFT JOIN previews p ON p.chat=c.id WHERE c.kind='conversation' ORDER BY c.sort_key DESC,c.id DESC");
    defer q.close();
    while (try q.step()) {
        const v = (try std.json.parseFromSlice(
            t.Conversation,
            a,
            q.bytes(0),
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        )).value;
        var preview: []const u8 = if (v.last_activity != null) "History not loaded" else "No messages yet";
        var latest: ?t.Message = null;
        if (q.bytes(2).len > 0) {
            const m = (try std.json.parseFromSlice(
                t.Message,
                a,
                q.bytes(2),
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            )).value;
            latest = m;
            preview = display.summary(a, m);
        }
        if (q.bytes(3).len > 0) {
            const p = (try std.json.parseFromSlice(
                t.ConversationPreview,
                a,
                q.bytes(3),
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            )).value;
            const newer_position = latest == null or std.mem.order(
                u8,
                p.timestamp,
                latest.?.timestamp,
            ) == .gt or
                (u.eq(p.timestamp, latest.?.timestamp) and std.mem.order(
                    u8,
                    p.message_id,
                    latest.?.id,
                ) == .gt);
            const newer_revision = latest != null and u.eq(p.message_id, latest.?.id) and (try std.fmt.parseInt(
                i64,
                p.revision,
                10,
            )) > (try std.fmt.parseInt(
                i64,
                latest.?.revision,
                10,
            ));
            if (newer_position or newer_revision) {
                const text = display.withoutObjectMarkers(a, p.text);
                preview = if (text.len > 0) text else if (u.eq(p.kind, "attachment")) "Attachment" else p.kind;
            }
        }
        try chats.append(a, .{
            .value = v,
            .preview = preview,
            .unread = q.int(1),
            .hidden = q.int(4) != 0,
        });
    }
    var by_id: std.StringHashMapUnmanaged(usize) = .empty;
    for (chats.items, 0..) |chat, index| try by_id.put(a, chat.value.id, index);
    var grouped: std.ArrayList(Chat) = .empty;
    var by_thread: std.StringHashMapUnmanaged(usize) = .empty;
    for (chats.items) |chat| {
        const root = if (chat.value.is_self and chat.value.thread_id != null) by_id.get(chat.value.thread_id.?) else null;
        const key = if (root) |index| chats.items[index].value.id else chat.value.id;
        const entry = try by_thread.getOrPut(a, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = grouped.items.len;
            var first = chat;
            if (root) |index| {
                first.value = chats.items[index].value;
                first.value.last_activity = chat.value.last_activity;
                first.value.history_complete = chat.value.history_complete;
                first.value.participants = chat.value.participants;
            }
            try grouped.append(a, first);
        } else {
            const merged = &grouped.items[entry.value_ptr.*];
            merged.unread += chat.unread;
            merged.hidden = merged.hidden and chat.hidden;
            merged.value.history_complete = merged.value.history_complete and chat.value.history_complete;
            var participants: std.ArrayList([]const u8) = .empty;
            try participants.appendSlice(a, merged.value.participants);
            for (chat.value.participants) |address| {
                var exists = false;
                for (participants.items) |previous| if (u.eq(previous, address)) {
                    exists = true;
                    break;
                };
                if (!exists) try participants.append(a, address);
            }
            merged.value.participants = try participants.toOwnedSlice(a);
        }
    }
    chats = grouped;
    // Local drafts without a current server conversation remain discoverable
    // after an epoch reset or while composing a new direct conversation.
    const drafts = try s.db.prepare("SELECT key,EXISTS(SELECT 1 FROM hidden_chats h WHERE h.key=local.key) FROM (SELECT key FROM drafts WHERE text!='' UNION SELECT draft_key AS key FROM outgoing_files WHERE draft_key IS NOT NULL UNION SELECT draft_key AS key FROM outbox WHERE state!='delivered') local WHERE NOT EXISTS(SELECT 1 FROM records WHERE kind='conversation' AND id=local.key)");
    defer drafts.close();
    while (try drafts.step()) {
        const key = try drafts.text(a, 0);
        try chats.append(a, .{
            .value = .{
                .id = key,
                .title = if (std.mem.startsWith(u8, key, "new:")) key[4..] else "Recovered draft",
                .service = "imessage",
            },
            .preview = "Saved locally · drafts and send history",
            .unread = 0,
            .hidden = drafts.int(1) != 0,
        });
    }
    // Separate chat history from linked send echoes so SQLite can use the
    // ordered history index instead of scanning every cached conversation.
    if (shared_messages == null) {
        const ms = try s.db.prepare(history_query);
        defer ms.close();
        try ms.bind(&.{.{ .text = selected }});
        while (try ms.step()) try messages.append(
            a,
            (try std.json.parseFromSlice(t.Message, a, ms.bytes(0), .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value,
        );
    }
    const visible_messages = shared_messages orelse messages.items;
    const epoch = try s.get(a, "epoch");
    const ps = try s.db.prepare(thread_cte ++ "SELECT payload,state,detail,record,sent_at FROM outbox WHERE draft_key IN (SELECT id FROM members) AND (coalesce(json_array_length(payload,'$.attachments'),0)>0 OR NOT EXISTS(SELECT 1 FROM records m WHERE m.kind='message' AND m.id=" ++ echo_id_sql ++ ")) ORDER BY rowid");
    defer ps.close();
    try ps.bind(&.{.{ .text = selected }});
    while (try ps.step()) {
        const record = if (ps.bytes(3).len > 0) (try std.json.parseFromSlice(
            t.SendRequest,
            a,
            ps.bytes(3),
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        )).value else null;
        try pending.append(a, .{
            .input = (try std.json.parseFromSlice(
                t.SendInput,
                a,
                ps.bytes(0),
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            )).value,
            .state = try ps.text(a, 1),
            .detail = try ps.text(a, 2),
            .record = record,
            .sent_at = try ps.text(a, 4),
        });
    }
    return .{
        .chats = chats.items,
        .messages = visible_messages,
        .pending = try s.pendingWithoutEchoes(a, selected, epoch, visible_messages, pending.items),
        .selected = try a.dupe(u8, selected),
        .draft = try s.draft(a, selected),
        .draft_attachments = try outgoing.draft(s, a, selected),
        .epoch = epoch,
        .more = (try s.nextPage(a, selected)) != null,
        .directory = try s.directory(a),
    };
}

fn pendingWithoutEchoes(
    s: Store,
    a: u.Allocator,
    selected: []const u8,
    epoch: []const u8,
    messages: []const t.Message,
    pending: []Pending,
) ReadError![]const Pending {
    if (pending.len == 0 or messages.len == 0) return pending;
    // Reserve authoritative and provisional links before pairing unlinked sends.
    // A message already accounting for one request cannot hide another one.
    var used_echoes: std.StringHashMapUnmanaged(void) = .empty;
    defer used_echoes.deinit(a);
    const linked = try s.db.prepare(thread_cte ++ "SELECT id FROM (" ++ send_echoes_query ++ ") WHERE draft_key IN (SELECT id FROM members) AND id IS NOT NULL");
    defer linked.close();
    try linked.bind(&.{.{ .text = selected }});
    while (try linked.step()) try used_echoes.put(a, try linked.text(a, 0), {});

    // A message can arrive before its request update, or remain unlinked when
    // repeated sends are ambiguous. Pair visible echoes one-to-one for display
    // only; never confirm, discard, or otherwise change the durable requests.
    var count: usize = 0;
    for (pending) |p| {
        if (multipartDelivered(p, epoch, messages)) continue;
        if (pendingEcho(p, epoch, messages, used_echoes)) |id| {
            try used_echoes.put(a, id, {});
        } else {
            pending[count] = p;
            count += 1;
        }
    }
    return pending[0..count];
}

fn multipartDelivered(p: Pending, epoch: []const u8, messages: []const t.Message) bool {
    if (p.input.attachments.len == 0 or !u.eq(p.state, "delivered") or
        !u.eq(p.input.server_epoch, epoch)) return false;
    const record = p.record orelse return false;
    if (record.parts.len == 0) return false;
    for (record.parts) |part| {
        if (part.state != .delivered) return false;
        const id = part.message_id orelse return false;
        for (messages) |message| {
            if (u.eq(message.id, id)) break;
        } else return false;
    }
    return true;
}

fn pendingEcho(
    p: Pending,
    epoch: []const u8,
    messages: []const t.Message,
    used_echoes: std.StringHashMapUnmanaged(void),
) ?[]const u8 {
    if (p.input.attachments.len != 0 or !u.eq(p.input.server_epoch, epoch) or u.eq(p.state, "failed")) return null;
    if (p.record) |record| if (record.message_id != null or record.candidate_message_id != null) return null;
    var sent_ms: i64 = undefined;
    if (bridge.zc_timestamp_ms(p.sent_at.ptr, p.sent_at.len, &sent_ms) == 0) return null;
    for (messages) |m| {
        if (m.direction != .outgoing or !u.eq(m.service, "imessage") or
            m.kind != .text or !u.eq(m.text orelse "", p.input.text) or
            used_echoes.contains(m.id)) continue;
        var message_ms: i64 = undefined;
        if (bridge.zc_timestamp_ms(m.timestamp.ptr, m.timestamp.len, &message_ms) == 0) continue;
        // Allow the relay's small timestamp tolerance and the local send grace
        // period, without matching old identical history.
        if (message_ms < sent_ms - 2000 or message_ms > sent_ms + display.unknown_grace_ms) continue;
        return m.id;
    }
    return null;
}

pub const echo_id_sql = "coalesce(json_extract(outbox.record,'$.message_id'),CASE WHEN outbox.state='unknown' AND outbox.epoch=(SELECT value FROM meta WHERE key='epoch') THEN json_extract(outbox.record,'$.candidate_message_id') END)";
// Include each operation so a caption cannot stand in for the entire send.
pub const send_echoes_query = "SELECT " ++ echo_id_sql ++ " AS id,epoch,draft_key,outbox.rowid AS position FROM outbox UNION ALL SELECT coalesce(json_extract(part.value,'$.message_id'),CASE WHEN outbox.epoch=(SELECT value FROM meta WHERE key='epoch') AND json_extract(part.value,'$.state')='unknown' THEN json_extract(part.value,'$.candidate_message_id') END),epoch,draft_key,outbox.rowid FROM outbox,json_each(outbox.record,'$.parts') part";
const enriched_record = "coalesce((SELECT e.record FROM enrichment_cache e WHERE e.message_id=records.id AND e.revision=records.revision),record)";
const enrichment_serial = "coalesce((SELECT e.serial FROM enrichment_cache e WHERE e.message_id=records.id AND e.revision=records.revision),0)";
const history_tail = " FROM records WHERE kind='message' AND chat NOT IN (SELECT id FROM members) AND id IN (SELECT id FROM (" ++ send_echoes_query ++ ") WHERE draft_key IN (SELECT id FROM members)) ORDER BY sort_key,id";
pub const history_query = thread_cte ++ "SELECT " ++ enriched_record ++ ",id,revision,sort_key," ++ enrichment_serial ++ " FROM records WHERE kind='message' AND chat IN (SELECT id FROM members) UNION ALL SELECT " ++ enriched_record ++ ",id,revision,sort_key," ++ enrichment_serial ++ history_tail;
pub const history_versions_query = thread_cte ++ "SELECT NULL,id,revision,sort_key," ++ enrichment_serial ++ " FROM records WHERE kind='message' AND chat IN (SELECT id FROM members) UNION ALL SELECT NULL,id,revision,sort_key," ++ enrichment_serial ++ history_tail;
pub const message_query = "SELECT " ++ enriched_record ++ " FROM records WHERE kind='message' AND id=?";

test "multipart history preserves partial outcomes and follows every confirmed echo" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Store.open(":memory:");
    defer s.close();
    const epoch = try u.id(a);
    try s.set("epoch", epoch);
    const file: attachments.Upload = .{
        .id = try u.id(a),
        .name = "photo.png",
        .mime_type = "image/png",
        .bytes = "17",
        .sha256 = "0" ** 64,
    };
    const key = "new:peer@example.invalid";
    try outgoing.addDraft(s, a, key, file);
    const input: t.SendInput = .{
        .request_id = try u.id(a),
        .server_epoch = epoch,
        .target = .{ .recipient = .{ .address = "peer@example.invalid", .service = "imessage" } },
        .text = "A caption",
        .attachments = &.{file},
    };
    try s.persistSend(a, key, input);
    const initial = try s.snapshot(a, key);
    const caption: t.Message = .{
        .id = try u.id(a),
        .revision = "1",
        .conversation_id = key,
        .sender = "",
        .service = "imessage",
        .direction = .outgoing,
        .timestamp = initial.pending[0].sent_at,
        .kind = .text,
        .text = input.text,
        .decoding = .plain,
        .observed_status = .delivered,
    };
    _ = try s.upsert(a, "message", try u.json(a, caption));
    // A matching caption alone cannot account for the attachment operation.
    try testing.expectEqual(@as(usize, 1), (try s.snapshot(a, key)).pending.len);
    var parts = [_]t.SendPart{
        .{ .kind = .text, .state = .delivered, .message_id = caption.id },
        .{ .kind = .attachment, .attachment_id = file.id, .state = .unknown },
    };
    var request: t.SendRequest = .{
        .request_id = input.request_id,
        .server_epoch = epoch,
        .revision = "2",
        .target = input.target,
        .text = input.text,
        .attachments = input.attachments,
        .parts = &parts,
        .state = .unknown,
    };
    _ = try s.upsert(a, "request", try u.json(a, request));
    try testing.expectEqual(@as(usize, 1), (try s.snapshot(a, key)).pending.len);
    var attachment = caption;
    attachment.id = try u.id(a);
    attachment.revision = "3";
    attachment.timestamp = "9999-01-01T00:00:00Z";
    attachment.conversation_id = try u.id(a);
    attachment.kind = .attachment;
    attachment.text = null;
    parts[1].state = .delivered;
    parts[1].message_id = attachment.id;
    request.revision = "4";
    request.state = .delivered;
    _ = try s.upsert(a, "request", try u.json(a, request));
    // Keep the summary until all linked records have been hydrated.
    try testing.expectEqual(@as(usize, 1), (try s.snapshot(a, key)).pending.len);
    _ = try s.upsert(a, "message", try u.json(a, attachment));
    const complete = try s.snapshot(a, key);
    try testing.expectEqual(@as(usize, 0), complete.pending.len);
    try testing.expectEqual(@as(usize, 2), complete.messages.len);
    try testing.expectEqualStrings(attachment.id, complete.messages[1].id);
    var versions = try s.db.prepare(history_versions_query);
    defer versions.close();
    try versions.bind(&.{.{ .text = key }});
    var count: usize = 0;
    while (try versions.step()) : (count += 1) {}
    try testing.expectEqual(@as(usize, 2), count);
}

pub fn enrichmentNext(
    s: Store,
    a: u.Allocator,
    id: []const u8,
    revision: []const u8,
    section: []const u8,
) ReadError!?[]const u8 {
    const q = try s.db.prepare("SELECT next FROM enrichment_pages WHERE message_id=? AND revision=? AND section=?");
    defer q.close();
    try q.bind(&.{
        .{ .text = id },
        .{ .text = revision },
        .{ .text = section },
    });
    if (!try q.step()) return "";
    return if (q.bytes(0).len == 0) null else try q.text(a, 0);
}
pub fn enrichmentPage(
    s: Store,
    a: u.Allocator,
    raw: []const u8,
    id: []const u8,
    revision: []const u8,
    section: content.Section,
    after: []const u8,
) EnrichmentPageError!bool {
    return switch (section) {
        inline else => |selected| s.enrichmentSection(selected, a, raw, id, revision, after),
    };
}

fn enrichmentSection(
    s: Store,
    comptime section: content.Section,
    a: u.Allocator,
    raw: []const u8,
    id: []const u8,
    revision: []const u8,
    after: []const u8,
) EnrichmentPageError!bool {
    const T = switch (section) {
        .attachments => t.Attachment,
        .previews => t.LinkPreview,
        .reactions => t.Reaction,
        .parts => t.MessagePart,
    };
    const Item = json_bounds.Decoded(T);
    try json_bounds.check(raw, t.max_metadata_page, 8192);
    const Page = struct {
        message_id: []const u8,
        revision: []const u8,
        section: content.Section,
        items: []const Item,
        total: usize,
        next: ?[]const u8,
    };
    const page_value = try std.json.parseFromSliceLeaky(
        Page,
        a,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    if (page_value.items.len > t.max_page or page_value.total > validation.max_section_items) return error.InvalidEnrichmentPage;
    if (!u.eq(page_value.message_id, id) or !u.eq(page_value.revision, revision) or page_value.section != section or (page_value.next != null and (u.eq(
        page_value.next.?,
        after,
    ) or page_value.items.len == 0))) return error.InvalidEnrichmentPage;
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    const q = try s.db.prepare(message_query);
    defer q.close();
    try q.bind(&.{.{ .text = id }});
    var m: t.Message = if (try q.step()) try std.json.parseFromSliceLeaky(
        t.Message,
        a,
        q.bytes(0),
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) else return error.MissingMessage;
    if (!u.eq(m.revision, revision)) {
        try s.db.exec("ROLLBACK");
        return false;
    }
    const expected = try s.enrichmentNext(a, id, revision, @tagName(section));
    if (expected == null or !u.eq(expected.?, after)) {
        try s.db.exec("ROLLBACK");
        return false;
    }
    var items: std.ArrayList(Item) = .empty;
    if (after.len > 0) {
        const previous = try s.db.prepare("SELECT items FROM enrichment_pages WHERE message_id=? AND section=? AND revision=?");
        defer previous.close();
        try previous.bind(&.{
            .{ .text = id },
            .{ .text = @tagName(section) },
            .{ .text = revision },
        });
        if (!try previous.step()) return error.InvalidEnrichmentPage;
        try items.appendSlice(
            a,
            try std.json.parseFromSliceLeaky([]const Item, a, try previous.text(a, 0), .{ .ignore_unknown_fields = true }),
        );
    }
    try items.appendSlice(a, page_value.items);
    if (items.items.len > page_value.total or (page_value.next == null and items.items.len != page_value.total)) return error.InvalidEnrichmentPage;
    if (m.enrichment == null) return error.InvalidEnrichmentPage;
    const aggregate = @field(m.enrichment.?, @tagName(section));
    if (page_value.total != aggregate.total or (page_value.next != null and items.items.len >= page_value.total)) return error.InvalidEnrichmentPage;
    const values = try a.alloc(T, items.items.len);
    const records = try a.alloc(Json, items.items.len);
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    for (items.items, values, records) |item, *value, *record| {
        value.* = item.value;
        record.* = .{ .bytes = item.raw };
        if (value.id.len == 0 or (try ids.getOrPut(a, value.id)).found_existing) return error.InvalidEnrichmentPage;
    }
    const field = comptime if (section == .previews) "link_previews" else @tagName(section);
    const current: []const T = if (section == .attachments) m.attachments else @field(m, field) orelse &.{};
    if (values.len >= current.len or page_value.next == null) @field(m, field) = values;
    @field(m.enrichment.?, @tagName(section)) = .{ .total = page_value.total, .complete = page_value.next == null };
    const encoded = try u.json(a, records);
    try validation.message(m);
    const record = try u.json(a, m);
    if (record.len > validation.max_expanded_bytes) return error.InvalidEnrichmentPage;
    try s.exec("INSERT INTO enrichment_pages VALUES(?,?,?,?,?) ON CONFLICT(message_id,section) DO UPDATE SET revision=excluded.revision,items=excluded.items,next=excluded.next", &.{
        .{ .text = id },
        .{ .text = @tagName(section) },
        .{ .text = revision },
        .{ .text = encoded },
        if (page_value.next) |next| .{ .text = next } else .null_value,
    });
    try s.exec("INSERT INTO enrichment_cache VALUES(?,?,?,1) ON CONFLICT(message_id) DO UPDATE SET revision=excluded.revision,record=excluded.record,serial=enrichment_cache.serial+1", &.{
        .{ .text = id },
        .{ .int = try std.fmt.parseInt(i64, revision, 10) },
        .{ .text = record },
    });
    try s.db.exec("COMMIT");
    return true;
}

pub fn directory(s: Store, a: u.Allocator) RecordError!Directory {
    var result = Directory{
        .available = !u.eq(try s.get(a, "contacts_blocked"), "1"),
    };
    const q = try s.db.prepare("SELECT record FROM identities");
    defer q.close();
    while (try q.step()) try result.put(
        a,
        try std.json.parseFromSliceLeaky(t.Identity, a, q.bytes(0), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }),
    );
    return result;
}

test "unknown sends expire at five minutes without dropping other states or returning on late updates" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const store = try Store.open(":memory:");
    defer store.close();
    const epoch = "EjRWeBI0EjQSNBI0VniQEg";
    try store.beginSync(epoch, epoch ++ ":0");
    const states = [_][]const u8{
        "unknown",
        "unknown",
        "sending",
        "queued",
        "dispatching",
        "submitted",
        "delivered",
        "failed",
        "unconfirmed",
    };
    const target = t.Target{ .recipient = .{
        .address = "peer@example.invalid",
        .service = "imessage",
    } };
    for (states, 0..) |state, i| {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, i, .big);
        const id = try ar.dupe(u8, &u.encodeId(bytes));
        try store.persistSend(ar, "chat", .{
            .request_id = id,
            .server_epoch = epoch,
            .target = target,
            .text = state,
        });
        try store.outcome(id, state, "");
        try store.exec("UPDATE outbox SET sent_at=? WHERE id=?", &.{
            .{ .text = if (i == 1) "2026-01-01T00:00:00.001000000Z" else "2026-01-01T00:00:00Z" },
            .{ .text = id },
        });
    }
    // 2026-01-01 00:05:00 UTC. Legacy timestamps omit fractional seconds.
    const deadline_ms = 1767225900000;
    try testing.expect(!try store.expireUnknown(deadline_ms - 1));
    try testing.expect(try store.expireUnknown(deadline_ms));
    const boundary = try store.snapshot(ar, "chat");
    try testing.expectEqual(@as(usize, 8), boundary.pending.len);
    try testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAQ", boundary.pending[0].input.request_id);
    try testing.expect(!try store.expireUnknown(deadline_ms));
    try testing.expect(try store.expireUnknown(deadline_ms + 1));
    const remaining = try store.snapshot(ar, "chat");
    try testing.expectEqual(@as(usize, 7), remaining.pending.len);
    for (remaining.pending, states[2..]) |pending, state| try testing.expectEqualStrings(state, pending.state);

    var late = t.SendRequest{
        .request_id = "AAAAAAAAAAAAAAAAAAAAAA",
        .server_epoch = epoch,
        .revision = "1",
        .target = target,
        .text = "unknown",
        .state = .unknown,
    };
    _ = try store.upsert(ar, "request", try u.json(ar, late));
    late.revision = "2";
    late.state = .delivered;
    _ = try store.upsert(ar, "request", try u.json(ar, late));
    try testing.expectEqual(@as(usize, 7), (try store.snapshot(ar, "chat")).pending.len);
    try testing.expectEqual(@as(i64, 0), try store.db.scalar("SELECT count(*) FROM outbox WHERE state='unknown'"));
}
