//! Bounded OpenGL 3.3 triangle batches. Coordinates are logical pixels; textures
//! contain straight-alpha RGBA. All operations belong to the GUI thread.
const std = @import("std");
const desktop = @import("desktop.zig");
const geometry = @import("geometry.zig");
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Color = geometry.Color;
const c = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
    @cInclude("png.h");
});
const a = std.heap.page_allocator;
const log = std.log.scoped(.client_graphics);

pub const Texture = struct { id: c_uint, width: i32, height: i32 };
pub const Target = struct { id: c_uint, texture: Texture };
pub const Filter = enum { nearest, linear };
pub const ResourceError = std.mem.Allocator.Error || error{ GraphicsUnavailable, InvalidDimensions };
pub const Vertex = extern struct { position: Point, uv: Point, color: Color };
pub const SaveError = std.mem.Allocator.Error || error{ InvalidPath, ImageOutputUnavailable };
pub const Image = struct {
    pixels: []Color,
    width: i32,
    height: i32,

    pub fn color(image: Image, x: i32, y: i32) Color {
        std.debug.assert(x >= 0 and x < image.width and y >= 0 and y < image.height);
        return image.pixels[@as(usize, @intCast(y)) * @as(usize, @intCast(image.width)) + @as(usize, @intCast(x))];
    }
    pub fn flip(image: Image) void {
        const width: usize = @intCast(image.width);
        for (0..@intCast(@divTrunc(image.height, 2))) |y| {
            const top = image.pixels[y * width ..][0..width];
            const bottom = image.pixels[(@as(usize, @intCast(image.height)) - y - 1) * width ..][0..width];
            for (top, bottom) |*p, *q| std.mem.swap(Color, p, q);
        }
    }
    /// Writes PNG bytes to path, propagating allocation and output errors.
    pub fn save(image: Image, path: []const u8) SaveError!void {
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const name = try a.dupeZ(u8, path);
        defer a.free(name);
        var png = std.mem.zeroes(c.png_image);
        png.version = c.PNG_IMAGE_VERSION;
        png.width = @intCast(image.width);
        png.height = @intCast(image.height);
        png.format = c.PNG_FORMAT_RGBA;
        if (c.png_image_write_to_file(&png, name, 0, image.pixels.ptr, 0, null) == 0)
            return error.ImageOutputUnavailable;
    }
};

/// Releases a captured or generated image. All copies become invalid after this call.
pub fn destroyImage(image: Image) void {
    a.free(image.pixels);
}

var program: c_uint = 0;
var vao: c_uint = 0;
var vbo: c_uint = 0;
var white: Texture = undefined;
var projection: c_int = -1;
var vertices: [12288]Vertex = undefined;
var count: usize = 0;
var texture_id: c_uint = 0;
var viewport_width: i32 = 0;
var viewport_height: i32 = 0;
var transform: Point = .{ .x = 1, .y = 1 };

/// Creates the renderer in the current SDL GL context. Deinit before closing the window.
pub fn init() ResourceError!void {
    const vertex = try shader(c.GL_VERTEX_SHADER,
        \\#version 330
        \\in vec2 vertexPosition;
        \\in vec2 vertexTexCoord;
        \\in vec4 vertexColor;
        \\out vec2 fragTexCoord;
        \\out vec4 fragColor;
        \\uniform mat4 mvp;
        \\void main() {
        \\    fragTexCoord = vertexTexCoord;
        \\    fragColor = vertexColor;
        \\    gl_Position = mvp * vec4(vertexPosition, 0.0, 1.0);
        \\}
    );
    defer c.glDeleteShader(vertex);
    const fragment = try shader(c.GL_FRAGMENT_SHADER,
        \\#version 330
        \\in vec2 fragTexCoord;
        \\in vec4 fragColor;
        \\out vec4 finalColor;
        \\uniform sampler2D texture0;
        \\void main() { finalColor = texture(texture0, fragTexCoord) * fragColor; }
    );
    defer c.glDeleteShader(fragment);
    program = c.glCreateProgram();
    errdefer {
        c.glDeleteProgram(program);
        program = 0;
    }
    c.glAttachShader(program, vertex);
    c.glAttachShader(program, fragment);
    c.glBindAttribLocation(program, 0, "vertexPosition");
    c.glBindAttribLocation(program, 1, "vertexTexCoord");
    c.glBindAttribLocation(program, 2, "vertexColor");
    c.glLinkProgram(program);
    var ok: c_int = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) return error.GraphicsUnavailable;
    projection = c.glGetUniformLocation(program, "mvp");
    c.glGenVertexArrays(1, &vao);
    errdefer c.glDeleteVertexArrays(1, &vao);
    c.glGenBuffers(1, &vbo);
    errdefer c.glDeleteBuffers(1, &vbo);
    c.glBindVertexArray(vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), null, c.GL_STREAM_DRAW);
    c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), null);
    c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "uv")));
    c.glVertexAttribPointer(2, 4, c.GL_UNSIGNED_BYTE, c.GL_TRUE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "color")));
    for (0..3) |i| c.glEnableVertexAttribArray(@intCast(i));
    c.glBindVertexArray(0);
    white = try upload(&.{
        255,
        255,
        255,
        255,
    }, 1, 1, .nearest);
    count = 0;
    texture_id = white.id;
    c.glDisable(c.GL_DEPTH_TEST);
    c.glDisable(c.GL_CULL_FACE);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glEnable(c.GL_MULTISAMPLE);
    beginFrame();
}
fn shader(kind: c_uint, source: [:0]const u8) ResourceError!c_uint {
    const id = c.glCreateShader(kind);
    errdefer c.glDeleteShader(id);
    const ptr = source.ptr;
    c.glShaderSource(id, 1, &ptr, null);
    c.glCompileShader(id);
    var ok: c_int = 0;
    c.glGetShaderiv(id, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var message: [1024]u8 = undefined;
        var length: c_int = 0;
        c.glGetShaderInfoLog(id, message.len, &length, &message);
        log.err("OpenGL shader: {s}", .{message[0..@intCast(length)]});
        return error.GraphicsUnavailable;
    }
    return id;
}
pub fn deinit() void {
    flush();
    c.glDeleteTextures(1, &white.id);
    c.glDeleteBuffers(1, &vbo);
    c.glDeleteVertexArrays(1, &vao);
    c.glDeleteProgram(program);
    program = 0;
    vbo = 0;
    vao = 0;
}
pub fn flush() void {
    if (count == 0) return;
    c.glUseProgram(program);
    const w: f32 = @floatFromInt(viewport_width);
    const h: f32 = @floatFromInt(viewport_height);
    const matrix = [16]f32{
        2 * transform.x / w,
        0,
        0,
        0,
        0,
        -2 * transform.y / h,
        0,
        0,
        0,
        0,
        -1,
        0,
        -1,
        1,
        0,
        1,
    };
    c.glUniformMatrix4fv(projection, 1, c.GL_FALSE, &matrix);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    c.glBindVertexArray(vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
    c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @intCast(count * @sizeOf(Vertex)), &vertices);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(count));
    c.glBindVertexArray(0);
    count = 0;
}
pub fn beginFrame() void {
    flush();
    viewport_width = desktop.pixelWidth();
    viewport_height = desktop.pixelHeight();
    transform = desktop.scale();
    c.glViewport(0, 0, viewport_width, viewport_height);
}
pub fn endFrame() void {
    flush();
    desktop.present();
}
pub fn clear(color: Color) void {
    flush();
    c.glClearColor(
        @as(f32, @floatFromInt(color.r)) / 255,
        @as(f32, @floatFromInt(color.g)) / 255,
        @as(f32, @floatFromInt(color.b)) / 255,
        @as(f32, @floatFromInt(color.a)) / 255,
    );
    c.glClear(c.GL_COLOR_BUFFER_BIT);
}
/// Replaces the window transform for physical-scale rendering tests.
pub fn setScale(scale: f32) void {
    flush();
    transform = .{ .x = scale, .y = scale };
}
pub fn resetScale() void {
    flush();
    transform = desktop.scale();
}
pub fn clip(x: i32, y: i32, width: i32, height: i32) void {
    flush();
    c.glEnable(c.GL_SCISSOR_TEST);
    const left = @as(f32, @floatFromInt(x)) * transform.x;
    const bottom = @as(f32, @floatFromInt(viewport_height)) -
        @as(f32, @floatFromInt(y + height)) * transform.y;
    c.glScissor(
        @intFromFloat(left),
        @intFromFloat(bottom),
        @intFromFloat(@as(f32, @floatFromInt(width)) * transform.x),
        @intFromFloat(@as(f32, @floatFromInt(height)) * transform.y),
    );
}
pub fn endClip() void {
    flush();
    c.glDisable(c.GL_SCISSOR_TEST);
}
/// Copies complete triangles into bounded staging storage. Flushes on texture or capacity changes.
pub fn triangles(texture: ?Texture, batch: []const Vertex) void {
    std.debug.assert(batch.len % 3 == 0);
    const id = if (texture) |t| t.id else white.id;
    if (texture_id != id) {
        flush();
        texture_id = id;
    }
    var offset: usize = 0;
    while (offset < batch.len) {
        if (count == vertices.len) flush();
        const n = @min(vertices.len - count, batch.len - offset);
        @memcpy(vertices[count..][0..n], batch[offset..][0..n]);
        count += n;
        offset += n;
    }
}
fn solid(p: Point, color: Color) Vertex {
    return .{
        .position = p,
        .uv = .{ .x = 0.5, .y = 0.5 },
        .color = color,
    };
}
pub fn triangle(p: Point, q: Point, r: Point, color: Color) void {
    triangles(null, &.{
        solid(p, color),
        solid(q, color),
        solid(r, color),
    });
}
pub fn rectangle(bounds: Rect, color: Color) void {
    const p: Point = .{ .x = bounds.x, .y = bounds.y };
    const q: Point = .{ .x = bounds.x, .y = bounds.y + bounds.height };
    const r: Point = .{ .x = bounds.x + bounds.width, .y = bounds.y + bounds.height };
    const s: Point = .{ .x = bounds.x + bounds.width, .y = bounds.y };
    triangles(null, &.{
        solid(p, color),
        solid(q, color),
        solid(r, color),
        solid(p, color),
        solid(r, color),
        solid(s, color),
    });
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
    const p = start.subtract(side);
    const q = start.add(side);
    const r = end.add(side);
    const s = end.subtract(side);
    triangles(null, &.{
        solid(p, color),
        solid(q, color),
        solid(r, color),
        solid(p, color),
        solid(r, color),
        solid(s, color),
    });
}
pub fn ring(center: Point, inner: f32, outer: f32, start: f32, end: f32, segments: i32, color: Color) void {
    if (outer <= 0 or segments <= 0) return;
    if (inner <= 0) return sector(center, outer, start, end, segments, color);
    const step = (end - start) / @as(f32, @floatFromInt(segments));
    var angle = start;
    for (0..@intCast(segments)) |_| {
        const p: Point = .{ .x = @cos(std.math.degreesToRadians(angle)), .y = @sin(std.math.degreesToRadians(angle)) };
        const q: Point = .{ .x = @cos(std.math.degreesToRadians(angle + step)), .y = @sin(std.math.degreesToRadians(angle + step)) };
        const v0 = solid(center.add(p.scale(inner)), color);
        const v1 = solid(center.add(p.scale(outer)), color);
        const v2 = solid(center.add(q.scale(outer)), color);
        const v3 = solid(center.add(q.scale(inner)), color);
        triangles(null, &.{
            v0,
            v1,
            v2,
            v0,
            v2,
            v3,
        });
        angle += step;
    }
}
pub fn sector(center: Point, radius: f32, start: f32, end: f32, segments: i32, color: Color) void {
    if (radius <= 0 or segments <= 0) return;
    const step = (end - start) / @as(f32, @floatFromInt(segments));
    var angle = start;
    for (0..@intCast(segments)) |_| {
        const p: Point = .{
            .x = @cos(std.math.degreesToRadians(angle)),
            .y = @sin(std.math.degreesToRadians(angle)),
        };
        const q: Point = .{
            .x = @cos(std.math.degreesToRadians(angle + step)),
            .y = @sin(std.math.degreesToRadians(angle + step)),
        };
        triangle(center, center.add(p.scale(radius)), center.add(q.scale(radius)), color);
        angle += step;
    }
}
pub fn rounded(r: Rect, roundness: f32, segments: i32, color: Color) void {
    const radius = @min(r.width, r.height) * std.math.clamp(roundness, 0, 1) / 2;
    if (radius <= 0) return rectangle(r, color);
    const left = r.x + radius;
    const right = r.x + r.width - radius;
    const top = r.y + radius;
    const bottom = r.y + r.height - radius;
    sector(.{ .x = left, .y = top }, radius, 180, 270, segments, color);
    sector(.{ .x = right, .y = top }, radius, 270, 360, segments, color);
    sector(.{ .x = right, .y = bottom }, radius, 0, 90, segments, color);
    sector(.{ .x = left, .y = bottom }, radius, 90, 180, segments, color);
    rectangle(.{
        .x = left,
        .y = r.y,
        .width = right - left,
        .height = radius,
    }, color);
    rectangle(.{
        .x = r.x,
        .y = top,
        .width = r.width,
        .height = bottom - top,
    }, color);
    rectangle(.{
        .x = left,
        .y = bottom,
        .width = right - left,
        .height = radius,
    }, color);
}
/// Assumes pixels contains width * height * 4 tightly packed RGBA bytes.
/// Borrows them for upload; own the returned texture until destroyTexture.
pub fn upload(pixels: [*]const u8, width: i32, height: i32, filter: Filter) ResourceError!Texture {
    try dimensions(width, height);
    var id: c_uint = 0;
    c.glGenTextures(1, &id);
    errdefer c.glDeleteTextures(1, &id);
    c.glBindTexture(c.GL_TEXTURE_2D, id);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels);
    const mode: c_int = switch (filter) {
        .nearest => c.GL_NEAREST,
        .linear => c.GL_LINEAR,
    };
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, mode);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, mode);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    try checkError();
    return .{
        .id = id,
        .width = width,
        .height = height,
    };
}
/// Flushes all references before deletion, including evictions during an active frame.
pub fn destroyTexture(texture: Texture) void {
    flush();
    c.glDeleteTextures(1, &texture.id);
}
pub fn drawTexture(texture: Texture, bounds: Rect) void {
    const p: Vertex = .{
        .position = .{ .x = bounds.x, .y = bounds.y },
        .uv = .{ .x = 0, .y = 0 },
        .color = .white,
    };
    const q: Vertex = .{
        .position = .{ .x = bounds.x, .y = bounds.y + bounds.height },
        .uv = .{ .x = 0, .y = 1 },
        .color = .white,
    };
    const r: Vertex = .{
        .position = .{ .x = bounds.x + bounds.width, .y = bounds.y + bounds.height },
        .uv = .{ .x = 1, .y = 1 },
        .color = .white,
    };
    const s: Vertex = .{
        .position = .{ .x = bounds.x + bounds.width, .y = bounds.y },
        .uv = .{ .x = 1, .y = 0 },
        .color = .white,
    };
    triangles(texture, &.{
        p,
        q,
        r,
        p,
        r,
        s,
    });
}
fn checkError() ResourceError!void {
    switch (c.glGetError()) {
        c.GL_NO_ERROR => {},
        c.GL_OUT_OF_MEMORY => return error.OutOfMemory,
        else => return error.GraphicsUnavailable,
    }
}
fn dimensions(width: i32, height: i32) ResourceError!void {
    var max_size: c_int = 0;
    c.glGetIntegerv(c.GL_MAX_TEXTURE_SIZE, &max_size);
    if (width <= 0 or height <= 0 or width > max_size or height > max_size) return error.InvalidDimensions;
}
fn allocateImage(width: i32, height: i32) ResourceError!Image {
    try dimensions(width, height);
    return .{
        .pixels = try a.alloc(Color, @as(usize, @intCast(width)) * @as(usize, @intCast(height))),
        .width = width,
        .height = height,
    };
}
pub fn solidImage(width: i32, height: i32, color: Color) ResourceError!Image {
    const image = try allocateImage(width, height);
    @memset(image.pixels, color);
    return image;
}
/// Captures the back buffer before presentation. Own the image until destroyImage.
pub fn capture() ResourceError!Image {
    flush();
    const image = try allocateImage(desktop.pixelWidth(), desktop.pixelHeight());
    errdefer destroyImage(image);
    c.glReadPixels(0, 0, image.width, image.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, image.pixels.ptr);
    try checkError();
    image.flip();
    // A window capture is opaque, independent of the framebuffer's alpha format.
    for (image.pixels) |*pixel| pixel.a = 255;
    return image;
}
/// Copies a texture in its stored row order. Own the image until destroyImage.
pub fn readTexture(texture: Texture) ResourceError!Image {
    flush();
    const image = try allocateImage(texture.width, texture.height);
    errdefer destroyImage(image);
    c.glBindTexture(c.GL_TEXTURE_2D, texture.id);
    c.glGetTexImage(c.GL_TEXTURE_2D, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, image.pixels.ptr);
    try checkError();
    return image;
}
/// Creates an offscreen color attachment; destroyTarget releases both framebuffer and texture.
pub fn createTarget(width: i32, height: i32) ResourceError!Target {
    const image = try solidImage(width, height, .black);
    defer destroyImage(image);
    const texture = try upload(@ptrCast(image.pixels.ptr), width, height, .nearest);
    errdefer destroyTexture(texture);
    var id: c_uint = 0;
    c.glGenFramebuffers(1, &id);
    errdefer c.glDeleteFramebuffers(1, &id);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, id);
    defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, texture.id, 0);
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return error.GraphicsUnavailable;
    return .{ .id = id, .texture = texture };
}
pub fn destroyTarget(target: Target) void {
    destroyTexture(target.texture);
    c.glDeleteFramebuffers(1, &target.id);
}
pub fn beginTarget(target: Target) void {
    flush();
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, target.id);
    viewport_width = target.texture.width;
    viewport_height = target.texture.height;
    c.glViewport(0, 0, viewport_width, viewport_height);
    transform = .{ .x = 1, .y = 1 };
}
pub fn endTarget() void {
    flush();
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    beginFrame();
}

test "triangle batches preserve clipping and queued textures through uploads and deletion" {
    try desktop.open(640, 480, "OpenGL resource ordering");
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
    // A second upload changes the GL binding while the first texture is still queued.
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
    clip(40, 10, 16, 20);
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
    // Overflow staging capacity without a texture switch, then draw a final marker.
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
    const shot = try readTexture(target.texture);
    defer destroyImage(shot);
    shot.flip();
    try std.testing.expectEqual(Color{
        .r = 255,
        .g = 0,
        .b = 0,
        .a = 255,
    }, shot.color(16, 20));
    try std.testing.expectEqual(Color{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    }, shot.color(48, 20));
    try std.testing.expectEqual(Color{
        .r = 255,
        .g = 0,
        .b = 0,
        .a = 255,
    }, shot.color(72, 40));
    try std.testing.expectEqual(Color.black, shot.color(36, 20));
    try std.testing.expectEqual(Color.black, shot.color(48, 40));
    try std.testing.expectEqual(Color.white, shot.color(84, 14));
    try std.testing.expectEqual(Color{
        .r = 0,
        .g = 0,
        .b = 255,
        .a = 255,
    }, shot.color(114, 14));
}
