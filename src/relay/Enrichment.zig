//! Canonical section storage is independent of inline transport budgets. The
//! journal writer owns all calls, so section changes and their message revision
//! commit together. Overflow tokens bind to the full message revision.
const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol/types.zig");
const Journal = @import("Journal.zig");
pub const Section = enum { attachments, previews, reactions, parts };
pub const Prepared = struct {
    value: t.Message,
    sections: [4]?[]const []const u8,
    hashes: [4]?[]const u8,
    changed: bool,
};

fn itemType(comptime section: Section) type {
    return switch (section) {
        .attachments => t.Attachment,
        .previews => t.LinkPreview,
        .reactions => t.Reaction,
        .parts => t.MessagePart,
    };
}
pub fn load(j: Journal, a: u.Allocator, comptime section: Section, id: []const u8) !?[]const itemType(section) {
    var exists = try j.db.prepare("SELECT 1 FROM enrichment_sections WHERE message_id=? AND section=?");
    defer exists.close();
    try exists.bind(&.{ .{ .text = id }, .{ .text = @tagName(section) } });
    if (!try exists.step()) return null;
    var q = try j.db.prepare("SELECT record FROM enrichment_items WHERE message_id=? AND section=? ORDER BY position");
    defer q.close();
    try q.bind(&.{ .{ .text = id }, .{ .text = @tagName(section) } });
    var values: std.ArrayList(itemType(section)) = .empty;
    while (try q.step()) try values.append(a, (try std.json.parseFromSlice(itemType(section), a, q.bytes(0), .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value);
    return try values.toOwnedSlice(a);
}

pub fn full(j: Journal, a: u.Allocator, value: t.Message) !t.Message {
    var v = value;
    v.attachments = (try load(j, a, .attachments, v.id)) orelse v.attachments;
    v.link_previews = (try load(j, a, .previews, v.id)) orelse v.link_previews;
    v.reactions = (try load(j, a, .reactions, v.id)) orelse v.reactions;
    v.parts = (try load(j, a, .parts, v.id)) orelse v.parts;
    return v;
}

pub fn fallbackParts(a: u.Allocator, v: t.Message) ![]const t.MessagePart {
    var parts: std.ArrayList(t.MessagePart) = .empty;
    if (v.text) |text| if (text.len > 0) {
        try parts.append(a, .{ .id = "text", .kind = .text, .text_start = 0, .text_length = text.len });
    };
    for (v.attachments) |attachment| if (!attachment.preview_artwork) {
        try parts.append(a, .{ .id = try std.fmt.allocPrint(a, "attachment:{s}", .{attachment.id}), .kind = .attachment, .attachment_id = attachment.id });
    };
    for (v.link_previews orelse &.{}) |preview| try parts.append(a, .{ .id = preview.part_id, .kind = .link_preview, .preview_id = preview.id });
    return parts.toOwnedSlice(a);
}

pub fn prepare(j: Journal, a: u.Allocator, value: t.Message, previous: ?t.Message) !Prepared {
    var v = value;
    if (previous) |old_inline| {
        const old = try full(j, a, old_inline);
        // Null is unsupplied, never a request to erase a worker's aggregate.
        if (v.reactions == null) v.reactions = old.reactions;
        if (v.link_previews == null) v.link_previews = old.link_previews;
        if (v.reaction_event == null) v.reaction_event = old.reaction_event;
        var by_id: std.StringHashMapUnmanaged(t.Attachment) = .empty;
        for (old.attachments) |attachment| try by_id.put(a, attachment.id, attachment);
        const merged = try a.dupe(t.Attachment, v.attachments);
        for (merged) |*attachment| if (by_id.get(attachment.id)) |old_attachment| {
            if (attachment.image == null) attachment.image = old_attachment.image;
            if (attachment.viewer == null) attachment.viewer = old_attachment.viewer;
        };
        v.attachments = merged;
    }
    if (v.parts == null) {
        v.parts = try fallbackParts(a, v);
        var metadata = v.enrichment orelse t.Enrichment{ .state = .complete };
        metadata.part_mapping = .unresolved;
        v.enrichment = metadata;
    }
    var result = Prepared{ .value = v, .sections = @splat(null), .hashes = @splat(null), .changed = false };
    inline for (comptime std.meta.tags(Section), 0..) |section, index| {
        const list: ?[]const itemType(section) = switch (section) {
            .attachments => v.attachments,
            .previews => v.link_previews,
            .reactions => v.reactions,
            .parts => v.parts,
        };
        if (list) |items| {
            var encoded: std.ArrayList([]const u8) = .empty;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            for (items) |item| {
                const json = try u.json(a, item);
                // Each item must fit an overflow page on its own. Adapters bound
                // their strings; callers cannot create an unpageable record.
                if (json.len > t.max_metadata_page - 1024) return error.MetadataItemTooLarge;
                hash.update(json);
                hash.update("\n");
                try encoded.append(a, json);
            }
            const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
            result.hashes[index] = try a.dupe(u8, &digest);
            var find = try j.db.prepare("SELECT content FROM enrichment_sections WHERE message_id=? AND section=?");
            defer find.close();
            try find.bind(&.{ .{ .text = v.id }, .{ .text = @tagName(section) } });
            if (!try find.step() or !u.eq(find.bytes(0), &digest)) {
                result.sections[index] = try encoded.toOwnedSlice(a);
                result.changed = true;
            }
        }
    }
    result.value = try inlineMessage(a, v);
    return result;
}

fn length(items: anytype) usize {
    return if (items) |values| values.len else 0;
}

fn inlineMessage(a: u.Allocator, value: t.Message) !t.Message {
    var v = value;
    var metadata = v.enrichment orelse t.Enrichment{ .state = .complete };
    metadata.attachments.total = v.attachments.len;
    metadata.previews.total = length(v.link_previews);
    metadata.reactions.total = length(v.reactions);
    metadata.parts.total = length(v.parts);
    v.attachments = v.attachments[0..@min(v.attachments.len, t.max_inline_attachments)];
    if (v.link_previews) |items| v.link_previews = items[0..@min(items.len, t.max_inline_previews)];
    if (v.reactions) |items| v.reactions = items[0..@min(items.len, t.max_inline_reactions)];
    if (v.parts) |items| v.parts = items[0..@min(items.len, t.max_inline_parts)];
    while (true) {
        metadata.attachments.complete = metadata.attachments.total == v.attachments.len;
        metadata.previews.complete = metadata.previews.total == length(v.link_previews);
        metadata.reactions.complete = metadata.reactions.total == length(v.reactions);
        metadata.parts.complete = metadata.parts.total == length(v.parts);
        v.enrichment = metadata;
        const bytes = try u.json(a, .{ .attachments = v.attachments, .parts = v.parts, .link_previews = v.link_previews, .reactions = v.reactions, .reaction_event = v.reaction_event, .enrichment = metadata });
        if (bytes.len <= t.max_enrichment) return v;
        // Keep every section's prefix and expose all omitted items through the
        // revision-bound endpoint. Trimming never touches original Message.text.
        if (length(v.parts) > 1) {
            v.parts = v.parts.?[0 .. v.parts.?.len - 1];
        } else if (length(v.reactions) > 0) {
            v.reactions = v.reactions.?[0 .. v.reactions.?.len - 1];
        } else if (length(v.link_previews) > 0) {
            v.link_previews = v.link_previews.?[0 .. v.link_previews.?.len - 1];
        } else if (v.attachments.len > 0) {
            v.attachments = v.attachments[0 .. v.attachments.len - 1];
        } else if (length(v.parts) > 0) {
            v.parts = &.{};
        } else return error.MetadataItemTooLarge;
    }
}

pub fn persist(j: Journal, id: []const u8, prepared: Prepared) !void {
    inline for (comptime std.meta.tags(Section), 0..) |section, index| if (prepared.sections[index]) |items| {
        try j.execute("DELETE FROM enrichment_items WHERE message_id=? AND section=?", &.{ .{ .text = id }, .{ .text = @tagName(section) } });
        for (items, 0..) |item, position| try j.execute("INSERT INTO enrichment_items VALUES(?,?,?,?)", &.{ .{ .text = id }, .{ .text = @tagName(section) }, .{ .int = @intCast(position) }, .{ .text = item } });
        try j.execute("INSERT INTO enrichment_sections VALUES(?,?,?) ON CONFLICT(message_id,section) DO UPDATE SET content=excluded.content", &.{ .{ .text = id }, .{ .text = @tagName(section) }, .{ .text = prepared.hashes[index].? } });
    };
}

pub const Page = struct { message_id: []const u8, revision: []const u8, section: Section, items: []const std.json.Value, total: usize, next: ?[]const u8 };
pub fn page(j: Journal, a: u.Allocator, id: []const u8, section: Section, revision: []const u8, after: ?[]const u8, limit: usize) !Page {
    const rev = std.fmt.parseInt(i64, revision, 10) catch return error.InvalidRequest;
    if (rev < 0) return error.InvalidRequest;
    var m = try j.db.prepare("SELECT json_extract(record,'$.revision') FROM messages WHERE id=?");
    defer m.close();
    try m.bind(&.{.{ .text = id }});
    if (!try m.step()) return error.NotFound;
    if (!u.eq(m.bytes(0), revision)) return error.EnrichmentRestartRequired;
    var position: i64 = -1;
    if (after) |token| {
        const prefix = try std.fmt.allocPrint(a, "{s}:{s}:{s}:", .{ id, revision, @tagName(section) });
        if (!std.mem.startsWith(u8, token, prefix)) return error.EnrichmentRestartRequired;
        position = std.fmt.parseInt(i64, token[prefix.len..], 10) catch return error.InvalidRequest;
        if (position < 0) return error.InvalidRequest;
    }
    var count = try j.db.prepare("SELECT count(*) FROM enrichment_items WHERE message_id=? AND section=?");
    defer count.close();
    try count.bind(&.{ .{ .text = id }, .{ .text = @tagName(section) } });
    _ = try count.step();
    var q = try j.db.prepare("SELECT position,record FROM enrichment_items WHERE message_id=? AND section=? AND position>? ORDER BY position LIMIT ?");
    defer q.close();
    try q.bind(&.{ .{ .text = id }, .{ .text = @tagName(section) }, .{ .int = position }, .{ .int = @intCast(limit + 1) } });
    var items: std.ArrayList(std.json.Value) = .empty;
    var bytes: usize = 1024; // Bounds the fixed envelope and continuation token.
    var next: ?[]const u8 = null;
    while (try q.step()) {
        if (items.items.len == limit or bytes + q.bytes(1).len + 1 > t.max_metadata_page) {
            next = try std.fmt.allocPrint(a, "{s}:{s}:{s}:{d}", .{ id, revision, @tagName(section), position });
            break;
        }
        bytes += q.bytes(1).len + 1;
        try items.append(a, (try std.json.parseFromSlice(std.json.Value, a, q.bytes(1), .{ .allocate = .alloc_always })).value);
        position = q.int(0);
    }
    return .{ .message_id = id, .revision = revision, .section = section, .items = try items.toOwnedSlice(a), .total = @intCast(count.int(0)), .next = next };
}

test "overflow is lossless, revision-bound, and preserves captions and independent aggregates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    const cid = try j.conversation(a, "chat", 1, "route", .{ .service = "imessage" }, "historical_import");
    const attachments = try a.alloc(t.Attachment, 60);
    for (attachments, 0..) |*item, i| item.* = .{ .id = try u.decimal(a, @intCast(i)), .name = "Photo", .mime_type = "image/png", .bytes = "123" };
    const reactions = try a.alloc(t.Reaction, 150);
    for (reactions, 0..) |*item, i| item.* = .{ .id = try u.decimal(a, @intCast(i)), .actor = .{ .service = "imessage", .address = try std.fmt.allocPrint(a, "actor-{d}@example.invalid", .{i}) }, .key = "like", .emoji = "👍" };
    const caption = try a.alloc(u8, 60000);
    @memset(caption, 'x');
    const base: t.Message = .{ .conversation_id = cid, .sender = "", .direction = .outgoing, .service = "imessage", .timestamp = "2026-01-01T00:00:00Z", .kind = .attachment, .text = caption, .decoding = .plain, .observed_status = .sent, .attachments = attachments };
    var v = base;
    v.reactions = reactions;
    try j.begin();
    try j.message(a, "message", 1, 10, v, "historical_import");
    try j.commit();
    var find = try j.db.prepare("SELECT record FROM messages");
    defer find.close();
    _ = try find.step();
    const first = (try std.json.parseFromSlice(t.Message, a, find.bytes(0), .{ .allocate = .alloc_always })).value;
    try std.testing.expectEqualStrings(caption, first.text.?);
    try std.testing.expectEqual(@as(usize, 60), first.enrichment.?.attachments.total);
    try std.testing.expectEqual(@as(usize, 150), first.enrichment.?.reactions.total);
    try std.testing.expect(!first.enrichment.?.attachments.complete and !first.enrichment.?.reactions.complete);
    const metadata_json = try u.json(a, .{ .parts = first.parts, .attachments = first.attachments, .link_previews = first.link_previews, .reactions = first.reactions, .reaction_event = first.reaction_event, .enrichment = first.enrichment });
    try std.testing.expect(metadata_json.len <= t.max_enrichment);
    try std.testing.expectEqual(@as(?usize, 60000), first.parts.?[0].text_length);
    var after: ?[]const u8 = null;
    var seen: usize = 0;
    while (true) {
        const p = try page(j, a, first.id, .reactions, first.revision, after, 40);
        try std.testing.expect((try u.json(a, p)).len <= t.max_metadata_page);
        for (p.items) |item| {
            try std.testing.expectEqualStrings(reactions[seen].id, item.object.get("id").?.string);
            seen += 1;
        }
        after = p.next;
        if (after == null) break;
    }
    try std.testing.expectEqual(@as(usize, 150), seen);
    const p = try page(j, a, first.id, .attachments, first.revision, null, 2);
    try std.testing.expectError(error.EnrichmentRestartRequired, page(j, a, first.id, .reactions, first.revision, p.next, 2));
    // Source refresh has no reaction field; it must retain all 150 canonical
    // items, including those that did not fit in the inline record.
    const revision = try j.sequence();
    try j.message(a, "message", 1, 10, base, "reconciliation");
    try std.testing.expectEqual(revision, try j.sequence());
    try std.testing.expectEqual(@as(usize, 150), (try load(j, a, .reactions, first.id)).?.len);
    v.reactions = &.{};
    try j.message(a, "message", 1, 10, v, "reconciliation");
    try std.testing.expectError(error.EnrichmentRestartRequired, page(j, a, first.id, .attachments, first.revision, p.next, 2));
    try std.testing.expectEqual(@as(usize, 0), (try load(j, a, .reactions, first.id)).?.len);
}
