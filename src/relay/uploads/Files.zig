//! Private upload directories preserve original basenames and own immutable bytes.
//! File writes and fsync run outside the journal mutex on the connection owner.
const std = @import("std");
const u = @import("../../common.zig");
const attachments = @import("../../protocol.zig").attachments;
const t = @import("../../protocol.zig").types;
const uploads = @import("../uploads.zig");
const c = @cImport({
    @cInclude("relay/media.h");
    @cInclude("relay/uploads.h");
});
const Files = @This();

root: []const u8,
directory: c_int,

pub const InitError = u.Allocator.Error || error{UploadStorageUnavailable};
pub const BeginError = InitError || attachments.ValidateError;
pub const OpenError = u.Allocator.Error || attachments.ValidateError || error{UploadFileUnavailable};
pub const RemoveError = error{ InvalidRequest, UploadStorageUnavailable };

/// Allocated paths belong to a and must outlive the returned descriptor owner.
pub fn init(a: u.Allocator, data: []const u8) InitError!Files {
    const root = try std.fmt.allocPrintSentinel(a, "{s}/uploads", .{data}, 0);
    const directory = c.zr_media_directory(root, 1);
    if (directory < 0) return error.UploadStorageUnavailable;
    return .{ .root = root, .directory = directory };
}

pub fn deinit(self: *Files) void {
    _ = u.c.close(self.directory);
    self.* = undefined;
}

/// Assume lease exclusively owns this upload. Removes only that ID's previous
/// interrupted files. The returned transfer borrows self and lease's slices;
/// its allocated names belong to a. No file is published on failure.
pub fn begin(self: Files, a: u.Allocator, lease: uploads.Lease) BeginError!Transfer {
    const expected = try attachments.validate(lease.file);
    if (!t.validId(lease.token)) return error.InvalidRequest;
    const id = try a.dupeZ(u8, lease.file.id);
    const name = try a.dupeZ(u8, lease.file.name);
    const temporary = try std.fmt.allocPrintSentinel(a, ".tmp-{s}{s}", .{
        lease.token,
        if (u.eq(lease.file.name, try std.fmt.allocPrint(a, ".tmp-{s}", .{lease.token}))) "-partial" else "",
    }, 0);
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, lease.file.sha256) catch return error.InvalidRequest;
    if (c.zr_upload_remove(self.directory, id) != 0) return error.UploadStorageUnavailable;
    const directory = c.zr_upload_directory(self.directory, id);
    if (directory < 0) return error.UploadStorageUnavailable;
    errdefer _ = u.c.close(directory);
    const file = c.zr_upload_temporary(directory, temporary);
    if (file < 0) return error.UploadStorageUnavailable;
    return .{
        .directory = directory,
        .file = file,
        .name = name,
        .temporary = temporary,
        .expected = expected,
        .digest = digest,
    };
}

/// Open a private regular file with its exact declared length; caller closes it.
pub fn open(self: Files, a: u.Allocator, file: attachments.Upload) OpenError!c_int {
    const size = try attachments.validate(file);
    const fd = c.zr_upload_open(self.directory, try a.dupeZ(u8, file.id), try a.dupeZ(u8, file.name), size);
    if (fd < 0) return error.UploadFileUnavailable;
    return fd;
}

/// Return an allocator-owned path for the local automation boundary only.
pub fn path(self: Files, a: u.Allocator, file: attachments.Upload) (u.Allocator.Error || attachments.ValidateError)![]const u8 {
    _ = try attachments.validate(file);
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{
        self.root,
        file.id,
        file.name,
    });
}

/// Assume this ID is retired or has no active transfer/retained send. The caller
/// keeps its ledger row retired until this succeeds, then releases its quota.
pub fn remove(self: Files, id: []const u8) RemoveError!void {
    if (!t.validId(id)) return error.InvalidRequest;
    var name: [u.id_length:0]u8 = undefined;
    @memcpy(&name, id);
    name[u.id_length] = 0;
    if (c.zr_upload_remove(self.directory, &name) != 0) return error.UploadStorageUnavailable;
}

pub const Transfer = struct {
    directory: c_int,
    file: c_int,
    name: [:0]const u8,
    temporary: [:0]const u8,
    expected: u64,
    digest: [32]u8,
    received: u64 = 0,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    phase: enum { receiving, sealed, published } = .receiving,

    pub const WriteError = error{ UploadLengthMismatch, UploadStorageUnavailable };
    pub const SealError = WriteError || error{UploadHashMismatch};

    /// Assume this transfer is receiving. Writes a bounded chunk without retaining it.
    pub fn write(self: *Transfer, bytes: []const u8) WriteError!void {
        std.debug.assert(self.phase == .receiving);
        if (bytes.len > self.expected - self.received) return error.UploadLengthMismatch;
        if (c.zr_upload_write(self.file, bytes.ptr, bytes.len) != 0) return error.UploadStorageUnavailable;
        self.hash.update(bytes);
        self.received += bytes.len;
    }

    /// Assume this transfer is receiving. Verify original bytes and fsync/rename
    /// before the caller commits ledger readiness. Failure keeps cleanup ownership.
    pub fn seal(self: *Transfer) SealError!void {
        std.debug.assert(self.phase == .receiving);
        if (self.received != self.expected) return error.UploadLengthMismatch;
        if (!std.mem.eql(u8, &self.hash.finalResult(), &self.digest)) return error.UploadHashMismatch;
        if (c.zr_upload_install(self.directory, self.file, self.temporary, self.name, self.expected) != 0)
            return error.UploadStorageUnavailable;
        self.phase = .sealed;
    }

    /// Call only after the ledger's completion commits. Relinquishes file cleanup
    /// ownership to the upload service; deinit still closes this transfer's handles.
    pub fn publish(self: *Transfer) void {
        std.debug.assert(self.phase == .sealed);
        self.phase = .published;
    }

    /// Closes owned handles and removes unpublished files before lease abandonment.
    pub fn deinit(self: *Transfer) void {
        if (self.phase != .published) {
            _ = u.c.unlinkat(self.directory, self.temporary, 0);
            _ = u.c.unlinkat(self.directory, self.name, 0);
        }
        _ = u.c.close(self.file);
        _ = u.c.close(self.directory);
        self.* = undefined;
    }
};

test "upload storage verifies chunked original bytes and retains only published files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const relative = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var absolute: [4096]u8 = undefined;
    const data = u.c.realpath(relative, &absolute) orelse return error.TestUnexpectedResult;
    var files = try Files.init(a, std.mem.span(data));
    defer files.deinit();
    const bytes = "original\x00binary\xffcontents";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const lease: uploads.Lease = .{
        .server_epoch = try u.id(a),
        .token = try u.id(a),
        .file = .{
            .id = try u.id(a),
            .name = "résumé.bin",
            .mime_type = "application/octet-stream",
            .bytes = try u.decimal(a, bytes.len),
            .sha256 = try a.dupe(u8, &std.fmt.bytesToHex(&digest, .lower)),
        },
    };
    {
        var transfer = try files.begin(a, lease);
        defer transfer.deinit();
        try transfer.write(bytes[0..3]);
        try std.testing.expectError(error.UploadFileUnavailable, files.open(a, lease.file));
        try std.testing.expectError(error.UploadLengthMismatch, transfer.seal());
        try transfer.write(bytes[3..]);
        try std.testing.expectError(error.UploadLengthMismatch, transfer.write("extra"));
        try transfer.seal();
        transfer.publish();
    }
    const fd = try files.open(a, lease.file);
    defer _ = u.c.close(fd);
    var received: [bytes.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, bytes.len), u.c.read(fd, &received, received.len));
    try std.testing.expectEqualStrings(bytes, &received);
    try files.remove(lease.file.id);
    try std.testing.expectError(error.UploadFileUnavailable, files.open(a, lease.file));
    try files.remove(lease.file.id);
}

test "upload storage rejects wrong hashes and cleans sealed files without ledger publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const relative = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var absolute: [4096]u8 = undefined;
    const data = u.c.realpath(relative, &absolute) orelse return error.TestUnexpectedResult;
    var files = try Files.init(a, std.mem.span(data));
    defer files.deinit();
    var lease: uploads.Lease = .{
        .server_epoch = try u.id(a),
        .token = try u.id(a),
        .file = .{
            .id = try u.id(a),
            .name = "empty.txt",
            .mime_type = "text/plain",
            .bytes = "0",
            .sha256 = "0" ** 64,
        },
    };
    {
        var transfer = try files.begin(a, lease);
        defer transfer.deinit();
        try std.testing.expectError(error.UploadHashMismatch, transfer.seal());
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &digest, .{});
    lease.file.sha256 = try a.dupe(u8, &std.fmt.bytesToHex(&digest, .lower));
    {
        var transfer = try files.begin(a, lease);
        defer transfer.deinit();
        try transfer.seal();
    }
    try std.testing.expectError(error.UploadFileUnavailable, files.open(a, lease.file));
    {
        var transfer = try files.begin(a, lease);
        defer transfer.deinit();
        try transfer.seal();
        transfer.publish();
    }
    const fd = try files.open(a, lease.file);
    defer _ = u.c.close(fd);
    try files.remove(lease.file.id);
    lease.file.name = try std.fmt.allocPrint(a, ".tmp-{s}", .{lease.token});
    {
        var transfer = try files.begin(a, lease);
        defer transfer.deinit();
        try transfer.seal();
        transfer.publish();
    }
    const collision = try files.open(a, lease.file);
    defer _ = u.c.close(collision);
    try files.remove(lease.file.id);
    const id = try a.dupeZ(u8, lease.file.id);
    try std.testing.expectEqual(@as(c_int, 0), u.c.symlinkat(data, files.directory, id));
    try std.testing.expectError(error.UploadStorageUnavailable, files.begin(a, lease));
    try std.testing.expectError(error.UploadStorageUnavailable, files.remove(lease.file.id));
    try std.testing.expectError(error.UploadFileUnavailable, files.open(a, lease.file));
}
