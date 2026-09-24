//! Frozen pre-enrichment message contract from 96914fa. Keep these enums and
//! fields independent of current types so additive compatibility is tested.
const std = @import("std");
const t = @import("types.zig");
const Attachment = struct { id: []const u8, name: []const u8, mime_type: []const u8, bytes: []const u8 };
const Message = struct {
    id: []const u8 = "",
    revision: []const u8 = "0",
    conversation_id: []const u8 = "",
    sender: []const u8,
    direction: enum { incoming, outgoing },
    service: []const u8,
    timestamp: []const u8,
    kind: enum { text, attachment, reaction, system, unsupported, empty },
    text: ?[]const u8 = null,
    decoding: enum { plain, attributed, empty, unsupported, malformed, oversized },
    attachments: []const Attachment = &.{},
    observed_status: enum { received, sent, delivered, failed, unknown },
};

test "enriched messages parse with the frozen v1 contract and old messages retain absent enrichment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rich: t.Message = .{
        .sender = "fixture@example.invalid",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .attachment,
        .text = "Caption 👩🏽‍💻",
        .decoding = .plain,
        .observed_status = .received,
        .attachments = &.{.{ .id = "fixture-attachment", .name = "photo.heic", .mime_type = "image/heic", .bytes = "123", .image = .{ .id = "asset", .version = "version", .variant = .inline_image, .availability = .pending } }},
        .enrichment = .{ .state = .complete },
        .parts = &.{.{ .id = "text", .kind = .text, .text_start = 0, .text_length = 7 }},
        .link_previews = &.{.{ .id = "card", .part_id = "card", .original_url = "https://example.invalid", .state = .complete }},
        .reactions = &.{.{ .id = "reaction", .actor = .{ .service = "imessage", .is_self = true }, .key = "like", .emoji = "👍" }},
        .reaction_event = .{ .actor = .{ .service = "imessage", .is_self = true }, .operation = .retired, .resolution = .resolved },
    };
    // The existing client uses ignore_unknown_fields for both history records
    // and event records. New values in its closed enums would still fail here.
    inline for (.{ "kind", "direction", "decoding", "observed_status" }) |field| {
        inline for (std.meta.tags(@FieldType(t.Message, field))) |value| {
            @field(rich, field) = value;
            const raw = try std.json.Stringify.valueAlloc(a, rich, .{});
            const old = (try std.json.parseFromSlice(Message, a, raw, .{ .ignore_unknown_fields = true })).value;
            try std.testing.expectEqualStrings(rich.text.?, old.text.?);
            try std.testing.expectEqualStrings("photo.heic", old.attachments[0].name);
            try std.testing.expectEqualStrings(@tagName(value), @tagName(@field(old, field)));
            const legacy_raw = try std.json.Stringify.valueAlloc(a, old, .{});
            const current = (try std.json.parseFromSlice(t.Message, a, legacy_raw, .{ .ignore_unknown_fields = true })).value;
            try std.testing.expect(current.enrichment == null and current.parts == null and current.link_previews == null and current.reactions == null and current.reaction_event == null);
            try std.testing.expect(current.attachments[0].image == null and current.attachments[0].viewer == null);
        }
    }
}
