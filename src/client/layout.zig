//! Pure pane geometry in logical window coordinates.
const Rect = @import("geometry.zig").Rect;
pub const Areas = struct {
    rail: Rect,
    sidebar: Rect,
    sidebar_footer: Rect,
    header: Rect,
    history: Rect,
    composer: Rect,
};
// 32 logical pixels fits the connection status and its vertical padding.
pub const footer_height: f32 = 32;
// Eight pixels keeps the final sidebar row clear of the footer.
pub const list_bottom_padding: f32 = 8;
// Twenty pixels separates message content from the conversation edges.
pub const conversation_padding: f32 = 20;
// Sixteen pixels distinguishes adjacent messages without wasting a full text line.
pub const message_spacing: f32 = 16;
// The last row supplies the remaining gap; the composer box is shifted up one pixel.
pub const composer_top_padding: f32 = conversation_padding - message_spacing + 1;
// Align conversation actions with the 32-pixel inset used by settings and details.
pub const action_right_padding: f32 = 32;
// 64 pixels fits a 40-pixel navigation tile with 12-pixel margins.
const rail_width: f32 = 64;
// 244 pixels leaves space for a contact name, avatar, and unread badge.
const sidebar_width: f32 = 244;

pub fn conversationWidth(width: f32) f32 {
    return width - rail_width - sidebar_width;
}

pub fn footer(r: Rect) Rect {
    return .{
        .x = r.x,
        .y = r.y + r.height - footer_height,
        .width = r.width,
        .height = footer_height,
    };
}

pub fn frame(width: f32, height: f32, composer_height: f32) Areas {
    const conversation_x = rail_width + sidebar_width;
    const conversation_width = @max(0, width - conversation_x);
    const header_height = @min(64, height);
    const composer = @min(composer_height, @max(0, height - header_height));
    return .{
        .rail = .{ .x = 0, .y = 0, .width = rail_width, .height = height },
        .sidebar = .{
            .x = rail_width,
            .y = 0,
            .width = sidebar_width,
            .height = @max(0, height - footer_height),
        },
        .sidebar_footer = .{
            .x = rail_width,
            .y = @max(0, height - footer_height),
            .width = sidebar_width,
            .height = @min(footer_height, height),
        },
        .header = .{
            .x = conversation_x,
            .y = 0,
            .width = conversation_width,
            .height = header_height,
        },
        .history = .{
            .x = conversation_x,
            .y = header_height,
            .width = conversation_width,
            .height = @max(0, height - header_height - composer),
        },
        .composer = .{
            .x = conversation_x,
            .y = height - composer,
            .width = conversation_width,
            .height = composer,
        },
    };
}
