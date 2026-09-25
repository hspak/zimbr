//! Durable reaction observations and projection. Called inside Core's source
//! read transaction and journal write transaction; no partial scan retires rows.
const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const Journal = @import("Journal.zig");
const enrichment = @import("enrichment.zig");
const Source = @import("adapter/MessagesDb.zig");
const Observation = @import("adapter/reactions.zig").Observation;
const Stored = struct {
    source: []const u8,
    row: i64,
    date: i64,
    value: t.Message,
};

pub const ObserveError = Journal.QueryError || std.json.ParseError(std.json.Scanner);
pub const NoLongerReactionError = Journal.QueryError || std.json.ParseError(std.json.Scanner);
pub const AnchorsMatchError = Journal.QueryError || u.Allocator.Error;
pub const DeletedAnchorError = Journal.QueryError || error{AmbiguousSourceIdentity};
pub const FindGuidError = Journal.QueryError || error{AmbiguousSourceIdentity};
pub const MissingTargetsError = Journal.QueryError || u.Allocator.Error || error{AmbiguousSourceIdentity};
pub const TrackedRowsError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    AmbiguousSourceIdentity,
    MetadataItemTooLarge,
    RandomUnavailable,
    WriteFailed,
};
pub const ProjectError = Journal.QueryError || std.json.ParseError(std.json.Scanner) || error{
    MetadataItemTooLarge,
    RandomUnavailable,
    WriteFailed,
};

fn message(a: u.Allocator, j: Journal, guid: []const u8) !?Stored {
    const q = try j.db.prepare("SELECT source,source_row,date_ns,record FROM messages WHERE source=?");
    defer q.close();
    try q.bind(&.{.{ .text = guid }});
    if (!try q.step()) return null;
    return .{
        .source = try q.text(a, 0),
        .row = q.int(1),
        .date = q.int(2),
        .value = try enrichment.full(
            a,
            j,
            (try std.json.parseFromSlice(t.Message, a, q.bytes(3), .{ .allocate = .alloc_always })).value,
        ),
    };
}
fn enqueue(j: Journal, cid: []const u8, target: []const u8) !void {
    try j.execute(
        "INSERT INTO reaction_work VALUES(?,?,0) ON CONFLICT(conversation_id,target_guid) DO UPDATE SET attempt_ms=0",
        &.{ .{ .text = cid }, .{ .text = target } },
    );
}
fn resolve(obs: Observation, cid: []const u8, target: ?Stored, retired: bool) t.ReactionEvent {
    var event = obs.event;
    if (retired) event.operation = .retired;
    if (event.resolution != .pending and event.resolution != .resolved) return event;
    const parent = target orelse return event;
    if (!u.eq(parent.value.conversation_id, cid) or parent.value.kind == .reaction) {
        event.resolution = .malformed;
        return event;
    }
    event.target_message_id = parent.value.id;
    event.resolution = .resolved;
    if (obs.source_part) |index| {
        for (parent.value.parts orelse &.{}) |part| if (part.source_index == index) {
            event.part_id = part.id;
            event.part_state = .resolved;
            break;
        };
    } else if (obs.bubble) {
        const cards = parent.value.link_previews orelse &.{};
        if (cards.len == 1) {
            event.part_id = cards[0].part_id;
            event.part_state = .resolved;
        }
    } else event.part_state = .resolved; // explicit whole-message association
    return event;
}
pub fn observe(
    a: u.Allocator,
    j: Journal,
    guid: []const u8,
    row: i64,
    date: i64,
    cid: []const u8,
    obs: Observation,
) ObserveError!t.ReactionEvent {
    const encoded = try u.json(a, obs);
    const previous = try j.db.prepare("SELECT observation,retired,conversation_id,target_guid,date_ns,source_row FROM reaction_sources WHERE source=?");
    defer previous.close();
    try previous.bind(&.{.{ .text = guid }});
    const exists = try previous.step();
    const retired = exists and previous.int(1) != 0;
    if (retired) {
        // A stale reimport cannot move a tombstone's target or source ordering.
        const original = (try std.json.parseFromSlice(
            Observation,
            a,
            previous.bytes(0),
            .{ .allocate = .alloc_always },
        )).value;
        return resolve(
            original,
            previous.bytes(2),
            if (original.target_guid) |target| try message(a, j, target) else null,
            true,
        );
    }
    const changed = !exists or !u.eq(previous.bytes(0), encoded) or !u.eq(previous.bytes(2), cid) or previous.int(4) != date or previous.int(5) != row;
    if (changed) {
        if (exists and previous.bytes(3).len > 0) try enqueue(
            j,
            previous.bytes(2),
            previous.bytes(3),
        );
        try j.execute("INSERT INTO reaction_sources(source,source_row,conversation_id,target_guid,date_ns,observation) VALUES(?,?,?,?,?,?) ON CONFLICT(source) DO UPDATE SET source_row=excluded.source_row,conversation_id=excluded.conversation_id,target_guid=excluded.target_guid,date_ns=excluded.date_ns,observation=excluded.observation", &.{
            .{ .text = guid },
            .{ .int = row },
            .{ .text = cid },
            if (obs.target_guid) |target| .{ .text = target } else .null_value,
            .{ .int = date },
            .{ .text = encoded },
        });
        if (obs.target_guid) |target| try enqueue(j, cid, target);
    }
    return resolve(
        obs,
        cid,
        if (obs.target_guid) |target| try message(a, j, target) else null,
        retired,
    );
}
pub fn targetImported(j: Journal, guid: []const u8, cid: []const u8) Journal.QueryError!void {
    try j.execute(
        "INSERT INTO reaction_work SELECT conversation_id,target_guid,0 FROM reaction_sources WHERE target_guid=? AND conversation_id=? GROUP BY conversation_id,target_guid ON CONFLICT(conversation_id,target_guid) DO UPDATE SET attempt_ms=0",
        &.{ .{ .text = guid }, .{ .text = cid } },
    );
}
pub fn noLongerReaction(a: u.Allocator, j: Journal, guid: []const u8) NoLongerReactionError!?t.ReactionEvent {
    const q = try j.db.prepare("SELECT observation,conversation_id,target_guid,retired FROM reaction_sources WHERE source=?");
    defer q.close();
    try q.bind(&.{.{ .text = guid }});
    if (!try q.step()) return null;
    const obs = (try std.json.parseFromSlice(
        Observation,
        a,
        q.bytes(0),
        .{ .allocate = .alloc_always },
    )).value;
    if (q.int(3) == 0) {
        try j.execute("UPDATE reaction_sources SET retired=1 WHERE source=?", &.{.{ .text = guid }});
        if (q.bytes(2).len > 0) try enqueue(j, q.bytes(1), q.bytes(2));
    }
    var event = obs.event;
    event.operation = .retired;
    event.resolution = .unsupported;
    return event;
}
pub fn anchor(j: Journal, guid: []const u8, row: i64) Journal.QueryError!void {
    // Each source row is visited once per batch. A duplicate GUID may reuse a
    // candidate that per-row trimming would already have discarded, but must
    // never move one of the retained anchors.
    try j.execute(
        "INSERT OR IGNORE INTO ordinary_anchors VALUES(?,?) ON CONFLICT(source) DO UPDATE SET source_row=excluded.source_row WHERE ordinary_anchors.source_row NOT IN(SELECT source_row FROM ordinary_anchors ORDER BY source_row LIMIT 4) AND ordinary_anchors.source_row NOT IN(SELECT source_row FROM ordinary_anchors ORDER BY source_row DESC LIMIT 12) AND NOT EXISTS(SELECT 1 FROM ordinary_anchors WHERE source_row=excluded.source_row)",
        &.{ .{ .int = row }, .{ .text = guid } },
    );
}
pub fn trimAnchors(j: Journal) Journal.QueryError!void {
    // Retain independent old and recent ordinary messages across cursor moves.
    // Run once inside the ingestion transaction, before committing its progress.
    try j.execute(
        "DELETE FROM ordinary_anchors WHERE source_row NOT IN(SELECT source_row FROM ordinary_anchors ORDER BY source_row LIMIT 4) AND source_row NOT IN(SELECT source_row FROM ordinary_anchors ORDER BY source_row DESC LIMIT 12)",
        &.{},
    );
}

test "batched anchors match per-row retention with duplicate GUIDs and rollback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    try j.db.exec("CREATE TEMP TABLE reference_anchors(source_row INTEGER PRIMARY KEY,source TEXT NOT NULL UNIQUE)");
    // Ascending live pages, descending backfill, and interleaved reconciliation.
    // Repeated GUIDs collide both with retained and already-discarded anchors.
    for (0..3) |order| {
        try j.db.exec("DELETE FROM ordinary_anchors; DELETE FROM reference_anchors");
        for (0..3) |batch| {
            try j.begin();
            for (0..96) |i| {
                const n = batch * 96 + i;
                const row: i64 = @intCast(1 + switch (order) {
                    0 => n,
                    1 => 287 - n,
                    else => (n * 101) % 288,
                });
                const guid = try u.decimal(a, @mod(row, 37));
                try anchor(j, guid, row);
                try j.execute(
                    "INSERT OR IGNORE INTO reference_anchors VALUES(?,?)",
                    &.{ .{ .int = row }, .{ .text = guid } },
                );
                try j.db.exec("DELETE FROM reference_anchors WHERE source_row NOT IN(SELECT source_row FROM reference_anchors ORDER BY source_row LIMIT 4) AND source_row NOT IN(SELECT source_row FROM reference_anchors ORDER BY source_row DESC LIMIT 12)");
            }
            try trimAnchors(j);
            try std.testing.expectEqual(
                @as(i64, 0),
                try j.db.scalar("SELECT count(*) FROM (SELECT * FROM ordinary_anchors EXCEPT SELECT * FROM reference_anchors)"),
            );
            try std.testing.expectEqual(
                @as(i64, 0),
                try j.db.scalar("SELECT count(*) FROM (SELECT * FROM reference_anchors EXCEPT SELECT * FROM ordinary_anchors)"),
            );
            try j.commit();
        }
        try j.begin();
        try anchor(j, "new-boundary", 1000);
        try trimAnchors(j);
        j.rollback();
        try std.testing.expectEqual(
            @as(i64, 0),
            try j.db.scalar("SELECT count(*) FROM (SELECT * FROM ordinary_anchors EXCEPT SELECT * FROM reference_anchors)"),
        );
        try j.begin();
        try j.reset(a);
        try j.commit();
        try std.testing.expectEqual(
            @as(i64, 0),
            try j.db.scalar("SELECT count(*) FROM ordinary_anchors"),
        );
    }
}
pub fn anchorsMatch(a: u.Allocator, j: Journal, source: Source) AnchorsMatchError!usize {
    const q = try j.db.prepare("SELECT source_row,source FROM ordinary_anchors");
    defer q.close();
    var count: usize = 0;
    while (try q.step()) {
        const current = try source.guid(a, q.int(0)) orelse return 0;
        if (!u.eq(current, q.bytes(1))) return 0;
        count += 1;
    }
    return count;
}
// A replaced/changed ordinary anchor never qualifies. Row reuse is allowed
// only when this tracked reaction GUID is absent everywhere in the same file.
pub fn deletedAnchor(j: Journal, source: Source, row: i64, saved: []const u8) DeletedAnchorError!bool {
    const q = try j.db.prepare("SELECT 1 FROM reaction_sources r JOIN messages m ON m.source=r.source WHERE r.source=? AND m.source_row=?");
    defer q.close();
    try q.bind(&.{ .{ .text = saved }, .{ .int = row } });
    if (!try q.step()) return false;
    return (try findGuid(source, saved, null)) == null;
}
pub fn findGuid(source: Source, guid: []const u8, chat: ?i64) FindGuidError!?i64 {
    const q = try source.db.prepare(if (chat != null) "SELECT m.ROWID FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID WHERE m.guid=? AND j.chat_id=? LIMIT 2" else "SELECT ROWID FROM message WHERE guid=? LIMIT 2");
    defer q.close();
    if (chat) |row| try q.bind(&.{ .{ .text = guid }, .{ .int = row } }) else try q.bind(&.{.{ .text = guid }});
    if (!try q.step()) return null;
    const row = q.int(0);
    if (try q.step()) return error.AmbiguousSourceIdentity;
    return row;
}
pub fn missingTargets(a: u.Allocator, j: Journal, source: Source) MissingTargetsError![]i64 {
    const q = try j.db.prepare("SELECT w.target_guid,c.source_row FROM reaction_work w JOIN conversations c ON c.id=w.conversation_id WHERE w.attempt_ms<=? AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.source=w.target_guid) ORDER BY w.attempt_ms,w.rowid LIMIT 10");
    defer q.close();
    try q.bind(&.{.{ .int = u.now() }});
    var rows: std.ArrayList(i64) = .empty;
    while (try q.step()) if (try findGuid(source, q.bytes(0), q.int(1))) |row| try rows.append(
        a,
        row,
    );
    return rows.toOwnedSlice(a);
}
pub fn prioritize(j: Journal, cid: []const u8) Journal.QueryError!void {
    try j.execute(
        "UPDATE reaction_sources SET check_ms=0 WHERE retired=0 AND conversation_id=?",
        &.{.{ .text = cid }},
    );
}
pub fn trackedRows(a: u.Allocator, j: Journal, source: Source) TrackedRowsError![]i64 {
    const q = try j.db.prepare("SELECT source,source_row,conversation_id,target_guid,observation FROM reaction_sources WHERE retired=0 ORDER BY check_ms,source LIMIT 50");
    defer q.close();
    const Tracked = struct {
        guid: []const u8,
        cid: []const u8,
        target: []const u8,
        obs: Observation,
    };
    var tracked: std.ArrayList(Tracked) = .empty;
    while (try q.step()) try tracked.append(a, .{
        .guid = try q.text(a, 0),
        .cid = try q.text(a, 2),
        .target = try q.text(a, 3),
        .obs = (try std.json.parseFromSlice(
            Observation,
            a,
            q.bytes(4),
            .{ .allocate = .alloc_always },
        )).value,
    });
    var rows: std.ArrayList(i64) = .empty;
    for (tracked.items) |item| {
        if (try findGuid(source, item.guid, null)) |row| {
            try rows.append(a, row);
            try j.execute(
                "UPDATE reaction_sources SET check_ms=? WHERE source=?",
                &.{ .{ .int = u.now() }, .{ .text = item.guid } },
            );
        } else {
            try j.execute(
                "UPDATE reaction_sources SET retired=1,check_ms=? WHERE source=?",
                &.{ .{ .int = u.now() }, .{ .text = item.guid } },
            );
            if (item.target.len > 0) try enqueue(j, item.cid, item.target);
            if (try message(a, j, item.guid)) |raw| {
                var value = raw.value;
                value.reaction_event = resolve(
                    item.obs,
                    item.cid,
                    if (item.target.len > 0) try message(a, j, item.target) else null,
                    true,
                );
                try j.message(a, raw.source, raw.row, raw.date, value, "reconciliation");
            }
        }
    }
    return rows.toOwnedSlice(a);
}
fn hash(a: u.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}
pub fn project(a: u.Allocator, j: Journal) ProjectError!void {
    const q = try j.db.prepare("SELECT conversation_id,target_guid FROM reaction_work WHERE attempt_ms<=? ORDER BY attempt_ms,rowid LIMIT 50");
    defer q.close();
    try q.bind(&.{.{ .int = u.now() }});
    const Target = struct { cid: []const u8, guid: []const u8 };
    var targets: std.ArrayList(Target) = .empty;
    while (try q.step()) try targets.append(
        a,
        .{ .cid = try q.text(a, 0), .guid = try q.text(a, 1) },
    );
    for (targets.items) |target| {
        const parent = try message(a, j, target.guid);
        if (parent == null) {
            try j.execute("UPDATE reaction_work SET attempt_ms=? WHERE conversation_id=? AND target_guid=?", &.{
                .{ .int = u.now() + 30000 },
                .{ .text = target.cid },
                .{ .text = target.guid },
            });
            continue;
        }
        const sources = try j.db.prepare("SELECT source,observation,retired FROM reaction_sources WHERE conversation_id=? AND target_guid=? ORDER BY date_ns,source_row,source");
        defer sources.close();
        try sources.bind(&.{ .{ .text = target.cid }, .{ .text = target.guid } });
        const Row = struct {
            guid: []const u8,
            obs: Observation,
            retired: bool,
        };
        var rows: std.ArrayList(Row) = .empty;
        while (try sources.step()) try rows.append(a, .{
            .guid = try sources.text(a, 0),
            .obs = (try std.json.parseFromSlice(
                Observation,
                a,
                sources.bytes(1),
                .{ .allocate = .alloc_always },
            )).value,
            .retired = sources.int(2) != 0,
        });
        var slots: std.StringHashMapUnmanaged(?t.Reaction) = .empty;
        for (rows.items) |item| {
            const event = resolve(item.obs, target.cid, parent, item.retired);
            if (try message(a, j, item.guid)) |raw| {
                var value = raw.value;
                value.reaction_event = event;
                try j.message(a, raw.source, raw.row, raw.date, value, "reconciliation");
            }
            if (event.resolution != .resolved or event.key == null) continue;
            const key = try u.json(a, .{
                .actor = event.actor,
                .part = item.obs.source_part,
                .bubble = item.obs.bubble,
            });
            const slot = try slots.getOrPut(a, key);
            if (!slot.found_existing) slot.value_ptr.* = null;
            switch (event.operation) {
                .add, .current => slot.value_ptr.* = .{
                    .id = try hash(a, try std.mem.concat(a, u8, &.{ parent.?.value.id, key })),
                    .actor = event.actor,
                    .key = event.key.?,
                    .emoji = event.emoji,
                    .part_id = event.part_id,
                    .part_state = if (event.part_state == .resolved) .resolved else .unresolved,
                },
                .remove => if (slot.value_ptr.*) |selected| {
                    if (u.eq(selected.key, event.key.?)) slot.value_ptr.* = null;
                },
                // Deletion of a current-state source is a durable ordering
                // barrier: earlier observed adds cannot resurrect after restart.
                .retired => if (item.obs.event.operation == .remove) {
                    if (slot.value_ptr.*) |selected| {
                        if (u.eq(selected.key, event.key.?)) slot.value_ptr.* = null;
                    }
                } else {
                    slot.value_ptr.* = null;
                },
                .unknown => {},
            }
        }
        if (u.eq(parent.?.value.conversation_id, target.cid) and parent.?.value.kind != .reaction) {
            var reactions: std.ArrayList(t.Reaction) = .empty;
            var it = slots.valueIterator();
            while (it.next()) |item| if (item.*) |reaction| try reactions.append(a, reaction);
            std.mem.sort(t.Reaction, reactions.items, {}, struct {
                fn less(_: void, x: t.Reaction, y: t.Reaction) bool {
                    return std.mem.order(u8, x.id, y.id) == .lt;
                }
            }.less);
            var value = parent.?.value;
            value.reactions = try reactions.toOwnedSlice(a);
            try j.message(a, parent.?.source, parent.?.row, parent.?.date, value, "reconciliation");
        }
        try j.execute(
            "DELETE FROM reaction_work WHERE conversation_id=? AND target_guid=?",
            &.{ .{ .text = target.cid }, .{ .text = target.guid } },
        );
    }
}
