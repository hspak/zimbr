const std = @import("std");
const u = @import("common.zig");
const t = @import("protocol/types.zig");
const Journal = @import("relay/Journal.zig");
const Core = @import("relay/Core.zig");
const Server = @import("relay/Server.zig");
const Adapter = if (@import("options").fake) @import("relay/adapter/fake.zig") else @import("relay/adapter/macos.zig");
const fake = @import("options").fake;
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("relay: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    var data: []const u8 = try std.fmt.allocPrint(a, "{s}/Library/Application Support/Zimbr", .{home});
    var source: []const u8 = try std.fmt.allocPrint(a, "{s}/Library/Messages/chat.db", .{home});
    var source_explicit = false;
    var port: u16 = 8731;
    var event_limit: i64 = 100000;
    var check_automation = false;
    var read_only = false;
    const cmd = if (args.len > 1) args[1] else "help";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (u.eq(args[i], "--read-only")) {
            read_only = true;
            continue;
        }
        if (u.eq(args[i], "--check-automation")) {
            check_automation = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        if (u.eq(args[i], "--data-dir")) data = args[i + 1] else if (u.eq(args[i], "--messages-db")) {
            source = args[i + 1];
            source_explicit = true;
        } else if (u.eq(args[i], "--port")) {
            port = try std.fmt.parseInt(u16, args[i + 1], 10);
            if (port == 0) return error.InvalidArguments;
        } else if (u.eq(args[i], "--event-limit")) {
            event_limit = try std.fmt.parseInt(i64, args[i + 1], 10);
            if (event_limit < 100) return error.InvalidArguments;
        } else return error.InvalidArguments;
        i += 1;
    }
    if (fake and (!source_explicit or !std.fs.path.isAbsolute(source))) return error.ExplicitFixturePathRequired;
    const source_path = try a.dupeZ(u8, source);
    const token_path = try std.fmt.allocPrintSentinel(a, "{s}/token", .{data}, 0);
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/relay.db", .{data}, 0);
    if (u.eq(cmd, "setup") or u.eq(cmd, "rotate-token")) {
        _ = u.c.umask(0o077);
        try std.Io.Dir.cwd().createDirPath(init.io, data);
        const dz = try a.dupeZ(u8, data);
        if (u.c.chmod(dz, 0o700) != 0) return error.PermissionRequired;
        var random: [32]u8 = undefined;
        if (u.c.zr_random(&random, random.len) != 0) return error.RandomUnavailable;
        const token = std.fmt.bytesToHex(random, .lower);
        if (u.eq(cmd, "rotate-token")) {
            const tmp = try std.fmt.allocPrintSentinel(a, "{s}/token-{s}", .{ data, try u.id(a) }, 0);
            if (u.c.zr_secure_file(tmp, &token, token.len, 0) != 0) return error.TokenWriteFailed;
            if (u.c.rename(tmp, token_path) != 0) {
                _ = u.c.unlink(tmp);
                return error.TokenWriteFailed;
            }
        } else if (u.c.zr_secure_file(token_path, &token, token.len, 0) != 0) {
            var b: [66]u8 = undefined;
            if (u.c.zr_read_secret(token_path, &b, b.len) < 64) return error.TokenWriteFailed;
        }
        const journal = try Journal.open(db_path);
        journal.close();
        try printJson(a, .{ .configured = true, .token_rotated = u.eq(cmd, "rotate-token") });
        return;
    }
    if (u.eq(cmd, "doctor") or u.eq(cmd, "probe")) {
        const opened = Adapter.open(a, source_path);
        if (opened) |adapter| {
            defer adapter.close();
            var decoded: usize = 0;
            var unsupported: usize = 0;
            var pending: usize = 0;
            for (try adapter.rowsFor(a, .recent, try adapter.high(), 0)) |row| {
                if (try adapter.message(a, row)) |m| {
                    if (m.value.decoding == .plain or m.value.decoding == .attributed) decoded += 1 else unsupported += 1;
                    if (m.pending) pending += 1;
                }
            }
            var token_buf: [66]u8 = undefined;
            var automation_error: ?[]const u8 = null;
            const automation: ?bool = if (check_automation) blk: {
                if (fake) break :blk true;
                Adapter.automation(a, "check", "", "") catch |err| {
                    automation_error = Adapter.automationReason(err);
                    break :blk false;
                };
                break :blk true;
            } else null;
            try printJson(a, .{ .database_readable = true, .schema_supported = true, .recent_decoded = decoded, .recent_other = unsupported, .pending = pending, .token_configured = u.c.zr_read_secret(token_path, &token_buf, token_buf.len) == 64, .automation_ready = automation, .automation_error = automation_error, .real_send_verified = false });
        } else |err| {
            try printJson(a, .{ .database_readable = false, .error_code = @errorName(err), .automation_ready = false });
            std.process.exit(1);
        }
        return;
    }
    if (!u.eq(cmd, "serve")) {
        const help = "Usage: relay setup|doctor|probe|serve|rotate-token [--data-dir PATH] [--messages-db PATH] [--port 8731] [--event-limit 100000] [--check-automation] [--read-only]\n";
        _ = u.c.write(1, help.ptr, help.len);
        return;
    }
    _ = u.c.umask(0o077);
    var tok: [66]u8 = undefined;
    if (u.c.zr_read_secret(token_path, &tok, tok.len) != 64) return error.RunSetupFirst;
    if (fake) {
        const db = try @import("relay/Sqlite.zig").open(source_path, true);
        defer db.close();
        if (try db.scalar("SELECT count(*) FROM zimbr_fixture WHERE key='synthetic' AND value='yes'") != 1) return error.NotAFixture;
    }
    const lock_path = try std.fmt.allocPrintSentinel(a, "{s}/relay.lock", .{data}, 0);
    const lock_fd = u.c.zr_lock(lock_path);
    if (lock_fd < 0) return error.AlreadyRunning;
    // Retain the lock for the lifetime of this process, including its workers.
    const core = try a.create(Core);
    core.* = .{ .io = init.io, .journal = try Journal.open(db_path), .source_path = source_path, .event_limit = event_limit, .automation_ready = if (read_only) false else fake, .automation_error = if (read_only) "read_only_mode" else "automation_unverified" };
    core.journal.changed = .{ .signal = &core.changed, .io = init.io };
    try core.journal.recover(a);
    const ingestion = try std.Thread.spawn(.{}, Core.ingestLoop, .{core});
    ingestion.detach();
    if (!read_only) {
        const sender = try std.Thread.spawn(.{}, Core.senderLoop, .{core});
        sender.detach();
    }
    var server: Server = .{ .core = core, .token_path = token_path, .port = port };
    std.debug.print("relay: listening on 127.0.0.1:{d}\n", .{port});
    try server.run();
}
fn printJson(a: u.Allocator, value: anytype) !void {
    const bytes = try u.json(a, value);
    _ = u.c.write(1, bytes.ptr, bytes.len);
    _ = u.c.write(1, "\n", 1);
}
test {
    _ = @import("protocol/types.zig");
    _ = @import("relay/adapter/decoder.zig");
    _ = @import("relay/Journal.zig");
}
