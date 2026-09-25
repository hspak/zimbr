//! GUI-thread textures; immutable bytes and decoding belong to Media's worker.
const std = @import("std");
const rl = @import("raylib");
const Media = @import("Media.zig");
const t = @import("../protocol.zig").types;
const u = @import("../common.zig");
const ImageCache = @This();
const a = std.heap.c_allocator;
const log = std.log.scoped(.client_images);

entries: std.AutoHashMapUnmanaged([64]u8, Entry) = .empty,
bytes: usize = 0,
frame: u64 = 0,
changed: bool = false,

pub const Entry = struct {
    texture: ?rl.Texture2D = null,
    bytes: usize = 0,
    used: u64 = 0,
    state: @FieldType(Media.Result, "state") = .pending,
    retry_at: i64 = 0,
    attempts: u8 = 0,
    requested: bool = false,
    reason: [128:0]u8 = @splat(0),
    refresh_owner: bool = false,
    pub fn availableTexture(entry: Entry) ?rl.Texture2D {
        return if (entry.state == .retired) null else entry.texture;
    }
};

pub fn deinit(s: *ImageCache) void {
    var it = s.entries.valueIterator();
    while (it.next()) |entry| if (entry.texture) |texture| rl.unloadTexture(texture);
    s.entries.deinit(a);
    s.* = undefined;
}
pub fn contextChanged(s: *ImageCache, avatars: bool) void {
    var it = s.entries.iterator();
    while (it.next()) |entry| {
        if ((!avatars and entry.key_ptr[0] == 'a') or entry.value_ptr.texture == null) {
            if (entry.value_ptr.texture) |texture| {
                rl.unloadTexture(texture);
                s.bytes -= entry.value_ptr.bytes;
            }
            entry.value_ptr.* = .{};
        }
    }
}
pub fn nextFrame(s: *ImageCache, media: *Media) void {
    s.frame +%= 1;
    s.changed = false;
    if (media.take()) |result| {
        defer media.release(result);
        if (result.generation != media.generation) return;
        if (s.entries.getPtr(result.key)) |entry| {
            const attempts = entry.attempts;
            if (entry.texture) |texture| {
                rl.unloadTexture(texture);
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
                const image = rl.Image{
                    .data = result.pixels.data,
                    .width = result.pixels.width,
                    .height = result.pixels.height,
                    .mipmaps = 1,
                    .format = .uncompressed_r8g8b8a8,
                };
                // makeRoom only clears entries; pointers remain valid.
                const texture = rl.loadTextureFromImage(image) catch return;
                rl.setTextureFilter(texture, .bilinear);
                entry.texture = texture;
                entry.bytes = bytes;
                entry.attempts = 0;
                s.bytes += bytes;
            } else if (entry.retry_at != 0) {
                const delay = @min(
                    @as(i64, 30000),
                    @as(i64, 2000) << @intCast(@min(entry.attempts -| 1, 4)),
                );
                entry.retry_at = @max(entry.retry_at, u.now() + delay);
            }
            s.changed = true;
        }
    }
    // Bound tiny-image textures and failure metadata as well as pixel bytes.
    // This runs before drawing, so no evicted texture is queued in a GL batch.
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
            rl.unloadTexture(texture);
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
        rl.unloadTexture(entry.texture.?);
        s.bytes -= entry.bytes;
        entry.* = .{};
    }
}
pub fn get(s: *ImageCache, media: *Media, asset: t.AssetRef) ?*Entry {
    if (!media.avatars and asset.variant == .avatar) return null;
    const cache_key = media.key(asset);
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
pub fn draw(texture: rl.Texture2D, bounds: rl.Rectangle) void {
    const scale = @min(
        bounds.width / @as(f32, @floatFromInt(texture.width)),
        bounds.height / @as(f32, @floatFromInt(texture.height)),
    );
    const w = @as(f32, @floatFromInt(texture.width)) * scale;
    const h = @as(f32, @floatFromInt(texture.height)) * scale;
    rl.drawTexturePro(texture, .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(texture.width),
        .height = @floatFromInt(texture.height),
    }, .{
        .x = bounds.x + (bounds.width - w) / 2,
        .y = bounds.y + (bounds.height - h) / 2,
        .width = w,
        .height = h,
    }, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
}

/// Draws a circular, center-cropped photo, or a solid tint when texture is null.
pub fn drawAvatar(texture: ?rl.Texture2D, bounds: rl.Rectangle, tint: rl.Color) void {
    const radius = @min(bounds.width, bounds.height) / 2;
    if (radius <= 0) return;
    if (texture) |photo| if (photo.width <= 0 or photo.height <= 0) return;
    const center = rl.Vector2{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
    // Center-crop rectangular photos to fill the circle without stretching.
    const uv: rl.Vector2 = if (texture) |photo| crop: {
        const size: f32 = @floatFromInt(@min(photo.width, photo.height));
        break :crop .{
            .x = size / @as(f32, @floatFromInt(photo.width)) / 2,
            .y = size / @as(f32, @floatFromInt(photo.height)) / 2,
        };
    } else .{ .x = 0, .y = 0 };
    const inner = @max(0, radius - 1 / @max(1, rl.getWindowScaleDPI().x));
    var transparent = tint;
    transparent.a = 0;
    const segments = 64;
    rl.gl.rlSetTexture(if (texture) |photo| photo.id else rl.gl.rlGetTextureIdDefault());
    rl.gl.rlBegin(rl.gl.rl_triangles);
    rl.gl.rlNormal3f(0, 0, 1);
    for (0..segments) |i| {
        const angle = -2 * std.math.pi * @as(f32, @floatFromInt(i)) / segments;
        const next = -2 * std.math.pi * @as(f32, @floatFromInt(i + 1)) / segments;
        const p = rl.Vector2{ .x = @cos(angle), .y = @sin(angle) };
        const q = rl.Vector2{ .x = @cos(next), .y = @sin(next) };
        avatarVertex(center, .{ .x = 0, .y = 0 }, radius, uv, 0, tint);
        avatarVertex(center, p, radius, uv, inner, tint);
        avatarVertex(center, q, radius, uv, inner, tint);
        // A one-pixel transparent fringe smooths the edge at every DPI.
        avatarVertex(center, p, radius, uv, inner, tint);
        avatarVertex(center, p, radius, uv, radius, transparent);
        avatarVertex(center, q, radius, uv, radius, transparent);
        avatarVertex(center, p, radius, uv, inner, tint);
        avatarVertex(center, q, radius, uv, radius, transparent);
        avatarVertex(center, q, radius, uv, inner, tint);
    }
    rl.gl.rlEnd();
    rl.gl.rlSetTexture(0);
}

fn avatarVertex(
    center: rl.Vector2,
    direction: rl.Vector2,
    radius: f32,
    uv: rl.Vector2,
    distance: f32,
    color: rl.Color,
) void {
    rl.gl.rlColor4ub(color.r, color.g, color.b, color.a);
    rl.gl.rlTexCoord2f(
        0.5 + direction.x * uv.x * distance / radius,
        0.5 + direction.y * uv.y * distance / radius,
    );
    rl.gl.rlVertex2f(center.x + direction.x * distance, center.y + direction.y * distance);
}
