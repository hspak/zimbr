const std = @import("std");
const Store = @import("client/Store.zig");
const Editor = @import("client/Editor.zig");
const Sse = @import("client/Sse.zig");
comptime {
    _ = @import("client/Config.zig");
    _ = @import("client/Content.zig");
    _ = @import("client/Media.zig");
    _ = @import("client/Links.zig");
    _ = @import("client/IdentityDirectory.zig");
    _ = @import("client/Worker.zig");
    _ = @import("client/display.zig");
    _ = @import("client/MessageSelection.zig");
}
const u = @import("common.zig");
const epoch = "12345678-1234-1234-1234-123456789012";
const message = "{\"id\":\"m1\",\"revision\":\"2\",\"conversation_id\":\"c1\",\"sender\":\"test@example.invalid\",\"direction\":\"incoming\",\"service\":\"imessage\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"kind\":\"text\",\"text\":\"Hello 👋\",\"decoding\":\"plain\",\"observed_status\":\"received\"}";
test "hostile messages cannot change records or advance the event cursor" {
    const t = @import("protocol/types.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":0");
    const deep = "{\"unknown\":" ++ "[" ** 32 ++ "0" ++ "]" ** 32 ++ "}";
    try std.testing.expectError(error.JsonTooDeep, s.upsert(a, "message", deep));
    var m = try std.json.parseFromSliceLeaky(t.Message, a, message, .{});
    for ([_][]const u8{ "hidden\x00suffix", "x" ** (t.max_body + 1) }) |text| {
        m.text = text;
        const event = try u.json(a, .{ .cursor = epoch ++ ":1", .sequence = "1", .type = "message.upsert", .origin = "live", .record = m });
        try std.testing.expectError(error.InvalidRecord, s.event(a, event, epoch ++ ":1", "message.upsert", ""));
    }
    try std.testing.expectEqualStrings(epoch ++ ":0", try s.get(a, "cursor"));
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM records"));
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
    m.text = "Valid 👩‍💻\nMultiline";
    const good = try u.json(a, .{ .cursor = epoch ++ ":1", .sequence = "1", .type = "message.upsert", .origin = "live", .record = m });
    try s.event(a, good, epoch ++ ":1", "message.upsert", "");
    try std.testing.expectEqualStrings(epoch ++ ":1", try s.get(a, "cursor"));
}

test "enrichment rejects unbounded and changing totals without committing pages" {
    const t = @import("protocol/types.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try std.json.parseFromSliceLeaky(t.Message, a, message, .{});
    m.enrichment = .{ .state = .complete, .attachments = .{ .total = 2, .complete = false } };
    _ = try s.upsert(a, "message", try u.json(a, m));
    const item = t.Attachment{ .id = "a", .name = "photo", .mime_type = "image/png", .bytes = "10" };
    for ([_]usize{ 1, 3, 4097 }) |total| {
        const page = try u.json(a, .{ .message_id = m.id, .revision = m.revision, .section = "attachments", .items = &.{item}, .total = total, .next = "more" });
        try std.testing.expectError(error.InvalidEnrichmentPage, s.enrichmentPage(a, page, m.id, m.revision, .attachments, ""));
    }
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM enrichment_pages"));
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM enrichment_cache"));
    const good = try u.json(a, .{ .message_id = m.id, .revision = m.revision, .section = "attachments", .items = &.{item}, .total = 2, .next = "more" });
    try std.testing.expect(try s.enrichmentPage(a, good, m.id, m.revision, .attachments, ""));
    const duplicate = try u.json(a, .{ .message_id = m.id, .revision = m.revision, .section = "attachments", .items = &.{item}, .total = 2, .next = @as(?[]const u8, null) });
    try std.testing.expectError(error.InvalidEnrichmentPage, s.enrichmentPage(a, duplicate, m.id, m.revision, .attachments, "more"));
    try std.testing.expectEqualStrings("more", (try s.enrichmentNext(a, m.id, m.revision, "attachments")).?);
}

test "self thread upgrade preserves both histories drafts unread and immutable sends" {
    const t = @import("protocol/types.zig");
    const Shared = @import("client/SharedSnapshot.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = epoch;
    const alias = "22345678-1234-1234-1234-123456789012";
    try s.beginSync(epoch, epoch ++ ":0");
    for ([_][]const u8{ root, alias, "unrelated" }) |id| {
        _ = try s.upsert(a, "conversation", try u.json(a, t.Conversation{ .id = id, .service = "imessage", .title = "Same contact name", .participants = &.{id}, .sendable = true }));
        var m = try std.json.parseFromSliceLeaky(t.Message, a, message, .{});
        m.id = id;
        m.conversation_id = id;
        _ = try s.upsert(a, "message", try u.json(a, m));
    }
    const input = t.SendInput{ .request_id = epoch, .server_epoch = epoch, .target = .{ .conversation_id = alias }, .text = "Unresolved send" };
    try s.persistSend(a, alias, input);
    try s.saveDraft(root, "Phone draft");
    try s.saveDraft(alias, "Email draft 👋");
    try s.page(root, null);
    try s.page(alias, "old-cursor");
    try s.exec("INSERT INTO unread VALUES(?,2),(?,3)", &.{ .{ .text = root }, .{ .text = alias } });
    const previous = try Shared.create(s, root, 1, null);
    defer previous.release();
    try std.testing.expectEqual(@as(usize, 3), previous.snapshot.chats.len);
    // Alias first models reversed bootstrap pages and upgrades with cached data.
    for ([_][]const u8{ alias, root }) |id| _ = try s.upsert(a, "conversation", try u.json(a, t.Conversation{ .id = id, .revision = "3", .service = "imessage", .participants = &.{id}, .sendable = true, .is_self = true, .thread_id = root }));
    const next = try Shared.create(s, root, 2, previous);
    defer next.release();
    try std.testing.expectEqual(@as(usize, 2), next.snapshot.chats.len);
    try std.testing.expectEqual(@as(usize, 2), next.snapshot.messages.len);
    try std.testing.expectEqual(@as(usize, 1), next.snapshot.pending.len);
    try std.testing.expectEqualStrings(alias, next.snapshot.pending[0].input.target.conversation_id.?);
    try std.testing.expectEqualStrings("Phone draft\n\nEmail draft 👋", next.snapshot.draft);
    try std.testing.expectEqualStrings("", (try s.nextPage(a, root)).?);
    try std.testing.expectEqualStrings(root, (try s.snapshot(a, alias)).selected);
    for (next.snapshot.chats) |chat| if (u.eq(chat.value.id, root)) {
        try std.testing.expectEqual(@as(i64, 5), chat.unread);
        try std.testing.expectEqual(@as(usize, 2), chat.value.participants.len);
        try std.testing.expectEqualStrings("You", next.snapshot.directory.conversation(a, chat.value));
        try std.testing.expect(next.snapshot.directory.matches(chat.value, alias));
    };
    try s.setHidden(alias, true);
    try std.testing.expectEqual(@as(i64, 2), try s.db.scalar("SELECT count(*) FROM hidden_chats"));
    try s.setHidden(root, false);
    try s.read(alias);
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
    var incoming = try std.json.parseFromSliceLeaky(t.Message, a, message, .{});
    incoming.id = "new-self-message";
    incoming.conversation_id = alias;
    const notification = try @import("client/Notification.zig").create(s, incoming);
    defer notification.destroy();
    try std.testing.expectEqualStrings(root, notification.chat);
    try std.testing.expectEqualStrings("You", notification.summary);
    const ev = try u.json(a, .{ .cursor = epoch ++ ":4", .sequence = "4", .type = "message.upsert", .origin = "live", .record = incoming });
    try std.testing.expect((try s.eventNotification(a, ev, epoch ++ ":4", "message.upsert", root)) == null);
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
    try s.saveDraft(root, "Edited combined draft");
    try std.testing.expectEqualStrings("Edited combined draft", try s.draft(a, alias));
}

test "You sends to a verified self address while other conversations keep their routes" {
    const t = @import("protocol/types.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const root = epoch;
    const alias = "22345678-1234-1234-1234-123456789012";
    try s.beginSync(epoch, epoch ++ ":0");
    const older = t.Conversation{ .id = root, .service = "imessage", .participants = &.{"self@example.invalid"}, .is_self = true, .thread_id = root, .last_activity = "2026-01-01T00:00:00Z", .sendable = false };
    const recent = t.Conversation{ .id = alias, .service = "imessage", .participants = &.{"+14155550124"}, .is_self = true, .thread_id = root, .last_activity = "2026-01-02T00:00:00Z", .sendable = true };
    for ([_]t.Conversation{ older, recent }) |chat| _ = try s.upsert(ar, "conversation", try u.json(ar, chat));
    for ([_][]const u8{ root, alias }) |key| {
        const target = try s.sendTarget(ar, key);
        try std.testing.expect(target.conversation_id == null);
        try std.testing.expectEqualStrings("+14155550124", target.recipient.?.address);
        try std.testing.expectEqualStrings("imessage", target.recipient.?.service);
    }
    const snapshot = try s.snapshot(ar, root);
    try std.testing.expectEqual(@as(usize, 1), snapshot.chats.len);
    try std.testing.expectEqualStrings(root, snapshot.selected);
    try std.testing.expect(Store.selfRecipient(snapshot.chats[0].value) != null);

    // A matching display name, SMS chat, or invalid address is not an exception.
    var other = t.Conversation{ .id = "other", .service = "imessage", .title = "You", .participants = &.{"peer@example.invalid"}, .sendable = false };
    _ = try s.upsert(ar, "conversation", try u.json(ar, other));
    try std.testing.expect(Store.selfRecipient(other) == null);
    try std.testing.expectEqualStrings("other", (try s.sendTarget(ar, "other")).conversation_id.?);
    other.is_self = true;
    other.service = "sms";
    other.revision = "1";
    _ = try s.upsert(ar, "conversation", try u.json(ar, other));
    try std.testing.expect(Store.selfRecipient(other) == null);
    try std.testing.expectEqualStrings("other", (try s.sendTarget(ar, "other")).conversation_id.?);
    other.service = "imessage";
    other.participants = &.{"invalid address"};
    other.revision = "2";
    _ = try s.upsert(ar, "conversation", try u.json(ar, other));
    try std.testing.expect(Store.selfRecipient(other) == null);
    try std.testing.expectEqualStrings("other", (try s.sendTarget(ar, "other")).conversation_id.?);
}

test "hidden conversations survive restart and live updates without losing history or drafts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = try std.fmt.allocPrintSentinel(ar, ".zig-cache/tmp/{s}/client.db", .{tmp.sub_path}, 0);
    const conversation = "{\"id\":\"c1\",\"service\":\"imessage\"}";
    {
        const store = try Store.open(path);
        defer store.close();
        try store.beginSync(epoch, epoch ++ ":0");
        _ = try store.upsert(ar, "conversation", conversation);
        try store.saveDraft("c1", "Keep this draft 👋");
        try store.setHidden("c1", true);
        try store.setHidden("c1", true);
    }
    const store = try Store.open(path);
    defer store.close();
    try std.testing.expect((try store.snapshot(ar, "c1")).chats[0].hidden);
    const ev = "{\"cursor\":\"" ++ epoch ++ ":1\",\"sequence\":\"1\",\"type\":\"message.upsert\",\"origin\":\"live\",\"record\":" ++ message ++ "}";
    try store.event(ar, ev, epoch ++ ":1", "message.upsert", "");
    _ = try store.upsert(ar, "conversation", "{\"id\":\"c1\",\"revision\":\"1\",\"service\":\"imessage\",\"title\":\"New activity\"}");
    const hidden = try store.snapshot(ar, "c1");
    try std.testing.expect(hidden.chats[0].hidden);
    try std.testing.expectEqualStrings("Hello 👋", hidden.messages[0].text.?);
    try std.testing.expectEqualStrings("Keep this draft 👋", hidden.draft);
    try store.setHidden("c1", false);
    const visible = try store.snapshot(ar, "c1");
    try std.testing.expect(!visible.chats[0].hidden);
    try std.testing.expectEqualStrings(hidden.draft, visible.draft);
    try std.testing.expectEqualStrings(hidden.messages[0].text.?, visible.messages[0].text.?);

    // A recovered draft must not bring a hidden conversation back into the list.
    try store.setHidden("c1", true);
    try store.beginSync(epoch, epoch ++ ":0");
    const recovered = try store.snapshot(ar, "c1");
    try std.testing.expect(recovered.chats[0].hidden);
    try std.testing.expectEqualStrings("Keep this draft 👋", recovered.draft);
    _ = try store.upsert(ar, "conversation", conversation);
    try std.testing.expect((try store.snapshot(ar, "c1")).chats[0].hidden);
}

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

test "background history advances sync and previews without filling the message cache" {
    const t = @import("protocol/types.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":0");
    _ = try s.upsert(ar, "conversation", "{\"id\":\"c1\",\"service\":\"imessage\"}");
    var m = try std.json.parseFromSliceLeaky(t.Message, ar, message, .{});
    for (0..200) |i| {
        m.id = try std.fmt.allocPrint(ar, "archive-{d}", .{i});
        m.revision = try u.decimal(ar, @intCast(i + 1));
        m.timestamp = if (i == 0) "2020-01-01T00:00:00Z" else "2010-01-01T00:00:00Z";
        const cursor = try t.cursor(ar, epoch, @intCast(i + 1));
        const raw = try u.json(ar, .{ .cursor = cursor, .sequence = m.revision, .type = "message.upsert", .origin = if (i % 2 == 0) "historical_import" else "reconciliation", .record = m });
        try std.testing.expect(try s.eventNotification(ar, raw, cursor, "message.upsert", "") == null);
    }
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM records WHERE kind='message'"));
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
    try std.testing.expectEqualStrings(epoch ++ ":200", try s.get(ar, "cursor"));
    var preview = try s.db.prepare("SELECT json_extract(record,'$.message_id') FROM previews WHERE chat='c1'");
    defer preview.close();
    _ = try preview.step();
    try std.testing.expectEqualStrings("archive-0", preview.bytes(0));

    // An explicit history page is retained and later edits still update it.
    _ = try s.upsert(ar, "message", try u.json(ar, m));
    m.revision = "201";
    m.text = "Edited requested history";
    const edited = try u.json(ar, .{ .cursor = epoch ++ ":201", .sequence = "201", .type = "message.upsert", .origin = "reconciliation", .record = m });
    try s.event(ar, edited, epoch ++ ":201", "message.upsert", "");
    try std.testing.expectEqualStrings("Edited requested history", (try s.snapshot(ar, "c1")).messages[0].text.?);
    m.id = "live";
    m.revision = "202";
    m.timestamp = "2026-01-01T00:00:00Z";
    const live = try u.json(ar, .{ .cursor = epoch ++ ":202", .sequence = "202", .type = "message.upsert", .origin = "live", .record = m });
    try std.testing.expect((try s.eventNotification(ar, live, epoch ++ ":202", "message.upsert", "")) != null);
    try std.testing.expect((try s.eventNotification(ar, live, epoch ++ ":202", "message.upsert", "")) == null);
    try std.testing.expectEqual(@as(i64, 2), try s.db.scalar("SELECT count(*) FROM records WHERE kind='message'"));
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count FROM unread WHERE chat='c1'"));
}

test "legacy history cache trims once per thread while preserving drafts sends and requested pages" {
    const t = @import("protocol/types.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = try std.fmt.allocPrintSentinel(ar, ".zig-cache/tmp/{s}/client.db", .{tmp.sub_path}, 0);
    const root = epoch;
    const alias = "22345678-1234-1234-1234-123456789012";
    const input = t.SendInput{ .request_id = epoch, .server_epoch = epoch, .target = .{ .conversation_id = alias }, .text = "Saved send" };
    var saved_payload: []const u8 = undefined;
    {
        const s = try Store.open(path);
        defer s.close();
        try s.beginSync(epoch, epoch ++ ":200");
        for ([_][]const u8{ root, alias }) |id| _ = try s.upsert(ar, "conversation", try u.json(ar, t.Conversation{ .id = id, .is_self = true, .thread_id = root, .service = "imessage" }));
        var m = try std.json.parseFromSliceLeaky(t.Message, ar, message, .{});
        for (0..150) |i| {
            m.id = try std.fmt.allocPrint(ar, "m-{d:0>3}", .{i});
            m.conversation_id = if (i % 2 == 0) root else alias;
            _ = try s.upsert(ar, "message", try u.json(ar, m));
        }
        try s.persistSend(ar, root, input);
        try s.saveDraft(root, "Keep draft 👋");
        _ = try s.upsert(ar, "request", try u.json(ar, t.SendRequest{ .request_id = input.request_id, .server_epoch = epoch, .target = input.target, .text = input.text, .state = .unknown, .candidate_message_id = "m-000" }));
        var payload = try s.db.prepare("SELECT payload FROM outbox");
        defer payload.close();
        _ = try payload.step();
        saved_payload = try payload.text(ar, 0);
        try s.page(root, "old-page");
        try s.exec("INSERT INTO unread VALUES(?,3)", &.{.{ .text = root }});
        try s.db.exec("INSERT INTO enrichment_pages VALUES('m-001','1','attachments','[]',NULL); INSERT INTO enrichment_cache VALUES('m-001',1,'{}',1)");
        try s.db.exec("DELETE FROM meta WHERE key='lazy_history_cache_v1'");
    }
    {
        const s = try Store.open(path);
        defer s.close();
        try std.testing.expectEqual(@as(i64, 101), try s.db.scalar("SELECT count(*) FROM records WHERE kind='message'"));
        try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM records WHERE kind='message' AND id='m-000'"));
        try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM enrichment_cache"));
        try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM enrichment_pages"));
        try std.testing.expectEqualStrings("", (try s.nextPage(ar, root)).?);
        try std.testing.expectEqualStrings("Keep draft 👋", try s.draft(ar, root));
        try std.testing.expectEqualStrings(epoch ++ ":200", try s.get(ar, "cursor"));
        try std.testing.expectEqual(@as(i64, 3), try s.db.scalar("SELECT count FROM unread"));
        var payload = try s.db.prepare("SELECT payload FROM outbox");
        defer payload.close();
        _ = try payload.step();
        try std.testing.expectEqualStrings(saved_payload, payload.bytes(0));
        // The pinned old echo must not let reconciliation refill the archive.
        var background = try std.json.parseFromSliceLeaky(t.Message, ar, message, .{});
        background.id = "m-010";
        background.conversation_id = alias;
        background.revision = "201";
        const old_event = try u.json(ar, .{ .cursor = epoch ++ ":201", .sequence = "201", .type = "message.upsert", .origin = "reconciliation", .record = background });
        try s.event(ar, old_event, epoch ++ ":201", "message.upsert", root);
        try std.testing.expectEqual(@as(i64, 101), try s.db.scalar("SELECT count(*) FROM records WHERE kind='message'"));
        // A newly discovered message inside the recent window is still useful.
        background.id = "m-999";
        background.revision = "202";
        const recent_event = try u.json(ar, .{ .cursor = epoch ++ ":202", .sequence = "202", .type = "message.upsert", .origin = "reconciliation", .record = background });
        try s.event(ar, recent_event, epoch ++ ":202", "message.upsert", root);
        try std.testing.expectEqual(@as(i64, 102), try s.db.scalar("SELECT count(*) FROM records WHERE kind='message'"));
        // History explicitly requested after the migration survives reopening.
        var older = try std.json.parseFromSliceLeaky(t.Message, ar, message, .{});
        older.id = "requested-old";
        older.conversation_id = alias;
        older.timestamp = "2010-01-01T00:00:00Z";
        _ = try s.upsert(ar, "message", try u.json(ar, older));
        try s.page(root, "requested-page");
    }
    const reopened = try Store.open(path);
    defer reopened.close();
    try std.testing.expectEqual(@as(i64, 103), try reopened.db.scalar("SELECT count(*) FROM records WHERE kind='message'"));
    try std.testing.expectEqualStrings("requested-page", (try reopened.nextPage(ar, root)).?);
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
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='delivered' AND detail=''"));
    _ = try s.upsert(a, "request", raw);
    try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='delivered'"));
}
test "outbox send times survive status updates, restart, and epoch reset" {
    const t = @import("protocol/types.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = try std.fmt.allocPrintSentinel(ar, ".zig-cache/tmp/{s}/client.db", .{tmp.sub_path}, 0);
    const input = t.SendInput{ .request_id = epoch, .server_epoch = epoch, .target = .{ .recipient = .{ .address = "test@example.invalid", .service = "imessage" } }, .text = "Keep my place" };
    var sent_at: []const u8 = undefined;
    {
        const store = try Store.open(path);
        defer store.close();
        try store.beginSync(epoch, epoch ++ ":0");
        const before = try u.timestamp(ar, (u.now() - 978307200000) * 1000000);
        try store.persistSend(ar, "c1", input);
        const after = try u.timestamp(ar, (u.now() - 978307200000) * 1000000);
        sent_at = (try store.snapshot(ar, "c1")).pending[0].sent_at;
        try std.testing.expect(std.mem.order(u8, sent_at, before) != .lt);
        try std.testing.expect(std.mem.order(u8, sent_at, after) != .gt);
        try store.outcome(epoch, "unknown", "Connection interrupted");
        _ = try store.upsert(ar, "request", try u.json(ar, t.SendRequest{ .request_id = epoch, .server_epoch = epoch, .target = input.target, .text = input.text, .revision = "2", .state = .unknown }));
        try std.testing.expectEqualStrings(sent_at, (try store.snapshot(ar, "c1")).pending[0].sent_at);
    }
    const reopened = try Store.open(path);
    defer reopened.close();
    try std.testing.expectEqualStrings(sent_at, (try reopened.snapshot(ar, "c1")).pending[0].sent_at);
    try reopened.beginSync("22345678-1234-1234-1234-123456789012", "22345678-1234-1234-1234-123456789012:0");
    try std.testing.expectEqualStrings(sent_at, (try reopened.snapshot(ar, "c1")).pending[0].sent_at);
}

test "legacy outbox positions are estimated from nearby history only once" {
    const t = @import("protocol/types.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = try std.fmt.allocPrintSentinel(ar, ".zig-cache/tmp/{s}/client.db", .{tmp.sub_path}, 0);
    const input = t.SendInput{ .request_id = epoch, .server_epoch = epoch, .target = .{ .recipient = .{ .address = "test@example.invalid", .service = "imessage" } }, .text = "Older uncertain send" };
    {
        const store = try Store.open(path);
        defer store.close();
        try store.beginSync(epoch, epoch ++ ":0");
        var m = (try std.json.parseFromSlice(t.Message, ar, message, .{})).value;
        m.revision = "10";
        _ = try store.upsert(ar, "message", try u.json(ar, m));
        m.id = "m2";
        m.revision = "30";
        m.timestamp = "2026-01-01T00:02:00Z";
        _ = try store.upsert(ar, "message", try u.json(ar, m));
        try store.persistSend(ar, "c1", input);
        _ = try store.upsert(ar, "request", try u.json(ar, t.SendRequest{ .request_id = epoch, .server_epoch = epoch, .target = input.target, .text = input.text, .revision = "20", .state = .unknown }));
        // Recreate the schema used before send times were persisted.
        try store.db.exec("ALTER TABLE outbox DROP COLUMN sent_at");
    }
    {
        const migrated = try Store.open(path);
        defer migrated.close();
        try std.testing.expectEqualStrings("2026-01-01T00:00:00Z", (try migrated.snapshot(ar, "c1")).pending[0].sent_at);
        _ = try migrated.upsert(ar, "request", try u.json(ar, t.SendRequest{ .request_id = epoch, .server_epoch = epoch, .target = input.target, .text = input.text, .revision = "40", .state = .unknown }));
    }
    const reopened = try Store.open(path);
    defer reopened.close();
    try std.testing.expectEqualStrings("2026-01-01T00:00:00Z", (try reopened.snapshot(ar, "c1")).pending[0].sent_at);
}

test "provisional outgoing echoes replace uncertainty without confirming or discarding the request" {
    const t = @import("protocol/types.zig");
    const SharedSnapshot = @import("client/SharedSnapshot.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":0");
    const input = t.SendInput{ .request_id = epoch, .server_epoch = epoch, .target = .{ .recipient = .{ .address = "test@example.invalid", .service = "imessage" } }, .text = "Awww" };
    var request = t.SendRequest{ .request_id = epoch, .server_epoch = epoch, .target = input.target, .text = input.text, .revision = "3", .state = .unknown, .error_info = .{ .code = "awaiting_observation", .message = "Awaiting an unambiguous outgoing Messages record.", .outcome = .uncertain } };
    var echo = (try std.json.parseFromSlice(t.Message, ar, message, .{})).value;
    echo.direction = .outgoing;
    echo.observed_status = .delivered;
    echo.text = input.text;
    // Cover existing chats and the eventual echo in a new direct conversation,
    // with both message-before-request and request-before-message arrival.
    for ([_][]const u8{ "c1", "new:test@example.invalid" }) |key| {
        try s.db.exec("DELETE FROM outbox; DELETE FROM records;");
        try s.persistSend(ar, key, input);
        request.revision = "3";
        request.candidate_message_id = null;
        _ = try s.upsert(ar, "request", try u.json(ar, request));
        if (u.eq(key, "c1")) _ = try s.upsert(ar, "message", try u.json(ar, echo));
        // Text alone must never hide a pending send.
        try std.testing.expectEqual(@as(usize, 1), (try s.snapshot(ar, key)).pending.len);
        request.revision = "4";
        request.candidate_message_id = echo.id;
        _ = try s.upsert(ar, "request", try u.json(ar, request));
        if (!u.eq(key, "c1")) {
            try std.testing.expectEqual(@as(usize, 1), (try s.snapshot(ar, key)).pending.len);
            _ = try s.upsert(ar, "message", try u.json(ar, echo));
        }
        const merged = try SharedSnapshot.create(s, key, 1, null);
        defer merged.release();
        try std.testing.expectEqual(@as(usize, 1), merged.snapshot.messages.len);
        try std.testing.expectEqual(.delivered, merged.snapshot.messages[0].observed_status);
        try std.testing.expectEqual(@as(usize, 0), merged.snapshot.pending.len);
        try std.testing.expectEqual(@as(usize, 0), (try s.snapshot(ar, key)).pending.len);
        try std.testing.expectEqual(@as(i64, 1), try s.db.scalar("SELECT count(*) FROM outbox WHERE state='unknown' AND json_extract(record,'$.message_id') IS NULL"));
        // Another plausible echo withdraws the hint. The saved request and its
        // uncertainty return, and new-conversation history drops the old hint.
        request.revision = "5";
        request.candidate_message_id = null;
        _ = try s.upsert(ar, "request", try u.json(ar, request));
        const ambiguous = try SharedSnapshot.create(s, key, 2, merged);
        defer ambiguous.release();
        try std.testing.expectEqual(@as(usize, 1), ambiguous.snapshot.pending.len);
        try std.testing.expectEqualStrings("unknown", ambiguous.snapshot.pending[0].state);
        try std.testing.expectEqual(@as(usize, if (u.eq(key, "c1")) 1 else 0), ambiguous.snapshot.messages.len);
    }
    // Old-epoch hints are never used after a reset, even if an ID is cached again.
    request.revision = "6";
    request.candidate_message_id = echo.id;
    _ = try s.upsert(ar, "request", try u.json(ar, request));
    try s.beginSync("22345678-1234-1234-1234-123456789012", "22345678-1234-1234-1234-123456789012:0");
    _ = try s.upsert(ar, "message", try u.json(ar, echo));
    const reset = try s.snapshot(ar, "new:test@example.invalid");
    try std.testing.expectEqual(@as(usize, 1), reset.pending.len);
    try std.testing.expectEqual(@as(usize, 0), reset.messages.len);
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

test "RGB glyph edges use opaque backgrounds and transparent text stays grayscale" {
    const c = @import("client/c.zig").api;
    const text = "RGB hinting: Hello world";
    const rgb = c.zc_text_new_with_options(text.ptr, text.len, 16, 300, 1, 0, 1) orelse return error.NoLayout;
    defer c.zc_text_free(rgb);
    const height = c.zc_text_height(rgb);
    const bytes: usize = @intCast(c.zc_text_width(rgb) * height * 4);
    // Independent RGB coverages cannot be stored in one transparent alpha.
    try std.testing.expect(c.zc_text_pixels(rgb, 0xffffffff, 0, 0, 0, height) == null);
    var chromatic: usize = 0;
    for ([_]u32{ 0x000000ff, 0xffffffff }) |background| {
        const foreground = (background ^ 0xffffff00);
        const pixels = c.zc_text_pixels_on(rgb, foreground, 0, 0, 0, height, background);
        try std.testing.expect(pixels != null);
        var i: usize = 0;
        while (i < bytes) : (i += 4) {
            try std.testing.expectEqual(@as(u8, 255), pixels[i + 3]);
            if (pixels[i] != pixels[i + 1] or pixels[i + 1] != pixels[i + 2]) chromatic += 1;
        }
        try std.testing.expectEqual(@as(u8, @intCast(background >> 24)), pixels[0]);
    }
    const gray = c.zc_text_new(text.ptr, text.len, 16, 300, 1) orelse return error.NoLayout;
    defer c.zc_text_free(gray);
    const gray_pixels = c.zc_text_pixels(gray, 0xffffffff, 0, 0, 0, c.zc_text_height(gray));
    try std.testing.expect(gray_pixels != null);
    const gray_bytes: usize = @intCast(c.zc_text_width(gray) * c.zc_text_height(gray) * 4);
    var partial_alpha = false;
    var i: usize = 0;
    while (i < gray_bytes) : (i += 4) {
        try std.testing.expectEqual(gray_pixels[i], gray_pixels[i + 1]);
        try std.testing.expectEqual(gray_pixels[i + 1], gray_pixels[i + 2]);
        partial_alpha = partial_alpha or (gray_pixels[i + 3] > 0 and gray_pixels[i + 3] < 255);
    }
    try std.testing.expect(partial_alpha);
    // Some font backends only provide grayscale coverage.
    if (chromatic == 0) return error.SkipZigTest;
}

test "fractional scale tiles match full text rendering including selection and bidi" {
    const c = @import("client/c.zig").api;
    const text = "Café é 👩‍💻 שלום مرحبا\n" ** 12;
    for ([_]f64{ 1, 1.25, 1.5, 2 }) |scale| for ([_]bool{ false, true }) |subpixel| {
        const layout = c.zc_text_new_with_options(text.ptr, text.len, 16, 300, scale, 0, @intFromBool(subpixel)) orelse return error.NoLayout;
        defer c.zc_text_free(layout);
        const width: usize = @intCast(c.zc_text_width(layout));
        const height = c.zc_text_height(layout);
        const background: u32 = if (subpixel) 0xf0e8d8ff else 0;
        const ptr = c.zc_text_pixels_on(layout, 0x112233ff, 0, 80, 0, height, background);
        try std.testing.expect(ptr != null);
        const full = try std.testing.allocator.dupe(u8, ptr[0 .. width * @as(usize, @intCast(height)) * 4]);
        defer std.testing.allocator.free(full);
        // It must contain glyphs rather than an empty successful surface.
        var ink = false;
        var i: usize = 0;
        while (i < full.len) : (i += 4) {
            ink = ink or if (subpixel) full[i] != background >> 24 else full[i + 3] != 0;
        }
        try std.testing.expect(ink);
        for ([_]usize{ 1, 17, 64, 128 }) |top| {
            const tile = c.zc_text_pixels_on(layout, 0x112233ff, 0, 80, @intCast(top), 128, background);
            try std.testing.expect(tile != null);
            try std.testing.expectEqualSlices(u8, full[width * top * 4 ..][0 .. width * 128 * 4], tile[0 .. width * 128 * 4]);
        }
    };
}

test "identity events are negotiated, revision merged, atomic and cleared on reset" {
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":0");
    const identity = "{\"id\":\"person\",\"revision\":\"7\",\"service\":\"imessage\",\"address\":\"test@example.invalid\",\"display_name\":\"Renamed 👋\",\"match_state\":\"matched\"}";
    const ev = "{\"cursor\":\"" ++ epoch ++ ":7\",\"sequence\":\"7\",\"type\":\"identity.upsert\",\"origin\":\"reconciliation\",\"record\":" ++ identity ++ "}";
    try std.testing.expectError(error.UnknownEvent, s.event(ar, ev, epoch ++ ":7", "identity.upsert", ""));
    try s.set("accepted_extensions", "identity-v1");
    try s.event(ar, ev, epoch ++ ":7", "identity.upsert", "");
    const stale = try std.mem.replaceOwned(u8, ar, identity, "\"7\"", "\"1\"");
    _ = try s.upsert(ar, "identity", stale);
    try std.testing.expectEqualStrings("Renamed 👋", (try s.directory(ar)).name("imessage", "test@example.invalid"));
    try std.testing.expectEqual(@as(i64, 7), try s.db.scalar("SELECT revision FROM identities"));
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
    try s.db.exec("CREATE TRIGGER reject_identity_cursor BEFORE UPDATE ON meta WHEN NEW.key='cursor' BEGIN SELECT RAISE(ABORT,'failure'); END");
    const cleared = "{\"id\":\"person\",\"revision\":\"8\",\"service\":\"imessage\",\"address\":\"test@example.invalid\",\"match_state\":\"unavailable\"}";
    const next = try u.json(ar, .{ .cursor = epoch ++ ":8", .sequence = "8", .type = "identity.upsert", .origin = "reconciliation", .record = try std.json.parseFromSliceLeaky(std.json.Value, ar, cleared, .{}) });
    try std.testing.expectError(error.DatabaseFailure, s.event(ar, next, epoch ++ ":8", "identity.upsert", ""));
    try std.testing.expectEqual(@as(i64, 7), try s.db.scalar("SELECT revision FROM identities"));
    try s.db.exec("DROP TRIGGER reject_identity_cursor");
    try s.event(ar, next, epoch ++ ":8", "identity.upsert", "");
    try std.testing.expectEqualStrings("test@example.invalid", (try s.directory(ar)).name("imessage", "test@example.invalid"));
    try s.saveDraft("c1", "Keep draft");
    try s.beginSync(epoch, epoch ++ ":8");
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM identities"));
    try std.testing.expectEqualStrings("Keep draft", try s.draft(ar, "c1"));
    try std.testing.expectEqualStrings("0", try s.get(ar, "identity_bootstrapped"));
}

test "reaction rows and enrichment changes do not alert or create unread" {
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":0");
    const reaction = try std.mem.replaceOwned(u8, ar, message, "\"kind\":\"text\"", "\"kind\":\"reaction\"");
    const ev = try std.fmt.allocPrint(ar, "{{\"cursor\":\"{s}:1\",\"sequence\":\"1\",\"type\":\"message.upsert\",\"origin\":\"live\",\"record\":{s}}}", .{ epoch, reaction });
    try std.testing.expect(try s.eventNotification(ar, ev, epoch ++ ":1", "message.upsert", "") == null);
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM unread"));
}

test "overflow pages extend immutable presentations and stale pages cannot restore cleared enrichment" {
    const t = @import("protocol/types.zig");
    const Shared = @import("client/SharedSnapshot.zig");
    const s = try Store.open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try s.beginSync(epoch, epoch ++ ":0");
    var m = try std.json.parseFromSliceLeaky(t.Message, ar, message, .{});
    m.enrichment = .{ .state = .complete, .attachments = .{ .total = 2, .complete = false } };
    const item = t.Attachment{ .id = "a", .name = "a.png", .mime_type = "image/png", .bytes = "10" };
    m.attachments = &.{item};
    _ = try s.upsert(ar, "message", try u.json(ar, m));
    const first = try Shared.create(s, "c1", 1, null);
    defer first.release();
    const page = try u.json(ar, .{ .message_id = m.id, .revision = m.revision, .section = "attachments", .items = &.{item}, .total = 2, .next = "next" });
    try std.testing.expect(try s.enrichmentPage(ar, page, m.id, m.revision, .attachments, ""));
    var second_item = item;
    second_item.id = "b";
    const final_page = try u.json(ar, .{ .message_id = m.id, .revision = m.revision, .section = "attachments", .items = &.{second_item}, .total = 2, .next = @as(?[]const u8, null) });
    try std.testing.expect(try s.enrichmentPage(ar, final_page, m.id, m.revision, .attachments, "next"));
    const expanded = try Shared.create(s, "c1", 2, first);
    defer expanded.release();
    try std.testing.expectEqual(@as(usize, 2), expanded.snapshot.messages[0].attachments.len);
    try std.testing.expect(expanded.snapshot.messages[0].enrichment.?.attachments.complete);
    try std.testing.expectEqual(@as(usize, 1), first.snapshot.messages[0].attachments.len);
    try std.testing.expect(first.history != expanded.history);
    try std.testing.expectEqualStrings("Hello 👋", expanded.snapshot.messages[0].text.?);
    m.revision = "3";
    m.attachments = &.{};
    m.reactions = &.{};
    m.enrichment = .{ .state = .complete };
    _ = try s.upsert(ar, "message", try u.json(ar, m));
    try std.testing.expect(!try s.enrichmentPage(ar, final_page, m.id, "2", .attachments, "next"));
    const cleared = try Shared.create(s, "c1", 3, expanded);
    defer cleared.release();
    try std.testing.expectEqual(@as(usize, 0), cleared.snapshot.messages[0].attachments.len);
    try std.testing.expectEqual(@as(usize, 0), cleared.snapshot.messages[0].reactions.?.len);
    try std.testing.expectEqual(@as(i64, 0), try s.db.scalar("SELECT count(*) FROM enrichment_cache"));
}
