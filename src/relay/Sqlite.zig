const std = @import("std");
const u = @import("../common.zig");
const c = u.c;
const Self = @This();
handle: *c.sqlite3,
pub fn open(path: [:0]const u8, readonly: bool) !Self {
    var db: ?*c.sqlite3 = null;
    const flags: c_int = if (readonly) c.SQLITE_OPEN_READONLY else c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    const rc = c.sqlite3_open_v2(path, &db, flags | c.SQLITE_OPEN_FULLMUTEX, null);
    if (rc != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return error.DatabaseUnavailable;
    }
    _ = c.sqlite3_busy_timeout(db, 1000);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_LENGTH, 2 * 1024 * 1024);
    return .{ .handle = db.? };
}
pub fn close(self: Self) void {
    _ = c.sqlite3_close(self.handle);
}
pub fn exec(self: Self, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(self.handle, sql, null, null, null) != c.SQLITE_OK) return error.DatabaseFailure;
}
pub fn prepare(self: Self, sql: [:0]const u8) !Statement {
    var stmt: ?*c.sqlite3_stmt = null;
    switch (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null)) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.DatabaseBusy,
        c.SQLITE_PERM, c.SQLITE_AUTH, c.SQLITE_CANTOPEN => return error.DatabaseUnavailable,
        else => return error.SchemaUnsupported,
    }
    return .{ .handle = stmt.? };
}
pub fn scalar(self: Self, sql: [:0]const u8) !i64 {
    var s = try self.prepare(sql);
    defer s.close();
    if (!try s.step()) return 0;
    return s.int(0);
}
pub const Value = union(enum) { text: []const u8, blob: []const u8, int: i64, null_value };
pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    pub fn close(s: Statement) void {
        _ = c.sqlite3_finalize(s.handle);
    }
    pub fn bind(s: Statement, values: []const Value) !void {
        for (values, 1..) |v, i| {
            const rc = switch (v) {
                .text => |t| c.sqlite3_bind_text(s.handle, @intCast(i), t.ptr, @intCast(t.len), null),
                .blob => |b| c.sqlite3_bind_blob(s.handle, @intCast(i), b.ptr, @intCast(b.len), null),
                .int => |n| c.sqlite3_bind_int64(s.handle, @intCast(i), n),
                .null_value => c.sqlite3_bind_null(s.handle, @intCast(i)),
            };
            if (rc != c.SQLITE_OK) return error.DatabaseFailure;
        }
    }
    pub fn step(s: Statement) !bool {
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
    pub fn bytes(s: Statement, i: c_int) []const u8 {
        const p: [*c]const u8 = @ptrCast(c.sqlite3_column_blob(s.handle, i));
        return if (p == null) "" else p[0..@intCast(c.sqlite3_column_bytes(s.handle, i))];
    }
    pub fn text(s: Statement, a: u.Allocator, i: c_int) ![]const u8 {
        return a.dupe(u8, s.bytes(i));
    }
};
