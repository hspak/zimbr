//! Immutable, independently owned message records. Updating one record never
//! reparses unchanged text or pins an obsolete snapshot's entire arena.
const std = @import("std");
const builtin = @import("builtin");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
const Store = @import("Store.zig");
const display = @import("display.zig");
const content = @import("content.zig");
const MessageHistory = @This();
const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

refs: std.atomic.Value(usize) = .init(1),
arena: std.heap.ArenaAllocator,
records: []const *Record,
messages: []const t.Message,
presentations: []const Presentation,
index: std.StringHashMapUnmanaged(*Record),

pub const Presentation = struct {
    text: []const u8,
    key: u64,
    blocks: []const content.Block = &.{},
};

const Record = struct {
    refs: std.atomic.Value(usize) = .init(1),
    arena: std.heap.ArenaAllocator,
    message: t.Message,
    presentation: Presentation,
    revision: i64,
    enrichment_serial: i64,

    fn create(raw: []const u8, revision: i64, serial: i64) !*Record {
        const record = try allocator.create(Record);
        errdefer allocator.destroy(record);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const message = try std.json.parseFromSliceLeaky(
            t.Message,
            arena.allocator(),
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        const text = display.record(arena.allocator(), message);
        const blocks = try content.prepare(arena.allocator(), message);
        record.* = .{
            .arena = arena,
            .message = message,
            .revision = revision,
            .enrichment_serial = serial,
            .presentation = .{
                .text = text,
                .key = std.hash.Wyhash.hash(0, if (blocks.len == 0) text else raw),
                .blocks = blocks,
            },
        };
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

pub const CreateError = std.json.ParseError(std.json.Scanner) || error{
    DatabaseBusy,
    DatabaseFailure,
    DatabaseUnavailable,
    MissingMessage,
    SchemaUnsupported,
};

pub fn create(store: Store, selected: []const u8, previous: ?*MessageHistory) CreateError!*MessageHistory {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const ar = arena.allocator();
    var records: std.ArrayList(*Record) = .empty;
    errdefer for (records.items) |record| record.release();
    if (previous) |old| try records.ensureTotalCapacity(ar, old.records.len);
    const query = try store.db.prepare(if (previous == null) Store.history_query else Store.history_versions_query);
    defer query.close();
    try query.bind(&.{.{ .text = selected }});
    const lookup = try store.db.prepare(Store.message_query);
    defer lookup.close();
    var unchanged = previous != null;
    while (try query.step()) {
        const id = query.bytes(1);
        const revision = query.int(2);
        const cached = if (previous) |old| cached: {
            // Appends and edits usually leave the prefix in the same order.
            if (records.items.len < old.records.len) {
                const at = old.records[records.items.len];
                if (u.eq(at.message.id, id)) break :cached at;
            }
            break :cached old.index.get(id);
        } else null;
        const record = if (cached != null and cached.?.revision == revision and cached.?.enrichment_serial == query.int(4)) cached.?.retain() else record: {
            var raw = query.bytes(0);
            if (previous != null) {
                _ = u.c.sqlite3_reset(lookup.handle);
                try lookup.bind(&.{.{ .text = id }});
                if (!try lookup.step()) return error.MissingMessage;
                raw = lookup.bytes(0);
            }
            break :record try Record.create(raw, revision, query.int(4));
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
    const history = try allocator.create(MessageHistory);
    history.* = .{
        .arena = arena,
        .records = records.items,
        .messages = messages,
        .presentations = presentations,
        .index = index,
    };
    return history;
}
pub fn retain(history: *MessageHistory) *MessageHistory {
    _ = history.refs.fetchAdd(1, .monotonic);
    return history;
}
pub fn release(history: *MessageHistory) void {
    if (history.refs.fetchSub(1, .acq_rel) == 1) {
        for (history.records) |record| record.release();
        history.arena.deinit();
        allocator.destroy(history);
    }
}
