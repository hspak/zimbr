const clay = @import("zclay");
const rl = @import("raylib");
pub const Areas = struct {
    rail: rl.Rectangle,
    sidebar: rl.Rectangle,
    sidebar_footer: rl.Rectangle,
    header: rl.Rectangle,
    history: rl.Rectangle,
    composer: rl.Rectangle,
};
fn rect(name: []const u8) rl.Rectangle {
    const b = clay.getElementData(.ID(name)).bounding_box;
    return .{
        .x = b.x,
        .y = b.y,
        .width = b.width,
        .height = b.height,
    };
}
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

pub fn footer(r: rl.Rectangle) rl.Rectangle {
    return .{
        .x = r.x,
        .y = r.y + r.height - footer_height,
        .width = r.width,
        .height = footer_height,
    };
}

pub fn frame(width: f32, height: f32, composer_height: f32) Areas {
    clay.setLayoutDimensions(.{ .w = width, .h = height });
    clay.beginLayout();
    clay.UI()(.{ .id = .ID("root"), .layout = .{ .sizing = .grow, .direction = .top_to_bottom } })({
        clay.UI()(.{ .layout = .{ .sizing = .grow, .direction = .left_to_right } })({
            clay.UI()(.{ .id = .ID("rail"), .layout = .{ .sizing = .{ .w = .fixed(rail_width), .h = .grow } } })({});
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(sidebar_width), .h = .grow }, .direction = .top_to_bottom } })({
                clay.UI()(.{ .id = .ID("sidebar"), .layout = .{ .sizing = .grow } })({});
                clay.UI()(.{ .id = .ID("sidebar_footer"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(footer_height) } } })({});
            });
            clay.UI()(.{ .layout = .{ .sizing = .grow, .direction = .top_to_bottom } })({
                // The 64-pixel header fits an avatar plus two lines of conversation information.
                clay.UI()(.{ .id = .ID("header"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(64) } } })({});
                clay.UI()(.{ .id = .ID("history"), .layout = .{ .sizing = .grow } })({});
                clay.UI()(.{ .id = .ID("composer"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(composer_height) } } })({});
            });
        });
    });
    _ = clay.endLayout();
    return .{
        .rail = rect("rail"),
        .sidebar = rect("sidebar"),
        .sidebar_footer = rect("sidebar_footer"),
        .header = rect("header"),
        .history = rect("history"),
        .composer = rect("composer"),
    };
}
