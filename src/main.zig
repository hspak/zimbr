const std = @import("std");
const u = @import("common.zig");
const t = @import("protocol/types.zig");
const Journal = @import("relay/Journal.zig");
const Core = @import("relay/Core.zig");
const Server = @import("relay/Server.zig");
const Tls = @import("relay/Tls.zig");
const Contacts = @import("relay/adapter/Contacts.zig");
const Assets = @import("relay/Assets.zig");
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
    // Private bounded child mode: no HOME, TLS config, Contacts enumeration or
    // permission request. Its exit status carries only the public OS decision.
    if (args.len == 2 and u.eq(args[1], "contacts-permission-status")) Contacts.permissionProbeExit();
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    var data: []const u8 = try std.fmt.allocPrint(a, "{s}/Library/Application Support/Zimbr", .{home});
    var source: []const u8 = try std.fmt.allocPrint(a, "{s}/Library/Messages/chat.db", .{home});
    var source_explicit = false;
    var config_path: ?[]const u8 = null;
    var event_limit: i64 = 100000;
    var check_automation = false;
    var request_contacts = false;
    var enrichment_probe = false;
    var read_only = false;
    const cmd = if (args.len > 1) args[1] else "help";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (u.eq(args[i], "--enrichment")) {
            enrichment_probe = true;
            continue;
        }
        if (u.eq(args[i], "--request-contacts")) {
            request_contacts = true;
            continue;
        }
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
        } else if (u.eq(args[i], "--config")) {
            config_path = args[i + 1];
        } else if (u.eq(args[i], "--event-limit")) {
            event_limit = try std.fmt.parseInt(i64, args[i + 1], 10);
            if (event_limit < 100) return error.InvalidArguments;
        } else return error.InvalidArguments;
        i += 1;
    }
    if (request_contacts and !u.eq(cmd, "doctor")) return error.InvalidArguments;
    if (enrichment_probe and !u.eq(cmd, "doctor") and !u.eq(cmd, "probe")) return error.InvalidArguments;
    if (fake and (!source_explicit or !std.fs.path.isAbsolute(source))) return error.ExplicitFixturePathRequired;
    const source_path = try a.dupeZ(u8, source);
    const tls_path = config_path orelse try std.fmt.allocPrint(a, "{s}/relay.json", .{data});
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/relay.db", .{data}, 0);
    if (u.eq(cmd, "setup")) {
        _ = u.c.umask(0o077);
        try std.Io.Dir.cwd().createDirPath(init.io, data);
        const dz = try a.dupeZ(u8, data);
        if (u.c.chmod(dz, 0o700) != 0) return error.PermissionRequired;
        const journal = try Journal.open(db_path);
        journal.close();
        try printJson(a, .{ .state_initialized = true });
        return;
    }
    if (u.eq(cmd, "check-config")) {
        const tls = try Tls.load(a, tls_path);
        defer tls.deinit();
        try printJson(a, try tls.info(a));
        return;
    }
    if (u.eq(cmd, "doctor") or u.eq(cmd, "probe")) {
        if (request_contacts) _ = try Contacts.requestPermission();
        const tls = try Tls.load(a, tls_path);
        defer tls.deinit();
        const tls_info = try tls.info(a);
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
            var automation_error: ?[]const u8 = null;
            const automation: ?bool = if (check_automation) blk: {
                if (fake) break :blk true;
                Adapter.automation(a, "check", "", "") catch |err| {
                    automation_error = Adapter.automationReason(err);
                    break :blk false;
                };
                break :blk true;
            } else null;
            const enrichment = if (enrichment_probe) try @import("relay/adapter/enrichment_probe.zig").run(a, adapter) else null;
            try printJson(a, .{ .database_readable = true, .schema_supported = true, .source_features = adapter.features, .enrichment_probe = enrichment, .recent_decoded = decoded, .recent_other = unsupported, .pending = pending, .tls = tls_info, .automation_ready = automation, .automation_error = automation_error, .real_send_verified = false, .contacts_permission = Contacts.permission(), .contacts_phone_region = tls.config.contacts_phone_region, .suggested_contacts_phone_region = try Contacts.suggestedRegion(a) });
        } else |err| {
            try printJson(a, .{ .database_readable = false, .tls = tls_info, .error_code = @errorName(err), .automation_ready = false, .contacts_permission = Contacts.permission() });
            std.process.exit(1);
        }
        return;
    }
    if (!u.eq(cmd, "serve")) {
        const help = "Usage: relay setup|check-config|doctor|probe|serve [--data-dir PATH] [--messages-db PATH] [--config PATH] [--event-limit 100000] [--check-automation] [--request-contacts] [--enrichment] [--read-only]\n";
        _ = u.c.write(1, help.ptr, help.len);
        if (!u.eq(cmd, "help")) return error.InvalidCommand;
        return;
    }
    _ = u.c.umask(0o077);
    const tls = try Tls.load(a, tls_path);
    // The TLS context lives as long as detached connection threads.
    const tls_info = try tls.info(a);
    if (tls_info.expiry_warning) std.debug.print("relay: certificate expires within 30 days; renew and restart\n", .{});
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
    core.contacts_phone_region = tls.config.contacts_phone_region;
    const attachment_root = if (fake) try std.fmt.allocPrint(a, "{s}.attachments", .{source}) else try std.fmt.allocPrint(a, "{s}/Library/Messages/Attachments", .{home});
    core.assets_service = Assets.init(a, init.io, data, attachment_root) catch null;
    core.assets_reason = if (core.assets_service != null) "" else "image_service_unavailable";
    core.journal.changed = .{ .signal = &core.changed, .io = init.io };
    try core.journal.recover(a);
    if (!fake and @import("builtin").os.tag == .macos) {
        Contacts.startAuthorizationChecks();
        const authorization = try std.Thread.spawn(.{}, Contacts.authorizationLoop, .{core});
        authorization.detach();
    }
    const ingestion = try std.Thread.spawn(.{}, Core.ingestLoop, .{core});
    ingestion.detach();
    const contacts = try std.Thread.spawn(.{}, Contacts.loop, .{core});
    contacts.detach();
    if (core.assets_service != null) {
        const media = try std.Thread.spawn(.{}, Assets.loop, .{core});
        media.detach();
    }
    if (!read_only) {
        const sender = try std.Thread.spawn(.{}, Core.senderLoop, .{core});
        sender.detach();
    }
    var server: Server = .{ .core = core, .tls = tls };
    if (!fake and @import("builtin").os.tag == .macos) {
        var state = NativeServer{ .server = &server };
        const listener = try std.Thread.spawn(.{}, NativeServer.run, .{&state});
        while (!state.done.load(.acquire)) Contacts.pumpMain();
        listener.join();
        if (state.failure) |err| return err;
    } else try server.run();
}
const NativeServer = struct {
    server: *Server,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    fn run(self: *NativeServer) void {
        self.server.run() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
};
fn printJson(a: u.Allocator, value: anytype) !void {
    const bytes = try u.json(a, value);
    _ = u.c.write(1, bytes.ptr, bytes.len);
    _ = u.c.write(1, "\n", 1);
}
test {
    _ = @import("protocol/types.zig");
    _ = @import("relay/adapter/decoder.zig");
    _ = @import("relay/adapter/body_parts.zig");
    _ = @import("relay/adapter/link_preview.zig");
    _ = @import("relay/adapter/reactions.zig");
    _ = @import("relay/Journal.zig");
    _ = Contacts;
    _ = Assets;
}
