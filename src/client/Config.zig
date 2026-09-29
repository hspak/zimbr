//! Client settings persisted in client.db, with optional launch overrides.
const std = @import("std");
const options = @import("client_options");
const u = @import("../common.zig");
const c = @import("c.zig").api;
const Store = @import("Store.zig");
const Sqlite = @import("../relay.zig").Sqlite;
const log = std.log.scoped(.client_config);
const Config = @This();

data: [:0]const u8,
relay_url: [:0]const u8 = "",
ca_file: [:0]const u8 = "",
client_cert_file: [:0]const u8 = "",
client_key_file: [:0]const u8 = "",
screenshot: ?[:0]const u8 = null,
frames: usize = 0,
control: bool = false,
enter_to_send: bool = true,
details: bool = false,
settings: bool = false,
save_connection: bool = false,
reset_cache: bool = false,
legacy_path: ?[:0]const u8 = null,
overrides: Overrides = .{},

const directory_name = switch (options.profile) {
    .dev => "zimbr-dev",
    .release => "zimbr",
};

const Overrides = struct {
    relay_url: ?[:0]const u8 = null,
    ca_file: ?[:0]const u8 = null,
    client_cert_file: ?[:0]const u8 = null,
    client_key_file: ?[:0]const u8 = null,
};
const Preferences = struct {
    relay_url: []const u8 = "",
    ca_file: []const u8 = "",
    client_cert_file: []const u8 = "",
    client_key_file: []const u8 = "",
    enter_to_send: bool = true,
};
const connection_fields = .{
    "relay_url",
    "ca_file",
    "client_cert_file",
    "client_key_file",
};

pub const LockCacheError = u.Allocator.Error || error{ClientAlreadyRunning};
pub const ValidateError = error{ InvalidRelayOrigin, CredentialPathsRequired };
pub const SaveError = Sqlite.QueryError || ValidateError;
pub const LoadError = Store.ReadError || SaveError || error{InvalidCredentials};
pub const ResetCacheError = Store.ReadError || u.IdError ||
    std.Io.Dir.OpenError || std.Io.Dir.StatFileError || std.Io.File.OpenError ||
    std.Io.Dir.DeleteTreeError || std.Io.Dir.DeleteFileError || std.Io.Dir.RenameError;
pub const ParseError = std.Io.Dir.CreateDirPathError || u.Allocator.Error || error{
    HomeRequired,
    InvalidArguments,
    ObsoleteTransportConfiguration,
    PrivateDirectoryRequired,
};

/// Hold the returned descriptor until the client and its workers have shut down.
pub fn lockCache(s: Config) LockCacheError!c_int {
    const a = std.heap.page_allocator;
    const path = try std.fmt.allocPrintSentinel(a, "{s}/client.lock", .{s.data}, 0);
    defer a.free(path);
    const lock = u.c.zr_lock(path);
    if (lock < 0) return error.ClientAlreadyRunning;
    return lock;
}
fn preferences(a: u.Allocator, raw: []const u8) !Preferences {
    const value = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer value.deinit();
    if (value.value != .object) return error.InvalidConfiguration;
    for ([_][]const u8{
        "port",
        "token_file",
        "token",
        "token_path",
    }) |field| {
        if (value.value.object.contains(field)) return error.ObsoleteTransportConfiguration;
    }
    return try std.json.parseFromSliceLeaky(
        Preferences,
        a,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}
fn dataDirectory(a: u.Allocator, explicit: ?[]const u8, state: ?[]const u8, home: ?[]const u8) ![:0]const u8 {
    if (explicit) |path| {
        if (path.len == 0) return error.InvalidArguments;
        return try a.dupeZ(u8, path);
    }
    if (state) |base| if (std.fs.path.isAbsolute(base)) {
        return try std.fmt.allocPrintSentinel(a, "{s}/" ++ directory_name, .{base}, 0);
    };
    const base = home orelse return error.HomeRequired;
    if (base.len == 0) return error.HomeRequired;
    return try std.fmt.allocPrintSentinel(a, "{s}/.local/share/" ++ directory_name, .{base}, 0);
}

/// Resolve launch options and prepare the state directory. Missing settings are
/// valid here; load them after acquiring lockCache, before starting workers.
pub fn parse(init: std.process.Init) ParseError!Config {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var config = Config{ .data = "" };
    var explicit: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (u.eq(arg, "--help")) {
            const help =
                "Usage: zimbr [--data-dir PATH] [--settings] [--details]\n" ++
                "       zimbr --reset-cache [--data-dir PATH]\n" ++
                "       zimbr [--relay-url HTTPS_ORIGIN] [--ca-file PATH]\n" ++
                "             [--client-cert-file PATH] [--client-key-file PATH]\n" ++
                "       Add --save-connection to validate and persist all four connection flags.\n" ++
                "       zimbr [--screenshot PATH --frames 90]\n" ++
                "First run: zimbr-provision setup user@mac.example\n" ++
                "Settings: saved in client.db. CLI overrides are temporary unless --save-connection is used.\n" ++
                "Reset: delete local messages, drafts, pending sends and media, then exit.\n" ++
                "       Retain readable saved settings and credential files.\n" ++
                "Profile: " ++ @tagName(options.profile) ++ "\n" ++
                "State: $XDG_STATE_HOME/" ++ directory_name ++
                ", falling back to $HOME/.local/share/" ++ directory_name ++ ".\n" ++
                "Credentials: absolute paths, owned 0600 files in 0700 directories; no symlinks.\n";
            _ = u.c.write(1, help.ptr, help.len);
            std.process.exit(0);
        }
        if (u.eq(arg, "--port") or u.eq(arg, "--token-file")) {
            log.err("obsolete transport option '{s}'; configure HTTPS and client certificates in Settings", .{arg});
            return error.ObsoleteTransportConfiguration;
        }
        if (u.eq(arg, "--details")) {
            config.details = true;
            continue;
        }
        if (u.eq(arg, "--settings")) {
            config.settings = true;
            continue;
        }
        if (u.eq(arg, "--save-connection")) {
            config.save_connection = true;
            continue;
        }
        if (u.eq(arg, "--reset-cache")) {
            config.reset_cache = true;
            continue;
        }
        if (u.eq(arg, "--control")) {
            config.control = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        const value = args[i + 1];
        if (u.eq(arg, "--data-dir")) {
            explicit = value;
        } else if (u.eq(arg, "--relay-url")) {
            config.overrides.relay_url = try a.dupeZ(u8, value);
        } else if (u.eq(arg, "--ca-file")) {
            config.overrides.ca_file = try a.dupeZ(u8, value);
        } else if (u.eq(arg, "--client-cert-file")) {
            config.overrides.client_cert_file = try a.dupeZ(u8, value);
        } else if (u.eq(arg, "--client-key-file")) {
            config.overrides.client_key_file = try a.dupeZ(u8, value);
        } else if (u.eq(arg, "--screenshot")) {
            config.screenshot = try a.dupeZ(u8, value);
        } else if (u.eq(arg, "--frames")) {
            config.frames = std.fmt.parseInt(usize, value, 10) catch return error.InvalidArguments;
        } else return error.InvalidArguments;
        i += 1;
    }
    if (config.save_connection) {
        if (config.reset_cache) return error.InvalidArguments;
        inline for (connection_fields) |field| {
            if (@field(config.overrides, field) == null) return error.InvalidArguments;
        }
    }
    const home = init.environ_map.get("HOME");
    config.data = try dataDirectory(a, explicit, init.environ_map.get("XDG_STATE_HOME"), home);
    const confbase = init.environ_map.get("XDG_CONFIG_HOME") orelse
        if (home) |base| try std.fmt.allocPrint(a, "{s}/.config", .{base}) else null;
    if (confbase) |base| if (std.fs.path.isAbsolute(base)) {
        config.legacy_path = try std.fmt.allocPrintSentinel(a, "{s}/" ++ directory_name ++ "/config.json", .{base}, 0);
    };
    _ = u.c.umask(0o077);
    try std.Io.Dir.cwd().createDirPath(init.io, config.data);
    if (u.c.chmod(config.data, 0o700) != 0) return error.PrivateDirectoryRequired;
    return config;
}

/// Returned strings and partial allocations belong to the caller's arena.
/// Invalid saved settings are retained so the settings pane can repair them.
pub fn read(a: u.Allocator, store: Store) Store.ReadError!?Config {
    const q = try store.db.prepare("SELECT relay_url,ca_file,client_cert_file,client_key_file,enter_to_send FROM settings WHERE id=1");
    defer q.close();
    if (!try q.step()) return null;
    var config = Config{ .data = "", .enter_to_send = q.int(4) != 0 };
    inline for (connection_fields, 0..) |field, index| {
        @field(config, field) = try a.dupeZ(u8, q.bytes(index));
    }
    return config;
}
fn write(s: Config, store: Store) Sqlite.QueryError!void {
    try store.exec(
        "INSERT INTO settings VALUES(1,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET relay_url=excluded.relay_url,ca_file=excluded.ca_file,client_cert_file=excluded.client_cert_file,client_key_file=excluded.client_key_file,enter_to_send=excluded.enter_to_send",
        &.{
            .{ .text = s.relay_url },
            .{ .text = s.ca_file },
            .{ .text = s.client_cert_file },
            .{ .text = s.client_key_file },
            .{ .int = @intFromBool(s.enter_to_send) },
        },
    );
}
fn importLegacy(s: *Config, a: u.Allocator) !void {
    const path = s.legacy_path orelse return;
    var raw: [*c]u8 = null;
    var length: usize = 0;
    const result = c.zc_private_read(path, &raw, &length);
    if (result == 0) return;
    if (result < 0) return error.UnsafeConfiguration;
    defer c.zc_private_free(raw, length);
    if (length > 8192) return error.ConfigurationTooLarge;
    const pref = try preferences(a, raw[0..length]);
    inline for (connection_fields) |field| @field(s, field) = try a.dupeZ(u8, @field(pref, field));
    s.enter_to_send = pref.enter_to_send;
}

/// Assume lockCache is held. Imports a legacy JSON file only when this database
/// has no settings yet. Overrides persist only with an explicit save_connection
/// request, after validating the complete connection and local credentials.
pub fn load(s: *Config, a: u.Allocator) LoadError!void {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{s.data}, 0);
    const store = try Store.open(path);
    defer store.close();
    if (try read(a, store)) |saved| {
        inline for (connection_fields) |field| @field(s, field) = @field(saved, field);
        s.enter_to_send = saved.enter_to_send;
    } else {
        s.importLegacy(a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => log.warn("legacy config was not imported ({s}); open Settings to configure this client", .{@errorName(err)}),
        };
        try s.write(store);
    }
    inline for (connection_fields) |field| {
        if (@field(s.overrides, field)) |value| @field(s, field) = value;
    }
    if (s.save_connection) {
        try s.validate();
        var detail: c.ZcError = undefined;
        if (!s.check(&detail)) {
            log.err("{s}", .{std.mem.sliceTo(&detail.message, 0)});
            return error.InvalidCredentials;
        }
        try s.save(store);
        s.save_connection = false;
        s.overrides = .{};
    }
}

/// Assume lockCache is held and all database connections and media workers are
/// closed. Recreate client.db with only readable saved settings and remove media.
/// Drafts and outbox identities are discarded; credential files are untouched.
pub fn resetCache(s: Config, io: std.Io) ResetCacheError!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.Io.Dir.cwd().openDir(io, s.data, .{ .follow_symlinks = false });
    defer dir.close(io);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{s.data}, 0);
    const saved = saved: {
        const stat = dir.statFile(io, "client.db", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => break :saved null,
            else => return err,
        };
        if (stat.kind != .file) break :saved null;
        break :saved readSaved(a, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("could not recover settings from client.db ({s}); reset will require setup", .{@errorName(err)});
                break :saved null;
            },
        };
    };
    const name = try std.fmt.allocPrint(a, ".client-reset-{s}.db", .{try u.id(a)});
    const temporary = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ s.data, name }, 0);
    const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    file.close(io);
    defer dir.deleteFile(io, name) catch {};
    defer removeSidecars(dir, io, name) catch {};
    {
        const replacement = try Store.open(temporary);
        defer replacement.close();
        // Save before touching the old cache; launch overrides are not preferences.
        try (saved orelse Config{ .data = "" }).write(replacement);
        try replacement.db.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;");
    }
    try dir.deleteTree(io, "media");
    try dir.deleteTree(io, "outgoing");
    try removeSidecars(dir, io, "client.db");
    try dir.rename(name, dir, "client.db", io);
}

fn readSaved(a: u.Allocator, path: [:0]const u8) Store.ReadError!?Config {
    const db = try Sqlite.openConfined(path, true);
    defer db.close();
    return read(a, .{ .db = db });
}

fn removeSidecars(dir: std.Io.Dir, io: std.Io, name: []const u8) std.Io.Dir.DeleteFileError!void {
    for ([_][]const u8{
        "-wal",
        "-shm",
        "-journal",
    }) |suffix| {
        // Fit client.db or the bounded temporary basename plus a SQLite sidecar suffix.
        var buffer: [128]u8 = undefined;
        // Only client.db and the bounded temporary name above are passed here.
        const path = std.fmt.bufPrint(&buffer, "{s}{s}", .{ name, suffix }) catch unreachable;
        dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

pub fn validate(s: Config) ValidateError!void {
    if (!validText(s.relay_url) or c.zc_origin_valid(s.relay_url) == 0) return error.InvalidRelayOrigin;
    inline for (.{
        "ca_file",
        "client_cert_file",
        "client_key_file",
    }) |field| {
        const path = @field(s, field);
        if (!validText(path) or !std.fs.path.isAbsolute(path)) return error.CredentialPathsRequired;
    }
}
fn validText(value: []const u8) bool {
    // Bound configured paths and origins to 4 KiB before passing them to native APIs.
    return value.len > 0 and value.len <= 4096 and std.unicode.utf8ValidateSlice(value) and
        std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

/// Check local credentials without connecting to the relay. On failure, detail
/// contains a user-facing explanation; temporary network failure is irrelevant.
pub fn check(s: Config, detail: *c.ZcError) bool {
    s.validate() catch |err| {
        detail.* = std.mem.zeroes(c.ZcError);
        detail.kind = c.ZC_CONFIG;
        const message = switch (err) {
            error.InvalidRelayOrigin => "Enter an HTTPS relay origin, such as https://relay.example:8731 (no path, query or fragment).",
            error.CredentialPathsRequired => "Enter absolute paths for the CA certificate, client certificate and client key.",
        };
        @memcpy(detail.message[0..message.len], message);
        return false;
    };
    var identity: c.ZcIdentity = undefined;
    const net = c.zc_net_new(s.relay_url, s.ca_file, s.client_cert_file, s.client_key_file, null, null, detail, &identity) orelse return false;
    c.zc_net_free(net);
    return true;
}

/// Atomically save the settings. Credential contents stay in their PEM files.
/// Call check before saving from the UI to also validate local credentials.
pub fn save(s: Config, store: Store) SaveError!void {
    try s.validate();
    try s.write(store);
}

test "only HTTPS origins are accepted" {
    for ([_][:0]const u8{
        "https://mac-mini.local:8731",
        "https://localhost/",
        "https://[::1]:8731",
    }) |url| try std.testing.expect(c.zc_origin_valid(url) == 1);
    for ([_][:0]const u8{
        "",
        "http://localhost",
        "https://",
        "https:///",
        "https://user@host",
        "https://host?",
        "https://host#",
        "https://host/path",
        "https://host:0",
        "https://host:65536",
        "https://host:",
        "https://host\\path",
        "https://host/%2f",
        "https:// host",
        "https://foo!",
        "https://-host",
        "https://host..local",
        "https://.",
    }) |url| try std.testing.expect(c.zc_origin_valid(url) == 0);
}
test "editor preferences are preserved and obsolete theme settings are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = "{\"relay_url\":\"https://mac\",\"theme\":\"light\",\"enter_to_send\":false}";
    const pref = try preferences(arena.allocator(), raw);
    try std.testing.expect(!pref.enter_to_send);
}

test "state directory honors explicit overrides then absolute XDG state and home fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("relative-state", try dataDirectory(a, "relative-state", "/xdg", null));
    const expected = switch (options.profile) {
        .dev => "/xdg/zimbr-dev",
        .release => "/xdg/zimbr",
    };
    try std.testing.expectEqualStrings(expected, try dataDirectory(a, null, "/xdg", null));
    const fallback = switch (options.profile) {
        .dev => "/home/example/.local/share/zimbr-dev",
        .release => "/home/example/.local/share/zimbr",
    };
    for ([_]?[]const u8{
        null,
        "",
        "relative",
    }) |state| {
        try std.testing.expectEqualStrings(fallback, try dataDirectory(a, null, state, "/home/example"));
    }
    try std.testing.expectError(error.HomeRequired, dataDirectory(a, null, "", null));
    try std.testing.expectError(error.InvalidArguments, dataDirectory(a, "", "/xdg", "/home/example"));
}

test "settings save replaces all preferences atomically and survives synchronization resets" {
    const store = try Store.open(":memory:");
    defer store.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try read(a, store) == null);
    const initial = Config{
        .data = "",
        .relay_url = "https://relay.example:8731",
        .ca_file = "/private/ca.pem",
        .client_cert_file = "/private/client.pem",
        .client_key_file = "/private/client-key.pem",
        .enter_to_send = false,
    };
    try initial.save(store);
    try store.saveDraft("chat", "Keep this draft");
    var replacement = initial;
    replacement.relay_url = "https://new.example:8731";
    replacement.client_key_file = "/new/key.pem";
    replacement.enter_to_send = true;
    try store.db.exec("CREATE TRIGGER reject_settings BEFORE UPDATE ON settings BEGIN SELECT RAISE(ABORT,'failure'); END");
    try std.testing.expectError(error.DatabaseFailure, replacement.save(store));
    const unchanged = (try read(a, store)).?;
    try std.testing.expectEqualStrings(initial.relay_url, unchanged.relay_url);
    try std.testing.expectEqualStrings(initial.client_key_file, unchanged.client_key_file);
    try std.testing.expect(!unchanged.enter_to_send);
    try store.db.exec("DROP TRIGGER reject_settings");
    try replacement.save(store);
    const epoch = "EjRWeBI0EjQSNBI0VniQEg";
    try store.beginSync(epoch, epoch ++ ":0");
    const saved = (try read(a, store)).?;
    try std.testing.expectEqualStrings(replacement.relay_url, saved.relay_url);
    try std.testing.expectEqualStrings(replacement.ca_file, saved.ca_file);
    try std.testing.expectEqualStrings(replacement.client_cert_file, saved.client_cert_file);
    try std.testing.expectEqualStrings(replacement.client_key_file, saved.client_key_file);
    try std.testing.expect(saved.enter_to_send);
    try std.testing.expectEqualStrings("Keep this draft", try store.draft(a, "chat"));
    replacement.relay_url = "http://invalid.example";
    try std.testing.expectError(error.InvalidRelayOrigin, replacement.save(store));
    replacement.relay_url = initial.relay_url;
    replacement.client_key_file = "relative.pem";
    try std.testing.expectError(error.CredentialPathsRequired, replacement.save(store));
    try std.testing.expectEqualStrings(saved.relay_url, (try read(a, store)).?.relay_url);
}

test "invalid stored connection values are loaded for repair and rejected before use" {
    const store = try Store.open(":memory:");
    defer store.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad = Config{ .data = "", .relay_url = "https://relay.example\x00ignored" };
    try bad.write(store);
    const loaded = (try read(a, store)).?;
    try std.testing.expectEqualStrings(bad.relay_url, loaded.relay_url);
    try std.testing.expectError(error.InvalidRelayOrigin, loaded.validate());
    bad.relay_url = "https://relay.example";
    bad.ca_file = "/ca\x00.pem";
    try std.testing.expectError(error.CredentialPathsRequired, bad.validate());
    bad.ca_file = "/ca.pem";
    bad.client_cert_file = "/cert.pem";
    bad.client_key_file = "/key.pem\n";
    try std.testing.expectError(error.CredentialPathsRequired, bad.validate());
}
