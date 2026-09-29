//! Durable ownership of local attachment originals. File preparation and cleanup
//! belong to Files; these operations change only the client cache transaction.
const std = @import("std");
const u = @import("../common.zig");
const protocol = @import("../protocol.zig");
const attachments = protocol.attachments;
const Store = @import("Store.zig");
pub const Files = @import("outgoing/Files.zig");

pub const max_stored_files = 256;
pub const max_stored_bytes = 2 * 1024 * 1024 * 1024;
pub const AddError = Store.ReadError || attachments.ValidateError || error{AttachmentStorageFull};
pub const TransferError = Store.RecordError || error{AttachmentDraftChanged};

/// A relay update may release local originals only for the immutable payload
/// saved under this request ID. Remote records for other devices have no owner.
pub fn validateRequest(s: Store, a: u.Allocator, value: protocol.types.SendRequest) (Store.RecordError || error{InvalidRecord})!void {
    const q = try s.db.prepare("SELECT payload FROM outbox WHERE id=?");
    defer q.close();
    try q.bind(&.{.{ .text = value.request_id }});
    if (!try q.step()) return;
    const expected = try std.json.parseFromSliceLeaky(protocol.types.SendInput, a, q.bytes(0), .{});
    if (expected.attachments.len == 0 and value.attachments.len == 0) return;
    if (!u.eq(expected.server_epoch, value.server_epoch) or !u.eq(expected.text, value.text) or
        !u.eq(try u.json(a, expected.target), try u.json(a, value.target)) or
        !u.eq(try u.json(a, expected.attachments), try u.json(a, value.attachments))) return error.InvalidRecord;
}

/// Return ordered metadata in the caller's arena. Drafts are independent of the
/// current relay epoch; local originals remain useful after a relay reset.
pub fn draft(s: Store, a: u.Allocator, key: []const u8) Store.RecordError![]const attachments.Upload {
    const canonical = try s.threadKey(a, key);
    const q = try s.db.prepare("SELECT record FROM outgoing_files WHERE draft_key=? ORDER BY rowid");
    defer q.close();
    try q.bind(&.{.{ .text = canonical }});
    var files: std.ArrayList(attachments.Upload) = .empty;
    while (try q.step()) try files.append(a, try std.json.parseFromSliceLeaky(
        attachments.Upload,
        a,
        q.bytes(0),
        .{ .allocate = .alloc_always },
    ));
    return files.items;
}

/// Check draft and disk quotas before copying. addDraft repeats this check in
/// its transaction, so a concurrent draft change cannot exceed the limits.
pub fn checkAdd(s: Store, a: u.Allocator, key: []const u8, file: attachments.Upload) AddError!void {
    const bytes = try attachments.validate(file);
    const canonical = try s.threadKey(a, key);
    const q = try s.db.prepare("SELECT count(*),coalesce(sum(bytes),0),count(CASE WHEN draft_key=? THEN 1 END),coalesce(sum(CASE WHEN draft_key=? THEN bytes END),0) FROM outgoing_files");
    defer q.close();
    try q.bind(&.{ .{ .text = canonical }, .{ .text = canonical } });
    std.debug.assert(try q.step());
    if (q.int(0) >= max_stored_files or @as(u64, @intCast(q.int(1))) + bytes > max_stored_bytes)
        return error.AttachmentStorageFull;
    if (q.int(2) >= attachments.max_files) return error.TooManyAttachments;
    if (@as(u64, @intCast(q.int(3))) + bytes > attachments.max_send_bytes)
        return error.AttachmentTooLarge;
}

/// Assume the private original has been fsynced. Ownership transfers to the
/// ledger only on success; the caller must remove the unowned file on failure.
pub fn addDraft(s: Store, a: u.Allocator, key: []const u8, file: attachments.Upload) AddError!void {
    try s.db.exec("BEGIN IMMEDIATE");
    errdefer s.db.exec("ROLLBACK") catch {};
    try checkAdd(s, a, key, file);
    try s.exec("INSERT INTO outgoing_files(id,draft_key,record,bytes) VALUES(?,?,?,?)", &.{
        .{ .text = file.id },
        .{ .text = try s.threadKey(a, key) },
        .{ .text = try u.json(a, file) },
        .{ .int = @intCast(try attachments.validate(file)) },
    });
    try s.db.exec("COMMIT");
}

/// Retire only this draft's file. Cleanup removes bytes before releasing quota.
pub fn removeDraft(s: Store, a: u.Allocator, key: []const u8, id: []const u8) Store.ReadError!void {
    try s.exec("UPDATE outgoing_files SET draft_key=NULL WHERE id=? AND draft_key=? AND request_id IS NULL", &.{
        .{ .text = id },
        .{ .text = try s.threadKey(a, key) },
    });
}

/// In persistSend's transaction, require exactly the reviewed files in their
/// original order, then transfer ownership to the durable outbox request.
pub fn transfer(s: Store, a: u.Allocator, key: []const u8, input: protocol.types.SendInput) TransferError!void {
    const files = try draft(s, a, key);
    if (files.len != input.attachments.len) return error.AttachmentDraftChanged;
    for (files, input.attachments) |saved, requested| {
        inline for (std.meta.fields(attachments.Upload)) |field| {
            if (!u.eq(@field(saved, field.name), @field(requested, field.name))) return error.AttachmentDraftChanged;
        }
    }
    try s.exec("UPDATE outgoing_files SET draft_key=NULL,request_id=? WHERE draft_key=?", &.{
        .{ .text = input.request_id },
        .{ .text = try s.threadKey(a, key) },
    });
}

/// Delivery ends local ownership. Failed or uncertain sends retain their files
/// for review; neither reconnect nor an epoch change authorizes another send.
pub fn delivered(s: Store, request_id: []const u8) Store.ReadError!void {
    try s.exec("UPDATE outgoing_files SET request_id=NULL WHERE request_id=?", &.{.{ .text = request_id }});
}

test "draft limits and global quotas include retired originals until physical cleanup" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Store.open(":memory:");
    defer s.close();
    var file: attachments.Upload = .{
        .id = try u.id(a),
        .name = "same-name.bin",
        .mime_type = "application/octet-stream",
        .bytes = "0",
        .sha256 = "0" ** 64,
    };
    for (0..attachments.max_files) |_| {
        file.id = try u.id(a);
        try addDraft(s, a, "chat", file);
    }
    try testing.expectError(error.TooManyAttachments, addDraft(s, a, "chat", file));
    try testing.expectEqual(@as(usize, attachments.max_files), (try draft(s, a, "chat")).len);
    try s.db.exec("DELETE FROM outgoing_files");
    file.bytes = "104857600";
    for (0..2) |_| {
        file.id = try u.id(a);
        try addDraft(s, a, "chat", file);
    }
    file.bytes = "1";
    try testing.expectError(error.AttachmentTooLarge, addDraft(s, a, "chat", file));
    file.bytes = "104857601";
    try testing.expectError(error.AttachmentTooLarge, addDraft(s, a, "other", file));
    try s.db.exec("DELETE FROM outgoing_files");
    file.bytes = "104857600";
    for (0..20) |i| {
        file.id = try u.id(a);
        try addDraft(s, a, try std.fmt.allocPrint(a, "chat-{d}", .{i}), file);
    }
    file.bytes = "50331648";
    file.id = try u.id(a);
    try addDraft(s, a, "last", file);
    try removeDraft(s, a, "last", file.id);
    file.bytes = "1";
    try testing.expectError(error.AttachmentStorageFull, addDraft(s, a, "last", file));
    try testing.expectEqual(@as(i64, max_stored_bytes), try s.db.scalar("SELECT sum(bytes) FROM outgoing_files"));
    try s.db.exec("DELETE FROM outgoing_files");
    file.bytes = "0";
    for (0..max_stored_files) |i| {
        file.id = try u.id(a);
        try addDraft(s, a, try std.fmt.allocPrint(a, "chat-{d}", .{i}), file);
    }
    try testing.expectError(error.AttachmentStorageFull, addDraft(s, a, "last", file));
}

test "merged conversation drafts preserve attachment order and immutable outbox ownership" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Store.open(":memory:");
    defer s.close();
    const root = try u.id(a);
    const alias = try u.id(a);
    try s.beginSync(root, try std.fmt.allocPrint(a, "{s}:0", .{root}));
    const first: attachments.Upload = .{
        .id = try u.id(a),
        .name = "one.bin",
        .mime_type = "application/octet-stream",
        .bytes = "0",
        .sha256 = "0" ** 64,
    };
    var second = first;
    second.id = try u.id(a);
    second.name = "two.bin";
    try addDraft(s, a, alias, first);
    try addDraft(s, a, root, second);
    for ([_][]const u8{ alias, root }) |id| _ = try s.upsert(a, "conversation", try u.json(a, protocol.types.Conversation{
        .id = id,
        .service = "imessage",
        .is_self = true,
        .thread_id = root,
    }));
    const combined = try draft(s, a, alias);
    try testing.expectEqual(@as(usize, 2), combined.len);
    try testing.expectEqualStrings(first.id, combined[0].id);
    try testing.expectEqualStrings(second.id, combined[1].id);
    const request_id = try u.id(a);
    try s.persistSend(a, alias, .{
        .request_id = request_id,
        .server_epoch = root,
        .target = .{ .conversation_id = alias },
        .text = "",
        .attachments = combined,
    });
    try testing.expectEqual(@as(usize, 0), (try draft(s, a, root)).len);
    try s.beginSync(alias, try std.fmt.allocPrint(a, "{s}:0", .{alias}));
    try testing.expect(!try s.expireUnknown(u.now() + 3600000));
    try testing.expectEqual(@as(i64, 2), try s.db.scalar("SELECT count(*) FROM outgoing_files WHERE request_id IS NOT NULL"));
    const q = try s.db.prepare("SELECT payload,state FROM outbox WHERE id=?");
    defer q.close();
    try q.bind(&.{.{ .text = request_id }});
    try testing.expect(try q.step());
    const input = try std.json.parseFromSliceLeaky(protocol.types.SendInput, a, q.bytes(0), .{});
    try testing.expectEqualStrings(alias, input.target.conversation_id.?);
    try testing.expectEqualStrings(first.id, input.attachments[0].id);
    try testing.expectEqualStrings("unknown", q.bytes(1));
}
