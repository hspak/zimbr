//! A separate verified copy inside Messages attachment storage. Once automation
//! may have used it, its lifetime belongs to Messages history, not upload cleanup.
const std = @import("std");
const log = std.log.scoped(.send_handoff);
const u = @import("../../common.zig");
const attachments = @import("../../protocol.zig").attachments;
const uploads = @import("../uploads.zig");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("relay/media.h");
});
const Handoff = @This();

storage: uploads.Files,
file: attachments.Upload,
path: []const u8,
retained: bool = false,

pub const InitError = uploads.Files.BeginError || uploads.Files.Transfer.SealError || u.IdError;

/// Borrow the original descriptor without changing its offset. All strings use
/// a and must outlive this value. On error, no file is passed to automation.
pub fn init(a: u.Allocator, attachment_root: []const u8, original: c_int, file: attachments.Upload) InitError!Handoff {
    const root = try a.dupeZ(u8, attachment_root);
    const opened = c.zr_media_directory(root, 0);
    const root_fd = if (opened == -2) c.zr_media_directory(root, 1) else opened;
    if (root_fd < 0) return error.UploadStorageUnavailable;
    defer _ = u.c.close(root_fd);
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/zimbr", .{attachment_root}, 0);
    const directory_fd = c.zr_media_directory(directory, 1);
    if (directory_fd < 0) return error.UploadStorageUnavailable;
    defer _ = u.c.close(directory_fd);
    if (u.c.fsync(root_fd) != 0) return error.UploadStorageUnavailable;
    var storage = try uploads.Files.init(a, directory);
    errdefer storage.deinit();
    var copy = file;
    copy.id = try u.id(a);
    var transfer = try storage.beginNew(a, .{
        .server_epoch = "",
        .token = try u.id(a),
        .file = copy,
    });
    defer transfer.deinit();
    errdefer storage.remove(copy.id) catch {};
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = u.c.pread(original, &buffer, @min(buffer.len, transfer.expected + 1 - offset), @intCast(offset));
        if (count < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.UploadStorageUnavailable;
        }
        if (count == 0) break;
        const length: usize = @intCast(count);
        try transfer.write(buffer[0..length]);
        offset += length;
    }
    try transfer.seal();
    const path = try storage.path(a, copy);
    transfer.publish();
    errdefer comptime unreachable;
    return .{ .storage = storage, .file = copy, .path = path };
}

/// Keep the copy whenever automation succeeded or may have started. Messages can
/// reference this exact file even after delivery; upload retirement must not erase it.
pub fn retain(self: *Handoff) void {
    self.retained = true;
}

/// Remove only a copy known not to have reached automation. Retained files remain
/// in Messages attachment storage across relay restart, reset, and upload cleanup.
pub fn deinit(self: *Handoff) void {
    if (!self.retained) self.storage.remove(self.file.id) catch |err| {
        log.warn("Unstarted attachment copy cleanup: {s}", .{@errorName(err)});
    };
    self.storage.deinit();
    self.* = undefined;
}

test "handoff keeps separate verified bytes only after ownership passes to Messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const relative = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var absolute: [4096]u8 = undefined;
    const base = u.c.realpath(relative, &absolute) orelse return error.TestUnexpectedResult;
    const original = try std.fmt.allocPrintSentinel(a, "{s}/original", .{base}, 0);
    const root = try std.fmt.allocPrint(a, "{s}/attachments", .{base});
    const fd = u.c.open(original, u.c.O_RDWR | u.c.O_CREAT | u.c.O_EXCL, @as(c_uint, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = u.c.close(fd);
    const content = "original\x00binary\xffbytes";
    try std.testing.expectEqual(@as(isize, content.len), u.c.write(fd, content, content.len));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    var file: attachments.Upload = .{
        .id = try u.id(a),
        .name = "photo 👋.png",
        .mime_type = "image/png",
        .bytes = try u.decimal(a, content.len),
        .sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)),
    };
    var unstarted = try Handoff.init(a, root, fd, file);
    const discarded_path = try a.dupeZ(u8, unstarted.path);
    unstarted.deinit();
    try std.testing.expect(u.c.access(discarded_path, u.c.F_OK) != 0);
    var attempted = try Handoff.init(a, root, fd, file);
    const kept_path = try a.dupeZ(u8, attempted.path);
    const copy = try attempted.storage.open(a, attempted.file);
    defer _ = u.c.close(copy);
    var source_fingerprint: c.ZrMediaFingerprint = undefined;
    var copy_fingerprint: c.ZrMediaFingerprint = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.zr_media_fingerprint(fd, &source_fingerprint));
    try std.testing.expectEqual(@as(c_int, 0), c.zr_media_fingerprint(copy, &copy_fingerprint));
    try std.testing.expect(source_fingerprint.inode != copy_fingerprint.inode);
    try std.testing.expectEqual(@as(i64, content.len), u.c.lseek(fd, 0, u.c.SEEK_CUR));
    attempted.retain();
    attempted.deinit();
    try std.testing.expectEqual(@as(c_int, 0), u.c.unlink(original));
    try std.testing.expectEqual(@as(c_int, 0), u.c.access(kept_path, u.c.F_OK));
    var received: [content.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, content.len), u.c.read(copy, &received, received.len));
    try std.testing.expectEqualStrings(content, &received);
    file.sha256 = "0" ** 64;
    try std.testing.expectError(error.UploadHashMismatch, Handoff.init(a, root, fd, file));
    const linked = try std.fmt.allocPrintSentinel(a, "{s}/linked", .{base}, 0);
    const root_name = try a.dupeZ(u8, root);
    try std.testing.expectEqual(@as(c_int, 0), u.c.symlink(root_name, linked));
    try std.testing.expectError(error.UploadStorageUnavailable, Handoff.init(a, linked, fd, file));
}
