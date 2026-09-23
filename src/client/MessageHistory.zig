//! Immutable, independently owned message records. Updating one record never
//! reparses unchanged text or pins an obsolete snapshot's entire arena.
const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol/types.zig");
const Store = @import("Store.zig");
const display = @import("display.zig");
const Self = @This();
const allocator = if (@import("builtin").is_test) std.testing.allocator else std.heap.c_allocator;
pub const Presentation = struct { text: []const u8, key: u64 };

const Record = struct {
    refs: std.atomic.Value(usize) = .init(1),
    arena: std.heap.ArenaAllocator,
    message: t.Message,
    presentation: Presentation,
    revision: i64,

    fn create(raw: []const u8, revision: i64) !*Record {
        const record = try allocator.create(Record);
        errdefer allocator.destroy(record);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const message = try std.json.parseFromSliceLeaky(t.Message, arena.allocator(), raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        const text = display.record(arena.allocator(), message);
        record.* = .{ .arena = arena, .message = message, .revision = revision, .presentation = .{ .text = text, .key = std.hash.Wyhash.hash(0, text) } };
        return record;
    }
    fn retain(record: *Record) *Record {
        _ = record.refs.fetchAdd(1, .monotonic);
        return record;
    }
    fn release(record: *Record) void {
        if (record.refs.fetchSub(1, .acq_rel) == 1) {
            record.arena.deinit();
            allocator.destroy(record);
        }
    }
};

refs: std.atomic.Value(usize) = .init(1),
arena: std.heap.ArenaAllocator,
records: []const *Record,
messages: []const t.Message,
presentations: []const Presentation,
index: std.StringHashMapUnmanaged(*Record),

pub fn create(store: Store, selected: []const u8, previous: ?*Self) !*Self {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const ar = arena.allocator();
    var records: std.ArrayList(*Record) = .empty;
    errdefer for (records.items) |record| record.release();
    if (previous) |old| try records.ensureTotalCapacity(ar, old.records.len);
    var query = try store.db.prepare(if (previous == null) Store.history_query else Store.history_versions_query);
    defer query.close();
    try query.bind(&.{ .{ .text = selected }, .{ .text = selected }, .{ .text = selected } });
    var lookup = try store.db.prepare("SELECT record FROM records WHERE kind='message' AND id=?");
    defer lookup.close();
    var unchanged = previous != null;
    while (try query.step()) {
        const id = query.bytes(1);
        const revision = query.int(2);
        const cached = if (previous) |old| blk: {
            // Appends and edits usually leave the prefix in the same order.
            if (records.items.len < old.records.len) {
                const at = old.records[records.items.len];
                if (u.eq(at.message.id, id)) break :blk at;
            }
            break :blk old.index.get(id);
        } else null;
        const record = if (cached != null and cached.?.revision == revision) cached.?.retain() else blk: {
            var raw = query.bytes(0);
            if (previous != null) {
                _ = u.c.sqlite3_reset(lookup.handle);
                try lookup.bind(&.{.{ .text = id }});
                if (!try lookup.step()) return error.MissingMessage;
                raw = lookup.bytes(0);
            }
            break :blk try Record.create(raw, revision);
        };
        errdefer record.release();
        if (unchanged) unchanged = records.items.len < previous.?.records.len and previous.?.records[records.items.len] == record;
        try records.append(ar, record);
    }
    if (unchanged and records.items.len == previous.?.records.len) {
        for (records.items) |record| record.release();
        arena.deinit();
        return previous.?.retain();
    }
    var index: std.StringHashMapUnmanaged(*Record) = .empty;
    try index.ensureTotalCapacity(ar, @intCast(records.items.len));
    const messages = try ar.alloc(t.Message, records.items.len);
    const presentations = try ar.alloc(Presentation, records.items.len);
    for (records.items, messages, presentations) |record, *message, *presentation| {
        message.* = record.message;
        presentation.* = record.presentation;
        index.putAssumeCapacity(message.id, record);
    }
    const history = try allocator.create(Self);
    history.* = .{ .arena = arena, .records = records.items, .messages = messages, .presentations = presentations, .index = index };
    return history;
}
pub fn retain(history: *Self) *Self {
    _ = history.refs.fetchAdd(1, .monotonic);
    return history;
}
pub fn release(history: *Self) void {
    if (history.refs.fetchSub(1, .acq_rel) == 1) {
        for (history.records) |record| record.release();
        history.arena.deinit();
        allocator.destroy(history);
    }
}
