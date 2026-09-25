const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const source_probe = @import("relay.zig").adapter.enrichment_probe;
const Sqlite = @import("relay.zig").Sqlite;
const u = @import("common.zig");
const t = @import("protocol.zig").types;
const Journal = @import("relay.zig").Journal;
const Core = @import("relay.zig").Core;
const Server = @import("relay.zig").Server;
const Tls = @import("relay.zig").Tls;
const contact_directory = @import("relay.zig").adapter.contacts;
const Assets = @import("relay.zig").Assets;
const Menu = @import("relay.zig").Menu;
const settings = @import("relay.zig").settings;
const adapter_api = if (options.fake) @import("relay.zig").adapter.fake else @import("relay.zig").adapter.macos;
const fake = options.fake;
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
    if (args.len == 2 and u.eq(args[1], "contacts-permission-status")) contact_directory.permissionProbeExit();
    // Contact reads use bounded private pipes and the same installed identity.
    if (args.len == 2 and u.eq(args[1], "contacts-reader")) contact_directory.readerProbeExit();
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    var data: []const u8 = try std.fmt.allocPrint(
        a,
        "{s}/Library/Application Support/Zimbr",
        .{home},
    );
    var source: []const u8 = try std.fmt.allocPrint(a, "{s}/Library/Messages/chat.db", .{home});
    var source_explicit = false;
    var config_path: ?[]const u8 = null;
    var event_limit: i64 = 100000;
    var check_automation = false;
    var request_contacts = false;
    var enrichment_probe = false;
    var read_only = false;
    var menu_bar = Menu.available and args.len == 1;
    var settings_input: ?[]const u8 = null;
    var settings_original: ?[]const u8 = null;
    var settings_new = false;
    const cmd = if (args.len > 1) args[1] else if (Menu.available) "serve" else "help";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (u.eq(args[i], "--menu-bar")) {
            if (!Menu.available) return error.MenuBarUnavailable;
            menu_bar = true;
            continue;
        }
        if (u.eq(args[i], "--settings-new")) {
            settings_new = true;
            continue;
        }
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
        } else if (u.eq(args[i], "--settings-input")) {
            settings_input = args[i + 1];
        } else if (u.eq(args[i], "--settings-original")) {
            settings_original = args[i + 1];
        } else if (u.eq(args[i], "--event-limit")) {
            event_limit = try std.fmt.parseInt(i64, args[i + 1], 10);
            if (event_limit < 100) return error.InvalidArguments;
        } else return error.InvalidArguments;
        i += 1;
    }
    if (menu_bar and !u.eq(cmd, "serve")) return error.InvalidArguments;
    if (!u.eq(cmd, "save-config") and (settings_input != null or settings_original != null or settings_new))
        return error.InvalidArguments;
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
    if (u.eq(cmd, "save-config")) {
        const input = settings_input orelse return error.InvalidArguments;
        if (settings_new == (settings_original != null)) return error.InvalidArguments;
        const expected = if (settings_original) |path| try Tls.readPrivate(a, path) else null;
        const result = try settings.save(a, tls_path, expected, try Tls.readPrivate(a, input));
        try printJson(a, .{ .saved = true, .durability_confirmed = result == .saved });
        return;
    }
    if (u.eq(cmd, "check-config")) {
        var tls = try Tls.load(a, tls_path);
        defer tls.deinit();
        try printJson(a, try tls.info(a));
        return;
    }
    if (u.eq(cmd, "doctor") or u.eq(cmd, "probe")) {
        if (request_contacts) _ = try contact_directory.requestPermission();
        var tls = try Tls.load(a, tls_path);
        defer tls.deinit();
        const tls_info = try tls.info(a);
        const opened = adapter_api.open(a, source_path);
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
            const automation: ?bool = if (check_automation) automation: {
                if (comptime fake) break :automation true;
                adapter_api.automation(a, "check", "", "") catch |err| {
                    automation_error = adapter_api.automationReason(err);
                    break :automation false;
                };
                break :automation true;
            } else null;
            const enrichment = if (enrichment_probe) try source_probe.run(a, adapter) else null;
            try printJson(a, .{
                .database_readable = true,
                .schema_supported = true,
                .source_features = adapter.features,
                .enrichment_probe = enrichment,
                .recent_decoded = decoded,
                .recent_other = unsupported,
                .pending = pending,
                .tls = tls_info,
                .automation_ready = automation,
                .automation_error = automation_error,
                .real_send_verified = false,
                .contacts_permission = contact_directory.permission(),
                .contacts_phone_region = tls.config.contacts_phone_region,
                .suggested_contacts_phone_region = try contact_directory.suggestedRegion(a),
            });
        } else |err| {
            try printJson(a, .{
                .database_readable = false,
                .tls = tls_info,
                .error_code = @errorName(err),
                .automation_ready = false,
                .contacts_permission = contact_directory.permission(),
            });
            std.process.exit(1);
        }
        return;
    }
    if (!u.eq(cmd, "serve")) {
        const help = "Usage: relay setup|check-config|save-config|doctor|probe|serve [--data-dir PATH] [--messages-db PATH] [--config PATH] [--event-limit 100000] [--check-automation] [--request-contacts] [--enrichment] [--read-only] [--menu-bar]\n       save-config --settings-input PATH (--settings-original PATH | --settings-new)\n";
        _ = u.c.write(1, help.ptr, help.len);
        if (!u.eq(cmd, "help")) return error.InvalidCommand;
        return;
    }
    _ = u.c.umask(0o077);
    if (menu_bar) try std.Io.Dir.cwd().createDirPath(init.io, data);
    const lock_path = try std.fmt.allocPrintSentinel(a, "{s}/relay.lock", .{data}, 0);
    const lock_fd = u.c.zr_lock(lock_path);
    if (lock_fd < 0) {
        if (menu_bar) Menu.reopen(try a.dupeZ(u8, tls_path));
        return error.AlreadyRunning;
    }
    // Retain the lock for this process, including the UI when startup fails.
    var menu: Menu = .{ .config_path = try a.dupeZ(u8, tls_path), .data_path = try a.dupeZ(u8, data) };
    var service: Service = .{
        .allocator = a,
        .io = init.io,
        .home = home,
        .data = data,
        .source = source,
        .source_path = source_path,
        .tls_path = tls_path,
        .db_path = db_path,
        .event_limit = event_limit,
        .read_only = read_only,
        .menu = if (menu_bar) &menu else null,
    };
    if (menu_bar) {
        const worker = try std.Thread.spawn(.{}, Service.runMenu, .{&service});
        worker.detach();
        menu.run(args.len == 1);
        // Detached relay workers retain the arena and service until process exit.
        std.process.exit(0);
    }
    try service.run();
}

const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    data: []const u8,
    source: []const u8,
    source_path: [:0]const u8,
    tls_path: []const u8,
    db_path: [:0]const u8,
    event_limit: i64,
    read_only: bool,
    menu: ?*Menu,

    fn runMenu(self: *Service) void {
        self.run() catch |err| {
            std.debug.print("relay: {s}\n", .{@errorName(err)});
            self.menu.?.failure.store(@errorName(err), .release);
        };
    }

    fn run(self: *Service) !void {
        const a = self.allocator;
        const home = self.home;
        const data = self.data;
        const source = self.source;
        const source_path = self.source_path;
        const tls_path = self.tls_path;
        const db_path = self.db_path;
        const event_limit = self.event_limit;
        const read_only = self.read_only;
        const tls = try Tls.load(a, tls_path);
        // The TLS context lives as long as detached connection threads.
        const tls_info = try tls.info(a);
        if (tls_info.expiry_warning) std.debug.print(
            "relay: certificate expires within 30 days; renew and restart\n",
            .{},
        );
        if (comptime fake) {
            const db = try Sqlite.open(source_path, true);
            defer db.close();
            if (try db.scalar("SELECT count(*) FROM zimbr_fixture WHERE key='synthetic' AND value='yes'") != 1) return error.NotAFixture;
        }
        const core = try a.create(Core);
        core.* = .{
            .io = self.io,
            .journal = try Journal.open(db_path),
            .source_path = source_path,
            .event_limit = event_limit,
            .automation_ready = if (read_only) false else fake,
            .automation_error = if (read_only) "read_only_mode" else "automation_unverified",
        };
        core.contacts_phone_region = tls.config.contacts_phone_region;
        const attachment_root = if (comptime fake) try std.fmt.allocPrint(
            a,
            "{s}.attachments",
            .{source},
        ) else try std.fmt.allocPrint(
            a,
            "{s}/Library/Messages/Attachments",
            .{home},
        );
        core.assets_service = Assets.init(a, self.io, data, attachment_root) catch null;
        core.assets_reason = if (core.assets_service != null) "" else "image_service_unavailable";
        core.journal.changed = .{ .signal = &core.changed, .io = self.io };
        try core.journal.recover(a);
        if (comptime !fake and builtin.os.tag == .macos) {
            contact_directory.startAuthorizationChecks();
            const authorization = try std.Thread.spawn(
                .{},
                contact_directory.authorizationLoop,
                .{core},
            );
            authorization.detach();
        }
        const ingestion = try std.Thread.spawn(.{}, Core.ingestLoop, .{core});
        ingestion.detach();
        const contacts = try std.Thread.spawn(.{}, contact_directory.loop, .{core});
        contacts.detach();
        if (core.assets_service != null) {
            const media = try std.Thread.spawn(.{}, Assets.loop, .{core});
            media.detach();
        }
        if (!read_only) {
            const sender = try std.Thread.spawn(.{}, Core.senderLoop, .{core});
            sender.detach();
        }
        const server = try a.create(Server);
        server.* = .{
            .core = core,
            .tls = tls,
            .listening = if (self.menu) |menu| &menu.listening else null,
        };
        if (self.menu) |menu| {
            menu.expires_unix = @min(tls_info.server_expires_unix, tls_info.ca_expires_unix);
            menu.core.store(core, .release);
            try server.run();
        } else if (comptime !fake and builtin.os.tag == .macos) {
            var state = NativeServer{ .server = server };
            const listener = try std.Thread.spawn(.{}, NativeServer.run, .{&state});
            while (!state.done.load(.acquire)) contact_directory.pumpMain();
            listener.join();
            if (state.failure) |err| return err;
        } else try server.run();
    }
};
const NativeServer = struct {
    server: *Server,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?Server.RunError = null,
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
    _ = @import("protocol.zig").types;
    _ = @import("protocol/legacy_v1_test.zig");
    _ = @import("relay.zig").adapter.decoder;
    _ = @import("relay.zig").adapter.body_parts;
    _ = @import("relay.zig").adapter.link_preview;
    _ = @import("relay.zig").adapter.reactions;
    _ = @import("relay.zig").Journal;
    _ = @import("relay.zig").Mutex;
    _ = contact_directory;
    _ = Assets;
    _ = Menu;
}
