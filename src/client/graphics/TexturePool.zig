//! Bounded FIFO of retired static textures. SDL flushes queued uses before an upload overwrites one.
const std = @import("std");
const c = @import("../desktop.zig").c;
const TexturePool = @This();

textures: [128]*c.SDL_Texture,
len: usize,
bytes: usize,

pub const empty: TexturePool = .{
    .textures = undefined,
    .len = 0,
    .bytes = 0,
};
const max_bytes = 8 * 1024 * 1024;

/// Transfers matching storage to the caller, who must overwrite its pixels before drawing.
pub fn take(pool: *TexturePool, format: c.SDL_PixelFormat, width: i32, height: i32) ?*c.SDL_Texture {
    for (pool.textures[0..pool.len], 0..) |texture, i| {
        if (texture.format == format and texture.w == width and texture.h == height)
            return pool.remove(i);
    }
    return null;
}

/// Takes ownership. Only static four-byte textures are retained; all others are destroyed.
pub fn retire(pool: *TexturePool, texture: *c.SDL_Texture) void {
    const properties = c.SDL_GetTextureProperties(texture);
    const access = c.SDL_GetNumberProperty(properties, c.SDL_PROP_TEXTURE_ACCESS_NUMBER, -1);
    if (access != c.SDL_TEXTUREACCESS_STATIC or
        (texture.format != c.SDL_PIXELFORMAT_RGBA32 and texture.format != c.SDL_PIXELFORMAT_ARGB8888) or
        size(texture) > max_bytes)
    {
        c.SDL_DestroyTexture(texture);
        return;
    }
    while (pool.len == pool.textures.len or pool.bytes + size(texture) > max_bytes)
        c.SDL_DestroyTexture(pool.remove(0));
    pool.textures[pool.len] = texture;
    pool.len += 1;
    pool.bytes += size(texture);
}

pub fn deinit(pool: *TexturePool) void {
    for (pool.textures[0..pool.len]) |texture| c.SDL_DestroyTexture(texture);
    pool.* = undefined;
}

fn remove(pool: *TexturePool, index: usize) *c.SDL_Texture {
    const texture = pool.textures[index];
    std.mem.copyForwards(*c.SDL_Texture, pool.textures[index .. pool.len - 1], pool.textures[index + 1 .. pool.len]);
    pool.len -= 1;
    pool.bytes -= size(texture);
    return texture;
}

fn size(texture: *c.SDL_Texture) usize {
    return @as(usize, @intCast(texture.w)) * @as(usize, @intCast(texture.h)) * 4;
}
