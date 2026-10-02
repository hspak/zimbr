//! Offline Unicode emoji shortcodes. The sorted catalog and its provenance are in
//! emoji/catalog.tsv and licenses/gemoji.txt; tools/generate_emoji.py regenerates it.

const std = @import("std");
const Editor = @import("Editor.zig");
const t = @import("../protocol.zig").types;
pub const Completion = @import("emoji/Completion.zig");

pub const Entry = struct { name: []const u8, text: []const u8 };

const catalog = @embedFile("emoji/catalog.tsv");
const entries = parseCatalog();

fn catalogCount() usize {
    @setEvalBranchQuota(100_000);
    var count: usize = 0;
    for (catalog) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn parseCatalog() [catalogCount()]Entry {
    @setEvalBranchQuota(500_000);
    var result: [catalogCount()]Entry = undefined;
    var lines = std.mem.tokenizeScalar(u8, catalog, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        result[index] = .{ .name = line[0..tab], .text = line[tab + 1 ..] };
    }
    return result;
}

fn lowerBound(name: []const u8) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.mem.order(u8, entries[mid].name, name) == .lt) low = mid + 1 else high = mid;
    }
    return low;
}

/// Borrow the Unicode sequence for an exact, case-sensitive shortcode, without colons.
pub fn lookup(name: []const u8) ?[]const u8 {
    const index = lowerBound(name);
    if (index == entries.len or !std.mem.eql(u8, entries[index].name, name)) return null;
    return entries[index].text;
}

/// Borrow the alphabetically ordered catalog entries beginning with prefix.
pub fn matches(prefix: []const u8) []const Entry {
    if (prefix.len == 0) return &.{};
    const start = lowerBound(prefix);
    var end = start;
    while (end < entries.len and std.mem.startsWith(u8, entries[end].name, prefix)) : (end += 1) {}
    return entries[start..end];
}

fn nameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '+';
}

fn opening(text: []const u8, at: usize) bool {
    if (at == 0) return true;
    const previous = text[at - 1];
    return std.ascii.isWhitespace(previous) or previous >= 0x80 or
        std.mem.indexOfScalar(u8, "([{'\"", previous) != null;
}

/// Find an unfinished shortcode at a collapsed caret. The returned range also
/// includes any remaining name and closing colon after the caret.
/// Assume caret is a UTF-8 boundary within text, including its end.
pub fn query(text: []const u8, caret: usize) ?Editor.Range {
    var start = caret;
    while (start > 0 and nameByte(text[start - 1])) : (start -= 1) {}
    if (start == caret or start == 0 or text[start - 1] != ':') return null;
    start -= 1;
    if (!opening(text, start)) return null;
    var end = caret;
    while (end < text.len and nameByte(text[end])) : (end += 1) {}
    if (end < text.len and text[end] == ':') end += 1;
    return .{ .start = start, .end = end };
}

fn append(buffer: []u8, used: *usize, text: []const u8) error{TextTooLarge}!void {
    if (text.len > buffer.len - used.*) return error.TextTooLarge;
    @memcpy(buffer[used.*..][0..text.len], text);
    used.* += text.len;
}

/// Expand completed shortcodes touched by the latest insertion, from its original
/// start through the current caret. Replacement is a separate undo step, allowing
/// the user to restore literal shortcodes. On error the inserted text is preserved.
/// Assume inserted_start is a UTF-8 boundary no later than the caret.
pub fn expand(editor: *Editor, inserted_start: usize) Editor.InsertError!void {
    const text = editor.text.items;
    const end = editor.caret;
    if (std.mem.indexOfScalar(u8, text[inserted_start..end], ':') == null) return;
    var start = inserted_start;
    while (start > 0 and nameByte(text[start - 1])) : (start -= 1) {}
    if (start > 0 and text[start - 1] == ':') start -= 1;
    var buffer: [t.max_text]u8 = undefined;
    var used: usize = 0;
    var at = start;
    var copied = start;
    var converted_end: ?usize = null;
    while (at < end) {
        if (text[at] != ':' or !(opening(text, at) or converted_end == at)) {
            at += 1;
            continue;
        }
        var close = at + 1;
        while (close < end and nameByte(text[close])) : (close += 1) {}
        if (close == end or text[close] != ':' or close < inserted_start) {
            at += 1;
            continue;
        }
        const replacement = lookup(text[at + 1 .. close]) orelse {
            at = close + 1;
            continue;
        };
        try append(&buffer, &used, text[copied..at]);
        try append(&buffer, &used, replacement);
        at = close + 1;
        copied = at;
        converted_end = at;
    }
    if (converted_end == null) return;
    try append(&buffer, &used, text[copied..end]);
    try editor.replace(.{ .start = start, .end = end }, buffer[0..used]);
}

test "emoji catalog has sorted unique names and Unicode sequences" {
    for (entries, 0..) |entry, index| {
        try std.testing.expect(entry.name.len > 0);
        for (entry.name) |byte| try std.testing.expect(nameByte(byte));
        try std.testing.expect(std.unicode.utf8ValidateSlice(entry.text));
        try std.testing.expect(try std.unicode.utf8CountCodepoints(entry.text) < entry.text.len);
        if (index > 0) try std.testing.expect(std.mem.order(u8, entries[index - 1].name, entry.name) == .lt);
    }
    try std.testing.expectEqualStrings("👩‍💻", lookup("woman_technologist").?);
    try std.testing.expectEqualStrings("👍", lookup("+1").?);
    try std.testing.expect(lookup("custom_emoji") == null);
    try std.testing.expectEqualStrings("smile", matches("smil")[0].name);
    try std.testing.expectEqualStrings("smiling_imp", matches("smil")[matches("smil").len - 1].name);
}

test "emoji expansion preserves surrounding text and undoes to literal shortcodes" {
    var editor: Editor = .{};
    defer editor.deinit();
    try editor.set("前 :s after");
    editor.caret = "前 :s".len;
    editor.anchor = editor.caret;
    const start = editor.caret;
    try editor.insert("mile::wave: :woman_technologist: :unknown: https://host/:smile:");
    try expand(&editor, start);
    try std.testing.expectEqualStrings("前 😄👋 👩‍💻 :unknown: https://host/:smile: after", editor.text.items);
    try std.testing.expectEqual(editor.text.items.len - " after".len, editor.caret);
    try editor.history(false);
    try std.testing.expectEqualStrings("前 :smile::wave: :woman_technologist: :unknown: https://host/:smile: after", editor.text.items);
    try editor.history(true);
    try std.testing.expectEqualStrings("前 😄👋 👩‍💻 :unknown: https://host/:smile: after", editor.text.items);
}

test "emoji queries require a name at a token boundary and include the suffix" {
    for ([_][]const u8{
        ":",
        "12:30",
        "https:",
        "https://host/:sm",
        "word:sm",
        ":no spaces",
    }) |text| try std.testing.expect(query(text, text.len) == null);
    const range = query("hello (:smile:) world", "hello (:sm".len).?;
    try std.testing.expectEqualStrings(":smile:", "hello (:smile:) world"[range.start..range.end]);
}

test "emoji expansion failure preserves literal text and caret" {
    var editor: Editor = .{};
    defer editor.deinit();
    try editor.insert(":smile:");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    editor.allocator = failing.allocator();
    defer editor.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, expand(&editor, 0));
    try std.testing.expectEqualStrings(":smile:", editor.text.items);
    try std.testing.expectEqual(@as(usize, 7), editor.caret);
    try std.testing.expectEqual(@as(usize, 1), editor.undo.items.len);
}

test "emoji expansion preserves a full draft when a sequence would exceed its byte budget" {
    var editor: Editor = .{};
    defer editor.deinit();
    try editor.set("x" ** (t.max_text - 4) ++ " :v:");
    const revision = editor.revision;
    try std.testing.expectError(error.TextTooLarge, expand(&editor, t.max_text - 1));
    try std.testing.expectEqualStrings("x" ** (t.max_text - 4) ++ " :v:", editor.text.items);
    try std.testing.expectEqual(revision, editor.revision);
    try std.testing.expectEqual(@as(usize, t.max_text), editor.caret);
}

test {
    _ = Completion;
}
