//! Outgoing file metadata shared by upload reservations, drafts, and sends.
const std = @import("std");
const u = @import("../common.zig");

pub const max_files = 16;
pub const max_file_bytes = 100 * 1024 * 1024;
pub const max_send_bytes = 200 * 1024 * 1024;

/// Metadata identifies immutable original bytes; name is a basename, never a path.
/// The relay verifies this metadata against a completed upload before dispatch.
pub const Upload = struct {
    id: []const u8,
    name: []const u8,
    mime_type: []const u8,
    bytes: []const u8,
    sha256: []const u8,
};

pub const ValidateError = error{
    InvalidRequest,
    AttachmentTooLarge,
    TooManyAttachments,
};

/// Validate metadata and return its byte count. Empty regular files are legal.
pub fn validate(file: Upload) ValidateError!u64 {
    if (file.id.len != u.id_length) return error.InvalidRequest;
    var id: [16]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&id, file.id) catch return error.InvalidRequest;
    if (file.name.len == 0 or file.name.len > 255 or u.eq(file.name, ".") or
        u.eq(file.name, "..") or !std.unicode.utf8ValidateSlice(file.name))
        return error.InvalidRequest;
    for (file.name) |ch| if (ch < 32 or ch == 127 or ch == '/' or ch == '\\')
        return error.InvalidRequest;
    var codepoints = std.unicode.Utf8View.initUnchecked(file.name).iterator();
    while (codepoints.nextCodepoint()) |cp| switch (cp) {
        // Filenames are shown before sending. Reject hidden line breaks and
        // direction overrides that can disguise the basename or its extension.
        0x80...0x9f, 0x061c, 0x200e, 0x200f, 0x2028...0x202e, 0x2066...0x2069 => return error.InvalidRequest,
        else => {},
    };
    if (!validMime(file.mime_type) or file.sha256.len != 64) return error.InvalidRequest;
    for (file.sha256) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f'))
        return error.InvalidRequest;
    if (file.bytes.len == 0 or (file.bytes.len > 1 and file.bytes[0] == '0'))
        return error.InvalidRequest;
    for (file.bytes) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidRequest;
    const bytes = std.fmt.parseInt(u64, file.bytes, 10) catch return error.AttachmentTooLarge;
    if (bytes > max_file_bytes) return error.AttachmentTooLarge;
    return bytes;
}

/// Validate the ordered set, rejecting duplicate upload IDs and combined overflow.
pub fn validateSet(files: []const Upload) ValidateError!void {
    if (files.len > max_files) return error.TooManyAttachments;
    var total: u64 = 0;
    for (files, 0..) |file, i| {
        total += try validate(file);
        if (total > max_send_bytes) return error.AttachmentTooLarge;
        for (files[0..i]) |previous| if (u.eq(file.id, previous.id)) return error.InvalidRequest;
    }
}

fn validMime(mime: []const u8) bool {
    if (mime.len < 3 or mime.len > 127) return false;
    const slash = std.mem.indexOfScalar(u8, mime, '/') orelse return false;
    if (slash == 0 or slash == mime.len - 1) return false;
    for (mime, 0..) |ch, i| {
        if (i == slash or std.ascii.isAlphanumeric(ch)) continue;
        if (std.mem.indexOfScalar(u8, "!#$&^_.+-", ch) == null) return false;
    }
    return true;
}

test "upload metadata accepts Unicode basenames and exact byte boundaries" {
    var file: Upload = .{
        .id = "ABEiM0RVZneImaq7zN3u_w",
        .name = "photo 👩‍💻.png",
        .mime_type = "image/png",
        .bytes = "0",
        .sha256 = "0123456789abcdef" ** 4,
    };
    try std.testing.expectEqual(@as(u64, 0), try validate(file));
    file.bytes = "104857600";
    try std.testing.expectEqual(@as(u64, max_file_bytes), try validate(file));
    file.bytes = "104857601";
    try std.testing.expectError(error.AttachmentTooLarge, validate(file));
    file.bytes = "18446744073709551616";
    try std.testing.expectError(error.AttachmentTooLarge, validate(file));
}

test "upload metadata rejects paths malformed identities hashes sizes and MIME headers" {
    const good: Upload = .{
        .id = "ABEiM0RVZneImaq7zN3u_w",
        .name = "document.pdf",
        .mime_type = "application/pdf",
        .bytes = "17",
        .sha256 = "0123456789abcdef" ** 4,
    };
    for ([_][]const u8{
        "",
        ".",
        "..",
        "../photo.png",
        "folder\\photo.png",
        "photo\x00.png",
        "photo\r\n.png",
        "invalid\xff",
        "x" ** 256,
    }) |name| {
        var bad = good;
        bad.name = name;
        try std.testing.expectError(error.InvalidRequest, validate(bad));
    }
    for ([_][]const u8{
        "",
        "/png",
        "image/",
        "image/png/extra",
        "image/png\r\nx: y",
        "image/png; charset=utf-8",
        "image/*",
    }) |mime| {
        var bad = good;
        bad.mime_type = mime;
        try std.testing.expectError(error.InvalidRequest, validate(bad));
    }
    for ([_][]const u8{
        "",
        "00",
        "01",
        "-1",
        "+1",
        "1.0",
        "1e2",
        " 1",
    }) |bytes| {
        var bad = good;
        bad.bytes = bytes;
        try std.testing.expectError(error.InvalidRequest, validate(bad));
    }
    var bad = good;
    bad.id = "ABEiM0RVZneImaq7zN3u_x";
    try std.testing.expectError(error.InvalidRequest, validate(bad));
    bad = good;
    bad.sha256 = "ABCDEF0123456789" ** 4;
    try std.testing.expectError(error.InvalidRequest, validate(bad));
    bad.sha256 = "0" ** 63;
    try std.testing.expectError(error.InvalidRequest, validate(bad));
}

test "attachment sets bound count and aggregate size and reject repeated upload IDs" {
    var files = [_]Upload{.{
        .id = "ABEiM0RVZneImaq7zN3u_w",
        .name = "file.bin",
        .mime_type = "application/octet-stream",
        .bytes = "104857600",
        .sha256 = "0123456789abcdef" ** 4,
    }} ** (max_files + 1);
    try std.testing.expectError(error.TooManyAttachments, validateSet(&files));
    try std.testing.expectError(error.InvalidRequest, validateSet(files[0..2]));
    files[1].id = "aBEiM0RVZneImaq7zN3u_w";
    try validateSet(files[0..2]);
    files[2].id = "bBEiM0RVZneImaq7zN3u_w";
    files[2].bytes = "1";
    try std.testing.expectError(error.AttachmentTooLarge, validateSet(files[0..3]));
    files[2].bytes = "0";
    try validateSet(files[0..3]);
}

test "attachment names reject invisible controls but preserve ordinary Unicode" {
    var file: Upload = .{
        .id = "ABEiM0RVZneImaq7zN3u_w",
        .name = "",
        .mime_type = "application/octet-stream",
        .bytes = "0",
        .sha256 = "0" ** 64,
    };
    for ([_][]const u8{
        "photo\u{85}.png",
        "photo\u{9b}.png",
        "photo\u{2028}.png",
        "photo\u{2029}.png",
        "photo\u{202e}gnp.exe",
        "photo\u{2066}.png",
        "photo\u{61c}.png",
    }) |name| {
        file.name = name;
        try std.testing.expectError(error.InvalidRequest, validate(file));
    }
    for ([_][]const u8{
        "صورة.png",
        "résumé 👩‍💻.txt",
        "re\u{301}sume\u{301}.txt",
        "quote'; DROP TABLE uploads;--.txt",
    }) |name| {
        file.name = name;
        try std.testing.expectEqual(@as(u64, 0), try validate(file));
    }
}
