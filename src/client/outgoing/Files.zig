//! Private, immutable local attachment snapshots. One background owner performs
//! file preparation and cleanup; metadata commits through its own Store connection.
const std = @import("std");
const u = @import("../../common.zig");
const attachments = @import("../../protocol.zig").attachments;
const t = @import("../../protocol.zig").types;
const c = @import("../c.zig").api;
const Store = @import("../Store.zig");
const outgoing = @import("../outgoing.zig");
const Files = @This();

directory: c_int,

pub const InitError = u.Allocator.Error || error{AttachmentStorageUnavailable};
pub const StageError = outgoing.AddError || u.IdError || error{
    AttachmentStorageUnavailable,
    AttachmentSourceUnavailable,
    AttachmentSourceChanged,
    AttachmentCanceled,
};
pub const OpenError = attachments.ValidateError || error{AttachmentSourceUnavailable};
pub const CollectError = Store.ReadError || error{AttachmentStorageUnavailable};
pub const StageOptions = struct {
    path: []const u8,
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub fn init(a: u.Allocator, data: []const u8) InitError!Files {
    const path = try a.dupeZ(u8, data);
    defer a.free(path);
    const directory = c.zc_outgoing_directory(path);
    if (directory < 0) return error.AttachmentStorageUnavailable;
    return .{ .directory = directory };
}

pub fn deinit(self: *Files) void {
    _ = u.c.close(self.directory);
    self.* = undefined;
}

/// Copy a regular file in bounded chunks and publish its durable draft metadata.
/// The returned metadata belongs to a. On failure no draft ownership transfers;
/// an interrupted process may leave an orphan for startup collection.
pub fn stage(self: Files, a: u.Allocator, s: Store, key: []const u8, options: StageOptions) StageError!attachments.Upload {
    if (options.path.len == 0 or options.path.len > 4096 or
        !std.fs.path.isAbsolute(options.path) or std.mem.indexOfScalar(u8, options.path, 0) != null)
        return error.AttachmentSourceUnavailable;
    var before: c.ZcOutgoingFingerprint = undefined;
    const source = c.zc_outgoing_source(try a.dupeZ(u8, options.path), &before);
    if (source < 0) return error.AttachmentSourceUnavailable;
    defer _ = u.c.close(source);
    const name = std.fs.path.basename(options.path);
    var file: attachments.Upload = .{
        .id = try u.id(a),
        .name = try a.dupe(u8, name),
        .mime_type = mimeType(name),
        .bytes = try std.fmt.allocPrint(a, "{d}", .{before.bytes}),
        // Use a correctly shaped placeholder while validating metadata before computing the digest.
        .sha256 = "0" ** 64,
    };
    try outgoing.checkAdd(s, a, key, file);
    const id = try a.dupeZ(u8, file.id);
    const destination = c.zc_outgoing_create(self.directory, id);
    if (destination < 0) return error.AttachmentStorageUnavailable;
    defer _ = u.c.close(destination);
    errdefer _ = c.zc_outgoing_remove(self.directory, id);
    const digest = try copy(source, destination, before, options.cancel);
    file.sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    if (u.c.fsync(destination) != 0 or u.c.fsync(self.directory) != 0)
        return error.AttachmentStorageUnavailable;
    if (options.cancel) |cancel| if (cancel.load(.acquire)) return error.AttachmentCanceled;
    try outgoing.addDraft(s, a, key, file);
    errdefer comptime unreachable;
    return file;
}

fn copy(source: c_int, destination: c_int, before: c.ZcOutgoingFingerprint, cancel: ?*const std.atomic.Value(bool)) StageError![32]u8 {
    // Copy/hash in 64 KiB chunks so cancellation stays responsive and memory stays fixed.
    var buffer: [64 * 1024]u8 = undefined;
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var remaining = before.bytes;
    while (remaining != 0) {
        if (cancel) |stopped| if (stopped.load(.acquire)) return error.AttachmentCanceled;
        const n = u.c.read(source, &buffer, @min(remaining, buffer.len));
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return error.AttachmentSourceUnavailable;
        }
        if (n == 0) return error.AttachmentSourceChanged;
        const bytes = buffer[0..@intCast(n)];
        if (c.zc_outgoing_write(destination, bytes.ptr, bytes.len) == 0)
            return error.AttachmentStorageUnavailable;
        hash.update(bytes);
        remaining -= bytes.len;
    }
    var after: c.ZcOutgoingFingerprint = undefined;
    if (c.zc_outgoing_fingerprint(source, &after) == 0 or !std.meta.eql(before, after))
        return error.AttachmentSourceChanged;
    return hash.finalResult();
}

/// Open the private original at its exact recorded length. The caller owns the
/// returned descriptor; the ledger must retain ownership until it is closed.
pub fn open(self: Files, file: attachments.Upload) OpenError!c_int {
    const bytes = try attachments.validate(file);
    var id: [u.id_length:0]u8 = undefined;
    @memcpy(&id, file.id);
    id[u.id_length] = 0;
    const fd = c.zc_outgoing_open(self.directory, &id, bytes);
    if (fd < 0) return error.AttachmentSourceUnavailable;
    return fd;
}

/// Startup collection assumes no concurrent preparation. Routine collection
/// removes only retired ledger entries, leaving in-flight unowned copies alone.
pub fn collect(self: Files, s: Store, startup: bool) CollectError!void {
    if (startup) {
        const scan = c.zc_outgoing_scan(self.directory) orelse return error.AttachmentStorageUnavailable;
        defer c.zc_outgoing_scan_close(scan);
        var name: [u.id_length + 1]u8 = undefined;
        while (true) {
            const count = c.zc_outgoing_next(scan, &name, name.len);
            if (count == 0) break;
            if (count < 0) return error.AttachmentStorageUnavailable;
            const id = name[0..@intCast(count)];
            if (!t.validId(id)) continue;
            const q = try s.db.prepare("SELECT 1 FROM outgoing_files WHERE id=? AND (draft_key IS NOT NULL OR request_id IS NOT NULL)");
            defer q.close();
            try q.bind(&.{.{ .text = id }});
            if (!try q.step() and c.zc_outgoing_remove(self.directory, &name) == 0)
                return error.AttachmentStorageUnavailable;
        }
    }
    const retired = try s.db.prepare("SELECT id FROM outgoing_files WHERE draft_key IS NULL AND request_id IS NULL");
    defer retired.close();
    while (try retired.step()) {
        const id = retired.bytes(0);
        if (!t.validId(id)) return error.AttachmentStorageUnavailable;
        var name: [u.id_length:0]u8 = undefined;
        @memcpy(&name, id);
        name[u.id_length] = 0;
        if (c.zc_outgoing_remove(self.directory, &name) == 0) return error.AttachmentStorageUnavailable;
        try s.exec("DELETE FROM outgoing_files WHERE id=? AND draft_key IS NULL AND request_id IS NULL", &.{.{ .text = &name }});
    }
}

fn mimeType(name: []const u8) []const u8 {
    const extension = std.fs.path.extension(name);
    const known = .{
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".heic", "image/heic" },
        .{ ".pdf", "application/pdf" },
        .{ ".txt", "text/plain" },
    };
    inline for (known) |pair| if (std.ascii.eqlIgnoreCase(extension, pair[0])) return pair[1];
    return "application/octet-stream";
}

test "local attachment originals survive source changes restart and relay reset" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try testRoot(a, tmp.sub_path);
    const db = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{root}, 0);
    const source = try std.fmt.allocPrintSentinel(a, "{s}/photo 👋.PNG", .{root}, 0);
    const bytes = "\x00\x01image original\xff";
    try testWrite(source, bytes);
    const epoch = try u.id(a);
    var first: attachments.Upload = undefined;
    {
        const s = try Store.open(db);
        defer s.close();
        try s.beginSync(epoch, try std.fmt.allocPrint(a, "{s}:0", .{epoch}));
        var files = try Files.init(a, root);
        defer files.deinit();
        first = try files.stage(a, s, "new:alice@example.invalid", .{ .path = source });
        try testing.expectEqualStrings("photo 👋.PNG", first.name);
        try testing.expectEqualStrings("image/png", first.mime_type);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        try testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), first.sha256);
        try testing.expectEqual(@as(usize, 1), (try s.snapshot(a, "new:alice@example.invalid")).draft_attachments.len);
        try testWrite(source, "Changed source");
        const second = try files.stage(a, s, "other", .{ .path = source });
        try testing.expect(!u.eq(first.id, second.id));
        try testing.expect(!u.eq(first.sha256, second.sha256));
        try testBytes(files, first, bytes);
        try testBytes(files, second, "Changed source");
        try outgoing.removeDraft(s, a, "wrong-draft", first.id);
        try files.collect(s, false);
        try testBytes(files, first, bytes);
        try outgoing.removeDraft(s, a, "other", second.id);
        try files.collect(s, false);
        try testing.expectError(error.AttachmentSourceUnavailable, files.open(second));
    }
    try testing.expectEqual(@as(c_int, 0), u.c.unlink(source));
    {
        const s = try Store.open(db);
        defer s.close();
        var files = try Files.init(a, root);
        defer files.deinit();
        try files.collect(s, true);
        try testBytes(files, first, bytes);
        const next_epoch = try u.id(a);
        try s.beginSync(next_epoch, try std.fmt.allocPrint(a, "{s}:0", .{next_epoch}));
        const snapshot = try s.snapshot(a, "new:alice@example.invalid");
        try testing.expectEqual(@as(usize, 1), snapshot.chats.len);
        try testing.expectEqualStrings(first.id, snapshot.draft_attachments[0].id);
        try outgoing.removeDraft(s, a, snapshot.selected, first.id);
        try testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outgoing_files"));
        try files.collect(s, false);
        try testing.expectError(error.AttachmentSourceUnavailable, files.open(first));
        try testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM outgoing_files"));
    }
}

test "attachment outbox ownership commits atomically and rejects changed drafts and false delivery" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try testRoot(a, tmp.sub_path);
    const s = try Store.open(":memory:");
    defer s.close();
    var files = try Files.init(a, root);
    defer files.deinit();
    const source = try std.fmt.allocPrintSentinel(a, "{s}/empty.bin", .{root}, 0);
    try testWrite(source, "");
    const epoch = try u.id(a);
    try s.beginSync(epoch, try std.fmt.allocPrint(a, "{s}:0", .{epoch}));
    try s.saveDraft("chat", "caption");
    const file = try files.stage(a, s, "chat", .{ .path = source });
    var input: t.SendInput = .{
        .request_id = try u.id(a),
        .server_epoch = epoch,
        .target = .{ .recipient = .{ .address = "alice@example.invalid", .service = "imessage" } },
        .text = "caption",
    };
    try testing.expectError(error.AttachmentDraftChanged, s.persistSend(a, "chat", input));
    var changed = file;
    changed.name = "other.bin";
    input.attachments = &.{changed};
    try testing.expectError(error.AttachmentDraftChanged, s.persistSend(a, "chat", input));
    input.attachments = &.{file};
    try s.db.exec("CREATE TRIGGER reject_send BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT,'fixture'); END");
    try testing.expectError(error.DatabaseFailure, s.persistSend(a, "chat", input));
    try testing.expectEqual(@as(usize, 1), (try outgoing.draft(s, a, "chat")).len);
    try testing.expectEqualStrings("caption", try s.draft(a, "chat"));
    try testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM outbox"));
    try s.db.exec("DROP TRIGGER reject_send");
    try s.persistSend(a, "chat", input);
    try testing.expectEqual(@as(usize, 0), (try outgoing.draft(s, a, "chat")).len);
    try testing.expectEqualStrings("", try s.draft(a, "chat"));
    try testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='uploading'"));
    try files.collect(s, true);
    try testBytes(files, file, "");
    try s.outcome(input.request_id, "unknown", "Connection interrupted");
    try testing.expect(!try s.expireUnknown(u.now() + 3600000));
    try testBytes(files, file, "");
    var parts = [_]t.SendPart{
        .{ .kind = .text, .state = .delivered },
        .{
            .kind = .attachment,
            .attachment_id = file.id,
            .state = .delivered,
        },
    };
    var delivered: t.SendRequest = .{
        .request_id = input.request_id,
        .server_epoch = epoch,
        .revision = "10",
        .target = input.target,
        .text = input.text,
        .attachments = input.attachments,
        .parts = &parts,
        .state = .delivered,
    };
    delivered.attachments = &.{changed};
    try testing.expectError(error.InvalidRecord, s.upsert(a, "request", try u.json(a, delivered)));
    delivered.attachments = input.attachments;
    delivered.text = "wrong caption";
    try testing.expectError(error.InvalidRecord, s.upsert(a, "request", try u.json(a, delivered)));
    delivered.text = input.text;
    parts[1].state = .invoked;
    try testing.expectError(error.InvalidRecord, s.upsert(a, "request", try u.json(a, delivered)));
    parts[1].state = .delivered;
    try s.db.exec("CREATE TRIGGER reject_retirement BEFORE UPDATE ON outgoing_files WHEN NEW.request_id IS NULL BEGIN SELECT RAISE(ABORT,'fixture'); END");
    try testing.expectError(error.DatabaseFailure, s.upsert(a, "request", try u.json(a, delivered)));
    try testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outgoing_files WHERE request_id IS NOT NULL"));
    try testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='unknown'"));
    try testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM records WHERE kind='request'"));
    try s.db.exec("DROP TRIGGER reject_retirement");
    _ = try s.upsert(a, "request", try u.json(a, delivered));
    try testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='delivered'"));
    try files.collect(s, false);
    try testing.expectError(error.AttachmentSourceUnavailable, files.open(file));
}

test "snapshot failures leave no draft and collection distinguishes active files from crash orphans" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try testRoot(a, tmp.sub_path);
    const s = try Store.open(":memory:");
    defer s.close();
    var files = try Files.init(a, root);
    defer files.deinit();
    const source = try std.fmt.allocPrintSentinel(a, "{s}/file.bin", .{root}, 0);
    try testWrite(source, "contents");
    var cancel: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.AttachmentCanceled, files.stage(a, s, "chat", .{ .path = source, .cancel = &cancel }));
    try s.db.exec("CREATE TRIGGER reject_file BEFORE INSERT ON outgoing_files BEGIN SELECT RAISE(ABORT,'fixture'); END");
    try testing.expectError(error.DatabaseFailure, files.stage(a, s, "chat", .{ .path = source }));
    try testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM outgoing_files"));
    try s.db.exec("DROP TRIGGER reject_file");
    const scan = c.zc_outgoing_scan(files.directory).?;
    defer c.zc_outgoing_scan_close(scan);
    var name: [23]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), c.zc_outgoing_next(scan, &name, name.len));
    const id = try a.dupeZ(u8, try u.id(a));
    const orphan = c.zc_outgoing_create(files.directory, id);
    try testing.expect(orphan >= 0);
    _ = u.c.close(orphan);
    try files.collect(s, false);
    const active = c.zc_outgoing_open(files.directory, id, 0);
    try testing.expect(active >= 0);
    _ = u.c.close(active);
    try files.collect(s, true);
    try testing.expectEqual(@as(c_int, -1), c.zc_outgoing_open(files.directory, id, 0));
    const link = try std.fmt.allocPrintSentinel(a, "{s}/link.bin", .{root}, 0);
    try testing.expectEqual(@as(c_int, 0), u.c.symlink(source, link));
    try testing.expectError(error.AttachmentSourceUnavailable, files.stage(a, s, "chat", .{ .path = link }));
    try testing.expectError(error.AttachmentSourceUnavailable, files.stage(a, s, "chat", .{ .path = root }));
    const fifo = try std.fmt.allocPrintSentinel(a, "{s}/fifo", .{root}, 0);
    try testing.expectEqual(@as(c_int, 0), u.c.mkfifo(fifo, 0o600));
    try testing.expectError(error.AttachmentSourceUnavailable, files.stage(a, s, "chat", .{ .path = fifo }));
    var before: c.ZcOutgoingFingerprint = undefined;
    const fd = c.zc_outgoing_source(source, &before);
    try testing.expect(fd >= 0);
    defer _ = u.c.close(fd);
    try testWrite(source, "short");
    const destination = c.zc_outgoing_create(files.directory, id);
    try testing.expect(destination >= 0);
    defer _ = u.c.close(destination);
    try testing.expectError(error.AttachmentSourceChanged, copy(fd, destination, before, null));
}

fn testRoot(a: u.Allocator, sub_path: [std.fs.base64_encoder.calcSize(12)]u8) ![:0]const u8 {
    var cwd: [std.fs.max_path_bytes]u8 = undefined;
    const current = u.c.getcwd(&cwd, cwd.len) orelse return error.TestUnexpectedResult;
    return std.fmt.allocPrintSentinel(a, "{s}/.zig-cache/tmp/{s}", .{ std.mem.span(current), sub_path }, 0);
}

fn testWrite(path: [:0]const u8, bytes: []const u8) !void {
    const fd = u.c.open(path, u.c.O_WRONLY | u.c.O_CREAT | u.c.O_TRUNC | u.c.O_CLOEXEC, @as(c_uint, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = u.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 1), c.zc_outgoing_write(fd, bytes.ptr, bytes.len));
}

fn testBytes(files: Files, file: attachments.Upload, expected: []const u8) !void {
    const fd = try files.open(file);
    defer _ = u.c.close(fd);
    const buffer = try std.testing.allocator.alloc(u8, expected.len + 1);
    defer std.testing.allocator.free(buffer);
    const count = u.c.read(fd, buffer.ptr, buffer.len);
    try std.testing.expectEqual(@as(isize, @intCast(expected.len)), count);
    try std.testing.expectEqualSlices(u8, expected, buffer[0..@intCast(count)]);
}
