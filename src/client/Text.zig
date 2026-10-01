const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("desktop.zig");
const graphics = @import("graphics.zig");
const c = @import("c.zig").api;
const display = @import("display.zig");
const theme = @import("theme.zig");
const Text = @This();
const a = std.heap.page_allocator;

entries: std.ArrayList(Entry) = .empty,
texture_bytes: usize = 0,
frame: u64 = 0,
scale: f32 = 1,

// Keep logical font sizes unchanged; display scaling is applied separately.
pub const font_scale = 1.0;
pub const Weight = enum(c_int) {
    // Use the native font-weight scale: 400 regular and 600 semibold.
    normal = 400,
    semibold = 600,
};
pub const Style = struct {
    size: i32,
    weight: Weight = .normal,
};
pub const Range = struct {
    start: usize,
    end: usize,
};
const Entry = struct {
    hash: u64,
    text: []const u8,
    layout: *c.ZcText,
    texture: ?graphics.Texture = null,
    tile_top: i32 = -1,
    used: u64 = 0,
    width: f32,
    height: f32,
    ink_center_y: ?f32 = null,
    fallback: bool = false,
    raster_failed: bool = false,
    color: graphics.Color = graphics.Color.white,
    background: ?graphics.Color = null,
    start: usize = 0,
    end: usize = 0,
};
// 32 MiB bounds cached glyph textures while retaining several visible screens of text.
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
        s.texture_bytes -= graphics.textureBytes(tx);
        graphics.destroyTexture(tx);
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
    return s.getStyled(text, .{ .size = size }, width, single_line, subpixel);
}
fn getStyled(s: *Text, text: []const u8, style: Style, width: f32, single_line: bool, subpixel: bool) !*Entry {
    var hash = std.hash.Wyhash.init(0);
    hash.update(text);
    hash.update(std.mem.asBytes(&style.size));
    hash.update(std.mem.asBytes(&style.weight));
    hash.update(std.mem.asBytes(&single_line));
    hash.update(std.mem.asBytes(&subpixel));
    if (!std.math.isFinite(width) or !std.math.isFinite(s.scale) or s.scale < 0.5 or s.scale > 8) return error.TextLayoutFailed;
    // Stay below the native 4096-pixel raster width after scale and two pixels of layout margin.
    const w: i32 = @intFromFloat(std.math.clamp(width, 1, 4096 / s.scale - 2));
    hash.update(std.mem.asBytes(&w));
    const key = hash.final();
    for (s.entries.items) |*e| if (e.hash == key and std.mem.eql(u8, e.text, text)) {
        e.used = s.frame;
        return e;
    };
    // Match the native 64 KiB shaping cap; larger content uses the bounded preview fallback.
    const original = if (text.len <= 65536) c.zc_text_new_weighted(
        text.ptr,
        @intCast(text.len),
        @as(f64, @floatFromInt(style.size)) * font_scale,
        w,
        s.scale,
        @intFromBool(single_line),
        @intFromBool(subpixel),
        @intFromEnum(style.weight),
    ) else null;
    const layout = original orelse c.zc_text_new_weighted(
        display.unavailable.ptr,
        display.unavailable.len,
        @as(f64, @floatFromInt(style.size)) * font_scale,
        w,
        s.scale,
        @intFromBool(single_line),
        @intFromBool(subpixel),
        @intFromEnum(style.weight),
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
    // 384 layouts retains recent visible text while bounding Pango objects independently of
    // textures.
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
    // Stay below the native 4096-pixel raster width after scale and two pixels of layout margin.
    const w: i32 = @intFromFloat(std.math.clamp(width, 1, 4096 / s.scale - 2));
    // Match the native 64 KiB shaping cap; larger content uses the bounded preview fallback.
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
    color: graphics.Color,
    background: ?graphics.Color,
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
    color: graphics.Color,
    background: ?graphics.Color,
) void {
    s.drawLineStyled(text, x, y, .{ .size = size }, width, color, background);
}
/// Draws one ellipsized line using the requested font size and weight.
pub fn drawLineStyled(
    s: *Text,
    text: []const u8,
    x: f32,
    y: f32,
    style: Style,
    width: f32,
    color: graphics.Color,
    background: ?graphics.Color,
) void {
    const e = s.getStyled(text, style, width, true, isOpaque(background)) catch return;
    s.drawEntry(e, x, y, color, 0, 0, background);
}
pub fn drawLineCentered(
    s: *Text,
    text: []const u8,
    bounds: graphics.Rect,
    size: i32,
    color: graphics.Color,
    background: ?graphics.Color,
) void {
    const e = s.get(text, size, bounds.width, true, isOpaque(background)) catch return;
    // Center the visible glyphs, excluding font bearings and texture padding.
    const x = bounds.x + bounds.width / 2 - @as(f32, @floatCast(c.zc_text_ink_center_x(e.layout)));
    const y = bounds.y + bounds.height / 2 - @as(f32, @floatCast(c.zc_text_ink_center_y(e.layout)));
    s.drawEntry(e, x, y, color, 0, 0, background);
}
pub fn lineSize(s: *Text, text: []const u8, size: i32, width: f32) graphics.Point {
    return s.lineSizeStyled(text, .{ .size = size }, width);
}
/// Measures one ellipsized line with the same metrics used by drawLineStyled.
pub fn lineSizeStyled(s: *Text, text: []const u8, style: Style, width: f32) graphics.Point {
    const e = s.getStyled(text, style, width, true, true) catch return .{ .x = 0, .y = 18 };
    return .{ .x = e.width, .y = e.height };
}
/// Returns the visible glyph center relative to the line's drawing origin at the current scale.
pub fn lineInkCenterY(s: *Text, text: []const u8, size: i32, width: f32) f32 {
    const e = s.get(text, size, width, true, true) catch return 9;
    if (e.ink_center_y) |center| return center;
    const fallback: f32 = @floatCast(c.zc_text_ink_center_y(e.layout));
    const height_pixels = c.zc_text_height(e.layout);
    // Keep one-shot rasterization within the native 2048-row tile limit.
    if (height_pixels > 2048) return fallback;
    // Hinting and fallback fonts can put ink outside Pango's reported extents.
    // Measure a neutral raster once per cached layout at its actual display scale.
    const pixels = c.zc_text_pixels_on(
        e.layout,
        0xffffffff,
        0,
        0,
        0,
        height_pixels,
        0x000000ff,
    );
    if (pixels == null) return fallback;
    defer c.zc_text_clear_pixels(e.layout);
    const stride: usize = @intCast(c.zc_text_pitch(e.layout));
    var first = height_pixels;
    var last: i32 = 0;
    var y: i32 = 0;
    while (y < height_pixels) : (y += 1) {
        const row = pixels + @as(usize, @intCast(y)) * stride;
        var x: usize = 0;
        const pixel_width: usize = @intCast(c.zc_text_width(e.layout));
        while (x < pixel_width * 4) : (x += 4) {
            const argb = std.mem.readInt(u32, row[x..][0..4], builtin.target.cpu.arch.endian());
            if (argb & 0x00ffffff == 0) continue;
            first = @min(first, y);
            last = y;
            break;
        }
    }
    const center = if (first <= last)
        @as(f32, @floatFromInt(first + last + 1)) / (2 * s.scale)
    else
        fallback;
    e.ink_center_y = center;
    return center;
}
/// Returns the font's capital-letter center relative to this line's drawing origin.
/// Descenders and accents do not move the center; fallback fonts may move the line's baseline.
pub fn lineCapCenterY(s: *Text, text: []const u8, size: i32, width: f32) f32 {
    const e = s.get(text, size, width, true, true) catch return 9;
    const baseline: f32 = @floatCast(c.zc_text_baseline(e.layout));
    const reference_width = @as(f32, @floatFromInt(size)) * 2;
    const reference = s.get("H", size, reference_width, true, true) catch return baseline;
    const reference_baseline: f32 = @floatCast(c.zc_text_baseline(reference.layout));
    return baseline - reference_baseline + s.lineInkCenterY("H", size, reference_width);
}
pub fn inkCenterY(s: *Text, text: []const u8, size: i32, width: f32) f32 {
    const e = s.get(text, size, width, false, true) catch return 9;
    return @floatCast(c.zc_text_ink_center_y(e.layout));
}
pub fn drawSelection(
    s: *Text,
    text: []const u8,
    x: f32,
    y: f32,
    size: i32,
    width: f32,
    color: graphics.Color,
    start: usize,
    end: usize,
    background: ?graphics.Color,
) void {
    const e = s.get(text, size, width, false, isOpaque(background)) catch return;
    s.drawEntry(e, x, y, color, start, end, background);
}
fn isOpaque(background: ?graphics.Color) bool {
    return if (background) |color| color.a == 255 else false;
}
const Underline = struct {
    origin: graphics.Point,
    scale: f32,
    color: graphics.Color,

    fn draw(user: ?*anyopaque, x: f64, y: f64, width: f64, line_height: f64) callconv(.c) void {
        const line: *const Underline = @ptrCast(@alignCast(user.?));
        graphics.rectangle(.{
            .x = @round((line.origin.x + @as(f32, @floatCast(x))) * line.scale) / line.scale,
            .y = @round((line.origin.y + @as(f32, @floatCast(y + line_height)) - 1) * line.scale) / line.scale,
            .width = @floatCast(width),
            .height = 1 / line.scale,
        }, line.color);
    }
};
/// Underline an IME range through wrapping and bidirectional layout using the same shaped text.
pub fn underline(s: *Text, text: []const u8, origin: graphics.Point, width: f32, range: Range) void {
    const e = s.get(text, 16, width, false, true) catch return;
    if (e.fallback) return;
    var line = Underline{
        .origin = origin,
        .scale = s.scale,
        .color = theme.colors.accent,
    };
    c.zc_text_ranges(e.layout, @intCast(range.start), @intCast(range.end), Underline.draw, &line);
}
fn rgba(color: graphics.Color) u32 {
    return (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | color.a;
}
fn drawEntry(
    s: *Text,
    e: *Entry,
    x: f32,
    y: f32,
    color: graphics.Color,
    start: usize,
    end: usize,
    background: ?graphics.Color,
) void {
    if (e.raster_failed or y >= @as(f32, @floatFromInt(desktop.height())) or y + e.height <= 0) return;
    const full_height = c.zc_text_height(e.layout);
    // Align tiles to 256-pixel bands so small scroll movements reuse cached rasterization.
    var top: i32 = @intFromFloat(@floor(@min(
        @as(f32, @floatFromInt(full_height)),
        @max(0, -y) * s.scale,
    ) / 256) * 256);
    const visible_end: i32 = @intFromFloat(@min(
        @as(f32, @floatFromInt(full_height)),
        @ceil((@as(f32, @floatFromInt(desktop.height())) - y) * s.scale / 256) * 256,
    ));
    // Very tall/high-DPI windows can span several bounded texture tiles.
    while (top < visible_end) {
        // Match the native raster cap while allowing tall windows to draw several bounded tiles.
        const tile_height = @min(visible_end - top, 2048);
        if (tile_height <= 0) return;
        if (e.texture != null and (e.tile_top != top or e.texture.?.h != tile_height or !std.meta.eql(
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
            const pixels = c.zc_text_pixels_with_selection(
                e.layout,
                rgba(color),
                if (e.fallback) 0 else @intCast(start),
                if (e.fallback) 0 else @intCast(end),
                top,
                tile_height,
                if (background) |bg| rgba(bg) else 0,
                rgba(theme.colors.selection),
            );
            if (pixels == null) {
                e.raster_failed = true;
                return;
            }
            defer c.zc_text_clear_pixels(e.layout);
            e.texture = graphics.uploadPixels(.{
                .bytes = pixels,
                .width = c.zc_text_width(e.layout),
                .height = tile_height,
                .pitch = c.zc_text_pitch(e.layout),
                .format = .cairo_argb,
            }, .nearest) catch {
                e.raster_failed = true;
                return;
            };
            s.texture_bytes += bytes;
            // Pango already antialiases at framebuffer resolution. Copy its pixels
            // 1:1 so texture filtering does not add another blur pass.
        }
        const tx = e.texture.?;
        graphics.drawRaster(tx, .{
            .x = x,
            .y = y + @as(f32, @floatFromInt(top)) / s.scale,
        });
        top += tile_height;
    }
}
pub fn caret(s: *Text, text: []const u8, width: f32, index: usize) graphics.Rect {
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

/// Returns byte bounds without splitting a grapheme. Internal apostrophes and
/// hyphens belong to words; other punctuation is selected on its own.
pub fn wordHit(s: *Text, text: []const u8, width: f32, x: f32, y: f32) Range {
    const e = s.get(text, 16, width, false, true) catch return .{ .start = 0, .end = 0 };
    if (e.fallback) return .{ .start = 0, .end = 0 };
    var start: c_int = 0;
    var end: c_int = 0;
    c.zc_text_word_hit(e.layout, @intFromFloat(x), @intFromFloat(y), &start, &end);
    return .{ .start = @intCast(start), .end = @intCast(end) };
}
