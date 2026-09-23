const std = @import("std");
const u = @import("../common.zig");
pub const c = @cImport({
    @cInclude("relay/tls.h");
});
pub const Config = struct {
    listen_address: []const u8,
    port: u16 = 8731,
    server_name: []const u8,
    server_cert_file: []const u8,
    server_key_file: []const u8,
    client_ca_file: []const u8,
    device_allowlist_file: []const u8,
};
pub const Device = struct { label: []const u8, sha256: []const u8, enabled: bool };
pub const Self = @This();
config: Config,
context: *c.ZrTlsContext,
enabled_devices: usize,
pub fn readPrivate(a: u.Allocator, path: []const u8) ![]const u8 {
    const buffer = try a.alloc(u8, 65536);
    const n = c.zr_tls_read_file(try a.dupeZ(u8, path), buffer.ptr, buffer.len);
    if (n < 0) {
        std.debug.print("relay: cannot read {s}: require an absolute path, owner-only file in a 0700 directory, no symlinks\n", .{path});
        return error.UnsafeOrMissingSecurityFile;
    }
    return buffer[0..@intCast(n)];
}
pub fn load(a: u.Allocator, path: []const u8) !Self {
    const config = (std.json.parseFromSlice(Config, a, try readPrivate(a, path), .{}) catch {
        std.debug.print("relay: invalid TLS config {s}; expected listen_address, port, server_name, server_cert_file, server_key_file, client_ca_file, device_allowlist_file\n", .{path});
        return error.InvalidTlsConfiguration;
    }).value;
    inline for (.{ config.listen_address, config.server_name, config.server_cert_file, config.server_key_file, config.client_ca_file, config.device_allowlist_file }) |value| {
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidTlsConfiguration;
    }
    if (config.port == 0 or config.server_name.len == 0) return error.InvalidTlsConfiguration;
    // A literal IP is deliberate: never resolve a bind name to an unintended interface.
    const address = std.Io.net.IpAddress.parse(config.listen_address, config.port) catch return error.ExplicitListenAddressRequired;
    switch (address) {
        .ip4 => |v| if (std.mem.eql(u8, &v.bytes, &.{ 0, 0, 0, 0 })) return error.WildcardListenAddressForbidden,
        .ip6 => |v| if (std.mem.allEqual(u8, &v.bytes, 0)) return error.WildcardListenAddressForbidden,
    }
    const devices = (std.json.parseFromSlice([]const Device, a, try readPrivate(a, config.device_allowlist_file), .{}) catch return error.InvalidDeviceAllowlist).value;
    if (devices.len > 256) return error.TooManyDevices;
    var fingerprints: [256][32]u8 = undefined;
    var count: usize = 0;
    for (devices, 0..) |device, i| {
        if (device.sha256.len != 64 or device.label.len == 0 or device.label.len > 128) return error.InvalidDeviceAllowlist;
        var decoded: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&decoded, device.sha256) catch return error.InvalidDeviceFingerprint;
        for (devices[0..i]) |previous| if (std.ascii.eqlIgnoreCase(previous.sha256, device.sha256)) return error.DuplicateDeviceFingerprint;
        if (device.enabled) {
            fingerprints[count] = decoded;
            count += 1;
        }
    }
    var diagnostic: [256]u8 = @splat(0);
    const ctx = c.zr_tls_context(try a.dupeZ(u8, config.server_cert_file), try a.dupeZ(u8, config.server_key_file), try a.dupeZ(u8, config.client_ca_file), try a.dupeZ(u8, config.server_name), @ptrCast(&fingerprints), count, &diagnostic, diagnostic.len) orelse {
        std.debug.print("relay: TLS configuration: {s}\n", .{std.mem.sliceTo(&diagnostic, 0)});
        return error.InvalidTlsCredentials;
    };
    return .{ .config = config, .context = ctx, .enabled_devices = count };
}
pub fn deinit(self: Self) void {
    c.zr_tls_context_free(self.context);
}
pub const Info = struct {
    configured: bool = true,
    protocol: []const u8 = "TLSv1.3",
    openssl: []const u8,
    enabled_devices: usize,
    server_sha256: []const u8,
    server_expires_unix: i64,
    ca_expires_unix: i64,
    expiry_warning: bool,
};
pub fn info(self: Self, a: u.Allocator) !Info {
    var fingerprint: [65]u8 = undefined;
    var expires: i64 = 0;
    var ca_expires: i64 = 0;
    if (c.zr_tls_info(self.context, &fingerprint, fingerprint.len, &expires, &ca_expires) != 0) return error.CertificateInfoFailed;
    return .{ .openssl = std.mem.span(c.zr_tls_version()), .enabled_devices = self.enabled_devices, .server_sha256 = try a.dupe(u8, fingerprint[0..64]), .server_expires_unix = expires, .ca_expires_unix = ca_expires, .expiry_warning = @min(expires, ca_expires) - @divTrunc(u.now(), 1000) <= 30 * 86400 };
}
