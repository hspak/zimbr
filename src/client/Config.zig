const std = @import("std");
const u = @import("../common.zig");
const c = @import("c.zig").api;
const Self = @This();
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
const Preferences = struct {
    relay_url: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
    client_cert_file: ?[]const u8 = null,
    client_key_file: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    enter_to_send: bool = true,
};
fn preferences(a: u.Allocator, raw: []const u8) !Preferences {
    const value = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer value.deinit();
    if (value.value != .object) return error.InvalidConfiguration;
    for ([_][]const u8{ "port", "token_file", "token", "token_path" }) |field| {
        if (value.value.object.contains(field)) {
            std.log.err("obsolete transport field '{s}'; configure relay_url, ca_file, client_cert_file and client_key_file", .{field});
            return error.ObsoleteTransportConfiguration;
        }
    }
    // Strings are retained by the process arena.
    return (try std.json.parseFromSlice(Preferences, a, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value;
}
pub fn parse(init: std.process.Init) !Self {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    for (args[1..]) |arg| {
        if (u.eq(arg, "--help")) {
            const help = "Usage: zimbr --relay-url https://HOST[:PORT] --ca-file PATH\n             --client-cert-file PATH --client-key-file PATH\n       zimbr [--data-dir PATH] [--details]\n       zimbr [--screenshot PATH --frames 90]\nConfig: $XDG_CONFIG_HOME/zimbr/config.json\nUse absolute credential paths: owned 0600 files in 0700 directories; no symlinks.\nTLS 1.3 with mutual authentication is required. Reconnect reloads credentials.\n";
            _ = u.c.write(1, help.ptr, help.len);
            std.process.exit(0);
        }
        if (u.eq(arg, "--port") or u.eq(arg, "--token-file")) {
            std.log.err("obsolete transport option '{s}'; use --relay-url, --ca-file, --client-cert-file and --client-key-file", .{arg});
            return error.ObsoleteTransportConfiguration;
        }
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    const base = init.environ_map.get("XDG_DATA_HOME") orelse try std.fmt.allocPrint(a, "{s}/.local/share", .{home});
    var data: []const u8 = try std.fmt.allocPrint(a, "{s}/zimbr", .{base});
    const confbase = init.environ_map.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{home});
    const conf = try std.fmt.allocPrintSentinel(a, "{s}/zimbr/config.json", .{confbase}, 0);
    var pref: Preferences = .{};
    var raw: [*c]u8 = null;
    var length: usize = 0;
    const read = c.zc_private_read(conf, &raw, &length);
    if (read < 0) {
        std.log.err("unsafe configuration: {s}; use an owned 0600 file in a 0700 directory without symlinks", .{conf});
        return error.UnsafeConfiguration;
    }
    if (read == 1) {
        defer c.zc_private_free(raw, length);
        if (length > 8192) return error.ConfigurationTooLarge;
        pref = try preferences(a, raw[0..length]);
    }
    if (pref.data_dir) |d| data = d;
    var screenshot: ?[:0]const u8 = null;
    var frames: usize = 0;
    var control = false;
    var details = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (u.eq(args[i], "--details")) {
            details = true;
            continue;
        }
        if (u.eq(args[i], "--control")) {
            control = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        const value = args[i + 1];
        if (u.eq(args[i], "--data-dir")) data = value else if (u.eq(args[i], "--relay-url")) pref.relay_url = value else if (u.eq(args[i], "--ca-file")) pref.ca_file = value else if (u.eq(args[i], "--client-cert-file")) pref.client_cert_file = value else if (u.eq(args[i], "--client-key-file")) pref.client_key_file = value else if (u.eq(args[i], "--screenshot")) screenshot = try a.dupeZ(u8, value) else if (u.eq(args[i], "--frames")) frames = try std.fmt.parseInt(usize, value, 10) else return error.InvalidArguments;
        i += 1;
    }
    const origin = try a.dupeZ(u8, pref.relay_url orelse "");
    if (std.mem.indexOfScalar(u8, origin, 0) != null or c.zc_origin_valid(origin) == 0) {
        std.log.err("relay_url must be an HTTPS origin, e.g. https://mac-mini.local:8731 (no userinfo, path, query or fragment)", .{});
        return error.InvalidRelayOrigin;
    }
    for ([_]?[]const u8{ pref.ca_file, pref.client_cert_file, pref.client_key_file }) |path| {
        if (path == null or path.?.len == 0 or path.?[0] != '/' or std.mem.indexOfScalar(u8, path.?, 0) != null) {
            std.log.err("ca_file, client_cert_file and client_key_file must all be absolute paths", .{});
            return error.CredentialPathsRequired;
        }
    }
    _ = u.c.umask(0o077);
    try std.Io.Dir.cwd().createDirPath(init.io, data);
    const dir = try a.dupeZ(u8, data);
    if (u.c.chmod(dir, 0o700) != 0) return error.PrivateDirectoryRequired;
    return .{ .data = dir, .relay_url = origin, .ca_file = try a.dupeZ(u8, pref.ca_file.?), .client_cert_file = try a.dupeZ(u8, pref.client_cert_file.?), .client_key_file = try a.dupeZ(u8, pref.client_key_file.?), .screenshot = screenshot, .frames = frames, .control = control, .enter_to_send = pref.enter_to_send, .details = details };
}

test "only HTTPS origins are accepted" {
    for ([_][:0]const u8{ "https://mac-mini.local:8731", "https://localhost/", "https://[::1]:8731" }) |url| try std.testing.expect(c.zc_origin_valid(url) == 1);
    for ([_][:0]const u8{ "", "http://localhost", "https://", "https:///", "https://user@host", "https://host?", "https://host#", "https://host/path", "https://host:0", "https://host:65536", "https://host:", "https://host\\path", "https://host/%2f", "https:// host", "https://foo!", "https://-host", "https://host..local", "https://." }) |url| try std.testing.expect(c.zc_origin_valid(url) == 0);
}
test "editor preferences are preserved and obsolete theme settings are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = "{\"relay_url\":\"https://mac\",\"theme\":\"light\",\"enter_to_send\":false}";
    const pref = try preferences(arena.allocator(), raw);
    try std.testing.expect(!pref.enter_to_send);
}
