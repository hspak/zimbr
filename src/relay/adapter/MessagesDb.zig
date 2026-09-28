const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol.zig").types;
const Db = @import("../Sqlite.zig");
const decoder = @import("decoder.zig");
const links = @import("link_preview.zig");
const reactions = @import("reactions.zig");
const MessagesDb = @This();

db: Db,
identity: []const u8,
features: Features,

pub const Features = struct {
    attachment_filename: bool = false,
    attachment_uti: bool = false,
    attachment_transfer_state: bool = false,
    link_payload: bool = false,
    reaction_target: bool = false,
    reaction_emoji: bool = false,
    reaction_range: bool = false,
    self_chat_metadata: bool = false,
};
pub const SourceConversation = struct {
    source: []const u8,
    row: i64,
    route: []const u8,
    thread_row: ?i64 = null,
    value: t.Conversation,
};
pub const AttachmentSource = struct {
    id: []const u8,
    filename: []const u8,
    uti: []const u8,
    transfer_state: i64,
};
pub const SourceMessage = struct {
    source: []const u8,
    row: i64,
    date: i64,
    chat_row: i64,
    value: t.Message,
    pending: bool,
    attachment_sources: []const AttachmentSource = &.{},
    link_artwork: []const links.Artwork = &.{},
    reaction: ?reactions.Observation = null,
};

pub const OpenError = u.Allocator.Error || error{
    DatabaseBusy,
    DatabaseUnavailable,
    SchemaUnsupported,
};
pub const GuidError = Db.QueryError || u.Allocator.Error;
pub const ChatError = Db.QueryError || u.Allocator.Error || error{InvalidTimestamp};
pub const ChatRowsError = Db.QueryError;
pub const RowsForError = Db.QueryError;
pub const row_batch_size = 100;
const row_limit = std.fmt.comptimePrint(" LIMIT {d}", .{row_batch_size});
pub const MessageError = Db.QueryError || u.Allocator.Error || error{
    InvalidTimestamp,
    Malformed,
    Oversized,
    Unsupported,
};
pub const ValidateRouteError = Db.QueryError || error{UnsupportedTarget};

pub fn open(a: u.Allocator, path: [:0]const u8) OpenError!MessagesDb {
    const db = try Db.open(path, true);
    errdefer db.close();
    var buf: [128]u8 = undefined;
    const n = u.c.zr_file_identity(path, &buf, buf.len);
    if (n < 0) return error.DatabaseUnavailable;
    // Prepare exact required queries before advertising read capability.
    const validate = try db.prepare(message_sql ++ " WHERE m.ROWID=0");
    validate.close();
    const chats = try db.prepare("SELECT c.guid,c.service_name,c.display_name,h.id FROM chat c LEFT JOIN chat_handle_join j ON j.chat_id=c.ROWID LEFT JOIN handle h ON h.ROWID=j.handle_id LIMIT 0");
    chats.close();
    const attachments = try db.prepare("SELECT a.guid,a.transfer_name,a.mime_type,a.total_bytes FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID LIMIT 0");
    attachments.close();
    return .{
        .db = db,
        .identity = try a.dupe(u8, buf[0..@intCast(n)]),
        .features = .{
            .attachment_filename = probe(db, "SELECT filename FROM attachment LIMIT 0"),
            .attachment_uti = probe(db, "SELECT uti FROM attachment LIMIT 0"),
            .attachment_transfer_state = probe(db, "SELECT transfer_state FROM attachment LIMIT 0"),
            .link_payload = probe(db, "SELECT payload_data FROM message LIMIT 0"),
            .reaction_target = probe(db, "SELECT associated_message_guid FROM message LIMIT 0"),
            .reaction_emoji = probe(db, "SELECT associated_message_emoji FROM message LIMIT 0"),
            .reaction_range = probe(
                db,
                "SELECT associated_message_range_location,associated_message_range_length FROM message LIMIT 0",
            ),
            .self_chat_metadata = probe(
                db,
                "SELECT style,account_id,chat_identifier,last_addressed_handle,room_name FROM chat LIMIT 0",
            ),
        },
    };
}
fn probe(db: Db, query: [:0]const u8) bool {
    // Optional enrichment columns never enter the required history query.
    var s = db.prepare(query) catch return false;
    s.close();
    return true;
}
pub fn close(self: MessagesDb) void {
    self.db.close();
}
pub fn legacyIdentityCandidate(self: MessagesDb, saved: []const u8) bool {
    // Only upgrades from the old decimal device:inode format qualify. Core
    // additionally requires the saved nonempty row/GUID anchor to match before
    // adopting this volume UUID. Different modern identities always reset.
    if (!std.mem.startsWith(u8, self.identity, "mac-v1:")) return false;
    var old = std.mem.splitScalar(u8, saved, ':');
    _ = std.fmt.parseInt(u64, old.next() orelse return false, 10) catch return false;
    const inode = std.fmt.parseInt(u64, old.next() orelse return false, 10) catch return false;
    if (old.next() != null) return false;
    var current = std.mem.splitScalar(u8, self.identity, ':');
    _ = current.next(); // version
    _ = current.next(); // volume UUID
    return inode == (std.fmt.parseInt(u64, current.next() orelse return false, 10) catch return false);
}
pub fn high(self: MessagesDb) Db.QueryError!i64 {
    return self.db.scalar("SELECT coalesce(max(ROWID),0) FROM message");
}
pub fn guid(self: MessagesDb, a: u.Allocator, row: i64) GuidError!?[]const u8 {
    const s = try self.db.prepare("SELECT guid FROM message WHERE ROWID=?");
    defer s.close();
    try s.bind(&.{.{ .int = row }});
    return if (try s.step()) try s.text(a, 0) else null;
}
pub fn chat(self: MessagesDb, a: u.Allocator, row: i64, complete: bool) ChatError!?SourceConversation {
    const s = try self.db.prepare("SELECT guid," ++ effective_service ++ ",substr(coalesce(display_name,''),1,1024),(SELECT max(m.date) FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id WHERE j.chat_id=c.ROWID) FROM chat c WHERE ROWID=?");
    defer s.close();
    try s.bind(&.{.{ .int = row }});
    if (!try s.step()) return null;
    const p = try self.db.prepare("SELECT DISTINCT substr(h.id,1,254) FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=? ORDER BY h.id LIMIT 256");
    defer p.close();
    try p.bind(&.{.{ .int = row }});
    var participants: std.ArrayList([]const u8) = .empty;
    while (try p.step()) try participants.append(a, try p.text(a, 0));
    const source = try s.text(a, 0);
    const service = normalizeService(s.bytes(1));
    const thread_row = if (u.eq(service, "imessage")) try self.selfThread(row) else null;
    return .{
        .source = source,
        .row = row,
        .route = source,
        .thread_row = thread_row,
        .value = .{
            .participants = try participants.toOwnedSlice(a),
            .title = try s.text(a, 2),
            .service = service,
            .last_activity = if (s.int(3) != 0) try u.timestamp(a, s.int(3)) else null,
            .history_complete = complete,
            .sendable = u.eq(service, "imessage"),
            .is_self = thread_row != null,
        },
    };
}
// Modern Messages uses transport-neutral `any` routes. Their chat-level label
// can lag the actual transport; use the latest ordinary message, never a
// reaction, system event, or the order in which history happened to be imported.
const effective_service = "CASE WHEN c.guid LIKE 'any;%' THEN coalesce((SELECT m.service FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id WHERE j.chat_id=c.ROWID AND coalesce(m.associated_message_type,0)=0 AND coalesce(m.item_type,0)=0 AND coalesce(m.is_system_message,0)=0 ORDER BY m.date DESC,m.ROWID DESC LIMIT 1),c.service_name) ELSE c.service_name END";

fn selfThread(self: MessagesDb, row: i64) !?i64 {
    if (!self.features.self_chat_metadata) return null;
    // Only reciprocal local addresses in single-participant chats on the same
    // account prove this relationship. Contact names and outgoing handles do not.
    const q = try self.db.prepare(
        "SELECT min(c.ROWID,p.ROWID),p.ROWID FROM chat c JOIN chat p ON p.account_id=c.account_id AND p.chat_identifier=c.last_addressed_handle AND p.last_addressed_handle=c.chat_identifier " ++
            "WHERE c.ROWID=? AND c.ROWID!=p.ROWID AND c.account_id!='' AND c.chat_identifier!='' AND c.last_addressed_handle!='' AND c.chat_identifier!=c.last_addressed_handle " ++
            "AND c.style=45 AND p.style=45 AND coalesce(c.room_name,'')='' AND coalesce(p.room_name,'')='' " ++
            "AND (" ++ effective_service ++ ")='iMessage' " ++
            "AND (SELECT count(*) FROM chat_handle_join WHERE chat_id=c.ROWID)=1 AND (SELECT count(*) FROM chat_handle_join WHERE chat_id=p.ROWID)=1 " ++
            "AND EXISTS(SELECT 1 FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=c.ROWID AND h.id=c.chat_identifier) " ++
            "AND EXISTS(SELECT 1 FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=p.ROWID AND h.id=p.chat_identifier) " ++
            "AND (SELECT count(*) FROM chat x WHERE x.account_id=c.account_id AND x.chat_identifier=c.chat_identifier AND x.last_addressed_handle=c.last_addressed_handle AND x.style=45)=1 LIMIT 2",
    );
    defer q.close();
    try q.bind(&.{.{ .int = row }});
    if (!try q.step()) return null;
    const canonical = q.int(0);
    const peer = q.int(1);
    if (try q.step()) return null;
    const service = try self.db.prepare("SELECT " ++ effective_service ++ " FROM chat c WHERE ROWID=?");
    defer service.close();
    try service.bind(&.{.{ .int = peer }});
    if (!try service.step() or !u.eq(service.bytes(0), "iMessage")) return null;
    return canonical;
}
/// Returned row IDs borrow buffer until it is reused by the caller.
pub fn chatRows(self: MessagesDb, buffer: *[row_batch_size]i64, after: i64) ChatRowsError![]const i64 {
    const s = try self.db.prepare("SELECT ROWID FROM chat WHERE ROWID>? ORDER BY ROWID" ++ row_limit);
    defer s.close();
    try s.bind(&.{.{ .int = after }});
    return rows(buffer, s);
}
/// Reads at most buffer.len row IDs, borrowing buffer until the caller reuses it.
pub fn rowsFor(self: MessagesDb, buffer: []i64, mode: enum {
    live,
    backfill,
    recent,
    rolling,
    chat,
}, position: i64, chat_row: i64) RowsForError![]const i64 {
    const s = try self.db.prepare(switch (mode) {
        .live, .rolling => "SELECT ROWID FROM message WHERE ROWID>? ORDER BY ROWID LIMIT ?",
        .backfill => "SELECT ROWID FROM message WHERE ROWID<=? ORDER BY ROWID DESC LIMIT ?",
        .recent => "SELECT ROWID FROM message WHERE ROWID<=? ORDER BY ROWID DESC LIMIT ?",
        .chat => "SELECT message_id FROM chat_message_join WHERE message_id>? AND chat_id=? ORDER BY message_id LIMIT ?",
    });
    defer s.close();
    if (mode == .chat) try s.bind(&.{
        .{ .int = position },
        .{ .int = chat_row },
        .{ .int = @intCast(buffer.len) },
    }) else try s.bind(&.{ .{ .int = position }, .{ .int = @intCast(buffer.len) } });
    return rows(buffer, s);
}
fn rows(buffer: []i64, s: Db.Statement) ![]const i64 {
    var len: usize = 0;
    while (try s.step()) : (len += 1) buffer[len] = s.int(0);
    return buffer[0..len];
}

test "bounded row scans preserve ordering pagination and conversation filters" {
    const db = try Db.open(":memory:", false);
    defer db.close();
    try db.exec(
        \\CREATE TABLE message(id INTEGER PRIMARY KEY);
        \\CREATE TABLE chat(id INTEGER PRIMARY KEY);
        \\CREATE TABLE chat_message_join(message_id INTEGER,chat_id INTEGER);
        \\WITH RECURSIVE ids(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM ids WHERE id<101)
        \\INSERT INTO message SELECT id FROM ids;
        \\INSERT INTO chat SELECT id FROM message;
        \\INSERT INTO chat_message_join SELECT id,id%2 FROM message;
    );
    const source = MessagesDb{ .db = db, .identity = "fixture", .features = .{} };
    var buffer: [row_batch_size]i64 = undefined;
    const first = try source.rowsFor(&buffer, .live, 0, 0);
    try std.testing.expectEqual(buffer[0..].ptr, first.ptr);
    try std.testing.expectEqual(@as(usize, 100), first.len);
    try std.testing.expectEqual(@as(i64, 1), first[0]);
    try std.testing.expectEqual(@as(i64, 100), first[first.len - 1]);
    const tail = try source.rowsFor(&buffer, .rolling, 100, 0);
    try std.testing.expectEqualSlices(i64, &.{101}, tail);
    const backfill = try source.rowsFor(&buffer, .backfill, 101, 0);
    try std.testing.expectEqual(@as(usize, 100), backfill.len);
    try std.testing.expectEqual(@as(i64, 101), backfill[0]);
    try std.testing.expectEqual(@as(i64, 2), backfill[backfill.len - 1]);
    const recent = try source.rowsFor(&buffer, .recent, 2, 0);
    try std.testing.expectEqualSlices(i64, &.{ 2, 1 }, recent);
    const chat_rows = try source.rowsFor(&buffer, .chat, 96, 0);
    try std.testing.expectEqualSlices(i64, &.{ 98, 100 }, chat_rows);
    const chats = try source.chatRows(&buffer, 100);
    try std.testing.expectEqualSlices(i64, &.{101}, chats);
    const empty = try source.chatRows(&buffer, 101);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "row scans honor caller capacity including empty buffers" {
    const db = try Db.open(":memory:", false);
    defer db.close();
    try db.exec(
        \\CREATE TABLE message(id INTEGER PRIMARY KEY);
        \\CREATE TABLE chat_message_join(message_id INTEGER,chat_id INTEGER);
        \\INSERT INTO message VALUES(1),(3),(5),(7);
        \\INSERT INTO chat_message_join VALUES(1,2),(3,1),(5,2),(7,1);
    );
    const source = MessagesDb{ .db = db, .identity = "fixture", .features = .{} };
    var buffer: [4]i64 = @splat(-1);
    try std.testing.expectEqualSlices(i64, &.{ 7, 5 }, try source.rowsFor(buffer[0..2], .backfill, 7, 0));
    try std.testing.expectEqual(@as(i64, -1), buffer[2]);
    try std.testing.expectEqualSlices(i64, &.{ 3, 1 }, try source.rowsFor(buffer[0..2], .backfill, 4, 0));
    try std.testing.expectEqualSlices(i64, &.{7}, try source.rowsFor(buffer[0..1], .chat, 3, 1));
    try std.testing.expectEqual(@as(usize, 0), (try source.rowsFor(buffer[0..0], .live, 0, 0)).len);
    try std.testing.expectEqualSlices(i64, &.{
        1,
        3,
        5,
        7,
    }, try source.rowsFor(&buffer, .live, 0, 0));
}

const message_sql =
    "SELECT m.guid,m.date,substr(coalesce(h.id,''),1,254),m.is_from_me,m.service,substr(CAST(m.text AS BLOB),1,65537),CASE WHEN length(CAST(m.attributedBody AS BLOB))<=1048576 THEN m.attributedBody END,length(CAST(m.attributedBody AS BLOB)),m.is_delivered,m.date_delivered,m.error,m.is_sent,m.is_finished,m.associated_message_type,m.item_type,m.is_system_message,m.balloon_bundle_id,(SELECT min(chat_id) FROM chat_message_join WHERE message_id=m.ROWID) FROM message m LEFT JOIN handle h ON h.ROWID=m.handle_id";
pub fn message(self: MessagesDb, a: u.Allocator, row: i64) MessageError!?SourceMessage {
    const s = try self.db.prepare(message_sql ++ " WHERE m.ROWID=?");
    defer s.close();
    try s.bind(&.{.{ .int = row }});
    if (!try s.step()) return null;
    const plain = s.bytes(5);
    const body = s.bytes(6);
    var text: ?[]const u8 = null;
    var decoding: @FieldType(t.Message, "decoding") = .empty;
    if (plain.len > t.max_body or s.int(7) > t.max_decode) decoding = .oversized else if (plain.len > 0) {
        if (std.unicode.utf8ValidateSlice(plain) and std.mem.indexOfScalar(u8, plain, 0) == null) {
            text = try a.dupe(u8, plain);
            decoding = .plain;
        } else decoding = .malformed;
    } else if (body.len > 0) {
        text = decoder.decode(a, body) catch |err| text: {
            decoding = switch (err) {
                error.Unsupported => .unsupported,
                error.Oversized => .oversized,
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => .malformed,
            };
            break :text null;
        };
        if (text != null) decoding = .attributed;
    }
    var attachments: std.ArrayList(t.Attachment) = .empty;
    var attachment_sources: std.ArrayList(AttachmentSource) = .empty;
    var metadata_oversized = false;
    const attachment_query = try std.fmt.allocPrintSentinel(a, "SELECT substr(CAST(a.guid AS BLOB),1,1025),substr(coalesce(a.transfer_name,'Attachment'),1,255),substr(coalesce(a.mime_type,''),1,128),a.total_bytes,{s},{s},{s} FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID WHERE j.message_id=? ORDER BY a.ROWID LIMIT 1025", .{
        if (self.features.attachment_filename) "substr(CAST(coalesce(a.filename,'') AS BLOB),1,4097)" else "''",
        if (self.features.attachment_uti) "substr(coalesce(a.uti,''),1,128)" else "''",
        if (self.features.attachment_transfer_state) "coalesce(a.transfer_state,0)" else "0",
    }, 0);
    const att = try self.db.prepare(attachment_query);
    defer att.close();
    try att.bind(&.{.{ .int = row }});
    while (try att.step()) {
        if (attachments.items.len == 1024 or att.bytes(0).len > 1024) {
            metadata_oversized = true;
            attachments.clearRetainingCapacity();
            attachment_sources.clearRetainingCapacity();
            break;
        }
        // Attachment IDs are hashes of private GUIDs, never file paths.
        try attachments.append(a, .{
            .id = try a.dupe(u8, &u.hashId(att.bytes(0))),
            .name = try att.text(a, 1),
            .mime_type = try att.text(a, 2),
            .bytes = try u.decimal(a, att.int(3)),
        });
        if (self.features.attachment_filename) try attachment_sources.append(a, .{
            .id = attachments.items[attachments.items.len - 1].id,
            .filename = try att.text(a, 4),
            .uti = try att.text(a, 5),
            .transfer_state = att.int(6),
        });
    }
    const reaction = reactions.candidate(s.int(13));
    const system = s.int(14) != 0 or s.int(15) != 0;
    const special = s.bytes(16).len != 0 or (s.int(13) != 0 and !reaction);
    const kind: @FieldType(t.Message, "kind") = if (reaction) .reaction else if (system) .system else if (special) .unsupported else if (attachments.items.len > 0 or metadata_oversized) .attachment else if (text != null and text.?.len > 0) .text else if (decoding == .empty) .empty else .unsupported;
    const outgoing = s.int(3) != 0;
    var reaction_result: ?reactions.Observation = null;
    if (reaction and self.features.reaction_target) {
        const sql = try std.fmt.allocPrintSentinel(a, "SELECT substr(coalesce(associated_message_guid,''),1,1100),{s},{s},{s} FROM message WHERE ROWID=?", .{
            if (self.features.reaction_emoji) "substr(coalesce(associated_message_emoji,''),1,257)" else "''",
            if (self.features.reaction_range) "associated_message_range_location" else "NULL",
            if (self.features.reaction_range) "associated_message_range_length" else "NULL",
        }, 0);
        const associated = try self.db.prepare(sql);
        defer associated.close();
        try associated.bind(&.{.{ .int = row }});
        if (try associated.step()) {
            reaction_result = try reactions.decode(a, s.int(13), associated.bytes(0), associated.bytes(1), .{
                .service = normalizeService(s.bytes(4)),
                .is_self = outgoing,
                .address = if (outgoing) null else try s.text(a, 2),
            });
            if (reaction_result) |*result| if (self.features.reaction_range) {
                result.range_location = associated.int(2);
                result.range_length = associated.int(3);
            };
        }
    }
    var link_result: ?links.Result = null;
    if (self.features.link_payload) {
        link_result = .{ .state = .complete };
        if (u.eq(s.bytes(16), links.provider)) {
            const payload = try self.db.prepare("SELECT CASE WHEN length(CAST(payload_data AS BLOB))<=1048576 THEN payload_data END,length(CAST(payload_data AS BLOB)) FROM message WHERE ROWID=?");
            defer payload.close();
            try payload.bind(&.{.{ .int = row }});
            // Binary plist strings/data borrow the input. Keep it in the row
            // arena: SQLite's column buffer dies when this statement closes.
            if (try payload.step()) link_result = if (payload.int(1) > t.max_decode) .{ .state = .oversized } else try links.decode(
                a,
                try payload.text(a, 0),
            );
        }
    }
    if (link_result) |*result| result.artwork = try links.bindLocalArtwork(
        a,
        s.bytes(0),
        attachments.items,
        result.artwork,
    );
    const parts = if (!metadata_oversized and body.len > 0 and text != null and (link_result == null or link_result.?.previews.len == 0)) decoder.parts(
        a,
        body,
        text.?,
        attachments.items,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed, error.Oversized, error.Unsupported => null,
    } else null;
    return .{
        .source = try s.text(a, 0),
        .row = row,
        .date = s.int(1),
        .chat_row = s.int(17),
        .reaction = reaction_result,
        .attachment_sources = try attachment_sources.toOwnedSlice(a),
        .link_artwork = if (link_result) |result| result.artwork else &.{},
        .pending = s.bytes(0).len == 0 or s.int(17) == 0 or (decoding == .empty and (s.int(12) == 0 or kind == .empty)),
        .value = .{
            .sender = try s.text(a, 2),
            .direction = if (outgoing) .outgoing else .incoming,
            .service = normalizeService(s.bytes(4)),
            .timestamp = try u.timestamp(a, s.int(1)),
            .kind = kind,
            .text = text,
            .decoding = decoding,
            .attachments = try attachments.toOwnedSlice(a),
            .link_previews = if (link_result) |result| result.previews else null,
            .parts = parts,
            .enrichment = if (metadata_oversized or link_result != null or parts != null) .{ .state = if (metadata_oversized) .oversized else if (link_result) |result| result.state else .complete, .part_mapping = if (parts != null) .resolved else .unresolved } else null,
            .observed_status = if (s.int(10) != 0) .failed else if (!outgoing) .received else if (s.int(8) != 0 or s.int(9) > 0) .delivered else if (s.int(11) != 0) .sent else .unknown,
        },
    };
}
fn normalizeService(s: []const u8) []const u8 {
    return if (u.eq(s, "iMessage")) "imessage" else if (u.eq(s, "SMS")) "sms" else if (u.eq(
        s,
        "RCS",
    )) "rcs" else "unsupported";
}
pub fn validateRoute(self: MessagesDb, mode: []const u8, destination: []const u8) ValidateRouteError!void {
    if (u.eq(mode, "direct")) return;
    if (!u.eq(mode, "chat")) return error.UnsupportedTarget;
    const q = try self.db.prepare("SELECT count(*) FROM chat c WHERE guid=? AND (" ++ effective_service ++ ")='iMessage'");
    defer q.close();
    try q.bind(&.{.{ .text = destination }});
    _ = try q.step();
    if (q.int(0) != 1) return error.UnsupportedTarget;
}
