const std = @import("std");
const u = @import("../common.zig");
const Self = @This();
pub const Theme = enum { light, dark };
data: [:0]const u8,
token_path: [:0]const u8,
port: u16 = 8731,
screenshot: ?[:0]const u8 = null,
frames: usize = 0,
control: bool = false,
enter_to_send: bool = true,
theme: ?Theme = null,
details: bool = false,
pub fn parse(init: std.process.Init) !Self {
    const a = init.arena.allocator();
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    const base = init.environ_map.get("XDG_DATA_HOME") orelse try std.fmt.allocPrint(a, "{s}/.local/share", .{home});
    var data: []const u8 = try std.fmt.allocPrint(a, "{s}/zimbr", .{base});
    const confbase = init.environ_map.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{home});
    const conf = try std.fmt.allocPrint(a, "{s}/zimbr/config.json", .{confbase});
    var port: u16 = 8731;
    var token: ?[]const u8 = null;
    var screenshot: ?[:0]const u8 = null;
    var frames: usize = 0;
    var control = false;
    var enter_to_send = true;
    var theme: ?Theme = null;
    var details = false;
    const file = std.Io.Dir.cwd().readFileAlloc(init.io, conf, a, .limited(8192)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (file) |raw| {
        const Preferences = struct { port: u16 = 8731, token_file: ?[]const u8 = null, data_dir: ?[]const u8 = null, enter_to_send: bool = true, theme: ?Theme = null };
        const pref = (try std.json.parseFromSlice(Preferences, a, raw, .{ .ignore_unknown_fields = true })).value;
        port = pref.port;
        enter_to_send = pref.enter_to_send;
        theme = pref.theme;
        token = pref.token_file;
        if (pref.data_dir) |d| data = d;
    }
    const args = try init.minimal.args.toSlice(a);
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
        if (u.eq(args[i], "--help")) {
            const help = "Usage: zimbr [--data-dir PATH] [--token-file PATH] [--port 8731]\n       zimbr [--theme light|dark] [--details]\n       zimbr [--screenshot PATH --frames 90]\nConfig: $XDG_CONFIG_HOME/zimbr/config.json (port, token_file, data_dir, theme)\nDefault token: $XDG_DATA_HOME/zimbr/token. Only loopback HTTP is supported.\n";
            _ = u.c.write(1, help.ptr, help.len);
            std.process.exit(0);
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        if (u.eq(args[i], "--data-dir")) data = args[i + 1] else if (u.eq(args[i], "--token-file")) token = args[i + 1] else if (u.eq(args[i], "--port")) port = try std.fmt.parseInt(u16, args[i + 1], 10) else if (u.eq(args[i], "--screenshot")) screenshot = try a.dupeZ(u8, args[i + 1]) else if (u.eq(args[i], "--frames")) frames = try std.fmt.parseInt(usize, args[i + 1], 10) else if (u.eq(args[i], "--theme")) theme = std.meta.stringToEnum(Theme, args[i + 1]) orelse return error.InvalidTheme else return error.InvalidArguments;
        i += 1;
    }
    if (port == 0) return error.InvalidPort;
    _ = u.c.umask(0o077);
    try std.Io.Dir.cwd().createDirPath(init.io, data);
    const dir = try a.dupeZ(u8, data);
    if (u.c.chmod(dir, 0o700) != 0) return error.PrivateDirectoryRequired;
    return .{ .data = dir, .token_path = try a.dupeZ(u8, token orelse try std.fmt.allocPrint(a, "{s}/token", .{data})), .port = port, .screenshot = screenshot, .frames = frames, .control = control, .enter_to_send = enter_to_send, .theme = theme, .details = details };
}
