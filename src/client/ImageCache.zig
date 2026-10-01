//! GUI-thread textures; immutable bytes and decoding belong to Media's worker.
const std = @import("std");
const desktop = @import("desktop.zig");
const graphics = @import("graphics.zig");
const Media = @import("Media.zig");
const t = @import("../protocol.zig").types;
const attachments = @import("../protocol.zig").attachments;
const u = @import("../common.zig");
const ImageCache = @This();
const a = std.heap.c_allocator;
const log = std.log.scoped(.client_images);

// Use the complete 64-character Media key so distinct cached representations remain separate.
entries: std.AutoHashMapUnmanaged([64]u8, Entry) = .empty,
bytes: usize = 0,
frame: u64 = 0,
changed: bool = false,

pub const Entry = struct {
    texture: ?graphics.Texture = null,
    bytes: usize = 0,
    used: u64 = 0,
    state: @FieldType(Media.Result, "state") = .pending,
    retry_at: i64 = 0,
    attempts: u8 = 0,
    requested: bool = false,
    // Match Media.Result's bounded, NUL-terminated diagnostic text.
    reason: [128:0]u8 = @splat(0),
    refresh_owner: bool = false,
    pub fn availableTexture(entry: Entry) ?graphics.Texture {
        return if (entry.state == .retired) null else entry.texture;
    }
};

pub fn deinit(s: *ImageCache) void {
    var it = s.entries.valueIterator();
    while (it.next()) |entry| if (entry.texture) |texture| graphics.destroyTexture(texture);
    s.entries.deinit(a);
    s.* = undefined;
}
pub fn contextChanged(s: *ImageCache, avatars: bool) void {
    var it = s.entries.iterator();
    while (it.next()) |entry| {
        if ((!avatars and entry.key_ptr[0] == 'a') or entry.value_ptr.texture == null) {
            if (entry.value_ptr.texture) |texture| {
                graphics.destroyTexture(texture);
                s.bytes -= entry.value_ptr.bytes;
            }
            entry.value_ptr.* = .{};
        }
    }
}
/// Borrows decoded pixels from the current media generation.
pub fn accept(s: *ImageCache, result: *const Media.Result) void {
    if (s.entries.getPtr(result.key)) |entry| {
        const attempts = entry.attempts;
        if (entry.texture) |texture| {
            graphics.destroyTexture(texture);
            s.bytes -= entry.bytes;
        }
        entry.* = .{
            .used = s.frame,
            .state = result.state,
            .retry_at = result.retry_at,
            .reason = result.reason,
            .attempts = attempts +| 1,
            .refresh_owner = result.state == .retired,
        };
        if (result.pixels.data != null and result.state == .ready) {
            const bytes = result.pixels.bytes;
            s.makeRoom(bytes);
            // makeRoom only clears entries; pointers remain valid.
            const texture = graphics.upload(@ptrCast(result.pixels.data.?), result.pixels.width, result.pixels.height, .linear) catch return;
            entry.texture = texture;
            entry.bytes = bytes;
            entry.attempts = 0;
            s.bytes += bytes;
        } else if (entry.retry_at != 0) {
            // Retry image failures from two seconds up to 30 seconds, doubling between attempts.
            const delay = @min(
                @as(i64, 30000),
                @as(i64, 2000) << @intCast(@min(entry.attempts -| 1, 4)),
            );
            entry.retry_at = @max(entry.retry_at, u.now() + delay);
        }
        s.changed = true;
    }
}
pub fn nextFrame(s: *ImageCache) void {
    s.frame +%= 1;
    s.changed = false;
    // Bound tiny-image textures and failure metadata as well as pixel bytes.
    // This runs before drawing, so no evicted texture is queued in a GL batch.
    // Trim to 896 entries, leaving 128 slots below the hard cap for this frame's new requests.
    while (s.entries.count() > 896) {
        var oldest: ?[64]u8 = null;
        var stamp: u64 = std.math.maxInt(u64);
        var it = s.entries.iterator();
        while (it.next()) |entry| if (entry.value_ptr.used <= stamp) {
            oldest = entry.key_ptr.*;
            stamp = entry.value_ptr.used;
        };
        const cache_key = oldest orelse break;
        const removed = s.entries.fetchRemove(cache_key).?.value;
        log.debug("Image {s}: memory cache entry evicted at entry limit", .{cache_key});
        if (removed.texture) |texture| {
            graphics.destroyTexture(texture);
            s.bytes -= removed.bytes;
        }
    }
}
fn makeRoom(s: *ImageCache, bytes: usize) void {
    while (s.bytes + bytes > Media.texture_budget) {
        var oldest: ?*Entry = null;
        var it = s.entries.valueIterator();
        while (it.next()) |entry| if (entry.texture != null and (oldest == null or entry.used < oldest.?.used)) {
            oldest = entry;
        };
        const entry = oldest orelse break;
        log.debug("Image texture evicted: {d} bytes; memory cache limit {d} bytes", .{
            entry.bytes,
            Media.texture_budget,
        });
        graphics.destroyTexture(entry.texture.?);
        s.bytes -= entry.bytes;
        entry.* = .{};
    }
}
pub fn get(s: *ImageCache, media: *Media, asset: t.AssetRef) ?*Entry {
    if (!media.avatars and asset.variant == .avatar) return null;
    const cache_key = media.key(asset);
    // Bound tiny textures and failure entries even when their pixel-byte cost is negligible.
    if (s.entries.count() >= 1024 and !s.entries.contains(cache_key)) return null;
    const value = s.entries.getOrPut(a, cache_key) catch return null;
    if (!value.found_existing) value.value_ptr.* = .{};
    const entry = value.value_ptr;
    entry.used = s.frame;
    if (asset.availability == .retired) {
        entry.refresh_owner = entry.state != .retired;
        entry.state = .retired;
        entry.requested = false;
        const reason = "Photo changed · refreshing message";
        @memset(&entry.reason, 0);
        @memcpy(entry.reason[0..reason.len], reason);
        return entry;
    }
    if (entry.texture == null and (!entry.requested and ((entry.state == .pending and entry.retry_at == 0) or (entry.retry_at > 0 and u.now() >= entry.retry_at)))) {
        media.request(asset) catch return entry;
        entry.requested = true;
    } else if (entry.requested) {
        // Refresh visibility and deduplicate in-flight work without extra GETs.
        media.request(asset) catch {};
    }
    return entry;
}
pub fn retry(entry: *Entry) void {
    entry.state = .pending;
    entry.requested = false;
    entry.retry_at = 0;
}

/// Borrow a local preview entry until the next cache mutation. Returns null when
/// capacity or allocation prevents caching; decoding failure remains an entry.
pub fn getLocal(s: *ImageCache, media: *Media, file: attachments.Upload) ?*Entry {
    const cache_key = media.localKey(file);
    // Bound tiny textures and failure entries even when their pixel-byte cost is negligible.
    if (s.entries.count() >= 1024 and !s.entries.contains(cache_key)) return null;
    const value = s.entries.getOrPut(a, cache_key) catch return null;
    if (!value.found_existing) value.value_ptr.* = .{};
    const entry = value.value_ptr;
    entry.used = s.frame;
    if (entry.texture == null and entry.state == .pending) {
        media.requestLocal(file) catch return entry;
        entry.requested = true;
    }
    return entry;
}
pub fn draw(texture: graphics.Texture, bounds: graphics.Rect) void {
    const scale = @min(
        bounds.width / @as(f32, @floatFromInt(texture.width)),
        bounds.height / @as(f32, @floatFromInt(texture.height)),
    );
    const w = @as(f32, @floatFromInt(texture.width)) * scale;
    const h = @as(f32, @floatFromInt(texture.height)) * scale;
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
    if (texture) |photo| if (photo.width <= 0 or photo.height <= 0) return;
    const center = graphics.Point{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
    // Center-crop rectangular photos to fill the circle without stretching.
    const uv: graphics.Point = if (texture) |photo| crop: {
        const size: f32 = @floatFromInt(@min(photo.width, photo.height));
        break :crop .{
            .x = size / @as(f32, @floatFromInt(photo.width)) / 2,
            .y = size / @as(f32, @floatFromInt(photo.height)) / 2,
        };
    } else .{ .x = 0, .y = 0 };
    const inner = @max(0, radius - 1 / @max(1, desktop.scale().x));
    var transparent = tint;
    transparent.a = 0;
    // 64 radial segments keep avatars smooth at ordinary and high display scales.
    const segments = 64;
    for (0..segments) |i| {
        const angle = -2 * std.math.pi * @as(f32, @floatFromInt(i)) / segments;
        const next = -2 * std.math.pi * @as(f32, @floatFromInt(i + 1)) / segments;
        const p = graphics.Point{ .x = @cos(angle), .y = @sin(angle) };
        const q = graphics.Point{ .x = @cos(next), .y = @sin(next) };
        const center_vertex = avatarVertex(center, .{ .x = 0, .y = 0 }, radius, uv, 0, tint);
        const inner_p = avatarVertex(center, p, radius, uv, inner, tint);
        const inner_q = avatarVertex(center, q, radius, uv, inner, tint);
        const outer_p = avatarVertex(center, p, radius, uv, radius, transparent);
        const outer_q = avatarVertex(center, q, radius, uv, radius, transparent);
        // A one-pixel transparent fringe smooths the edge at every DPI.
        graphics.triangles(texture, &.{
            center_vertex, inner_p, inner_q,
            inner_p,       outer_p, outer_q,
            inner_p,       outer_q, inner_q,
        });
    }
}

fn avatarVertex(
    center: graphics.Point,
    direction: graphics.Point,
    radius: f32,
    uv: graphics.Point,
    distance: f32,
    color: graphics.Color,
) graphics.Vertex {
    return .{
        .position = .{ .x = center.x + direction.x * distance, .y = center.y + direction.y * distance },
        .uv = .{ .x = 0.5 + direction.x * uv.x * distance / radius, .y = 0.5 + direction.y * uv.y * distance / radius },
        .color = color,
    };
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
    try std.testing.expect(queued.texture == null and queued.requested);
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
    }, image.color(0, 0));
    try std.testing.expectEqual(@as(usize, 4), images.bytes);
    images.contextChanged(false);
    try std.testing.expect(images.getLocal(&media, file).?.availableTexture() != null);
}

fn openWindow(width: i32, height: i32, title: [:0]const u8) !void {
    try desktop.open(width, height, title);
    errdefer desktop.close();
    try graphics.init();
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
        graphics.clip(0, 0, 32, 64);
        drawAvatar(texture, .{ .x = 8, .y = 8, .width = 48, .height = 48 }, .white);
        graphics.endClip();
        graphics.endTarget();
        const shot = try graphics.readTexture(target.texture);
        defer graphics.destroyImage(shot);
        shot.flip();
        try std.testing.expectEqual(graphics.Color{ .r = 0, .g = 255, .b = 0, .a = 255 }, shot.color(
            @intFromFloat(16 * scale),
            @intFromFloat(32 * scale),
        ));
        // Corner pixels exclude the quad outside the circle; the right half is clipped.
        try std.testing.expectEqual(graphics.Color.black, shot.color(@intFromFloat(9 * scale), @intFromFloat(9 * scale)));
        try std.testing.expectEqual(graphics.Color.black, shot.color(@intFromFloat(40 * scale), @intFromFloat(32 * scale)));
    }
}
