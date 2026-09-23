const std = @import("std");
const Store = @import("client/Store.zig");
const Editor = @import("client/Editor.zig");
const Sse = @import("client/Sse.zig");
comptime {
    _ = @import("client/display.zig");
    _ = @import("client/MessageSelection.zig");
}
const u = @import("common.zig");
const epoch = "12345678-1234-1234-1234-123456789012";
const message = "{\"id\":\"m1\",\"revision\":\"2\",\"conversation_id\":\"c1\",\"sender\":\"test@example.invalid\",\"direction\":\"incoming\",\"service\":\"imessage\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"kind\":\"text\",\"text\":\"Hello 👋\",\"decoding\":\"plain\",\"observed_status\":\"received\"}";
test "events commit records and cursor together, deduplicate replay and ignore stale snapshots" {
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":1");
    const ev = "{\"cursor\":\"" ++ epoch ++ ":2\",\"sequence\":\"2\",\"type\":\"message.upsert\",\"origin\":\"live\",\"record\":" ++ message ++ "}";
    try s.event(a, ev, epoch ++ ":2", "message.upsert", "");
    try s.event(a, ev, epoch ++ ":2", "message.upsert", "");
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM records"));
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count FROM unread"));
    try std.testing.expectEqualStrings(epoch ++ ":2", try s.get(a, "cursor"));
    try s.db.exec("CREATE TRIGGER reject_cursor BEFORE UPDATE ON meta WHEN NEW.key='cursor' BEGIN SELECT RAISE(ABORT,'failure'); END");
    const next = try std.mem.replaceOwned(u8, a, ev, ":2\"", ":3\"");
    const next2 = try std.mem.replaceOwned(u8, a, next, "\"sequence\":\"2\"", "\"sequence\":\"3\"");
    try std.testing.expectError(error.DatabaseFailure, s.event(a, next2, epoch ++ ":3", "message.upsert", ""));
    try std.testing.expectEqualStrings(epoch ++ ":2", try s.get(a, "cursor"));
}
test "historical imports do not create unread markers; epoch reset preserves drafts and holds old sends" {
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":1");
    try s.saveDraft("c1", "Draft 👩‍💻\nCafé");
    const ev = "{\"cursor\":\"" ++ epoch ++ ":2\",\"sequence\":\"2\",\"type\":\"message.upsert\",\"origin\":\"historical_import\",\"record\":" ++ message ++ "}";
    try s.event(a, ev, epoch ++ ":2", "message.upsert", "");
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
    try s.persistSend(a, "new:test", .{ .request_id = epoch, .server_epoch = epoch, .target = .{ .recipient = .{ .address = "test@example.invalid", .service = "imessage" } }, .text = "Hello" });
    const changed = "22345678-1234-1234-1234-123456789012";
    try s.beginSync(changed, changed ++ ":0");
    try std.testing.expectEqualStrings("Draft 👩‍💻\nCafé", try s.draft(a, "c1"));
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='unknown'"));
}

test "sidebar projections never replace full messages or roll back newer previews" {
    const t = @import("protocol/types.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    _ = try s.upsert(ar, "conversation", "{\"id\":\"c1\",\"service\":\"imessage\"}");
    var preview = t.ConversationPreview{ .conversation_id = "c1", .message_id = "m1", .revision = "2", .timestamp = "2026-01-01T00:00:00Z", .kind = "text", .text = "Truncated preview" };
    try s.savePreview(ar, try u.json(ar, preview));
    const projected = try s.snapshot(ar, "c1");
    try std.testing.expectEqualStrings("Truncated preview", projected.chats[0].preview);
    try std.testing.expectEqual(@as(usize, 0), projected.messages.len);
    _ = try s.upsert(ar, "message", message);
    const full = try s.snapshot(ar, "c1");
    try std.testing.expectEqualStrings("Hello 👋", full.messages[0].text.?);
    try std.testing.expectEqualStrings("Hello 👋", full.chats[0].preview);
    preview.revision = "3";
    preview.text = "Newer text";
    try s.savePreview(ar, try u.json(ar, preview));
    preview.revision = "1";
    preview.text = "Stale text";
    try s.savePreview(ar, try u.json(ar, preview));
    const updated = try s.snapshot(ar, "c1");
    try std.testing.expectEqualStrings("Newer text", updated.chats[0].preview);
    try std.testing.expectEqualStrings("Hello 👋", updated.messages[0].text.?);
}
test "composer deletes graphemes and restores Unicode selection with undo and redo" {
    var e = Editor{};
    defer e.deinit();
    try e.set("Café 👩‍💻🇺🇸");
    try e.delete(true);
    try std.testing.expectEqualStrings("Café 👩‍💻", e.text.items);
    try e.delete(true);
    try std.testing.expectEqualStrings("Café ", e.text.items);
    try e.history(false);
    try std.testing.expectEqualStrings("Café 👩‍💻", e.text.items);
    try e.history(true);
    try std.testing.expectEqualStrings("Café ", e.text.items);
    try e.delete(true);
    try e.delete(true);
    try std.testing.expectEqualStrings("Caf", e.text.items);
    e.anchor = 0;
    try e.insert("你好\n🙂");
    try std.testing.expectEqualStrings("你好\n🙂", e.text.items);
    const large = try std.testing.allocator.alloc(u8, 16385);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    try std.testing.expectError(error.TextTooLarge, e.insert(large));
}
const Frames = struct {
    count: usize = 0,
    fn accept(s: *@This(), _: u.Allocator, data: []const u8, id: []const u8, event: []const u8) !void {
        try std.testing.expectEqualStrings("one\ntwo", data);
        try std.testing.expectEqualStrings("42", id);
        try std.testing.expectEqualStrings("update", event);
        s.count += 1;
    }
};
test "SSE accepts fragmented multiline frames and ignores heartbeats and truncated tails" {
    var parser = Sse{};
    defer parser.deinit();
    var frames = Frames{};
    const wire = ": heartbeat\r\n\r\nid: 42\r\nevent: update\r\ndata: one\r\ndata: two\r\n\r\nid: truncated\ndata: no";
    for (wire) |byte| try parser.feed(&.{byte}, &frames, Frames.accept);
    try std.testing.expectEqual(@as(usize, 1), frames.count);
}
test {
    _ = @import("client/Worker.zig");
}

test "live replay after a snapshot still records unread exactly once" {
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":1");
    _ = try s.upsert(a, "message", message);
    const ev = "{\"cursor\":\"" ++ epoch ++ ":2\",\"sequence\":\"2\",\"type\":\"message.upsert\",\"origin\":\"live\",\"record\":" ++ message ++ "}";
    try s.event(a, ev, epoch ++ ":2", "message.upsert", "");
    try s.event(a, ev, epoch ++ ":2", "message.upsert", "");
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count FROM unread"));
}
test "an unchanged authoritative request resolves local uncertainty without another POST" {
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":1");
    const input = @import("protocol/types.zig").SendInput{ .request_id = epoch, .server_epoch = epoch, .target = .{ .recipient = .{ .address = "test@example.invalid", .service = "imessage" } }, .text = "hello" };
    try s.persistSend(a, "new:test", input);
    const raw = try u.json(a, @import("protocol/types.zig").SendRequest{ .request_id = epoch, .server_epoch = epoch, .target = input.target, .text = input.text, .revision = "2", .state = .delivered });
    _ = try s.upsert(a, "request", raw);
    try s.outcome(epoch, "unknown", "Lost HTTP response");
    _ = try s.upsert(a, "request", raw);
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='delivered'"));
}
test "failed cursor commit rolls back a new message and unread marker" {
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":1");
    try s.db.exec("CREATE TRIGGER reject_cursor BEFORE UPDATE ON meta WHEN NEW.key='cursor' BEGIN SELECT RAISE(ABORT,'failure'); END");
    const ev = "{\"cursor\":\"" ++ epoch ++ ":2\",\"sequence\":\"2\",\"type\":\"message.upsert\",\"origin\":\"live\",\"record\":" ++ message ++ "}";
    try std.testing.expectError(error.DatabaseFailure, s.event(a, ev, epoch ++ ":2", "message.upsert", ""));
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM records"));
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
    try std.testing.expectEqualStrings(epoch ++ ":1", try s.get(a, "cursor"));
}
test "indexed history keeps linked echoes ordered and deduplicated across conversations" {
    const t = @import("protocol/types.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":0");
    const base = (try std.json.parseFromSlice(t.Message, ar, message, .{})).value;
    // m0 is an echo in the eventual direct conversation. m1 is both local
    // history and a linked echo; it must appear once. m2 shares its timestamp.
    for ([_][]const u8{ "m2", "m1", "m0", "unrelated" }) |id| {
        var m = base;
        m.id = id;
        m.conversation_id = if (u.eq(id, "m1") or u.eq(id, "m2")) "c1" else "c2";
        if (u.eq(id, "m0")) m.timestamp = "2025-12-31T23:59:59Z";
        _ = try s.upsert(ar, "message", try u.json(ar, m));
    }
    for ([_][]const u8{ epoch, "22345678-1234-1234-1234-123456789012", "32345678-1234-1234-1234-123456789012" }, [_][]const u8{ "m0", "m1", "m0" }) |id, echo| {
        const input = t.SendInput{ .request_id = id, .server_epoch = epoch, .target = .{ .recipient = .{ .address = "test@example.invalid", .service = "imessage" } }, .text = "Fixture" };
        try s.persistSend(ar, "c1", input);
        _ = try s.upsert(ar, "request", try u.json(ar, t.SendRequest{ .request_id = id, .server_epoch = epoch, .target = input.target, .text = input.text, .state = .delivered, .message_id = echo }));
    }
    const snapshot = try s.snapshot(ar, "c1");
    try std.testing.expectEqual(@as(usize, 3), snapshot.messages.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
    for (snapshot.messages, [_][]const u8{ "m0", "m1", "m2" }) |m, id| try std.testing.expectEqualStrings(id, m.id);
    const SharedSnapshot = @import("client/SharedSnapshot.zig");
    const shared = try SharedSnapshot.create(s, "c1", 1, null);
    defer shared.release();
    try std.testing.expectEqual(@as(usize, 0), shared.snapshot.pending.len);
    for (shared.snapshot.messages, snapshot.messages) |actual, expected| try std.testing.expectEqualStrings(expected.id, actual.id);
}

test "incremental snapshots preserve versions through prepends, reordering, failure and epoch replacement" {
    const t = @import("protocol/types.zig");
    const SharedSnapshot = @import("client/SharedSnapshot.zig");
    const store = try Store.open(":memory:");
    defer store.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try store.beginSync(epoch, epoch ++ ":0");
    var m = (try std.json.parseFromSlice(t.Message, ar, message, .{})).value;
    _ = try store.upsert(ar, "message", try u.json(ar, m));
    m.id = "m2";
    m.text = "Second";
    _ = try store.upsert(ar, "message", try u.json(ar, m));
    const first = try SharedSnapshot.create(store, "c1", 1, null);
    defer first.release();
    const unchanged = try SharedSnapshot.create(store, "c1", 2, first);
    defer unchanged.release();
    try std.testing.expectEqual(first.history, unchanged.history);
    // A prepended page and same-count edit reuse unchanged records only.
    m.id = "older";
    m.timestamp = "2025-01-01T00:00:00Z";
    _ = try store.upsert(ar, "message", try u.json(ar, m));
    m.id = "m2";
    m.revision = "3";
    m.text = "Edited 👩‍💻";
    m.timestamp = "2026-01-02T00:00:00Z";
    _ = try store.upsert(ar, "message", try u.json(ar, m));
    const edited = try SharedSnapshot.create(store, "c1", 3, unchanged);
    defer edited.release();
    try std.testing.expectEqual(@as(usize, 3), edited.snapshot.messages.len);
    try std.testing.expectEqualStrings("older", edited.snapshot.messages[0].id);
    try std.testing.expectEqual(first.snapshot.messages[0].text.?.ptr, edited.snapshot.messages[1].text.?.ptr);
    try std.testing.expectEqualStrings("Edited 👩‍💻", edited.snapshot.messages[2].text.?);
    try std.testing.expectEqualStrings("Second", first.snapshot.messages[1].text.?);
    // Moving an existing record earlier must change ordering without stale text.
    m.timestamp = "2024-01-01T00:00:00Z";
    m.revision = "4";
    _ = try store.upsert(ar, "message", try u.json(ar, m));
    const reordered = try SharedSnapshot.create(store, "c1", 4, edited);
    defer reordered.release();
    try std.testing.expectEqualStrings("m2", reordered.snapshot.messages[0].id);
    try std.testing.expectEqualStrings("m1", reordered.snapshot.messages[2].id);
    // Fail after acquiring both a new record and shared records. The testing
    // allocator checks that error cleanup releases every ownership reference.
    m.revision = "5";
    _ = try store.upsert(ar, "message", try u.json(ar, m));
    try store.db.exec("UPDATE records SET revision=99,record='invalid' WHERE id='m1'");
    try std.testing.expectError(error.SyntaxError, SharedSnapshot.create(store, "c1", 5, reordered));
    try std.testing.expectEqualStrings("Hello 👋", reordered.snapshot.messages[2].text.?);
    // Identical IDs/revisions in a new epoch never reuse old message content.
    const next_epoch = "22345678-1234-1234-1234-123456789012";
    try store.beginSync(next_epoch, next_epoch ++ ":0");
    m.id = "m1";
    m.revision = "2";
    m.text = "New epoch";
    _ = try store.upsert(ar, "message", try u.json(ar, m));
    const reset = try SharedSnapshot.create(store, "c1", 6, reordered);
    defer reset.release();
    try std.testing.expectEqualStrings("New epoch", reset.snapshot.messages[0].text.?);
    try std.testing.expectEqualStrings("Hello 👋", first.snapshot.messages[0].text.?);
    const selected = try SharedSnapshot.create(store, "other", 7, reset);
    defer selected.release();
    try std.testing.expectEqual(@as(usize, 0), selected.snapshot.messages.len);
}

test "long Unicode text measures, wraps, and renders a bounded tile" {
    const c = @import("client/c.zig").api;
    const text = try std.testing.allocator.alloc(u8, 16384);
    defer std.testing.allocator.free(text);
    @memset(text, 'W');
    const layout = c.zc_text_new(text.ptr, @intCast(text.len), 16, 300, 2) orelse return error.NoLayout;
    defer c.zc_text_free(layout);
    try std.testing.expect(c.zc_text_height(layout) > 10000);
    try std.testing.expect(c.zc_text_pixels(layout, 0x112233ff, 0, 20, 300, 512) != null);
    var x: c_int = 0;
    var y: c_int = 0;
    var h: c_int = 0;
    c.zc_text_caret(layout, 100, &x, &y, &h);
    try std.testing.expect(y > 0 and h > 0);
    const hit = c.zc_text_hit(layout, x, y + @divTrunc(h, 2));
    try std.testing.expect(hit >= 99 and hit <= 101);
}

test "unbroken messages and URLs have bounded raster dimensions" {
    const c = @import("client/c.zig").api;
    const text = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(text);
    @memset(text, 'W');
    @memcpy(text[0..24], "https://example.invalid/");
    const layout = c.zc_text_new(text.ptr, @intCast(text.len), 16, 160, 1.5) orelse return error.NoLayout;
    defer c.zc_text_free(layout);
    try std.testing.expect(c.zc_text_width(layout) <= 243);
    try std.testing.expect(c.zc_text_height(layout) > 2048);
    try std.testing.expect(c.zc_text_pixels(layout, 0x112233ff, 0, 0, 256, 512) != null);
    c.zc_text_clear_pixels(layout);
    try std.testing.expect(c.zc_text_pixels(layout, 0x112233ff, 0, 0, -1, 512) == null);
    try std.testing.expect(c.zc_text_pixels(layout, 0x112233ff, 0, 0, 0, 1000000) == null);
    try std.testing.expect(c.zc_text_pixels(layout, 0x112233ff, 0, 0, c.zc_text_height(layout), 1) == null);
}

test "unsafe text and invalid geometry fail before shaping or allocation" {
    const c = @import("client/c.zig").api;
    for ([_][]const u8{ "bad\xff", "nul\x00text", "a" ++ "́" ** 1000, "\u{202e}" ** 1000, "\n" ** 65536 }) |text| {
        try std.testing.expect(c.zc_text_new(text.ptr, @intCast(text.len), 16, 300, 1) == null);
    }
    try std.testing.expect(c.zc_text_new("a", -1, 16, 300, 1) == null);
    try std.testing.expect(c.zc_text_new("a", 1, 16, std.math.maxInt(c_int), 1) == null);
    try std.testing.expect(c.zc_text_new("a", 1, 16, 300, std.math.nan(f64)) == null);
    try std.testing.expect(c.zc_text_new("a", 1, 16, 300, 0) == null);
}

test "fractional scale tiles match full text rendering including selection and bidi" {
    const c = @import("client/c.zig").api;
    const text = "Café é 👩‍💻 שלום مرحبا\n" ** 12;
    for ([_]f64{ 1, 1.25, 1.5, 2 }) |scale| {
        const layout = c.zc_text_new(text.ptr, text.len, 16, 300, scale) orelse return error.NoLayout;
        defer c.zc_text_free(layout);
        const width: usize = @intCast(c.zc_text_width(layout));
        const height = c.zc_text_height(layout);
        const ptr = c.zc_text_pixels(layout, 0x112233ff, 0, 80, 0, height);
        try std.testing.expect(ptr != null);
        const full = try std.testing.allocator.dupe(u8, ptr[0 .. width * @as(usize, @intCast(height)) * 4]);
        defer std.testing.allocator.free(full);
        // It must contain glyphs rather than an empty successful surface.
        var ink = false;
        var i: usize = 3;
        while (i < full.len) : (i += 4) ink = ink or full[i] != 0;
        try std.testing.expect(ink);
        const tile = c.zc_text_pixels(layout, 0x112233ff, 0, 80, 128, 128);
        try std.testing.expect(tile != null);
        try std.testing.expectEqualSlices(u8, full[width * 128 * 4 ..][0 .. width * 128 * 4], tile[0 .. width * 128 * 4]);
    }
}
