//! Fault-controlled adapter for the real journal and server. Only synthetic DBs
//! passed explicitly to fake-relay are writable. No Apple account is used.
pub const Source = @import("MessagesDb.zig");
pub const open = Source.open;
const std = @import("std");
const u = @import("../../common.zig");
const Db = @import("../Sqlite.zig");
const Journal = @import("../Journal.zig");
pub fn dispatch(a: u.Allocator, path: [:0]const u8, route: Journal.Route, text: []const u8) !void {
    if (u.eq(text, "[fake:stall]")) {
        var delay: u.c.struct_timespec = .{ .tv_sec = 3, .tv_nsec = 0 };
        _ = u.c.nanosleep(&delay, null);
    }
    if (u.eq(text, "[fake:reject]")) return error.Rejected;
    if (u.eq(text, "[fake:unknown]")) return error.Uncertain;
    const db = try Db.open(path, false);
    defer db.close();
    var guard = try db.prepare("SELECT value FROM zimbr_fixture WHERE key='synthetic'");
    defer guard.close();
    if (!try guard.step() or !u.eq(guard.bytes(0), "yes")) return error.NotAFixture;
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    var q = try db.prepare(if (u.eq(route.mode, "chat")) "SELECT ROWID FROM chat WHERE guid=?" else "SELECT c.ROWID FROM chat c JOIN chat_handle_join j ON j.chat_id=c.ROWID JOIN handle h ON h.ROWID=j.handle_id WHERE h.id=? AND c.service_name='iMessage' AND (SELECT count(*) FROM chat_handle_join WHERE chat_id=c.ROWID)=1 LIMIT 1");
    defer q.close();
    try q.bind(&.{.{ .text = route.destination }});
    var chat: i64 = 0;
    if (try q.step()) chat = q.int(0) else {
        if (!u.eq(route.mode, "direct")) return error.Rejected;
        var h = try db.prepare("INSERT INTO handle(id,service) VALUES(?,'iMessage')");
        defer h.close();
        try h.bind(&.{.{ .text = route.destination }});
        _ = try h.step();
        const hid = u.c.sqlite3_last_insert_rowid(db.handle);
        var c = try db.prepare("INSERT INTO chat(guid,service_name,display_name) VALUES(?,'iMessage','')");
        defer c.close();
        try c.bind(&.{.{ .text = try std.fmt.allocPrint(a, "iMessage;-;{s}", .{route.destination}) }});
        _ = try c.step();
        chat = u.c.sqlite3_last_insert_rowid(db.handle);
        var j = try db.prepare("INSERT INTO chat_handle_join VALUES(?,?)");
        defer j.close();
        try j.bind(&.{ .{ .int = chat }, .{ .int = hid } });
        _ = try j.step();
    }
    var m = try db.prepare("INSERT INTO message(guid,date,is_from_me,service,text,is_sent,is_finished,is_delivered) VALUES(?,?,1,'iMessage',?,1,1,1)");
    defer m.close();
    try m.bind(&.{ .{ .text = try u.id(a) }, .{ .int = (u.now() - 978307200000) * 1000000 }, .{ .text = text } });
    _ = try m.step();
    const mid = u.c.sqlite3_last_insert_rowid(db.handle);
    var join = try db.prepare("INSERT INTO chat_message_join(chat_id,message_id) VALUES(?,?)");
    defer join.close();
    try join.bind(&.{ .{ .int = chat }, .{ .int = mid } });
    _ = try join.step();
    try db.exec("COMMIT");
}
