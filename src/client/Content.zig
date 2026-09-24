//! Immutable message blocks. Missing/unverified placement falls back to the
//! entire original text, then attachments and cards, without losing captions.
const std = @import("std");
const t = @import("../protocol/types.zig");
const u = @import("../common.zig");
const display = @import("display.zig");
pub const Block = struct {
    part_id: ?[]const u8 = null,
    source_text: ?[]const u8 = null,
    value: union(enum) {
        text: []const u8,
        attachment: t.Attachment,
        card: t.LinkPreview,
        reactions: []const Chip,
        more: Section,
    },
};
pub const Section = enum { attachments, previews, reactions, parts };
pub const Chip = struct { label: []const u8, actors: []const t.ReactionActor, unresolved: bool };

pub fn prepare(a: u.Allocator, m: t.Message) ![]const Block {
    if (m.reaction_event != null) return &.{};
    const text: []const u8 = m.text orelse "";
    const complete = if (m.enrichment) |e| e.attachments.complete and e.previews.complete and e.reactions.complete and e.parts.complete else true;
    if (m.attachments.len == 0 and (if (m.link_previews) |items| items.len == 0 else true) and (if (m.reactions) |items| items.len == 0 else true) and complete and std.ascii.indexOfIgnoreCase(text, "http://") == null and std.ascii.indexOfIgnoreCase(text, "https://") == null) return &.{};
    var blocks: std.ArrayList(Block) = .empty;
    const previews = m.link_previews orelse &.{};
    var attachments_seen = try a.alloc(bool, m.attachments.len);
    @memset(attachments_seen, false);
    var previews_seen = try a.alloc(bool, previews.len);
    @memset(previews_seen, false);
    const parts = m.parts orelse &.{};
    const mapped = if (m.enrichment) |e| e.part_mapping == .resolved and e.parts.complete else false;
    var text_present = false;
    // Validate all text ranges before using any of the placement information.
    // Incomplete or malformed ranges must not swallow the original caption.
    var text_bytes: usize = 0;
    var valid_text = mapped;
    for (parts) |part| if (part.kind == .text) {
        const value = partText(m, part) orelse {
            valid_text = false;
            continue;
        };
        const original = m.text orelse "";
        if (text_bytes > original.len or value.len > original.len - text_bytes or !u.eq(original[text_bytes..][0..value.len], value)) valid_text = false;
        text_bytes +|= value.len;
    };
    const original: []const u8 = m.text orelse "";
    valid_text = valid_text and text_bytes == original.len;
    if (!valid_text) if (m.text) |value| if (value.len > 0) {
        try blocks.append(a, .{ .source_text = value, .value = .{ .text = display.message(a, value) } });
        text_present = true;
    };
    if (mapped) for (parts) |part| {
        switch (part.kind) {
            .text => if (valid_text) {
                const value = partText(m, part) orelse continue;
                try blocks.append(a, .{ .part_id = part.id, .source_text = value, .value = .{ .text = display.message(a, value) } });
                text_present = true;
            },
            .attachment => for (m.attachments, 0..) |item, i| {
                if (!attachments_seen[i] and u.eq(item.id, part.attachment_id orelse "")) {
                    attachments_seen[i] = true;
                    if (!item.preview_artwork) try blocks.append(a, .{ .part_id = part.id, .value = .{ .attachment = item } });
                }
            },
            .link_preview => for (previews, 0..) |item, i| {
                if (!previews_seen[i] and u.eq(item.id, part.preview_id orelse "")) {
                    previews_seen[i] = true;
                    try blocks.append(a, .{ .part_id = part.id, .value = .{ .card = item } });
                }
            },
        }
    };
    for (m.attachments, 0..) |item, i| if (!attachments_seen[i] and !item.preview_artwork) {
        try blocks.append(a, .{ .value = .{ .attachment = item } });
    };
    for (previews, 0..) |item, i| if (!previews_seen[i]) {
        try blocks.append(a, .{ .part_id = if (mapped) item.part_id else null, .value = .{ .card = item } });
    };
    if (blocks.items.len == 0 and !text_present) try blocks.append(a, .{ .value = .{ .text = display.record(a, m) } });
    // Place chips immediately below the referenced block; unresolved or absent
    // parts get one message-level group with an explicit explanation in detail.
    const grouped = try ReactionGroups.init(a, m.reactions orelse &.{}, blocks.items);
    var result: std.ArrayList(Block) = .empty;
    for (blocks.items) |block| {
        try result.append(a, block);
        if (block.part_id) |id| {
            const chips = grouped.groups[grouped.by_part.get(id).?];
            if (chips.len > 0) try result.append(a, .{ .part_id = id, .value = .{ .reactions = chips } });
        }
    }
    const chips = grouped.groups[0];
    if (chips.len > 0) try result.append(a, .{ .value = .{ .reactions = chips } });
    if (m.enrichment) |e| inline for (comptime std.meta.tags(Section)) |section| {
        if (!@field(e, @tagName(section)).complete) try result.append(a, .{ .value = .{ .more = section } });
    };
    return result.items;
}
pub fn partText(m: t.Message, part: t.MessagePart) ?[]const u8 {
    if (part.text) |value| return value;
    const text = m.text orelse return null;
    const start = part.text_start orelse return null;
    const len = part.text_length orelse return null;
    if (start > text.len or len > text.len - start) return null;
    const value = text[start..][0..len];
    return if (std.unicode.utf8ValidateSlice(value)) value else null;
}
// Resolve targets and build actor lists once. Re-scanning every block for
// every reaction at every part made hostile metadata cubic in its item count.
const ReactionGroups = struct {
    groups: []const []const Chip,
    by_part: std.StringHashMapUnmanaged(usize),
    fn init(a: u.Allocator, reactions: []const t.Reaction, blocks: []const Block) !ReactionGroups {
        const PendingChip = struct { label: []const u8, actors: std.ArrayList(t.ReactionActor) = .empty };
        const PendingGroup = struct { labels: std.StringHashMapUnmanaged(usize) = .empty, chips: std.ArrayList(PendingChip) = .empty };
        var by_part: std.StringHashMapUnmanaged(usize) = .empty;
        var pending: std.ArrayList(PendingGroup) = .empty;
        try pending.append(a, .{}); // Unresolved/message-level reactions.
        for (blocks) |block| if (block.part_id) |id| {
            const entry = try by_part.getOrPut(a, id);
            if (!entry.found_existing) {
                entry.value_ptr.* = pending.items.len;
                try pending.append(a, .{});
            }
        };
        for (reactions) |reaction| {
            const index = if (reaction.part_state == .resolved and reaction.part_id != null) by_part.get(reaction.part_id.?) orelse 0 else 0;
            const group = &pending.items[index];
            const label = reaction.emoji orelse reactionLabel(reaction.key);
            const entry = try group.labels.getOrPut(a, label);
            if (!entry.found_existing) {
                entry.value_ptr.* = group.chips.items.len;
                try group.chips.append(a, .{ .label = label });
            }
            try group.chips.items[entry.value_ptr.*].actors.append(a, reaction.actor);
        }
        const groups = try a.alloc([]const Chip, pending.items.len);
        for (pending.items, groups, 0..) |group, *chips, index| {
            const values = try a.alloc(Chip, group.chips.items.len);
            for (group.chips.items, values) |chip, *value| value.* = .{ .label = chip.label, .actors = chip.actors.items, .unresolved = index == 0 };
            chips.* = values;
        }
        return .{ .groups = groups, .by_part = by_part };
    }
};
fn reactionLabel(key: []const u8) []const u8 {
    const keys = [_][]const u8{ "heart", "like", "dislike", "laugh", "emphasize", "question" };
    const labels = [_][]const u8{ "❤️", "👍", "👎", "😂", "‼️", "❓" };
    for (keys, labels) |k, label| if (u.eq(key, k)) return label;
    return key;
}

test "composite blocks keep captions, source order, part reactions and overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = t.Message{ .sender = "peer", .service = "imessage", .direction = .incoming, .timestamp = "", .kind = .attachment, .decoding = .plain, .observed_status = .received, .text = "Caption 👋", .attachments = &.{.{ .id = "a", .name = "photo", .mime_type = "image/png", .bytes = "20" }}, .parts = &.{.{ .id = "image-part", .kind = .attachment, .attachment_id = "a" }}, .enrichment = .{ .part_mapping = .resolved, .reactions = .{ .total = 3, .complete = false } }, .reactions = &.{ .{ .id = "r", .part_id = "image-part", .part_state = .resolved, .actor = .{ .service = "imessage", .is_self = true }, .key = "custom", .emoji = "👩🏽‍💻" }, .{ .id = "r2", .actor = .{ .service = "imessage", .address = "peer" }, .key = "love" } } };
    const blocks = try prepare(a, m);
    try std.testing.expectEqualStrings("Caption 👋", blocks[0].value.text);
    try std.testing.expectEqualStrings("a", blocks[1].value.attachment.id);
    try std.testing.expectEqualStrings("👩🏽‍💻", blocks[2].value.reactions[0].label);
    try std.testing.expect(!blocks[2].value.reactions[0].unresolved);
    try std.testing.expect(blocks[3].value.reactions[0].unresolved);
    try std.testing.expectEqual(Section.reactions, blocks[4].value.more);
}

test "many reactions group each actor once across many target parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const count = 4096;
    const blocks = try a.alloc(Block, count);
    const reactions = try a.alloc(t.Reaction, count);
    for (blocks, reactions, 0..) |*block, *reaction, i| {
        const id = try std.fmt.allocPrint(a, "part:{d}", .{i});
        block.* = .{ .part_id = id, .value = .{ .text = "text" } };
        reaction.* = .{ .id = id, .part_id = id, .part_state = .resolved, .actor = .{ .address = "peer", .service = "imessage" }, .key = "like" };
    }
    const grouped = try ReactionGroups.init(a, reactions, blocks);
    try std.testing.expectEqual(@as(usize, count + 1), grouped.groups.len);
    try std.testing.expectEqual(@as(usize, 0), grouped.groups[0].len);
    for (grouped.groups[1..]) |chips| {
        try std.testing.expectEqual(@as(usize, 1), chips.len);
        try std.testing.expectEqual(@as(usize, 1), chips[0].actors.len);
        try std.testing.expect(!chips[0].unresolved);
    }
    for (reactions) |*reaction| reaction.part_id = "missing";
    const unresolved = try ReactionGroups.init(a, reactions, blocks);
    try std.testing.expectEqual(@as(usize, count), unresolved.groups[0][0].actors.len);
    try std.testing.expect(unresolved.groups[0][0].unresolved);
}
