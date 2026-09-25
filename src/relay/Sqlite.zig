const std = @import("std");
const u = @import("../common.zig");
const c = u.c;
const Sqlite = @This();

handle: *c.sqlite3,
cache: *Cache,

// Fixed-size, connection-owned cache. Checked-out statements are removed so
// nested uses of the same SQL always get independent cursors and bindings.
const Cache = struct {
    slots: [256]?*c.sqlite3_stmt = @splat(null),
};

pub const QueryError = error{
    DatabaseUnavailable,
    DatabaseBusy,
    DatabaseFailure,
    SchemaUnsupported,
};
pub const OpenError = u.Allocator.Error || error{DatabaseUnavailable};
pub const ExecError = error{DatabaseFailure};
pub const PrepareError = error{
    DatabaseBusy,
    DatabaseUnavailable,
    SchemaUnsupported,
};

pub fn open(path: [:0]const u8, readonly: bool) OpenError!Sqlite {
    const cache = try std.heap.c_allocator.create(Cache);
    errdefer std.heap.c_allocator.destroy(cache);
    cache.* = .{};
    var db: ?*c.sqlite3 = null;
    const flags: c_int = if (readonly) c.SQLITE_OPEN_READONLY else c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    const rc = c.sqlite3_open_v2(path, &db, flags | c.SQLITE_OPEN_FULLMUTEX, null);
    if (rc != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return error.DatabaseUnavailable;
    }
    _ = c.sqlite3_busy_timeout(db, 1000);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_LENGTH, 2 * 1024 * 1024);
    return .{ .handle = db.?, .cache = cache };
}
pub fn close(self: Sqlite) void {
    for (self.cache.slots) |stmt| if (stmt) |s| {
        _ = c.sqlite3_finalize(s);
    };
    std.heap.c_allocator.destroy(self.cache);
    _ = c.sqlite3_close(self.handle);
}
pub fn exec(self: Sqlite, sql: [:0]const u8) ExecError!void {
    if (c.sqlite3_exec(self.handle, sql, null, null, null) != c.SQLITE_OK) return error.DatabaseFailure;
}
pub fn prepare(self: Sqlite, sql: [:0]const u8) PrepareError!Statement {
    // Schema/PRAGMA preparation can itself have side effects. Cache only DML.
    const reusable = sql.len <= 4096 and (std.mem.startsWith(u8, sql, "SELECT ") or
        std.mem.startsWith(u8, sql, "INSERT ") or std.mem.startsWith(u8, sql, "UPDATE ") or
        std.mem.startsWith(u8, sql, "DELETE ") or std.mem.startsWith(u8, sql, "WITH "));
    const slot = std.hash.Wyhash.hash(0, sql) % self.cache.slots.len;
    // Preserve FULLMUTEX semantics even when callers share copies of this Db.
    const mutex = c.sqlite3_db_mutex(self.handle);
    c.sqlite3_mutex_enter(mutex);
    defer c.sqlite3_mutex_leave(mutex);
    if (reusable) if (self.cache.slots[slot]) |cached| {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_sql(cached)), sql)) {
            self.cache.slots[slot] = null;
            return .{
                .handle = cached,
                .cache = self.cache,
                .slot = slot,
            };
        }
    };
    var stmt: ?*c.sqlite3_stmt = null;
    switch (c.sqlite3_prepare_v3(
        self.handle,
        sql,
        -1,
        if (reusable) c.SQLITE_PREPARE_PERSISTENT else 0,
        &stmt,
        null,
    )) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.DatabaseBusy,
        c.SQLITE_PERM, c.SQLITE_AUTH, c.SQLITE_CANTOPEN => return error.DatabaseUnavailable,
        else => return error.SchemaUnsupported,
    }
    return .{
        .handle = stmt.?,
        .cache = if (reusable) self.cache else null,
        .slot = slot,
    };
}
pub fn scalar(self: Sqlite, sql: [:0]const u8) QueryError!i64 {
    const s = try self.prepare(sql);
    defer s.close();
    if (!try s.step()) return 0;
    return s.int(0);
}
pub const Parameter = union(enum) {
    text: []const u8,
    blob: []const u8,
    int: i64,
    null_value,
};
pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    cache: ?*Cache = null,
    slot: usize = 0,
    pub fn close(s: Statement) void {
        const cache = s.cache orelse {
            _ = c.sqlite3_finalize(s.handle);
            return;
        };
        const mutex = c.sqlite3_db_mutex(c.sqlite3_db_handle(s.handle));
        c.sqlite3_mutex_enter(mutex);
        defer c.sqlite3_mutex_leave(mutex);
        // End unfinished reads and release borrowed SQLITE_STATIC data before
        // the caller frees its arena. reset() alone retains all bindings.
        const rc = c.sqlite3_reset(s.handle);
        _ = c.sqlite3_clear_bindings(s.handle);
        if (rc != c.SQLITE_OK) {
            _ = c.sqlite3_finalize(s.handle);
            return;
        }
        if (cache.slots[s.slot]) |old| _ = c.sqlite3_finalize(old);
        cache.slots[s.slot] = s.handle;
    }
    pub const BindError = error{DatabaseFailure};
    /// Borrow text and blob bytes until the statement is closed or rebound.
    pub fn bind(s: Statement, values: []const Parameter) BindError!void {
        for (values, 1..) |v, i| {
            const rc = switch (v) {
                .text => |t| c.sqlite3_bind_text(
                    s.handle,
                    @intCast(i),
                    t.ptr,
                    @intCast(t.len),
                    null,
                ),
                .blob => |b| c.sqlite3_bind_blob(
                    s.handle,
                    @intCast(i),
                    b.ptr,
                    @intCast(b.len),
                    null,
                ),
                .int => |n| c.sqlite3_bind_int64(s.handle, @intCast(i), n),
                .null_value => c.sqlite3_bind_null(s.handle, @intCast(i)),
            };
            if (rc != c.SQLITE_OK) return error.DatabaseFailure;
        }
    }
    pub const StepError = error{ DatabaseBusy, DatabaseFailure };
    pub fn step(s: Statement) StepError!bool {
        return switch (c.sqlite3_step(s.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
            else => error.DatabaseFailure,
        };
    }
    pub fn int(s: Statement, i: c_int) i64 {
        return c.sqlite3_column_int64(s.handle, i);
    }
    /// Borrow the current column bytes until the next step or close.
    pub fn bytes(s: Statement, i: c_int) []const u8 {
        const p: [*c]const u8 = @ptrCast(c.sqlite3_column_blob(s.handle, i));
        return if (p == null) "" else p[0..@intCast(c.sqlite3_column_bytes(s.handle, i))];
    }
    /// The caller owns the returned copy of the current column.
    pub fn text(s: Statement, a: u.Allocator, i: c_int) u.Allocator.Error![]const u8 {
        return a.dupe(u8, s.bytes(i));
    }
};

test "cached statements release bindings and unfinished cursors and allow nested queries" {
    const db = try open(":memory:", false);
    defer db.close();
    const query = "SELECT ? UNION ALL SELECT 'second'";
    var first = try db.prepare(query);
    const handle = first.handle;
    const borrowed = try std.testing.allocator.dupe(u8, "borrowed");
    try first.bind(&.{.{ .text = borrowed }});
    try std.testing.expect(try first.step());
    first.close(); // Intentionally leave a row unread.
    std.testing.allocator.free(borrowed);

    first = try db.prepare(query);
    defer first.close();
    try std.testing.expectEqual(handle, first.handle);
    try std.testing.expect(try first.step());
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(first.handle, 0));
    const nested = try db.prepare(query);
    defer nested.close();
    try std.testing.expect(first.handle != nested.handle);
    try nested.bind(&.{.{ .text = "nested" }});
    try std.testing.expect(try nested.step());
    try std.testing.expectEqualStrings("nested", nested.bytes(0));
    try std.testing.expect(try first.step());
    try std.testing.expectEqualStrings("second", first.bytes(0));
}

test "cache survives schema changes and failed writes and stays bounded" {
    const db = try open(":memory:", false);
    defer db.close();
    try db.exec("CREATE TABLE example(id INTEGER PRIMARY KEY)");
    var insert = try db.prepare("INSERT INTO example VALUES(?)");
    try insert.bind(&.{.{ .int = 1 }});
    try std.testing.expect(!try insert.step());
    insert.close();
    insert = try db.prepare("INSERT INTO example VALUES(?)");
    try insert.bind(&.{.{ .int = 1 }});
    try std.testing.expectError(error.DatabaseFailure, insert.step());
    insert.close();
    insert = try db.prepare("INSERT INTO example VALUES(?)");
    try insert.bind(&.{.{ .int = 2 }});
    try std.testing.expect(!try insert.step());
    insert.close();
    try std.testing.expectEqual(@as(i64, 2), try db.scalar("SELECT count(*) FROM example"));
    try db.exec("ALTER TABLE example ADD COLUMN value TEXT");
    try std.testing.expectEqual(@as(i64, 2), try db.scalar("SELECT count(*) FROM example"));
    var buf: [64]u8 = undefined;
    for (0..1024) |i| {
        const sql = try std.fmt.bufPrintZ(&buf, "SELECT {d}", .{i});
        try std.testing.expectEqual(@as(i64, @intCast(i)), try db.scalar(sql));
    }
    var count: usize = 0;
    var stmt = c.sqlite3_next_stmt(db.handle, null);
    while (stmt != null) : (stmt = c.sqlite3_next_stmt(db.handle, stmt)) count += 1;
    try std.testing.expect(count <= db.cache.slots.len);
}

test "failed partial bindings cannot leak into a later cached query or connection" {
    const db = try open(":memory:", false);
    defer db.close();
    const other = try open(":memory:", false);
    defer other.close();
    const query = "SELECT ?";
    const secret = try std.testing.allocator.dupe(u8, "private\x00blob");
    var statement = try db.prepare(query);
    // The first parameter binds borrowed memory before the second fails.
    try std.testing.expectError(
        error.DatabaseFailure,
        statement.bind(&.{ .{ .blob = secret }, .{ .int = 2 } }),
    );
    statement.close();
    std.testing.allocator.free(secret);
    statement = try db.prepare(query);
    defer statement.close();
    try std.testing.expect(try statement.step());
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement.handle, 0));
    const independent = try other.prepare(query);
    defer independent.close();
    try independent.bind(&.{.{ .text = "other connection" }});
    try std.testing.expect(try independent.step());
    try std.testing.expectEqualStrings("other connection", independent.bytes(0));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement.handle, 0));
}
