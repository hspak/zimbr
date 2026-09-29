//! Durable reservations and ownership for outgoing files. The caller serializes
//! access with the journal mutex; only immutable metadata is stored in SQLite.
const std = @import("std");
const u = @import("../common.zig");
const protocol = @import("../protocol.zig");
const t = protocol.types;
const attachments = protocol.attachments;
const Journal = @import("Journal.zig");
pub const Files = @import("uploads/Files.zig");

pub const max_reservations = 256;
pub const max_reserved_bytes = 2 * 1024 * 1024 * 1024;
pub const unused_lifetime_ms = 24 * 60 * 60 * 1000;

test {
    _ = Files;
}

pub const Phase = enum { reserved, receiving, ready, pinned, deleting };
pub const Record = struct {
    server_epoch: []const u8,
    file: attachments.Upload,
    phase: Phase,
};
/// Only the matching token may publish or abandon a transfer. All slices
/// belong to the allocator supplied to claim and must outlive the transfer.
pub const Lease = struct {
    server_epoch: []const u8,
    file: attachments.Upload,
    token: []const u8,
};
/// An allocation-free copy retained when releasing a disconnected writer fails.
pub const Release = struct {
    id: [u.id_length]u8,
    epoch: [u.id_length]u8,
    token: [u.id_length]u8,

    /// Assume lease was returned by claim, with canonical IDs.
    pub fn init(lease: Lease) Release {
        return .{
            .id = lease.file.id[0..u.id_length].*,
            .epoch = lease.server_epoch[0..u.id_length].*,
            .token = lease.token[0..u.id_length].*,
        };
    }

    /// Caller holds the journal mutex. Stale tokens cannot release a new writer.
    pub fn apply(self: Release, j: Journal) Journal.QueryError!void {
        try j.execute("UPDATE uploads SET state='reserved' WHERE id=? AND epoch=? AND lease=? AND state='receiving'", &.{
            .{ .text = &self.id },
            .{ .text = &self.epoch },
            .{ .text = &self.token },
        });
    }
};
pub const Claim = union(enum) {
    complete: Record,
    write: Lease,
};

pub const ReadError = Journal.RecordError || error{
    InvalidRequest,
    ResyncRequired,
    UploadNotFound,
    UploadExpired,
};
pub const ReserveError = ReadError || attachments.ValidateError || error{
    RequestConflict,
    UploadQuota,
};
pub const ClaimError = ReadError || error{ UploadBusy, RandomUnavailable };
pub const CompleteError = Journal.ReadError || error{ ResyncRequired, UploadLeaseExpired };
pub const CancelError = ReadError || error{ UploadBusy, UploadInUse };
pub const PinError = ReadError || attachments.ValidateError || error{ UploadNotReady, UploadInUse, RequestConflict };

/// Reserve space before accepting bytes. Owner is the authenticated device
/// fingerprint, never a caller-supplied JSON field. Exact retries retain phase.
/// Returned slices belong to a. This function owns its transaction.
pub fn reserve(
    j: Journal,
    a: u.Allocator,
    owner: []const u8,
    epoch: []const u8,
    file: attachments.Upload,
    now_ms: i64,
) ReserveError!Record {
    const size = try attachments.validate(file);
    try j.begin();
    errdefer j.rollback();
    try checkEpoch(j, a, epoch);
    const record = try u.json(a, file);
    const existing = try j.db.prepare("SELECT owner,epoch,record FROM uploads WHERE id=?");
    defer existing.close();
    try existing.bind(&.{.{ .text = file.id }});
    if (try existing.step()) {
        if (!u.eq(existing.bytes(0), owner)) return error.UploadNotFound;
        if (!u.eq(existing.bytes(1), epoch)) return error.UploadExpired;
        if (!u.eq(existing.bytes(2), record)) return error.RequestConflict;
        const found = try lookup(j, a, owner, epoch, file.id);
        try j.commit();
        return found;
    }
    const count = try j.db.scalar("SELECT count(*) FROM uploads");
    const used = try j.db.scalar("SELECT coalesce(sum(bytes),0) FROM uploads");
    if (count >= max_reservations or used > max_reserved_bytes - size) return error.UploadQuota;
    try j.execute("INSERT INTO uploads(id,epoch,owner,record,bytes,state,created_ms) VALUES(?,?,?,?,?,'reserved',?)", &.{
        .{ .text = file.id },
        .{ .text = epoch },
        .{ .text = owner },
        .{ .text = record },
        .{ .int = @intCast(size) },
        .{ .int = now_ms },
    });
    const result = try lookup(j, a, owner, epoch, file.id);
    try j.commit();
    return result;
}

/// Read one current-epoch upload owned by this device. Other devices' IDs are
/// indistinguishable from absence. Returned metadata belongs to a.
pub fn lookup(j: Journal, a: u.Allocator, owner: []const u8, epoch: []const u8, id: []const u8) ReadError!Record {
    if (!t.validId(id)) return error.InvalidRequest;
    try checkEpoch(j, a, epoch);
    const q = try j.db.prepare("SELECT epoch,record,state FROM uploads WHERE id=? AND owner=?");
    defer q.close();
    try q.bind(&.{ .{ .text = id }, .{ .text = owner } });
    if (!try q.step()) return error.UploadNotFound;
    if (!u.eq(q.bytes(0), epoch) or u.eq(q.bytes(2), "deleting")) return error.UploadExpired;
    return .{
        .server_epoch = try q.text(a, 0),
        .file = try std.json.parseFromSliceLeaky(attachments.Upload, a, q.bytes(1), .{ .allocate = .alloc_always }),
        .phase = std.meta.stringToEnum(Phase, q.bytes(2)) orelse return error.DatabaseFailure,
    };
}

/// Claim a single writer or return the already-completed immutable upload.
/// Call complete only after the file is verified and durably installed; call
/// abandon when the stream ends without publication. Owns its transaction.
pub fn claim(j: Journal, a: u.Allocator, owner: []const u8, epoch: []const u8, id: []const u8) ClaimError!Claim {
    try j.begin();
    errdefer j.rollback();
    const found = try lookup(j, a, owner, epoch, id);
    switch (found.phase) {
        .ready, .pinned => {
            try j.commit();
            return .{ .complete = found };
        },
        .receiving => return error.UploadBusy,
        .deleting => unreachable, // lookup rejects retired uploads.
        .reserved => {},
    }
    // A fresh token also rejects stale completions after an ID is purged/reused.
    const token = try u.id(a);
    try j.execute("UPDATE uploads SET state='receiving',lease=? WHERE id=?", &.{
        .{ .text = token },
        .{ .text = id },
    });
    try j.commit();
    return .{ .write = .{
        .server_epoch = found.server_epoch,
        .file = found.file,
        .token = token,
    } };
}

/// Publish a verified, fsynced file. The caller must have installed the complete
/// bytes before calling; a stale lease cannot publish into a replacement upload.
pub fn complete(j: Journal, a: u.Allocator, lease: Lease) CompleteError!void {
    if (!u.eq(lease.server_epoch, try j.epoch(a))) return error.ResyncRequired;
    try j.execute("UPDATE uploads SET state='ready' WHERE id=? AND epoch=? AND lease=? AND state='receiving'", &.{
        .{ .text = lease.file.id },
        .{ .text = lease.server_epoch },
        .{ .text = lease.token },
    });
    if (u.c.sqlite3_changes(j.db.handle) != 1) return error.UploadLeaseExpired;
}

/// Release an unfinished transfer after closing/removing its temporary files.
/// A late release is harmless after completion or after another transfer starts.
pub fn abandon(j: Journal, lease: Lease) Journal.QueryError!void {
    return Release.init(lease).apply(j);
}

/// Retire a reservation so no new writer or send can acquire it. Active writers
/// must be cancelled and closed first; files pinned by a send cannot be cancelled.
/// Physical removal and purge follow later. Owns its transaction.
pub fn cancel(j: Journal, a: u.Allocator, owner: []const u8, epoch: []const u8, id: []const u8) CancelError!void {
    try j.begin();
    errdefer j.rollback();
    const found = try lookup(j, a, owner, epoch, id);
    switch (found.phase) {
        .receiving => return error.UploadBusy,
        .pinned => return error.UploadInUse,
        .deleting => unreachable, // lookup rejects retired uploads.
        .reserved, .ready => {},
    }
    try j.execute("UPDATE uploads SET state='deleting' WHERE id=?", &.{.{ .text = id }});
    try j.commit();
}

/// Bind every file to one durable request in the caller's acceptance transaction.
/// The request row must already exist. Validate all files before mutating any;
/// the caller must roll back its transaction on any error.
pub fn pin(
    j: Journal,
    a: u.Allocator,
    owner: []const u8,
    epoch: []const u8,
    files: []const attachments.Upload,
    request_id: []const u8,
) PinError!void {
    try attachments.validateSet(files);
    for (files) |file| {
        const found = try lookup(j, a, owner, epoch, file.id);
        switch (found.phase) {
            .reserved, .receiving => return error.UploadNotReady,
            .pinned => return error.UploadInUse,
            .deleting => unreachable, // lookup rejects retired uploads.
            .ready => {},
        }
        if (!u.eq(try u.json(a, file), try u.json(a, found.file))) return error.RequestConflict;
    }
    for (files) |file| try j.execute("UPDATE uploads SET state='pinned',request_id=? WHERE id=?", &.{
        .{ .text = request_id },
        .{ .text = file.id },
    });
}

/// Called once before accepting connections, after removing interrupted files.
/// Pinned files retain their ownership even when a send's outcome is uncertain.
pub fn recover(j: Journal) Journal.QueryError!void {
    try j.db.exec("UPDATE uploads SET state='reserved' WHERE state='receiving'");
}

/// Mark unused reservations for physical cleanup. Active transfers and files
/// pinned by sends remain protected, including across epoch changes.
pub fn expire(j: Journal, now_ms: i64) Journal.QueryError!void {
    try j.execute("UPDATE uploads SET state='deleting' WHERE state IN ('reserved','ready') AND (created_ms<? OR epoch<>(SELECT epoch FROM relay_meta))", &.{
        .{ .int = now_ms - unused_lifetime_ms },
    });
}

/// Release quota only after physical removal succeeds. The retired row prevents
/// a concurrent retry from creating replacement files during cleanup.
pub fn purge(j: Journal, id: []const u8) Journal.QueryError!void {
    try j.execute("DELETE FROM uploads WHERE id=? AND state='deleting'", &.{.{ .text = id }});
}

fn checkEpoch(j: Journal, a: u.Allocator, epoch: []const u8) (Journal.ReadError || error{ InvalidRequest, ResyncRequired })!void {
    if (!t.validId(epoch)) return error.InvalidRequest;
    if (!u.eq(epoch, try j.epoch(a))) return error.ResyncRequired;
}

test "upload reservations preserve ownership metadata and phase on exact retries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    const epoch = try j.epoch(a);
    var file: attachments.Upload = .{
        .id = try u.id(a),
        .name = "photo.png",
        .mime_type = "image/png",
        .bytes = "4",
        .sha256 = "0123456789abcdef" ** 4,
    };
    try std.testing.expectEqual(Phase.reserved, (try reserve(j, a, "device-a", epoch, file, 100)).phase);
    const lease = (try claim(j, a, "device-a", epoch, file.id)).write;
    try std.testing.expectEqual(Phase.receiving, (try reserve(j, a, "device-a", epoch, file, 200)).phase);
    try std.testing.expectError(error.UploadBusy, claim(j, a, "device-a", epoch, file.id));
    try std.testing.expectError(error.UploadNotFound, lookup(j, a, "device-b", epoch, file.id));
    try std.testing.expectError(error.UploadNotFound, reserve(j, a, "device-b", epoch, file, 200));
    file.name = "changed.png";
    try std.testing.expectError(error.RequestConflict, reserve(j, a, "device-a", epoch, file, 200));
    try complete(j, a, lease);
    try std.testing.expectEqual(Phase.ready, (try claim(j, a, "device-a", epoch, file.id)).complete.phase);
    try abandon(j, lease);
    try std.testing.expectEqual(Phase.ready, (try lookup(j, a, "device-a", epoch, file.id)).phase);
    try std.testing.expectEqual(@as(i64, 1), try j.db.scalar("SELECT count(*) FROM uploads"));
    try std.testing.expectEqual(@as(i64, 100), try j.db.scalar("SELECT created_ms FROM uploads"));
}

test "stale upload leases cannot publish or abandon a replacement transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    const epoch = try j.epoch(a);
    const file: attachments.Upload = .{
        .id = try u.id(a),
        .name = "empty.txt",
        .mime_type = "text/plain",
        .bytes = "0",
        .sha256 = "0123456789abcdef" ** 4,
    };
    _ = try reserve(j, a, "device", epoch, file, 0);
    const first = (try claim(j, a, "device", epoch, file.id)).write;
    try std.testing.expectError(error.UploadBusy, cancel(j, a, "device", epoch, file.id));
    try abandon(j, first);
    const second = (try claim(j, a, "device", epoch, file.id)).write;
    try std.testing.expect(!u.eq(second.token, first.token));
    try std.testing.expectError(error.UploadLeaseExpired, complete(j, a, first));
    try abandon(j, first);
    try std.testing.expectEqual(Phase.receiving, (try lookup(j, a, "device", epoch, file.id)).phase);
    try recover(j);
    try std.testing.expectEqual(Phase.reserved, (try lookup(j, a, "device", epoch, file.id)).phase);
    const third = (try claim(j, a, "device", epoch, file.id)).write;
    try std.testing.expect(!u.eq(third.token, second.token));
    try std.testing.expectError(error.UploadLeaseExpired, complete(j, a, second));
    try complete(j, a, third);
    try cancel(j, a, "device", epoch, file.id);
    try std.testing.expectError(error.UploadExpired, lookup(j, a, "device", epoch, file.id));
    try std.testing.expectError(error.UploadExpired, reserve(j, a, "device", epoch, file, 1));
    try purge(j, file.id);
    try std.testing.expectError(error.UploadNotFound, lookup(j, a, "device", epoch, file.id));
    _ = try reserve(j, a, "device", epoch, file, 2);
    const replacement = (try claim(j, a, "device", epoch, file.id)).write;
    try std.testing.expectError(error.UploadLeaseExpired, complete(j, a, first));
    try abandon(j, first);
    try complete(j, a, replacement);
}

test "upload quotas account for declared bytes and empty-file reservations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    const epoch = try j.epoch(a);
    var file: attachments.Upload = .{
        .id = "",
        .name = "file.bin",
        .mime_type = "application/octet-stream",
        .bytes = "104857600",
        .sha256 = "0123456789abcdef" ** 4,
    };
    for (0..20) |_| {
        file.id = try u.id(a);
        _ = try reserve(j, a, "device", epoch, file, 0);
    }
    file.id = try u.id(a);
    try std.testing.expectError(error.UploadQuota, reserve(j, a, "device", epoch, file, 0));
    file.bytes = "50331648";
    _ = try reserve(j, a, "device", epoch, file, 0);
    file.id = try u.id(a);
    file.bytes = "1";
    try std.testing.expectError(error.UploadQuota, reserve(j, a, "device", epoch, file, 0));
    file.bytes = "0";
    for (21..max_reservations) |_| {
        file.id = try u.id(a);
        _ = try reserve(j, a, "device", epoch, file, 0);
    }
    file.id = try u.id(a);
    try std.testing.expectError(error.UploadQuota, reserve(j, a, "device", epoch, file, 0));
    try std.testing.expectEqual(@as(i64, max_reservations), try j.db.scalar("SELECT count(*) FROM uploads"));
    try expire(j, unused_lifetime_ms + 1);
    // Retirement still consumes quota until the physical files have been removed.
    try std.testing.expectError(error.UploadQuota, reserve(j, a, "device", epoch, file, unused_lifetime_ms + 1));
}

test "pinning validates the entire set and keeps uncertain files across resets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    const epoch = try j.epoch(a);
    const input: t.SendInput = .{
        .request_id = try u.id(a),
        .server_epoch = epoch,
        .target = .{ .recipient = .{ .address = "peer@example.invalid", .service = "imessage" } },
        .text = "caption",
    };
    _ = try j.accept(a, input, true);
    var files = [_]attachments.Upload{.{
        .id = try u.id(a),
        .name = "file.bin",
        .mime_type = "application/octet-stream",
        .bytes = "4",
        .sha256 = "0123456789abcdef" ** 4,
    }} ** 3;
    files[1].id = try u.id(a);
    files[2].id = try u.id(a);
    for (files) |file| _ = try reserve(j, a, "device", epoch, file, 0);
    const first = (try claim(j, a, "device", epoch, files[0].id)).write;
    const second = (try claim(j, a, "device", epoch, files[1].id)).write;
    const third = (try claim(j, a, "device", epoch, files[2].id)).write;
    try complete(j, a, first);
    try j.begin();
    try std.testing.expectError(error.UploadNotReady, pin(j, a, "device", epoch, files[0..2], input.request_id));
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM uploads WHERE state='pinned'"));
    j.rollback();
    try complete(j, a, second);
    files[1].name = "wrong-name.bin";
    try j.begin();
    try std.testing.expectError(error.RequestConflict, pin(j, a, "device", epoch, files[0..2], input.request_id));
    j.rollback();
    files[1].name = "file.bin";
    try j.db.exec("CREATE TRIGGER reject_second_pin BEFORE UPDATE ON uploads WHEN NEW.state='pinned' AND (SELECT count(*) FROM uploads WHERE state='pinned')=1 BEGIN SELECT RAISE(ABORT,'injected pin failure'); END");
    try j.begin();
    try std.testing.expectError(error.DatabaseFailure, pin(j, a, "device", epoch, files[0..2], input.request_id));
    j.rollback();
    try std.testing.expectEqual(@as(i64, 2), try j.db.scalar("SELECT count(*) FROM uploads WHERE state='ready'"));
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM uploads WHERE request_id IS NOT NULL"));
    try j.db.exec("DROP TRIGGER reject_second_pin");
    try j.begin();
    try pin(j, a, "device", epoch, files[0..2], input.request_id);
    try j.commit();
    try std.testing.expectError(error.UploadInUse, cancel(j, a, "device", epoch, files[0].id));
    try expire(j, unused_lifetime_ms + 1);
    try std.testing.expectEqual(@as(i64, 2), try j.db.scalar("SELECT count(*) FROM uploads WHERE state='pinned'"));
    try std.testing.expectEqual(@as(i64, 1), try j.db.scalar("SELECT count(*) FROM uploads WHERE state='receiving'"));
    try j.begin();
    try j.reset(a);
    try j.commit();
    try std.testing.expectError(error.ResyncRequired, complete(j, a, third));
    try abandon(j, third);
    try expire(j, 1);
    try std.testing.expectEqual(@as(i64, 2), try j.db.scalar("SELECT count(*) FROM uploads WHERE state='pinned'"));
    try std.testing.expectEqual(@as(i64, 1), try j.db.scalar("SELECT count(*) FROM uploads WHERE state='deleting'"));
}

test "upload leases and completed reservations survive closing and reopening the journal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/relay.db", .{tmp.sub_path}, 0);
    var interrupted: Lease = undefined;
    var ready_id: []const u8 = undefined;
    {
        const j = try Journal.open(path);
        defer j.close();
        const epoch = try j.epoch(a);
        var file: attachments.Upload = .{
            .id = try u.id(a),
            .name = "file.bin",
            .mime_type = "application/octet-stream",
            .bytes = "4",
            .sha256 = "0123456789abcdef" ** 4,
        };
        _ = try reserve(j, a, "device", epoch, file, 0);
        interrupted = (try claim(j, a, "device", epoch, file.id)).write;
        file.id = try u.id(a);
        ready_id = file.id;
        _ = try reserve(j, a, "device", epoch, file, 0);
        try complete(j, a, (try claim(j, a, "device", epoch, file.id)).write);
    }
    const reopened = try Journal.open(path);
    defer reopened.close();
    try std.testing.expectEqual(Phase.receiving, (try lookup(reopened, a, "device", interrupted.server_epoch, interrupted.file.id)).phase);
    try recover(reopened);
    const resumed = (try claim(reopened, a, "device", interrupted.server_epoch, interrupted.file.id)).write;
    try std.testing.expect(!u.eq(resumed.token, interrupted.token));
    try std.testing.expectError(error.UploadLeaseExpired, complete(reopened, a, interrupted));
    try std.testing.expectEqual(Phase.ready, (try lookup(reopened, a, "device", interrupted.server_epoch, ready_id)).phase);
}
