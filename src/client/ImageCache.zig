//! GUI-thread textures; immutable bytes and decoding belong to Media's worker.
const std = @import("std");
const a = std.heap.c_allocator;
const desktop = @import("desktop.zig");
const graphics = @import("graphics.zig");
const Media = @import("Media.zig");
const t = @import("../protocol.zig").types;
const attachments = @import("../protocol.zig").attachments;
const u = @import("../common.zig");
const ImageCache = @This();
const log = std.log.scoped(.client_images);

entries: std.AutoHashMapUnmanaged(Media.Key, Entry) = .empty,
bytes: usize = 0,
frame: u64 = 0,

pub const Entry = struct {
    used: u64 = 0,
    attempts: u8 = 0,
    content: union(enum) {
        pending,
        requested,
        ready: graphics.Texture,
        unavailable: struct {
            kind: enum { offline, preparing, failed, denied },
            retry_at: i64,
            reason: [128:0]u8,
        },
        retired: bool,
    } = .pending,

    pub fn availableTexture(entry: *const Entry) ?graphics.Texture {
        return switch (entry.content) {
            .ready => |texture| texture,
            .pending, .requested, .unavailable, .retired => null,
        };
    }
    pub fn reason(entry: *const Entry) []const u8 {
        return switch (entry.content) {
            .unavailable => |*failure| std.mem.sliceTo(&failure.reason, 0),
            .retired => "Photo changed · refreshing message",
            .pending, .requested, .ready => "",
        };
    }
    pub fn canRetry(entry: *const Entry) bool {
        return switch (entry.content) {
            .unavailable => |failure| failure.kind != .denied and failure.kind != .preparing,
            .pending, .requested, .ready, .retired => false,
        };
    }
    pub fn takeRefresh(entry: *Entry) bool {
        if (entry.content != .retired) return false;
        const refresh = entry.content.retired;
        entry.content.retired = false;
        return refresh;
    }
    fn wantsRequest(entry: *const Entry, now: i64) bool {
        return switch (entry.content) {
            .pending, .requested => true,
            .unavailable => |failure| failure.retry_at > 0 and now >= failure.retry_at,
            .ready, .retired => false,
        };
    }
};

pub fn deinit(s: *ImageCache) void {
    var it = s.entries.valueIterator();
    while (it.next()) |entry| if (entry.availableTexture()) |texture| graphics.destroyTexture(texture);
    s.entries.deinit(a);
    s.* = undefined;
}
fn release(s: *ImageCache, entry: *Entry) void {
    if (entry.availableTexture()) |texture| {
        s.bytes -= graphics.textureBytes(texture);
        graphics.destroyTexture(texture);
    }
    entry.content = .pending;
}
pub fn contextChanged(s: *ImageCache, avatars: bool) void {
    var it = s.entries.iterator();
    while (it.next()) |entry| {
        if ((!avatars and entry.key_ptr.isAvatar()) or entry.value_ptr.availableTexture() == null) {
            s.release(entry.value_ptr);
            entry.value_ptr.* = .{};
        }
    }
}
/// Borrows decoded pixels. Readiness is committed only after SDL accepts the upload.
pub fn accept(s: *ImageCache, result: *const Media.Result) void {
    const entry = s.entries.getPtr(result.key) orelse return;
    s.release(entry);
    entry.used = s.frame;
    entry.attempts +|= 1;
    const delay: i64 = @min(30000, @as(i64, 2000) << @intCast(@min(entry.attempts -| 1, 4)));
    switch (result.state) {
        .ready => {
            const bytes = result.pixels.bytes;
            s.makeRoom(bytes);
            const texture = upload(result) catch |err| {
                var reason: [128:0]u8 = @splat(0);
                const message = "Could not upload image · retrying";
                @memcpy(reason[0..message.len], message);
                entry.content = .{ .unavailable = .{
                    .kind = .failed,
                    .retry_at = u.now() + delay,
                    .reason = reason,
                } };
                log.warn("Image upload: {s}", .{@errorName(err)});
                return;
            };
            entry.content = .{ .ready = texture };
            entry.attempts = 0;
            s.bytes += graphics.textureBytes(texture);
        },
        .retired => entry.content = .{ .retired = true },
        .offline, .pending, .failed, .denied => entry.content = .{ .unavailable = .{
            .kind = switch (result.state) {
                .offline => .offline,
                .pending => .preparing,
                .failed => .failed,
                .denied => .denied,
                else => unreachable,
            },
            .retry_at = if (result.retry_at == 0) 0 else @max(result.retry_at, u.now() + delay),
            .reason = result.reason,
        } },
    }
}
fn upload(result: *const Media.Result) graphics.ResourceError!graphics.Texture {
    const pixels = result.pixels;
    if (pixels.data == null or pixels.width <= 0 or pixels.height <= 0 or
        @as(u64, @intCast(pixels.width)) * @as(u64, @intCast(pixels.height)) * 4 != pixels.bytes or
        pixels.bytes > Media.texture_budget) return error.InvalidDimensions;
    return graphics.upload(@ptrCast(pixels.data.?), pixels.width, pixels.height, .linear);
}
pub fn nextFrame(s: *ImageCache) void {
    s.frame +%= 1;
    // Leave room for new visible requests below the hard 1024-entry cap.
    while (s.entries.count() > 896) {
        var oldest: ?Media.Key = null;
        var stamp: u64 = std.math.maxInt(u64);
        var it = s.entries.iterator();
        while (it.next()) |entry| if (entry.value_ptr.used <= stamp) {
            oldest = entry.key_ptr.*;
            stamp = entry.value_ptr.used;
        };
        const key = oldest orelse break;
        var removed = s.entries.fetchRemove(key).?.value;
        s.release(&removed);
    }
}
fn makeRoom(s: *ImageCache, bytes: usize) void {
    while (bytes <= Media.texture_budget and s.bytes + bytes > Media.texture_budget) {
        var oldest: ?*Entry = null;
        var it = s.entries.valueIterator();
        while (it.next()) |entry| if (entry.availableTexture() != null and (oldest == null or entry.used < oldest.?.used)) {
            oldest = entry;
        };
        s.release(oldest orelse break);
    }
}
fn touch(s: *ImageCache, key: Media.Key) ?*Entry {
    if (s.entries.count() >= 1024 and !s.entries.contains(key)) return null;
    const result = s.entries.getOrPut(a, key) catch return null;
    if (!result.found_existing) result.value_ptr.* = .{};
    result.value_ptr.used = s.frame;
    return result.value_ptr;
}
pub fn get(s: *ImageCache, media: *Media, asset: t.AssetRef) ?*Entry {
    if (!media.avatars and asset.variant == .avatar) return null;
    const entry = s.touch(media.key(asset)) orelse return null;
    if (asset.availability == .retired) {
        if (entry.content != .retired) {
            s.release(entry);
            entry.content = .{ .retired = true };
        }
        return entry;
    }
    if (entry.wantsRequest(u.now())) {
        // Refresh visibility while Media deduplicates queued or in-flight work.
        media.request(asset) catch return entry;
        entry.content = .requested;
    }
    return entry;
}
pub fn retry(entry: *Entry) void {
    if (entry.canRetry()) entry.content = .pending;
}
/// Borrow an entry until the next cache mutation. Decoding failures remain retryable entries.
pub fn getLocal(s: *ImageCache, media: *Media, file: attachments.Upload) ?*Entry {
    const entry = s.touch(media.localKey(file)) orelse return null;
    if (entry.wantsRequest(u.now())) {
        media.requestLocal(file) catch return entry;
        entry.content = .requested;
    }
    return entry;
}
pub fn draw(texture: graphics.Texture, bounds: graphics.Rect) void {
    const scale = @min(
        bounds.width / @as(f32, @floatFromInt(texture.w)),
        bounds.height / @as(f32, @floatFromInt(texture.h)),
    );
    const w = @as(f32, @floatFromInt(texture.w)) * scale;
    const h = @as(f32, @floatFromInt(texture.h)) * scale;
    graphics.drawTexture(texture, .{
        .x = bounds.x + (bounds.width - w) / 2,
        .y = bounds.y + (bounds.height - h) / 2,
        .width = w,
        .height = h,
    });
}

/// Draws a circular, center-cropped photo, or a solid tint when texture is null.
pub fn drawAvatar(texture: ?graphics.Texture, bounds: graphics.Rect, tint: graphics.Color) void {
    const radius = @min(bounds.width, bounds.height) / 2;
    if (radius <= 0) return;
    if (texture) |photo| if (photo.w <= 0 or photo.h <= 0) return;
    const center = graphics.Point{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
    // Center-crop rectangular photos to fill the circle without stretching.
    const uv: graphics.Point = if (texture) |photo| crop: {
        const size: f32 = @floatFromInt(@min(photo.w, photo.h));
        break :crop .{
            .x = size / @as(f32, @floatFromInt(photo.w)) / 2,
            .y = size / @as(f32, @floatFromInt(photo.h)) / 2,
        };
    } else .{ .x = 0, .y = 0 };
    const inner = @max(0, radius - 1 / @max(1, graphics.scale().x));
    var transparent = tint;
    transparent.a = 0;
    // 64 radial segments keep avatars smooth at ordinary and high display scales.
    const segments = 64;
    var vertices: [1 + segments * 2]graphics.Vertex = undefined;
    var indices: [segments * 9]u16 = undefined;
    vertices[0] = avatarVertex(center, .{ .x = 0, .y = 0 }, radius, uv, 0, tint);
    for (0..segments) |i| {
        const angle = -2 * std.math.pi * @as(f32, @floatFromInt(i)) / segments;
        const direction: graphics.Point = .{ .x = @cos(angle), .y = @sin(angle) };
        vertices[1 + i] = avatarVertex(center, direction, radius, uv, inner, tint);
        vertices[1 + segments + i] = avatarVertex(center, direction, radius, uv, radius, transparent);
        const p: u16 = @intCast(1 + i);
        const q: u16 = @intCast(1 + (i + 1) % segments);
        indices[i * 9 ..][0..9].* = .{
            0,
            p,
            q,
            p,
            p + segments,
            q + segments,
            p,
            q + segments,
            q,
        };
    }
    graphics.mesh(texture, &vertices, &indices);
}

fn avatarVertex(
    center: graphics.Point,
    direction: graphics.Point,
    radius: f32,
    uv: graphics.Point,
    distance: f32,
    color: graphics.Color,
) graphics.Vertex {
    return graphics.vertex(
        .{ .x = center.x + direction.x * distance, .y = center.y + direction.y * distance },
        .{ .x = 0.5 + direction.x * uv.x * distance / radius, .y = 0.5 + direction.y * uv.y * distance / radius },
        color,
    );
}

test "local previews queue offline and transfer decoded pixels into bounded textures" {
    try openWindow(780, 560, "Local attachment preview");
    defer closeWindow();
    var media = Media{ .io = std.testing.io, .config = .{ .data = "" } };
    defer media.shutdown();
    _ = try media.context("", "draft", 0, false, true);
    var images = ImageCache{};
    defer images.deinit();
    const file: attachments.Upload = .{
        .id = "ABEiM0RVZneImaq7zN3u_w",
        .name = "photo.png",
        .mime_type = "image/png",
        .bytes = "71",
        .sha256 = "0" ** 64,
    };
    const queued = images.getLocal(&media, file) orelse return error.TestUnexpectedResult;
    try std.testing.expect(queued.availableTexture() == null and queued.content == .requested);
    _ = images.getLocal(&media, file);
    try std.testing.expectEqual(@as(usize, 1), media.queue.items.len);
    var pixel = [_]u8{
        12,
        34,
        56,
        255,
    };
    const result: Media.Result = .{
        .key = media.localKey(file),
        .generation = media.generation,
        .state = .ready,
        .pixels = .{
            .data = &pixel,
            .width = 1,
            .height = 1,
            .bytes = pixel.len,
        },
    };
    images.accept(&result);
    const ready = images.getLocal(&media, file) orelse return error.TestUnexpectedResult;
    const texture = ready.availableTexture() orelse return error.TestUnexpectedResult;
    const image = try graphics.readTexture(texture);
    defer graphics.destroyImage(image);
    try std.testing.expectEqual(graphics.Color{
        .r = 12,
        .g = 34,
        .b = 56,
        .a = 255,
    }, graphics.imageColor(image, 0, 0));
    try std.testing.expectEqual(@as(usize, 4), images.bytes);
    images.contextChanged(false);
    try std.testing.expect(images.getLocal(&media, file).?.availableTexture() != null);
}

fn openWindow(width: i32, height: i32, title: [:0]const u8) !void {
    try desktop.open(width, height, title);
    errdefer desktop.close();
    try graphics.init();
}

test "pending image retries honor the relay deadline" {
    var images = ImageCache{};
    defer images.deinit();
    const key: Media.Key = .init(@splat(0), .inline_image);
    const entry = images.touch(key) orelse return error.OutOfMemory;
    const now = u.now();
    const result: Media.Result = .{
        .key = key,
        .generation = 0,
        .state = .pending,
        .retry_at = now + 10000,
    };
    images.accept(&result);
    try std.testing.expect(!entry.wantsRequest(now));
    try std.testing.expect(!entry.wantsRequest(now + 9999));
    try std.testing.expect(entry.wantsRequest(now + 10000));
    try std.testing.expect(!entry.canRetry());
    try std.testing.expect(entry.availableTexture() == null);
}

test "failed SDL uploads remain retryable and account only for resident textures" {
    try openWindow(320, 240, "Image upload retry");
    defer closeWindow();
    var images = ImageCache{};
    defer images.deinit();
    const key: Media.Key = .init(@splat(0), .avatar);
    const entry = images.touch(key) orelse return error.OutOfMemory;
    var pixel = [_]u8{
        12,
        34,
        56,
        255,
    };
    const result: Media.Result = .{
        .key = key,
        .generation = 0,
        .state = .ready,
        .pixels = .{
            .data = &pixel,
            .width = 1,
            .height = 1,
            .bytes = pixel.len,
        },
    };
    graphics.deinit();
    images.accept(&result);
    try std.testing.expect(entry.availableTexture() == null);
    try std.testing.expect(entry.canRetry());
    try std.testing.expect(entry.content.unavailable.retry_at > u.now());
    try std.testing.expectEqual(@as(usize, 0), images.bytes);

    try graphics.init();
    retry(entry);
    try std.testing.expect(entry.wantsRequest(u.now()));
    images.accept(&result);
    try std.testing.expect(entry.availableTexture() != null);
    try std.testing.expect(!entry.canRetry());
    try std.testing.expectEqual(@as(usize, 4), images.bytes);
    try std.testing.expectEqual(@as(u8, 0), entry.attempts);
    images.contextChanged(false);
    try std.testing.expectEqual(@as(usize, 0), images.bytes);
}
fn closeWindow() void {
    graphics.deinit();
    desktop.close();
}

test "circular photos crop rectangular sources and respect scaled clipping" {
    try openWindow(640, 480, "Circular photo clipping");
    defer closeWindow();
    var pixels: [6 * 2]graphics.Color = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = if (i % 6 == 0) .red else if (i % 6 == 5) .sky_blue else .{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    };
    const texture = try graphics.upload(@ptrCast(&pixels), 6, 2, .linear);
    defer graphics.destroyTexture(texture);
    const target = try graphics.createTarget(128, 128);
    defer graphics.destroyTarget(target);
    for ([_]f32{
        1,
        1.25,
        2,
    }) |scale| {
        graphics.beginTarget(target);
        graphics.setScale(scale);
        graphics.clear(.black);
        graphics.clip(.{
            .x = 0,
            .y = 0,
            .width = 32,
            .height = 64,
        });
        drawAvatar(texture, .{
            .x = 8,
            .y = 8,
            .width = 48,
            .height = 48,
        }, .white);
        graphics.endClip();
        graphics.endTarget();
        const shot = try graphics.readTexture(target);
        defer graphics.destroyImage(shot);

        try std.testing.expectEqual(graphics.Color{
            .r = 0,
            .g = 255,
            .b = 0,
            .a = 255,
        }, graphics.imageColor(shot, @intFromFloat(16 * scale), @intFromFloat(32 * scale)));
        // Corner pixels exclude the quad outside the circle; the right half is clipped.
        try std.testing.expectEqual(graphics.Color.black, graphics.imageColor(shot, @intFromFloat(9 * scale), @intFromFloat(9 * scale)));
        try std.testing.expectEqual(graphics.Color.black, graphics.imageColor(shot, @intFromFloat(40 * scale), @intFromFloat(32 * scale)));
    }
}
