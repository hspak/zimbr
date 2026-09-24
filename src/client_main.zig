const std = @import("std");
const rl = @import("raylib");
const clay = @import("zclay");
const client_options = @import("client_options");
const u = @import("common.zig");
const t = @import("protocol/types.zig");
const Config = @import("client/Config.zig");
const Worker = @import("client/Worker.zig");
const Editor = @import("client/Editor.zig");
const MessageSelection = @import("client/MessageSelection.zig");
const Text = @import("client/Text.zig");
const display = @import("client/display.zig");
const theme = @import("client/theme.zig");
const layout = @import("client/layout.zig");
const Scrollbar = @import("client/Scrollbar.zig");
const bridge = @import("client/c.zig").api;
const a = std.heap.page_allocator;

// Track framebuffer changes as well as logical size, as Flamez does. Moving a
// window between displays can change the former without changing the latter.
const WindowMetrics = struct {
    width: i32 = 0,
    height: i32 = 0,
    render_width: i32 = 0,
    render_height: i32 = 0,
    scale: f32 = 1,

    fn current() WindowMetrics {
        return .{
            .width = rl.getScreenWidth(),
            .height = rl.getScreenHeight(),
            .render_width = rl.getRenderWidth(),
            .render_height = rl.getRenderHeight(),
            // Match raylib's screenScale transform, including fractional DPI.
            .scale = @max(1, rl.getWindowScaleDPI().x),
        };
    }
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("zimbr: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn clayError(data: clay.ErrorData) callconv(.c) void {
    _ = data;
    std.log.warn("UI layout limit reached", .{});
}
fn run(init: std.process.Init) !void {
    const config = try Config.parse(init);
    rl.setTraceLogLevel(.warning);
    rl.setConfigFlags(.{ .window_resizable = true, .window_highdpi = true });
    rl.initWindow(1120, 780, "Zimbr");
    defer rl.closeWindow();
    bridge.zc_activation_init();
    defer bridge.zc_activation_free();
    // Let Wayland deliver its initial scale before caching any text textures.
    rl.pollInputEvents();
    rl.setWindowMinSize(780, 560);
    rl.setExitKey(.null);
    rl.setTargetFPS(120);
    _ = clay.initialize(.init(try init.arena.allocator().alloc(u8, clay.minMemorySize())), .{ .w = 1120, .h = 780 }, .{ .error_handler_function = clayError });
    var worker = Worker{ .io = init.io, .config = config };
    try worker.start();
    defer worker.shutdown();
    var app = App{ .worker = &worker, .enter_to_send = config.enter_to_send, .show_details = config.details };
    defer app.deinit();
    app.notifications = bridge.zc_notifications_new(App.notificationAction, &app);
    defer bridge.zc_notifications_free(app.notifications);
    var frames: usize = 0;
    var last_draw: i64 = 0;
    var active_until: f64 = 0;
    var last_generation: u64 = 0;
    var last_revision: u64 = 0;
    var last_mouse = rl.getMousePosition();
    var last_window = WindowMetrics{};
    while (!rl.windowShouldClose()) {
        bridge.zc_notifications_poll();
        try app.update();
        app.deliverNotifications();
        const generation = if (app.view) |v| v.generation else 0;
        const revision = app.composer.revision + app.search.revision + app.recipient.revision;
        const mouse = rl.getMousePosition();
        const window = WindowMetrics.current();
        const keyboard_input = for (std.enums.values(rl.KeyboardKey)) |key| {
            if (pressed(key)) break true;
        } else false;
        const input = keyboard_input or rl.isMouseButtonDown(.left) or rl.isMouseButtonReleased(.left) or rl.getMouseWheelMove() != 0 or mouse.x != last_mouse.x or mouse.y != last_mouse.y;
        const window_changed = rl.isWindowResized() or !std.meta.eql(window, last_window);
        const now = rl.getTime();
        // Keep rendering between input events so scrolling and key repeat do
        // not fall back to the idle polling cadence during an interaction.
        if (input or window_changed or revision != last_revision) active_until = now + 0.5;
        if (frames < 4 or config.frames > 0 or app.layout_pending or now < active_until or generation != last_generation or u.now() - last_draw >= 500) {
            app.capture_frame = config.screenshot != null and config.frames > 0 and frames + 1 >= config.frames;
            app.draw(window.scale);
            last_draw = u.now();
            last_generation = generation;
            last_revision = revision;
            last_mouse = mouse;
            last_window = window;
            frames += 1;
        } else {
            rl.waitTime(0.025);
            rl.pollInputEvents();
        }
        if (config.frames > 0 and frames >= config.frames) {
            if (config.screenshot) |path| {
                const shot = app.captured orelse return error.ScreenshotFailed;
                if (!rl.exportImage(shot, path)) return error.ScreenshotFailed;
            }
            break;
        }
    }
    try app.saveDraft();
}
const App = struct {
    worker: *Worker,
    notifications: ?*bridge.ZcNotifications = null,
    enter_to_send: bool = true,
    view: ?*Worker.View = null,
    text: Text = .{},
    heights: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    height_context: u64 = 0,
    height_cursor: usize = 0,
    history_arena: std.heap.ArenaAllocator = .init(a),
    history_rows: []HistoryRow = &.{},
    history_generation: ?u64 = null,
    layout_pending: bool = false,
    height_budget: usize = 0,
    height_deadline: i64 = 0,
    composer: Editor = .{},
    recipient: Editor = .{},
    search: Editor = .{},
    focus: enum { composer, recipient, search, none } = .composer,
    key: []const u8 = "",
    loaded_key: []const u8 = "",
    new_mode: bool = false,
    draft_dirty: bool = false,
    draft_at: i64 = 0,
    send_wait: bool = false,
    send_ack: u64 = 0,
    duplicate_risk: bool = false,
    scroll: f64 = 0,
    sidebar_scroll: f32 = 0,
    sidebar_bar: Scrollbar = .{},
    history_bar: Scrollbar = .{},
    details_bar: Scrollbar = .{},
    composer_bar: Scrollbar = .{},
    content_height: f64 = 0,
    history_anchor: []const u8 = "",
    anchor_offset: f64 = 0,
    anchor_pending: bool = false,
    following: bool = true,
    message_count: usize = 0,
    new_messages: bool = false,
    composer_scroll: f32 = 0,
    composer_revision: ?u64 = null,
    composer_caret: usize = 0,
    composer_width: f32 = 0,
    notice: []const u8 = "",
    notice_until: i64 = 0,
    message_selection: MessageSelection = .{},
    dragging: bool = false,
    was_reading: ?bool = null,
    show_details: bool = false,
    show_hidden: bool = false,
    details_scroll: f32 = 0,
    details_height: f32 = 0,
    capture_frame: bool = false,
    captured: ?rl.Image = null,
    fn deinit(s: *App) void {
        if (s.captured) |shot| rl.unloadImage(shot);
        if (s.view) |v| v.destroy();
        s.text.deinit();
        s.heights.deinit(a);
        s.history_arena.deinit();
        s.composer.deinit();
        s.recipient.deinit();
        s.search.deinit();
        a.free(s.key);
        a.free(s.loaded_key);
        s.message_selection.clear();
        a.free(s.history_anchor);
    }
    fn info(s: *App, msg: []const u8) void {
        s.notice = msg;
        s.notice_until = u.now() + 7000;
    }
    fn notificationAction(context: ?*anyopaque, chat: [*c]const u8, token: [*c]const u8) callconv(.c) void {
        const s: *App = @ptrCast(@alignCast(context.?));
        s.select(std.mem.span(chat)) catch {
            s.info("Could not open the conversation. Please try again.");
            return;
        };
        s.show_hidden = s.selectedHidden() orelse false;
        s.search.set("") catch {};
        s.layout_pending = true;
        rl.restoreWindow();
        if (bridge.zc_activation_activate(rl.getWindowHandle(), token) == 0) rl.setWindowFocused();
    }
    fn readingConversation(s: *const App) bool {
        return rl.isWindowFocused() and !rl.isWindowMinimized() and s.following and !s.show_details and !s.new_mode;
    }
    fn deliverNotifications(s: *App) void {
        while (s.worker.takeNotification()) |n| {
            defer n.destroy();
            if (s.readingConversation() and u.eq(s.key, n.chat)) continue;
            bridge.zc_notifications_show(s.notifications, n.chat, n.summary, n.body);
        }
        if (s.readingConversation()) {
            const key = a.dupeZ(u8, s.key) catch return;
            defer a.free(key);
            bridge.zc_notifications_dismiss(s.notifications, key);
        }
    }
    fn saveDraft(s: *App) !void {
        if (s.draft_dirty and s.key.len > 0) {
            try s.worker.push(.{ .kind = .draft, .key = s.key, .text = s.composer.text.items });
            s.draft_dirty = false;
        }
    }
    fn select(s: *App, key: []const u8) !void {
        s.show_details = false;
        try s.saveDraft();
        try s.worker.push(.{ .kind = .select, .key = key, .text = if (rl.isWindowFocused() and !rl.isWindowMinimized()) "yes" else "no" });
        s.message_selection.clear();
        a.free(s.key);
        s.key = try a.dupe(u8, key);
        s.following = true;
        a.free(s.history_anchor);
        s.history_anchor = "";
        s.scroll = 0;
        s.history_bar = .{};
        s.composer_bar = .{};
        s.new_messages = false;
        s.focus = .composer;
        s.new_mode = false;
        s.send_wait = false;
        s.duplicate_risk = false;
    }
    fn matchesSidebar(s: *const App, chat: @import("client/Store.zig").Chat) bool {
        return chat.hidden == s.show_hidden and (s.search.text.items.len == 0 or std.ascii.indexOfIgnoreCase(chatName(chat.value), s.search.text.items) != null);
    }
    fn firstSidebarKey(s: *const App) []const u8 {
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (s.matchesSidebar(chat)) return chat.value.id;
        };
        return "";
    }
    fn selectedHidden(s: *const App) ?bool {
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (u.eq(chat.value.id, s.key)) return chat.hidden;
        };
        return null;
    }
    fn reconcileSelection(s: *App) !void {
        if (s.new_mode or s.show_details) return;
        if (s.key.len > 0) {
            const hidden = s.selectedHidden() orelse return;
            if (hidden == s.show_hidden) return;
        }
        const next = s.firstSidebarKey();
        if (!u.eq(s.key, next)) try s.select(next);
    }
    fn toggleHidden(s: *App) !void {
        try s.saveDraft();
        try s.search.set("");
        s.show_hidden = !s.show_hidden;
        s.sidebar_scroll = 0;
        s.sidebar_bar = .{};
        try s.select(s.firstSidebarKey());
    }
    fn setSelectedHidden(s: *App, hidden: bool) !void {
        try s.saveDraft();
        // Wait for the worker's persisted snapshot before changing the list.
        try s.worker.push(.{ .kind = if (hidden) .hide else .unhide, .key = s.key });
    }
    fn update(s: *App) !void {
        if (s.worker.take()) |v| {
            // Metadata-only views retain the same immutable records, so their
            // history previews and measurements remain valid across updates.
            const same_history = if (s.view) |old| old.shared != null and v.shared != null and old.shared.?.history == v.shared.?.history and old.snapshot.pending.len == 0 and v.snapshot.pending.len == 0 else false;
            if (same_history and s.history_generation == s.view.?.content_generation) {
                s.history_generation = v.content_generation;
            } else if (s.view == null or v.content_generation == null or s.view.?.content_generation != v.content_generation) s.history_generation = null;
            if (s.view) |old| {
                if (!s.following and u.eq(old.snapshot.selected, v.snapshot.selected) and old.snapshot.messages.len > 0 and v.snapshot.messages.len > 0 and !u.eq(old.snapshot.messages[old.snapshot.messages.len - 1].id, v.snapshot.messages[v.snapshot.messages.len - 1].id)) s.new_messages = true;
                old.destroy();
            }
            s.view = v;
            if (s.key.len == 0 and v.snapshot.selected.len > 0) s.key = try a.dupe(u8, v.snapshot.selected);
            if (std.mem.startsWith(u8, s.key, "new:") and u.eq(s.key, v.redirect_from) and v.snapshot.selected.len > 0) {
                if (s.draft_dirty or (s.composer.text.items.len > 0 and !s.send_wait)) {
                    try s.saveDraft();
                    try s.worker.push(.{ .kind = .select, .key = s.key });
                } else {
                    a.free(s.key);
                    s.key = try a.dupe(u8, v.snapshot.selected);
                    s.send_wait = false;
                    s.following = true;
                }
            }
            if (u.eq(s.key, v.snapshot.selected)) {
                if (!u.eq(s.loaded_key, s.key)) {
                    try s.composer.set(v.snapshot.draft);
                    a.free(s.loaded_key);
                    s.loaded_key = try a.dupe(u8, s.key);
                    s.composer_scroll = 0;
                    s.message_count = v.snapshot.messages.len;
                }
                if (s.send_wait and v.ack > s.send_ack) {
                    try s.composer.set(v.snapshot.draft);
                    s.send_wait = false;
                    s.draft_dirty = false;
                    s.following = true;
                }
                s.message_count = v.snapshot.messages.len;
            }
        }
        try s.reconcileSelection();
        if (s.draft_dirty and u.now() - s.draft_at > 300) try s.saveDraft();
        const reading = s.readingConversation();
        if (s.was_reading == null or reading != s.was_reading.?) {
            s.worker.push(.{ .kind = .viewed, .text = if (reading) "yes" else "no" }) catch return;
            s.was_reading = reading;
        }
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        if (ctrl and rl.isKeyPressed(.f)) {
            s.message_selection.clear();
            s.focus = .search;
        }
        if (ctrl and rl.isKeyPressed(.d)) s.toggleDetails();
        if (ctrl and rl.isKeyPressed(.n)) try s.newMessage();
        if (s.show_details) {
            if (rl.isKeyPressed(.escape)) {
                s.toggleDetails();
                return;
            }
            if (s.focus != .search) {
                if (pressed(.page_down)) s.details_scroll += @as(f32, @floatFromInt(rl.getScreenHeight())) * 0.7;
                if (pressed(.page_up)) s.details_scroll -= @as(f32, @floatFromInt(rl.getScreenHeight())) * 0.7;
                if (pressed(.home)) s.details_scroll = 0;
                if (pressed(.end)) s.details_scroll = s.details_height;
                // Do not route keystrokes to the hidden composer.
                while (rl.getCharPressed() != 0) {}
                return;
            }
        }
        if (rl.isKeyPressed(.escape)) {
            s.message_selection.clear();
            s.new_mode = false;
            s.focus = .composer;
        }
        if (s.focus == .composer and s.readOnlyChat()) {
            s.focus = .none;
            s.dragging = false;
        }
        const editor: ?*Editor = switch (s.focus) {
            .composer => if (s.send_wait or !u.eq(s.key, s.loaded_key)) null else &s.composer,
            .recipient => &s.recipient,
            .search => &s.search,
            .none => null,
        };
        if (editor) |e| {
            const revision = e.revision;
            if (ctrl and rl.isKeyPressed(.a)) {
                e.anchor = 0;
                e.caret = e.text.items.len;
            }
            if (ctrl and (rl.isKeyPressed(.c) or rl.isKeyPressed(.x))) {
                if (e.selected().len > 0) {
                    const clip = try a.dupeZ(u8, e.selected());
                    defer a.free(clip);
                    rl.setClipboardText(clip);
                    if (rl.isKeyPressed(.x)) try e.insert("");
                }
            }
            if (ctrl and rl.isKeyPressed(.v)) {
                const clip = rl.getClipboardText();
                e.insert(clip) catch s.info("Text exceeds the 16 KiB limit or has invalid encoding.");
            }
            if (ctrl and rl.isKeyPressed(.z)) try e.history(shift);
            if (ctrl and rl.isKeyPressed(.y)) try e.history(true);
            if (pressed(.left)) e.move(-1, shift);
            if (pressed(.right)) e.move(1, shift);
            if (pressed(.backspace)) try e.delete(true);
            if (pressed(.delete)) try e.delete(false);
            if (pressed(.home)) {
                e.caret = if (ctrl) 0 else lineStart(e.text.items, e.caret);
                if (!shift) e.anchor = e.caret;
            }
            if (pressed(.end)) {
                e.caret = if (ctrl) e.text.items.len else lineEnd(e.text.items, e.caret);
                if (!shift) e.anchor = e.caret;
            }
            if (!ctrl) while (true) {
                const ch = rl.getCharPressed();
                if (ch == 0) break;
                if (ch < 32) continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(ch), &buf) catch continue;
                e.insert(buf[0..n]) catch s.info("Message exceeds the 16 KiB limit.");
            };
            if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) {
                switch (s.focus) {
                    .composer => if (shift or (!s.enter_to_send and !ctrl)) {
                        e.insert("\n") catch s.info("Message exceeds the 16 KiB limit.");
                    } else try s.send(),
                    .recipient => try s.startDirect(),
                    .search => s.focus = .composer,
                    .none => {},
                }
            }
            if (e.revision != revision and s.focus == .composer) {
                s.draft_dirty = true;
                s.draft_at = u.now();
            }
        } else {
            if (s.focus == .none and s.message_selection.id.len > 0) {
                if (ctrl and rl.isKeyPressed(.a)) s.message_selection.selectAll();
                if (ctrl and rl.isKeyPressed(.c) and s.message_selection.selected().len > 0) {
                    const clip = try a.dupeZ(u8, s.message_selection.selected());
                    defer a.free(clip);
                    rl.setClipboardText(clip);
                    s.info("Selected text copied");
                }
            }
            // Discard typing while an input is disabled instead of replaying
            // it when a writable conversation gains focus.
            while (rl.getCharPressed() != 0) {}
        }
    }
    fn newMessage(s: *App) !void {
        try s.saveDraft();
        s.message_selection.clear();
        s.show_details = false;
        s.show_hidden = false;
        s.new_mode = true;
        s.focus = .recipient;
    }
    fn startDirect(s: *App) !void {
        const address = std.mem.trim(u8, s.recipient.text.items, " \n\r\t");
        if (!t.validAddress(address)) {
            s.info("Use an international number (+country code) or an email address.");
            return;
        }
        const key = try std.fmt.allocPrint(a, "new:{s}", .{address});
        defer a.free(key);
        s.show_hidden = false;
        try s.select(key);
    }
    fn readOnlyChat(s: *const App) bool {
        if (std.mem.startsWith(u8, s.key, "new:")) return false;
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (u.eq(chat.value.id, s.key)) return !chat.value.sendable;
        };
        return false;
    }
    fn canSend(s: *App) bool {
        const v = s.view orelse return false;
        if (!v.online or s.send_wait or s.key.len == 0 or !u.eq(s.loaded_key, s.key) or std.mem.trim(u8, s.composer.text.items, " \r\n\t").len == 0) return false;
        if (std.mem.startsWith(u8, s.key, "new:")) return v.send_direct;
        if (!v.reply_existing) return false;
        for (v.snapshot.chats) |chat| if (u.eq(chat.value.id, s.key)) return chat.value.sendable;
        return false;
    }
    fn send(s: *App) !void {
        if (!s.canSend()) {
            s.info("Connect to a sendable iMessage conversation before sending.");
            return;
        }
        try s.saveDraft();
        try s.worker.push(.{ .kind = .send, .key = s.key, .text = s.composer.text.items, .recipient = if (std.mem.startsWith(u8, s.key, "new:")) s.key[4..] else "" });
        s.send_wait = true;
        s.send_ack = s.view.?.ack;
        s.following = true;
    }
    fn draw(s: *App, scale: f32) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        s.text.nextFrame(scale);
        s.layout_pending = false;
        const areas = layout.frame(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()), s.composerHeight());
        std.debug.assert(clip_depth == 0);
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(theme.colors.paper);
        rl.setMouseCursor(.default);
        s.drawRail(areas.rail);
        s.drawSidebar(areas.sidebar, ar);
        if (s.show_details) {
            s.drawDetails(.{ .x = areas.header.x, .y = areas.header.y, .width = areas.header.width, .height = areas.composer.y + areas.composer.height - areas.header.y }, ar);
        } else {
            s.drawHeader(areas.header, ar);
            beginClip(areas.history);
            if (s.new_mode) {
                const r = areas.history;
                s.text.draw("Start a conversation", r.x + 32, r.y + 34, 25, r.width - 64, theme.colors.ink, theme.colors.paper);
                s.text.draw("Send an iMessage to a phone number or email address.", r.x + 32, r.y + 72, 15, r.width - 64, theme.colors.muted, theme.colors.paper);
                const field = rl.Rectangle{ .x = r.x + 32, .y = r.y + 110, .width = r.width - 64, .height = 46 };
                s.inputBox(&s.recipient, field, "+1 415 555 0123 or name@example.com", .recipient, false);
                if (s.button(.{ .x = r.x + 32, .y = r.y + 176, .width = 164, .height = 36 }, "Continue", true)) s.startDirect() catch s.info("Could not open conversation.");
                s.text.draw("Existing groups appear in your conversations.\nCreating groups is not supported yet.", r.x + 32, r.y + 236, 14, r.width - 64, theme.colors.muted, theme.colors.paper);
            } else if (s.key.len > 0) s.drawHistory(areas.history, ar) else {
                const r = areas.history;
                s.text.draw(if (s.show_hidden) "No hidden conversations." else "Your conversations, here.", r.x + 36, r.y + r.height / 2 - 56, 27, r.width - 72, theme.colors.ink, theme.colors.paper);
                s.text.draw(if (s.show_hidden) "Conversations you hide appear here.\nYou can restore them at any time." else if (s.view != null and s.view.?.snapshot.chats.len > 0) "Open Hidden to restore a conversation,\nor start a new message." else "Connect to your Mac to get started.\nYour cached messages stay available offline.", r.x + 36, r.y + r.height / 2 - 4, 16, r.width - 72, theme.colors.muted, theme.colors.paper);
            }
            endClip();
            s.drawComposer(areas.composer);
        }
        const footer = areas.sidebar_footer;
        rl.drawRectangleRec(footer, theme.colors.sidebar);
        rl.drawLine(@intFromFloat(footer.x), @intFromFloat(footer.y), @intFromFloat(footer.x + footer.width), @intFromFloat(footer.y), theme.colors.line);
        const online = s.view != null and s.view.?.online;
        const status = if (online) "Connected to your Mac" else "Offline · drafts saved locally";
        const status_x = footer.x + sidebar_padding + sidebar_text_inset;
        const status_width = footer.x + footer.width - sidebar_padding - status_x;
        const status_size = s.text.lineSize(status, 11, status_width);
        const status_y = @round((footer.y + (footer.height - status_size.y) / 2) * scale) / scale;
        // Align with the visible glyphs, excluding the font's line and texture padding.
        const dot_y = status_y + s.text.lineInkCenterY(status, 11, status_width);
        rl.drawCircleV(.{ .x = footer.x + sidebar_padding + sidebar_icon_inset + sidebar_icon_size / 2, .y = dot_y }, 3, if (online) theme.colors.success else theme.colors.danger);
        s.text.drawLine(status, status_x, status_y, 11, status_width, theme.colors.muted, theme.colors.sidebar);
        const fps_width: f32 = if (client_options.fps_counter) 72 else 0;
        // Keep transient feedback in the composer's hint line without reserving
        // a second footer or repeating the sidebar's connection status.
        if (u.now() < s.notice_until) {
            const warning_visible = s.duplicate_risk and s.key.len > 0 and !s.new_mode and !s.show_details;
            var notice = composerFooter(areas.composer);
            if (warning_visible) notice.height /= 2;
            rl.drawRectangleRec(notice, theme.colors.paper);
            s.drawFooterLabel(display.label(ar, s.notice), notice, theme.colors.muted);
        }
        if (client_options.fps_counter) {
            var buffer: [32]u8 = undefined;
            const fps = std.fmt.bufPrint(&buffer, "{d} FPS", .{rl.getFPS()}) catch unreachable;
            const band = layout.footer(areas.composer);
            s.drawFooterLabel(fps, .{ .x = band.x + band.width - fps_width, .y = band.y, .width = fps_width - 12, .height = band.height }, theme.colors.muted);
        }
        if (s.capture_frame) {
            // Read the completed frame before swapping; Wayland may discard the
            // back buffer afterwards, making post-swap screenshots unreliable.
            rl.gl.rlDrawRenderBatchActive();
            if (s.captured) |old| rl.unloadImage(old);
            s.captured = rl.loadImageFromScreen() catch null;
        }
        if (!rl.isMouseButtonDown(.left)) s.message_selection.dragging = false;
    }
    fn toggleDetails(s: *App) void {
        s.show_details = !s.show_details;
        s.message_selection.clear();
        s.focus = if (s.show_details) .none else .composer;
        s.dragging = false;
        s.history_bar = .{};
        s.details_bar = .{};
        s.composer_bar = .{};
        s.worker.push(.{ .kind = .viewed, .text = if (!s.show_details and s.following and rl.isWindowFocused()) "yes" else "no" }) catch {};
    }
    const RailIcon = enum { messages, hidden, details };
    fn railItem(s: *App, r: rl.Rectangle, label: []const u8, icon: RailIcon, selected: bool) bool {
        const hot = hover(r);
        const bg = if (selected) theme.colors.selected else if (hot) theme.colors.avatar else theme.colors.rail;
        const tile = rl.Rectangle{ .x = r.x + 12, .y = r.y + 3, .width = 40, .height = 36 };
        if (selected or hot) rl.drawRectangleRounded(tile, 0.3, 8, bg);
        const color = if (selected or hot) theme.colors.ink else theme.colors.muted;
        const x = tile.x + 10;
        const y = tile.y + 9;
        switch (icon) {
            .messages => {
                rl.drawRectangleRoundedLinesEx(.{ .x = x, .y = y, .width = 20, .height = 15 }, 0.3, 8, 1.5, color);
                rl.drawLineEx(.{ .x = x + 4, .y = y + 15 }, .{ .x = x + 4, .y = y + 19 }, 1.5, color);
                rl.drawLineEx(.{ .x = x + 4, .y = y + 19 }, .{ .x = x + 9, .y = y + 15 }, 1.5, color);
                rl.drawLineEx(.{ .x = x + 5, .y = y + 6 }, .{ .x = x + 15, .y = y + 6 }, 1.5, color);
            },
            .hidden => {
                rl.drawRectangleLinesEx(.{ .x = x, .y = y + 1, .width = 20, .height = 5 }, 1.5, color);
                rl.drawRectangleLinesEx(.{ .x = x + 2, .y = y + 6, .width = 16, .height = 12 }, 1.5, color);
                rl.drawLineEx(.{ .x = x + 7, .y = y + 10 }, .{ .x = x + 13, .y = y + 10 }, 1.5, color);
            },
            .details => {
                rl.drawCircleLines(@intFromFloat(x + 10), @intFromFloat(y + 9), 10, color);
                rl.drawCircle(@intFromFloat(x + 10), @intFromFloat(y + 4), 1, color);
                rl.drawLineEx(.{ .x = x + 10, .y = y + 8 }, .{ .x = x + 10, .y = y + 14 }, 1.5, color);
            },
        }
        const size = s.text.lineSize(label, 10, r.width);
        s.text.drawLine(label, r.x + (r.width - size.x) / 2, r.y + 43, 10, r.width, color, theme.colors.rail);
        if (hot) rl.setMouseCursor(.pointing_hand);
        return hot and rl.isMouseButtonPressed(.left);
    }
    fn drawRail(s: *App, r: rl.Rectangle) void {
        rl.drawRectangleRec(r, theme.colors.rail);
        if (s.railItem(.{ .x = r.x, .y = r.y + 16, .width = r.width, .height = 62 }, "Messages", .messages, !s.show_hidden and !s.show_details)) {
            if (s.show_hidden) s.toggleHidden() catch s.info("Could not switch conversations.");
            if (s.show_details) s.toggleDetails();
            s.new_mode = false;
            s.focus = .composer;
        }
        if (s.railItem(.{ .x = r.x, .y = r.y + 86, .width = r.width, .height = 62 }, "Hidden", .hidden, s.show_hidden and !s.show_details)) {
            if (!s.show_hidden) s.toggleHidden() catch s.info("Could not switch conversations.");
            if (s.show_details) s.toggleDetails();
            s.new_mode = false;
            s.focus = .composer;
        }
        const footer = layout.footer(r);
        const details_size = s.text.lineSize("Details", 10, r.width);
        if (s.railItem(.{ .x = r.x, .y = footer.y + (footer.height - details_size.y) / 2 - 43, .width = r.width, .height = 62 }, "Details", .details, s.show_details)) s.toggleDetails();
    }
    const sidebar_row_height: f32 = 36;
    const sidebar_padding: f32 = 8;
    const sidebar_icon_inset: f32 = 8;
    const sidebar_icon_size: f32 = 22;
    const sidebar_text_inset: f32 = 38;
    const sidebar_search_height: f32 = 30;
    const sidebar_search_gap: f32 = sidebar_padding;
    const sidebar_header_height = sidebar_padding + sidebar_search_height + sidebar_search_gap;
    const sidebar_list_gap: f32 = 4;
    fn sidebarViewport(r: rl.Rectangle) rl.Rectangle {
        return .{ .x = r.x + sidebar_padding, .y = r.y + sidebar_header_height + sidebar_list_gap, .width = r.width - sidebar_padding - 4, .height = @max(0, r.height - sidebar_header_height - sidebar_list_gap - layout.list_bottom_padding) };
    }
    fn drawSidebar(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        rl.drawRectangleRec(r, theme.colors.sidebar);
        rl.drawLine(@intFromFloat(r.x + r.width - 1), @intFromFloat(r.y), @intFromFloat(r.x + r.width - 1), @intFromFloat(r.y + r.height), theme.colors.line);
        const viewport = sidebarViewport(r);
        var clip = viewport;
        clip.width -= Scrollbar.gutter;
        var count: usize = 0;
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (s.matchesSidebar(chat)) count += 1;
        };
        const content_height = @as(f32, @floatFromInt(count)) * sidebar_row_height;
        if (hover(viewport)) s.sidebar_scroll -= rl.getMouseWheelMove() * 34 * Scrollbar.wheel_scale;
        s.sidebar_scroll = std.math.clamp(s.sidebar_scroll, 0, @max(0, content_height - clip.height));
        if (s.sidebar_bar.update(viewport, content_height, s.sidebar_scroll, scrollbarInput())) |offset| s.sidebar_scroll = @floatCast(offset);
        beginClip(clip);
        var y = clip.y - s.sidebar_scroll;
        if (s.view) |v| {
            // The snapshot is ordered by latest message activity, newest first.
            // Preserve that order across group and direct conversations.
            for (v.snapshot.chats) |chat| {
                if (!s.matchesSidebar(chat)) continue;
                const row = rl.Rectangle{ .x = clip.x, .y = y, .width = clip.width, .height = sidebar_row_height - 2 };
                y += sidebar_row_height;
                if (row.y + row.height < clip.y or row.y > clip.y + clip.height) continue;
                const selected = u.eq(s.key, chat.value.id) and !s.new_mode and !s.show_details;
                const hot = hover(row) and hover(clip);
                const bg = if (selected) theme.colors.selected else if (hot) theme.colors.avatar else theme.colors.sidebar;
                if (selected or hot) rl.drawRectangleRounded(row, 0.2, 8, bg);
                const name = display.label(ar, chatName(chat.value));
                if (chat.value.participants.len > 1) {
                    s.text.drawLine("#", row.x + 11, row.y + 5, 20, 20, if (selected) theme.colors.ink else theme.colors.muted, bg);
                } else {
                    s.drawAvatar(.{ .x = row.x + sidebar_icon_inset, .y = row.y + 6, .width = sidebar_icon_size, .height = sidebar_icon_size }, name, theme.participant(chat.value.id, &.{}), 12);
                }
                s.text.drawLine(name, row.x + sidebar_text_inset, row.y + 8, 14, row.width - (if (chat.unread > 0) @as(f32, 76) else 46), if (selected or chat.unread > 0) theme.colors.ink else theme.colors.muted, bg);
                if (chat.unread > 0) {
                    const badge = rl.Rectangle{ .x = row.x + row.width - 30, .y = row.y + 8, .width = 24, .height = 19 };
                    rl.drawRectangleRounded(badge, 0.5, 8, theme.colors.ink);
                    const label = if (chat.unread > 99) "99+" else std.fmt.allocPrint(ar, "{d}", .{chat.unread}) catch "";
                    const size = s.text.lineSize(label, 10, 24);
                    s.text.drawLine(label, badge.x + (24 - size.x) / 2, badge.y + 2, 10, 24, theme.colors.sidebar, theme.colors.ink);
                }
                if (hot) rl.setMouseCursor(.pointing_hand);
                if (hot and rl.isMouseButtonPressed(.left)) s.select(chat.value.id) catch s.info("Could not open conversation.");
            }
            if (count == 0) s.text.draw(if (s.show_hidden) "No hidden conversations" else if (v.online or v.snapshot.chats.len > 0) "No matching conversations" else "Waiting for your Mac…", clip.x + 10, clip.y + 18, 14, clip.width - 20, theme.colors.muted, theme.colors.sidebar);
        }
        endClip();
        s.sidebar_bar.draw(viewport, content_height, s.sidebar_scroll);
        const search = rl.Rectangle{ .x = clip.x, .y = r.y + sidebar_padding, .width = clip.width, .height = sidebar_search_height };
        s.inputBox(&s.search, search, "Search conversations", .search, false);
        const divider_y = r.y + sidebar_header_height;
        rl.drawLine(@intFromFloat(search.x), @intFromFloat(divider_y), @intFromFloat(search.x + search.width), @intFromFloat(divider_y), theme.colors.line);
    }
    fn drawAvatar(s: *App, r: rl.Rectangle, name: []const u8, style: theme.Participant, size: i32) void {
        rl.drawRectangleRounded(r, 0.25, 8, style.bubble);
        var initial = [_]u8{if (name.len > 0 and std.ascii.isAlphabetic(name[0])) std.ascii.toUpper(name[0]) else '+'};
        const measured = s.text.lineSize(&initial, size, r.width);
        s.text.drawLine(&initial, r.x + (r.width - measured.x) / 2, r.y + (r.height - measured.y) / 2, size, r.width, style.label, style.bubble);
    }
    fn detailSection(s: *App, label: []const u8, r: rl.Rectangle, y: *f32) void {
        y.* += 18;
        s.text.draw(label, r.x, y.*, 17, r.width, theme.colors.ink, theme.colors.paper);
        y.* += 32;
    }
    fn detailRow(s: *App, label: []const u8, value: []const u8, r: rl.Rectangle, y: *f32) void {
        const label_width: f32 = 122;
        const value_width = @max(80, r.width - label_width - 12);
        const height = @max(20, s.text.height(value, 14, value_width));
        s.text.draw(label, r.x, y.* + 1, 12, label_width - 8, theme.colors.muted, theme.colors.paper);
        s.text.draw(value, r.x + label_width, y.*, 14, value_width, theme.colors.ink, theme.colors.paper);
        y.* += height + 10;
    }
    fn drawDetails(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        const back_size = s.buttonSize("Back");
        const reconnect_size = s.buttonSize("Reconnect");
        const back = rl.Rectangle{ .x = r.x + r.width - 24 - back_size.x, .y = r.y + 18, .width = back_size.x, .height = 30 };
        const reconnect = rl.Rectangle{ .x = back.x - 8 - reconnect_size.x, .y = back.y, .width = reconnect_size.x, .height = back.height };
        const title_width = @max(1, reconnect.x - r.x - 40);
        s.text.drawLine("Technical details", r.x + 24, r.y + 14, 21, title_width, theme.colors.ink, theme.colors.paper);
        s.text.drawLine("Connection, synchronization and this client", r.x + 24, r.y + 43, 13, title_width, theme.colors.muted, theme.colors.paper);
        if (s.button(reconnect, "Reconnect", false)) {
            s.worker.push(.{ .kind = .reconnect }) catch {};
            s.send_wait = false;
        }
        if (s.button(back, "Back", false)) s.toggleDetails();
        rl.drawLine(@intFromFloat(r.x), @intFromFloat(r.y + 76), @intFromFloat(r.x + r.width), @intFromFloat(r.y + 76), theme.colors.line);
        const viewport = rl.Rectangle{ .x = r.x + 24, .y = r.y + 78, .width = r.width - 32, .height = @max(0, r.height - 86) };
        var clip = viewport;
        clip.width -= Scrollbar.gutter;
        if (hover(viewport)) s.details_scroll -= rl.getMouseWheelMove() * 42 * Scrollbar.wheel_scale;
        s.details_scroll = std.math.clamp(s.details_scroll, 0, @max(0, s.details_height - clip.height));
        if (s.details_bar.update(viewport, s.details_height, s.details_scroll, scrollbarInput())) |offset| s.details_scroll = @floatCast(offset);
        beginClip(clip);
        var y = clip.y - s.details_scroll;
        s.detailSection("Connection", clip, &y);
        s.detailRow("Status", if (s.view) |v| v.status else "Opening cache…", clip, &y);
        s.detailRow("Endpoint", s.worker.config.relay_url, clip, &y);
        s.detailRow("Transport", "Direct HTTPS / SSE · TLS 1.3 · mutual certificates", clip, &y);
        if (s.view) |v| {
            const d = v.diagnostics;
            s.detailRow("Authentication", if (d.auth_blocked) "Action required — see failure details, then Reconnect" else if (d.last_status_ms > 0 and v.online) "mTLS authenticated" else "Client certificate; waiting for connection", clip, &y);
            s.detailRow("Client SHA-256", if (d.transport.fingerprint.len > 0) d.transport.fingerprint else "Not loaded", clip, &y);
            s.detailRow("Certificate expiry", if (d.transport.expiring) std.fmt.allocPrint(ar, "{s} · renew now, then Reconnect", .{d.transport.expires}) catch "" else d.transport.expires, clip, &y);
            s.detailRow("Failure", std.fmt.allocPrint(ar, "{s} · curl {d} · verification {d}\n{s}", .{ d.transport.failure, d.transport.curl_code, d.transport.verify_result, d.transport.detail }) catch "", clip, &y);
            s.detailRow("Last response", if (d.last_response_ms == 0) "None this session" else if (d.last_http_status == 0) "Transport interrupted / no HTTP response" else std.fmt.allocPrint(ar, "HTTP {d} · {s}", .{ d.last_http_status, elapsed(ar, d.last_response_ms) }) catch "", clip, &y);
            s.detailRow("Retry", if (d.auth_blocked) "Waiting for Reconnect" else if (!v.online and d.retry_at > u.now()) std.fmt.allocPrint(ar, "In {d}s", .{@divTrunc(d.retry_at - u.now() + 999, 1000)}) catch "" else if (v.online) "Not needed" else "Connecting", clip, &y);
            s.detailSection("Relay", clip, &y);
            s.detailRow("Last checked", elapsed(ar, d.last_status_ms), clip, &y);
            if (d.server) |server| {
                s.detailRow("API version", server.api_version, clip, &y);
                s.detailRow("Server epoch", server.server_epoch, clip, &y);
                s.detailRow("Messages adapter", if (server.adapter_ready) "Ready at last check" else "Unavailable at last check", clip, &y);
                const caps = server.capabilities;
                s.detailRow("Capabilities", std.fmt.allocPrint(ar, "History: {s} · Live messages: {s}\nDirect sends: {s} · Replies: {s}\nAttachments: {s} · Create groups: {s}", .{ yesNo(caps.read_history), yesNo(caps.live_messages), yesNo(caps.send_direct), yesNo(caps.reply_existing), yesNo(caps.attachments), yesNo(caps.group_creation) }) catch "", clip, &y);
                s.detailRow("Degraded reasons", if (server.degraded_reasons.len == 0) "None reported at last check" else std.mem.join(ar, "\n", server.degraded_reasons) catch "", clip, &y);
            } else s.detailRow("Server information", "Not yet available. Connect to the relay to load its status.", clip, &y);
            s.detailSection("Synchronization", clip, &y);
            s.detailRow("Current operation", d.job, clip, &y);
            s.detailRow("Initial download", if (d.bootstrapped) "Complete" else "Pending", clip, &y);
            s.detailRow("Event stream", if (v.online and d.stream_active) "Connected" else if (d.stream_active) "Opening" else "Disconnected", clip, &y);
            s.detailRow("Saved cursor", if (d.cursor.len > 0) d.cursor else "Not established", clip, &y);
            s.detailRow("Last event", elapsed(ar, d.last_event_ms), clip, &y);
            s.detailRow("Local cache", std.fmt.allocPrint(ar, "{d} conversations · {d} messages\n{d} drafts · {d} unresolved sends", .{ v.snapshot.chats.len, d.cached_messages, d.saved_drafts, d.pending_sends }) catch "", clip, &y);
            s.detailRow("Current history", std.fmt.allocPrint(ar, "{d} cached messages · {s}", .{ v.snapshot.messages.len, if (v.loading_history) "Loading" else if (v.snapshot.more) "Older history available" else "No older page" }) catch "", clip, &y);
        }
        s.detailSection("Client", clip, &y);
        s.detailRow("Version", client_options.version, clip, &y);
        s.detailRow("Platform", @tagName(@import("builtin").os.tag) ++ " / " ++ @tagName(@import("builtin").cpu.arch) ++ " · Wayland", clip, &y);
        s.detailRow("Rendering", "raylib / Clay · Pango / Cairo · RGB subpixel (grayscale fallback)", clip, &y);
        s.detailRow("Display", std.fmt.allocPrint(ar, "{d} × {d} logical · {d} × {d} pixels · {d:.0}% scale", .{ rl.getScreenWidth(), rl.getScreenHeight(), rl.getRenderWidth(), rl.getRenderHeight(), s.text.scale * 100 }) catch "", clip, &y);
        s.detailRow("Database", std.fmt.allocPrint(ar, "{s}/client.db", .{s.worker.config.data}) catch "", clip, &y);
        s.detailRow("CA file", s.worker.config.ca_file, clip, &y);
        s.detailRow("Client certificate", s.worker.config.client_cert_file, clip, &y);
        s.detailRow("Client key file", s.worker.config.client_key_file, clip, &y);
        s.detailRow("Send shortcut", if (s.enter_to_send) "Enter (Shift+Enter for a new line)" else "Ctrl+Enter", clip, &y);
        s.details_height = y - clip.y + s.details_scroll + 12;
        endClip();
        const clamped = std.math.clamp(s.details_scroll, 0, @max(0, s.details_height - clip.height));
        s.layout_pending = s.layout_pending or clamped != s.details_scroll;
        s.details_scroll = clamped;
        s.details_bar.draw(viewport, s.details_height, s.details_scroll);
    }
    fn drawHeader(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        var title: []const u8 = if (s.show_hidden) "Hidden conversations" else "Messages";
        var subtitle: []const u8 = if (s.show_hidden) "Hidden on this device" else "Choose a conversation to get started.";
        if (s.new_mode) {
            title = "New message";
            subtitle = "A new direct iMessage conversation";
        } else if (std.mem.startsWith(u8, s.key, "new:")) {
            title = s.key[4..];
            subtitle = "New iMessage conversation";
        } else if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (u.eq(chat.value.id, s.key)) {
                title = chatName(chat.value);
                subtitle = if (chat.value.participants.len > 1) std.fmt.allocPrint(ar, "{d} participants  ·  {s}", .{ chat.value.participants.len, if (chat.value.sendable) "iMessage" else "Read only" }) catch "Group conversation" else if (chat.value.sendable) "iMessage" else "Read only · unsupported service";
                break;
            }
        };
        const hidden = if (s.new_mode) null else s.selectedHidden();
        const text_width = r.width - (if (hidden != null) @as(f32, 140) else 48);
        beginClip(.{ .x = r.x + 24, .y = r.y + 8, .width = text_width, .height = 48 });
        s.text.draw(display.label(ar, title), r.x + 24, r.y + 9, 20, text_width, theme.colors.ink, theme.colors.paper);
        s.text.draw(subtitle, r.x + 24, r.y + 36, 12, text_width, theme.colors.muted, theme.colors.paper);
        endClip();
        if (hidden) |is_hidden| {
            const label = if (is_hidden) "Unhide" else "Hide";
            const size = s.buttonSize(label);
            if (s.button(.{ .x = r.x + r.width - layout.action_right_padding - size.x, .y = r.y + 16, .width = size.x, .height = 30 }, label, false)) s.setSelectedHidden(!is_hidden) catch s.info("Could not save conversation visibility. Try again.");
        }
        rl.drawLine(@intFromFloat(r.x), @intFromFloat(r.y + r.height), @intFromFloat(r.x + r.width), @intFromFloat(r.y + r.height), theme.colors.line);
    }
    const HistoryRow = struct {
        id: []const u8,
        text: []const u8,
        key: u64,
        measured: ?f32,
        padding: f32,
        pending: bool = false,
        source_index: usize = 0,
        top: f64 = 0,

        fn height(row: HistoryRow) f32 {
            return (row.measured orelse 24) + row.padding;
        }

        fn before(snapshot: @import("client/Store.zig").Snapshot, left: HistoryRow, right: HistoryRow) bool {
            const left_time = if (left.pending) snapshot.pending[left.source_index].sent_at else snapshot.messages[left.source_index].timestamp;
            const right_time = if (right.pending) snapshot.pending[right.source_index].sent_at else snapshot.messages[right.source_index].timestamp;
            const order = std.mem.order(u8, left_time, right_time);
            if (order != .eq) return order == .lt;
            if (left.pending != right.pending) return !left.pending;
            return left.source_index < right.source_index;
        }
    };
    fn prepareHistory(s: *App, inner: f32) ![]HistoryRow {
        const snapshot = s.view.?.snapshot;
        var hash = std.hash.Wyhash.init(0);
        hash.update(snapshot.selected);
        hash.update(std.mem.asBytes(&inner));
        hash.update(std.mem.asBytes(&s.text.scale));
        const context = hash.final();
        if (context != s.height_context) {
            // Retain every height in the active conversation. Clearing a full
            // cache mid-layout makes histories larger than the cap start over.
            s.heights.clearRetainingCapacity();
            s.height_context = context;
            s.height_cursor = 0;
            s.history_generation = null;
        }
        const generation = s.view.?.content_generation orelse s.view.?.generation;
        if (s.history_generation == generation and s.history_rows.len == snapshot.messages.len + snapshot.pending.len) return s.history_rows;
        _ = s.history_arena.reset(.retain_capacity);
        const ar = s.history_arena.allocator();
        const rows = try ar.alloc(HistoryRow, snapshot.messages.len + snapshot.pending.len);
        for (snapshot.messages, rows[0..snapshot.messages.len], 0..) |m, *row, i| {
            const prepared = if (s.view.?.shared) |shared| shared.history.presentations[i] else blk: {
                const text = messageText(ar, m);
                break :blk @import("client/MessageHistory.zig").Presentation{ .text = text, .key = std.hash.Wyhash.hash(0, text) };
            };
            const text = prepared.text;
            const key = prepared.key;
            row.* = .{ .id = m.id, .text = text, .key = key, .measured = s.heights.get(key), .padding = 38, .source_index = i };
        }
        for (snapshot.pending, rows[snapshot.messages.len..], 0..) |p, *row, i| {
            const text = display.message(ar, p.input.text);
            const key = std.hash.Wyhash.hash(0, text);
            row.* = .{ .id = p.input.request_id, .text = text, .key = key, .measured = s.heights.get(key), .padding = 74, .pending = true, .source_index = i };
        }
        if (snapshot.pending.len > 0) std.mem.sort(HistoryRow, rows, snapshot, HistoryRow.before);
        s.history_rows = rows;
        s.history_generation = generation;
        if (s.message_selection.id.len > 0) {
            var valid = false;
            for (rows) |row| {
                if (!s.message_selection.matches(row.id, row.pending, row.text)) continue;
                const full = if (row.pending) snapshot.pending[row.source_index].input.text else snapshot.messages[row.source_index].text orelse row.text;
                valid = u.eq(full, s.message_selection.full);
                break;
            }
            if (!valid) s.message_selection.clear();
        }
        return rows;
    }
    fn historyLimit(s: *App, viewport: f32) f64 {
        // Keep short histories at the bottom too, so expanding older rows
        // cannot move the latest message from the top to the bottom later.
        return s.content_height - viewport + 16;
    }
    fn clampHistoryScroll(s: *App, value: f64, viewport: f32) f64 {
        const bottom = s.historyLimit(viewport);
        return std.math.clamp(value, @min(0, bottom), bottom);
    }
    fn scrollHistory(s: *App, wheel: f32, viewport: f32) void {
        s.scroll = s.clampHistoryScroll(s.scroll - wheel * 46 * Scrollbar.wheel_scale, viewport);
        // Any upward movement leaves follow mode immediately. Do not snap a
        // small trackpad scroll back to the bottom on the next frame.
        s.following = wheel < 0 and s.scroll >= s.historyLimit(viewport) - 1;
    }
    fn positionHistory(s: *App, rows: []HistoryRow, viewport: f32) void {
        var total: f64 = 54;
        for (rows) |*row| {
            row.top = total;
            if (!s.following and row.pending == s.anchor_pending and u.eq(row.id, s.history_anchor)) s.scroll = total - s.anchor_offset;
            total += row.height();
        }
        s.content_height = total;
        s.scroll = if (s.following) s.historyLimit(viewport) else s.clampHistoryScroll(s.scroll, viewport);
    }
    const max_height_work = 256;
    fn hasHeightBudget(s: *App) bool {
        // Guarantee progress even when preparing a large snapshot took time.
        return s.height_budget > 0 and (s.height_budget == max_height_work or u.c.zr_monotonic_ms() < s.height_deadline);
    }
    fn measureRow(s: *App, row: *HistoryRow, width: f32, visible: bool) f32 {
        if (row.measured != null) return 0;
        const old = row.height();
        if (s.heights.get(row.key)) |height| {
            row.measured = height;
            return row.height() - old;
        }
        if (!s.hasHeightBudget()) return 0;
        s.height_budget -= 1;
        row.measured = if (visible) s.text.height(row.text, 16, width) else s.text.measure(row.text, 16, width);
        s.heights.put(a, row.key, row.measured.?) catch {};
        return row.height() - old;
    }
    fn measureHistory(s: *App, rows: []HistoryRow, inner: f32, viewport: f32) void {
        s.height_budget = max_height_work;
        s.height_deadline = u.c.zr_monotonic_ms() + 8;
        var anchor: usize = 0;
        var top: f64 = 54;
        while (anchor < rows.len and top + rows[anchor].height() <= s.scroll) : (anchor += 1) top += rows[anchor].height();

        // Resolve what the user can see before spending time on offscreen rows.
        if (s.following) {
            var i = rows.len;
            var covered: f32 = 16;
            while (i > 0 and covered < viewport) {
                i -= 1;
                _ = s.measureRow(&rows[i], inner, true);
                covered += rows[i].height();
            }
        } else {
            var i = anchor;
            var y = top;
            while (i < rows.len and y < s.scroll + viewport) : (i += 1) {
                _ = s.measureRow(&rows[i], inner, true);
                y += rows[i].height();
            }
        }
        // Continue from newest to oldest, resuming instead of repeatedly
        // walking already-measured rows until the frame deadline expires.
        for (0..rows.len) |_| {
            if (!s.hasHeightBudget()) break;
            if (s.height_cursor >= rows.len) s.height_cursor = 0;
            const i = rows.len - 1 - s.height_cursor;
            const delta = s.measureRow(&rows[i], inner, false);
            if (!s.following and i < anchor) s.scroll += delta;
            s.height_cursor += 1;
        }
        s.content_height = 54;
        s.layout_pending = false;
        for (rows) |*row| {
            row.top = s.content_height;
            s.content_height += row.height();
            s.layout_pending = s.layout_pending or row.measured == null;
        }
        s.scroll = if (s.following) s.historyLimit(viewport) else s.clampHistoryScroll(s.scroll, viewport);
    }
    fn rememberHistoryAnchor(s: *App, rows: []const HistoryRow) void {
        var top: f64 = 54;
        for (rows) |row| {
            if (top + row.height() > s.scroll) {
                if (row.pending != s.anchor_pending or !u.eq(row.id, s.history_anchor)) {
                    const id = a.dupe(u8, row.id) catch return;
                    a.free(s.history_anchor);
                    s.history_anchor = id;
                    s.anchor_pending = row.pending;
                }
                s.anchor_offset = top - s.scroll;
                return;
            }
            top += row.height();
        }
    }
    const HistoryRange = struct { start: usize, end: usize, loading: bool = false };
    fn visibleHistory(s: *App, rows: []const HistoryRow, viewport: f32) HistoryRange {
        var low: usize = 0;
        var high = rows.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (rows[middle].top + rows[middle].height() <= s.scroll) low = middle + 1 else high = middle;
        }
        const start = low;
        high = rows.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (rows[middle].top < s.scroll + viewport) low = middle + 1 else high = middle;
        }
        var range = HistoryRange{ .start = start, .end = low };
        // Reveal only final geometry outward from the reading anchor. An
        // estimated-height bubble must never push already-visible text around.
        if (s.following) {
            var i = range.end;
            while (i > range.start) {
                i -= 1;
                if (rows[i].measured == null) {
                    range.start = i + 1;
                    range.loading = true;
                    break;
                }
            }
        } else {
            for (rows[range.start..range.end], range.start..) |row, i| if (row.measured == null) {
                range.end = i;
                range.loading = true;
                break;
            };
        }
        return range;
    }
    fn drawHistory(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        const v = s.view orelse return;
        if (!u.eq(s.key, v.snapshot.selected)) return;
        const inner = historyTextWidth(r);
        const rows = s.prepareHistory(inner) catch return;
        s.positionHistory(rows, r.height);
        var scrolled = false;
        if (hover(r)) {
            const wheel = rl.getMouseWheelMove();
            if (wheel != 0) {
                s.scrollHistory(wheel, r.height);
                scrolled = true;
            }
        }
        if (s.history_bar.update(r, s.content_height + 16, s.scroll, scrollbarInput())) |offset| {
            s.scroll = offset;
            s.following = s.scroll >= s.historyLimit(r.height) - 1;
            scrolled = true;
        }
        s.measureHistory(rows, inner, r.height);
        // Deferred measurements may change the range during a drag. Keep the
        // thumb under the pointer, then save this position as the reading anchor.
        if (s.history_bar.dragging) {
            var held = scrollbarInput();
            held.pressed = false;
            if (s.history_bar.update(r, s.content_height + 16, s.scroll, held)) |offset| {
                s.scroll = offset;
                s.following = s.scroll >= s.historyLimit(r.height) - 1;
            }
        }
        if (scrolled) s.worker.push(.{ .kind = .viewed, .text = if (s.following and rl.isWindowFocused()) "yes" else "no" }) catch {};
        s.rememberHistoryAnchor(rows);
        var clip = r;
        clip.width -= Scrollbar.gutter;
        if (hover(clip) and rl.isMouseButtonPressed(.left)) s.message_selection.clear();
        beginClip(clip);
        var participants: []const []const u8 = &.{};
        for (v.snapshot.chats) |chat| if (u.eq(chat.value.id, s.key)) {
            participants = chat.value.participants;
            break;
        };
        if (s.scroll < 54 and v.snapshot.more and !std.mem.startsWith(u8, s.key, "new:")) {
            const y = r.y + 16 - @as(f32, @floatCast(s.scroll));
            if (s.button(.{ .x = r.x + r.width / 2 - 86, .y = y, .width = 172, .height = 30 }, "Load older messages", false)) {
                s.worker.push(.{ .kind = .older }) catch {};
                s.following = false;
            }
        }
        if (v.snapshot.messages.len == 0 and v.snapshot.pending.len == 0) s.text.draw(if (v.loading_history) "Loading history…" else if (v.online) "The start of something good.\nWrite your first message below." else "No cached messages in this conversation.", r.x + 40, r.y + 90, 17, r.width - 80, theme.colors.muted, theme.colors.paper);
        const visible = s.visibleHistory(rows, r.height);
        for (rows[visible.start..visible.end]) |row| {
            if (row.pending) continue;
            const m = v.snapshot.messages[row.source_index];
            const text = row.text;
            const h = row.measured.?;
            // Subtract in double precision before drawing. Accumulating tens
            // of thousands of f32 heights caused visible fractional-DPI drift.
            const y = r.y + @as(f32, @floatCast(row.top - s.scroll));
            const outgoing = m.direction == .outgoing;
            const style = if (outgoing) theme.Participant{ .bubble = theme.colors.selected, .label = theme.colors.focus } else theme.participant(m.sender, participants);
            if (y + row.height() >= r.y and y < r.y + r.height) {
                const hover_padding = (row.padding - 22) / 2;
                const bounds = rl.Rectangle{ .x = r.x, .y = y - hover_padding, .width = clip.width, .height = row.height() };
                const bg = if (hover(bounds)) theme.colors.surface else theme.colors.paper;
                if (hover(bounds)) rl.drawRectangleRec(bounds, bg);
                s.drawAvatar(.{ .x = r.x + 20, .y = y, .width = 34, .height = 34 }, if (outgoing) "You" else m.sender, style, 17);
                const x = r.x + 66;
                const name = display.label(ar, if (outgoing) "You" else if (m.sender.len > 0) m.sender else "Unknown sender");
                const name_width = @min(inner * 0.55, s.text.lineSize(name, 14, inner * 0.55).x);
                s.text.drawLine(name, x, y, 14, name_width, if (outgoing) theme.colors.ink else style.label, bg);
                const status: MessageStatus = if (!outgoing) .none else switch (m.observed_status) {
                    .sent => .{ .checks = false },
                    .delivered => .{ .checks = true },
                    else => .{ .label = @tagName(m.observed_status) },
                };
                const stamp_x = x + name_width + 10;
                s.drawMessageMeta(localTime(ar, m.timestamp, false), status, .{ .x = stamp_x, .y = y + 2, .width = @max(1, inner - name_width - 10), .height = 18 }, bg);
                s.drawMessageText(row, m.text orelse text, .{ .x = x, .y = y + 22, .width = inner, .height = h }, theme.colors.ink, bg);
            }
        }
        for (rows[visible.start..visible.end]) |row| {
            if (!row.pending) continue;
            const p = v.snapshot.pending[row.source_index];
            const h = row.measured.?;
            const y = r.y + @as(f32, @floatCast(row.top - s.scroll));
            const x = r.x + 66;
            if (y + row.height() >= r.y and y < r.y + r.height) {
                s.drawAvatar(.{ .x = r.x + 20, .y = y, .width = 34, .height = 34 }, "You", .{ .bubble = theme.colors.incoming, .label = theme.colors.muted }, 17);
                const name_width = s.text.lineSize("You", 14, inner).x;
                s.text.drawLine("You", x, y, 14, name_width, theme.colors.muted, theme.colors.paper);
                const label = if (u.eq(p.state, "unknown") or u.eq(p.state, "unconfirmed")) "Uncertain · not automatically resent" else if (u.eq(p.state, "failed")) "Failed" else if (u.eq(p.state, "sending")) "Saving / submitting…" else p.state;
                const status = if (p.detail.len > 0) std.fmt.allocPrint(ar, "{s} · {s}", .{ label, display.label(ar, p.detail) }) catch label else label;
                s.drawMessageMeta(localTime(ar, p.sent_at, false), .{ .label = status }, .{ .x = x + name_width + 10, .y = y + 2, .width = @max(1, inner - name_width - 10), .height = 18 }, theme.colors.paper);
                s.drawMessageText(row, p.input.text, .{ .x = x, .y = y + 22, .width = inner, .height = h }, theme.colors.muted, theme.colors.paper);
                if (s.button(.{ .x = x + inner - 118, .y = y + h + 24, .width = 118, .height = 27 }, "Copy to draft", false)) {
                    if (s.readOnlyChat()) s.info("This conversation is read-only.") else if (s.composer.text.items.len > 0) s.info("Your composer has a draft. Save or clear it before copying another message.") else {
                        s.composer.set(p.input.text) catch {};
                        s.draft_dirty = true;
                        s.draft_at = 0;
                        s.focus = .composer;
                        s.duplicate_risk = u.eq(p.state, "unknown") or u.eq(p.state, "unconfirmed");
                    }
                }
            }
        }
        if (visible.loading) s.text.draw("Loading messages…", r.x + 24, if (s.following) r.y + 12 else r.y + r.height - 28, 13, r.width - 48, theme.colors.muted, null);
        endClip();
        s.history_bar.draw(r, s.content_height + 16, s.scroll);
        if (!s.following and s.new_messages) if (s.button(.{ .x = r.x + r.width / 2 - 74, .y = r.y + r.height - 42, .width = 148, .height = 32 }, "New messages ↓", true)) {
            s.following = true;
            s.new_messages = false;
            s.worker.push(.{ .kind = .viewed, .text = "yes" }) catch {};
        };
    }
    const MessageStatus = union(enum) { none, label: []const u8, checks: bool };
    fn drawMessageMeta(s: *App, stamp: []const u8, status: MessageStatus, r: rl.Rectangle, background: rl.Color) void {
        const reserved: f32 = switch (status) {
            .none => 0,
            .checks => 28,
            .label => |label| @min(r.width / 2, s.text.lineSize(label, 11, r.width).x + 8),
        };
        const stamp_width = @max(1, r.width - reserved);
        const size = s.text.lineSize(stamp, 11, stamp_width);
        s.text.drawLine(stamp, r.x, r.y, 11, stamp_width, theme.colors.muted, background);
        // Every send state occupies the same slot immediately after the timestamp.
        const status_x = r.x + size.x + 8;
        switch (status) {
            .none => {},
            .checks => |delivered| drawDeliveryChecks(status_x, r.y + (size.y - 12) / 2, delivered),
            .label => |label| s.text.drawLine(label, status_x, r.y, 11, @max(1, r.x + r.width - status_x), theme.colors.muted, background),
        }
    }
    fn drawDeliveryChecks(x: f32, y: f32, delivered: bool) void {
        // Neutral checks indicate transport status; the relay has no read receipts.
        const color = theme.colors.muted;
        rl.drawLineEx(.{ .x = x + 1, .y = y + 6 }, .{ .x = x + 5, .y = y + 10 }, 1.5, color);
        rl.drawLineEx(.{ .x = x + 5, .y = y + 10 }, .{ .x = x + 13, .y = y + 2 }, 1.5, color);
        if (delivered) {
            rl.drawLineEx(.{ .x = x + 9, .y = y + 8 }, .{ .x = x + 11, .y = y + 10 }, 1.5, color);
            rl.drawLineEx(.{ .x = x + 11, .y = y + 10 }, .{ .x = x + 19, .y = y + 2 }, 1.5, color);
        }
    }
    fn historyTextWidth(r: rl.Rectangle) f32 {
        return @max(80, r.width - 90);
    }
    fn drawMessageText(s: *App, row: HistoryRow, full: []const u8, bounds: rl.Rectangle, color: rl.Color, background: rl.Color) void {
        const x = bounds.x;
        const y = bounds.y;
        const width = bounds.width;
        const hot = hover(bounds);
        const selection = &s.message_selection;
        if (hot) rl.setMouseCursor(.ibeam);
        if (hot and rl.isMouseButtonPressed(.left)) {
            const at = s.text.hit(row.text, width, rl.getMousePosition().x - x, rl.getMousePosition().y - y);
            selection.begin(row.id, row.pending, row.text, full, at) catch {
                s.info("Could not select message text.");
                return;
            };
            s.focus = .none;
            s.dragging = false;
            s.info("Drag to select text · Ctrl+C to copy · Ctrl+A for the whole message");
        }
        const active = s.focus == .none and selection.matches(row.id, row.pending, row.text);
        if (active and selection.dragging and (rl.isMouseButtonDown(.left) or rl.isMouseButtonReleased(.left))) {
            selection.caret = s.text.hit(row.text, width, rl.getMousePosition().x - x, rl.getMousePosition().y - y);
            selection.whole = false;
        }
        s.text.drawSelection(row.text, x, y, 16, width, color, if (active) @min(selection.anchor, selection.caret) else 0, if (active) @max(selection.anchor, selection.caret) else 0, background);
    }
    fn composerHeight(s: *App) f32 {
        // Measure one line at the current display scale, then add the editor
        // padding and the shared sidebar footer height.
        // Round up so fractional layout arithmetic cannot create a scrollbar
        // for a draft that fits exactly into the single-line viewport.
        return @ceil(s.text.height("Ag", 16, 400)) + 22 + layout.composer_top_padding + layout.footer_height;
    }
    fn composerBox(r: rl.Rectangle) rl.Rectangle {
        return .{ .x = r.x + 20, .y = r.y + layout.composer_top_padding, .width = r.width - 40, .height = r.height - layout.composer_top_padding - layout.footer_height };
    }
    fn composerEditor(box: rl.Rectangle) rl.Rectangle {
        // Keep the text clear of the Send button.
        return .{ .x = box.x + 1, .y = box.y + 1, .width = box.width - 100, .height = box.height - 2 };
    }
    fn composerFooter(r: rl.Rectangle) rl.Rectangle {
        var footer = layout.footer(r);
        footer.x += 24;
        footer.width -= 48 + (if (client_options.fps_counter) @as(f32, 72) else 0);
        return footer;
    }
    fn drawFooterLabel(s: *App, label: []const u8, r: rl.Rectangle, color: rl.Color) void {
        // Keep all footer hints, notices, and warnings aligned to the left edge.
        const size = s.text.lineSize(label, 11, r.width);
        s.text.drawLine(label, r.x, r.y + (r.height - size.y) / 2, 11, r.width, color, theme.colors.paper);
    }
    fn drawComposer(s: *App, r: rl.Rectangle) void {
        rl.drawRectangleRec(r, theme.colors.paper);
        if (s.key.len == 0 or s.new_mode) return;
        const box = composerBox(r);
        const read_only = s.readOnlyChat();
        const background = if (read_only) theme.colors.incoming else theme.colors.surface;
        rl.drawRectangleRounded(box, 0.12, 8, background);
        const editor = composerEditor(box);
        if (read_only) {
            s.text.drawLine(if (s.composer.text.items.len > 0) s.composer.text.items else "This conversation is read-only", box.x + 12, box.y + 11, 16, box.width - 24, theme.colors.disabled, background);
        } else {
            s.inputBox(&s.composer, editor, if (s.view != null and s.view.?.online) "Message this conversation…" else "Write a draft while offline…", .composer, true);
        }
        rl.drawRectangleRoundedLinesEx(box, 0.12, 8, 1, if (!read_only and s.focus == .composer) theme.colors.focus else theme.colors.line);
        if (read_only) return;
        const send_button = rl.Rectangle{ .x = r.x + r.width - layout.action_right_padding - 76, .y = box.y + (box.height - 28) / 2, .width = 76, .height = 28 };
        const enabled = s.canSend();
        const hot = hover(send_button);
        const bg = if (enabled) theme.colors.success else theme.colors.incoming;
        rl.drawRectangleRounded(send_button, 0.25, 8, bg);
        const label = if (s.send_wait) "Saving…" else "Send ↑";
        const size = s.text.lineSize(label, 13, send_button.width);
        s.text.drawLine(label, send_button.x + (send_button.width - size.x) / 2, send_button.y + (send_button.height - size.y) / 2, 13, send_button.width, if (enabled) theme.colors.paper else theme.colors.muted, bg);
        if (hot and enabled) {
            rl.setMouseCursor(.pointing_hand);
            if (rl.isMouseButtonPressed(.left)) s.send() catch s.info("Could not queue message. Your draft is retained.");
        }
        var footer = composerFooter(r);
        if (s.duplicate_risk and u.now() < s.notice_until) {
            footer.height /= 2;
            footer.y += footer.height;
        }
        if (s.duplicate_risk) {
            s.drawFooterLabel("Earlier send may have succeeded. Sending again may duplicate it.", footer, theme.colors.danger);
        } else {
            const hint = if (s.enter_to_send) "Enter to send · Shift+Enter for a new line" else "Ctrl+Enter to send · Enter for a new line";
            s.drawFooterLabel(hint, footer, theme.colors.muted);
        }
    }
    fn inputBox(s: *App, e: *Editor, r: rl.Rectangle, placeholder: []const u8, focus: @FieldType(App, "focus"), multiline: bool) void {
        const background = if (multiline) theme.colors.surface else if (focus == .search) theme.colors.sidebar else theme.colors.paper;
        if (!multiline) {
            rl.drawRectangleRounded(r, 0.2, 8, background);
            rl.drawRectangleRoundedLinesEx(r, 0.2, 8, 1, if (s.focus == focus) theme.colors.focus else theme.colors.line);
        }
        var viewport = rl.Rectangle{ .x = r.x + 11, .y = r.y + (if (multiline) @as(f32, 10) else 6), .width = r.width - 22, .height = r.height - (if (multiline) @as(f32, 20) else 10) };
        if (focus == .search) {
            const label = if (e.text.items.len == 0) placeholder else e.text.items;
            const size = s.text.lineSize(label, 16, viewport.width);
            viewport.height = @min(size.y, r.height - 2);
            viewport.y = r.y + r.height / 2 - s.text.lineInkCenterY(label, 16, viewport.width);
        }
        var inner = viewport;
        if (multiline) inner.width -= Scrollbar.gutter;
        const width = inner.width;
        var caret = s.text.caret(e.text.items, width, e.caret);
        const content_height = if (multiline) @max(s.text.height(e.text.items, 16, width), caret.y + caret.height) else 0;
        if (multiline) {
            // Only typing, cursor movement, or a new layout should reveal the
            // caret. Manual scrolling must not snap back to it each frame.
            if (s.composer_revision != e.revision or s.composer_caret != e.caret or s.composer_width != width) s.revealComposerCaret(caret, inner.height);
            if (hover(r)) s.composer_scroll -= rl.getMouseWheelMove() * 46 * Scrollbar.wheel_scale;
            s.composer_scroll = std.math.clamp(s.composer_scroll, 0, @max(0, content_height - inner.height));
            if (s.composer_bar.update(viewport, content_height, s.composer_scroll, scrollbarInput())) |offset| {
                s.composer_scroll = @floatCast(offset);
                s.dragging = false;
            }
        }
        var offset = if (multiline) s.composer_scroll else 0;
        const previous_caret = e.caret;
        if (hover(if (multiline) inner else r) and rl.isMouseButtonPressed(.left)) {
            s.message_selection.clear();
            s.focus = focus;
            const at = s.text.hit(e.text.items, width, @as(f32, @floatFromInt(rl.getMouseX())) - inner.x, @as(f32, @floatFromInt(rl.getMouseY())) - inner.y + offset);
            e.caret = at;
            if (!rl.isKeyDown(.left_shift)) e.anchor = at;
            s.dragging = true;
        }
        if (s.dragging and s.focus == focus and rl.isMouseButtonDown(.left)) e.caret = s.text.hit(e.text.items, width, @as(f32, @floatFromInt(rl.getMouseX())) - inner.x, @as(f32, @floatFromInt(rl.getMouseY())) - inner.y + offset);
        if (rl.isMouseButtonReleased(.left)) s.dragging = false;
        if (s.focus == focus and (pressed(.up) or pressed(.down))) {
            const at = s.text.hit(e.text.items, width, caret.x, caret.y + (if (pressed(.up)) -1 else caret.height + 1));
            e.caret = at;
            if (!rl.isKeyDown(.left_shift)) e.anchor = at;
        }
        if (e.caret != previous_caret) {
            caret = s.text.caret(e.text.items, width, e.caret);
            if (multiline) {
                s.revealComposerCaret(caret, inner.height);
                offset = s.composer_scroll;
            }
        }
        if (multiline) {
            s.composer_revision = e.revision;
            s.composer_caret = e.caret;
            s.composer_width = width;
        }
        beginClip(inner);
        if (e.text.items.len == 0) s.text.draw(placeholder, inner.x, inner.y, 16, width, theme.colors.muted, background) else s.text.drawSelection(e.text.items, inner.x, inner.y - offset, 16, width, theme.colors.ink, @min(e.caret, e.anchor), @max(e.caret, e.anchor), background);
        if (s.focus == focus and @mod(u.now(), 1000) < 600) rl.drawRectangleRec(.{ .x = inner.x + caret.x, .y = inner.y + caret.y - offset, .width = 1.5, .height = caret.height }, theme.colors.accent);
        endClip();
        if (multiline) s.composer_bar.draw(viewport, content_height, s.composer_scroll);
    }
    fn revealComposerCaret(s: *App, caret: rl.Rectangle, viewport: f32) void {
        if (caret.y < s.composer_scroll) s.composer_scroll = caret.y;
        if (caret.y + caret.height > s.composer_scroll + viewport) s.composer_scroll = caret.y + caret.height - viewport;
    }
    const button_padding = rl.Vector2{ .x = 12, .y = 4 };
    const button_font_size = 13;
    const button_label_width = 512;
    fn buttonSize(s: *App, label: []const u8) rl.Vector2 {
        const text_size = s.text.lineSize(label, button_font_size, button_label_width);
        return .{ .x = text_size.x + 2 * button_padding.x, .y = text_size.y + 2 * button_padding.y };
    }
    fn button(s: *App, bounds: rl.Rectangle, label: []const u8, primary: bool) bool {
        const size = s.buttonSize(label);
        const r = rl.Rectangle{ .x = bounds.x + (bounds.width - size.x) / 2, .y = bounds.y + (bounds.height - size.y) / 2, .width = size.x, .height = size.y };
        const hot = hover(r);
        if (hot) rl.setMouseCursor(.pointing_hand);
        const background = if (primary) (if (hot) theme.colors.accent_hover else theme.colors.accent) else if (hot) theme.colors.line else theme.colors.incoming;
        rl.drawRectangleRounded(r, 0.22, 8, background);
        s.text.drawLine(label, r.x + button_padding.x, r.y + button_padding.y, button_font_size, button_label_width, if (primary) theme.colors.on_accent else theme.colors.muted, background);
        return hot and rl.isMouseButtonPressed(.left);
    }
};
fn scrollbarInput() Scrollbar.Input {
    return .{ .mouse = rl.getMousePosition(), .pressed = rl.isMouseButtonPressed(.left), .down = rl.isMouseButtonDown(.left) };
}
fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}
fn elapsed(ar: u.Allocator, when: i64) []const u8 {
    if (when == 0) return "Not observed";
    const seconds = @max(0, @divTrunc(u.now() - when, 1000));
    if (seconds < 60) return std.fmt.allocPrint(ar, "{d}s ago", .{seconds}) catch "";
    if (seconds < 3600) return std.fmt.allocPrint(ar, "{d}m ago", .{@divTrunc(seconds, 60)}) catch "";
    return std.fmt.allocPrint(ar, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "";
}
fn pressed(key: rl.KeyboardKey) bool {
    return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
}
fn hover(r: rl.Rectangle) bool {
    const point = rl.getMousePosition();
    return rl.checkCollisionPointRec(point, r) and (clip_depth == 0 or rl.checkCollisionPointRec(point, clip_stack[clip_depth - 1]));
}
var clip_stack: [16]rl.Rectangle = undefined;
var clip_depth: usize = 0;
fn beginClip(requested: rl.Rectangle) void {
    std.debug.assert(clip_depth < clip_stack.len);
    var r = requested;
    if (clip_depth > 0) {
        const parent = clip_stack[clip_depth - 1];
        const right = @min(r.x + r.width, parent.x + parent.width);
        const bottom = @min(r.y + r.height, parent.y + parent.height);
        r.x = @max(r.x, parent.x);
        r.y = @max(r.y, parent.y);
        r.width = @max(0, right - r.x);
        r.height = @max(0, bottom - r.y);
    }
    clip_stack[clip_depth] = r;
    clip_depth += 1;
    applyClip(r);
}
fn applyClip(r: rl.Rectangle) void {
    rl.beginScissorMode(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(@max(0, r.width)), @intFromFloat(@max(0, r.height)));
}
fn endClip() void {
    std.debug.assert(clip_depth > 0);
    clip_depth -= 1;
    if (clip_depth == 0) rl.endScissorMode() else applyClip(clip_stack[clip_depth - 1]);
}
fn chatName(v: t.Conversation) []const u8 {
    if (v.title.len > 0) return v.title;
    if (v.participants.len > 0) return v.participants[0];
    return "Conversation";
}
fn localTime(ar: u.Allocator, value: []const u8, compact: bool) []const u8 {
    const stamp = ar.dupeZ(u8, value) catch return value;
    const buffer = ar.alloc(u8, 64) catch return value;
    const n = bridge.zc_local_time(stamp, buffer.ptr, buffer.len, @intFromBool(compact));
    return if (n > 0) buffer[0..@intCast(n)] else value;
}
fn messageText(ar: u.Allocator, m: t.Message) []const u8 {
    return display.record(ar, m);
}
fn lineStart(text: []const u8, at: usize) usize {
    var p = at;
    while (p > 0 and text[p - 1] != '\n') p -= 1;
    return p;
}
fn lineEnd(text: []const u8, at: usize) usize {
    var p = at;
    while (p < text.len and text[p] != '\n') p += 1;
    return p;
}

test "hidden conversations stay out of search and selection until restored" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var chats = [_]@import("client/Store.zig").Chat{
        .{ .value = .{ .id = "spam", .title = "Spam", .service = "imessage" }, .preview = "", .unread = 1, .hidden = true },
        .{ .value = .{ .id = "friend", .title = "Friend", .service = "imessage" }, .preview = "", .unread = 0 },
    };
    const view = try a.create(Worker.View);
    view.* = .{ .arena = std.heap.ArenaAllocator.init(a), .snapshot = .{ .chats = &chats, .messages = &.{}, .pending = &.{}, .selected = "spam", .draft = "", .epoch = "", .more = false }, .status = "Offline", .online = false, .send_direct = false, .reply_existing = false, .generation = 1, .ack = 0 };
    var app = App{ .worker = &worker, .view = view, .key = try a.dupe(u8, "spam") };
    defer app.deinit();
    // Restarting with a hidden chat selected must choose a visible chat.
    try app.reconcileSelection();
    try std.testing.expectEqualStrings("friend", app.key);
    try app.search.set("spam");
    try std.testing.expect(!app.matchesSidebar(chats[0]));
    try std.testing.expectEqualStrings("", app.firstSidebarKey());
    try app.search.set("");
    try app.composer.set("Keep my draft");
    app.draft_dirty = true;
    const commands = worker.commands.items.len;
    try app.setSelectedHidden(true);
    try std.testing.expect(worker.commands.items[commands].kind == .draft);
    try std.testing.expectEqualStrings("Keep my draft", worker.commands.items[commands].text);
    try std.testing.expect(worker.commands.items[commands + 1].kind == .hide);
    chats[1].hidden = true; // The worker publishes the saved setting.
    try app.reconcileSelection();
    try std.testing.expectEqualStrings("", app.key);
    try app.toggleHidden();
    try std.testing.expect(app.show_hidden and app.matchesSidebar(chats[0]));
    try std.testing.expectEqualStrings("spam", app.key);
    try app.setSelectedHidden(false);
    try std.testing.expect(worker.commands.items[worker.commands.items.len - 1].kind == .unhide);
    chats[0].hidden = false;
    try app.reconcileSelection();
    try std.testing.expectEqualStrings("friend", app.key);
    try app.toggleHidden();
    try std.testing.expect(!app.show_hidden and app.matchesSidebar(chats[0]));
    try std.testing.expectEqualStrings("spam", app.key);
}

test "workspace navigation, compact lists, message selection, and scrollbars render correctly" {
    // Raylib logs to stdout, which Zig's test runner reserves for its protocol.
    rl.setTraceLogLevel(.none);
    rl.setConfigFlags(.{ .window_highdpi = true });
    rl.initWindow(1120, 780, "Zimbr UI checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    rl.setTargetFPS(60);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = clay.initialize(.init(try arena.allocator().alloc(u8, clay.minMemorySize())), .{ .w = 1120, .h = 780 }, .{ .error_handler_function = clayError });
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/zimbr-ui-test" } };
    defer worker.shutdown();
    const Store = @import("client/Store.zig");
    var chats: [32]Store.Chat = undefined;
    for (&chats, 0..) |*chat, i| chat.* = .{
        .value = .{ .id = try std.fmt.allocPrint(arena.allocator(), "fixture-{d}", .{i}), .service = "imessage", .title = try std.fmt.allocPrint(arena.allocator(), "Conversation {d} long wrapped label", .{i}), .last_activity = "2026-01-01T00:00:00Z", .sendable = true },
        .preview = "This preview must stay below the search box.",
        .unread = 1,
    };
    const view = try a.create(Worker.View);
    view.* = .{ .arena = std.heap.ArenaAllocator.init(a), .snapshot = .{ .chats = &chats, .messages = &.{}, .pending = &.{}, .selected = "fixture-0", .draft = "", .epoch = "", .more = false }, .status = "Offline", .online = false, .send_direct = false, .reply_existing = false, .generation = 1, .ack = 0 };
    var app = App{ .worker = &worker, .view = view, .key = try a.dupe(u8, "fixture-0"), .focus = .none };
    defer app.deinit();
    for (0..4) |_| app.draw(WindowMetrics.current().scale);
    const before = try captureTestFrame(&app, WindowMetrics.current().scale);
    defer rl.unloadImage(before);
    const scale = WindowMetrics.current().scale;
    for ([_]f32{ 25, 53, 107, 345 }) |scroll| {
        app.sidebar_scroll = scroll;
        const after = try captureTestFrame(&app, scale);
        defer rl.unloadImage(after);
        const fixed = layout.frame(1120, 780, app.composerHeight());
        const right: i32 = @intFromFloat((fixed.sidebar.x + fixed.sidebar.width - 1) * scale);
        const bottom: i32 = @intFromFloat(App.sidebarViewport(fixed.sidebar).y * scale);
        var y: i32 = 0;
        while (y < bottom) : (y += 1) {
            var x: i32 = 0;
            while (x < right) : (x += 1) try std.testing.expectEqual(rl.getImageColor(before, x, y), rl.getImageColor(after, x, y));
        }
        try std.testing.expectEqual(@as(usize, 0), clip_depth);
    }
    const dark = try captureTestFrame(&app, scale);
    defer rl.unloadImage(dark);
    try std.testing.expectEqual(theme.colors.rail, rl.getImageColor(dark, @intFromFloat(5 * scale), @intFromFloat(50 * scale)));
    try std.testing.expectEqual(theme.colors.sidebar, rl.getImageColor(dark, @intFromFloat(70 * scale), @intFromFloat(50 * scale)));
    try std.testing.expectEqual(theme.colors.paper, rl.getImageColor(dark, @intFromFloat(320 * scale), @intFromFloat(50 * scale)));
    app.toggleDetails();
    app.draw(scale);
    try std.testing.expect(app.details_height > 0);
    app.details_scroll = 100000;
    app.draw(scale);
    try std.testing.expect(app.details_scroll < 100000);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);
    app.toggleDetails();
    app.draw(scale);
    try std.testing.expect(!app.show_details);
    // A narrow, short window exercises wrapping and the diagnostics scroll path.
    rl.setWindowSize(780, 560);
    for (0..4) |_| app.draw(WindowMetrics.current().scale);
    app.toggleDetails();
    app.draw(WindowMetrics.current().scale);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);

    // Exercise every scrollbar with overflowing content, including a draft
    // whose caret is at the bottom while the user reads its first lines.
    app.show_details = false;
    chats[0].value.participants = &.{ "alice@example.invalid", "bob@example.invalid", "carol@example.invalid" };
    var group_messages: [12]t.Message = undefined;
    for (&group_messages, 0..) |*m, i| m.* = .{
        .id = try std.fmt.allocPrint(arena.allocator(), "group-{d}", .{i}),
        .sender = chats[0].value.participants[i % 3],
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = "A message from the group",
        .decoding = .plain,
        .observed_status = .received,
    };
    view.snapshot.messages = &group_messages;
    view.generation += 1;
    try app.composer.set("A longer draft line\n" ** 20);
    app.draw(WindowMetrics.current().scale);
    try std.testing.expect(app.composer_scroll > 0);
    app.composer_scroll = 0;
    {
        const shot = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer rl.unloadImage(shot);
        try std.testing.expectEqual(@as(f32, 0), app.composer_scroll);
        const areas = layout.frame(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()), app.composerHeight());
        try expectScrollbarPixel(shot, App.sidebarViewport(areas.sidebar), chats.len * App.sidebar_row_height, app.sidebar_scroll);
        try expectScrollbarPixel(shot, areas.history, app.content_height + 16, app.scroll);
        const editor = App.composerEditor(App.composerBox(areas.composer));
        const composer_viewport = rl.Rectangle{ .x = editor.x + 11, .y = editor.y + 10, .width = editor.width - 22, .height = editor.height - 20 };
        try expectScrollbarPixel(shot, composer_viewport, app.text.height(app.composer.text.items, 16, composer_viewport.width - Scrollbar.gutter), app.composer_scroll);
        const visible = app.visibleHistory(app.history_rows, areas.history.height);
        var checked: usize = 0;
        for (app.history_rows[visible.start..visible.end], group_messages[visible.start..visible.end]) |row, m| {
            const y = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 17;
            if (y < areas.history.y or y >= areas.history.y + areas.history.height) continue;
            const style = theme.participant(m.sender, chats[0].value.participants);
            const pixel = rl.getImageColor(shot, @intFromFloat((areas.history.x + 24) * WindowMetrics.current().scale), @intFromFloat(y * WindowMetrics.current().scale));
            try std.testing.expectEqual(style.bubble, pixel);
            checked += 1;
        }
        try std.testing.expect(checked >= 2);
        app.toggleDetails();
        app.draw(WindowMetrics.current().scale);
        const details = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer rl.unloadImage(details);
        try expectScrollbarPixel(details, .{ .x = areas.header.x + 24, .y = areas.header.y + 78, .width = areas.header.width - 32, .height = areas.composer.y + areas.composer.height - areas.header.y - 86 }, app.details_height, app.details_scroll);
        app.toggleDetails();
    }
    app.composer.caret = 0;
    app.draw(WindowMetrics.current().scale);
    app.composer.caret = app.composer.text.items.len;
    app.draw(WindowMetrics.current().scale);
    try std.testing.expect(app.composer_scroll > 0);
    try app.composer.set("");

    // Drive the actual mouse path: drag backwards within a message, release,
    // and verify the selected range stays highlighted and ready to copy.
    app.draw(scale);
    const selection_before = try captureTestFrame(&app, scale);
    defer rl.unloadImage(selection_before);
    const areas = layout.frame(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()), app.composerHeight());
    const row = app.history_rows[app.history_rows.len - 1];
    const text_width = App.historyTextWidth(areas.history);
    const text_x = areas.history.x + 66;
    const text_y = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 22;
    const start = app.text.caret(row.text, text_width, "A ".len);
    const end = app.text.caret(row.text, text_width, "A message".len);
    // raylib automation event IDs: mouse position = 7, down = 6, up = 5.
    rl.playAutomationEvent(.{ .frame = 0, .type = 7, .params = .{ @intFromFloat(text_x + end.x), @intFromFloat(text_y + end.y + end.height / 2), 0, 0 } });
    rl.playAutomationEvent(.{ .frame = 0, .type = 6, .params = .{ 0, 0, 0, 0 } });
    app.draw(scale);
    rl.playAutomationEvent(.{ .frame = 0, .type = 7, .params = .{ @intFromFloat(text_x + start.x), @intFromFloat(text_y + start.y + start.height / 2), 0, 0 } });
    const selection_after = try captureTestFrame(&app, scale);
    defer rl.unloadImage(selection_after);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());
    var highlighted: usize = 0;
    var py: i32 = @intFromFloat(text_y * scale);
    while (py < @as(i32, @intFromFloat((text_y + start.height) * scale))) : (py += 1) {
        var px: i32 = @intFromFloat((text_x + start.x) * scale);
        while (px < @as(i32, @intFromFloat((text_x + end.x) * scale))) : (px += 1) {
            if (!std.meta.eql(rl.getImageColor(selection_before, px, py), rl.getImageColor(selection_after, px, py))) highlighted += 1;
        }
    }
    try std.testing.expect(highlighted > 100);
    rl.playAutomationEvent(.{ .frame = 0, .type = 5, .params = .{ 0, 0, 0, 0 } });
    app.draw(scale);
    try std.testing.expect(!app.message_selection.dragging);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());

    // An uncertain send stays before a newer reply and retains its recovery action.
    group_messages[group_messages.len - 1].timestamp = "2026-01-01T00:02:00Z";
    const pending = [_]Store.Pending{.{
        .input = .{ .request_id = "pending-fixture", .server_epoch = "", .target = .{ .conversation_id = "fixture-0" }, .text = "Keep this uncertain send available as a draft." },
        .state = "unknown",
        .detail = "Connection interrupted before confirmation.",
        .record = null,
        .sent_at = "2026-01-01T00:01:00Z",
    }};
    view.snapshot.pending = &pending;
    view.generation += 1;
    app.draw(scale);
    const pending_row = app.history_rows[app.history_rows.len - 2];
    try std.testing.expect(pending_row.pending);
    try std.testing.expectEqualStrings(group_messages[group_messages.len - 1].id, app.history_rows[app.history_rows.len - 1].id);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());
    clickTestFrame(&app, areas.history.x + 66 + App.historyTextWidth(areas.history) - 59, areas.history.y + @as(f32, @floatCast(pending_row.top - app.scroll)) + pending_row.measured.? + 37);
    try std.testing.expectEqualStrings(pending[0].input.text, app.composer.text.items);
    try std.testing.expect(app.duplicate_risk);
    view.snapshot.pending = &.{};
    view.generation += 1;

    // Follow the relocated controls with real pointer events. Returning from
    // New message must restore composer focus, not the hidden recipient field.
    try app.newMessage();
    try std.testing.expect(app.new_mode and app.focus == .recipient);
    clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + 40);
    try std.testing.expect(!app.new_mode and app.focus == .composer);
    clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + 110);
    try std.testing.expect(app.show_hidden);
    clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + 40);
    try std.testing.expect(!app.show_hidden);
    clickTestFrame(&app, areas.rail.x + 32, areas.sidebar_footer.y + 8 - 43 + 28);
    try std.testing.expect(app.show_details);
    app.send_wait = true;
    clickTestFrame(&app, areas.header.x + areas.header.width - 24 - app.buttonSize("Back").x - 8 - app.buttonSize("Reconnect").x / 2, areas.header.y + 33);
    try std.testing.expect(!app.send_wait and app.show_details);
    try std.testing.expect(worker.commands.items[worker.commands.items.len - 1].kind == .reconnect);
    clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + 40);
    try std.testing.expect(!app.show_details);
    clickTestFrame(&app, areas.sidebar.x + 40, areas.sidebar.y + 30);
    try std.testing.expect(app.focus == .search);
    app.focus = .none;
    try app.composer.set("");

    // A chat becoming read-only blocks keyboard and pointer editing without
    // discarding its draft. Writable chats still support drafting offline.
    try app.composer.set("Saved draft");
    app.draft_dirty = false;
    a.free(app.loaded_key);
    app.loaded_key = try a.dupe(u8, app.key);
    chats[0].value.sendable = false;
    view.online = true;
    view.reply_existing = true;
    app.focus = .composer;
    for ([_]rl.KeyboardKey{ .backspace, .enter }) |key| {
        rl.playAutomationEvent(.{ .frame = 0, .type = 2, .params = .{ @intFromEnum(key), 0, 0, 0 } });
        try app.update();
        rl.playAutomationEvent(.{ .frame = 0, .type = 1, .params = .{ @intFromEnum(key), 0, 0, 0 } });
        try std.testing.expectEqualStrings("Saved draft", app.composer.text.items);
        try std.testing.expect(!app.send_wait and !app.draft_dirty and !app.canSend());
    }
    const disabled_box = App.composerBox(areas.composer);
    clickTestFrame(&app, disabled_box.x + 40, disabled_box.y + 16);
    try std.testing.expect(app.focus == .none);
    const disabled = try captureTestFrame(&app, scale);
    defer rl.unloadImage(disabled);
    try std.testing.expectEqual(theme.colors.incoming, rl.getImageColor(disabled, @intFromFloat((disabled_box.x + 5) * scale), @intFromFloat((disabled_box.y + disabled_box.height / 2) * scale)));
    clickTestFrame(&app, areas.composer.x + areas.composer.width - layout.action_right_padding - 38, disabled_box.y + disabled_box.height / 2);
    for (worker.commands.items) |command| try std.testing.expect(command.kind != .send);
    chats[0].value.sendable = true;
    view.online = false;
    view.reply_existing = false;
    clickTestFrame(&app, disabled_box.x + 40, disabled_box.y + 16);
    try std.testing.expect(app.focus == .composer);
    app.composer.caret = app.composer.text.items.len;
    app.composer.anchor = app.composer.caret;
    rl.playAutomationEvent(.{ .frame = 0, .type = 2, .params = .{ @intFromEnum(rl.KeyboardKey.backspace), 0, 0, 0 } });
    try app.update();
    rl.playAutomationEvent(.{ .frame = 0, .type = 1, .params = .{ @intFromEnum(rl.KeyboardKey.backspace), 0, 0, 0 } });
    try std.testing.expectEqualStrings("Saved draf", app.composer.text.items);
    app.focus = .none;
    app.draft_dirty = false;
    try app.composer.set("");

    // A large cached conversation must settle over multiple frames, keeping
    // input responsive and never painting full text into estimated row heights.
    app.show_details = false;
    app.heights.clearRetainingCapacity();
    var messages: [420]t.Message = undefined;
    const bodies = [_][]const u8{ "Normal é 👩‍💻 שלום مرحبا", "https://example.invalid/" ++ "W" ** 65500, "\n" ** 65536, "a" ++ "́" ** 1000, "nul\x00tail", "bad\xff" };
    for (&messages, 0..) |*m, i| m.* = .{
        .id = try std.fmt.allocPrint(arena.allocator(), "message-{d}", .{i}),
        .conversation_id = "fixture-0",
        .sender = "long-sender-" ** 100,
        .direction = if (i % 2 == 0) .incoming else .outgoing,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = try std.fmt.allocPrint(arena.allocator(), "{d}: {s}", .{ i, bodies[i % bodies.len] }),
        .decoding = .plain,
        .observed_status = .received,
    };
    view.snapshot.messages = &messages;
    view.generation += 1;
    app.draw(WindowMetrics.current().scale);
    try std.testing.expect(app.layout_pending);
    try std.testing.expect(app.heights.count() <= App.max_height_work);
    const newest = messageText(arena.allocator(), messages[messages.len - 1]);
    try std.testing.expect(app.heights.contains(std.hash.Wyhash.hash(0, newest)));
    var frames: usize = 0;
    while (app.layout_pending and frames < 200) : (frames += 1) app.draw(WindowMetrics.current().scale);
    try std.testing.expect(!app.layout_pending);
    try std.testing.expectEqual(messages.len, app.heights.count());
    try std.testing.expect(app.text.texture_bytes <= 32 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);
}

fn expectScrollbarPixel(shot: rl.Image, viewport: rl.Rectangle, content: f64, offset: f64) !void {
    const g = Scrollbar.geometry(viewport, content, offset) orelse return error.MissingScrollbar;
    const scale = WindowMetrics.current().scale;
    const pixel = rl.getImageColor(shot, @intFromFloat((g.thumb.x + g.thumb.width / 2) * scale), @intFromFloat((g.thumb.y + g.thumb.height / 2) * scale));
    try std.testing.expect(std.meta.eql(pixel, theme.colors.muted) or std.meta.eql(pixel, theme.colors.accent));
}

test "shared message presentations survive replaced views and refresh edited text" {
    const Store = @import("client/Store.zig");
    const SharedSnapshot = @import("client/SharedSnapshot.zig");
    const store = try Store.open(":memory:");
    defer store.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var message = t.Message{ .id = "m1", .conversation_id = "c1", .sender = "peer", .direction = .incoming, .service = "imessage", .timestamp = "2026-01-01T00:00:00Z", .kind = .text, .text = "Long " ++ "x" ** 6000, .decoding = .plain, .observed_status = .received };
    _ = try store.upsert(ar, "message", try u.json(ar, message));
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    rl.setTraceLogLevel(.none);
    rl.initWindow(780, 560, "Zimbr shared view checks");
    defer rl.closeWindow();
    var app = App{ .worker = &worker, .key = try a.dupe(u8, "c1"), .focus = .none };
    defer app.deinit();
    var first_rows: ?[*]App.HistoryRow = null;
    for (0..3) |iteration| {
        if (iteration == 2) {
            message.revision = "1";
            message.text = "Edited 👩‍💻";
            _ = try store.upsert(ar, "message", try u.json(ar, message));
        }
        const shared = try SharedSnapshot.create(store, "c1", iteration + 1, if (app.view) |old| old.shared else null);
        const view = try a.create(Worker.View);
        view.* = .{ .arena = .init(a), .snapshot = shared.snapshot, .shared = shared, .content_generation = shared.generation, .status = "Offline", .online = false, .send_direct = false, .reply_existing = false, .generation = iteration + 1, .ack = 0 };
        worker.view = view;
        try app.update();
        const rows = try app.prepareHistory(320);
        try std.testing.expectEqual(shared.history.presentations[0].text.ptr, rows[0].text.ptr);
        if (iteration == 0) {
            first_rows = rows.ptr;
            try std.testing.expect(std.mem.endsWith(u8, rows[0].text, display.shortened));
            try std.testing.expectEqual(@as(usize, 6005), view.snapshot.messages[0].text.?.len);
            try app.message_selection.begin(rows[0].id, false, rows[0].text, message.text.?, 0);
            app.message_selection.caret = "Long".len;
        } else if (iteration == 1) {
            try std.testing.expectEqual(first_rows.?, rows.ptr);
            try std.testing.expect(std.mem.endsWith(u8, rows[0].text, display.shortened));
            try std.testing.expectEqualStrings("Long", app.message_selection.selected());
        } else {
            try std.testing.expectEqualStrings("Edited 👩‍💻", rows[0].text);
            try std.testing.expectEqualStrings("", app.message_selection.selected());
        }
    }
}

test "history larger than the old cache limit renders newest first and settles" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/zimbr-history-test" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    const view = try a.create(Worker.View);
    view.* = .{ .arena = std.heap.ArenaAllocator.init(a), .snapshot = .{ .chats = &.{}, .messages = &.{}, .pending = &.{}, .selected = "large-history", .draft = "", .epoch = "", .more = false }, .status = "Offline", .online = false, .send_direct = false, .reply_existing = false, .generation = 1, .ack = 0 };
    app.view = view;
    app.text.nextFrame(1.25);
    const ar = view.arena.allocator();
    const messages = try ar.alloc(t.Message, 17000);
    for (messages, 0..) |*m, i| m.* = .{
        .id = try std.fmt.allocPrint(ar, "message-{d}", .{i}),
        .sender = "fixture",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = try std.fmt.allocPrint(ar, "Message {d}\nA second line", .{i}),
        .decoding = .plain,
        .observed_status = .received,
    };
    view.snapshot.messages = messages;
    var frames: usize = 0;
    while (frames < messages.len) : (frames += 1) {
        const rows = try app.prepareHistory(320);
        app.positionHistory(rows, 500);
        const before = app.heights.count();
        app.measureHistory(rows, 320, 500);
        app.rememberHistoryAnchor(rows);
        try std.testing.expect(app.heights.count() > before);
        try std.testing.expect(app.heights.count() - before <= App.max_height_work);
        if (frames == 0) {
            try std.testing.expect(rows[rows.len - 1].measured != null);
            try std.testing.expect(rows[0].measured == null);
        }
        // Repeated frames reuse previews and partially measured rows.
        try std.testing.expectEqual(rows.ptr, (try app.prepareHistory(320)).ptr);
        // Fractional heights must not accumulate into visible drift, even on
        // the first frame or with millions of pixels above the viewport.
        const last_y = rows[rows.len - 1].top - app.scroll;
        try std.testing.expectApproxEqAbs(484 - @as(f64, rows[rows.len - 1].height()), last_y, 0.000001);
        if (!app.layout_pending) break;
    }
    try std.testing.expect(!app.layout_pending);
    try std.testing.expectEqual(messages.len, app.heights.count());
    const settled_height = app.content_height;
    const settled_scroll = app.scroll;
    for (0..3) |_| {
        const rows = try app.prepareHistory(320);
        app.positionHistory(rows, 500);
        app.measureHistory(rows, 320, 500);
        try std.testing.expect(!app.layout_pending);
        try std.testing.expectEqual(settled_height, app.content_height);
        try std.testing.expectEqual(settled_scroll, app.scroll);
    }
    // A new snapshot with the same row count must refresh changed previews.
    messages[messages.len - 1].text = "Updated newest message";
    view.generation += 1;
    const updated = try app.prepareHistory(320);
    try std.testing.expectEqualStrings("Updated newest message", updated[updated.len - 1].text);
    try std.testing.expect(updated[updated.len - 1].measured == null);
    try std.testing.expect(updated[0].measured != null);
    // Resizing replaces old geometry; switching conversations releases its
    // measurements rather than accumulating unrelated histories indefinitely.
    _ = try app.prepareHistory(200);
    try std.testing.expectEqual(@as(u32, 0), app.heights.count());
    view.snapshot.selected = "other-history";
    view.snapshot.messages = messages[0..1];
    const other = try app.prepareHistory(320);
    app.positionHistory(other, 500);
    app.measureHistory(other, 320, 500);
    try std.testing.expectEqual(@as(u32, 1), app.heights.count());
}

test "reading position survives deferred heights and prepended history" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/zimbr-history-test" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .following = false };
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows: [800]App.HistoryRow = undefined;
    for (&rows, 0..) |*row, i| {
        const text = try std.fmt.allocPrint(arena.allocator(), "Message {d}\nLine two\nLine three", .{i});
        row.* = .{ .id = text, .text = text, .key = std.hash.Wyhash.hash(0, text), .measured = null, .padding = 54 };
    }
    const visible = rows[300..];
    app.scroll = 54 + 30 * 78 + 10;
    app.positionHistory(visible, 300);
    app.rememberHistoryAnchor(visible);
    const anchor = try arena.allocator().dupe(u8, app.history_anchor);
    const offset = app.anchor_offset;
    for (0..rows.len) |_| {
        app.positionHistory(visible, 300);
        app.measureHistory(visible, 320, 300);
        app.rememberHistoryAnchor(visible);
        try std.testing.expectEqualStrings(anchor, app.history_anchor);
        try std.testing.expectEqual(offset, app.anchor_offset);
        if (!app.layout_pending) break;
    }
    try std.testing.expect(!app.layout_pending);
    // Loading older messages uses the same anchor immediately, even before
    // their final heights are known, and never waits for the whole chat.
    for (0..rows.len) |_| {
        app.positionHistory(&rows, 300);
        app.measureHistory(&rows, 320, 300);
        app.rememberHistoryAnchor(&rows);
        try std.testing.expectEqualStrings(anchor, app.history_anchor);
        try std.testing.expectEqual(offset, app.anchor_offset);
        if (!app.layout_pending) break;
    }
    try std.testing.expect(!app.layout_pending);
}

test "loading reveals final rows without moving the newest message or snapping small scrolls" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/zimbr-history-test" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    var rows = [_]App.HistoryRow{
        .{ .id = "old", .text = "", .key = 0, .measured = null, .padding = 54 },
        .{ .id = "recent", .text = "", .key = 1, .measured = 31.2, .padding = 54 },
        .{ .id = "latest", .text = "", .key = 2, .measured = 31.2, .padding = 54 },
    };
    app.positionHistory(&rows, 500);
    const before = rows[2].top - app.scroll;
    const partial = app.visibleHistory(&rows, 500);
    try std.testing.expect(partial.loading);
    try std.testing.expectEqual(@as(usize, 1), partial.start);
    try std.testing.expectEqual(@as(usize, 3), partial.end);
    // A short history grows beyond the viewport while the already displayed
    // newest messages stay at exactly the same screen coordinates.
    rows[0].measured = 1000.8;
    app.positionHistory(&rows, 500);
    try std.testing.expectApproxEqAbs(before, rows[2].top - app.scroll, 0.000001);
    try std.testing.expect(!app.visibleHistory(&rows, 500).loading);

    app.scrollHistory(0.1, 500);
    try std.testing.expect(!app.following);
    app.rememberHistoryAnchor(&rows);
    const scrolled = app.scroll;
    app.positionHistory(&rows, 500);
    try std.testing.expectApproxEqAbs(scrolled, app.scroll, 0.000001);
    app.scrollHistory(-0.1, 500);
    try std.testing.expect(app.following);

    // In reading mode, do not expose later bubbles under an estimated row.
    app.following = false;
    rows[0].measured = null;
    app.content_height = 3000;
    app.scroll = 0;
    rows[0].top = 54;
    rows[1].top = 132;
    rows[2].top = 218;
    const loading = app.visibleHistory(&rows, 500);
    try std.testing.expect(loading.loading);
    try std.testing.expectEqual(loading.start, loading.end);
}

test "offscreen measurements match drawing metrics without evicting layouts" {
    var text = Text{};
    defer text.deinit();
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        text.nextFrame(scale);
        for ([_][]const u8{ "Hello", "Café 👩‍💻 שלום مرحبا\nSecond line", "wrapped " ** 150, "bad\xff", "a" ++ "́" ** 1000 }) |body| {
            const drawn_height = text.height(body, 16, 320);
            const count = text.entries.items.len;
            try std.testing.expectEqual(drawn_height, text.measure(body, 16, 320));
            try std.testing.expectEqual(count, text.entries.items.len);
        }
    }
}

fn clickTestFrame(app: *App, x: f32, y: f32) void {
    rl.playAutomationEvent(.{ .frame = 0, .type = 7, .params = .{ @intFromFloat(x), @intFromFloat(y), 0, 0 } });
    rl.playAutomationEvent(.{ .frame = 0, .type = 6, .params = .{ 0, 0, 0, 0 } });
    app.draw(WindowMetrics.current().scale);
    rl.playAutomationEvent(.{ .frame = 0, .type = 5, .params = .{ 0, 0, 0, 0 } });
    app.draw(WindowMetrics.current().scale);
}

fn captureTestFrame(app: *App, scale: f32) !rl.Image {
    app.capture_frame = true;
    defer app.capture_frame = false;
    app.draw(scale);
    const shot = app.captured orelse return error.ScreenshotFailed;
    app.captured = null;
    return shot;
}

test "text remains intact when layouts evict textures queued in the same frame" {
    rl.setTraceLogLevel(.none);
    rl.initWindow(640, 360, "Zimbr text cache checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    var text = Text{};
    defer text.deinit();
    for (0..4) |_| {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.white);
        rl.endDrawing();
        rl.pollInputEvents();
    }
    var images: [2]rl.Image = undefined;
    for (&images, 0..) |*shot, pass| {
        text.nextFrame(1);
        rl.beginDrawing();
        rl.clearBackground(rl.Color.white);
        text.draw("Message text must retain its glyphs and proportions", 20, 20, 16, 500, rl.Color.black, rl.Color.white);
        // Recoloring and selection share metrics but replace the texture.
        text.drawSelection("Message text must retain its glyphs and proportions", 20, 60, 16, 500, rl.Color.red, 0, 7, rl.Color.white);
        if (pass == 1) {
            var buf: [64]u8 = undefined;
            for (0..400) |i| {
                const label = try std.fmt.bufPrint(&buf, "Offscreen message {d}", .{i});
                _ = text.height(label, 16, 320);
            }
        }
        rl.gl.rlDrawRenderBatchActive();
        shot.* = try rl.loadImageFromScreen();
        rl.endDrawing();
    }
    defer for (images) |shot| rl.unloadImage(shot);
    const before = images[0];
    const after = images[1];
    try std.testing.expectEqual(before.width, after.width);
    try std.testing.expectEqual(before.height, after.height);
    var ink: usize = 0;
    var y: i32 = 0;
    while (y < before.height) : (y += 1) {
        var x: i32 = 0;
        while (x < before.width) : (x += 1) {
            if (!std.meta.eql(rl.Color.white, rl.getImageColor(before, x, y))) ink += 1;
            try std.testing.expectEqual(rl.getImageColor(before, x, y), rl.getImageColor(after, x, y));
        }
    }
    try std.testing.expect(ink > 100);
    // Even a viewport spanning multiple 2048-pixel tiles must draw to its
    // bottom. Synthetic 8x scale exercises this on an ordinary display.
    text.nextFrame(8);
    rl.beginDrawing();
    rl.clearBackground(rl.Color.white);
    text.draw("Visible text at every height\n" ** 40, 20, 0, 16, 300, rl.Color.black, rl.Color.white);
    rl.gl.rlDrawRenderBatchActive();
    const tall = try rl.loadImageFromScreen();
    rl.endDrawing();
    defer rl.unloadImage(tall);
    ink = 0;
    y = @divTrunc(tall.height * 3, 4);
    while (y < tall.height) : (y += 1) {
        var x: i32 = 0;
        while (x < tall.width) : (x += 1) {
            if (!std.meta.eql(rl.Color.white, rl.getImageColor(tall, x, y))) ink += 1;
        }
    }
    try std.testing.expect(ink > 100);
}
