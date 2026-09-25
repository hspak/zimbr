//! One durable asset service for approved local sources. File inspection and
//! conversion run outside the journal mutex; immutable completions are guarded
//! by source version and epoch before owner metadata is published.
const std = @import("std");
const Sqlite = @import("Sqlite.zig");
const MessagesDb = @import("adapter/MessagesDb.zig");
const link_preview = @import("adapter/link_preview.zig");
const options = @import("options");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const Journal = @import("Journal.zig");
const enrichment = @import("enrichment.zig");
const Core = @import("Core.zig");
const contacts = @import("adapter/contacts.zig");
pub const c = @cImport({
    @cInclude("relay/media.h");
});
const Assets = @This();

root_path: []const u8,
cache_fd: c_int,
helper_path: [:0]const u8,
worker_busy: std.atomic.Value(bool) = .init(false),

pub const Variant = @FieldType(t.AssetRef, "variant");
pub const max_source = 100 * 1024 * 1024;
pub const max_derivative = 8 * 1024 * 1024;
pub const max_queue = 128;
pub const cache_budget = 2 * 1024 * 1024 * 1024;
pub const transform_version = "image-v1";

pub const InitError = std.process.ExecutablePathAllocError || error{ UnsafeAssetCache, ImageHelperUnavailable };
pub const ReferenceError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{NotFound};
pub const RegisterError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    InvalidRequest,
    MetadataItemTooLarge,
    NotFound,
    RandomUnavailable,
    WriteFailed,
};
pub const AvatarError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    AssetQueueFull,
    InvalidRequest,
    MetadataItemTooLarge,
    NotFound,
    RandomUnavailable,
    WriteFailed,
};
pub const AttachError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    InvalidRequest,
    MetadataItemTooLarge,
    NotFound,
    RandomUnavailable,
    WriteFailed,
};
pub const PreviewsError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    InvalidRequest,
    MetadataItemTooLarge,
    NotFound,
    RandomUnavailable,
    WriteFailed,
};
pub const EnqueueError = Journal.QueryError || error{AssetQueueFull};
pub const LookupError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    AssetQueueFull,
    AssetRetired,
    NotFound,
};
pub const EvictedError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    AssetQueueFull,
    InvalidRequest,
    MetadataItemTooLarge,
    NotFound,
    RandomUnavailable,
    WriteFailed,
};
pub const ReadBytesError = u.Allocator.Error || error{InvalidImage};
pub const ContactWorkError = contacts.ThumbnailError || Journal.MessageError || ReferenceError ||
    error{
        AssetCacheUnavailable,
        InvalidAsset,
        InvalidImage,
        InvalidRequest,
    };

/// Paths and allocated strings must live in the caller's arena until close.
/// The returned service owns its cache descriptor.
pub fn init(a: u.Allocator, io: std.Io, data: []const u8, root: []const u8) InitError!Assets {
    const cache = try std.fmt.allocPrintSentinel(a, "{s}/assets", .{data}, 0);
    const cache_fd = c.zr_media_directory(cache, 1);
    if (cache_fd < 0) return error.UnsafeAssetCache;
    errdefer _ = u.c.close(cache_fd);
    const helper = try std.fmt.allocPrintSentinel(
        a,
        "{s}/{s}",
        .{ try std.process.executableDirPathAlloc(io, a), if (comptime options.fake) "fake-image-helper" else "image-helper" },
        0,
    );
    if (u.c.access(helper, u.c.X_OK) != 0) return error.ImageHelperUnavailable;
    _ = c.zr_media_sweep(cache_fd);
    return .{
        .root_path = root,
        .cache_fd = cache_fd,
        .helper_path = helper,
    };
}
pub fn close(self: Assets) void {
    _ = u.c.close(self.cache_fd);
}
fn relative(self: Assets, path: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null or path.len > 4096) return null;
    const expected = "~/Library/Messages/Attachments/";
    if (!options.fake and std.mem.startsWith(u8, path, expected)) return path[expected.len..];
    if (std.mem.startsWith(u8, path, self.root_path) and path.len > self.root_path.len and path[self.root_path.len] == '/') return path[self.root_path.len + 1 ..];
    return null;
}
const Source = struct {
    id: []const u8,
    kind: []const u8,
    path: []const u8,
    version: []const u8,
    fingerprint: []const u8,
    attempts: i64,
};
fn sourceRow(a: u.Allocator, row: Sqlite.Statement) !Source {
    return .{
        .id = try row.text(a, 0),
        .kind = try row.text(a, 1),
        .path = try row.text(a, 2),
        .version = try row.text(a, 3),
        .fingerprint = try row.text(a, 4),
        .attempts = row.int(5),
    };
}
const source_columns = "SELECT id,kind,path,version,fingerprint,attempts FROM asset_sources";

pub fn reference(a: u.Allocator, j: Journal, id: []const u8, variant: Variant) ReferenceError!t.AssetRef {
    const q = try j.db.prepare("SELECT r.record FROM asset_representations r JOIN asset_sources s ON s.id=r.asset_id AND s.version=r.version WHERE r.asset_id=? AND r.variant=?");
    defer q.close();
    try q.bind(&.{ .{ .text = id }, .{ .text = @tagName(variant) } });
    if (!try q.step()) return error.NotFound;
    return (try std.json.parseFromSlice(t.AssetRef, a, q.bytes(0), .{ .allocate = .alloc_always })).value;
}
fn newRepresentations(
    a: u.Allocator,
    j: Journal,
    id: []const u8,
    version: []const u8,
    variants: []const Variant,
) !void {
    for (variants) |variant| {
        const ref: t.AssetRef = .{
            .id = id,
            .version = version,
            .variant = variant,
            .reason = "conversion_pending",
        };
        try j.execute("INSERT OR IGNORE INTO asset_representations(asset_id,version,variant,record,requested) VALUES(?,?,?,?,coalesce((SELECT max(requested) FROM asset_representations WHERE asset_id=? AND variant=?),0))", &.{
            .{ .text = id },
            .{ .text = version },
            .{ .text = @tagName(variant) },
            .{ .text = try u.json(a, ref) },
            .{ .text = id },
            .{ .text = @tagName(variant) },
        });
    }
}
fn rotate(a: u.Allocator, j: Journal, source: Source, path: []const u8, signature: []const u8) ![]const u8 {
    const version = try u.id(a);
    try j.execute("UPDATE asset_sources SET path=?,version=?,fingerprint=?,check_ms=0,attempts=0 WHERE id=?", &.{
        .{ .text = path },
        .{ .text = version },
        .{ .text = signature },
        .{ .text = source.id },
    });
    try j.execute("DELETE FROM asset_work WHERE asset_id=?", &.{.{ .text = source.id }});
    try newRepresentations(
        a,
        j,
        source.id,
        version,
        if (u.eq(source.kind, "contact")) &.{.avatar} else &.{ .inline_image, .viewer },
    );
    return version;
}
pub fn register(a: u.Allocator, j: Journal, kind: []const u8, key: []const u8, path: []const u8) RegisterError![]const u8 {
    const q = try j.db.prepare(source_columns ++ " WHERE kind=? AND source_key=?");
    defer q.close();
    try q.bind(&.{ .{ .text = kind }, .{ .text = key } });
    if (try q.step()) {
        const source = try sourceRow(a, q);
        if (!u.eq(source.path, path)) {
            _ = try rotate(a, j, source, path, "");
            try publishOwners(a, j, source.id);
        }
        return source.id;
    }
    const id = try u.id(a);
    const version = try u.id(a);
    try j.execute("INSERT INTO asset_sources(id,kind,source_key,path,version) VALUES(?,?,?,?,?)", &.{
        .{ .text = id },
        .{ .text = kind },
        .{ .text = key },
        .{ .text = path },
        .{ .text = version },
    });
    try newRepresentations(
        a,
        j,
        id,
        version,
        if (u.eq(kind, "contact")) &.{.avatar} else &.{ .inline_image, .viewer },
    );
    return id;
}

pub fn avatar(a: u.Allocator, j: Journal, identity: []const u8, photo: ?contacts.PhotoSource) AvatarError!?t.AssetRef {
    try j.execute(
        "DELETE FROM asset_owners WHERE kind='identity' AND owner_id=?",
        &.{.{ .text = identity }},
    );
    const source = photo orelse return null;
    const id = try register(a, j, "contact", source.contact_id, try u.json(a, source));
    try j.execute(
        "INSERT OR IGNORE INTO asset_owners VALUES(?,'identity',?)",
        &.{ .{ .text = id }, .{ .text = identity } },
    );
    const ref = try reference(a, j, id, .avatar);
    const q = try j.db.prepare("SELECT requested FROM asset_representations WHERE asset_id=? AND version=? AND variant='avatar'");
    defer q.close();
    try q.bind(&.{ .{ .text = id }, .{ .text = ref.version } });
    if (try q.step() and q.int(0) != 0) enqueue(a, j, ref, false) catch |err| {
        if (err != error.AssetQueueFull) return err;
    };
    return ref;
}

pub fn attach(
    a: u.Allocator,
    j: Journal,
    message_source: []const u8,
    value: *t.Message,
    sources: []const MessagesDb.AttachmentSource,
) AttachError!void {
    var owners: std.StringHashMapUnmanaged(void) = .empty;
    var by_attachment: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (sources) |source| {
        const id = try register(a, j, "attachment", source.id, source.filename);
        try owners.put(a, id, {});
        try by_attachment.put(a, source.id, id);
        try j.execute(
            "INSERT OR IGNORE INTO asset_owners VALUES(?,'message',?)",
            &.{ .{ .text = id }, .{ .text = message_source } },
        );
    }
    const q = try j.db.prepare("SELECT asset_id FROM asset_owners WHERE kind='message' AND owner_id=?");
    defer q.close();
    try q.bind(&.{.{ .text = message_source }});
    var removed: std.ArrayList([]const u8) = .empty;
    while (try q.step()) if (!owners.contains(q.bytes(0))) try removed.append(a, try q.text(a, 0));
    for (removed.items) |id| try j.execute(
        "DELETE FROM asset_owners WHERE asset_id=? AND kind='message' AND owner_id=?",
        &.{ .{ .text = id }, .{ .text = message_source } },
    );
    const attachments = try a.dupe(t.Attachment, value.attachments);
    for (attachments) |*attachment| if (by_attachment.get(attachment.id)) |id| {
        attachment.image = try reference(a, j, id, .inline_image);
        attachment.viewer = try reference(a, j, id, .viewer);
    };
    value.attachments = attachments;
}

pub fn previews(
    a: u.Allocator,
    j: Journal,
    message_source: []const u8,
    value: *t.Message,
    artwork: []const link_preview.Artwork,
) PreviewsError!void {
    const cards = try a.dupe(t.LinkPreview, value.link_previews orelse return);
    const attachments = try a.dupe(t.Attachment, value.attachments);
    try j.execute(
        "DELETE FROM asset_owners WHERE kind='preview' AND owner_id=?",
        &.{.{ .text = message_source }},
    );
    for (artwork) |item| {
        var ref: ?t.AssetRef = null;
        if (item.data) |bytes| {
            const key = try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{
                message_source,
                item.preview_id,
                if (item.icon) "icon" else "image",
            });
            const id = try register(a, j, "payload", key, try digest(a, bytes));
            try j.execute(
                "INSERT INTO asset_blobs VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET bytes=excluded.bytes WHERE bytes<>excluded.bytes",
                &.{ .{ .text = id }, .{ .blob = bytes } },
            );
            ref = try reference(a, j, id, .inline_image);
        } else if (item.attachment_guid) |guid| {
            const attachment_id = try digest(a, guid);
            for (attachments) |*attachment| if (u.eq(attachment.id, attachment_id)) {
                ref = attachment.image;
                if (ref != null) attachment.preview_artwork = true;
                break;
            };
        }
        if (ref) |image| {
            try j.execute(
                "INSERT OR IGNORE INTO asset_owners VALUES(?,'preview',?)",
                &.{ .{ .text = image.id }, .{ .text = message_source } },
            );
            for (cards) |*card| if (u.eq(card.id, item.preview_id)) {
                if (item.icon) card.icon = image else card.image = image;
            };
        }
    }
    value.link_previews = cards;
    value.attachments = attachments;
}

fn publishOwners(a: u.Allocator, j: Journal, id: []const u8) !void {
    const identities = try j.db.prepare("SELECT i.record FROM asset_owners o JOIN identities i ON i.id=o.owner_id WHERE o.asset_id=? AND o.kind='identity'");
    defer identities.close();
    try identities.bind(&.{.{ .text = id }});
    var identity_values: std.ArrayList(t.Identity) = .empty;
    while (try identities.step()) try identity_values.append(
        a,
        (try std.json.parseFromSlice(t.Identity, a, identities.bytes(0), .{ .allocate = .alloc_always })).value,
    );
    for (identity_values.items) |item| {
        var value = item;
        if (value.avatar) |ref| if (u.eq(ref.id, id)) {
            value.avatar = try reference(a, j, id, .avatar);
            try j.updateIdentity(a, value);
        };
    }
    const q = try j.db.prepare("SELECT DISTINCT m.source,m.source_row,m.date_ns,m.record FROM asset_owners o JOIN messages m ON m.source=o.owner_id WHERE o.asset_id=? AND o.kind IN('message','preview')");
    defer q.close();
    try q.bind(&.{.{ .text = id }});
    const Owner = struct {
        source: []const u8,
        row: i64,
        date: i64,
        value: t.Message,
    };
    var owners: std.ArrayList(Owner) = .empty;
    while (try q.step()) try owners.append(a, .{
        .source = try q.text(a, 0),
        .row = q.int(1),
        .date = q.int(2),
        .value = try enrichment.full(
            a,
            j,
            (try std.json.parseFromSlice(t.Message, a, q.bytes(3), .{ .allocate = .alloc_always })).value,
        ),
    });
    for (owners.items) |owner| {
        var value = owner.value;
        const attachments = try a.dupe(t.Attachment, value.attachments);
        for (attachments) |*attachment| {
            if (attachment.image) |image| if (u.eq(image.id, id)) {
                attachment.image = try reference(a, j, id, .inline_image);
            };
            if (attachment.viewer) |viewer| if (u.eq(viewer.id, id)) {
                attachment.viewer = try reference(a, j, id, .viewer);
            };
        }
        value.attachments = attachments;
        if (value.link_previews) |old_cards| {
            const cards = try a.dupe(t.LinkPreview, old_cards);
            for (cards) |*card| {
                if (card.image) |ref| if (u.eq(ref.id, id)) {
                    card.image = try reference(a, j, id, .inline_image);
                };
                if (card.icon) |ref| if (u.eq(ref.id, id)) {
                    card.icon = try reference(a, j, id, .inline_image);
                };
            }
            value.link_previews = cards;
        }
        try j.message(a, owner.source, owner.row, owner.date, value, "reconciliation");
    }
}

fn state(
    a: u.Allocator,
    j: Journal,
    source: Source,
    availability: @FieldType(t.AssetRef, "availability"),
    reason: []const u8,
) !void {
    for ([_]Variant{ .inline_image, .viewer }) |variant| {
        var ref = try reference(a, j, source.id, variant);
        if (ref.availability == availability and u.eq(ref.reason orelse "", reason)) continue;
        ref.availability = availability;
        ref.reason = reason;
        try j.execute("UPDATE asset_representations SET record=? WHERE asset_id=? AND version=? AND variant=?", &.{
            .{ .text = try u.json(a, ref) },
            .{ .text = ref.id },
            .{ .text = ref.version },
            .{ .text = @tagName(variant) },
        });
    }
    try publishOwners(a, j, source.id);
}
pub fn retryable(ref: t.AssetRef) bool {
    return ref.availability == .pending or ref.availability == .not_local or (ref.availability == .unavailable and (u.eq(
        ref.reason orelse "",
        "helper_unavailable",
    ) or u.eq(
        ref.reason orelse "",
        "conversion_timeout",
    ) or u.eq(
        ref.reason orelse "",
        "source_unavailable",
    )));
}
pub fn enqueue(a: u.Allocator, j: Journal, ref: t.AssetRef, visible: bool) EnqueueError!void {
    if (!retryable(ref)) return;
    const q = try j.db.prepare("SELECT 1 FROM asset_work WHERE asset_id=? AND version=? AND variant=?");
    defer q.close();
    try q.bind(&.{
        .{ .text = ref.id },
        .{ .text = ref.version },
        .{ .text = @tagName(ref.variant) },
    });
    if (try q.step()) return;
    if (try j.db.scalar("SELECT count(*) FROM asset_work") >= max_queue) return error.AssetQueueFull;
    try j.execute("INSERT INTO asset_work VALUES(?,?,?,?)", &.{
        .{ .text = ref.id },
        .{ .text = ref.version },
        .{ .text = @tagName(ref.variant) },
        .{ .int = if (visible) u.now() else u.now() + 1000 },
    });
    _ = a;
}
pub const Lookup = struct {
    ref: t.AssetRef,
    etag: ?[]const u8,
    file_name: ?[]const u8,
};
pub fn lookup(a: u.Allocator, j: Journal, id: []const u8, version: []const u8, variant: Variant) LookupError!Lookup {
    const source = try j.db.prepare("SELECT version FROM asset_sources WHERE id=? AND EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=?)");
    defer source.close();
    try source.bind(&.{ .{ .text = id }, .{ .text = id } });
    if (!try source.step()) return error.NotFound;
    if (!u.eq(version, source.bytes(0))) return error.AssetRetired;
    const q = try j.db.prepare("SELECT record,etag,file_name FROM asset_representations WHERE asset_id=? AND version=? AND variant=?");
    defer q.close();
    try q.bind(&.{
        .{ .text = id },
        .{ .text = version },
        .{ .text = @tagName(variant) },
    });
    if (!try q.step()) return error.NotFound;
    const ref = (try std.json.parseFromSlice(
        t.AssetRef,
        a,
        q.bytes(0),
        .{ .allocate = .alloc_always },
    )).value;
    try j.execute("UPDATE asset_representations SET requested=1,last_access_ms=? WHERE asset_id=? AND version=? AND variant=?", &.{
        .{ .int = u.now() },
        .{ .text = id },
        .{ .text = version },
        .{ .text = @tagName(variant) },
    });
    try enqueue(a, j, ref, true);
    return .{
        .ref = ref,
        .etag = if (q.bytes(1).len > 0) try q.text(a, 1) else null,
        .file_name = if (q.bytes(2).len > 0) try q.text(a, 2) else null,
    };
}
pub fn evicted(a: u.Allocator, j: Journal, value: Lookup) EvictedError!void {
    var ref = value.ref;
    ref.availability = .pending;
    ref.reason = "cache_evicted";
    try j.execute("UPDATE asset_representations SET record=?,file_name=NULL,bytes=0 WHERE asset_id=? AND version=? AND variant=?", &.{
        .{ .text = try u.json(a, ref) },
        .{ .text = ref.id },
        .{ .text = ref.version },
        .{ .text = @tagName(ref.variant) },
    });
    try publishOwners(a, j, ref.id);
    try enqueue(a, j, ref, true);
}
pub fn prioritizeConversation(j: Journal, id: []const u8) Journal.QueryError!void {
    try j.execute(
        "UPDATE asset_sources SET check_ms=0 WHERE id IN(SELECT o.asset_id FROM asset_owners o JOIN messages m ON m.source=o.owner_id WHERE o.kind='message' AND m.conversation_id=? ORDER BY m.date_ns DESC,m.id DESC LIMIT 100)",
        &.{.{ .text = id }},
    );
}
pub fn readBytes(a: u.Allocator, fd: c_int, length: usize) ReadBytesError![]const u8 {
    if (length == 0 or length > max_source) return error.InvalidImage;
    const bytes = try a.alloc(u8, length);
    var offset: usize = 0;
    while (offset < length) {
        const n = u.c.pread(fd, bytes[offset..].ptr, length - offset, @intCast(offset));
        if (n <= 0) return error.InvalidImage;
        offset += @intCast(n);
    }
    return bytes;
}
fn digest(a: u.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    return a.dupe(u8, &hex);
}
pub fn verifyBytes(a: u.Allocator, bytes: []const u8, etag: []const u8) u.Allocator.Error!bool {
    return u.eq(try digest(a, bytes), etag);
}
fn fingerprint(a: u.Allocator, value: c.ZrMediaFingerprint) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}:{d}:{d}:{d}:{d}:{d}:{d}", .{
        transform_version,
        value.device,
        value.inode,
        value.bytes,
        value.modified_sec,
        value.modified_ns,
        value.changed_sec,
        value.changed_ns,
    });
}
fn openSource(self: *Assets, a: u.Allocator, source: Source, fp: *c.ZrMediaFingerprint) !c_int {
    // Reopen the approved namespace for every inspection, including the check
    // after conversion. A replaced root must not leave an old directory live.
    const root_fd = c.zr_media_directory(try a.dupeZ(u8, self.root_path), 0);
    if (root_fd < 0) return root_fd;
    defer _ = u.c.close(root_fd);
    if (source.path.len == 0) return -2;
    const relative_path = self.relative(source.path) orelse return -3;
    return c.zr_media_source(root_fd, try a.dupeZ(u8, relative_path), fp);
}
fn current(a: u.Allocator, j: Journal, epoch: []const u8, source: Source) !bool {
    if (!u.eq(epoch, try j.epoch(a))) return false;
    const q = try j.db.prepare("SELECT version,path FROM asset_sources WHERE id=? AND EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=asset_sources.id)");
    defer q.close();
    try q.bind(&.{.{ .text = source.id }});
    return try q.step() and u.eq(q.bytes(0), source.version) and u.eq(q.bytes(1), source.path);
}

fn checkSources(self: *Assets, core: *Core, a: u.Allocator) !void {
    core.lock();
    const j = core.journal;
    const batch = batch: {
        defer core.unlock();
        const epoch = try j.epoch(a);
        const q = try j.db.prepare(source_columns ++ " WHERE kind='attachment' AND check_ms<=? AND EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=asset_sources.id) ORDER BY check_ms,id LIMIT 16");
        defer q.close();
        try q.bind(&.{.{ .int = u.now() }});
        var sources: std.ArrayList(Source) = .empty;
        while (try q.step()) try sources.append(a, try sourceRow(a, q));
        break :batch .{ .epoch = epoch, .sources = try sources.toOwnedSlice(a) };
    };
    for (batch.sources) |original| {
        var fp: c.ZrMediaFingerprint = undefined;
        const fd = try self.openSource(a, original, &fp);
        if (fd >= 0) _ = u.c.close(fd);
        const signature = if (fd >= 0) try fingerprint(a, fp) else try std.fmt.allocPrint(
            a,
            "error:{d}",
            .{fd},
        );
        core.lock();
        defer core.unlock();
        try j.begin();
        errdefer j.rollback();
        if (!try current(a, j, batch.epoch, original)) {
            j.rollback();
            continue;
        }
        var source = original;
        if (!u.eq(signature, original.fingerprint)) {
            if (original.fingerprint.len > 0) source.version = try rotate(
                a,
                j,
                original,
                original.path,
                signature,
            ) else try j.execute(
                "UPDATE asset_sources SET fingerprint=? WHERE id=?",
                &.{ .{ .text = signature }, .{ .text = source.id } },
            );
            source.fingerprint = signature;
            try j.execute(
                "UPDATE asset_work SET attempt_ms=0 WHERE asset_id=? AND version=?",
                &.{ .{ .text = source.id }, .{ .text = source.version } },
            );
            try publishOwners(a, j, source.id);
        }
        const attempts = if (fd >= 0) 0 else @min(original.attempts + 1, 6);
        try j.execute("UPDATE asset_sources SET check_ms=?,attempts=? WHERE id=?", &.{
            .{ .int = u.now() + if (fd >= 0) @as(i64, 3000) else @min(
                @as(i64, 1000) << @intCast(attempts),
                30000,
            ) },
            .{ .int = attempts },
            .{ .text = source.id },
        });
        if (fd < 0) try state(a, j, source, if (fd == -2) .not_local else if (fd == -4) .oversized else .unavailable, switch (fd) {
            -2 => "not_local",
            -3 => "unsafe_source",
            -4 => "source_too_large",
            else => "source_unavailable",
        });
        const requested = try j.db.prepare("SELECT record FROM asset_representations WHERE asset_id=? AND version=? AND requested=1");
        defer requested.close();
        try requested.bind(&.{ .{ .text = source.id }, .{ .text = source.version } });
        while (try requested.step()) {
            const ref = (try std.json.parseFromSlice(
                t.AssetRef,
                a,
                requested.bytes(0),
                .{ .allocate = .alloc_always },
            )).value;
            if (fd >= 0) enqueue(a, j, ref, false) catch |err| {
                if (err != error.AssetQueueFull) return err;
            };
        }
        try j.commit();
    }
}
const Job = struct {
    source: Source,
    variant: Variant,
    epoch: []const u8,
    etag: ?[]const u8,
};
fn nextJob(a: u.Allocator, core: *Core, contact: bool) !?Job {
    core.lock();
    defer core.unlock();
    const j = core.journal;
    const q = try j.db.prepare("SELECT s.id,s.kind,s.path,s.version,s.fingerprint,s.attempts,w.variant,r.etag FROM asset_work w JOIN asset_sources s ON s.id=w.asset_id AND s.version=w.version JOIN asset_representations r ON r.asset_id=w.asset_id AND r.version=w.version AND r.variant=w.variant WHERE w.attempt_ms<=? AND (s.kind='contact')=? AND EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=s.id) ORDER BY w.attempt_ms,w.rowid LIMIT 1");
    defer q.close();
    try q.bind(&.{ .{ .int = u.now() }, .{ .int = @intFromBool(contact) } });
    if (!try q.step()) return null;
    return .{
        .source = try sourceRow(a, q),
        .variant = std.meta.stringToEnum(Variant, q.bytes(6)) orelse return error.InvalidAsset,
        .epoch = try j.epoch(a),
        .etag = if (q.bytes(7).len > 0) try q.text(a, 7) else null,
    };
}
fn failJob(a: u.Allocator, j: Journal, job: Job, code: c_int) !void {
    var ref = try reference(a, j, job.source.id, job.variant);
    ref.availability = switch (code) {
        -2 => .not_local,
        -4 => .oversized,
        -5 => .unsupported,
        -7 => .pending,
        else => .unavailable,
    };
    ref.reason = switch (code) {
        -2 => "not_local",
        -3 => "unsafe_source",
        -4 => "image_too_large",
        -5 => "unsupported_or_corrupt_image",
        -6 => "conversion_timeout",
        -7 => "source_changed",
        -8 => "helper_unavailable",
        else => "source_unavailable",
    };
    try j.execute("UPDATE asset_representations SET record=? WHERE asset_id=? AND version=? AND variant=?", &.{
        .{ .text = try u.json(a, ref) },
        .{ .text = ref.id },
        .{ .text = ref.version },
        .{ .text = @tagName(ref.variant) },
    });
    if (retryable(ref)) try j.execute("UPDATE asset_work SET attempt_ms=? WHERE asset_id=? AND version=? AND variant=?", &.{
        .{ .int = u.now() + 30000 },
        .{ .text = ref.id },
        .{ .text = ref.version },
        .{ .text = @tagName(ref.variant) },
    }) else try j.execute("DELETE FROM asset_work WHERE asset_id=? AND version=? AND variant=?", &.{
        .{ .text = ref.id },
        .{ .text = ref.version },
        .{ .text = @tagName(ref.variant) },
    });
    try publishOwners(a, j, ref.id);
}
fn convert(self: *Assets, core: *Core, a: u.Allocator, job: Job) !void {
    var fp: c.ZrMediaFingerprint = undefined;
    const photo = if (u.eq(job.source.kind, "contact")) (try std.json.parseFromSlice(
        contacts.PhotoSource,
        a,
        job.source.path,
        .{},
    )).value else null;
    const source_temp = try std.fmt.allocPrintSentinel(a, ".tmp-{s}", .{try u.id(a)}, 0);
    const payload = u.eq(job.source.kind, "payload");
    const photo_fd = if (photo != null or payload) c.zr_media_temporary(self.cache_fd, source_temp) else -1;
    defer if (photo_fd >= 0) {
        _ = u.c.close(photo_fd);
        _ = c.zr_media_remove(self.cache_fd, source_temp);
    };
    const input = if (photo) |p| input: {
        if (photo_fd < 0) return error.AssetCacheUnavailable;
        const result = try contacts.thumbnail(a, core, p, photo_fd);
        break :input if (result == 0) u.c.dup(photo_fd) else result;
    } else if (payload) decoded: {
        if (photo_fd < 0) return error.AssetCacheUnavailable;
        const bytes = bytes: {
            core.lock();
            defer core.unlock();
            if (!try current(a, core.journal, job.epoch, job.source)) return;
            const q = try core.journal.db.prepare("SELECT bytes FROM asset_blobs WHERE asset_id=?");
            defer q.close();
            try q.bind(&.{.{ .text = job.source.id }});
            if (!try q.step()) break :decoded @as(c_int, -2);
            break :bytes try a.dupe(u8, q.bytes(0));
        };
        if (!u.eq(try digest(a, bytes), job.source.path)) return;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = u.c.write(photo_fd, bytes[offset..].ptr, bytes.len - offset);
            if (n <= 0) return error.AssetCacheUnavailable;
            offset += @intCast(n);
        }
        break :decoded u.c.dup(photo_fd);
    } else try self.openSource(a, job.source, &fp);
    defer if (input >= 0) {
        _ = u.c.close(input);
    };
    const temporary = try std.fmt.allocPrintSentinel(a, ".tmp-{s}", .{try u.id(a)}, 0);
    const output = c.zr_media_temporary(self.cache_fd, temporary);
    if (output < 0) return error.AssetCacheUnavailable;
    defer _ = u.c.close(output);
    defer _ = c.zr_media_remove(self.cache_fd, temporary);
    var info: c.ZrImageInfo = undefined;
    var code: c_int = if (input < 0) input else if (photo == null and !payload and !u.eq(
        try fingerprint(a, fp),
        job.source.fingerprint,
    )) -7 else c.zr_media_convert(
        self.helper_path,
        input,
        output,
        @tagName(job.variant),
        &info,
        15000,
    );
    if (photo) |p| {
        if (!try contacts.photoCurrent(a, core, p)) return;
    } else if (code == 0 and !payload) {
        var reopened: c.ZrMediaFingerprint = undefined;
        const fd = try self.openSource(a, job.source, &reopened);
        if (fd >= 0) _ = u.c.close(fd);
        if (fd < 0 or c.zr_media_same(&fp, &reopened) == 0) code = -7;
    }
    const hash = if (code == 0) try digest(a, try readBytes(a, output, @intCast(info.bytes))) else null;
    var installed_name: ?[:0]const u8 = null;
    var published = false;
    defer if (installed_name != null and !published) {
        _ = c.zr_media_remove(self.cache_fd, installed_name.?);
    };
    if (code == 0 and (job.etag == null or u.eq(job.etag.?, hash.?))) {
        // fsync/rename is outside the writer lock. A stale/failed completion
        // removes its installed file; startup GC handles a crash in this gap.
        const name = try std.fmt.allocPrintSentinel(a, "{s}-{s}-{s}", .{
            job.source.id,
            job.source.version,
            @tagName(job.variant),
        }, 0);
        if (c.zr_media_install(self.cache_fd, output, temporary, name) != 0) return error.AssetCacheUnavailable;
        installed_name = name;
    }
    core.lock();
    defer core.unlock();
    const j = core.journal;
    try j.begin();
    errdefer j.rollback();
    if (!try current(a, j, job.epoch, job.source)) {
        j.rollback();
        return;
    }
    if (code != 0) {
        try failJob(a, j, job, code);
    } else if (job.etag != null and !u.eq(job.etag.?, hash.?)) {
        // An evicted representation may only reuse its URL if bytes agree.
        _ = try rotate(a, j, job.source, job.source.path, job.source.fingerprint);
        try publishOwners(a, j, job.source.id);
    } else {
        const ref: t.AssetRef = .{
            .id = job.source.id,
            .version = job.source.version,
            .variant = job.variant,
            .availability = .ready,
            .mime_type = if (info.png != 0) "image/png" else "image/jpeg",
            .bytes = try u.decimal(a, @intCast(info.bytes)),
            .width = info.width,
            .height = info.height,
            .still_preview = info.still != 0,
        };
        try j.execute("UPDATE asset_representations SET record=?,etag=?,file_name=?,bytes=?,last_access_ms=? WHERE asset_id=? AND version=? AND variant=?", &.{
            .{ .text = try u.json(a, ref) },
            .{ .text = hash.? },
            .{ .text = installed_name.? },
            .{ .int = @intCast(info.bytes) },
            .{ .int = u.now() },
            .{ .text = ref.id },
            .{ .text = ref.version },
            .{ .text = @tagName(ref.variant) },
        });
        try j.execute("DELETE FROM asset_work WHERE asset_id=? AND version=? AND variant=?", &.{
            .{ .text = ref.id },
            .{ .text = ref.version },
            .{ .text = @tagName(ref.variant) },
        });
        try publishOwners(a, j, ref.id);
    }
    try j.commit();
    published = true;
}

fn collect(self: *Assets, core: *Core, a: u.Allocator, reserve: usize) !void {
    core.lock();
    const removals = removals: {
        defer core.unlock();
        const j = core.journal;
        try j.begin();
        errdefer j.rollback();
        var total = try j.db.scalar("SELECT coalesce(sum(bytes),0) FROM asset_representations");
        const q = try j.db.prepare("SELECT r.asset_id,r.version,r.variant,r.file_name,r.bytes,r.record,s.version,EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=r.asset_id) FROM asset_representations r JOIN asset_sources s ON s.id=r.asset_id WHERE r.file_name IS NOT NULL ORDER BY (r.version=s.version AND EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=r.asset_id)),r.last_access_ms LIMIT 64");
        defer q.close();
        const Entry = struct {
            value: Lookup,
            obsolete: bool,
            retired: bool,
            bytes: i64,
        };
        var candidates: std.ArrayList(Entry) = .empty;
        while (try q.step()) try candidates.append(a, .{
            .value = .{
                .ref = (try std.json.parseFromSlice(
                    t.AssetRef,
                    a,
                    q.bytes(5),
                    .{ .allocate = .alloc_always },
                )).value,
                .etag = null,
                .file_name = try q.text(a, 3),
            },
            .obsolete = !u.eq(q.bytes(1), q.bytes(6)) or q.int(7) == 0,
            .retired = !u.eq(q.bytes(1), q.bytes(6)),
            .bytes = q.int(4),
        });
        var names: std.ArrayList([]const u8) = .empty;
        for (candidates.items) |candidate| {
            if (!candidate.obsolete and total <= cache_budget - reserve) break;
            total -= candidate.bytes;
            try names.append(a, candidate.value.file_name.?);
            const ref = candidate.value.ref;
            if (candidate.retired) try j.execute("DELETE FROM asset_representations WHERE asset_id=? AND version=? AND variant=?", &.{
                .{ .text = ref.id },
                .{ .text = ref.version },
                .{ .text = @tagName(ref.variant) },
            }) else {
                var pending = ref;
                pending.availability = .pending;
                pending.reason = "cache_evicted";
                try j.execute("UPDATE asset_representations SET record=?,file_name=NULL,bytes=0,requested=0 WHERE asset_id=? AND version=? AND variant=?", &.{
                    .{ .text = try u.json(a, pending) },
                    .{ .text = ref.id },
                    .{ .text = ref.version },
                    .{ .text = @tagName(ref.variant) },
                });
                try publishOwners(a, j, ref.id);
            }
        }
        try j.db.exec("DELETE FROM asset_work WHERE NOT EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=asset_work.asset_id)");
        try j.db.exec("DELETE FROM asset_blobs WHERE NOT EXISTS(SELECT 1 FROM asset_owners WHERE asset_id=asset_blobs.asset_id)");
        try j.db.exec("DELETE FROM asset_representations WHERE file_name IS NULL AND version<>(SELECT version FROM asset_sources WHERE id=asset_id)");
        try j.commit();
        break :removals names.items;
    };
    for (removals) |name| _ = c.zr_media_remove(self.cache_fd, try a.dupeZ(u8, name));
}
fn sweepOrphans(self: *Assets, core: *Core) !void {
    const scan = c.zr_media_scan(self.cache_fd) orelse return error.AssetCacheUnavailable;
    defer c.zr_media_scan_close(scan);
    var name: [256]u8 = undefined;
    while (true) {
        const n = c.zr_media_scan_next(scan, &name, name.len);
        if (n <= 0) break;
        const key = name[0..@intCast(n)];
        if (key.len < 75 or key[36] != '-' or key[73] != '-' or !t.uuid(key[0..36]) or !t.uuid(key[37..73]) or std.meta.stringToEnum(
            Variant,
            key[74..],
        ) == null) continue;
        core.lock();
        const referenced = referenced: {
            defer core.unlock();
            const q = try core.journal.db.prepare("SELECT 1 FROM asset_representations WHERE file_name=? LIMIT 1");
            defer q.close();
            try q.bind(&.{.{ .text = key }});
            break :referenced try q.step();
        };
        if (!referenced) _ = c.zr_media_remove(self.cache_fd, @ptrCast(&name));
    }
}
pub fn contactWork(a: u.Allocator, core: *Core) ContactWorkError!void {
    const self = if (core.assets_service) |*value| value else return;
    // Keep Contacts reads on its dedicated worker, while sharing the bounded
    // conversion lane and cache maintenance with attachment/preview sources.
    if (self.worker_busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    defer self.worker_busy.store(false, .release);
    if (try nextJob(a, core, true)) |job| {
        try self.collect(core, a, max_derivative);
        core.lock();
        const enough_space = (core.journal.db.scalar("SELECT coalesce(sum(bytes),0) FROM asset_representations") catch cache_budget) <= cache_budget - max_derivative;
        core.unlock();
        if (enough_space) try self.convert(core, a, job);
    }
}
pub fn loop(core: *Core) void {
    u.c.zr_thread_qos(0);
    const self = if (core.assets_service) |*value| value else return;
    var maintenance: i64 = 0;
    while (!core.stop.load(.acquire)) {
        if (self.worker_busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            core.sleep(250);
            continue;
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        self.checkSources(core, a) catch {};
        if (nextJob(a, core, false) catch null) |job| {
            self.collect(core, a, max_derivative) catch {
                self.worker_busy.store(false, .release);
                core.sleep(1000);
                continue;
            };
            core.lock();
            const enough_space = (core.journal.db.scalar("SELECT coalesce(sum(bytes),0) FROM asset_representations") catch cache_budget) <= cache_budget - max_derivative;
            core.unlock();
            if (enough_space) self.convert(core, a, job) catch {
                core.sleep(1000);
            } else core.sleep(250);
        }
        if (u.now() >= maintenance) {
            self.collect(core, a, 0) catch {};
            self.sweepOrphans(core) catch {};
            maintenance = u.now() + 10000;
        }
        self.worker_busy.store(false, .release);
        core.sleep(250);
    }
}

test "asset requests deduplicate and enforce the shared durable queue bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    try j.begin();
    defer j.rollback();
    for (0..max_queue) |i| {
        const id = try register(
            a,
            j,
            "attachment",
            try std.fmt.allocPrint(a, "fixture-{d}", .{i}),
            "",
        );
        const ref = try reference(a, j, id, .inline_image);
        try enqueue(a, j, ref, true);
        try enqueue(a, j, ref, true);
    }
    try std.testing.expectEqual(
        @as(i64, max_queue),
        try j.db.scalar("SELECT count(*) FROM asset_work"),
    );
    const extra = try register(a, j, "attachment", "extra", "");
    try std.testing.expectError(
        error.AssetQueueFull,
        enqueue(a, j, try reference(a, j, extra, .inline_image), true),
    );
    try j.reset(a);
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM asset_work"));
}
