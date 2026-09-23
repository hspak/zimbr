const clay = @import("zclay");
const rl = @import("raylib");
pub const Areas = struct { sidebar: rl.Rectangle, sidebar_footer: rl.Rectangle, header: rl.Rectangle, history: rl.Rectangle, composer: rl.Rectangle, status: rl.Rectangle };
fn rect(name: []const u8) rl.Rectangle {
    const b = clay.getElementData(.ID(name)).bounding_box;
    return .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height };
}
pub fn frame(width: f32, height: f32) Areas {
    const footer_height = 36;
    clay.setLayoutDimensions(.{ .w = width, .h = height });
    clay.beginLayout();
    clay.UI()(.{ .id = .ID("root"), .layout = .{ .sizing = .grow, .direction = .left_to_right } })({
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(if (width < 950) 270 else 310), .h = .grow }, .direction = .top_to_bottom } })({
            clay.UI()(.{ .id = .ID("sidebar"), .layout = .{ .sizing = .grow } })({});
            clay.UI()(.{ .id = .ID("sidebar_footer"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(footer_height) } } })({});
        });
        clay.UI()(.{ .layout = .{ .sizing = .grow, .direction = .top_to_bottom } })({
            clay.UI()(.{ .id = .ID("header"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(76) } } })({});
            clay.UI()(.{ .id = .ID("history"), .layout = .{ .sizing = .grow } })({});
            clay.UI()(.{ .id = .ID("composer"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(148) } } })({});
            clay.UI()(.{ .id = .ID("status"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(footer_height) } } })({});
        });
    });
    _ = clay.endLayout();
    return .{ .sidebar = rect("sidebar"), .sidebar_footer = rect("sidebar_footer"), .header = rect("header"), .history = rect("history"), .composer = rect("composer"), .status = rect("status") };
}
