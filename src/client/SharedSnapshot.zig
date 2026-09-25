//! Immutable records shared between the worker and UI. Metadata and drafts
//! can publish without copying/reparsing the selected conversation's history.
const std = @import("std");
const builtin = @import("builtin");
const Store = @import("Store.zig");
const MessageHistory = @import("MessageHistory.zig");
const SharedSnapshot = @This();

refs: std.atomic.Value(usize) = .init(1),
arena: std.heap.ArenaAllocator,
snapshot: Store.Snapshot,
generation: u64,
cached_messages: i64,
pending_sends: i64,
history: *MessageHistory,

// Connection metadata belongs to each published View's arena, never the shared
// history allocation. Reconnect/renewal can update it without replacing records.
pub const Transport = struct {
    failure: []const u8 = "none",
    curl_code: c_int = 0,
    verify_result: c_long = 0,
    detail: []const u8 = "",
    fingerprint: []const u8 = "",
    expires: []const u8 = "",
    expiring: bool = false,
};
const a = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;

pub const CreateError = std.json.ParseError(std.json.Scanner) || error{
    DatabaseBusy,
    DatabaseFailure,
    DatabaseUnavailable,
    MissingMessage,
    SchemaUnsupported,
};

pub fn create(store: Store, selected: []const u8, generation: u64, previous: ?*SharedSnapshot) CreateError!*SharedSnapshot {
    const s = try a.create(SharedSnapshot);
    errdefer a.destroy(s);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const epoch = try store.get(arena.allocator(), "epoch");
    const reusable = if (previous) |old| std.mem.eql(u8, old.snapshot.selected, selected) and std.mem.eql(
        u8,
        old.snapshot.epoch,
        epoch,
    ) else false;
    const history = try MessageHistory.create(
        store,
        selected,
        if (reusable) previous.?.history else null,
    );
    errdefer history.release();
    const snapshot = try store.snapshotWithMessages(arena.allocator(), selected, history.messages);
    s.* = .{
        .arena = arena,
        .snapshot = snapshot,
        .generation = generation,
        .history = history,
        .cached_messages = try store.db.scalar("SELECT count(*) FROM records WHERE kind='message'"),
        .pending_sends = try store.db.scalar("SELECT count(*) FROM outbox WHERE state NOT IN ('delivered','failed')"),
    };
    return s;
}
pub fn retain(s: *SharedSnapshot) *SharedSnapshot {
    _ = s.refs.fetchAdd(1, .monotonic);
    return s;
}
pub fn release(s: *SharedSnapshot) void {
    if (s.refs.fetchSub(1, .acq_rel) == 1) {
        s.history.release();
        s.arena.deinit();
        a.destroy(s);
    }
}
