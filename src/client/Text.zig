const std = @import("std");
const rl = @import("raylib");
const c = @import("c.zig").api;
const display = @import("display.zig");
const Text = @This();
const a = std.heap.page_allocator;

entries: std.ArrayList(Entry) = .empty,
texture_bytes: usize = 0,
frame: u64 = 0,
scale: f32 = 1,

// Apply the same modest reduction to labels, messages, and editor metrics.
pub const font_scale = 0.94;
const Entry = struct {
    hash: u64,
    text: []const u8,
    layout: *c.ZcText,
    texture: ?rl.Texture2D = null,
    tile_top: i32 = -1,
    used: u64 = 0,
    width: f32,
    height: f32,
    fallback: bool = false,
    raster_failed: bool = false,
    color: rl.Color = rl.Color.white,
    background: ?rl.Color = null,
    start: usize = 0,
    end: usize = 0,
};
const max_texture_bytes = 32 * 1024 * 1024;
pub fn deinit(s: *Text) void {
    for (s.entries.items) |*e| {
        c.zc_text_free(e.layout);
        s.dropTexture(e);
        a.free(e.text);
    }
    s.entries.deinit(a);
    s.* = undefined;
}
fn dropTexture(s: *Text, e: *Entry) void {
    if (e.texture) |tx| {
        // raylib batches draws until EndDrawing. An evicted texture may still
        // be referenced by this frame; flush before deleting/reusing its GL id.
        rl.gl.rlDrawRenderBatchActive();
        rl.unloadTexture(tx);
        s.texture_bytes -= @as(usize, @intCast(tx.width)) * @as(usize, @intCast(tx.height)) * 4;
        e.texture = null;
    }
}
pub fn nextFrame(s: *Text, scale: f32) void {
    if (s.scale != scale) {
        s.deinit();
        s.* = .{};
    }
    s.scale = scale;
    s.frame += 1;
}
fn get(s: *Text, text: []const u8, size: i32, width: f32, single_line: bool, subpixel: bool) !*Entry {
    var hash = std.hash.Wyhash.init(0);
    hash.update(text);
    hash.update(std.mem.asBytes(&size));
    hash.update(std.mem.asBytes(&single_line));
    hash.update(std.mem.asBytes(&subpixel));
    if (!std.math.isFinite(width) or !std.math.isFinite(s.scale) or s.scale < 0.5 or s.scale > 8) return error.TextLayoutFailed;
    const w: i32 = @intFromFloat(std.math.clamp(width, 1, 4096 / s.scale - 2));
    hash.update(std.mem.asBytes(&w));
    const key = hash.final();
    for (s.entries.items) |*e| if (e.hash == key and std.mem.eql(u8, e.text, text)) {
        e.used = s.frame;
        return e;
    };
    const original = if (text.len <= 65536) c.zc_text_new_with_options(
        text.ptr,
        @intCast(text.len),
        @as(f64, @floatFromInt(size)) * font_scale,
        w,
        s.scale,
        @intFromBool(single_line),
        @intFromBool(subpixel),
    ) else null;
    const layout = original orelse c.zc_text_new_with_options(
        display.unavailable.ptr,
        display.unavailable.len,
        @as(f64, @floatFromInt(size)) * font_scale,
        w,
        s.scale,
        @intFromBool(single_line),
        @intFromBool(subpixel),
    ) orelse return error.TextLayoutFailed;
    errdefer c.zc_text_free(layout);
    const copy = try a.dupe(u8, text);
    errdefer a.free(copy);
    const e = Entry{
        .hash = key,
        .text = copy,
        .layout = layout,
        .used = s.frame,
        .fallback = original == null,
        .width = @as(f32, @floatFromInt(c.zc_text_width(layout))) / s.scale,
        .height = @as(f32, @floatFromInt(c.zc_text_height(layout))) / s.scale,
    };
    // Bound the texture cache; layouts for offscreen rows have no GPU allocation.
    if (s.entries.items.len >= 384) {
        var oldest: usize = 0;
        for (s.entries.items, 0..) |entry, i| if (entry.used < s.entries.items[oldest].used) {
            oldest = i;
        };
        const old = &s.entries.items[oldest];
        c.zc_text_free(old.layout);
        s.dropTexture(old);
        a.free(old.text);
        s.entries.items[oldest] = e;
        return &s.entries.items[oldest];
    }
    try s.entries.append(a, e);
    return &s.entries.items[s.entries.items.len - 1];
}
pub fn height(s: *Text, text: []const u8, size: i32, width: f32) f32 {
    const e = s.get(text, size, width, false, true) catch return 24;
    return e.height;
}
// Offscreen history needs only metrics. Keeping these layouts in the drawing
// cache evicts visible glyphs and textures during every background batch.
pub fn measure(s: *Text, text: []const u8, size: i32, width: f32) f32 {
    if (!std.math.isFinite(width) or !std.math.isFinite(s.scale) or s.scale < 0.5 or s.scale > 8) return 24;
    const w: i32 = @intFromFloat(std.math.clamp(width, 1, 4096 / s.scale - 2));
    const original = if (text.len <= 65536) c.zc_text_new_with_options(
        text.ptr,
        @intCast(text.len),
        @as(f64, @floatFromInt(size)) * font_scale,
        w,
        s.scale,
        0,
        1,
    ) else null;
    const layout = original orelse c.zc_text_new_with_options(
        display.unavailable.ptr,
        display.unavailable.len,
        @as(f64, @floatFromInt(size)) * font_scale,
        w,
        s.scale,
        0,
        1,
    ) orelse return 24;
    defer c.zc_text_free(layout);
    return @as(f32, @floatFromInt(c.zc_text_height(layout))) / s.scale;
}
pub fn draw(
    s: *Text,
    text: []const u8,
    x: f32,
    y: f32,
    size: i32,
    width: f32,
    color: rl.Color,
    background: ?rl.Color,
) void {
    s.drawSelection(text, x, y, size, width, color, 0, 0, background);
}
pub fn drawLine(
    s: *Text,
    text: []const u8,
    x: f32,
    y: f32,
    size: i32,
    width: f32,
    color: rl.Color,
    background: ?rl.Color,
) void {
    const e = s.get(text, size, width, true, isOpaque(background)) catch return;
    s.drawEntry(e, x, y, color, 0, 0, background);
}
pub fn drawLineCentered(
    s: *Text,
    text: []const u8,
    bounds: rl.Rectangle,
    size: i32,
    color: rl.Color,
    background: ?rl.Color,
) void {
    const e = s.get(text, size, bounds.width, true, isOpaque(background)) catch return;
    // Center the visible glyphs, excluding font bearings and texture padding.
    const x = bounds.x + bounds.width / 2 - @as(f32, @floatCast(c.zc_text_ink_center_x(e.layout)));
    const y = bounds.y + bounds.height / 2 - @as(f32, @floatCast(c.zc_text_ink_center_y(e.layout)));
    s.drawEntry(e, x, y, color, 0, 0, background);
}
pub fn lineSize(s: *Text, text: []const u8, size: i32, width: f32) rl.Vector2 {
    const e = s.get(text, size, width, true, true) catch return .{ .x = 0, .y = 18 };
    return .{ .x = e.width, .y = e.height };
}
pub fn lineInkCenterY(s: *Text, text: []const u8, size: i32, width: f32) f32 {
    const e = s.get(text, size, width, true, true) catch return 9;
    return @floatCast(c.zc_text_ink_center_y(e.layout));
}
pub fn drawSelection(
    s: *Text,
    text: []const u8,
    x: f32,
    y: f32,
    size: i32,
    width: f32,
    color: rl.Color,
    start: usize,
    end: usize,
    background: ?rl.Color,
) void {
    const e = s.get(text, size, width, false, isOpaque(background)) catch return;
    s.drawEntry(e, x, y, color, start, end, background);
}
fn isOpaque(background: ?rl.Color) bool {
    return if (background) |color| color.a == 255 else false;
}
fn rgba(color: rl.Color) u32 {
    return (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | color.a;
}
fn drawEntry(
    s: *Text,
    e: *Entry,
    x: f32,
    y: f32,
    color: rl.Color,
    start: usize,
    end: usize,
    background: ?rl.Color,
) void {
    if (e.raster_failed or y >= @as(f32, @floatFromInt(rl.getScreenHeight())) or y + e.height <= 0) return;
    const full_height = c.zc_text_height(e.layout);
    var top: i32 = @intFromFloat(@floor(@min(
        @as(f32, @floatFromInt(full_height)),
        @max(0, -y) * s.scale,
    ) / 256) * 256);
    const visible_end: i32 = @intFromFloat(@min(
        @as(f32, @floatFromInt(full_height)),
        @ceil((@as(f32, @floatFromInt(rl.getScreenHeight())) - y) * s.scale / 256) * 256,
    ));
    // Very tall/high-DPI windows can span several bounded texture tiles.
    while (top < visible_end) {
        const tile_height = @min(visible_end - top, 2048);
        if (tile_height <= 0) return;
        if (e.texture != null and (e.tile_top != top or e.texture.?.height != tile_height or !std.meta.eql(
            e.color,
            color,
        ) or !std.meta.eql(
            e.background,
            background,
        ) or e.start != start or e.end != end)) s.dropTexture(e);
        if (e.texture == null) {
            const bytes = @as(usize, @intCast(c.zc_text_width(e.layout))) * @as(
                usize,
                @intCast(tile_height),
            ) * 4;
            for (s.entries.items) |*other| {
                if (s.texture_bytes + bytes <= max_texture_bytes) break;
                s.dropTexture(other);
            }
            e.tile_top = top;
            e.color = color;
            e.background = background;
            e.start = start;
            e.end = end;
            const pixels = c.zc_text_pixels_on(
                e.layout,
                rgba(color),
                if (e.fallback) 0 else @intCast(start),
                if (e.fallback) 0 else @intCast(end),
                top,
                tile_height,
                if (background) |bg| rgba(bg) else 0,
            );
            if (pixels == null) {
                e.raster_failed = true;
                return;
            }
            defer c.zc_text_clear_pixels(e.layout);
            e.texture = rl.loadTextureFromImage(.{
                .data = pixels,
                .width = c.zc_text_width(e.layout),
                .height = tile_height,
                .mipmaps = 1,
                .format = .uncompressed_r8g8b8a8,
            }) catch {
                e.raster_failed = true;
                return;
            };
            s.texture_bytes += bytes;
            // Pango already antialiases at framebuffer resolution. Copy its pixels
            // 1:1 so texture filtering does not add another blur pass.
            rl.setTextureFilter(e.texture.?, .point);
        }
        const tx = e.texture.?;
        // Like Flamez's label alignment, but snap to physical pixels so fractional
        // Wayland scaling and scrolling never place the texture between pixels.
        rl.drawTexturePro(tx, .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(tx.width),
            .height = @floatFromInt(tx.height),
        }, .{
            .x = @round(x * s.scale) / s.scale,
            .y = (@round(y * s.scale) + @as(f32, @floatFromInt(top))) / s.scale,
            .width = @as(f32, @floatFromInt(tx.width)) / s.scale,
            .height = @as(f32, @floatFromInt(tx.height)) / s.scale,
        }, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
        top += tile_height;
    }
}
pub fn caret(s: *Text, text: []const u8, width: f32, index: usize) rl.Rectangle {
    const e = s.get(text, 16, width, false, true) catch return .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 20,
    };
    if (e.fallback) return .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 20,
    };
    var x: c_int = 0;
    var y: c_int = 0;
    var h: c_int = 0;
    c.zc_text_caret(e.layout, @intCast(index), &x, &y, &h);
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = 1.5,
        .height = @floatFromInt(h),
    };
}
pub fn hit(s: *Text, text: []const u8, width: f32, x: f32, y: f32) usize {
    const e = s.get(text, 16, width, false, true) catch return 0;
    if (e.fallback) return 0;
    return @intCast(@max(0, c.zc_text_hit(e.layout, @intFromFloat(x), @intFromFloat(y))));
}
