const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol.zig").types;
const plist = @import("plist.zig");
pub const safeUrl = @import("../../protocol.zig").url.safe;
const V = plist.Node;
pub const provider = "com.apple.messages.URLBalloonProvider";
pub const Artwork = struct {
    preview_id: []const u8,
    icon: bool = false,
    data: ?[]const u8 = null,
    attachment_guid: ?[]const u8 = null,
    attachment_index: ?u32 = null,
};
pub const Result = struct {
    previews: []const t.LinkPreview = &.{},
    artwork: []const Artwork = &.{},
    state: t.EnrichmentStatus,
};
const Failure = error{
    Malformed,
    Unsupported,
    Oversized,
    OutOfMemory,
};

pub fn decode(a: u.Allocator, bytes: []const u8) u.Allocator.Error!Result {
    if (bytes.len == 0) return .{ .state = .pending };
    return parse(a, bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Oversized => .{ .state = .oversized },
        error.Unsupported => .{ .state = .unsupported },
        error.Malformed => .{ .state = .malformed },
    };
}
fn parse(a: u.Allocator, bytes: []const u8) Failure!Result {
    const value = try plist.parse(a, bytes);
    var archive = Archive{ .a = a };
    var root = value;
    if (value.get("$objects")) |objects| {
        if (objects != .array or objects.array.len == 0 or objects.array.len > plist.max_objects) return error.Malformed;
        const archiver = (value.get("$archiver") orelse return error.Malformed).text() orelse return error.Malformed;
        if (!u.eq(archiver, "NSKeyedArchiver")) return error.Unsupported;
        archive.objects = objects.array;
        archive.active = try a.alloc(bool, objects.array.len);
        @memset(archive.active, false);
        const top = value.get("$top") orelse return error.Malformed;
        root = top.get("root") orelse return error.Malformed;
    }
    root = try archive.resolve(root, 0);
    const roots: []const V = if (root == .array) root.array else &.{root};
    var previews: std.ArrayList(t.LinkPreview) = .empty;
    var artwork: std.ArrayList(Artwork) = .empty;
    for (roots, 0..) |item, i| {
        const metadata = item.get("richLinkMetadata") orelse item.get("metadata") orelse return error.Unsupported;
        if (metadata != .dict) return error.Malformed;
        // URLBalloonProvider also stores richer app/music/map objects. Retain
        // their readable message fallback until their own layouts are verified.
        for ([_][]const u8{
            "musicMetadata",
            "collaborationMetadata",
            "appStoreMetadata",
            "mapMetadata",
            "specialization",
        }) |key| if (metadata.get(key) != null) return error.Unsupported;
        const id = try std.fmt.allocPrint(a, "link:{d}", .{i});
        const original = try urlField(metadata, "originalURL");
        const final = try urlField(metadata, "URL");
        if (original == null and final == null) return error.Malformed;
        const placeholder = item.get("richLinkIsPlaceholder") orelse metadata.get("richLinkIsPlaceholder");
        try previews.append(a, .{
            .id = id,
            .part_id = id,
            .original_url = original,
            .metadata_url = final,
            .title = try field(metadata, "title", 2048),
            .summary = try field(metadata, "summary", 4096),
            .site_name = try field(metadata, "siteName", 512),
            .state = if (placeholder != null and placeholder.? == .boolean and placeholder.?.boolean) .pending else .complete,
        });
        // Leave room for both eventual asset descriptors in overflow pages.
        if ((try u.json(a, previews.items[previews.items.len - 1])).len > 24 * 1024) return error.Oversized;
        for ([_][]const u8{ "image", "icon" }, 0..) |key, role| if (metadata.get(key)) |image| {
            if (image == .none) continue;
            if (image == .data) {
                if (image.data.len > 0) try artwork.append(a, .{
                    .preview_id = id,
                    .icon = role == 1,
                    .data = image.data,
                });
            } else if (image == .dict) {
                if (image.get("data")) |data| {
                    if (data != .data) return error.Malformed;
                    if (data.data.len > 0) try artwork.append(a, .{
                        .preview_id = id,
                        .icon = role == 1,
                        .data = data.data,
                    });
                } else if (try field(image, "attachmentGUID", 1024)) |guid| {
                    try artwork.append(a, .{
                        .preview_id = id,
                        .icon = role == 1,
                        .attachment_guid = guid,
                    });
                } else if (image.get("richLinkImageAttachmentSubstituteIndex")) |index| {
                    if (index != .integer or index.integer > std.math.maxInt(u32)) return error.Malformed;
                    try artwork.append(a, .{
                        .preview_id = id,
                        .icon = role == 1,
                        .attachment_index = @intCast(index.integer),
                    });
                }
                // Remote URL-only artwork remains unavailable. It never
                // becomes a network job or a locally guessed file path.
            } else return error.Malformed;
        };
    }
    return .{
        .previews = try previews.toOwnedSlice(a),
        .artwork = try artwork.toOwnedSlice(a),
        .state = .complete,
    };
}
fn field(value: V, key: []const u8, maximum: usize) Failure!?[]const u8 {
    const item = value.get(key) orelse return null;
    if (item == .none) return null;
    const bytes = item.text() orelse return error.Malformed;
    if (bytes.len > maximum) return error.Oversized;
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.Malformed;
    return if (bytes.len == 0) null else bytes;
}
fn urlField(value: V, key: []const u8) Failure!?[]const u8 {
    var item = value.get(key) orelse return null;
    if (item == .dict) item = item.get(key) orelse item.get("URL") orelse return error.Malformed;
    if (item == .none) return null;
    const url = item.text() orelse return error.Malformed;
    if (url.len > 4096) return error.Oversized;
    return if (safeUrl(url)) url else null;
}

fn knownKey(key: []const u8) bool {
    for ([_][]const u8{
        "richLinkMetadata",
        "metadata",
        "title",
        "summary",
        "siteName",
        "URL",
        "originalURL",
        "richLinkIsPlaceholder",
        "image",
        "icon",
        "data",
        "attachmentGUID",
        "richLinkImageAttachmentSubstituteIndex",
        "images",
        "icons",
        "musicMetadata",
        "collaborationMetadata",
        "appStoreMetadata",
        "mapMetadata",
        "specialization",
    }) |known| if (u.eq(key, known)) return true;
    return false;
}
const Archive = struct {
    a: u.Allocator,
    objects: []const V = &.{},
    active: []bool = &.{},
    visits: usize = 0,
    expanded_bytes: usize = 0,
    fn charge(self: *Archive, bytes: usize) Failure!void {
        const maximum = 4 * t.max_decode;
        if (bytes > maximum - self.expanded_bytes) return error.Oversized;
        self.expanded_bytes += bytes;
    }
    fn resolve(self: *Archive, value: V, depth: usize) Failure!V {
        self.visits += 1;
        if (depth >= plist.max_depth or self.visits > plist.max_objects) return error.Oversized;
        // A small shared graph can expand into many copies of artwork or
        // metadata. Charge both borrowed scalars and containers before use.
        try self.charge(switch (value) {
            .string => value.string.len,
            .data => value.data.len,
            .array => value.array.len * @sizeOf(V),
            .dict => value.dict.len * @sizeOf(plist.Entry),
            .none, .boolean, .integer, .uid => 0,
        });
        if (value == .uid) {
            if (value.uid >= self.objects.len or self.active[value.uid]) return error.Malformed;
            if (value.uid == 0 and self.objects[0] == .string and u.eq(
                self.objects[0].string,
                "$null",
            )) return .none;
            self.active[value.uid] = true;
            defer self.active[value.uid] = false;
            return self.resolve(self.objects[value.uid], depth + 1);
        }
        if (value == .array) {
            const items = try self.a.alloc(V, value.array.len);
            for (items, value.array) |*item, original| item.* = try self.resolve(
                original,
                depth + 1,
            );
            return .{ .array = items };
        }
        if (value != .dict) return value;
        if (value.get("$class")) |class| {
            if (class != .uid or class.uid >= self.objects.len) return error.Malformed;
            const name = (self.objects[class.uid].get("$classname") orelse return error.Malformed).text() orelse return error.Malformed;
            var known = false;
            for ([_][]const u8{
                "NSDictionary",
                "NSMutableDictionary",
                "NSArray",
                "NSMutableArray",
                "NSString",
                "NSMutableString",
                "NSURL",
                "NSData",
                "NSMutableData",
                "LPLinkMetadata",
                "LPImage",
                "LPImageMetadata",
                "LPIconMetadata",
                "RichLink",
                "LPSharingMetadataWrapper",
                "RichLinkImageAttachmentSubstitute",
            }) |allowed| if (u.eq(name, allowed)) {
                known = true;
                break;
            };
            if (!known) return error.Unsupported;
        }
        if (value.get("NS.relative")) |url| {
            if (value.get("NS.base")) |base| if (try self.resolve(base, depth + 1) != .none) return error.Unsupported;
            return self.resolve(url, depth + 1);
        }
        if (value.get("NS.string")) |string| return self.resolve(string, depth + 1);
        if (value.get("NS.data")) |data| return self.resolve(data, depth + 1);
        var entries: std.ArrayList(plist.Entry) = .empty;
        if (value.get("NS.keys")) |raw_keys| {
            const keys = try self.resolve(raw_keys, depth + 1);
            const values = value.get("NS.objects") orelse return error.Malformed;
            if (keys != .array or values != .array or keys.array.len != values.array.len) return error.Malformed;
            for (keys.array, values.array) |key, item| {
                const name = key.text() orelse return error.Malformed;
                if (!knownKey(name)) continue;
                for (entries.items) |entry| if (u.eq(entry.key, name)) return error.Malformed;
                try entries.append(
                    self.a,
                    .{ .key = name, .value = try self.resolve(item, depth + 1) },
                );
            }
        } else if (value.get("NS.objects")) |array| {
            return self.resolve(array, depth + 1);
        } else {
            for (value.dict) |entry| if (knownKey(entry.key)) {
                try entries.append(
                    self.a,
                    .{ .key = entry.key, .value = try self.resolve(entry.value, depth + 1) },
                );
            };
        }
        return .{ .dict = try entries.toOwnedSlice(self.a) };
    }
};

pub fn bindLocalArtwork(
    a: u.Allocator,
    source_guid: []const u8,
    attachments: []const t.Attachment,
    artwork: []const Artwork,
) u.Allocator.Error![]const Artwork {
    const result = try a.dupe(Artwork, artwork);
    for (result) |*item| if (item.attachment_index) |index| {
        // Observed RichLink substitutes use at_<index>_<message GUID>. Require
        // that exact attachment to be joined to this message. Never interpret
        // the index as SQL row order or as an attributed-body part index.
        const guid = try std.fmt.allocPrint(a, "at_{d}_{s}", .{ index, source_guid });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(guid, &digest, .{});
        const id = std.fmt.bytesToHex(digest, .lower);
        for (attachments) |attachment| if (u.eq(attachment.id, &id)) {
            item.attachment_guid = guid;
            break;
        };
    };
    return result;
}

test "URL activation contract rejects unsafe schemes, credentials, and hidden destinations" {
    for ([_][]const u8{
        "https://example.invalid/path?q=a%20b#fragment",
        "http://example.invalid:8080/",
        "https://[::1]/",
    }) |url| try std.testing.expect(safeUrl(url));
    for ([_][]const u8{
        "file:///etc/passwd",
        "javascript:alert(1)",
        "https:///missing",
        "https://user:pass@example.invalid",
        "https://example.invalid\\@evil.invalid",
        "https://example.invalid\n",
        "https://%65xample.invalid",
        "https://[not-ip]/",
        "https://example..invalid/",
        "https://host<>/",
    }) |url| try std.testing.expect(!safeUrl(url));
}
