const std = @import("std");
const rl = @import("raylib");
const clay = @import("zclay");
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
    // Let Wayland deliver its initial scale before caching any text textures.
    rl.pollInputEvents();
    rl.setWindowMinSize(780, 560);
    rl.setExitKey(.null);
    rl.setTargetFPS(30);
    _ = clay.initialize(.init(try init.arena.allocator().alloc(u8, clay.minMemorySize())), .{ .w = 1120, .h = 780 }, .{ .error_handler_function = clayError });
    var worker = Worker{ .io = init.io, .config = config };
    try worker.start();
    defer worker.shutdown();
    theme.setDark(config.theme == .dark);
    var app = App{ .worker = &worker, .enter_to_send = config.enter_to_send, .theme_loaded = config.theme != null, .show_details = config.details };
    defer app.deinit();
    var frames: usize = 0;
    var last_draw: i64 = 0;
    var last_generation: u64 = 0;
    var last_revision: u64 = 0;
    var last_mouse = rl.getMousePosition();
    var last_window = WindowMetrics{};
    while (!rl.windowShouldClose()) {
        try app.update();
        const generation = if (app.view) |v| v.generation else 0;
        const revision = app.composer.revision + app.search.revision + app.recipient.revision;
        const mouse = rl.getMousePosition();
        const window = WindowMetrics.current();
        const input = rl.getKeyPressed() != .null or rl.isMouseButtonDown(.left) or rl.isMouseButtonReleased(.left) or rl.getMouseWheelMove() != 0 or mouse.x != last_mouse.x or mouse.y != last_mouse.y;
        if (frames < 4 or config.frames > 0 or app.layout_pending or input or rl.isWindowResized() or !std.meta.eql(window, last_window) or generation != last_generation or revision != last_revision or u.now() - last_draw >= 500) {
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
    was_focused: bool = true,
    theme_loaded: bool = false,
    show_details: bool = false,
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
    fn saveDraft(s: *App) !void {
        if (s.draft_dirty and s.key.len > 0) {
            try s.worker.push(.{ .kind = .draft, .key = s.key, .text = s.composer.text.items });
            s.draft_dirty = false;
        }
    }
    fn select(s: *App, key: []const u8) !void {
        s.show_details = false;
        try s.saveDraft();
        try s.worker.push(.{ .kind = .select, .key = key });
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
            if (!s.theme_loaded) {
                theme.setDark(v.dark_mode);
                s.theme_loaded = true;
            }
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
        if (s.key.len == 0 and !s.new_mode and !s.show_details) if (s.view) |v| {
            if (v.snapshot.chats.len > 0) try s.select(v.snapshot.chats[0].value.id);
        };
        if (s.draft_dirty and u.now() - s.draft_at > 300) try s.saveDraft();
        const focused = rl.isWindowFocused();
        if (focused != s.was_focused) {
            s.worker.push(.{ .kind = .viewed, .text = if (focused and s.following and !s.show_details) "yes" else "no" }) catch {};
            s.was_focused = focused;
        }
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        if (ctrl and rl.isKeyPressed(.f)) {
            s.message_selection.clear();
            s.focus = .search;
        }
        if (ctrl and rl.isKeyPressed(.d)) s.toggleDetails();
        if (ctrl and rl.isKeyPressed(.n)) {
            try s.saveDraft();
            s.message_selection.clear();
            s.show_details = false;
            s.new_mode = true;
            s.focus = .recipient;
        }
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
        } else if (s.focus == .none and s.message_selection.id.len > 0) {
            if (ctrl and rl.isKeyPressed(.a)) s.message_selection.selectAll();
            if (ctrl and rl.isKeyPressed(.c) and s.message_selection.selected().len > 0) {
                const clip = try a.dupeZ(u8, s.message_selection.selected());
                defer a.free(clip);
                rl.setClipboardText(clip);
                s.info("Selected text copied");
            }
            while (rl.getCharPressed() != 0) {}
        }
    }
    fn startDirect(s: *App) !void {
        const address = std.mem.trim(u8, s.recipient.text.items, " \n\r\t");
        if (!t.validAddress(address)) {
            s.info("Use an international number (+country code) or an email address.");
            return;
        }
        const key = try std.fmt.allocPrint(a, "new:{s}", .{address});
        defer a.free(key);
        try s.select(key);
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
        const areas = layout.frame(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()));
        std.debug.assert(clip_depth == 0);
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(theme.colors.paper);
        rl.setMouseCursor(.default);
        s.drawSidebar(areas.sidebar, ar);
        if (s.show_details) {
            s.drawDetails(.{ .x = areas.header.x, .y = areas.header.y, .width = areas.header.width, .height = areas.status.y - areas.header.y }, ar);
        } else {
            s.drawHeader(areas.header, ar);
            beginClip(areas.history);
            if (s.new_mode) {
                const r = areas.history;
                s.text.draw("Start a conversation", r.x + 32, r.y + 34, 25, r.width - 64, theme.colors.ink);
                s.text.draw("Send an iMessage to a phone number or email address.", r.x + 32, r.y + 72, 15, r.width - 64, theme.colors.muted);
                const field = rl.Rectangle{ .x = r.x + 32, .y = r.y + 110, .width = r.width - 64, .height = 46 };
                s.inputBox(&s.recipient, field, "+1 415 555 0123 or name@example.com", .recipient, false);
                if (s.button(.{ .x = r.x + 32, .y = r.y + 176, .width = 164, .height = 36 }, "Continue", true)) s.startDirect() catch s.info("Could not open conversation.");
                s.text.draw("Existing groups appear in your conversations.\nCreating groups is not supported yet.", r.x + 32, r.y + 236, 14, r.width - 64, theme.colors.muted);
            } else if (s.key.len > 0) s.drawHistory(areas.history, ar) else {
                const r = areas.history;
                s.text.draw("Your conversations, here.", r.x + 36, r.y + r.height / 2 - 56, 27, r.width - 72, theme.colors.ink);
                s.text.draw("Connect to your Mac to get started.\nYour cached messages stay available offline.", r.x + 36, r.y + r.height / 2 - 4, 16, r.width - 72, theme.colors.muted);
            }
            endClip();
            s.drawComposer(areas.composer);
        }
        const status = areas.status;
        rl.drawRectangleRec(status, theme.colors.sidebar);
        rl.drawCircle(@intFromFloat(status.x + 22), @intFromFloat(status.y + 18), 4, if (s.view != null and s.view.?.online) theme.colors.accent else theme.colors.danger);
        const msg = if (u.now() < s.notice_until) s.notice else if (s.view) |v| v.status else "Opening cache…";
        beginClip(.{ .x = status.x + 32, .y = status.y, .width = status.width - 142, .height = status.height });
        s.text.draw(msg, status.x + 32, status.y + 9, 12, status.width - 142, theme.colors.muted);
        endClip();
        if (s.button(.{ .x = status.x + status.width - 104, .y = status.y + 4, .width = 92, .height = 28 }, "Reconnect", false)) {
            s.worker.push(.{ .kind = .reconnect }) catch {};
            s.send_wait = false;
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
    fn toggleTheme(s: *App) void {
        const next = !theme.is_dark;
        s.worker.push(.{ .kind = .appearance, .text = if (next) "dark" else "light" }) catch {
            s.info("Could not save appearance. Try again.");
            return;
        };
        theme.setDark(next);
        s.theme_loaded = true;
    }
    fn drawSidebar(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        rl.drawRectangleRec(r, theme.colors.sidebar);
        rl.drawLine(@intFromFloat(r.width - 1), 0, @intFromFloat(r.width - 1), @intFromFloat(r.height), theme.colors.line);
        const viewport = rl.Rectangle{ .x = 8, .y = 158, .width = r.width - 16, .height = @max(0, r.height - 210) };
        var clip = viewport;
        clip.width -= Scrollbar.gutter;
        var count: usize = 0;
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (s.search.text.items.len == 0 or std.ascii.indexOfIgnoreCase(chatName(chat.value), s.search.text.items) != null) count += 1;
        };
        const content_height = @as(f32, @floatFromInt(count)) * 78;
        if (hover(viewport)) s.sidebar_scroll -= rl.getMouseWheelMove() * 34 * Scrollbar.wheel_scale;
        s.sidebar_scroll = std.math.clamp(s.sidebar_scroll, 0, @max(0, content_height - clip.height));
        if (s.sidebar_bar.update(viewport, content_height, s.sidebar_scroll, scrollbarInput())) |offset| s.sidebar_scroll = @floatCast(offset);
        beginClip(clip);
        var y = clip.y - s.sidebar_scroll;
        if (s.view) |v| {
            for (v.snapshot.chats) |chat| {
                const name = chatName(chat.value);
                if (s.search.text.items.len > 0 and std.ascii.indexOfIgnoreCase(name, s.search.text.items) == null) continue;
                const row = rl.Rectangle{ .x = 10, .y = y, .width = clip.width - 4, .height = 72 };
                y += 78;
                if (row.y + row.height < clip.y or row.y > clip.y + clip.height) continue;
                const selected = u.eq(s.key, chat.value.id) and !s.new_mode and !s.show_details;
                const hot = hover(row) and hover(clip);
                if (selected or hot) rl.drawRectangleRounded(row, 0.16, 8, if (selected) theme.colors.selected else theme.colors.line);
                const avatar = rl.Rectangle{ .x = row.x + 10, .y = row.y + 16, .width = 34, .height = 34 };
                rl.drawRectangleRounded(avatar, 1, 12, if (selected) theme.colors.accent else theme.colors.avatar);
                const initial = if (chat.value.participants.len > 1) "#" else if (name.len > 0 and std.ascii.isAlphabetic(name[0])) std.fmt.allocPrint(ar, "{c}", .{std.ascii.toUpper(name[0])}) catch "?" else "+";
                s.text.draw(initial, avatar.x + 10, avatar.y + 6, 18, 26, if (selected) theme.colors.on_accent else theme.colors.ink);
                // Each child clip intersects the list viewport and restores it
                // when popped, including rows partly behind the search header.
                beginClip(.{ .x = row.x + 54, .y = row.y + 10, .width = row.width - 119, .height = 21 });
                s.text.draw(display.label(ar, name), row.x + 54, row.y + 10, 15, row.width - 119, theme.colors.ink);
                endClip();
                beginClip(.{ .x = row.x + row.width - 61, .y = row.y + 12, .width = 56, .height = 18 });
                if (chat.value.last_activity) |stamp| s.text.draw(localTime(ar, stamp, true), row.x + row.width - 61, row.y + 12, 10, 56, theme.colors.muted);
                endClip();
                beginClip(.{ .x = row.x + 54, .y = row.y + 32, .width = row.width - 70, .height = 32 });
                s.text.draw(display.label(ar, chat.preview), row.x + 54, row.y + 32, 12, row.width - 70, theme.colors.muted);
                endClip();
                if (chat.unread > 0) rl.drawCircle(@intFromFloat(row.x + row.width - 10), @intFromFloat(row.y + 43), 3, theme.colors.accent);
                if (hot and rl.isMouseButtonPressed(.left)) s.select(chat.value.id) catch s.info("Could not open conversation.");
            }
            if (count == 0) s.text.draw(if (v.online) "No conversations found" else "Waiting for your Mac…", 20, clip.y + 18, 14, r.width - 40, theme.colors.muted);
        }
        endClip();
        s.sidebar_bar.draw(viewport, content_height, s.sidebar_scroll);
        // Fixed controls are drawn after the list, above all scrolling content.
        rl.drawRectangleRounded(.{ .x = 18, .y = 20, .width = 30, .height = 30 }, 0.35, 10, theme.colors.accent);
        s.text.draw("z", 27, 19, 25, 26, theme.colors.on_accent);
        s.text.draw("zimbr", 58, 18, 26, 180, theme.colors.ink);
        s.text.draw("MESSAGES", 20, 81, 11, 150, theme.colors.muted);
        if (s.button(.{ .x = r.width - 52, .y = 71, .width = 32, .height = 30 }, "+", false)) {
            s.saveDraft() catch {};
            s.message_selection.clear();
            s.show_details = false;
            s.new_mode = true;
            s.focus = .recipient;
        }
        s.inputBox(&s.search, .{ .x = 16, .y = 112, .width = r.width - 32, .height = 34 }, "Search conversations", .search, false);
        const footer_y = r.height - 42;
        rl.drawLine(16, @intFromFloat(footer_y - 8), @intFromFloat(r.width - 16), @intFromFloat(footer_y - 8), theme.colors.line);
        if (s.button(.{ .x = 16, .y = footer_y, .width = (r.width - 40) / 2, .height = 30 }, if (theme.is_dark) "Light mode" else "Dark mode", false)) s.toggleTheme();
        if (s.button(.{ .x = r.width / 2 + 4, .y = footer_y, .width = (r.width - 40) / 2, .height = 30 }, "Details", s.show_details)) s.toggleDetails();
    }
    fn detailSection(s: *App, label: []const u8, r: rl.Rectangle, y: *f32) void {
        y.* += 18;
        s.text.draw(label, r.x, y.*, 17, r.width, theme.colors.ink);
        y.* += 32;
    }
    fn detailRow(s: *App, label: []const u8, value: []const u8, r: rl.Rectangle, y: *f32) void {
        const label_width: f32 = 122;
        const value_width = @max(80, r.width - label_width - 12);
        const height = @max(20, s.text.height(value, 14, value_width));
        s.text.draw(label, r.x, y.* + 1, 12, label_width - 8, theme.colors.muted);
        s.text.draw(value, r.x + label_width, y.*, 14, value_width, theme.colors.ink);
        y.* += height + 10;
    }
    fn drawDetails(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        s.text.draw("Technical details", r.x + 24, r.y + 14, 21, r.width - 150, theme.colors.ink);
        s.text.draw("Connection, synchronization and this client", r.x + 24, r.y + 43, 13, r.width - 48, theme.colors.muted);
        if (s.button(.{ .x = r.x + r.width - 98, .y = r.y + 18, .width = 74, .height = 30 }, "Back", false)) s.toggleDetails();
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
        s.detailRow("Version", @import("client_options").version, clip, &y);
        s.detailRow("Platform", @tagName(@import("builtin").os.tag) ++ " / " ++ @tagName(@import("builtin").cpu.arch) ++ " · Wayland", clip, &y);
        s.detailRow("Rendering", "raylib / Clay · Pango / Cairo · grayscale antialiasing", clip, &y);
        s.detailRow("Display", std.fmt.allocPrint(ar, "{d} × {d} logical · {d} × {d} pixels · {d:.0}% scale", .{ rl.getScreenWidth(), rl.getScreenHeight(), rl.getRenderWidth(), rl.getRenderHeight(), s.text.scale * 100 }) catch "", clip, &y);
        s.detailRow("Appearance", if (theme.is_dark) "Dark" else "Light", clip, &y);
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
        var title: []const u8 = "Welcome to Zimbr";
        var subtitle: []const u8 = "A little closer, wherever you work.";
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
        beginClip(.{ .x = r.x + 24, .y = r.y + 12, .width = r.width - 48, .height = 56 });
        s.text.draw(display.label(ar, title), r.x + 24, r.y + 13, 21, r.width - 48, theme.colors.ink);
        s.text.draw(subtitle, r.x + 24, r.y + 43, 13, r.width - 48, theme.colors.muted);
        endClip();
        rl.drawLine(@intFromFloat(r.x), @intFromFloat(r.y + r.height), @intFromFloat(r.x + r.width), @intFromFloat(r.y + r.height), theme.colors.line);
    }
    const HistoryRow = struct {
        id: []const u8,
        text: []const u8,
        key: u64,
        measured: ?f32,
        padding: f32,
        pending: bool = false,
        top: f64 = 0,

        fn height(row: HistoryRow) f32 {
            return (row.measured orelse 24) + row.padding;
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
            row.* = .{ .id = m.id, .text = text, .key = key, .measured = s.heights.get(key), .padding = 54 };
        }
        for (snapshot.pending, rows[snapshot.messages.len..]) |p, *row| {
            const text = display.message(ar, p.input.text);
            const key = std.hash.Wyhash.hash(0, text);
            row.* = .{ .id = p.input.request_id, .text = text, .key = key, .measured = s.heights.get(key), .padding = if (p.detail.len > 0) 106 else 66, .pending = true };
        }
        s.history_rows = rows;
        s.history_generation = generation;
        if (s.message_selection.id.len > 0) {
            var valid = false;
            for (rows, 0..) |row, i| {
                if (!s.message_selection.matches(row.id, row.pending, row.text)) continue;
                const full = if (row.pending) snapshot.pending[i - snapshot.messages.len].input.text else snapshot.messages[i].text orelse row.text;
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
        const width = @min(500, r.width * 0.76);
        const inner = width - 24;
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
        if (v.snapshot.messages.len == 0 and v.snapshot.pending.len == 0) s.text.draw(if (v.loading_history) "Loading history…" else if (v.online) "The start of something good.\nWrite your first message below." else "No cached messages in this conversation.", r.x + 40, r.y + 90, 17, r.width - 80, theme.colors.muted);
        const visible = s.visibleHistory(rows, r.height);
        const message_end = @min(visible.end, v.snapshot.messages.len);
        const message_start = @min(visible.start, message_end);
        for (v.snapshot.messages[message_start..message_end], rows[message_start..message_end]) |m, row| {
            const text = row.text;
            const h = row.measured.?;
            // Subtract in double precision before drawing. Accumulating tens
            // of thousands of f32 heights caused visible fractional-DPI drift.
            const y = r.y + @as(f32, @floatCast(row.top - s.scroll));
            const outgoing = m.direction == .outgoing;
            const participant = if (!outgoing and participants.len > 1) theme.participant(m.sender, participants) else null;
            const x = if (outgoing) r.x + r.width - width - 24 else r.x + 24;
            if (y + h + 54 >= r.y and y < r.y + r.height) {
                const bubble = rl.Rectangle{ .x = x, .y = y, .width = width, .height = h + 20 };
                rl.drawRectangleRounded(bubble, 0.14, 10, if (outgoing) theme.colors.accent else if (participant) |style| style.bubble else theme.colors.incoming);
                s.drawMessageText(row, m.text orelse text, bubble, if (outgoing) theme.colors.on_accent else theme.colors.ink);
                const stamp = if (outgoing)
                    std.fmt.allocPrint(ar, "{s}  ·  {s}", .{ localTime(ar, m.timestamp, false), @tagName(m.observed_status) }) catch ""
                else
                    std.fmt.allocPrint(ar, "{s}  ·  {s}", .{ m.sender, localTime(ar, m.timestamp, false) }) catch "";
                beginClip(.{ .x = x + 4, .y = y + h + 24, .width = inner, .height = 24 });
                s.text.draw(display.label(ar, stamp), x + 4, y + h + 26, 11, inner, if (participant) |style| style.label else theme.colors.muted);
                endClip();
            }
        }
        const pending_start = @max(visible.start, v.snapshot.messages.len);
        const pending_end = @max(visible.end, v.snapshot.messages.len);
        for (v.snapshot.pending[pending_start - v.snapshot.messages.len .. pending_end - v.snapshot.messages.len], rows[pending_start..pending_end]) |p, row| {
            const h = row.measured.?;
            const y = r.y + @as(f32, @floatCast(row.top - s.scroll));
            const x = r.x + r.width - width - 24;
            if (y + h + 130 >= r.y and y < r.y + r.height) {
                const bubble = rl.Rectangle{ .x = x, .y = y, .width = width, .height = h + 20 };
                rl.drawRectangleRounded(bubble, 0.14, 10, theme.colors.selected);
                s.drawMessageText(row, p.input.text, bubble, theme.colors.ink);
                const label = if (u.eq(p.state, "unknown") or u.eq(p.state, "unconfirmed")) "Uncertain · not automatically resent" else if (u.eq(p.state, "failed")) "Failed" else if (u.eq(p.state, "sending")) "Saving / submitting…" else p.state;
                beginClip(.{ .x = x + 4, .y = y + h + 24, .width = inner - 118, .height = 26 });
                s.text.draw(label, x + 4, y + h + 25, 12, inner - 118, if (p.detail.len > 0) theme.colors.danger else theme.colors.muted);
                endClip();
                if (s.button(.{ .x = x + width - 118, .y = y + h + 22, .width = 118, .height = 27 }, "Copy to draft", false)) {
                    if (s.composer.text.items.len > 0) s.info("Your composer has a draft. Save or clear it before copying another message.") else {
                        s.composer.set(p.input.text) catch {};
                        s.draft_dirty = true;
                        s.draft_at = 0;
                        s.focus = .composer;
                        s.duplicate_risk = u.eq(p.state, "unknown") or u.eq(p.state, "unconfirmed");
                    }
                }
                if (p.detail.len > 0) {
                    beginClip(.{ .x = x + 4, .y = y + h + 52, .width = inner, .height = 48 });
                    s.text.draw(display.label(ar, p.detail), x + 4, y + h + 52, 12, inner, theme.colors.danger);
                    endClip();
                }
            }
        }
        if (visible.loading) s.text.draw("Loading messages…", r.x + 24, if (s.following) r.y + 12 else r.y + r.height - 28, 13, r.width - 48, theme.colors.muted);
        endClip();
        s.history_bar.draw(r, s.content_height + 16, s.scroll);
        if (!s.following and s.new_messages) if (s.button(.{ .x = r.x + r.width / 2 - 74, .y = r.y + r.height - 42, .width = 148, .height = 32 }, "New messages ↓", true)) {
            s.following = true;
            s.new_messages = false;
            s.worker.push(.{ .kind = .viewed, .text = "yes" }) catch {};
        };
    }
    fn drawMessageText(s: *App, row: HistoryRow, full: []const u8, bubble: rl.Rectangle, color: rl.Color) void {
        const x = bubble.x + 12;
        const y = bubble.y + 10;
        const width = bubble.width - 24;
        const hot = hover(bubble);
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
        s.text.drawSelection(row.text, x, y, 16, width, color, if (active) @min(selection.anchor, selection.caret) else 0, if (active) @max(selection.anchor, selection.caret) else 0);
    }
    fn drawComposer(s: *App, r: rl.Rectangle) void {
        rl.drawRectangleRec(r, theme.colors.paper);
        if (s.key.len == 0 or s.new_mode) return;
        const box = rl.Rectangle{ .x = r.x + 20, .y = r.y + 8, .width = r.width - 40, .height = 92 };
        s.inputBox(&s.composer, box, if (s.view != null and s.view.?.online) "Write a message…" else "Write a draft while offline…", .composer, true);
        s.text.draw(if (s.duplicate_risk) "Earlier send may have succeeded. Sending again may duplicate it." else if (s.enter_to_send) "Enter to send  ·  Shift+Enter for a new line" else "Ctrl+Enter to send  ·  Enter for a new line", r.x + 24, r.y + 116, 11, r.width - 180, theme.colors.muted);
        if (s.button(.{ .x = r.x + r.width - 112, .y = r.y + 108, .width = 88, .height = 30 }, if (s.send_wait) "Saving…" else "Send ↑", s.canSend())) s.send() catch s.info("Could not queue message. Your draft is retained.");
    }
    fn inputBox(s: *App, e: *Editor, r: rl.Rectangle, placeholder: []const u8, focus: @FieldType(App, "focus"), multiline: bool) void {
        rl.drawRectangleRounded(r, 0.12, 8, if (multiline) theme.colors.sidebar else theme.colors.paper);
        rl.drawRectangleRoundedLinesEx(r, 0.12, 8, 1, if (s.focus == focus) theme.colors.focus else theme.colors.line);
        const viewport = rl.Rectangle{ .x = r.x + 11, .y = r.y + (if (multiline) @as(f32, 10) else 6), .width = r.width - 22, .height = r.height - (if (multiline) @as(f32, 20) else 10) };
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
        if (e.text.items.len == 0) s.text.draw(placeholder, inner.x, inner.y, 16, width, theme.colors.muted) else s.text.drawSelection(e.text.items, inner.x, inner.y - offset, 16, width, theme.colors.ink, @min(e.caret, e.anchor), @max(e.caret, e.anchor));
        if (s.focus == focus and @mod(u.now(), 1000) < 600) rl.drawRectangleRec(.{ .x = inner.x + caret.x, .y = inner.y + caret.y - offset, .width = 1.5, .height = caret.height }, theme.colors.accent);
        endClip();
        if (multiline) s.composer_bar.draw(viewport, content_height, s.composer_scroll);
    }
    fn revealComposerCaret(s: *App, caret: rl.Rectangle, viewport: f32) void {
        if (caret.y < s.composer_scroll) s.composer_scroll = caret.y;
        if (caret.y + caret.height > s.composer_scroll + viewport) s.composer_scroll = caret.y + caret.height - viewport;
    }
    fn button(s: *App, r: rl.Rectangle, label: []const u8, primary: bool) bool {
        const hot = hover(r);
        rl.drawRectangleRounded(r, 0.22, 8, if (primary) (if (hot) theme.colors.accent_hover else theme.colors.accent) else if (hot) theme.colors.line else theme.colors.incoming);
        s.text.draw(label, r.x + 8, r.y + (r.height - 18) / 2, 13, r.width - 14, if (primary) theme.colors.on_accent else theme.colors.muted);
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

test "sidebar scroll preserves the fixed header and dark mode changes every surface" {
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
        .value = .{ .id = try std.fmt.allocPrint(arena.allocator(), "fixture-{d}", .{i}), .service = "imessage", .title = try std.fmt.allocPrint(arena.allocator(), "Conversation {d} long wrapped label", .{i}), .last_activity = "2026-01-01T00:00:00Z" },
        .preview = "This preview must stay below the search box.",
        .unread = 1,
    };
    const view = try a.create(Worker.View);
    view.* = .{ .arena = std.heap.ArenaAllocator.init(a), .snapshot = .{ .chats = &chats, .messages = &.{}, .pending = &.{}, .selected = "fixture-0", .draft = "", .epoch = "", .more = false }, .status = "Offline", .online = false, .send_direct = false, .reply_existing = false, .generation = 1, .ack = 0 };
    var app = App{ .worker = &worker, .view = view, .key = try a.dupe(u8, "fixture-0"), .focus = .none, .theme_loaded = true };
    defer app.deinit();
    theme.setDark(false);
    defer theme.setDark(false);
    for (0..4) |_| app.draw(WindowMetrics.current().scale);
    const before = try captureTestFrame(&app, WindowMetrics.current().scale);
    defer rl.unloadImage(before);
    const scale = WindowMetrics.current().scale;
    for ([_]f32{ 25, 53, 107, 345 }) |scroll| {
        app.sidebar_scroll = scroll;
        const after = try captureTestFrame(&app, scale);
        defer rl.unloadImage(after);
        const right: i32 = @intFromFloat(309 * scale);
        const bottom: i32 = @intFromFloat(154 * scale);
        var y: i32 = 0;
        while (y < bottom) : (y += 1) {
            var x: i32 = 0;
            while (x < right) : (x += 1) try std.testing.expectEqual(rl.getImageColor(before, x, y), rl.getImageColor(after, x, y));
        }
        try std.testing.expectEqual(@as(usize, 0), clip_depth);
    }
    app.toggleTheme();
    try std.testing.expectEqualStrings("dark", worker.commands.items[worker.commands.items.len - 1].text);
    const dark = try captureTestFrame(&app, scale);
    defer rl.unloadImage(dark);
    try std.testing.expectEqual(theme.dark.sidebar, rl.getImageColor(dark, @intFromFloat(5 * scale), @intFromFloat(5 * scale)));
    try std.testing.expectEqual(theme.dark.paper, rl.getImageColor(dark, @intFromFloat(320 * scale), @intFromFloat(5 * scale)));
    app.toggleDetails();
    app.draw(scale);
    try std.testing.expect(app.details_height > 0);
    app.details_scroll = 100000;
    app.draw(scale);
    try std.testing.expect(app.details_scroll < 100000);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);
    app.toggleDetails();
    app.toggleTheme();
    app.draw(scale);
    try std.testing.expect(!theme.is_dark and !app.show_details);
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
    for ([_]bool{ false, true }) |dark_mode| {
        theme.setDark(dark_mode);
        const shot = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer rl.unloadImage(shot);
        try std.testing.expectEqual(@as(f32, 0), app.composer_scroll);
        const areas = layout.frame(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()));
        try expectScrollbarPixel(shot, .{ .x = 8, .y = 158, .width = areas.sidebar.width - 16, .height = areas.sidebar.height - 210 }, chats.len * 78, app.sidebar_scroll);
        try expectScrollbarPixel(shot, areas.history, app.content_height + 16, app.scroll);
        const composer_viewport = rl.Rectangle{ .x = areas.composer.x + 31, .y = areas.composer.y + 18, .width = areas.composer.width - 62, .height = 72 };
        try expectScrollbarPixel(shot, composer_viewport, app.text.height(app.composer.text.items, 16, composer_viewport.width - Scrollbar.gutter), app.composer_scroll);
        const visible = app.visibleHistory(app.history_rows, areas.history.height);
        var checked: usize = 0;
        for (app.history_rows[visible.start..visible.end], group_messages[visible.start..visible.end]) |row, m| {
            const y = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + (row.measured.? + 20) / 2;
            if (y < areas.history.y or y >= areas.history.y + areas.history.height) continue;
            const style = theme.participant(m.sender, chats[0].value.participants);
            const pixel = rl.getImageColor(shot, @intFromFloat((areas.history.x + 30) * WindowMetrics.current().scale), @intFromFloat(y * WindowMetrics.current().scale));
            try std.testing.expectEqual(style.bubble, pixel);
            checked += 1;
        }
        try std.testing.expect(checked >= 2);
        app.toggleDetails();
        app.draw(WindowMetrics.current().scale);
        const details = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer rl.unloadImage(details);
        try expectScrollbarPixel(details, .{ .x = areas.header.x + 24, .y = areas.header.y + 78, .width = areas.header.width - 32, .height = areas.status.y - areas.header.y - 86 }, app.details_height, app.details_scroll);
        app.toggleDetails();
    }
    app.composer.caret = 0;
    app.draw(WindowMetrics.current().scale);
    app.composer.caret = app.composer.text.items.len;
    app.draw(WindowMetrics.current().scale);
    try std.testing.expect(app.composer_scroll > 0);
    try app.composer.set("");
    theme.setDark(false);

    // Drive the actual mouse path: drag backwards within a message, release,
    // and verify the selected range stays highlighted and ready to copy.
    app.draw(scale);
    const selection_before = try captureTestFrame(&app, scale);
    defer rl.unloadImage(selection_before);
    const areas = layout.frame(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()));
    const row = app.history_rows[app.history_rows.len - 1];
    const text_width = @min(500, areas.history.width * 0.76) - 24;
    const text_x = areas.history.x + 36;
    const text_y = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 10;
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
    var app = App{ .worker = &worker, .key = try a.dupe(u8, "c1"), .theme_loaded = true, .focus = .none };
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
        text.draw("Message text must retain its glyphs and proportions", 20, 20, 16, 500, rl.Color.black);
        // Recoloring and selection share metrics but replace the texture.
        text.drawSelection("Message text must retain its glyphs and proportions", 20, 60, 16, 500, rl.Color.red, 0, 7);
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
    text.draw("Visible text at every height\n" ** 40, 20, 0, 16, 300, rl.Color.black);
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
