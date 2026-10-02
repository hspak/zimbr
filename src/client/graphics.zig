//! SDL rendering in logical coordinates. SDL owns batching, textures and render targets.
//! Resource creation, drawing and destruction belong to the GUI thread.
const std = @import("std");
const a = std.heap.page_allocator;
const desktop = @import("desktop.zig");
const geometry = @import("geometry.zig");
const TexturePool = @import("graphics/TexturePool.zig");
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Color = geometry.Color;
const c = desktop.c;
const png = @cImport({
    @cInclude("png.h");
});
const log = std.log.scoped(.client_graphics);

pub const Texture = *c.SDL_Texture;
pub const Image = *c.SDL_Surface;
pub const Vertex = c.SDL_Vertex;
pub const Filter = enum { nearest, linear };
pub const ResourceError = error{ GraphicsUnavailable, InvalidDimensions };
pub const SaveError = std.mem.Allocator.Error || error{ InvalidPath, ImageOutputUnavailable };
pub const Pixels = struct {
    bytes: [*]const u8,
    width: i32,
    height: i32,
    pitch: i32,
    format: enum { rgba, cairo_argb },
};

var renderer: ?*c.SDL_Renderer = null;
var retired: TexturePool = .empty;
var transform: Point = .{ .x = 1, .y = 1 };

/// Owns the window renderer until deinit. Destroy textures before deinit.
pub fn init() ResourceError!void {
    // Environment overrides remain available for diagnostics and driver comparisons.
    _ = c.SDL_SetHintWithPriority(c.SDL_HINT_RENDER_DRIVER, "vulkan,opengl", c.SDL_HINT_DEFAULT);
    renderer = c.SDL_CreateRenderer(desktop.window(), null) orelse {
        log.err("SDL renderer: {s}", .{c.SDL_GetError()});
        return error.GraphicsUnavailable;
    };
    errdefer deinit();
    log.info("SDL renderer: {s}", .{c.SDL_GetRendererName(renderer)});
    if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND))
        return error.GraphicsUnavailable;
    beginFrame();
}
pub fn deinit() void {
    retired.deinit();
    retired = .empty;
    c.SDL_DestroyRenderer(renderer);
    renderer = null;
}
pub fn flush() void {
    check(c.SDL_FlushRenderer(renderer));
}
fn check(ok: bool) void {
    if (!ok) log.err("SDL rendering: {s}", .{c.SDL_GetError()});
}
pub fn beginFrame() void {
    transform = desktop.scale();
}
pub fn endFrame() void {
    desktop.present();
}
pub fn clear(color: Color) void {
    setColor(color);
    check(c.SDL_RenderClear(renderer));
}
fn setColor(color: Color) void {
    check(c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a));
}
pub fn scale() Point {
    return transform;
}
/// Set a physical scale for the current render target.
pub fn setScale(factor: f32) void {
    transform = .{ .x = factor, .y = factor };
}
pub fn resetScale() void {
    transform = desktop.scale();
}
/// Clip in logical coordinates, rounding framebuffer edges only once.
pub fn clip(bounds: Rect) void {
    const left = @floor(bounds.x * transform.x);
    const top = @floor(bounds.y * transform.y);
    const rect: c.SDL_Rect = .{
        .x = @intFromFloat(left),
        .y = @intFromFloat(top),
        .w = @intFromFloat(@max(0, @ceil((bounds.x + bounds.width) * transform.x) - left)),
        .h = @intFromFloat(@max(0, @ceil((bounds.y + bounds.height) * transform.y) - top)),
    };
    check(c.SDL_SetRenderClipRect(renderer, &rect));
}
pub fn endClip() void {
    check(c.SDL_SetRenderClipRect(renderer, null));
}
fn physical(bounds: Rect) c.SDL_FRect {
    return .{
        .x = bounds.x * transform.x,
        .y = bounds.y * transform.y,
        .w = bounds.width * transform.x,
        .h = bounds.height * transform.y,
    };
}
pub fn vertex(position: Point, uv: Point, color: Color) Vertex {
    return .{
        .position = .{ .x = position.x * transform.x, .y = position.y * transform.y },
        .tex_coord = .{ .x = uv.x, .y = uv.y },
        .color = .{
            .r = @as(f32, @floatFromInt(color.r)) / 255,
            .g = @as(f32, @floatFromInt(color.g)) / 255,
            .b = @as(f32, @floatFromInt(color.b)) / 255,
            .a = @as(f32, @floatFromInt(color.a)) / 255,
        },
    };
}
/// SDL copies the submitted geometry. Vertices are in framebuffer coordinates.
pub fn mesh(texture: ?Texture, vertices: []const Vertex, indices: []const u16) void {
    if (vertices.len == 0) return;
    check(c.SDL_RenderGeometryRaw(
        renderer,
        texture,
        &vertices[0].position.x,
        @sizeOf(Vertex),
        &vertices[0].color,
        @sizeOf(Vertex),
        &vertices[0].tex_coord.x,
        @sizeOf(Vertex),
        @intCast(vertices.len),
        if (indices.len == 0) null else indices.ptr,
        @intCast(indices.len),
        @sizeOf(u16),
    ));
}
pub fn triangles(texture: ?Texture, vertices: []const Vertex) void {
    std.debug.assert(vertices.len % 3 == 0);
    mesh(texture, vertices, &.{});
}
fn solid(point: Point, color: Color) Vertex {
    return vertex(point, .{ .x = 0, .y = 0 }, color);
}
pub fn triangle(p: Point, q: Point, r: Point, color: Color) void {
    triangles(null, &.{
        solid(p, color),
        solid(q, color),
        solid(r, color),
    });
}
pub fn rectangle(bounds: Rect, color: Color) void {
    setColor(color);
    const rect = physical(bounds);
    check(c.SDL_RenderFillRect(renderer, &rect));
}
pub fn outline(r: Rect, thickness: f32, color: Color) void {
    const t = @min(thickness, @min(r.width, r.height) / 2);
    rectangle(.{
        .x = r.x,
        .y = r.y,
        .width = r.width,
        .height = t,
    }, color);
    rectangle(.{
        .x = r.x,
        .y = r.y + r.height - t,
        .width = r.width,
        .height = t,
    }, color);
    rectangle(.{
        .x = r.x,
        .y = r.y + t,
        .width = t,
        .height = r.height - 2 * t,
    }, color);
    rectangle(.{
        .x = r.x + r.width - t,
        .y = r.y + t,
        .width = t,
        .height = r.height - 2 * t,
    }, color);
}
pub fn line(start: Point, end: Point, thickness: f32, color: Color) void {
    const delta = end.subtract(start);
    const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
    if (length == 0 or thickness <= 0) return;
    const side: Point = .{ .x = -delta.y * thickness / (2 * length), .y = delta.x * thickness / (2 * length) };
    const points = [_]Vertex{
        solid(start.subtract(side), color),
        solid(start.add(side), color),
        solid(end.add(side), color),
        solid(end.subtract(side), color),
    };
    mesh(null, &points, &.{
        0,
        1,
        2,
        0,
        2,
        3,
    });
}

/// Copies tightly packed straight RGBA bytes. Caller owns the resulting SDL texture.
pub fn upload(pixels: [*]const u8, width: i32, height: i32, filter: Filter) ResourceError!Texture {
    if (width <= 0 or width > std.math.maxInt(i32) / 4) return error.InvalidDimensions;
    return uploadPixels(.{
        .bytes = pixels,
        .width = width,
        .height = height,
        .pitch = width * 4,
        .format = .rgba,
    }, filter);
}
/// Borrows pixels until return. Cairo bytes retain their native ARGB layout and premultiplied alpha.
pub fn uploadPixels(pixels: Pixels, filter: Filter) ResourceError!Texture {
    if (pixels.width <= 0 or pixels.height <= 0 or pixels.width > std.math.maxInt(i32) / 4 or pixels.pitch < pixels.width * 4)
        return error.InvalidDimensions;
    const format: c.SDL_PixelFormat = switch (pixels.format) {
        .rgba => c.SDL_PIXELFORMAT_RGBA32,
        .cairo_argb => c.SDL_PIXELFORMAT_ARGB8888,
    };
    const texture = retired.take(format, pixels.width, pixels.height) orelse
        c.SDL_CreateTexture(renderer, format, c.SDL_TEXTUREACCESS_STATIC, pixels.width, pixels.height) orelse
        return error.GraphicsUnavailable;
    errdefer c.SDL_DestroyTexture(texture);
    const blend: c.SDL_BlendMode = switch (pixels.format) {
        .rgba => c.SDL_BLENDMODE_BLEND,
        .cairo_argb => c.SDL_BLENDMODE_BLEND_PREMULTIPLIED,
    };
    if (!c.SDL_SetTextureBlendMode(texture, blend) or
        !c.SDL_SetTextureScaleMode(texture, switch (filter) {
            .nearest => c.SDL_SCALEMODE_NEAREST,
            .linear => c.SDL_SCALEMODE_LINEAR,
        }) or
        !c.SDL_UpdateTexture(texture, null, pixels.bytes, pixels.pitch)) return error.GraphicsUnavailable;
    return texture;
}
pub fn textureBytes(texture: Texture) usize {
    return @as(usize, @intCast(texture.w)) * @as(usize, @intCast(texture.h)) * 4;
}
/// Releases ownership; bounded static texture storage may be retained until reuse or deinit.
pub fn destroyTexture(texture: Texture) void {
    retired.retire(texture);
}
pub fn drawTexture(texture: Texture, bounds: Rect) void {
    const rect = physical(bounds);
    check(c.SDL_RenderTexture(renderer, texture, null, &rect));
}
/// Copy a raster prepared at the current display scale, one source pixel per target pixel.
pub fn drawRaster(texture: Texture, origin: Point) void {
    const rect = c.SDL_FRect{
        .x = @round(origin.x * transform.x),
        .y = @round(origin.y * transform.y),
        .w = @floatFromInt(texture.w),
        .h = @floatFromInt(texture.h),
    };
    check(c.SDL_RenderTexture(renderer, texture, null, &rect));
}
pub fn destroyImage(image: Image) void {
    c.SDL_DestroySurface(image);
}
pub fn imageColor(image: Image, x: i32, y: i32) Color {
    std.debug.assert(x >= 0 and x < image.w and y >= 0 and y < image.h);
    std.debug.assert(image.format == c.SDL_PIXELFORMAT_RGBA32);
    const bytes: [*]const u8 = @ptrCast(image.pixels.?);
    return @as(*align(1) const Color, @ptrCast(bytes + @as(usize, @intCast(y * image.pitch + x * 4)))).*;
}
pub fn saveImage(image: Image, path: []const u8) SaveError!void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const name = try a.dupeZ(u8, path);
    defer a.free(name);
    std.debug.assert(image.format == c.SDL_PIXELFORMAT_RGBA32);
    var output = std.mem.zeroes(png.png_image);
    output.version = png.PNG_IMAGE_VERSION;
    output.width = @intCast(image.w);
    output.height = @intCast(image.h);
    output.format = png.PNG_FORMAT_RGBA;
    if (png.png_image_write_to_file(&output, name, 0, image.pixels, image.pitch, null) == 0)
        return error.ImageOutputUnavailable;
}
pub fn solidImage(width: i32, height: i32, color: Color) ResourceError!Image {
    if (width <= 0 or height <= 0) return error.InvalidDimensions;
    const image = c.SDL_CreateSurface(width, height, c.SDL_PIXELFORMAT_RGBA32) orelse return error.GraphicsUnavailable;
    errdefer c.SDL_DestroySurface(image);
    if (!c.SDL_FillSurfaceRect(image, null, c.SDL_MapSurfaceRGBA(image, color.r, color.g, color.b, color.a))) return error.GraphicsUnavailable;
    return image;
}
/// Own the returned RGBA surface. Rows follow SDL's top-to-bottom convention.
pub fn capture() ResourceError!Image {
    const image: Image = c.SDL_RenderReadPixels(renderer, null) orelse return error.GraphicsUnavailable;
    if (image.format == c.SDL_PIXELFORMAT_RGBA32) return image;
    defer c.SDL_DestroySurface(image);
    return c.SDL_ConvertSurface(image, c.SDL_PIXELFORMAT_RGBA32) orelse error.GraphicsUnavailable;
}
/// Own the returned target texture until destroyTexture.
pub fn createTarget(width: i32, height: i32) ResourceError!Texture {
    if (width <= 0 or height <= 0) return error.InvalidDimensions;
    return c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_TARGET, width, height) orelse error.GraphicsUnavailable;
}
pub const destroyTarget = destroyTexture;
pub fn beginTarget(target: Texture) void {
    check(c.SDL_SetRenderTarget(renderer, target));
    transform = .{ .x = 1, .y = 1 };
}
pub fn endTarget() void {
    check(c.SDL_SetRenderTarget(renderer, null));
    beginFrame();
}
/// Copies a texture into an owned RGBA surface, preserving its stored alpha.
pub fn readTexture(texture: Texture) ResourceError!Image {
    const target = try createTarget(texture.w, texture.h);
    defer destroyTarget(target);
    const previous = c.SDL_GetRenderTarget(renderer);
    if (!c.SDL_SetRenderTarget(renderer, target)) return error.GraphicsUnavailable;
    defer check(c.SDL_SetRenderTarget(renderer, previous));
    var blend: c.SDL_BlendMode = undefined;
    if (!c.SDL_GetTextureBlendMode(texture, &blend)) return error.GraphicsUnavailable;
    if (!c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_NONE)) return error.GraphicsUnavailable;
    defer check(c.SDL_SetTextureBlendMode(texture, blend));
    if (!c.SDL_RenderTexture(renderer, texture, null, null)) return error.GraphicsUnavailable;
    return capture();
}

test "SDL rendering preserves clipping and queued textures through uploads and deletion" {
    try desktop.open(640, 480, "SDL resource ordering");
    defer desktop.close();
    try init();
    defer deinit();
    const target = try createTarget(128, 64);
    defer destroyTarget(target);
    beginTarget(target);
    clear(.black);
    const first = try upload(&.{
        255,
        0,
        0,
        255,
    }, 1, 1, .nearest);
    drawTexture(first, .{
        .x = 0,
        .y = 0,
        .width = 32,
        .height = 64,
    });
    // Uploading another texture must not disturb a queued draw.
    const second = upload(&.{
        0,
        255,
        0,
        255,
    }, 1, 1, .nearest) catch |err| {
        destroyTexture(first);
        return err;
    };
    defer destroyTexture(second);
    clip(.{
        .x = 40,
        .y = 10,
        .width = 16,
        .height = 20,
    });
    drawTexture(second, .{
        .x = 32,
        .y = 0,
        .width = 32,
        .height = 64,
    });
    endClip();
    drawTexture(first, .{
        .x = 64,
        .y = 32,
        .width = 16,
        .height = 16,
    });
    destroyTexture(first);
    // Many queued operations followed by a marker must preserve submission order.
    for (0..3000) |_| rectangle(.{
        .x = 80,
        .y = 10,
        .width = 8,
        .height = 8,
    }, .white);
    rectangle(.{
        .x = 110,
        .y = 10,
        .width = 8,
        .height = 8,
    }, .{
        .r = 0,
        .g = 0,
        .b = 255,
        .a = 255,
    });
    endTarget();
    const shot = try readTexture(target);
    defer destroyImage(shot);

    try std.testing.expectEqual(Color{
        .r = 255,
        .g = 0,
        .b = 0,
        .a = 255,
    }, imageColor(shot, 16, 20));
    try std.testing.expectEqual(Color{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    }, imageColor(shot, 48, 20));
    try std.testing.expectEqual(Color{
        .r = 255,
        .g = 0,
        .b = 0,
        .a = 255,
    }, imageColor(shot, 72, 40));
    try std.testing.expectEqual(Color.black, imageColor(shot, 36, 20));
    try std.testing.expectEqual(Color.black, imageColor(shot, 48, 40));
    try std.testing.expectEqual(Color.white, imageColor(shot, 84, 14));
    try std.testing.expectEqual(Color{
        .r = 0,
        .g = 0,
        .b = 255,
        .a = 255,
    }, imageColor(shot, 114, 14));
}

test "native Cairo uploads respect row pitch and premultiplied alpha" {
    try desktop.open(320, 240, "Cairo texture contract");
    defer desktop.close();
    try init();
    defer deinit();
    const pixels = [_]u32{
        0x80800000,
        0xffffffff,
        0xff00ff00,
        0xffffffff,
    };
    const texture = try uploadPixels(.{
        .bytes = @ptrCast(&pixels),
        .width = 1,
        .height = 2,
        .pitch = 8,
        .format = .cairo_argb,
    }, .nearest);
    defer destroyTexture(texture);
    const target = try createTarget(4, 4);
    defer destroyTarget(target);
    beginTarget(target);
    setScale(1);
    clear(.{
        .r = 0,
        .g = 0,
        .b = 255,
        .a = 255,
    });
    drawRaster(texture, .{ .x = 0, .y = 0 });
    endTarget();
    const shot = try readTexture(target);
    defer destroyImage(shot);
    const mixed = imageColor(shot, 0, 0);
    try std.testing.expectEqual(@as(u8, 128), mixed.r);
    try std.testing.expectEqual(@as(u8, 0), mixed.g);
    try std.testing.expect(mixed.b >= 126 and mixed.b <= 128);
    try std.testing.expectEqual(@as(u8, 255), mixed.a);
    try std.testing.expectEqual(Color{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    }, imageColor(shot, 0, 1));
}

test "retired textures respect count and byte limits and exclude render targets" {
    try desktop.open(320, 240, "Texture retention limits");
    defer desktop.close();
    try init();
    defer deinit();
    const pixels = [_]u8{255} ** (132 * 4);
    for (1..133) |width| {
        destroyTexture(try upload(&pixels, @intCast(width), 1, .nearest));
    }
    try std.testing.expectEqual(@as(usize, 128), retired.len);
    // FIFO eviction removes the oldest sizes, which otherwise accumulate after window resizes.
    for (retired.textures[0..retired.len]) |texture| try std.testing.expect(texture.w >= 5);

    const large = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, 2048, 1024) orelse return error.GraphicsUnavailable;
    destroyTexture(large);
    try std.testing.expectEqual(@as(usize, 1), retired.len);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), retired.bytes);
    const oversized = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, 2048, 1025) orelse return error.GraphicsUnavailable;
    destroyTexture(oversized);
    destroyTarget(try createTarget(16, 16));
    try std.testing.expectEqual(@as(usize, 1), retired.len);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), retired.bytes);
}

test "texture uploads preserve distinct pixels across batch rollover and buffer growth" {
    try desktop.open(320, 240, "Upload batch ordering");
    defer desktop.close();
    try init();
    defer deinit();
    desktop.poll();

    // Exceed the Vulkan upload batch, then cycle command buffers with growing and shrinking data.
    for (0..9) |frame| {
        beginFrame();
        setScale(1);
        clear(.black);
        var textures: std.ArrayList(Texture) = .empty;
        defer {
            for (textures.items) |texture| destroyTexture(texture);
            textures.deinit(std.testing.allocator);
        }
        try textures.ensureTotalCapacity(std.testing.allocator, 160);
        const width = 1 + frame % 3;
        for (0..160) |i| {
            const pixel = [_]u8{
                @intCast(i),
                @intCast(255 - i),
                @intCast(frame * 20),
                255,
            };
            const pixels = pixel ** 3;
            textures.appendAssumeCapacity(try upload(&pixels, @intCast(width), 1, .nearest));
        }
        for (textures.items, 0..) |texture, i| drawTexture(texture, .{
            .x = @floatFromInt((i % 16) * 8),
            .y = @floatFromInt((i / 16) * 8),
            .width = 8,
            .height = 8,
        });
        const shot = try capture();
        defer destroyImage(shot);
        endFrame();
        for (0..160) |i| try std.testing.expectEqual(Color{
            .r = @intCast(i),
            .g = @intCast(255 - i),
            .b = @intCast(frame * 20),
            .a = 255,
        }, imageColor(shot, @intCast((i % 16) * 8 + 4), @intCast((i / 16) * 8 + 4)));
    }
}

test "mixed geometry index widths preserve pixels across primitives and flushes" {
    try desktop.open(320, 240, "Indexed geometry ordering");
    defer desktop.close();
    try init();
    defer deinit();
    const target = try createTarget(180, 64);
    defer destroyTarget(target);
    const texture = try upload(&.{
        255,
        255,
        255,
        255,
    }, 1, 1, .nearest);
    defer destroyTexture(texture);
    beginTarget(target);
    clear(.black);
    const colors = [_]Color{
        .{
            .r = 255,
            .g = 0,
            .b = 0,
            .a = 255,
        },
        .{
            .r = 0,
            .g = 255,
            .b = 0,
            .a = 255,
        },
        .{
            .r = 0,
            .g = 0,
            .b = 255,
            .a = 255,
        },
        .{
            .r = 255,
            .g = 255,
            .b = 0,
            .a = 255,
        },
    };
    const indices8 = [_]u8{
        2,
        1,
        0,
        3,
        2,
        0,
    };
    const indices16 = [_]u16{
        2,
        1,
        0,
        3,
        2,
        0,
    };
    const indices32 = [_]u32{
        2,
        1,
        0,
        3,
        2,
        0,
    };
    for ([_]c_int{
        0,
        1,
        2,
        4,
    }, colors, 0..) |size, color, i| {
        const x: f32 = @floatFromInt(i * 40 + 5);
        const quad = [_]Vertex{
            vertex(.{ .x = x, .y = 5 }, .{ .x = 0, .y = 0 }, color),
            vertex(.{ .x = x + 30, .y = 5 }, .{ .x = 1, .y = 0 }, color),
            vertex(.{ .x = x + 30, .y = 35 }, .{ .x = 1, .y = 1 }, color),
            vertex(.{ .x = x, .y = 35 }, .{ .x = 0, .y = 1 }, color),
        };
        var expanded_vertices: [6]Vertex = undefined;
        for (&expanded_vertices, indices8) |*v, index| v.* = quad[index];
        const vertices: []const Vertex = if (size == 0) &expanded_vertices else &quad;
        const indices: ?*const anyopaque = switch (size) {
            0 => null,
            1 => &indices8,
            2 => &indices16,
            4 => &indices32,
            else => unreachable,
        };
        try std.testing.expect(c.SDL_RenderGeometryRaw(
            renderer,
            if (i % 2 == 0) texture else null,
            &vertices[0].position.x,
            @sizeOf(Vertex),
            &vertices[0].color,
            @sizeOf(Vertex),
            &vertices[0].tex_coord.x,
            @sizeOf(Vertex),
            @intCast(vertices.len),
            indices,
            if (indices != null) 6 else 0,
            size,
        ));
        // A flush consumes the CPU streams but leaves prior GPU draws pending.
        if (i == 1) flush();
        setColor(.white);
        try std.testing.expect(c.SDL_RenderPoint(renderer, x + 15, 45));
        try std.testing.expect(c.SDL_RenderLine(renderer, x, 55, x + 30, 55));
    }
    const shot = try readTexture(target);
    defer destroyImage(shot);
    for (colors, 0..) |color, i| {
        const x: i32 = @intCast(i * 40 + 20);
        try std.testing.expectEqual(color, imageColor(shot, x, 20));
        try std.testing.expectEqual(Color.white, imageColor(shot, x, 45));
        try std.testing.expectEqual(Color.white, imageColor(shot, x, 55));
        try std.testing.expectEqual(Color.black, imageColor(shot, x, 40));
    }
}
