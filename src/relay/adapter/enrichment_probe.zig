//! Bounded, aggregate-only source-format diagnostics. No source values leave
//! this probe: key/class labels below are fixed, public format vocabulary.
const std = @import("std");
const u = @import("../../common.zig");
const Source = @import("MessagesDb.zig");
const plist = @import("plist.zig");
const links = @import("link_preview.zig");
const Count = struct { label: []const u8, count: usize = 0 };
const keys = [_][]const u8{ "$archiver", "$objects", "$top", "root", "richLinkMetadata", "metadata", "URL", "originalURL", "title", "summary", "siteName", "image", "icon", "images", "icons", "imageMetadata", "iconMetadata", "richLinkIsPlaceholder", "data", "attachmentGUID", "NS.keys", "NS.objects", "NS.relative", "NS.base", "NS.data", "NS.string" };
const classes = [_][]const u8{ "NSDictionary", "NSMutableDictionary", "NSArray", "NSMutableArray", "NSString", "NSMutableString", "NSURL", "NSData", "NSMutableData", "LPLinkMetadata", "LPImage", "LPImageMetadata", "LPIconMetadata", "RichLink", "LPSharingMetadataWrapper", "RichLinkImageAttachmentSubstitute" };
const states = [_][]const u8{ "pending", "complete", "unavailable", "unsupported", "malformed", "oversized" };
pub const Report = struct {
    sample_limit: usize = 100,
    url_samples: usize = 0,
    binary_plists: usize = 0,
    xml_plists: usize = 0,
    other_payloads: usize = 0,
    empty_payloads: usize = 0,
    preview_count: usize = 0,
    local_artwork_count: usize = 0,
    indexed_artwork_count: usize = 0,
    matched_indexed_artwork_count: usize = 0,
    unknown_archive_classes: usize = 0,
    decode_states: []Count,
    known_keys: []Count,
    known_classes: []Count,
    reaction_samples: usize = 0,
    reaction_types: []Count,
    target_part_prefix: usize = 0,
    target_bubble_prefix: usize = 0,
    target_other: usize = 0,
    custom_emoji_present: usize = 0,
};
fn counts(a: u.Allocator, labels: []const []const u8) ![]Count {
    const out = try a.alloc(Count, labels.len);
    for (out, labels) |*item, label| item.* = .{ .label = label };
    return out;
}
fn bump(items: []Count, label: []const u8) bool {
    for (items) |*item| if (u.eq(item.label, label)) {
        item.count += 1;
        return true;
    };
    return false;
}
fn shape(report: *Report, value: plist.Value, depth: usize) void {
    if (depth > plist.max_depth) return;
    switch (value) {
        .dict => |entries| for (entries) |entry| {
            _ = bump(report.known_keys, entry.key);
            if (u.eq(entry.key, "$classname")) {
                if (entry.value.text()) |name| if (!bump(report.known_classes, name)) {
                    report.unknown_archive_classes += 1;
                };
            } else shape(report, entry.value, depth + 1);
        },
        .array => |items| for (items) |item| shape(report, item, depth + 1),
        .string => |text| {
            // NS.keys stores dictionary field labels as string objects.
            _ = bump(report.known_keys, text);
        },
        else => {},
    }
}
pub fn run(a: u.Allocator, source: Source) !Report {
    var report = Report{
        .decode_states = try counts(a, &states),
        .known_keys = try counts(a, &keys),
        .known_classes = try counts(a, &classes),
        .reaction_types = try counts(a, &.{ "1000", "2000", "2001", "2002", "2003", "2004", "2005", "2006", "2007", "3000", "3001", "3002", "3003", "3004", "3005", "3006", "3007", "other" }),
    };
    if (source.features.link_payload) {
        var q = try source.db.prepare("SELECT CASE WHEN length(payload_data)<=1048576 THEN payload_data END,length(payload_data),ROWID FROM message WHERE balloon_bundle_id='com.apple.messages.URLBalloonProvider' ORDER BY ROWID DESC LIMIT 100");
        defer q.close();
        while (try q.step()) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const scratch = arena.allocator();
            report.url_samples += 1;
            if (q.int(1) > 1048576) {
                _ = bump(report.decode_states, "oversized");
                continue;
            }
            const bytes = q.bytes(0);
            if (bytes.len == 0) report.empty_payloads += 1 else if (std.mem.startsWith(u8, bytes, "bplist")) report.binary_plists += 1 else if (std.mem.startsWith(u8, std.mem.trimStart(u8, bytes, " \r\n\t"), "<")) report.xml_plists += 1 else report.other_payloads += 1;
            const decoded = try links.decode(scratch, bytes);
            _ = bump(report.decode_states, @tagName(decoded.state));
            report.preview_count += decoded.previews.len;
            for (decoded.artwork) |artwork| {
                if (artwork.attachment_index != null) report.indexed_artwork_count += 1 else report.local_artwork_count += 1;
            }
            if (decoded.artwork.len > 0) if (try source.message(scratch, q.int(2))) |message| {
                for (message.link_artwork) |artwork| if (artwork.attachment_index != null and artwork.attachment_guid != null) {
                    report.matched_indexed_artwork_count += 1;
                };
            };
            if (plist.parse(scratch, bytes)) |value| shape(&report, value, 0) else |_| {}
        }
    }
    if (source.features.reaction_target) {
        const sql = try std.fmt.allocPrintSentinel(a, "SELECT associated_message_type,associated_message_guid,{s} FROM message WHERE associated_message_type BETWEEN 1000 AND 3999 ORDER BY ROWID DESC LIMIT 100", .{if (source.features.reaction_emoji) "associated_message_emoji" else "NULL"}, 0);
        var q = try source.db.prepare(sql);
        defer q.close();
        while (try q.step()) {
            report.reaction_samples += 1;
            var buffer: [32]u8 = undefined;
            if (!bump(report.reaction_types, try std.fmt.bufPrint(&buffer, "{d}", .{q.int(0)}))) _ = bump(report.reaction_types, "other");
            const target = q.bytes(1);
            if (std.mem.startsWith(u8, target, "p:")) report.target_part_prefix += 1 else if (std.mem.startsWith(u8, target, "bp:")) report.target_bubble_prefix += 1 else report.target_other += 1;
            if (q.bytes(2).len > 0) report.custom_emoji_present += 1;
        }
    }
    return report;
}
