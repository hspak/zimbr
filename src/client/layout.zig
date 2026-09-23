const clay = @import("zclay");
const rl = @import("raylib");
pub const Areas = struct { rail: rl.Rectangle, sidebar: rl.Rectangle, sidebar_footer: rl.Rectangle, header: rl.Rectangle, history: rl.Rectangle, composer: rl.Rectangle };
fn rect(name: []const u8) rl.Rectangle {
    const b = clay.getElementData(.ID(name)).bounding_box;
    return .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height };
}
pub const footer_height: f32 = 32;
pub const list_bottom_padding: f32 = 8;
pub const composer_top_padding: f32 = 8;
pub const action_right_padding: f32 = 32;

pub fn footer(r: rl.Rectangle) rl.Rectangle {
    return .{ .x = r.x, .y = r.y + r.height - footer_height, .width = r.width, .height = footer_height };
}

pub fn frame(width: f32, height: f32, composer_height: f32) Areas {
    clay.setLayoutDimensions(.{ .w = width, .h = height });
    clay.beginLayout();
    clay.UI()(.{ .id = .ID("root"), .layout = .{ .sizing = .grow, .direction = .top_to_bottom } })({
        clay.UI()(.{ .layout = .{ .sizing = .grow, .direction = .left_to_right } })({
            clay.UI()(.{ .id = .ID("rail"), .layout = .{ .sizing = .{ .w = .fixed(64), .h = .grow } } })({});
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(if (width < 950) 220 else 244), .h = .grow }, .direction = .top_to_bottom } })({
                clay.UI()(.{ .id = .ID("sidebar"), .layout = .{ .sizing = .grow } })({});
                clay.UI()(.{ .id = .ID("sidebar_footer"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(footer_height) } } })({});
            });
            clay.UI()(.{ .layout = .{ .sizing = .grow, .direction = .top_to_bottom } })({
                clay.UI()(.{ .id = .ID("header"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(64) } } })({});
                clay.UI()(.{ .id = .ID("history"), .layout = .{ .sizing = .grow } })({});
                clay.UI()(.{ .id = .ID("composer"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(composer_height) } } })({});
            });
        });
    });
    _ = clay.endLayout();
    return .{ .rail = rect("rail"), .sidebar = rect("sidebar"), .sidebar_footer = rect("sidebar_footer"), .header = rect("header"), .history = rect("history"), .composer = rect("composer") };
}
