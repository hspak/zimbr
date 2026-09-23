const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol/types.zig");
const Db = @import("../Sqlite.zig");
const decoder = @import("decoder.zig");
const Self = @This();
db: Db,
identity: []const u8,
pub const SourceConversation = struct { source: []const u8, row: i64, route: []const u8, value: t.Conversation };
pub const SourceMessage = struct { source: []const u8, row: i64, date: i64, chat_row: i64, value: t.Message, pending: bool };
pub fn open(a: u.Allocator, path: [:0]const u8) !Self {
    const db = try Db.open(path, true);
    errdefer db.close();
    var buf: [128]u8 = undefined;
    const n = u.c.zr_file_identity(path, &buf, buf.len);
    if (n < 0) return error.DatabaseUnavailable;
    // Prepare exact required queries before advertising read capability.
    var validate = try db.prepare(message_sql ++ " WHERE m.ROWID=0");
    validate.close();
    var chats = try db.prepare("SELECT c.guid,c.service_name,c.display_name,h.id FROM chat c LEFT JOIN chat_handle_join j ON j.chat_id=c.ROWID LEFT JOIN handle h ON h.ROWID=j.handle_id LIMIT 0");
    chats.close();
    var attachments = try db.prepare("SELECT a.guid,a.transfer_name,a.mime_type,a.total_bytes FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID LIMIT 0");
    attachments.close();
    return .{ .db = db, .identity = try a.dupe(u8, buf[0..@intCast(n)]) };
}
pub fn close(self: Self) void {
    self.db.close();
}
pub fn high(self: Self) !i64 {
    return self.db.scalar("SELECT coalesce(max(ROWID),0) FROM message");
}
pub fn guid(self: Self, a: u.Allocator, row: i64) !?[]const u8 {
    var s = try self.db.prepare("SELECT guid FROM message WHERE ROWID=?");
    defer s.close();
    try s.bind(&.{.{ .int = row }});
    return if (try s.step()) try s.text(a, 0) else null;
}
pub fn chat(self: Self, a: u.Allocator, row: i64, complete: bool) !?SourceConversation {
    var s = try self.db.prepare("SELECT guid,service_name,substr(coalesce(display_name,''),1,1024),(SELECT max(m.date) FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id WHERE j.chat_id=c.ROWID) FROM chat c WHERE ROWID=?");
    defer s.close();
    try s.bind(&.{.{ .int = row }});
    if (!try s.step()) return null;
    var p = try self.db.prepare("SELECT DISTINCT substr(h.id,1,254) FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=? ORDER BY h.id LIMIT 256");
    defer p.close();
    try p.bind(&.{.{ .int = row }});
    var participants: std.ArrayList([]const u8) = .empty;
    while (try p.step()) try participants.append(a, try p.text(a, 0));
    const source = try s.text(a, 0);
    const service = normalizeService(s.bytes(1));
    return .{ .source = source, .row = row, .route = source, .value = .{ .participants = try participants.toOwnedSlice(a), .title = try s.text(a, 2), .service = service, .last_activity = if (s.int(3) != 0) try u.timestamp(a, s.int(3)) else null, .history_complete = complete, .sendable = u.eq(service, "imessage") } };
}
pub fn chatRows(self: Self, a: u.Allocator, after: i64) ![]i64 {
    var s = try self.db.prepare("SELECT ROWID FROM chat WHERE ROWID>? ORDER BY ROWID LIMIT 100");
    defer s.close();
    try s.bind(&.{.{ .int = after }});
    return rows(a, s);
}
pub fn rowsFor(self: Self, a: u.Allocator, mode: enum { live, backfill, recent, rolling, chat }, position: i64, chat_row: i64) ![]i64 {
    var s = try self.db.prepare(switch (mode) {
        .live, .rolling => "SELECT ROWID FROM message WHERE ROWID>? ORDER BY ROWID LIMIT 100",
        .backfill => "SELECT ROWID FROM message WHERE ROWID<=? ORDER BY ROWID DESC LIMIT 100",
        .recent => "SELECT ROWID FROM message WHERE ROWID<=? ORDER BY ROWID DESC LIMIT 100",
        .chat => "SELECT message_id FROM chat_message_join WHERE message_id>? AND chat_id=? ORDER BY message_id LIMIT 100",
    });
    defer s.close();
    if (mode == .chat) try s.bind(&.{ .{ .int = position }, .{ .int = chat_row } }) else try s.bind(&.{.{ .int = position }});
    return rows(a, s);
}
fn rows(a: u.Allocator, s: Db.Statement) ![]i64 {
    var out: std.ArrayList(i64) = .empty;
    while (try s.step()) try out.append(a, s.int(0));
    return out.toOwnedSlice(a);
}
const message_sql =
    "SELECT m.guid,m.date,substr(coalesce(h.id,''),1,254),m.is_from_me,m.service,substr(m.text,1,65537),CASE WHEN length(m.attributedBody)<=1048576 THEN m.attributedBody END,length(m.attributedBody),m.is_delivered,m.date_delivered,m.error,m.is_sent,m.is_finished,m.associated_message_type,m.item_type,m.is_system_message,m.balloon_bundle_id,(SELECT min(chat_id) FROM chat_message_join WHERE message_id=m.ROWID) FROM message m LEFT JOIN handle h ON h.ROWID=m.handle_id";
pub fn message(self: Self, a: u.Allocator, row: i64) !?SourceMessage {
    var s = try self.db.prepare(message_sql ++ " WHERE m.ROWID=?");
    defer s.close();
    try s.bind(&.{.{ .int = row }});
    if (!try s.step()) return null;
    const plain = s.bytes(5);
    const body = s.bytes(6);
    var text: ?[]const u8 = null;
    var decoding: @FieldType(t.Message, "decoding") = .empty;
    if (plain.len > t.max_body or s.int(7) > t.max_decode) decoding = .oversized else if (plain.len > 0) {
        if (std.unicode.utf8ValidateSlice(plain)) {
            text = try a.dupe(u8, plain);
            decoding = .plain;
        } else decoding = .malformed;
    } else if (body.len > 0) {
        text = decoder.decode(a, body) catch |err| blk: {
            decoding = switch (err) {
                error.Unsupported => .unsupported,
                error.Oversized => .oversized,
                else => .malformed,
            };
            break :blk null;
        };
        if (text != null) decoding = .attributed;
    }
    var attachments: std.ArrayList(t.Attachment) = .empty;
    var att = try self.db.prepare("SELECT a.guid,substr(coalesce(a.transfer_name,'Attachment'),1,255),substr(coalesce(a.mime_type,''),1,128),a.total_bytes FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID WHERE j.message_id=? ORDER BY a.ROWID LIMIT 32");
    defer att.close();
    try att.bind(&.{.{ .int = row }});
    while (try att.step()) {
        // Attachment IDs are hashes of private GUIDs, never file paths.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(att.bytes(0), &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try attachments.append(a, .{ .id = try a.dupe(u8, &hex), .name = try att.text(a, 1), .mime_type = try att.text(a, 2), .bytes = try u.decimal(a, att.int(3)) });
    }
    const reaction = s.int(13) >= 2000 and s.int(13) < 4000;
    const system = s.int(14) != 0 or s.int(15) != 0;
    const special = s.bytes(16).len != 0 or (s.int(13) != 0 and !reaction);
    const kind: @FieldType(t.Message, "kind") = if (reaction) .reaction else if (system) .system else if (special) .unsupported else if (attachments.items.len > 0) .attachment else if (text != null and text.?.len > 0) .text else if (decoding == .empty) .empty else .unsupported;
    const outgoing = s.int(3) != 0;
    return .{ .source = try s.text(a, 0), .row = row, .date = s.int(1), .chat_row = s.int(17), .pending = s.bytes(0).len == 0 or s.int(17) == 0 or (decoding == .empty and (s.int(12) == 0 or kind == .empty)), .value = .{
        .sender = try s.text(a, 2),
        .direction = if (outgoing) .outgoing else .incoming,
        .service = normalizeService(s.bytes(4)),
        .timestamp = try u.timestamp(a, s.int(1)),
        .kind = kind,
        .text = text,
        .decoding = decoding,
        .attachments = try attachments.toOwnedSlice(a),
        .observed_status = if (s.int(10) != 0) .failed else if (!outgoing) .received else if (s.int(8) != 0 or s.int(9) > 0) .delivered else if (s.int(11) != 0) .sent else .unknown,
    } };
}
fn normalizeService(s: []const u8) []const u8 {
    return if (u.eq(s, "iMessage")) "imessage" else if (u.eq(s, "SMS")) "sms" else if (u.eq(s, "RCS")) "rcs" else "unsupported";
}
pub fn validateRoute(self: Self, mode: []const u8, destination: []const u8) !void {
    if (u.eq(mode, "direct")) return;
    if (!u.eq(mode, "chat")) return error.UnsupportedTarget;
    var q = try self.db.prepare("SELECT count(*) FROM chat WHERE guid=? AND service_name='iMessage'");
    defer q.close();
    try q.bind(&.{.{ .text = destination }});
    _ = try q.step();
    if (q.int(0) != 1) return error.UnsupportedTarget;
}
