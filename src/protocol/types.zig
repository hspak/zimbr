const std = @import("std");
const u = @import("../common.zig");
const attachments = @import("attachments.zig");
pub const max_body = 64 * 1024;
pub const max_text = 16 * 1024;
pub const max_decode = 1024 * 1024;
pub const max_page = 200;
pub const default_page = 50;
pub const api_version = "1";
pub const id_length = u.id_length;
pub const max_enrichment = 32 * 1024;
pub const max_metadata_page = 32 * 1024;
pub const max_history_bytes = 8 * 1024 * 1024;
pub const max_inline_attachments = 32;
pub const max_inline_previews = 4;
pub const max_inline_reactions = 128;
pub const max_inline_parts = 128;

/// Background work currently running or ready to run; excludes blocked retries.
pub const SyncActivity = struct {
    messages: bool = false,
    contacts: bool = false,
    images: bool = false,
    media: bool = false,

    pub fn active(self: SyncActivity) bool {
        return self.messages or self.contacts or self.images or self.media;
    }
};

// Null enrichment fields mean "not supplied". A complete, empty aggregate
// explicitly clears earlier content. No existing v1 enum is extended.
pub const EnrichmentStatus = enum {
    pending,
    complete,
    unavailable,
    unsupported,
    malformed,
    oversized,
};
pub const AssetRef = struct {
    id: []const u8,
    version: []const u8,
    variant: enum {
        avatar,
        inline_image,
        viewer,
    },
    mime_type: ?[]const u8 = null,
    bytes: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    availability: enum {
        pending,
        ready,
        not_local,
        unavailable,
        unsupported,
        oversized,
        retired,
    } = .pending,
    reason: ?[]const u8 = null,
    still_preview: bool = false,
};
pub const Identity = struct {
    id: []const u8 = "",
    revision: []const u8 = "0",
    service: []const u8,
    address: []const u8,
    display_name: ?[]const u8 = null,
    avatar: ?AssetRef = null,
    match_state: enum {
        pending,
        matched,
        unmatched,
        ambiguous,
        unavailable,
    } = .pending,
    freshness: enum { fresh, stale } = .fresh,
};
pub const Aggregate = struct { total: usize = 0, complete: bool = true };
pub const Enrichment = struct {
    state: EnrichmentStatus = .pending,
    part_mapping: enum { resolved, unresolved } = .unresolved,
    attachments: Aggregate = .{},
    previews: Aggregate = .{},
    reactions: Aggregate = .{},
    parts: Aggregate = .{},
};
pub const MessagePart = struct {
    id: []const u8,
    kind: enum {
        text,
        attachment,
        link_preview,
    },
    // Source indices are supplied only when verified from the body structure.
    source_index: ?u32 = null,
    text: ?[]const u8 = null,
    // UTF-8 byte range into Message.text; avoids copying a long caption into
    // enrichment metadata. A source parser must use codepoint boundaries.
    text_start: ?usize = null,
    text_length: ?usize = null,
    attachment_id: ?[]const u8 = null,
    preview_id: ?[]const u8 = null,
};
pub const LinkPreview = struct {
    id: []const u8,
    part_id: []const u8,
    original_url: ?[]const u8 = null,
    metadata_url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    site_name: ?[]const u8 = null,
    image: ?AssetRef = null,
    icon: ?AssetRef = null,
    state: EnrichmentStatus = .pending,
};
pub const ReactionActor = struct {
    address: ?[]const u8 = null,
    service: []const u8,
    is_self: bool = false,
};
pub const Reaction = struct {
    id: []const u8,
    part_id: ?[]const u8 = null,
    part_state: enum { resolved, unresolved } = .unresolved,
    actor: ReactionActor,
    key: []const u8,
    emoji: ?[]const u8 = null,
};
pub const ReactionEvent = struct {
    target_message_id: ?[]const u8 = null,
    part_id: ?[]const u8 = null,
    part_state: enum { resolved, unresolved } = .unresolved,
    actor: ReactionActor,
    operation: enum {
        add,
        remove,
        current,
        retired,
        unknown,
    },
    key: ?[]const u8 = null,
    emoji: ?[]const u8 = null,
    resolution: enum {
        pending,
        resolved,
        unavailable,
        unsupported,
        malformed,
    } = .pending,
};
pub const Conversation = struct {
    id: []const u8 = "",
    revision: []const u8 = "0",
    participants: []const []const u8 = &.{},
    title: []const u8 = "",
    service: []const u8,
    last_activity: ?[]const u8 = null,
    history_complete: bool = false,
    sendable: bool = false,
    // Presentation grouping only; IDs and send routes remain distinct.
    thread_id: ?[]const u8 = null,
    is_self: bool = false,
};
pub const Attachment = struct {
    id: []const u8,
    name: []const u8,
    mime_type: []const u8,
    bytes: []const u8,
    image: ?AssetRef = null,
    viewer: ?AssetRef = null,
    preview_artwork: bool = false,
};
// A sidebar projection, never a replacement for the canonical message record.
pub const ConversationPreview = struct {
    conversation_id: []const u8,
    message_id: []const u8,
    revision: []const u8,
    timestamp: []const u8,
    kind: []const u8,
    text: []const u8,
};
pub const Message = struct {
    id: []const u8 = "",
    revision: []const u8 = "0",
    conversation_id: []const u8 = "",
    sender: []const u8,
    direction: enum { incoming, outgoing },
    service: []const u8,
    timestamp: []const u8,
    kind: enum {
        text,
        attachment,
        reaction,
        system,
        unsupported,
        empty,
    },
    text: ?[]const u8 = null,
    decoding: enum {
        plain,
        attributed,
        empty,
        unsupported,
        malformed,
        oversized,
    },
    attachments: []const Attachment = &.{},
    observed_status: enum {
        received,
        sent,
        delivered,
        failed,
        unknown,
    },
    parts: ?[]const MessagePart = null,
    enrichment: ?Enrichment = null,
    link_previews: ?[]const LinkPreview = null,
    reactions: ?[]const Reaction = null,
    reaction_event: ?ReactionEvent = null,
    // Text-first history projection; GET /v1/messages/{id} supplies metadata.
    // Absent/false on canonical records, including those from older relays.
    metadata_deferred: bool = false,
};
pub const Target = struct {
    conversation_id: ?[]const u8 = null,
    recipient: ?struct { address: []const u8, service: []const u8 } = null,
};
pub const SendInput = struct {
    request_id: []const u8,
    server_epoch: []const u8,
    target: Target,
    text: []const u8,
    attachments: []const attachments.Upload = &.{},

    /// Omit empty attachments to preserve persisted text-only idempotency payloads.
    pub fn jsonStringify(self: SendInput, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        try writer.beginObject();
        inline for (.{
            "request_id",
            "server_epoch",
            "target",
            "text",
        }) |field| {
            try writer.objectField(field);
            try writer.write(@field(self, field));
        }
        if (self.attachments.len != 0) {
            try writer.objectField("attachments");
            try writer.write(self.attachments);
        }
        try writer.endObject();
    }
};
pub const SendStatus = enum {
    queued,
    dispatching,
    submitted,
    delivered,
    failed,
    unknown,
};
pub const SendRequest = struct {
    request_id: []const u8,
    server_epoch: []const u8,
    revision: []const u8 = "0",
    target: Target,
    text: []const u8,
    attachments: []const attachments.Upload = &.{},
    state: SendStatus = .queued,
    message_id: ?[]const u8 = null,
    // Presentation-only echo while the observation window is still open.
    // It may be withdrawn if another matching message appears.
    candidate_message_id: ?[]const u8 = null,
    error_info: ?SafeError = null,
};

pub const SafeError = struct {
    code: []const u8,
    message: []const u8,
    outcome: enum { unstarted, uncertain } = .unstarted,
};

pub const ValidateError = attachments.ValidateError || error{
    InvalidRequest,
    TextTooLarge,
    UnsupportedTarget,
};
pub const ParseCursorError = error{ InvalidRequest, ResyncRequired };

/// Accept only canonical Base64url encodings of 16-byte IDs, including zero pad bits.
pub fn validId(s: []const u8) bool {
    if (s.len != id_length) return false;
    var bytes: [16]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&bytes, s) catch return false;
    return true;
}
pub fn validAddress(s: []const u8) bool {
    if (s.len < 3 or s.len > 254) return false;
    if (s[0] == '+') {
        if (s.len < 8 or s.len > 16 or s[1] == '0') return false;
        for (s[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
        return true;
    }
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1 or std.mem.indexOfScalar(u8, s[at + 1 ..], '@') != null) return false;
    if (std.mem.indexOfScalar(u8, s[at + 1 ..], '.') == null) return false;
    for (s) |ch| if (ch <= 32 or ch >= 127 or std.mem.indexOfScalar(u8, "<>\\\"(),;:", ch) != null) return false;
    return true;
}
pub fn validate(v: SendInput) ValidateError!void {
    if (!validId(v.request_id) or !validId(v.server_epoch)) return error.InvalidRequest;
    if (v.text.len > max_text) return error.TextTooLarge;
    try attachments.validateSet(v.attachments);
    if ((v.text.len == 0 and v.attachments.len == 0) or !std.unicode.utf8ValidateSlice(v.text) or std.mem.indexOfScalar(
        u8,
        v.text,
        0,
    ) != null) return error.InvalidRequest;
    if ((v.target.conversation_id != null) == (v.target.recipient != null)) return error.InvalidRequest;
    if (v.target.conversation_id) |id| {
        if (!validId(id)) return error.InvalidRequest;
    }
    if (v.target.recipient) |r| {
        if (!u.eq(r.service, "imessage")) return error.UnsupportedTarget;
        if (!validAddress(r.address)) return error.InvalidRequest;
    }
}
pub fn cursor(a: u.Allocator, epoch: []const u8, seq: i64) u.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ epoch, seq });
}
pub fn parseCursor(s: []const u8, epoch: []const u8) ParseCursorError!i64 {
    if (s.len < id_length + 2 or s[id_length] != ':' or
        !validId(s[0..id_length]) or !u.eq(s[0..id_length], epoch)) return error.ResyncRequired;
    const seq = std.fmt.parseInt(i64, s[id_length + 1 ..], 10) catch return error.InvalidRequest;
    if (seq < 0) return error.InvalidRequest;
    return seq;
}
test "send input validation never guesses a service or address" {
    try std.testing.expect(validAddress("+14155550123"));
    try std.testing.expect(validAddress("test@example.invalid"));
    try std.testing.expect(!validAddress("4155550123"));
    try std.testing.expect(!validAddress("Alice"));
    try std.testing.expect(!validAddress("+00012345678"));
}

test "attachment-only sends validate without weakening text or target validation" {
    const file: attachments.Upload = .{
        .id = "ABEiM0RVZneImaq7zN3u_w",
        .name = "photo.png",
        .mime_type = "image/png",
        .bytes = "4",
        .sha256 = "0123456789abcdef" ** 4,
    };
    var input: SendInput = .{
        .request_id = "aBEiM0RVZneImaq7zN3u_w",
        .server_epoch = "bBEiM0RVZneImaq7zN3u_w",
        .target = .{ .recipient = .{ .address = "test@example.invalid", .service = "imessage" } },
        .text = "",
    };
    try std.testing.expectError(error.InvalidRequest, validate(input));
    input.attachments = &.{file};
    try validate(input);
    input.text = "caption";
    try validate(input);
    input.text = "bad\x00caption";
    try std.testing.expectError(error.InvalidRequest, validate(input));
    input.text = "x" ** (max_text + 1);
    try std.testing.expectError(error.TextTooLarge, validate(input));
    input.text = "";
    input.target.recipient.?.service = "sms";
    try std.testing.expectError(error.UnsupportedTarget, validate(input));
    input.target.recipient = null;
    try std.testing.expectError(error.InvalidRequest, validate(input));
}

test "text sends retain legacy serialization and attachments survive round trips" {
    const a = std.testing.allocator;
    const legacy = "{\"request_id\":\"aBEiM0RVZneImaq7zN3u_w\",\"server_epoch\":\"bBEiM0RVZneImaq7zN3u_w\"," ++
        "\"target\":{\"conversation_id\":null,\"recipient\":{\"address\":\"test@example.invalid\",\"service\":\"imessage\"}},\"text\":\"caption\"}";
    const parsed = try std.json.parseFromSlice(SendInput, a, legacy, .{});
    defer parsed.deinit();
    const encoded = try u.json(a, parsed.value);
    defer a.free(encoded);
    try std.testing.expectEqualStrings(legacy, encoded);
    var input = parsed.value;
    input.attachments = &.{.{
        .id = "ABEiM0RVZneImaq7zN3u_w",
        .name = "photo.png",
        .mime_type = "image/png",
        .bytes = "4",
        .sha256 = "0123456789abcdef" ** 4,
    }};
    const with_file = try u.json(a, input);
    defer a.free(with_file);
    const decoded = try std.json.parseFromSlice(SendInput, a, with_file, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.value.attachments.len);
    try std.testing.expectEqualStrings("photo.png", decoded.value.attachments[0].name);
    try std.testing.expectEqualStrings(input.attachments[0].sha256, decoded.value.attachments[0].sha256);
    try validate(decoded.value);
}
test "cursor binds sequence to epoch without floating point" {
    const e = "EjRWeBI0EjQSNBI0VniQEg";
    try std.testing.expectEqual(
        @as(i64, 9007199254740993),
        try parseCursor(e ++ ":9007199254740993", e),
    );
    try std.testing.expectError(error.ResyncRequired, parseCursor(e ++ ":1", "other"));
    try std.testing.expectError(error.ResyncRequired, parseCursor(e ++ ":1", "ejRWeBI0EjQSNBI0VniQEg"));
    try std.testing.expectError(error.InvalidRequest, parseCursor(e ++ ":-1", e));
}

test "public IDs require canonical unpadded Base64url" {
    try std.testing.expect(validId("ABEiM0RVZneImaq7zN3u_w"));
    try std.testing.expect(validId("aBEiM0RVZneImaq7zN3u_w"));
    try std.testing.expect(validId("---------------------w"));
    for ([_][]const u8{
        "00112233-4455-6677-8899-aabbccddeeff",
        "ABEiM0RVZneImaq7zN3u_w==",
        "ABEiM0RVZneImaq7zN3u_w=",
        "ABEiM0RVZneImaq7zN3u_wA",
        "ABEiM0RVZneImaq7zN3u_",
        "ABEiM0RVZneImaq7zN3u_x",
        "ABEiM0RVZneImaq7zN3u/w",
        "ABEiM0RVZneImaq7zN3u+w",
        "ABEiM0RVZneImaq7zN3u w",
    }) |invalid| try std.testing.expect(!validId(invalid));
}
