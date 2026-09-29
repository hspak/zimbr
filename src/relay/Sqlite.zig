const std = @import("std");
const u = @import("../common.zig");
const c = u.c;
const Sqlite = @This();

handle: *c.sqlite3,
cache: *Cache,

const max_value_bytes = 2 * 1024 * 1024;
const max_sql_bytes = 64 * 1024;

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
    return openFlags(path, readonly, c.SQLITE_OPEN_FULLMUTEX);
}

/// Assume this connection and its statements are used by at most one thread at
/// a time. Other connections may still access the database concurrently.
pub fn openConfined(path: [:0]const u8, readonly: bool) OpenError!Sqlite {
    return openFlags(path, readonly, c.SQLITE_OPEN_NOMUTEX);
}

fn openFlags(path: [:0]const u8, readonly: bool, threading: c_int) OpenError!Sqlite {
    const cache = try std.heap.c_allocator.create(Cache);
    errdefer std.heap.c_allocator.destroy(cache);
    cache.* = .{};
    var db: ?*c.sqlite3 = null;
    const flags: c_int = if (readonly) c.SQLITE_OPEN_READONLY else c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    const rc = c.sqlite3_open_v2(path, &db, flags | threading, null);
    if (rc != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return error.DatabaseUnavailable;
    }
    errdefer _ = c.sqlite3_close(db);
    // Bound the engine as well as callers. Zimbr never attaches databases or
    // needs schema text to invoke application-defined functions.
    if (c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_DEFENSIVE, @as(c_int, 1), @as(?*c_int, null)) != c.SQLITE_OK or
        c.sqlite3_db_config(db, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, @as(c_int, 0), @as(?*c_int, null)) != c.SQLITE_OK)
        return error.DatabaseUnavailable;
    _ = c.sqlite3_busy_timeout(db, 1000);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_LENGTH, max_value_bytes);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_SQL_LENGTH, max_sql_bytes);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_ATTACHED, 0);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_VARIABLE_NUMBER, 128);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_EXPR_DEPTH, 100);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_TRIGGER_DEPTH, 16);
    return .{ .handle = db.?, .cache = cache };
}
pub fn close(self: Sqlite) void {
    for (self.cache.slots) |stmt| if (stmt) |s| {
        _ = c.sqlite3_finalize(s);
    };
    std.heap.c_allocator.destroy(self.cache);
    _ = c.sqlite3_close(self.handle);
}
/// Execute trusted application SQL. Bind all external values through Statement.
pub fn exec(self: Sqlite, sql: [:0]const u8) ExecError!void {
    if (sql.len > max_sql_bytes or std.mem.indexOfScalar(u8, sql, 0) != null)
        return error.DatabaseFailure;
    if (c.sqlite3_exec(self.handle, sql, null, null, null) != c.SQLITE_OK) return error.DatabaseFailure;
}
/// Prepare exactly one trusted statement. User input belongs in bind parameters.
pub fn prepare(self: Sqlite, sql: [:0]const u8) PrepareError!Statement {
    if (sql.len > max_sql_bytes or std.mem.indexOfScalar(u8, sql, 0) != null)
        return error.SchemaUnsupported;
    // Schema/PRAGMA preparation can itself have side effects. Cache only DML.
    const reusable = sql.len <= 4096 and (std.mem.startsWith(u8, sql, "SELECT ") or
        std.mem.startsWith(u8, sql, "INSERT ") or std.mem.startsWith(u8, sql, "UPDATE ") or
        std.mem.startsWith(u8, sql, "DELETE ") or std.mem.startsWith(u8, sql, "WITH "));
    const slot = std.hash.Wyhash.hash(0, sql) % self.cache.slots.len;
    // Preserve FULLMUTEX semantics even when callers share copies of this Db.
    // SQLite treats the null mutex on confined connections as a no-op.
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
    var tail: [*c]const u8 = null;
    switch (c.sqlite3_prepare_v3(
        self.handle,
        sql,
        -1,
        if (reusable) c.SQLITE_PREPARE_PERSISTENT else 0,
        &stmt,
        &tail,
    )) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.DatabaseBusy,
        c.SQLITE_PERM, c.SQLITE_AUTH, c.SQLITE_CANTOPEN => return error.DatabaseUnavailable,
        else => return error.SchemaUnsupported,
    }
    const prepared = stmt orelse return error.SchemaUnsupported;
    errdefer _ = c.sqlite3_finalize(prepared);
    if (std.mem.trim(u8, std.mem.span(tail), " \t\r\n").len != 0)
        return error.SchemaUnsupported;
    return .{
        .handle = prepared,
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
    /// Replace all bindings, borrowing text and blob bytes until close or rebind.
    /// On error every parameter is cleared; incomplete parameter sets are rejected.
    pub fn bind(s: Statement, values: []const Parameter) BindError!void {
        // Validate before narrowing lengths to SQLite's signed C integers or
        // borrowing any new memory. A failed rebind must not retain old inputs.
        _ = c.sqlite3_clear_bindings(s.handle);
        if (values.len != c.sqlite3_bind_parameter_count(s.handle)) return error.DatabaseFailure;
        for (values) |v| switch (v) {
            .text, .blob => |input| if (input.len > max_value_bytes) return error.DatabaseFailure,
            .int, .null_value => {},
        };
        errdefer _ = c.sqlite3_clear_bindings(s.handle);
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
    try std.testing.expect(c.sqlite3_db_mutex(db.handle) != null);
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
    // An invalid parameter set must not retain borrowed memory.
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

test "database connections reject attachment and schema tampering" {
    const db = try open(":memory:", false);
    defer db.close();
    try db.exec("CREATE TABLE keep(id INTEGER PRIMARY KEY)");
    try std.testing.expectError(error.DatabaseFailure, db.exec("ATTACH ':memory:' AS other"));
    try db.exec("PRAGMA writable_schema=ON");
    try std.testing.expectError(error.DatabaseFailure, db.exec("DELETE FROM sqlite_schema"));
    try std.testing.expectEqual(@as(i64, 1), try db.scalar("SELECT count(*) FROM sqlite_schema WHERE name='keep'"));
    try std.testing.expectEqual(@as(i64, 0), try db.scalar("PRAGMA trusted_schema"));
}

test "prepared statements reject trailing SQL and embedded NULs" {
    const db = try open(":memory:", false);
    defer db.close();
    for ([_][:0]const u8{
        "SELECT 1; SELECT 2",
        "SELECT 1\x00; SELECT 2",
        "",
        "-- comment only",
    }) |sql| {
        if (db.prepare(sql)) |statement| {
            statement.close();
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.SchemaUnsupported, err);
    }
    try std.testing.expectEqual(@as(i64, 1), try db.scalar("SELECT 1; \n\t"));
}

test "rejected rebindings clear secrets and bound values remain literal" {
    const db = try open(":memory:", false);
    defer db.close();
    const statement = try db.prepare("SELECT ?, ?");
    defer statement.close();
    const literal = "'); DROP TABLE example;--\x00hidden\xff";
    try statement.bind(&.{ .{ .text = literal }, .{ .blob = literal } });
    try std.testing.expect(try statement.step());
    try std.testing.expectEqualStrings(literal, statement.bytes(0));
    try std.testing.expectEqualStrings(literal, statement.bytes(1));
    _ = c.sqlite3_reset(statement.handle);
    try std.testing.expectError(error.DatabaseFailure, statement.bind(&.{.{ .text = "replacement" }}));
    try std.testing.expect(try statement.step());
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement.handle, 0));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement.handle, 1));
    _ = c.sqlite3_reset(statement.handle);
    const large = try std.testing.allocator.alloc(u8, max_value_bytes + 1);
    defer std.testing.allocator.free(large);
    try std.testing.expectError(error.DatabaseFailure, statement.bind(&.{ .{ .text = "secret" }, .{ .blob = large } }));
    try std.testing.expect(try statement.step());
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement.handle, 0));
}
