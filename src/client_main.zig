const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const clay = @import("zclay");
const client_options = @import("client_options");
const u = @import("common.zig");
const t = @import("protocol.zig").types;
const Settings = @import("client.zig").Settings;
const Config = @import("client.zig").Config;
const Store = @import("client.zig").Store;
const Worker = @import("client.zig").Worker;
const Editor = @import("client.zig").Editor;
const MessageSelection = @import("client.zig").MessageSelection;
const MessageHistory = @import("client.zig").MessageHistory;
const Text = @import("client.zig").Text;
const display = @import("client.zig").display;
const message_content = @import("client.zig").content;
const link_targets = @import("client.zig").links;
const Media = @import("client.zig").Media;
const ImageCache = @import("client.zig").ImageCache;
const LogBuffer = @import("client.zig").LogBuffer;
const theme = @import("client.zig").theme;
const shapes = @import("client.zig").shapes;
const layout = @import("client.zig").layout;
const Scrollbar = @import("client.zig").Scrollbar;
const bridge = @import("client.zig").c.api;
const log = std.log.scoped(.client);
const a = std.heap.page_allocator;

var session_logs: LogBuffer = .{};
pub const std_options: std.Options = .{
    .logFn = clientLog,
    .log_scope_levels = &.{
        .{ .scope = .client_media, .level = .debug },
        .{ .scope = .client_images, .level = .debug },
    },
};

fn clientLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    session_logs.append(level, scope, format, args);
    std.log.defaultLog(level, scope, format, args);
}

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
        if (err == error.ClientAlreadyRunning) {
            std.debug.print("zimbr: another client is already using this data directory.\n", .{});
        } else {
            std.debug.print("zimbr: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}
fn clayError(data: clay.ErrorData) callconv(.c) void {
    _ = data;
    log.warn("UI layout limit reached", .{});
}
fn run(init: std.process.Init) !void {
    log.info("Starting Zimbr {s}", .{client_options.version});
    var config = try Config.parse(init);
    const cache_lock = try config.lockCache();
    defer _ = u.c.close(cache_lock);
    try config.load(init.arena.allocator());
    rl.setTraceLogLevel(.warning);
    rl.setConfigFlags(.{
        .window_resizable = true,
        .window_highdpi = true,
        .msaa_4x_hint = true,
    });
    rl.initWindow(1120, 780, "Zimbr");
    defer rl.closeWindow();
    bridge.zc_activation_init();
    defer bridge.zc_activation_free();
    // Let Wayland deliver its initial scale before caching any text textures.
    rl.pollInputEvents();
    rl.setWindowMinSize(780, 560);
    rl.setExitKey(.null);
    rl.setTargetFPS(120);
    _ = clay.initialize(
        .init(try init.arena.allocator().alloc(u8, clay.minMemorySize())),
        .{ .w = 1120, .h = 780 },
        .{ .error_handler_function = clayError },
    );
    while (true) config = try runSession(init, config) orelse break;
}

fn runSession(init: std.process.Init, config: Config) !?Config {
    var worker = Worker{
        .io = init.io,
        .config = config,
        .on_ready = bridge.zc_activation_wake,
    };
    var app = App{
        .worker = &worker,
        .enter_to_send = config.enter_to_send,
        .show_details = config.details,
        .settings = try Settings.init(config),
        .config_allocator = init.arena.allocator(),
    };
    defer app.deinit();
    worker.auth_blocked = app.settings.required;
    if (app.settings.required) worker.status = "Complete Settings to connect";
    try worker.start();
    defer worker.shutdown();
    var media = Media{
        .io = init.io,
        .config = config,
        .on_ready = bridge.zc_activation_wake,
    };
    const media_ready = if (media.start()) true else |err| failed: {
        log.err("Image cache unavailable: {s}", .{@errorName(err)});
        break :failed false;
    };
    defer if (media_ready) media.shutdown();
    if (app.settings.visible) app.focus = .settings_relay;
    if (media_ready) app.media = &media;
    app.notifications = bridge.zc_notifications_new(App.notificationAction, &app);
    defer bridge.zc_notifications_free(app.notifications);
    var frames: usize = 0;
    var last_draw: i64 = 0;
    var active_until: f64 = 0;
    var last_generation: u64 = 0;
    var last_revision: u64 = 0;
    var last_mouse = rl.getMousePosition();
    var last_window = WindowMetrics{};
    var background_ready = false;
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
        if (frames < 4 or config.frames > 0 or background_ready or app.layout_pending or now < active_until or generation != last_generation or u.now() - last_draw >= 500) {
            app.capture_frame = config.screenshot != null and config.frames > 0 and frames + 1 >= config.frames;
            app.draw(window.scale);
            background_ready = false;
            last_draw = u.now();
            last_generation = generation;
            last_revision = revision;
            last_mouse = mouse;
            last_window = window;
            frames += 1;
        } else {
            background_ready = bridge.zc_activation_wait(25) != 0;
            rl.pollInputEvents();
        }
        if (app.next_config != null) break;
        if (config.frames > 0 and frames >= config.frames) {
            if (config.screenshot) |path| {
                const shot = app.captured orelse return error.ScreenshotFailed;
                if (!rl.exportImage(shot, path)) return error.ScreenshotFailed;
            }
            break;
        }
    }
    try app.saveDraft();
    return app.next_config;
}
const App = struct {
    worker: *Worker,
    settings: Settings = .{},
    next_config: ?Config = null,
    config_allocator: u.Allocator = a,
    notifications: ?*bridge.ZcNotifications = null,
    media: ?*Media = null,
    images: ImageCache = .{},
    viewer_message: []const u8 = "",
    viewer_attachment: usize = 0,
    detail_body: ?[:0]const u8 = null,
    open_link: *const fn (link_targets.Target) bool = link_targets.open,
    detail_reaction_message: []const u8 = "",
    detail_reaction_part: []const u8 = "",
    detail_reaction_label: []const u8 = "",
    content_detail_scroll: f32 = 0,
    rich_count: usize = 0,
    rich_consumed: bool = false,
    rich_focus: ?usize = null,
    enter_to_send: bool = true,
    view: ?*Worker.View = null,
    text: Text = .{},
    heights: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    height_context: u64 = 0,
    height_cursor: usize = 0,
    history_arena: std.heap.ArenaAllocator = .init(a),
    history_rows: []HistoryRow = &.{},
    history_generation: ?u64 = null,
    history_needs_position: bool = true,
    history_needs_measurement: bool = true,
    frame_arena: std.heap.ArenaAllocator = .init(a),
    hydration_at: i64 = 0,
    layout_pending: bool = false,
    height_budget: usize = 0,
    height_deadline: i64 = 0,
    composer: Editor = .{},
    recipient: Editor = .{},
    search: Editor = .{},
    focus: enum {
        composer,
        recipient,
        search,
        settings_relay,
        settings_ca,
        settings_cert,
        settings_key,
        none,
    } = .composer,
    key: []const u8 = "",
    // Own the requested key while the displayed key and view stay together.
    pending_key: ?[]const u8 = null,
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
    settings_bar: Scrollbar = .{},
    settings_scroll: f32 = 0,
    composer_bar: Scrollbar = .{},
    content_height: f64 = 0,
    history_anchor: []const u8 = "",
    anchor_offset: f64 = 0,
    anchor_pending: bool = false,
    anchor_block: []const u8 = "",
    anchor_block_offset: f64 = 0,
    anchor_block_kind: std.meta.Tag(@FieldType(message_content.Block, "value")) = .text,
    history_width: f32 = 0,
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
    logs: *LogBuffer = &session_logs,
    logs_bar: Scrollbar = .{},
    logs_scroll: f32 = 0,
    logs_limit: f32 = 0,
    logs_follow: bool = true,
    logs_focused: bool = false,
    logs_anchor: ?u64 = null,
    logs_anchor_offset: f32 = 0,
    capture_frame: bool = false,
    captured: ?rl.Image = null,
    fn deinit(s: *App) void {
        s.settings.deinit();
        s.closeContentDetail();
        a.free(s.viewer_message);
        s.images.deinit();
        if (s.captured) |shot| rl.unloadImage(shot);
        if (s.view) |v| v.destroy();
        s.text.deinit();
        s.heights.deinit(a);
        s.history_arena.deinit();
        s.frame_arena.deinit();
        s.composer.deinit();
        s.recipient.deinit();
        s.search.deinit();
        a.free(s.key);
        if (s.pending_key) |key| a.free(key);
        a.free(s.loaded_key);
        s.message_selection.clear();
        a.free(s.history_anchor);
        a.free(s.anchor_block);
        s.* = undefined;
    }
    fn info(s: *App, msg: []const u8) void {
        s.notice = msg;
        s.notice_until = u.now() + 7000;
    }
    fn notificationAction(context: ?*anyopaque, chat: [*c]const u8, token: [*c]const u8) callconv(.c) void {
        const s: *App = @ptrCast(@alignCast(context.?));
        if (s.settings.required) return;
        s.settings.close();
        s.select(std.mem.span(chat)) catch {
            s.info("Could not open the conversation. Please try again.");
            return;
        };
        s.show_hidden = s.chatHidden(std.mem.span(chat)) orelse false;
        s.search.set("") catch {};
        s.layout_pending = true;
        rl.restoreWindow();
        if (bridge.zc_activation_activate(rl.getWindowHandle(), token) == 0) rl.setWindowFocused();
    }
    fn readingConversation(s: *const App) bool {
        return s.pending_key == null and rl.isWindowFocused() and !rl.isWindowMinimized() and s.following and !s.show_details and !s.settings.visible and !s.new_mode;
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
            try s.worker.push(.{
                .kind = .draft,
                .key = s.key,
                .text = s.composer.text.items,
            });
            s.draft_dirty = false;
        }
    }
    fn select(s: *App, key: []const u8) !void {
        if (s.settings.required) return;
        s.settings.close();
        s.closeViewer();
        s.closeContentDetail();
        s.show_details = false;
        try s.saveDraft();
        const next_key = try a.dupe(u8, key);
        errdefer a.free(next_key);
        try s.worker.push(.{
            .kind = .select,
            .key = key,
            // Mark it viewed only after its snapshot reaches the screen.
            .text = "no",
        });
        if (s.pending_key) |previous| a.free(previous);
        s.pending_key = next_key;
        s.focus = .composer;
        s.new_mode = false;
        s.dragging = false;
    }
    fn completeSelection(s: *App, selected: []const u8) !void {
        const requested = s.pending_key.?;
        const next_key = if (u.eq(requested, selected)) requested else try a.dupe(u8, selected);
        if (!u.eq(requested, selected)) a.free(requested);
        s.pending_key = null;
        s.message_selection.clear();
        a.free(s.key);
        s.key = next_key;
        s.following = true;
        a.free(s.history_anchor);
        s.history_anchor = "";
        s.scroll = 0;
        s.history_bar = .{};
        s.composer_bar = .{};
        s.was_reading = null;
        s.new_messages = false;
        s.send_wait = false;
        s.duplicate_risk = false;
    }
    fn matchesSidebar(s: *const App, chat: Store.Chat) bool {
        return chat.hidden == s.show_hidden and (if (s.view) |v| v.snapshot.directory.matches(
            chat.value,
            s.search.text.items,
        ) else s.search.text.items.len == 0);
    }
    fn firstSidebarKey(s: *const App) []const u8 {
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (s.matchesSidebar(chat)) return chat.value.id;
        };
        return "";
    }
    fn selectedHidden(s: *const App) ?bool {
        return s.chatHidden(s.key);
    }
    fn chatHidden(s: *const App, key: []const u8) ?bool {
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (u.eq(chat.value.id, key)) return chat.hidden;
        };
        return null;
    }
    fn reconcileSelection(s: *App) !void {
        if (s.pending_key != null or s.new_mode or s.show_details or s.settings.visible) return;
        if (s.key.len > 0) {
            const hidden = s.selectedHidden() orelse return;
            if (hidden == s.show_hidden) return;
        }
        const next = s.firstSidebarKey();
        if (!u.eq(s.key, next)) try s.select(next);
    }
    fn toggleHidden(s: *App) !void {
        if (s.settings.required) return;
        s.settings.close();
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
    fn newUnread(old: Store.Snapshot, next: Store.Snapshot) bool {
        if (!u.eq(old.selected, next.selected)) return false;
        var before: i64 = 0;
        var after: i64 = 0;
        for (old.chats) |chat| if (u.eq(chat.value.id, old.selected)) {
            before = chat.unread;
            break;
        };
        for (next.chats) |chat| if (u.eq(chat.value.id, next.selected)) {
            after = chat.unread;
            break;
        };
        return after > before;
    }
    fn update(s: *App) !void {
        if (s.worker.take()) |v| incoming: {
            if (s.pending_key) |key| {
                // An older publication may still be in flight after a click,
                // including a response to a selection since superseded.
                if (v.cache_unavailable) {
                    a.free(key);
                    s.pending_key = null;
                } else if (!u.eq(key, v.snapshot.selected) and (key.len == 0 or !u.eq(key, v.redirect_from))) {
                    v.destroy();
                    break :incoming;
                } else s.completeSelection(v.snapshot.selected) catch |err| {
                    v.destroy();
                    return err;
                };
            }
            if (s.view == null or !u.eq(s.view.?.status, v.status)) log.info("{s}", .{v.status});
            // Metadata-only views retain the same immutable records, so their
            // history previews and measurements remain valid across updates.
            const same_history = if (s.view) |old| old.shared != null and v.shared != null and old.shared.?.history == v.shared.?.history and old.snapshot.pending.len == 0 and v.snapshot.pending.len == 0 and old.snapshot.directory.fingerprint() == v.snapshot.directory.fingerprint() else false;
            if (same_history and s.history_generation == s.view.?.content_generation) {
                s.history_generation = v.content_generation;
            } else if (s.view == null or v.content_generation == null or s.view.?.content_generation != v.content_generation) s.history_generation = null;
            if (s.view) |old| {
                if (!s.following and newUnread(old.snapshot, v.snapshot)) s.new_messages = true;
                old.destroy();
            }
            s.view = v;
            if (s.key.len == 0 and v.snapshot.selected.len > 0) s.key = try a.dupe(
                u8,
                v.snapshot.selected,
            );
            if (u.eq(s.key, v.redirect_from) and s.key.len > 0 and v.snapshot.selected.len > 0) {
                if (!std.mem.startsWith(u8, s.key, "new:") and s.draft_dirty) {
                    // Save the last edit under its old key before switching;
                    // the worker merges it with any other saved self draft.
                    try s.saveDraft();
                    try s.worker.push(.{ .kind = .select, .key = s.key });
                    return;
                }
                if (std.mem.startsWith(u8, s.key, "new:") and (s.draft_dirty or (s.composer.text.items.len > 0 and !s.send_wait))) {
                    try s.saveDraft();
                    try s.worker.push(.{ .kind = .select, .key = s.key });
                } else {
                    const next_key = try a.dupe(u8, v.snapshot.selected);
                    a.free(s.key);
                    s.key = next_key;
                    s.send_wait = false;
                    s.following = true;
                }
            }
            if (u.eq(s.key, v.snapshot.selected)) {
                if (!u.eq(s.loaded_key, s.key)) {
                    try s.composer.set(v.snapshot.draft);
                    const next_loaded_key = try a.dupe(u8, s.key);
                    a.free(s.loaded_key);
                    s.loaded_key = next_loaded_key;
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
        s.refreshReactionDetail();
        if (s.media) |media| if (s.view) |v| {
            const online = v.online and (if (v.diagnostics.server) |server| server.capabilities.image_assets_v1 else false);
            if (try media.context(
                v.snapshot.epoch,
                s.key,
                v.credential_generation,
                online,
                v.snapshot.directory.available,
            )) s.images.contextChanged(v.snapshot.directory.available);
        };
        if (s.draft_dirty and u.now() - s.draft_at > 300) try s.saveDraft();
        const reading = s.readingConversation();
        if (s.was_reading == null or reading != s.was_reading.?) {
            s.worker.push(.{ .kind = .viewed, .text = if (reading) "yes" else "no" }) catch return;
            s.was_reading = reading;
        }
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        if (ctrl and rl.isKeyPressed(.comma)) try s.openSettings();
        if (s.settings.visible) {
            if (rl.isKeyPressed(.escape)) {
                s.settings.close();
                if (!s.settings.visible) s.focus = .composer;
                return;
            }
            if (rl.isKeyPressed(.tab)) {
                const index = s.settingsFocus() orelse 0;
                s.focus = settings_focus[(index + (if (shift) @as(usize, 3) else 1)) % 4];
            }
        } else {
            if (s.viewer_message.len > 0) {
                if (rl.isKeyPressed(.escape)) s.closeViewer();
                if (rl.isKeyPressed(.left)) s.moveViewer(-1);
                if (rl.isKeyPressed(.right)) s.moveViewer(1);
                while (rl.getCharPressed() != 0) {}
                return;
            }
            if (s.detail_body) |body| {
                if (rl.isKeyPressed(.escape)) {
                    s.closeContentDetail();
                    return;
                }
                if (ctrl and rl.isKeyPressed(.c)) rl.setClipboardText(body);
                if (pressed(.page_down) or pressed(.down)) s.content_detail_scroll += 100;
                if (pressed(.page_up) or pressed(.up)) s.content_detail_scroll -= 100;
                while (rl.getCharPressed() != 0) {}
                return;
            }
            if (s.pending_key == null and rl.isKeyPressed(.tab) and s.rich_count > 0) {
                s.focus = .none;
                const old = s.rich_focus orelse (if (shift) 0 else s.rich_count - 1);
                s.rich_focus = if (shift) (old + s.rich_count - 1) % s.rich_count else (old + 1) % s.rich_count;
            }
            if (ctrl and rl.isKeyPressed(.f) and !s.show_details) {
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
                if (s.logs_focused) {
                    if (ctrl and pressed(.c)) s.copyLogs();
                    var offset = s.logs_scroll;
                    if (pressed(.page_down)) offset += 160;
                    if (pressed(.page_up)) offset -= 160;
                    if (pressed(.down)) offset += 24;
                    if (pressed(.up)) offset -= 24;
                    if (pressed(.home)) offset = 0;
                    if (pressed(.end)) offset = s.logs_limit;
                    if (offset != s.logs_scroll) {
                        s.logs_scroll = std.math.clamp(offset, 0, s.logs_limit);
                        s.logs_follow = s.logs_scroll >= s.logs_limit;
                        s.logs_anchor = null;
                    }
                    while (rl.getCharPressed() != 0) {}
                    return;
                }
                if (pressed(.page_down)) s.details_scroll += @as(
                    f32,
                    @floatFromInt(rl.getScreenHeight()),
                ) * 0.7;
                if (pressed(.page_up)) s.details_scroll -= @as(
                    f32,
                    @floatFromInt(rl.getScreenHeight()),
                ) * 0.7;
                if (pressed(.home)) s.details_scroll = 0;
                if (pressed(.end)) s.details_scroll = s.details_height;
                // Do not route keystrokes to hidden conversation inputs.
                while (rl.getCharPressed() != 0) {}
                return;
            }
            if (rl.isKeyPressed(.escape)) {
                s.message_selection.clear();
                s.new_mode = false;
                s.focus = .composer;
            }
        }
        if (s.focus == .composer and s.readOnlyChat()) {
            s.focus = .none;
            s.dragging = false;
        }
        const editor: ?*Editor = switch (s.focus) {
            .composer => if (s.pending_key != null or s.send_wait or !u.eq(s.key, s.loaded_key)) null else &s.composer,
            .recipient => &s.recipient,
            .search => &s.search,
            .settings_relay => &s.settings.fields[0],
            .settings_ca => &s.settings.fields[1],
            .settings_cert => &s.settings.fields[2],
            .settings_key => &s.settings.fields[3],
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
                    .settings_relay, .settings_ca, .settings_cert, .settings_key => {
                        if (ctrl) s.saveSettings() catch s.settingsSaveError() else {
                            const index = s.settingsFocus().?;
                            s.focus = settings_focus[(index + 1) % 4];
                        }
                    },
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
        if (s.settings.required) return;
        s.settings.close();
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
            if (u.eq(chat.value.id, s.key)) return !chat.value.sendable and Store.selfRecipient(chat.value) == null;
        };
        return false;
    }
    fn canSend(s: *App) bool {
        if (s.pending_key != null or s.settings.visible) return false;
        const v = s.view orelse return false;
        if (!v.online or s.send_wait or s.key.len == 0 or !u.eq(s.loaded_key, s.key) or std.mem.trim(
            u8,
            s.composer.text.items,
            " \r\n\t",
        ).len == 0) return false;
        if (std.mem.startsWith(u8, s.key, "new:")) return v.send_direct;
        for (v.snapshot.chats) |chat| if (u.eq(chat.value.id, s.key)) {
            if (Store.selfRecipient(chat.value) != null) return v.send_direct;
            return v.reply_existing and chat.value.sendable;
        };
        return false;
    }
    fn send(s: *App) !void {
        if (!s.canSend()) {
            s.info("Connect to a sendable iMessage conversation before sending.");
            return;
        }
        try s.saveDraft();
        try s.worker.push(.{
            .kind = .send,
            .key = s.key,
            .text = s.composer.text.items,
            .recipient = if (std.mem.startsWith(u8, s.key, "new:")) s.key[4..] else "",
        });
        s.send_wait = true;
        s.send_ack = s.view.?.ack;
        s.following = true;
    }
    fn draw(s: *App, scale: f32) void {
        defer _ = s.frame_arena.reset(.{ .retain_with_limit = 1024 * 1024 });
        const ar = s.frame_arena.allocator();
        s.text.nextFrame(scale);
        if (s.media) |media| s.images.nextFrame(media);
        s.rich_count = 0;
        s.rich_consumed = false;
        input_obscured = s.detail_body != null or s.viewer_message.len > 0;
        s.layout_pending = false;
        const areas = layout.frame(
            @floatFromInt(rl.getScreenWidth()),
            @floatFromInt(rl.getScreenHeight()),
            s.composerHeight(),
        );
        std.debug.assert(clip_depth == 0);
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(theme.colors.paper);
        rl.setMouseCursor(.default);
        s.drawRail(areas.rail);
        const pane = rl.Rectangle{
            .x = areas.sidebar.x,
            .y = 0,
            .width = @as(f32, @floatFromInt(rl.getScreenWidth())) - areas.sidebar.x,
            .height = @floatFromInt(rl.getScreenHeight()),
        };
        if (s.settings.visible) {
            s.drawSettings(pane);
        } else if (s.show_details) {
            s.drawDetails(pane, ar);
            s.drawNotice(pane, ar);
        } else {
            s.drawSidebar(areas.sidebar, ar);
            const obscured = input_obscured;
            input_obscured = obscured or s.pending_key != null;
            defer input_obscured = obscured;
            s.drawHeader(areas.header, ar);
            beginClip(areas.history);
            if (s.new_mode) {
                const r = areas.history;
                s.text.draw(
                    "Start a conversation",
                    r.x + 32,
                    r.y + 34,
                    25,
                    r.width - 64,
                    theme.colors.ink,
                    theme.colors.paper,
                );
                s.text.draw(
                    "Send an iMessage to a phone number or email address.",
                    r.x + 32,
                    r.y + 72,
                    15,
                    r.width - 64,
                    theme.colors.muted,
                    theme.colors.paper,
                );
                const field = rl.Rectangle{
                    .x = r.x + 32,
                    .y = r.y + 110,
                    .width = r.width - 64,
                    .height = 46,
                };
                s.inputBox(
                    &s.recipient,
                    field,
                    "+1 415 555 0123 or name@example.com",
                    .recipient,
                    false,
                );
                if (s.button(.{
                    .x = r.x + 32,
                    .y = r.y + 176,
                    .width = 164,
                    .height = 36,
                }, "Continue", true)) s.startDirect() catch s.info("Could not open conversation.");
                s.text.draw(
                    "Existing groups appear in your conversations.\nCreating groups is not supported yet.",
                    r.x + 32,
                    r.y + 236,
                    14,
                    r.width - 64,
                    theme.colors.muted,
                    theme.colors.paper,
                );
            } else if (s.key.len > 0) s.drawHistory(areas.history, ar) else {
                const r = areas.history;
                s.text.draw(
                    if (s.show_hidden) "No hidden conversations." else "Your conversations, here.",
                    r.x + 36,
                    r.y + r.height / 2 - 56,
                    27,
                    r.width - 72,
                    theme.colors.ink,
                    theme.colors.paper,
                );
                s.text.draw(
                    if (s.show_hidden) "Conversations you hide appear here.\nYou can restore them at any time." else if (s.view != null and s.view.?.snapshot.chats.len > 0) "Open Hidden to restore a conversation,\nor start a new message." else "Connect to your Mac to get started.\nYour cached messages stay available offline.",
                    r.x + 36,
                    r.y + r.height / 2 - 4,
                    16,
                    r.width - 72,
                    theme.colors.muted,
                    theme.colors.paper,
                );
            }
            endClip();
            s.drawComposer(areas.composer, ar);
            const footer = areas.sidebar_footer;
            rl.drawRectangleRec(footer, theme.colors.sidebar);
            rl.drawLine(
                @intFromFloat(footer.x),
                @intFromFloat(footer.y),
                @intFromFloat(footer.x + footer.width),
                @intFromFloat(footer.y),
                theme.colors.line,
            );
            const online = s.view != null and s.view.?.online;
            const status = if (online) "Connected to your Mac" else "Offline · drafts saved locally";
            const status_x = footer.x + sidebar_padding + sidebar_text_inset;
            const status_width = footer.x + footer.width - sidebar_padding - status_x;
            const status_size = s.text.lineSize(status, 11, status_width);
            const status_y = @round((footer.y + (footer.height - status_size.y) / 2) * scale) / scale;
            // Align with the visible glyphs, excluding the font's line and texture padding.
            const dot_y = status_y + s.text.lineInkCenterY(status, 11, status_width);
            drawStatusDot(
                .{ .x = footer.x + sidebar_padding + sidebar_icon_inset + sidebar_icon_size / 2, .y = dot_y },
                scale,
                if (online) theme.colors.success else theme.colors.danger,
            );
            s.text.drawLine(
                status,
                status_x,
                status_y,
                11,
                status_width,
                theme.colors.muted,
                theme.colors.sidebar,
            );
        }
        if (comptime client_options.fps_counter) {
            if (!s.settings.visible) {
                const fps_width: f32 = 72;
                var buffer: [32]u8 = undefined;
                const fps = std.fmt.bufPrint(&buffer, "{d} FPS", .{rl.getFPS()}) catch unreachable;
                const band = layout.footer(areas.composer);
                s.drawFooterLabel(fps, .{
                    .x = band.x + band.width - fps_width,
                    .y = band.y,
                    .width = fps_width - 12,
                    .height = band.height,
                }, theme.colors.muted);
            }
        }
        input_obscured = false;
        s.drawContentDetail();
        s.drawViewer(ar);
        if (s.capture_frame) {
            // Read the completed frame before swapping; Wayland may discard the
            // back buffer afterwards, making post-swap screenshots unreliable.
            rl.gl.rlDrawRenderBatchActive();
            if (s.captured) |old| rl.unloadImage(old);
            s.captured = rl.loadImageFromScreen() catch null;
        }
        if (!rl.isMouseButtonDown(.left)) s.message_selection.dragging = false;
    }
    fn drawStatusDot(center: rl.Vector2, scale: f32, color: rl.Color) void {
        // Keep this six-pixel dot symmetric on the physical pixel grid, with
        // a one-pixel antialiased edge even at fractional display scales.
        const cx = @round(center.x * scale * 2) / 2;
        const cy = @round(center.y * scale * 2) / 2;
        const radius = 3 * scale;
        var y = @floor(cy - radius - 0.5);
        while (y < cy + radius + 0.5) : (y += 1) {
            var x = @floor(cx - radius - 0.5);
            while (x < cx + radius + 0.5) : (x += 1) {
                const dx = x + 0.5 - cx;
                const dy = y + 0.5 - cy;
                const coverage = std.math.clamp(radius + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
                if (coverage == 0) continue;
                var pixel = color;
                pixel.a = @intFromFloat(@round(@as(f32, @floatFromInt(color.a)) * coverage));
                rl.drawRectangleRec(.{
                    .x = x / scale,
                    .y = y / scale,
                    .width = 1 / scale,
                    .height = 1 / scale,
                }, pixel);
            }
        }
    }
    const settings_focus = [_]@FieldType(App, "focus"){
        .settings_relay,
        .settings_ca,
        .settings_cert,
        .settings_key,
    };
    fn settingsFocus(s: *const App) ?usize {
        for (settings_focus, 0..) |focus, index| if (s.focus == focus) return index;
        return null;
    }
    fn openSettings(s: *App) !void {
        if (s.settings.visible) return;
        var settings = try Settings.init(s.worker.config);
        settings.visible = true;
        s.settings.deinit();
        s.settings = settings;
        s.settings_scroll = 0;
        s.settings_bar = .{};
        s.closeViewer();
        s.closeContentDetail();
        s.show_details = false;
        s.message_selection.clear();
        s.focus = .settings_relay;
        s.dragging = false;
    }
    fn saveSettings(s: *App) !void {
        // Validate and commit before replacing either worker's credential snapshot.
        const candidate = try s.settings.toConfig(s.config_allocator, s.worker.config);
        if (!candidate.check(&s.settings.failure)) {
            s.settings_scroll = std.math.inf(f32);
            return;
        }
        const path = try std.fmt.allocPrintSentinel(a, "{s}/client.db", .{candidate.data}, 0);
        defer a.free(path);
        const store = try Store.open(path);
        defer store.close();
        try candidate.save(store);
        s.next_config = candidate;
    }
    fn settingsSaveError(s: *App) void {
        s.settings_scroll = std.math.inf(f32);
        s.settings.failure = std.mem.zeroes(bridge.ZcError);
        const message = "Could not save settings. Check the state directory is writable and try again.";
        @memcpy(s.settings.failure.message[0..message.len], message);
    }
    fn drawPaneHeader(s: *App, title: []const u8, subtitle: []const u8, r: rl.Rectangle) void {
        const x = r.x + 32;
        const width = @min(760, r.width - 64);
        s.text.drawLine(title, x, r.y + 22, 25, width, theme.colors.ink, theme.colors.paper);
        s.text.drawLine(subtitle, x, r.y + 58, 15, width, theme.colors.muted, theme.colors.paper);
    }
    fn drawSettings(s: *App, r: rl.Rectangle) void {
        const x = r.x + 32;
        const width = @min(760, r.width - 64);
        s.drawPaneHeader(
            "Settings",
            if (s.settings.required) "Set up your relay and certificates to continue." else "Connection and message preferences",
            r,
        );
        const helper = "Use absolute paths to your enrolled device credentials. Files must be owned 0600, in private 0700 directories.";
        const paths_y = 144 + s.text.height(helper, 14, width) + 20;
        const failure = std.mem.sliceTo(&s.settings.failure.message, 0);
        const failure_y = paths_y + 3 * 66 + 8;
        const content_height = failure_y + (if (failure.len > 0)
            s.text.height(failure, 14, width) + 12
        else
            @as(f32, 0));
        const viewport = rl.Rectangle{
            .x = x,
            .y = r.y + 98,
            .width = r.width - 48,
            .height = @max(0, r.height - 170),
        };
        if (hover(viewport)) s.settings_scroll -= rl.getMouseWheelMove() * 42 * Scrollbar.wheel_scale;
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        if (rl.isKeyPressed(.tab) or (!ctrl and (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)))) {
            if (s.settingsFocus()) |index| {
                const top = if (index == 0) 0 else paths_y + @as(f32, @floatFromInt(index - 1)) * 66;
                if (top < s.settings_scroll) s.settings_scroll = top;
                if (top + 55 > s.settings_scroll + viewport.height) {
                    s.settings_scroll = top + 55 - viewport.height;
                }
            }
        }
        s.settings_scroll = std.math.clamp(
            s.settings_scroll,
            0,
            @max(0, content_height - viewport.height),
        );
        if (s.settings_bar.update(viewport, content_height, s.settings_scroll, scrollbarInput())) |offset| {
            s.settings_scroll = @floatCast(offset);
        }
        var clip = viewport;
        // Field outlines extend beyond their nominal bounds.
        clip.x -= 2;
        clip.width += 2 - Scrollbar.gutter;
        beginClip(clip);
        const top = viewport.y - s.settings_scroll;
        const labels = [_][]const u8{
            "Relay URL",
            "CA certificate",
            "Client certificate",
            "Client private key",
        };
        const placeholders = [_][]const u8{
            "https://relay.example:8731",
            "/absolute/path/to/ca.pem",
            "/absolute/path/to/client.pem",
            "/absolute/path/to/client-key.pem",
        };
        for (labels, placeholders, 0..) |label, placeholder, index| {
            const y = top + if (index == 0) 0 else paths_y + @as(f32, @floatFromInt(index - 1)) * 66;
            s.text.drawLine(label, x, y, 13, width, theme.colors.muted, theme.colors.paper);
            s.inputBox(&s.settings.fields[index], .{
                .x = x,
                .y = y + 21,
                .width = width,
                .height = 34,
            }, placeholder, settings_focus[index], false);
        }
        s.text.drawLine(
            "Ctrl+Enter always sends",
            x,
            top + 74,
            13,
            width,
            theme.colors.muted,
            theme.colors.paper,
        );
        const toggle_label = if (s.settings.enter_to_send) "Enter to send: On" else "Enter to send: Off";
        const toggle_size = s.buttonSize(toggle_label);
        if (s.button(.{
            .x = x,
            .y = top + 96,
            .width = toggle_size.x,
            .height = toggle_size.y,
        }, toggle_label, false)) s.settings.enter_to_send = !s.settings.enter_to_send;
        s.text.draw(helper, x, top + 144, 14, width, theme.colors.muted, theme.colors.paper);
        if (failure.len > 0) s.text.draw(
            failure,
            x,
            top + failure_y,
            14,
            width,
            theme.colors.danger,
            theme.colors.paper,
        );
        endClip();
        s.settings_bar.draw(viewport, content_height, s.settings_scroll);

        const save_size = s.buttonSize("Save and connect");
        const save = rl.Rectangle{
            .x = r.x + r.width - 32 - save_size.x,
            .y = r.y + r.height - 50,
            .width = save_size.x,
            .height = 32,
        };
        if (!s.settings.required) {
            const cancel_size = s.buttonSize("Cancel");
            if (s.button(.{
                .x = save.x - 12 - cancel_size.x,
                .y = save.y,
                .width = cancel_size.x,
                .height = save.height,
            }, "Cancel", false)) {
                s.settings.close();
                s.focus = .composer;
            }
        }
        if (s.button(save, "Save and connect", true)) s.saveSettings() catch s.settingsSaveError();
    }
    fn toggleDetails(s: *App) void {
        if (s.settings.required) return;
        s.settings.close();
        s.show_details = !s.show_details;
        s.message_selection.clear();
        s.focus = if (s.show_details) .none else .composer;
        s.dragging = false;
        s.history_bar = .{};
        s.details_bar = .{};
        s.composer_bar = .{};
        s.worker.push(.{ .kind = .viewed, .text = if (!s.show_details and s.following and rl.isWindowFocused()) "yes" else "no" }) catch {};
    }
    const rail_label_style = Text.Style{ .size = 10, .weight = .semibold };
    const RailIcon = enum {
        messages,
        hidden,
        settings,
        details,
    };
    fn railItem(s: *App, r: rl.Rectangle, label: []const u8, icon: RailIcon, selected: bool) bool {
        const hot = hover(r);
        const bg = if (selected) theme.colors.selected else if (hot) theme.colors.avatar else theme.colors.rail;
        const tile = rl.Rectangle{
            .x = r.x + 12,
            .y = r.y + 3,
            .width = 40,
            .height = 36,
        };
        if (selected or hot) shapes.drawRectangle(tile, 0.3, bg);
        const color = if (selected) theme.colors.focus else if (hot) theme.colors.ink else theme.colors.muted;
        const x = tile.x + 10;
        const y = tile.y + 9;
        switch (icon) {
            .messages => {
                shapes.drawRectangleLines(.{
                    .x = x,
                    .y = y,
                    .width = 20,
                    .height = 15,
                }, 0.3, 1.5, color);
                rl.drawLineEx(
                    .{ .x = x + 4, .y = y + 15 },
                    .{ .x = x + 4, .y = y + 19 },
                    1.5,
                    color,
                );
                rl.drawLineEx(
                    .{ .x = x + 4, .y = y + 19 },
                    .{ .x = x + 9, .y = y + 15 },
                    1.5,
                    color,
                );
                rl.drawLineEx(.{ .x = x + 5, .y = y + 6 }, .{ .x = x + 15, .y = y + 6 }, 1.5, color);
            },
            .hidden => {
                rl.drawRectangleLinesEx(.{
                    .x = x,
                    .y = y + 1,
                    .width = 20,
                    .height = 5,
                }, 1.5, color);
                rl.drawRectangleLinesEx(.{
                    .x = x + 2,
                    .y = y + 6,
                    .width = 16,
                    .height = 12,
                }, 1.5, color);
                rl.drawLineEx(
                    .{ .x = x + 7, .y = y + 10 },
                    .{ .x = x + 13, .y = y + 10 },
                    1.5,
                    color,
                );
            },
            .settings => {
                for (0..3) |i| {
                    const row = y + 3 + @as(f32, @floatFromInt(i)) * 7;
                    rl.drawLineEx(.{ .x = x, .y = row }, .{ .x = x + 20, .y = row }, 1.5, color);
                    shapes.drawCircle(.{ .x = x + (if (i == 1) @as(f32, 14) else 6), .y = row }, 3, color);
                }
            },
            .details => {
                shapes.drawCircleLines(.{ .x = x + 10, .y = y + 9 }, 10, 1, color);
                shapes.drawCircle(.{ .x = x + 10, .y = y + 4 }, 1, color);
                rl.drawLineEx(
                    .{ .x = x + 10, .y = y + 8 },
                    .{ .x = x + 10, .y = y + 14 },
                    1.5,
                    color,
                );
            },
        }
        const size = s.text.lineSizeStyled(label, rail_label_style, r.width);
        s.text.drawLineStyled(
            label,
            r.x + (r.width - size.x) / 2,
            r.y + 43,
            rail_label_style,
            r.width,
            color,
            theme.colors.rail,
        );
        if (hot) rl.setMouseCursor(.pointing_hand);
        return hot and rl.isMouseButtonPressed(.left);
    }
    fn drawRail(s: *App, r: rl.Rectangle) void {
        rl.drawRectangleRec(r, theme.colors.rail);
        if (s.railItem(.{
            .x = r.x,
            .y = r.y + 16,
            .width = r.width,
            .height = 62,
        }, "Messages", .messages, !s.show_hidden and !s.show_details and !s.settings.visible)) {
            if (s.settings.required) return;
            s.settings.close();
            if (s.show_hidden) s.toggleHidden() catch s.info("Could not switch conversations.");
            if (s.show_details) s.toggleDetails();
            s.new_mode = false;
            s.focus = .composer;
        }
        if (s.railItem(.{
            .x = r.x,
            .y = r.y + 86,
            .width = r.width,
            .height = 62,
        }, "Hidden", .hidden, s.show_hidden and !s.show_details and !s.settings.visible)) {
            if (s.settings.required) return;
            s.settings.close();
            if (!s.show_hidden) s.toggleHidden() catch s.info("Could not switch conversations.");
            if (s.show_details) s.toggleDetails();
            s.new_mode = false;
            s.focus = .composer;
        }
        if (s.railItem(.{
            .x = r.x,
            .y = r.y + r.height - 142,
            .width = r.width,
            .height = 62,
        }, "Settings", .settings, s.settings.visible)) {
            s.openSettings() catch s.info("Could not open Settings.");
        }
        const footer = layout.footer(r);
        const details_size = s.text.lineSizeStyled("Details", rail_label_style, r.width);
        if (s.railItem(.{
            .x = r.x,
            .y = footer.y + (footer.height - details_size.y) / 2 - 43,
            .width = r.width,
            .height = 62,
        }, "Details", .details, s.show_details and !s.settings.visible)) s.toggleDetails();
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
        return .{
            .x = r.x + sidebar_padding,
            .y = r.y + sidebar_header_height + sidebar_list_gap,
            .width = r.width - sidebar_padding - 4,
            .height = @max(
                0,
                r.height - sidebar_header_height - sidebar_list_gap - layout.list_bottom_padding,
            ),
        };
    }
    fn drawSidebar(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        rl.drawRectangleRec(r, theme.colors.sidebar);
        rl.drawLine(
            @intFromFloat(r.x + r.width - 1),
            @intFromFloat(r.y),
            @intFromFloat(r.x + r.width - 1),
            @intFromFloat(r.y + r.height),
            theme.colors.line,
        );
        const viewport = sidebarViewport(r);
        var clip = viewport;
        clip.width -= Scrollbar.gutter;
        var count: usize = 0;
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (s.matchesSidebar(chat)) count += 1;
        };
        const content_height = @as(f32, @floatFromInt(count)) * sidebar_row_height;
        if (hover(viewport)) s.sidebar_scroll -= rl.getMouseWheelMove() * 34 * Scrollbar.wheel_scale;
        s.sidebar_scroll = std.math.clamp(
            s.sidebar_scroll,
            0,
            @max(0, content_height - clip.height),
        );
        if (s.sidebar_bar.update(viewport, content_height, s.sidebar_scroll, scrollbarInput())) |offset| s.sidebar_scroll = @floatCast(offset);
        // Resolve clicks before painting rows so a frame has one selection,
        // even when a click replaces an earlier pending selection.
        if (hover(clip) and rl.isMouseButtonPressed(.left)) {
            const offset = rl.getMousePosition().y - clip.y + s.sidebar_scroll;
            if (@mod(offset, sidebar_row_height) < sidebar_row_height - 2) {
                var index: usize = @intFromFloat(@floor(offset / sidebar_row_height));
                if (s.view) |v| for (v.snapshot.chats) |chat| {
                    if (!s.matchesSidebar(chat)) continue;
                    if (index == 0) {
                        s.select(chat.value.id) catch s.info("Could not open conversation.");
                        break;
                    }
                    index -= 1;
                };
            }
        }
        const selected_key = s.pending_key orelse s.key;
        beginClip(clip);
        var y = clip.y - s.sidebar_scroll;
        if (s.view) |v| {
            // The snapshot is ordered by latest message activity, newest first.
            // Preserve that order across group and direct conversations.
            for (v.snapshot.chats) |chat| {
                if (!s.matchesSidebar(chat)) continue;
                const row = rl.Rectangle{
                    .x = clip.x,
                    .y = y,
                    .width = clip.width,
                    .height = sidebar_row_height - 2,
                };
                y += sidebar_row_height;
                if (row.y + row.height < clip.y or row.y > clip.y + clip.height) continue;
                const selected = u.eq(selected_key, chat.value.id) and !s.new_mode and !s.show_details;
                const hot = hover(row) and hover(clip);
                const read_only = !chat.value.sendable and Store.selfRecipient(chat.value) == null;
                const emphasized = selected or chat.unread > 0;
                const foreground = if (read_only)
                    (if (emphasized) theme.colors.muted else theme.colors.disabled)
                else if (emphasized) theme.colors.ink else theme.colors.muted;
                const bg = if (selected)
                    (if (read_only) theme.colors.line else theme.colors.selected)
                else if (hot)
                    (if (read_only) theme.colors.incoming else theme.colors.avatar)
                else
                    theme.colors.sidebar;
                if (selected or hot) shapes.drawRectangle(row, 0.2, bg);
                const name = display.label(ar, v.snapshot.directory.conversation(ar, chat.value));
                const avatar = rl.Rectangle{
                    .x = row.x + sidebar_icon_inset,
                    .y = row.y + 6,
                    .width = sidebar_icon_size,
                    .height = sidebar_icon_size,
                };
                if (!chat.value.is_self and chat.value.participants.len > 1) {
                    if (read_only) {
                        ImageCache.drawAvatar(null, avatar, theme.read_only_avatar.bubble);
                        s.text.drawLineCentered("#", avatar, 16, theme.read_only_avatar.label, null);
                    } else {
                        s.text.drawLine(
                            "#",
                            row.x + 11,
                            row.y + 5,
                            20,
                            20,
                            if (selected) theme.colors.ink else theme.colors.muted,
                            bg,
                        );
                    }
                } else if (read_only) {
                    s.drawAvatar(avatar, name, theme.read_only_avatar, 12);
                } else {
                    s.drawPeerAvatar(
                        avatar,
                        name,
                        theme.participant(chat.value.id, &.{}),
                        12,
                        chat.value.service,
                        if (chat.value.participants.len == 1) chat.value.participants[0] else "",
                    );
                }
                s.text.drawLine(
                    name,
                    row.x + sidebar_text_inset,
                    row.y + 8,
                    14,
                    row.width - (if (chat.unread > 0) @as(f32, 76) else 46),
                    foreground,
                    bg,
                );
                if (chat.unread > 0) {
                    const badge = rl.Rectangle{
                        .x = row.x + row.width - 30,
                        .y = row.y + 8,
                        .width = 24,
                        .height = 19,
                    };
                    const badge_color = if (read_only) theme.colors.muted else theme.colors.accent;
                    shapes.drawRectangle(badge, 0.5, badge_color);
                    const label = if (chat.unread > 99) "99+" else std.fmt.allocPrint(
                        ar,
                        "{d}",
                        .{chat.unread},
                    ) catch "";
                    const size = s.text.lineSize(label, 10, 24);
                    s.text.drawLine(
                        label,
                        badge.x + (24 - size.x) / 2,
                        badge.y + 2,
                        10,
                        24,
                        theme.colors.on_accent,
                        badge_color,
                    );
                }
                if (hot) rl.setMouseCursor(.pointing_hand);
            }
            if (count == 0) s.text.draw(
                if (s.show_hidden) "No hidden conversations" else if (v.online or v.snapshot.chats.len > 0) "No matching conversations" else "Waiting for your Mac…",
                clip.x + 10,
                clip.y + 18,
                14,
                clip.width - 20,
                theme.colors.muted,
                theme.colors.sidebar,
            );
        }
        endClip();
        s.sidebar_bar.draw(viewport, content_height, s.sidebar_scroll);
        const search = rl.Rectangle{
            .x = clip.x,
            .y = r.y + sidebar_padding,
            .width = clip.width,
            .height = sidebar_search_height,
        };
        s.inputBox(&s.search, search, "Search conversations", .search, false);
        const divider_y = r.y + sidebar_header_height;
        rl.drawLine(
            @intFromFloat(search.x),
            @intFromFloat(divider_y),
            @intFromFloat(search.x + search.width),
            @intFromFloat(divider_y),
            theme.colors.line,
        );
    }
    fn drawAvatar(s: *App, r: rl.Rectangle, name: []const u8, style: theme.Participant, size: i32) void {
        ImageCache.drawAvatar(null, r, style.bubble);
        const safe = display.prefix(name, 128, 1);
        var ascii = [_]u8{if (safe.len > 0 and std.ascii.isAlphabetic(safe[0])) std.ascii.toUpper(safe[0]) else '+'};
        const initial: []const u8 = if (safe.len > 0 and safe[0] >= 128) safe[0..bridge.zc_text_boundary(
            safe.ptr,
            safe.len,
            0,
            1,
        )] else &ascii;
        s.text.drawLineCentered(initial, r, size, style.label, null);
    }
    fn detailSection(s: *App, label: []const u8, r: rl.Rectangle, y: *f32) void {
        y.* += 18;
        s.text.draw(label, r.x, y.*, 17, r.width, theme.colors.ink, theme.colors.paper);
        y.* += 32;
    }
    const detail_label_width: f32 = 122;
    fn detailRow(s: *App, label: []const u8, value: []const u8, r: rl.Rectangle, y: *f32) void {
        const label_width = detail_label_width;
        const value_width = @max(80, r.width - label_width - 12);
        const height = @max(20, s.text.height(value, 14, value_width));
        s.text.draw(
            label,
            r.x,
            y.* + 1,
            12,
            label_width - 8,
            theme.colors.muted,
            theme.colors.paper,
        );
        s.text.draw(
            value,
            r.x + label_width,
            y.*,
            14,
            value_width,
            theme.colors.ink,
            theme.colors.paper,
        );
        y.* += height + 10;
    }
    fn reconnectButton(s: *App, bounds: rl.Rectangle, viewport: rl.Rectangle) bool {
        const hot = hover(bounds);
        const color = if (hot) theme.colors.ink else theme.colors.muted;
        if (hot) {
            rl.setMouseCursor(.pointing_hand);
            shapes.drawRectangle(bounds, 0.25, theme.colors.incoming);
            const size = s.buttonSize("Reconnect");
            const tooltip = rl.Rectangle{
                .x = @max(viewport.x, @min(bounds.x, viewport.x + viewport.width - size.x)),
                .y = @max(viewport.y, bounds.y - size.y - 6),
                .width = size.x,
                .height = size.y,
            };
            shapes.drawRectangle(tooltip, 0.2, theme.colors.incoming);
            s.text.drawLineCentered("Reconnect", tooltip, button_font_size, color, theme.colors.incoming);
        }
        // Rasterize the symbol through Pango for smooth edges at the display scale.
        s.text.drawLineCentered("↻", bounds, 22, color, null);
        return hot and rl.isMouseButtonPressed(.left);
    }
    fn detailStatus(s: *App, r: rl.Rectangle, y: *f32) bool {
        const status = if (s.view) |v| v.status else "Opening cache…";
        const value_width = @max(1, r.width - detail_label_width - 12 - 30);
        const text_width = s.text.lineSize(status, 14, value_width).x;
        const text_y = y.* + 2;
        s.text.draw("Status", r.x, y.* + 3, 12, detail_label_width - 8, theme.colors.muted, theme.colors.paper);
        s.text.draw(status, r.x + detail_label_width, text_y, 14, value_width, theme.colors.ink, theme.colors.paper);
        const clicked = s.reconnectButton(.{
            .x = r.x + detail_label_width + text_width + 6,
            .y = text_y + s.text.inkCenterY(status, 14, value_width) - 12,
            .width = 24,
            .height = 24,
        }, r);
        y.* += @max(24, s.text.height(status, 14, value_width) + 4) + 10;
        return clicked;
    }
    fn drawDetails(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        s.drawPaneHeader("Details", "Connection, synchronization and this client", r);
        const viewport = rl.Rectangle{
            .x = r.x + 32,
            .y = r.y + 98,
            .width = r.width - 48,
            .height = @max(0, r.height - 106),
        };
        var clip = viewport;
        clip.width -= Scrollbar.gutter;
        s.details_scroll = std.math.clamp(
            s.details_scroll,
            0,
            @max(0, s.details_height - clip.height),
        );
        if (s.details_bar.update(viewport, s.details_height, s.details_scroll, scrollbarInput())) |offset| s.details_scroll = @floatCast(offset);
        beginClip(clip);
        var y = clip.y - s.details_scroll;
        const logs_hovered = s.drawLogs(clip, &y, ar);
        s.detailSection("Connection", clip, &y);
        if (s.detailStatus(clip, &y)) {
            s.worker.push(.{ .kind = .reconnect }) catch {};
            s.send_wait = false;
        }
        s.detailRow("Endpoint", s.worker.config.relay_url, clip, &y);
        s.detailRow("Transport", "Direct HTTPS / SSE · TLS 1.3 · mutual certificates", clip, &y);
        if (s.view) |v| {
            const d = v.diagnostics;
            s.detailRow(
                "Authentication",
                if (d.auth_blocked) "Action required — see failure details, then Reconnect" else if (d.last_status_ms > 0 and v.online) "mTLS authenticated" else "Client certificate; waiting for connection",
                clip,
                &y,
            );
            s.detailRow(
                "Client SHA-256",
                if (d.transport.fingerprint.len > 0) d.transport.fingerprint else "Not loaded",
                clip,
                &y,
            );
            s.detailRow(
                "Certificate expiry",
                if (d.transport.expiring) std.fmt.allocPrint(ar, "{s} · renew now, then Reconnect", .{d.transport.expires}) catch "" else d.transport.expires,
                clip,
                &y,
            );
            s.detailRow("Failure", std.fmt.allocPrint(ar, "{s} · curl {d} · verification {d}\n{s}", .{
                d.transport.failure,
                d.transport.curl_code,
                d.transport.verify_result,
                d.transport.detail,
            }) catch "", clip, &y);
            s.detailRow(
                "Last response",
                if (d.last_response_ms == 0) "None this session" else if (d.last_http_status == 0) "Transport interrupted / no HTTP response" else std.fmt.allocPrint(ar, "HTTP {d} · {s}", .{ d.last_http_status, elapsed(ar, d.last_response_ms) }) catch "",
                clip,
                &y,
            );
            s.detailRow(
                "Retry",
                if (d.auth_blocked) "Waiting for Reconnect" else if (!v.online and d.retry_at > u.now()) std.fmt.allocPrint(ar, "In {d}s", .{@divTrunc(d.retry_at - u.now() + 999, 1000)}) catch "" else if (v.online) "Not needed" else "Connecting",
                clip,
                &y,
            );
            s.detailSection("Relay", clip, &y);
            s.detailRow("Last checked", elapsed(ar, d.last_status_ms), clip, &y);
            if (d.server) |server| {
                s.detailRow("API version", server.api_version, clip, &y);
                s.detailRow("Server epoch", server.server_epoch, clip, &y);
                s.detailRow(
                    "Messages adapter",
                    if (server.adapter_ready) "Ready at last check" else "Unavailable at last check",
                    clip,
                    &y,
                );
                const caps = server.capabilities;
                s.detailRow("Capabilities", std.fmt.allocPrint(ar, "History: {s} · Live messages: {s}\nDirect sends: {s} · Replies: {s}\nAttachments: {s} · Create groups: {s}", .{
                    yesNo(caps.read_history),
                    yesNo(caps.live_messages),
                    yesNo(caps.send_direct),
                    yesNo(caps.reply_existing),
                    yesNo(caps.attachments),
                    yesNo(caps.group_creation),
                }) catch "", clip, &y);
                s.detailRow(
                    "Degraded reasons",
                    if (server.degraded_reasons.len == 0) "None reported at last check" else std.mem.join(ar, "\n", server.degraded_reasons) catch "",
                    clip,
                    &y,
                );
            } else s.detailRow(
                "Server information",
                "Not yet available. Connect to the relay to load its status.",
                clip,
                &y,
            );
            if (d.server) |server| {
                s.detailSection("Message enrichment", clip, &y);
                inline for (.{
                    "identity_directory_v1",
                    "image_assets_v1",
                    "image_attachments_v1",
                    "stored_link_previews_v1",
                    "reactions_v1",
                    "contact_avatars_v1",
                }, .{
                    "Contact names",
                    "Image delivery",
                    "Attached images",
                    "Stored link cards",
                    "Reactions",
                    "Contact photos",
                }) |field, label| {
                    const state = @field(server.enrichment_readiness, field);
                    s.detailRow(
                        label,
                        if (!@field(server.capabilities, field)) "Not supported by this relay" else if (state.ready) "Ready" else if (state.reason.len > 0) state.reason else "Unavailable",
                        clip,
                        &y,
                    );
                }
                const contacts = server.enrichment_readiness.identity_directory_v1;
                s.detailRow(
                    "Contacts permission",
                    contacts.permission orelse "Not reported",
                    clip,
                    &y,
                );
                s.detailRow(
                    "Contacts freshness",
                    if (contacts.stale) "Cached matches are stale" else if (contacts.last_refresh_ms) |ms| elapsed(ar, ms) else "Not reported",
                    clip,
                    &y,
                );
            }
            s.detailSection("Participants", clip, &y);
            for (v.snapshot.chats) |chat| if (u.eq(chat.value.id, s.key)) {
                for (chat.value.participants) |address| s.detailRow(
                    v.snapshot.directory.name(chat.value.service, address),
                    address,
                    clip,
                    &y,
                );
            };
            s.detailSection("Synchronization", clip, &y);
            s.detailRow("Current operation", d.job, clip, &y);
            s.detailRow("Initial download", if (d.bootstrapped) "Complete" else "Pending", clip, &y);
            s.detailRow(
                "Event stream",
                if (v.online and d.stream_active) "Connected" else if (d.stream_active) "Opening" else "Disconnected",
                clip,
                &y,
            );
            s.detailRow(
                "Saved cursor",
                if (d.cursor.len > 0) d.cursor else "Not established",
                clip,
                &y,
            );
            s.detailRow("Last event", elapsed(ar, d.last_event_ms), clip, &y);
            s.detailRow("Local cache", std.fmt.allocPrint(ar, "{d} conversations · {d} messages\n{d} drafts · {d} unresolved sends", .{
                v.snapshot.chats.len,
                d.cached_messages,
                d.saved_drafts,
                d.pending_sends,
            }) catch "", clip, &y);
            s.detailRow(
                "Current history",
                std.fmt.allocPrint(ar, "{d} cached messages · {s}", .{ v.snapshot.messages.len, if (v.loading_history) "Loading" else if (v.snapshot.more) "Older history available" else "No older page" }) catch "",
                clip,
                &y,
            );
        }
        s.detailSection("Client", clip, &y);
        s.detailRow("Version", client_options.version, clip, &y);
        s.detailRow(
            "Platform",
            @tagName(builtin.os.tag) ++ " / " ++ @tagName(builtin.cpu.arch) ++ " · Wayland",
            clip,
            &y,
        );
        s.detailRow(
            "Rendering",
            "raylib / Clay · Pango / Cairo · RGB subpixel (grayscale fallback)",
            clip,
            &y,
        );
        s.detailRow("Display", std.fmt.allocPrint(ar, "{d} × {d} logical · {d} × {d} pixels · {d:.0}% scale", .{
            rl.getScreenWidth(),
            rl.getScreenHeight(),
            rl.getRenderWidth(),
            rl.getRenderHeight(),
            s.text.scale * 100,
        }) catch "", clip, &y);
        s.detailRow(
            "Database",
            std.fmt.allocPrint(ar, "{s}/client.db", .{s.worker.config.data}) catch "",
            clip,
            &y,
        );
        s.detailRow("CA file", s.worker.config.ca_file, clip, &y);
        s.detailRow("Client certificate", s.worker.config.client_cert_file, clip, &y);
        s.detailRow("Client key file", s.worker.config.client_key_file, clip, &y);
        s.detailRow(
            "Send shortcut",
            if (s.enter_to_send) "Enter (Shift+Enter for a new line)" else "Ctrl+Enter",
            clip,
            &y,
        );
        if (rl.isMouseButtonPressed(.left)) s.logs_focused = logs_hovered;
        s.details_height = y - clip.y + s.details_scroll + 12;
        endClip();
        if (hover(viewport) and !logs_hovered) {
            const wheel = rl.getMouseWheelMove();
            s.details_scroll -= wheel * 42 * Scrollbar.wheel_scale;
            s.layout_pending = s.layout_pending or wheel != 0;
        }
        const clamped = std.math.clamp(s.details_scroll, 0, @max(0, s.details_height - clip.height));
        s.layout_pending = s.layout_pending or clamped != s.details_scroll;
        s.details_scroll = clamped;
        s.details_bar.draw(viewport, s.details_height, s.details_scroll);
    }

    fn copyLogs(s: *App) void {
        const copied = s.logs.copy(a) catch return;
        defer a.free(copied);
        rl.setClipboardText(copied);
    }

    fn drawLogs(s: *App, r: rl.Rectangle, y: *f32, ar: u.Allocator) bool {
        s.detailSection("Logs", r, y);
        const box = rl.Rectangle{
            .x = r.x,
            .y = y.*,
            .width = r.width - 16,
            .height = @min(260, @max(120, r.height - 90)),
        };
        const header_y = y.* - 34;
        const button_gap = 4;
        const latest_size = s.buttonSize("Latest");
        const copy_size = s.buttonSize("Copy");
        const clear_size = s.buttonSize("Clear");
        const clear_x = box.x + box.width - clear_size.x;
        const copy_x = clear_x - button_gap - copy_size.x;
        if (s.button(.{
            .x = copy_x - button_gap - latest_size.x,
            .y = header_y,
            .width = latest_size.x,
            .height = 28,
        }, "Latest", false)) {
            s.logs_follow = true;
        }
        if (s.button(.{
            .x = copy_x,
            .y = header_y,
            .width = copy_size.x,
            .height = 28,
        }, "Copy", false)) s.copyLogs();
        if (s.button(.{
            .x = clear_x,
            .y = header_y,
            .width = clear_size.x,
            .height = 28,
        }, "Clear", false)) {
            s.logs.clear();
            s.logs_scroll = 0;
            s.logs_follow = true;
            s.logs_anchor = null;
        }
        y.* += box.height + 26;
        const hot = hover(box);
        // Logs remain available while Details is closed, but hidden rows need
        // no snapshots, text layouts, or textures.
        if (box.y >= r.y + r.height or box.y + box.height <= r.y) return false;
        const entries = s.logs.snapshot(ar) catch return hot;
        rl.drawRectangleRec(box, theme.colors.surface);
        rl.drawRectangleLinesEx(box, 1, if (s.logs_focused) theme.colors.focus else theme.colors.line);
        const viewport = rl.Rectangle{
            .x = box.x + 10,
            .y = box.y + 10,
            .width = box.width - 20,
            .height = box.height - 20,
        };
        var inner = viewport;
        inner.width -= Scrollbar.gutter;
        var heights: [LogBuffer.capacity]f32 = undefined;
        var total: f32 = 0;
        var anchor_offset: ?f32 = null;
        for (entries, 0..) |*entry, i| {
            if (s.logs_anchor == entry.serial) anchor_offset = total + s.logs_anchor_offset;
            heights[i] = s.text.height(entry.text(), 12, inner.width) + 6;
            total += heights[i];
        }
        s.logs_limit = @max(0, total - inner.height);
        if (s.logs_follow) {
            s.logs_scroll = s.logs_limit;
        } else if (s.logs_anchor != null) {
            s.logs_scroll = anchor_offset orelse 0;
        }
        if (hot and rl.getMouseWheelMove() != 0) {
            s.logs_scroll -= rl.getMouseWheelMove() * 42 * Scrollbar.wheel_scale;
            s.logs_follow = s.logs_scroll >= s.logs_limit;
        }
        var input = scrollbarInput();
        input.pressed = input.pressed and hot;
        if (s.logs_bar.update(viewport, total, s.logs_scroll, input)) |offset| {
            s.logs_scroll = @floatCast(offset);
            s.logs_follow = s.logs_scroll >= s.logs_limit;
        }
        s.logs_scroll = std.math.clamp(s.logs_scroll, 0, s.logs_limit);
        s.logs_anchor = null;
        beginClip(inner);
        var top: f32 = 0;
        for (entries, 0..) |*entry, i| {
            const bottom = top + heights[i];
            if (top <= s.logs_scroll and bottom > s.logs_scroll) {
                s.logs_anchor = entry.serial;
                s.logs_anchor_offset = s.logs_scroll - top;
            }
            if (bottom > s.logs_scroll and top < s.logs_scroll + inner.height) s.text.draw(
                entry.text(),
                inner.x,
                inner.y + top - s.logs_scroll,
                12,
                inner.width,
                theme.colors.ink,
                theme.colors.surface,
            );
            top = bottom;
        }
        if (entries.len == 0) s.text.draw("No logs yet.", inner.x, inner.y, 12, inner.width, theme.colors.muted, theme.colors.surface);
        endClip();
        s.logs_bar.draw(viewport, total, s.logs_scroll);
        var zone: [80]u8 = undefined;
        const status = std.fmt.allocPrint(ar, "{s} · {s} · {s}", .{
            if (s.logs_follow) "Live" else "Scrolled back",
            LogBuffer.timeZone(&zone),
            if (s.logs_follow) "latest 200 entries" else "Latest resumes live updates",
        }) catch "Local time";
        s.text.drawLine(
            status,
            box.x,
            box.y + box.height + 5,
            12,
            box.width,
            theme.colors.muted,
            theme.colors.paper,
        );
        return hot;
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
                title = v.snapshot.directory.conversation(ar, chat.value);
                subtitle = if (!chat.value.is_self and chat.value.participants.len > 1) std.fmt.allocPrint(
                    ar,
                    "{d} participants  ·  {s}",
                    .{ chat.value.participants.len, if (chat.value.sendable) "iMessage" else "Read only" },
                ) catch "Group conversation" else if (chat.value.sendable) "iMessage" else "Read only · unsupported service";
                break;
            }
        };
        const hidden = if (s.new_mode) null else s.selectedHidden();
        var title_x = r.x + 24;
        if (!s.new_mode) if (s.view) |v| for (v.snapshot.chats) |chat| if (u.eq(
            chat.value.id,
            s.key,
        ) and chat.value.participants.len == 1) {
            s.drawPeerAvatar(.{
                .x = title_x,
                .y = r.y + 14,
                .width = 34,
                .height = 34,
            }, title, theme.participant(chat.value.participants[0], &.{}), 17, chat.value.service, chat.value.participants[0]);
            title_x += 46;
            break;
        };
        const text_width = r.width - (title_x - r.x) - (if (hidden != null) @as(f32, 116) else 24);
        beginClip(.{
            .x = title_x,
            .y = r.y + 8,
            .width = text_width,
            .height = 48,
        });
        s.text.draw(
            display.label(ar, title),
            title_x,
            r.y + 9,
            20,
            text_width,
            theme.colors.ink,
            theme.colors.paper,
        );
        s.text.draw(
            subtitle,
            title_x,
            r.y + 36,
            12,
            text_width,
            theme.colors.muted,
            theme.colors.paper,
        );
        endClip();
        if (hidden) |is_hidden| {
            const label = if (is_hidden) "Unhide" else "Hide";
            const size = s.buttonSize(label);
            if (s.button(.{
                .x = r.x + r.width - layout.action_right_padding - size.x,
                .y = r.y + 16,
                .width = size.x,
                .height = 30,
            }, label, false)) s.setSelectedHidden(!is_hidden) catch s.info("Could not save conversation visibility. Try again.");
        }
        rl.drawLine(
            @intFromFloat(r.x),
            @intFromFloat(r.y + r.height),
            @intFromFloat(r.x + r.width),
            @intFromFloat(r.y + r.height),
            theme.colors.line,
        );
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
        blocks: []const message_content.Block = &.{},

        fn height(row: HistoryRow) f32 {
            return (row.measured orelse 24) + row.padding;
        }

        fn before(snapshot: Store.Snapshot, left: HistoryRow, right: HistoryRow) bool {
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
        s.history_width = inner;
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
        if (s.history_generation == generation) return s.history_rows;
        _ = s.history_arena.reset(.retain_capacity);
        const ar = s.history_arena.allocator();
        const rows = try ar.alloc(HistoryRow, snapshot.messages.len + snapshot.pending.len);
        var count: usize = 0;
        for (snapshot.messages, 0..) |m, i| {
            if (display.resolvedReaction(m)) {
                const target = m.reaction_event.?.target_message_id.?;
                const represented = if (s.view.?.shared) |shared| shared.history.index.contains(target) else for (snapshot.messages) |other| {
                    if (u.eq(other.id, target)) break true;
                } else false;
                if (represented) continue;
            }
            const row = &rows[count];
            count += 1;
            const prepared = if (s.view.?.shared) |shared| shared.history.presentations[i] else prepared: {
                const text = messageText(ar, m);
                const blocks = try message_content.prepare(ar, m);
                break :prepared MessageHistory.Presentation{
                    .text = text,
                    .key = std.hash.Wyhash.hash(0, if (blocks.len == 0) text else try u.json(ar, m)),
                    .blocks = blocks,
                };
            };
            const text = prepared.text;
            const identity_key = if (m.direction == .incoming) snapshot.directory.presentationKey(
                m.service,
                m.sender,
            ) else 0;
            const key = if (identity_key == 0) prepared.key else std.hash.Wyhash.hash(
                prepared.key,
                std.mem.asBytes(&identity_key),
            );
            row.* = .{
                .id = m.id,
                .text = text,
                .key = key,
                .measured = s.heights.get(key),
                .padding = 22 + layout.message_spacing,
                .source_index = i,
                .blocks = prepared.blocks,
            };
        }
        for (snapshot.pending, rows[count..][0..snapshot.pending.len], 0..) |p, *row, i| {
            const text = display.message(ar, p.input.text);
            const key = std.hash.Wyhash.hash(0, text);
            row.* = .{
                .id = p.input.request_id,
                .text = text,
                .key = key,
                .measured = s.heights.get(key),
                .padding = 74,
                .pending = true,
                .source_index = i,
            };
        }
        const active_rows = rows[0 .. count + snapshot.pending.len];
        if (snapshot.pending.len > 0) std.mem.sort(
            HistoryRow,
            active_rows,
            snapshot,
            HistoryRow.before,
        );
        s.history_rows = active_rows;
        s.history_generation = generation;
        s.history_needs_position = true;
        s.history_needs_measurement = true;
        if (s.message_selection.id.len > 0) {
            var valid = false;
            for (active_rows) |row| {
                var matches = s.message_selection.matches(row.id, row.pending, row.text);
                for (row.blocks) |block| if (block.value == .text) {
                    matches = matches or s.message_selection.matches(
                        row.id,
                        row.pending,
                        block.value.text,
                    );
                };
                if (!matches) continue;
                const full = if (row.pending) snapshot.pending[row.source_index].input.text else snapshot.messages[row.source_index].text orelse row.text;
                valid = u.eq(full, s.message_selection.full);
                break;
            }
            if (!valid) s.message_selection.clear();
        }
        return active_rows;
    }
    fn historyLimit(s: *App, viewport: f32) f64 {
        // Keep short histories at the bottom too, so expanding older rows
        // cannot move the latest message from the top to the bottom later.
        return s.content_height - viewport;
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
        var unmeasured = false;
        for (rows) |*row| {
            row.top = total;
            if (!s.following and row.pending == s.anchor_pending and u.eq(row.id, s.history_anchor)) {
                s.scroll = total - s.anchor_offset;
                if (s.anchor_block.len > 0) {
                    var block_top: f64 = total + 22;
                    for (row.blocks) |block| {
                        if (u.eq(blockId(block), s.anchor_block) and std.meta.activeTag(block.value) == s.anchor_block_kind) {
                            s.scroll = block_top - s.anchor_block_offset;
                            break;
                        }
                        block_top += s.blockHeight(block, s.history_width, false) + 8;
                    }
                }
            }
            total += row.height();
            unmeasured = unmeasured or row.measured == null;
        }
        s.content_height = total;
        // An updated attachment temporarily has an estimated row height. Its
        // reading anchor can lie beyond that estimate until measurement finishes.
        if (s.following) {
            s.scroll = s.historyLimit(viewport);
        } else if (!unmeasured) {
            s.scroll = s.clampHistoryScroll(s.scroll, viewport);
        }
        s.history_needs_position = false;
        s.history_needs_measurement = unmeasured;
        s.layout_pending = unmeasured;
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
        row.measured = if (row.blocks.len == 0) (if (visible) s.text.height(row.text, 16, width) else s.text.measure(
            row.text,
            16,
            width,
        )) else measured: {
            var height: f32 = 0;
            for (row.blocks) |block| height += s.blockHeight(block, width, visible) + 8;
            break :measured @max(0, height - 8);
        };
        s.heights.put(a, row.key, row.measured.?) catch {};
        return row.height() - old;
    }
    fn measureHistory(s: *App, rows: []HistoryRow, inner: f32, viewport: f32) void {
        s.height_budget = max_height_work;
        s.height_deadline = u.c.zr_monotonic_ms() + 8;
        var anchor: usize = 0;
        var top: f64 = 54;
        while (anchor < rows.len and top + rows[anchor].height() <= s.scroll) : (anchor += 1) top += rows[anchor].height();
        // The visible block may be deeper than its row's temporary estimate.
        // Resolve the saved row first so it cannot be skipped by the frame budget.
        if (!s.following and s.history_anchor.len > 0) {
            for (rows, 0..) |row, i| {
                if (row.pending != s.anchor_pending or !u.eq(row.id, s.history_anchor)) continue;
                anchor = i;
                top = row.top;
                break;
            }
        }

        // Resolve what the user can see before spending time on offscreen rows.
        if (s.following) {
            var i = rows.len;
            var covered: f32 = 0;
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
        s.positionHistory(rows, viewport);
    }
    fn rememberHistoryAnchor(s: *App, rows: []const HistoryRow) void {
        // Positions are already sorted. Scrolling near the end of a large
        // archive must not walk every earlier message on every frame.
        const start = s.historyStart(rows);
        for (rows[start..]) |row| {
            const top = row.top;
            if (top + row.height() > s.scroll) {
                if (row.pending != s.anchor_pending or !u.eq(row.id, s.history_anchor)) {
                    const id = a.dupe(u8, row.id) catch return;
                    a.free(s.history_anchor);
                    s.history_anchor = id;
                    s.anchor_pending = row.pending;
                }
                s.anchor_offset = top - s.scroll;
                var block_top: f64 = top + 22;
                var block_id: []const u8 = "";
                if (s.scroll >= block_top) for (row.blocks) |block| {
                    const height = s.blockHeight(block, s.history_width, false) + 8;
                    if (block_top + height > s.scroll) {
                        block_id = blockId(block);
                        s.anchor_block_kind = std.meta.activeTag(block.value);
                        s.anchor_block_offset = block_top - s.scroll;
                        break;
                    }
                    block_top += height;
                };
                if (!u.eq(block_id, s.anchor_block)) {
                    const owned = a.dupe(u8, block_id) catch return;
                    a.free(s.anchor_block);
                    s.anchor_block = owned;
                }
                return;
            }
        }
    }
    fn blockId(block: message_content.Block) []const u8 {
        if (block.part_id) |id| return id;
        return switch (block.value) {
            .attachment => |item| item.id,
            .card => |card| card.id,
            .text => "fallback-text",
            .reactions => "message-reactions",
            .more => |section| @tagName(section),
        };
    }
    const HistoryRange = struct {
        start: usize,
        end: usize,
        loading: bool = false,
    };
    fn historyStart(s: *App, rows: []const HistoryRow) usize {
        var low: usize = 0;
        var high = rows.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (rows[middle].top + rows[middle].height() <= s.scroll) low = middle + 1 else high = middle;
        }
        return low;
    }
    fn visibleHistory(s: *App, rows: []const HistoryRow, viewport: f32) HistoryRange {
        const start = s.historyStart(rows);
        var low = start;
        var high = rows.len;
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
        const reposition = s.history_needs_position;
        if (reposition) {
            s.positionHistory(rows, r.height);
            // Restore resized content before input clamps against the scroll range.
            if (s.history_needs_measurement) s.measureHistory(rows, inner, r.height);
        } else if (!s.history_needs_measurement) {
            s.scroll = if (s.following) s.historyLimit(r.height) else s.clampHistoryScroll(
                s.scroll,
                r.height,
            );
        }
        var scrolled = false;
        if (hover(r)) {
            const wheel = rl.getMouseWheelMove();
            if (wheel != 0) {
                s.scrollHistory(wheel, r.height);
                scrolled = true;
            }
        }
        if (s.history_bar.update(r, s.content_height, s.scroll, scrollbarInput())) |offset| {
            s.scroll = offset;
            s.following = s.scroll >= s.historyLimit(r.height) - 1;
            scrolled = true;
        }
        if (!reposition and s.history_needs_measurement) {
            if (scrolled) s.rememberHistoryAnchor(rows);
            s.measureHistory(rows, inner, r.height);
        }
        // Deferred measurements may change the range during a drag. Keep the
        // thumb under the pointer, then save this position as the reading anchor.
        if (s.history_bar.dragging) {
            var held = scrollbarInput();
            held.pressed = false;
            if (s.history_bar.update(r, s.content_height, s.scroll, held)) |offset| {
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
        var is_group = false;
        for (v.snapshot.chats) |chat| if (u.eq(chat.value.id, s.key)) {
            participants = chat.value.participants;
            is_group = !chat.value.is_self and participants.len > 1;
            break;
        };
        if (s.scroll < 54 and v.snapshot.more and !std.mem.startsWith(u8, s.key, "new:")) {
            const y = r.y + 16 - @as(f32, @floatCast(s.scroll));
            if (s.button(.{
                .x = r.x + r.width / 2 - 86,
                .y = y,
                .width = 172,
                .height = 30,
            }, "Load older messages", false)) {
                s.worker.push(.{ .kind = .older }) catch {};
                s.following = false;
            }
        }
        if (v.snapshot.messages.len == 0 and v.snapshot.pending.len == 0) s.text.draw(
            if (v.loading_history) "Loading history…" else if (v.online) "The start of something good.\nWrite your first message below." else "No cached messages in this conversation.",
            r.x + 40,
            r.y + 90,
            17,
            r.width - 80,
            theme.colors.muted,
            theme.colors.paper,
        );
        const visible = s.visibleHistory(rows, r.height);
        if (v.online and u.now() >= s.hydration_at) {
            // Visibility, not history size, bounds lazy metadata requests.
            var ids: std.ArrayList([]const u8) = .empty;
            for (rows[visible.start..visible.end]) |row| {
                if (!row.pending and v.snapshot.messages[row.source_index].metadata_deferred and ids.items.len < 64) ids.append(
                    ar,
                    row.id,
                ) catch {};
            }
            if (u.json(ar, ids.items)) |raw| {
                s.worker.push(.{
                    .kind = .hydrate,
                    .key = s.key,
                    .text = raw,
                }) catch {};
            } else |_| {}
            s.hydration_at = u.now() + 250;
        }
        // Reevaluate on idle redraws too, even when the snapshot is unchanged.
        const status_now = u.now();
        var delivery_hover: ?rl.Rectangle = null;
        for (rows[visible.start..visible.end]) |row| {
            if (row.pending) continue;
            const m = v.snapshot.messages[row.source_index];
            const text = row.text;
            const h = row.measured.?;
            // Subtract in double precision before drawing. Accumulating tens
            // of thousands of f32 heights caused visible fractional-DPI drift.
            const y = r.y + @as(f32, @floatCast(row.top - s.scroll));
            const outgoing = m.direction == .outgoing;
            const style = if (outgoing) theme.Participant{ .bubble = theme.colors.selected, .label = theme.colors.focus } else theme.participant(
                m.sender,
                participants,
            );
            if (y + row.height() >= r.y and y < r.y + r.height) {
                const hover_padding = (row.padding - 22) / 2;
                const bounds = rl.Rectangle{
                    .x = r.x,
                    .y = y - hover_padding,
                    .width = clip.width,
                    .height = row.height(),
                };
                const bg = if (hover(bounds)) theme.colors.surface else theme.colors.paper;
                if (hover(bounds)) rl.drawRectangleRec(bounds, bg);
                s.drawPeerAvatar(.{
                    .x = r.x + 20,
                    .y = y,
                    .width = 34,
                    .height = 34,
                }, if (outgoing) "You" else v.snapshot.directory.name(m.service, m.sender), style, 17, m.service, if (outgoing) "" else m.sender);
                const x = r.x + 66;
                const name = display.label(
                    ar,
                    if (outgoing) "You" else v.snapshot.directory.name(m.service, m.sender),
                );
                if (s.drawMessageHeader(
                    name,
                    localTime(ar, m.timestamp, false),
                    display.messageStatus(m, is_group, status_now),
                    .{
                        .x = x,
                        .y = y,
                        .width = inner,
                    },
                    if (outgoing) theme.colors.ink else style.label,
                    bg,
                )) |check_bounds| delivery_hover = check_bounds;
                if (row.blocks.len == 0) {
                    s.drawMessageText(row, m.text orelse text, .{
                        .x = x,
                        .y = y + 22,
                        .width = inner,
                        .height = h,
                    }, theme.colors.ink, bg);
                } else s.drawBlocks(row, m, .{
                    .x = x,
                    .y = y + 22,
                    .width = inner,
                    .height = h,
                }, bg, ar);
            }
        }
        for (rows[visible.start..visible.end]) |row| {
            if (!row.pending) continue;
            const p = v.snapshot.pending[row.source_index];
            const h = row.measured.?;
            const y = r.y + @as(f32, @floatCast(row.top - s.scroll));
            const x = r.x + 66;
            if (y + row.height() >= r.y and y < r.y + r.height) {
                s.drawAvatar(.{
                    .x = r.x + 20,
                    .y = y,
                    .width = 34,
                    .height = 34,
                }, "You", .{ .bubble = theme.colors.incoming, .label = theme.colors.muted }, 17);
                const status = display.pendingStatus(ar, p.state, p.detail, p.sent_at, status_now);
                _ = s.drawMessageHeader(
                    "You",
                    localTime(ar, p.sent_at, false),
                    .{ .label = status },
                    .{
                        .x = x,
                        .y = y,
                        .width = inner,
                    },
                    theme.colors.muted,
                    theme.colors.paper,
                );
                s.drawMessageText(row, p.input.text, .{
                    .x = x,
                    .y = y + 22,
                    .width = inner,
                    .height = h,
                }, theme.colors.muted, theme.colors.paper);
                if (display.canCopyPending(p.state, p.sent_at, status_now) and s.button(.{
                    .x = x + inner - 118,
                    .y = y + h + 24,
                    .width = 118,
                    .height = 27,
                }, "Copy to draft", false)) {
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
        if (visible.loading) s.text.draw(
            "Loading messages…",
            r.x + 24,
            if (s.following) r.y + 12 else r.y + r.height - 28,
            13,
            r.width - 48,
            theme.colors.muted,
            null,
        );
        endClip();
        s.history_bar.draw(r, s.content_height, s.scroll);
        if (!s.following and s.new_messages) if (s.button(.{
            .x = r.x + r.width / 2 - 74,
            .y = r.y + r.height - 42,
            .width = 148,
            .height = 32,
        }, "New messages ↓", true)) {
            s.following = true;
            s.new_messages = false;
            s.worker.push(.{ .kind = .viewed, .text = "yes" }) catch {};
        };
        if (delivery_hover) |bounds| s.drawGroupDeliveryTooltip(bounds, clip);
    }
    fn drawPeerAvatar(
        s: *App,
        r: rl.Rectangle,
        name: []const u8,
        style: theme.Participant,
        size: i32,
        service: []const u8,
        address: []const u8,
    ) void {
        if (address.len > 0) if (s.view) |view| if (s.media) |media| {
            if (view.snapshot.directory.avatar(service, address)) |asset| if (s.images.get(
                media,
                asset,
            )) |entry| if (entry.availableTexture()) |texture| {
                ImageCache.drawAvatar(texture, r, rl.Color.white);
                return;
            };
        };
        s.drawAvatar(r, name, style, size);
    }
    fn drawAsset(s: *App, asset: t.AssetRef, r: rl.Rectangle, chat: []const u8) void {
        const media = s.media orelse {
            s.text.drawLine(
                "Image cache unavailable",
                r.x + 8,
                r.y + 8,
                12,
                @max(1, r.width - 16),
                theme.colors.muted,
                theme.colors.incoming,
            );
            return;
        };
        const entry = s.images.get(media, asset) orelse return;
        if (entry.availableTexture()) |texture| {
            ImageCache.draw(texture, r);
        } else {
            const label = std.mem.sliceTo(&entry.reason, 0);
            s.text.draw(
                display.prefix(if (label.len > 0) label else "Loading photo…", 256, 3),
                r.x + 8,
                r.y + 8,
                12,
                @max(1, r.width - 16),
                theme.colors.muted,
                theme.colors.incoming,
            );
            if (s.viewer_message.len == 0 and r.width >= 140 and r.height >= 70 and (entry.state == .failed or entry.state == .offline)) {
                const retry_rect = rl.Rectangle{
                    .x = r.x + 8,
                    .y = r.y + r.height - 30,
                    .width = 100,
                    .height = 26,
                };
                s.text.drawLine(
                    "Retry image",
                    retry_rect.x + 4,
                    retry_rect.y + 3,
                    12,
                    92,
                    theme.colors.focus,
                    theme.colors.incoming,
                );
                if (s.richControl(retry_rect)) ImageCache.retry(entry);
            }
            if (entry.refresh_owner) {
                entry.refresh_owner = false;
                if (u.eq(chat, s.key)) s.worker.push(.{
                    .kind = .select,
                    .key = chat,
                    .text = if (s.readingConversation()) "yes" else "no",
                }) catch {};
            }
        }
    }
    fn openViewer(s: *App, m: t.Message, attachment: []const u8) void {
        const id = a.dupe(u8, m.id) catch return;
        s.closeViewer();
        s.viewer_message = id;
        for (m.attachments, 0..) |item, i| if (u.eq(item.id, attachment)) {
            s.viewer_attachment = i;
            break;
        };
        s.focus = .none;
    }
    fn closeViewer(s: *App) void {
        a.free(s.viewer_message);
        s.viewer_message = "";
    }
    fn viewerMessage(s: *App) ?t.Message {
        if (s.view) |view| for (view.snapshot.messages) |m| if (u.eq(m.id, s.viewer_message)) return m;
        return null;
    }
    fn moveViewer(s: *App, direction: i32) void {
        const m = s.viewerMessage() orelse return;
        if (m.attachments.len == 0) return;
        var i = @min(s.viewer_attachment, m.attachments.len - 1);
        for (0..m.attachments.len) |_| {
            i = if (direction < 0) (i + m.attachments.len - 1) % m.attachments.len else (i + 1) % m.attachments.len;
            if (!m.attachments[i].preview_artwork and m.attachments[i].image != null) {
                s.viewer_attachment = i;
                return;
            }
        }
    }
    fn drawViewer(s: *App, ar: u.Allocator) void {
        if (s.viewer_message.len == 0) return;
        const m = s.viewerMessage() orelse {
            s.closeViewer();
            return;
        };
        if (s.viewer_attachment >= m.attachments.len) {
            s.closeViewer();
            return;
        }
        const item = m.attachments[s.viewer_attachment];
        const asset = item.viewer orelse item.image orelse {
            s.closeViewer();
            return;
        };
        const w: f32 = @floatFromInt(rl.getScreenWidth());
        const h: f32 = @floatFromInt(rl.getScreenHeight());
        rl.drawRectangleRec(.{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
        }, theme.colors.paper);
        s.text.drawLine(
            display.label(ar, item.name),
            24,
            20,
            16,
            w - 160,
            theme.colors.ink,
            theme.colors.paper,
        );
        if (s.button(.{
            .x = w - 100,
            .y = 12,
            .width = 80,
            .height = 32,
        }, "Close", false)) {
            s.closeViewer();
            return;
        }
        const image_r = rl.Rectangle{
            .x = 24,
            .y = 65,
            .width = w - 48,
            .height = h - 130,
        };
        s.drawAsset(asset, image_r, m.conversation_id);
        if (s.button(.{
            .x = 24,
            .y = h - 52,
            .width = 120,
            .height = 32,
        }, "← Previous", false)) s.moveViewer(-1);
        if (s.button(.{
            .x = w - 144,
            .y = h - 52,
            .width = 120,
            .height = 32,
        }, "Next →", false)) s.moveViewer(1);
        if (s.media) |media| if (s.images.get(media, asset)) |entry| if (entry.texture == null and (entry.state == .failed or entry.state == .offline)) {
            if (s.button(.{
                .x = w / 2 - 50,
                .y = h - 52,
                .width = 100,
                .height = 32,
            }, "Retry", false) or rl.isKeyPressed(.r)) ImageCache.retry(entry);
        };
        if (asset.still_preview) s.text.drawLine(
            "Still preview",
            w / 2 - 60,
            h - 78,
            12,
            120,
            theme.colors.muted,
            theme.colors.paper,
        );
    }
    fn imageSize(asset: ?t.AssetRef, width: f32) rl.Vector2 {
        const w: f32 = if (asset) |v| @floatFromInt(v.width orelse 320) else 320;
        const h: f32 = if (asset) |v| @floatFromInt(v.height orelse 200) else 200;
        const scale = @min(@min(@min(width, 480) / @max(1, w), 320 / @max(1, h)), 1);
        return .{ .x = @max(32, w * scale), .y = @max(32, h * scale) };
    }
    fn inlineAsset(item: t.Attachment, size: rl.Vector2, scale: f32) ?t.AssetRef {
        const inline_image = item.image orelse return null;
        const viewer = item.viewer orelse return inline_image;
        const w: f32 = @floatFromInt(inline_image.width orelse 1024);
        const h: f32 = @floatFromInt(inline_image.height orelse 1024);
        // Reuse the existing larger variant at high DPI; layout stays anchored
        // to the inline descriptor and there are still only two cached variants.
        if (viewer.availability != .retired and (size.x * scale > w or size.y * scale > h) and ((viewer.width orelse 2560) > (inline_image.width orelse 1024) or (viewer.height orelse 2560) > (inline_image.height orelse 1024))) return viewer;
        return inline_image;
    }
    fn blockHeight(s: *App, block: message_content.Block, width: f32, visible: bool) f32 {
        return switch (block.value) {
            .text => |value| height: {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const links = link_targets.inText(arena.allocator(), block.source_text orelse value) catch &.{};
                break :height (if (visible) s.text.height(value, 16, width) else s.text.measure(
                    value,
                    16,
                    width,
                )) + @as(
                    f32,
                    @floatFromInt(links.len),
                ) * 28;
            },
            .attachment => |item| if (item.image != null) imageSize(item.image, width).y + 28 else 48,
            .card => |card| 76 + (if (card.summary != null) @as(f32, 54) else 0) + (if (card.image) |asset| imageSize(
                asset,
                width - 24,
            ).y + 8 else 0),
            .reactions => |chips| height: {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                var x: f32 = 0;
                var rows: f32 = 1;
                for (chips) |chip| {
                    const label = std.fmt.allocPrint(
                        arena.allocator(),
                        "{s} {d}",
                        .{ chip.label, chip.actors.len },
                    ) catch chip.label;
                    const w = s.chipWidth(label, width);
                    if (x > 0 and x + w > width) {
                        x = 0;
                        rows += 1;
                    }
                    x += w + 6;
                }
                break :height rows * 32;
            },
            .more => 30,
        };
    }
    fn chipWidth(s: *App, label: []const u8, width: f32) f32 {
        return @min(width, s.text.lineSize(label, 15, @max(1, width - 16)).x + 16);
    }
    fn richControl(s: *App, r: rl.Rectangle) bool {
        const index = s.rich_count;
        s.rich_count += 1;
        const focused = s.focus == .none and s.rich_focus == index;
        if (focused) rl.drawRectangleLinesEx(r, 1, theme.colors.focus);
        if (input_obscured or s.detail_body != null or s.viewer_message.len > 0 or s.rich_consumed) return false;
        const hot = hover(r);
        if (hot) rl.setMouseCursor(.pointing_hand);
        const clicked = hot and rl.isMouseButtonPressed(.left);
        if (clicked or (focused and rl.isKeyPressed(.enter))) {
            s.focus = .none;
            s.rich_focus = if (clicked) null else index;
            s.rich_consumed = true;
            return true;
        }
        return false;
    }
    fn showContentDetail(s: *App, body: []const u8) void {
        const copy = a.dupeZ(u8, body) catch return;
        s.closeContentDetail();
        s.detail_body = copy;
        s.focus = .none;
    }
    fn closeContentDetail(s: *App) void {
        if (s.detail_body) |value| a.free(value);
        s.detail_body = null;
        a.free(s.detail_reaction_message);
        a.free(s.detail_reaction_part);
        a.free(s.detail_reaction_label);
        s.detail_reaction_message = "";
        s.detail_reaction_part = "";
        s.detail_reaction_label = "";
        s.content_detail_scroll = 0;
    }
    fn drawBlocks(
        s: *App,
        row: HistoryRow,
        m: t.Message,
        bounds: rl.Rectangle,
        bg: rl.Color,
        ar: u.Allocator,
    ) void {
        var y = bounds.y;
        for (row.blocks) |block| {
            const h = s.blockHeight(block, bounds.width, true);
            const r = rl.Rectangle{
                .x = bounds.x,
                .y = y,
                .width = bounds.width,
                .height = h,
            };
            y += h + 8;
            if (clip_depth > 0) {
                const viewport = clip_stack[clip_depth - 1];
                if (r.y + r.height < viewport.y - 200 or r.y > viewport.y + viewport.height + 200) continue;
            }
            switch (block.value) {
                .text => |value| {
                    var part_row = row;
                    part_row.text = value;
                    const text_h = s.text.height(value, 16, r.width);
                    s.drawMessageText(part_row, m.text orelse block.source_text orelse value, .{
                        .x = r.x,
                        .y = r.y,
                        .width = r.width,
                        .height = text_h,
                    }, theme.colors.ink, bg);
                    const links = link_targets.inText(ar, block.source_text orelse value) catch &.{};
                    for (links, 0..) |link, i| {
                        const link_r = rl.Rectangle{
                            .x = r.x,
                            .y = r.y + text_h + @as(f32, @floatFromInt(i)) * 28,
                            .width = r.width,
                            .height = 26,
                        };
                        s.text.drawLine(
                            link.url,
                            link_r.x,
                            link_r.y + 3,
                            13,
                            link_r.width,
                            theme.colors.focus,
                            bg,
                        );
                        if (s.richControl(link_r)) _ = s.open_link(link);
                    }
                },
                .attachment => |item| {
                    if (item.image) |asset| {
                        const size = imageSize(asset, r.width);
                        const image_r = rl.Rectangle{
                            .x = r.x,
                            .y = r.y,
                            .width = size.x,
                            .height = size.y,
                        };
                        shapes.drawRectangle(image_r, 0.06, theme.colors.incoming);
                        s.drawAsset(
                            inlineAsset(item, size, s.text.scale).?,
                            image_r,
                            m.conversation_id,
                        );
                        if (s.richControl(image_r)) s.openViewer(m, item.id);
                        s.text.drawLine(
                            if (asset.still_preview) "Still preview" else display.label(ar, item.name),
                            r.x,
                            r.y + size.y + 5,
                            12,
                            r.width,
                            theme.colors.muted,
                            bg,
                        );
                    } else {
                        s.text.drawLine(
                            display.label(ar, item.name),
                            r.x,
                            r.y,
                            14,
                            r.width,
                            theme.colors.ink,
                            bg,
                        );
                        s.text.drawLine(
                            std.fmt.allocPrint(ar, "{s} · {s} bytes · preview unavailable", .{ item.mime_type, item.bytes }) catch "Attachment",
                            r.x,
                            r.y + 24,
                            12,
                            r.width,
                            theme.colors.muted,
                            bg,
                        );
                    }
                },
                .card => |card| {
                    shapes.drawRectangle(r, 0.04, theme.colors.incoming);
                    const link = link_targets.target(ar, card) catch null;
                    var top = r.y + 10;
                    if (card.image) |asset| {
                        const size = imageSize(asset, r.width - 24);
                        const image_r = rl.Rectangle{
                            .x = r.x + 12,
                            .y = top,
                            .width = size.x,
                            .height = size.y,
                        };
                        rl.drawRectangleRec(image_r, theme.colors.avatar);
                        s.drawAsset(asset, image_r, m.conversation_id);
                        top += size.y + 8;
                    }
                    var title_x = r.x + 12;
                    if (card.icon) |icon| {
                        if (s.media) |media| if (s.images.get(media, icon)) |entry| if (entry.availableTexture()) |texture| ImageCache.draw(texture, .{
                            .x = title_x,
                            .y = top,
                            .width = 20,
                            .height = 20,
                        });
                        title_x += 26;
                    }
                    s.text.drawLine(
                        display.label(ar, card.title orelse "Shared link"),
                        title_x,
                        top,
                        16,
                        r.x + r.width - 12 - title_x,
                        theme.colors.ink,
                        theme.colors.incoming,
                    );
                    top += 25;
                    s.text.drawLine(
                        if (link) |target| target.hostname else "Link unavailable",
                        r.x + 12,
                        top,
                        12,
                        r.width - 24,
                        theme.colors.focus,
                        theme.colors.incoming,
                    );
                    top += 20;
                    if (card.summary) |summary| {
                        beginClip(.{
                            .x = r.x + 12,
                            .y = top,
                            .width = r.width - 24,
                            .height = 54,
                        });
                        s.text.draw(
                            display.prefix(summary, 2048, 3),
                            r.x + 12,
                            top,
                            13,
                            r.width - 24,
                            theme.colors.muted,
                            theme.colors.incoming,
                        );
                        endClip();
                    }
                    if (s.richControl(r)) {
                        if (link) |target| {
                            _ = s.open_link(target);
                        } else s.showContentDetail(
                            card.original_url orelse card.metadata_url orelse "Stored link metadata is unavailable",
                        );
                    }
                },
                .reactions => |chips| {
                    var x = r.x;
                    var top = r.y;
                    for (chips) |chip| {
                        const label = std.fmt.allocPrint(
                            ar,
                            "{s} {d}",
                            .{ chip.label, chip.actors.len },
                        ) catch chip.label;
                        const w = s.chipWidth(label, r.width);
                        if (x > r.x and x + w > r.x + r.width) {
                            x = r.x;
                            top += 32;
                        }
                        const chip_r = rl.Rectangle{
                            .x = x,
                            .y = top,
                            .width = w,
                            .height = 28,
                        };
                        shapes.drawRectangle(chip_r, 0.6, theme.colors.incoming);
                        s.text.drawLineCentered(label, .{
                            .x = x + 8,
                            .y = top,
                            .width = @max(1, w - 16),
                            .height = chip_r.height,
                        }, 15, theme.colors.ink, theme.colors.incoming);
                        if (s.richControl(chip_r)) {
                            s.showContentDetail(s.reactionDetail(ar, chip));
                            s.detail_reaction_message = a.dupe(u8, m.id) catch "";
                            s.detail_reaction_part = a.dupe(u8, block.part_id orelse "") catch "";
                            s.detail_reaction_label = a.dupe(u8, chip.label) catch "";
                        }
                        x += w + 6;
                    }
                },
                .more => |section| {
                    const label = std.fmt.allocPrint(ar, "Show more {s}", .{@tagName(section)}) catch "Show more";
                    s.text.drawLine(
                        label,
                        r.x + 8,
                        r.y + 5,
                        13,
                        r.width - 16,
                        theme.colors.focus,
                        bg,
                    );
                    if (s.richControl(r)) s.worker.push(.{
                        .kind = .enrichment,
                        .key = m.id,
                        .recipient = m.revision,
                        .text = @tagName(section),
                    }) catch {};
                },
            }
        }
    }
    fn reactionDetail(s: *App, ar: u.Allocator, chip: message_content.Chip) []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        for (chip.actors) |actor| {
            const name = s.view.?.snapshot.directory.actor(actor);
            names.append(
                ar,
                if (actor.is_self) "You (your reaction)" else std.fmt.allocPrint(ar, "{s} · {s}", .{ name, actor.address orelse "Unknown address" }) catch name,
            ) catch {};
        }
        const people = std.mem.join(ar, "\n", names.items) catch "";
        return std.fmt.allocPrint(ar, "{s}\n\n{s}{s}", .{
            chip.label,
            people,
            if (chip.unresolved) "\n\nShown on the whole message: the original message part could not be resolved." else "",
        }) catch people;
    }
    fn refreshReactionDetail(s: *App) void {
        if (s.detail_reaction_message.len == 0) return;
        const view = s.view orelse return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        var body: []const u8 = "This reaction is no longer present.";
        for (view.snapshot.messages, 0..) |m, i| if (u.eq(m.id, s.detail_reaction_message)) {
            const blocks = if (view.shared) |shared| shared.history.presentations[i].blocks else message_content.prepare(
                ar,
                m,
            ) catch &.{};
            for (blocks) |block| if (block.value == .reactions and u.eq(
                block.part_id orelse "",
                s.detail_reaction_part,
            )) {
                for (block.value.reactions) |chip| if (u.eq(chip.label, s.detail_reaction_label)) {
                    body = s.reactionDetail(ar, chip);
                    break;
                };
            };
            break;
        };
        if (!u.eq(body, s.detail_body orelse "")) {
            const owned = a.dupeZ(u8, body) catch return;
            if (s.detail_body) |old| a.free(old);
            s.detail_body = owned;
        }
    }
    fn drawContentDetail(s: *App) void {
        const body = s.detail_body orelse return;
        const width: f32 = @floatFromInt(rl.getScreenWidth());
        const height: f32 = @floatFromInt(rl.getScreenHeight());
        rl.drawRectangleRec(.{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        }, .{
            .r = 0,
            .g = 0,
            .b = 0,
            .a = 190,
        });
        const r = rl.Rectangle{
            .x = width * 0.1,
            .y = height * 0.1,
            .width = width * 0.8,
            .height = height * 0.8,
        };
        shapes.drawRectangle(r, 0.03, theme.colors.paper);
        if (s.button(.{
            .x = r.x + r.width - 90,
            .y = r.y + 10,
            .width = 80,
            .height = 30,
        }, "Close", false)) {
            s.closeContentDetail();
            return;
        }
        const viewport = rl.Rectangle{
            .x = r.x + 20,
            .y = r.y + 52,
            .width = r.width - 40,
            .height = r.height - 72,
        };
        const content_height = s.text.height(body, 16, viewport.width);
        if (hover(viewport)) s.content_detail_scroll -= rl.getMouseWheelMove() * 40;
        s.content_detail_scroll = std.math.clamp(
            s.content_detail_scroll,
            0,
            @max(0, content_height - viewport.height),
        );
        beginClip(viewport);
        s.text.draw(
            body,
            viewport.x,
            viewport.y - s.content_detail_scroll,
            16,
            viewport.width,
            theme.colors.ink,
            theme.colors.paper,
        );
        endClip();
    }
    // Return hovered checkmark bounds so the hint can be drawn after all rows.
    fn drawMessageHeader(
        s: *App,
        name: []const u8,
        stamp: []const u8,
        status: display.MessageStatus,
        r: struct { x: f32, y: f32, width: f32 },
        foreground: rl.Color,
        background: rl.Color,
    ) ?rl.Rectangle {
        const name_width = @min(r.width * 0.55, s.text.lineSize(name, 14, r.width * 0.55).x);
        // Use a common pixel origin and a fixed font reference. Centering each
        // string's ink moves dates when names or months contain descenders/emoji.
        const top_pixels = @round(r.y * s.text.scale);
        const cap_center = s.text.lineInkCenterY("H", 14, 28);
        const name_offset = cap_center - s.text.lineCapCenterY(name, 14, name_width);
        s.text.drawLine(
            name,
            r.x,
            (top_pixels + @round(name_offset * s.text.scale)) / s.text.scale,
            14,
            name_width,
            foreground,
            background,
        );
        const stamp_x = r.x + name_width + 6;
        const meta_width = @max(1, r.width - name_width - 6);
        const reserved: f32 = switch (status) {
            .none => 0,
            .checks => 28,
            .label => |label| @min(meta_width / 2, s.text.lineSize(label, 11, meta_width).x + 8),
        };
        const stamp_width = @max(1, meta_width - reserved);
        const size = s.text.lineSize(stamp, 11, stamp_width);
        const stamp_offset = cap_center - s.text.lineCapCenterY(stamp, 11, stamp_width);
        const stamp_y = (top_pixels + @round(stamp_offset * s.text.scale)) / s.text.scale;
        s.text.drawLine(stamp, stamp_x, stamp_y, 11, stamp_width, theme.colors.muted, background);
        // Every send state occupies the same slot immediately after the timestamp.
        const status_x = stamp_x + size.x + 8;
        switch (status) {
            .none => {},
            .checks => |checks| {
                const status_y = (top_pixels + @round((cap_center - 6) * s.text.scale)) / s.text.scale;
                drawDeliveryChecks(status_x, status_y, checks);
                const bounds = rl.Rectangle{
                    .x = status_x - 3,
                    .y = status_y - 3,
                    .width = 26,
                    .height = 18,
                };
                if (checks == .group_sent and hover(bounds)) return bounds;
            },
            .label => |label| {
                const width = @max(1, r.x + r.width - status_x);
                const offset = cap_center - s.text.lineCapCenterY(label, 11, width);
                s.text.drawLine(
                    label,
                    status_x,
                    (top_pixels + @round(offset * s.text.scale)) / s.text.scale,
                    11,
                    width,
                    theme.colors.muted,
                    background,
                );
            },
        }
        return null;
    }
    fn drawDeliveryChecks(x: f32, y: f32, checks: display.MessageStatus.Checks) void {
        // Neutral checks indicate transport status; the relay has no read receipts.
        const color = theme.colors.muted;
        rl.drawLineEx(.{ .x = x + 1, .y = y + 6 }, .{ .x = x + 5, .y = y + 10 }, 1.5, color);
        rl.drawLineEx(.{ .x = x + 5, .y = y + 10 }, .{ .x = x + 13, .y = y + 2 }, 1.5, color);
        switch (checks) {
            .sent => {},
            .group_sent => {
                const dots = [_]rl.Vector2{
                    .{ .x = 9, .y = 8 },
                    .{ .x = 11, .y = 10 },
                    .{ .x = 13, .y = 8 },
                    .{ .x = 15, .y = 6 },
                    .{ .x = 17, .y = 4 },
                    .{ .x = 19, .y = 2 },
                };
                for (dots) |dot| shapes.drawCircle(.{ .x = x + dot.x, .y = y + dot.y }, 0.85, color);
            },
            .delivered => {
                rl.drawLineEx(.{ .x = x + 9, .y = y + 8 }, .{ .x = x + 11, .y = y + 10 }, 1.5, color);
                rl.drawLineEx(.{ .x = x + 11, .y = y + 10 }, .{ .x = x + 19, .y = y + 2 }, 1.5, color);
            },
        }
    }
    fn drawGroupDeliveryTooltip(s: *App, anchor: rl.Rectangle, viewport: rl.Rectangle) void {
        const label = "Sent · group delivery receipts unavailable.";
        const size = s.text.lineSize(label, 12, @max(1, viewport.width - 32));
        const width = size.x + 20;
        const height = size.y + 12;
        const above = anchor.y - height - 6;
        const bounds = rl.Rectangle{
            .x = std.math.clamp(anchor.x, viewport.x + 6, viewport.x + viewport.width - width - 6),
            .y = std.math.clamp(
                if (above >= viewport.y + 6) above else anchor.y + anchor.height + 6,
                viewport.y + 6,
                @max(viewport.y + 6, viewport.y + viewport.height - height - 6),
            ),
            .width = width,
            .height = height,
        };
        shapes.drawRectangle(bounds, 0.2, theme.colors.incoming);
        shapes.drawRectangleLines(bounds, 0.2, 1, theme.colors.line);
        s.text.drawLineCentered(label, bounds, 12, theme.colors.ink, theme.colors.incoming);
    }
    fn historyTextWidth(r: rl.Rectangle) f32 {
        return @max(80, r.width - 90);
    }
    fn drawMessageText(
        s: *App,
        row: HistoryRow,
        full: []const u8,
        bounds: rl.Rectangle,
        color: rl.Color,
        background: rl.Color,
    ) void {
        const x = bounds.x;
        const y = bounds.y;
        const width = bounds.width;
        const hot = hover(bounds);
        const selection = &s.message_selection;
        if (hot) rl.setMouseCursor(.ibeam);
        if (hot and rl.isMouseButtonPressed(.left)) {
            const at = s.text.hit(
                row.text,
                width,
                rl.getMousePosition().x - x,
                rl.getMousePosition().y - y,
            );
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
            selection.caret = s.text.hit(
                row.text,
                width,
                rl.getMousePosition().x - x,
                rl.getMousePosition().y - y,
            );
            selection.whole = false;
        }
        s.text.drawSelection(
            row.text,
            x,
            y,
            16,
            width,
            color,
            if (active) @min(selection.anchor, selection.caret) else 0,
            if (active) @max(selection.anchor, selection.caret) else 0,
            background,
        );
    }
    fn composerHeight(s: *App) f32 {
        const one_line = s.text.height("Ag", 16, 400);
        var height = one_line;
        if (!s.readOnlyChat() and s.key.len > 0 and !s.new_mode) {
            const pane = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = layout.conversationWidth(@floatFromInt(rl.getScreenWidth())),
                .height = 0,
            };
            const editor = composerEditor(composerBox(pane));
            // Match the editor's wrapping width, including its scrollbar gutter.
            const width = editor.width - 22 - Scrollbar.gutter;
            const caret = s.text.caret(s.composer.text.items, width, s.composer.caret);
            const content_height = @max(
                s.text.height(s.composer.text.items, 16, width),
                caret.y + caret.height,
            );
            height = std.math.clamp(content_height, one_line, s.text.height("Ag\nAg\nAg", 16, 400));
        }
        // Round up so fractional layout arithmetic cannot scroll a fitting draft.
        return @ceil(height) + 22 + layout.composer_top_padding + layout.footer_height;
    }
    fn composerBox(r: rl.Rectangle) rl.Rectangle {
        return .{
            .x = r.x + layout.conversation_padding,
            // The outline extends one pixel below the box, onto the sidebar divider.
            .y = r.y + layout.composer_top_padding - 1,
            .width = r.width - 2 * layout.conversation_padding,
            .height = r.height - layout.composer_top_padding - layout.footer_height,
        };
    }
    fn composerEditor(box: rl.Rectangle) rl.Rectangle {
        // Keep the text clear of the Send button.
        return .{
            .x = box.x + 1,
            .y = box.y + 1,
            .width = box.width - 100,
            .height = box.height - 2,
        };
    }
    fn composerFooter(r: rl.Rectangle) rl.Rectangle {
        var footer = layout.footer(r);
        footer.x += 24;
        footer.width -= 48 + (if (comptime client_options.fps_counter) @as(f32, 72) else 0);
        return footer;
    }
    fn drawFooterLabel(s: *App, label: []const u8, r: rl.Rectangle, color: rl.Color) void {
        // Keep all footer hints, notices, and warnings aligned to the left edge.
        const size = s.text.lineSize(label, 11, r.width);
        s.text.drawLine(
            label,
            r.x,
            r.y + (r.height - size.y) / 2,
            11,
            r.width,
            color,
            theme.colors.paper,
        );
    }
    fn drawNotice(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        if (u.now() >= s.notice_until) return;
        const warning_visible = s.duplicate_risk and s.key.len > 0 and !s.new_mode and !s.show_details;
        var notice = composerFooter(r);
        if (warning_visible) notice.height /= 2;
        rl.drawRectangleRec(notice, theme.colors.paper);
        s.drawFooterLabel(display.label(ar, s.notice), notice, theme.colors.muted);
    }
    fn drawComposer(s: *App, r: rl.Rectangle, ar: u.Allocator) void {
        rl.drawRectangleRec(r, theme.colors.paper);
        // Draw footer feedback first so the input always appears above it.
        s.drawNotice(r, ar);
        if (s.key.len == 0 or s.new_mode) return;
        const box = composerBox(r);
        const read_only = s.readOnlyChat();
        if (!read_only) {
            var footer = composerFooter(r);
            if (s.duplicate_risk and u.now() < s.notice_until) {
                footer.height /= 2;
                footer.y += footer.height;
            }
            if (s.duplicate_risk) {
                s.drawFooterLabel(
                    "Earlier send may have succeeded. Sending again may duplicate it.",
                    footer,
                    theme.colors.danger,
                );
            } else if (u.now() >= s.notice_until) {
                const hint = if (s.enter_to_send) "Enter to send · Shift+Enter for a new line" else "Ctrl+Enter to send · Enter for a new line";
                s.drawFooterLabel(hint, footer, theme.colors.muted);
            }
        }
        const background = if (read_only) theme.colors.incoming else theme.colors.surface;
        shapes.drawRectangle(box, 0.12, background);
        const editor = composerEditor(box);
        if (read_only) {
            s.text.drawLine(
                if (s.composer.text.items.len > 0) s.composer.text.items else "This conversation is read-only",
                box.x + 12,
                box.y + 11,
                16,
                box.width - 24,
                theme.colors.disabled,
                background,
            );
        } else {
            s.inputBox(
                &s.composer,
                editor,
                if (s.view != null and s.view.?.online) "Message this conversation…" else "Write a draft while offline…",
                .composer,
                true,
            );
        }
        shapes.drawRectangleLines(
            box,
            0.12,
            1,
            if (!read_only and s.focus == .composer) theme.colors.focus else theme.colors.line,
        );
        if (read_only) return;
        const send_button = rl.Rectangle{
            .x = r.x + r.width - layout.action_right_padding - 76,
            .y = box.y + box.height - 36,
            .width = 76,
            .height = 28,
        };
        const enabled = s.canSend();
        const hot = hover(send_button);
        const bg = if (enabled)
            (if (hot) theme.colors.accent_hover else theme.colors.accent)
        else
            theme.colors.incoming;
        shapes.drawRectangle(send_button, 0.25, bg);
        const label = if (s.send_wait) "Saving…" else "Send ↑";
        const size = s.text.lineSize(label, 13, send_button.width);
        s.text.drawLine(
            label,
            send_button.x + (send_button.width - size.x) / 2,
            send_button.y + (send_button.height - size.y) / 2,
            13,
            send_button.width,
            if (enabled) theme.colors.on_accent else theme.colors.muted,
            bg,
        );
        if (hot and enabled) {
            rl.setMouseCursor(.pointing_hand);
            if (rl.isMouseButtonPressed(.left)) s.send() catch s.info("Could not queue message. Your draft is retained.");
        }
    }
    fn inputBox(
        s: *App,
        e: *Editor,
        r: rl.Rectangle,
        placeholder: []const u8,
        focus: @FieldType(App, "focus"),
        multiline: bool,
    ) void {
        const background = if (multiline) theme.colors.surface else if (focus == .search) theme.colors.sidebar else theme.colors.paper;
        if (!multiline) {
            shapes.drawRectangle(r, 0.2, background);
            shapes.drawRectangleLines(
                r,
                0.2,
                1,
                if (s.focus == focus) theme.colors.focus else theme.colors.line,
            );
        }
        var viewport = rl.Rectangle{
            .x = r.x + 11,
            .y = r.y + (if (multiline) @as(f32, 10) else 6),
            .width = r.width - 22,
            .height = r.height - (if (multiline) @as(f32, 20) else 10),
        };
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
        const content_height = if (multiline) @max(
            s.text.height(e.text.items, 16, width),
            caret.y + caret.height,
        ) else 0;
        if (multiline) {
            // Only typing, cursor movement, or a new layout should reveal the
            // caret. Manual scrolling must not snap back to it each frame.
            if (s.composer_revision != e.revision or s.composer_caret != e.caret or s.composer_width != width) s.revealComposerCaret(
                caret,
                inner.height,
            );
            if (hover(r)) s.composer_scroll -= rl.getMouseWheelMove() * 46 * Scrollbar.wheel_scale;
            s.composer_scroll = std.math.clamp(
                s.composer_scroll,
                0,
                @max(0, content_height - inner.height),
            );
            if (s.composer_bar.update(viewport, content_height, s.composer_scroll, scrollbarInput())) |offset| {
                s.composer_scroll = @floatCast(offset);
                s.dragging = false;
            }
        }
        const settings_field = for (settings_focus) |item| {
            if (focus == item) break true;
        } else false;
        var offset = if (multiline) s.composer_scroll else if (settings_field) @max(0, caret.y + caret.height - inner.height) else 0;
        const previous_caret = e.caret;
        if (hover(if (multiline) inner else r) and rl.isMouseButtonPressed(.left)) {
            s.message_selection.clear();
            s.focus = focus;
            const at = s.text.hit(
                e.text.items,
                width,
                @as(f32, @floatFromInt(rl.getMouseX())) - inner.x,
                @as(f32, @floatFromInt(rl.getMouseY())) - inner.y + offset,
            );
            e.caret = at;
            if (!rl.isKeyDown(.left_shift)) e.anchor = at;
            s.dragging = true;
        }
        if (s.dragging and s.focus == focus and rl.isMouseButtonDown(.left)) e.caret = s.text.hit(
            e.text.items,
            width,
            @as(f32, @floatFromInt(rl.getMouseX())) - inner.x,
            @as(f32, @floatFromInt(rl.getMouseY())) - inner.y + offset,
        );
        if (rl.isMouseButtonReleased(.left)) s.dragging = false;
        if (!input_obscured and s.focus == focus and (pressed(.up) or pressed(.down))) {
            const at = s.text.hit(
                e.text.items,
                width,
                caret.x,
                caret.y + (if (pressed(.up)) -1 else caret.height + 1),
            );
            e.caret = at;
            if (!rl.isKeyDown(.left_shift)) e.anchor = at;
        }
        if (e.caret != previous_caret) {
            caret = s.text.caret(e.text.items, width, e.caret);
            if (multiline) {
                s.revealComposerCaret(caret, inner.height);
                offset = s.composer_scroll;
            } else if (settings_field) offset = @max(0, caret.y + caret.height - inner.height);
        }
        if (multiline) {
            s.composer_revision = e.revision;
            s.composer_caret = e.caret;
            s.composer_width = width;
        }
        beginClip(inner);
        if (e.text.items.len == 0) s.text.draw(
            placeholder,
            inner.x,
            inner.y,
            16,
            width,
            theme.colors.muted,
            background,
        ) else s.text.drawSelection(
            e.text.items,
            inner.x,
            inner.y - offset,
            16,
            width,
            theme.colors.ink,
            @min(e.caret, e.anchor),
            @max(e.caret, e.anchor),
            background,
        );
        if (s.focus == focus and @mod(u.now(), 1000) < 600) rl.drawRectangleRec(.{
            .x = inner.x + caret.x,
            .y = inner.y + caret.y - offset,
            .width = 1.5,
            .height = caret.height,
        }, theme.colors.accent);
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
        const r = rl.Rectangle{
            .x = bounds.x + (bounds.width - size.x) / 2,
            .y = bounds.y + (bounds.height - size.y) / 2,
            .width = size.x,
            .height = size.y,
        };
        const hot = hover(r);
        if (hot) rl.setMouseCursor(.pointing_hand);
        const background = if (primary) (if (hot) theme.colors.accent_hover else theme.colors.accent) else if (hot) theme.colors.line else theme.colors.incoming;
        shapes.drawRectangle(r, 0.22, background);
        s.text.drawLine(
            label,
            r.x + button_padding.x,
            r.y + button_padding.y,
            button_font_size,
            button_label_width,
            if (primary) theme.colors.on_accent else theme.colors.muted,
            background,
        );
        return hot and rl.isMouseButtonPressed(.left);
    }
};
fn scrollbarInput() Scrollbar.Input {
    return .{
        .mouse = rl.getMousePosition(),
        .pressed = !input_obscured and rl.isMouseButtonPressed(.left),
        .down = !input_obscured and rl.isMouseButtonDown(.left),
    };
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
var input_obscured = false;
fn hover(r: rl.Rectangle) bool {
    if (input_obscured) return false;
    const point = rl.getMousePosition();
    return rl.checkCollisionPointRec(point, r) and (clip_depth == 0 or rl.checkCollisionPointRec(
        point,
        clip_stack[clip_depth - 1],
    ));
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
    rl.beginScissorMode(
        @intFromFloat(r.x),
        @intFromFloat(r.y),
        @intFromFloat(@max(0, r.width)),
        @intFromFloat(@max(0, r.height)),
    );
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

test "pending conversation selections accept redirects and surface cache failure" {
    const fixture = struct {
        fn publish(app: *App, snapshot: Store.Snapshot, redirect: []const u8, unavailable: bool) !void {
            const v = try a.create(Worker.View);
            v.* = .{
                .arena = .init(a),
                .snapshot = snapshot,
                .status = if (unavailable) "Cache unavailable" else "Online",
                .online = !unavailable,
                .send_direct = true,
                .reply_existing = true,
                .generation = if (app.view) |old| old.generation + 1 else 1,
                .ack = 0,
                .redirect_from = redirect,
                .cache_unavailable = unavailable,
            };
            app.worker.view = v;
            try app.update();
        }
    };
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    var snapshot = Store.Snapshot{
        .chats = &.{},
        .messages = &.{},
        .pending = &.{},
        .selected = "old",
        .draft = "Old draft",
        .epoch = "fixture",
        .more = false,
    };
    try fixture.publish(&app, snapshot, "", false);
    try app.composer.set("Edited old draft");
    app.draft_dirty = true;
    try app.select("new:recipient");
    snapshot.selected = "canonical";
    snapshot.draft = "Canonical draft";
    try fixture.publish(&app, snapshot, "new:recipient", false);
    try std.testing.expect(app.pending_key == null);
    try std.testing.expectEqualStrings("canonical", app.key);
    try std.testing.expectEqualStrings("Canonical draft", app.composer.text.items);
    // Redirects must not save the previous conversation's composer under the new key.
    for (worker.commands.items) |command| if (command.kind == .draft) {
        try std.testing.expectEqualStrings("old", command.key);
        try std.testing.expectEqualStrings("Edited old draft", command.text);
    };

    try app.select("other");
    try app.select("canonical");
    snapshot.selected = "other";
    snapshot.draft = "Other draft";
    try fixture.publish(&app, snapshot, "", false);
    try std.testing.expectEqualStrings("canonical", app.key);
    try std.testing.expectEqualStrings("Canonical draft", app.composer.text.items);
    snapshot.selected = "canonical";
    snapshot.draft = "Canonical draft";
    try fixture.publish(&app, snapshot, "", false);
    try std.testing.expect(app.pending_key == null);
    try std.testing.expectEqualStrings("canonical", app.loaded_key);

    // An empty selection is a request too, not permission to adopt a stale view.
    try app.select("");
    try fixture.publish(&app, snapshot, "", false);
    try std.testing.expectEqualStrings("", app.pending_key.?);
    try std.testing.expectEqualStrings("canonical", app.key);
    snapshot.selected = "";
    snapshot.draft = "";
    try fixture.publish(&app, snapshot, "", false);
    try std.testing.expect(app.pending_key == null);
    try std.testing.expectEqualStrings("", app.key);
    try std.testing.expectEqualStrings("", app.composer.text.items);

    try app.select("unavailable");
    try fixture.publish(&app, snapshot, "", true);
    try std.testing.expect(app.pending_key == null);
    try std.testing.expectEqualStrings("Cache unavailable", app.view.?.status);
    try std.testing.expect(!app.canSend());
}

test "hidden conversations stay out of search and selection until restored" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var chats = [_]Store.Chat{
        .{
            .value = .{
                .id = "spam",
                .title = "Spam",
                .service = "imessage",
            },
            .preview = "",
            .unread = 1,
            .hidden = true,
        },
        .{
            .value = .{
                .id = "friend",
                .title = "Friend",
                .service = "imessage",
            },
            .preview = "",
            .unread = 0,
        },
    };
    const view = try a.create(Worker.View);
    view.* = .{
        .arena = std.heap.ArenaAllocator.init(a),
        .snapshot = .{
            .chats = &chats,
            .messages = &.{},
            .pending = &.{},
            .selected = "spam",
            .draft = "",
            .epoch = "",
            .more = false,
        },
        .status = "Offline",
        .online = false,
        .send_direct = false,
        .reply_existing = false,
        .generation = 1,
        .ack = 0,
    };
    var app = App{
        .worker = &worker,
        .view = view,
        .key = try a.dupe(u8, "spam"),
    };
    defer app.deinit();
    // Restarting with a hidden chat selected must choose a visible chat.
    try app.reconcileSelection();
    // Navigation commits when the worker supplies the requested snapshot.
    try std.testing.expectEqualStrings("friend", app.pending_key.?);
    try app.completeSelection("friend");
    view.snapshot.selected = "friend";
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
    try std.testing.expectEqualStrings("", app.pending_key.?);
    try app.completeSelection("");
    view.snapshot.selected = "";
    try std.testing.expectEqualStrings("", app.key);
    try app.toggleHidden();
    try std.testing.expect(app.show_hidden and app.matchesSidebar(chats[0]));
    try std.testing.expectEqualStrings("spam", app.pending_key.?);
    try app.completeSelection("spam");
    view.snapshot.selected = "spam";
    try std.testing.expectEqualStrings("spam", app.key);
    try app.setSelectedHidden(false);
    try std.testing.expect(worker.commands.items[worker.commands.items.len - 1].kind == .unhide);
    chats[0].hidden = false;
    try app.reconcileSelection();
    try std.testing.expectEqualStrings("friend", app.pending_key.?);
    try app.completeSelection("friend");
    view.snapshot.selected = "friend";
    try std.testing.expectEqualStrings("friend", app.key);
    try app.toggleHidden();
    try std.testing.expect(!app.show_hidden and app.matchesSidebar(chats[0]));
    try std.testing.expectEqualStrings("spam", app.pending_key.?);
    try app.completeSelection("spam");
    view.snapshot.selected = "spam";
    try std.testing.expectEqualStrings("spam", app.key);
}

test "workspace navigation, compact lists, message selection, and scrollbars render correctly" {
    // Raylib logs to stdout, which Zig's test runner reserves for its protocol.
    rl.setTraceLogLevel(.none);
    rl.setConfigFlags(.{ .window_highdpi = true, .msaa_4x_hint = true });
    rl.initWindow(1120, 780, "Zimbr UI checks");
    defer rl.closeWindow();
    bridge.zc_activation_init();
    defer bridge.zc_activation_free();
    // Coalesced worker signals wake an idle UI without dispatching or clearing
    // input callbacks. Draining must leave the next wait idle.
    for (0..10000) |_| bridge.zc_activation_wake();
    try std.testing.expectEqual(@as(c_int, 1), bridge.zc_activation_wait(0));
    try std.testing.expectEqual(@as(c_int, 0), bridge.zc_activation_wait(0));
    rl.pollInputEvents();
    // Test frames advance explicitly; a display-rate cap only adds idle time.
    rl.setTargetFPS(0);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = clay.initialize(
        .init(try arena.allocator().alloc(u8, clay.minMemorySize())),
        .{ .w = 1120, .h = 780 },
        .{ .error_handler_function = clayError },
    );
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/zimbr-ui-test" } };
    defer worker.shutdown();
    var chats: [32]Store.Chat = undefined;
    for (&chats, 0..) |*chat, i| chat.* = .{
        .value = .{
            .id = try std.fmt.allocPrint(arena.allocator(), "fixture-{d}", .{i}),
            .service = "imessage",
            .title = try std.fmt.allocPrint(
                arena.allocator(),
                "Conversation {d} long wrapped label",
                .{i},
            ),
            .last_activity = "2026-01-01T00:00:00Z",
            .sendable = true,
        },
        .preview = "This preview must stay below the search box.",
        .unread = 1,
    };
    const view = try a.create(Worker.View);
    view.* = .{
        .arena = std.heap.ArenaAllocator.init(a),
        .snapshot = .{
            .chats = &chats,
            .messages = &.{},
            .pending = &.{},
            .selected = "fixture-0",
            .draft = "",
            .epoch = "",
            .more = false,
        },
        .status = "Offline",
        .online = false,
        .send_direct = false,
        .reply_existing = false,
        .generation = 1,
        .ack = 0,
    };
    var app = App{
        .worker = &worker,
        .view = view,
        .key = try a.dupe(u8, "fixture-0"),
        .focus = .none,
    };
    defer app.deinit();
    for (0..4) |_| app.draw(WindowMetrics.current().scale);
    const before = try captureTestFrame(&app, WindowMetrics.current().scale);
    defer rl.unloadImage(before);
    const scale = WindowMetrics.current().scale;
    for ([_]f32{
        25,
        53,
        107,
        345,
    }) |scroll| {
        app.sidebar_scroll = scroll;
        const after = try captureTestFrame(&app, scale);
        defer rl.unloadImage(after);
        const fixed = layout.frame(1120, 780, app.composerHeight());
        const right: i32 = @intFromFloat((fixed.sidebar.x + fixed.sidebar.width - 1) * scale);
        const bottom: i32 = @intFromFloat(App.sidebarViewport(fixed.sidebar).y * scale);
        var y: i32 = 0;
        while (y < bottom) : (y += 1) {
            var x: i32 = 0;
            while (x < right) : (x += 1) try std.testing.expectEqual(
                rl.getImageColor(before, x, y),
                rl.getImageColor(after, x, y),
            );
        }
        try std.testing.expectEqual(@as(usize, 0), clip_depth);
    }
    const dark = try captureTestFrame(&app, scale);
    defer rl.unloadImage(dark);
    try std.testing.expectEqual(
        theme.colors.rail,
        rl.getImageColor(dark, @intFromFloat(5 * scale), @intFromFloat(50 * scale)),
    );
    try std.testing.expectEqual(
        theme.colors.sidebar,
        rl.getImageColor(dark, @intFromFloat(70 * scale), @intFromFloat(50 * scale)),
    );
    try std.testing.expectEqual(
        theme.colors.paper,
        rl.getImageColor(dark, @intFromFloat(320 * scale), @intFromFloat(50 * scale)),
    );
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
    chats[0].value.participants = &.{
        "alice@example.invalid",
        "bob@example.invalid",
        "carol@example.invalid",
    };
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
        const areas = layout.frame(
            @floatFromInt(rl.getScreenWidth()),
            @floatFromInt(rl.getScreenHeight()),
            app.composerHeight(),
        );
        try expectScrollbarPixel(
            shot,
            App.sidebarViewport(areas.sidebar),
            chats.len * App.sidebar_row_height,
            app.sidebar_scroll,
        );
        try expectScrollbarPixel(shot, areas.history, app.content_height, app.scroll);
        const editor = App.composerEditor(App.composerBox(areas.composer));
        const composer_viewport = rl.Rectangle{
            .x = editor.x + 11,
            .y = editor.y + 10,
            .width = editor.width - 22,
            .height = editor.height - 20,
        };
        try expectScrollbarPixel(
            shot,
            composer_viewport,
            app.text.height(app.composer.text.items, 16, composer_viewport.width - Scrollbar.gutter),
            app.composer_scroll,
        );
        const visible = app.visibleHistory(app.history_rows, areas.history.height);
        var checked: usize = 0;
        for (app.history_rows[visible.start..visible.end], group_messages[visible.start..visible.end]) |row, m| {
            const y = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 17;
            if (y < areas.history.y or y >= areas.history.y + areas.history.height) continue;
            const style = theme.participant(m.sender, chats[0].value.participants);
            const pixel = rl.getImageColor(
                shot,
                @intFromFloat((areas.history.x + 24) * WindowMetrics.current().scale),
                @intFromFloat(y * WindowMetrics.current().scale),
            );
            try std.testing.expectEqual(style.bubble, pixel);
            checked += 1;
        }
        try std.testing.expect(checked >= 2);
        app.toggleDetails();
        app.draw(WindowMetrics.current().scale);
        const details = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer rl.unloadImage(details);
        try expectScrollbarPixel(details, .{
            .x = areas.sidebar.x + 32,
            .y = 98,
            .width = areas.sidebar.width + areas.header.width - 48,
            .height = areas.composer.y + areas.composer.height - 106,
        }, app.details_height, app.details_scroll);
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
    const areas = layout.frame(
        @floatFromInt(rl.getScreenWidth()),
        @floatFromInt(rl.getScreenHeight()),
        app.composerHeight(),
    );
    const row = app.history_rows[app.history_rows.len - 1];
    const text_width = App.historyTextWidth(areas.history);
    const text_x = areas.history.x + 66;
    const text_y = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 22;
    const start = app.text.caret(row.text, text_width, "A ".len);
    const end = app.text.caret(row.text, text_width, "A message".len);
    // raylib automation event IDs: mouse position = 7, down = 6, up = 5.
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 7,
        .params = .{
            @intFromFloat(text_x + end.x),
            @intFromFloat(text_y + end.y + end.height / 2),
            0,
            0,
        },
    });
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 6,
        .params = .{
            0,
            0,
            0,
            0,
        },
    });
    app.draw(scale);
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 7,
        .params = .{
            @intFromFloat(text_x + start.x),
            @intFromFloat(text_y + start.y + start.height / 2),
            0,
            0,
        },
    });
    const selection_after = try captureTestFrame(&app, scale);
    defer rl.unloadImage(selection_after);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());
    var highlighted: usize = 0;
    var py: i32 = @intFromFloat(text_y * scale);
    while (py < @as(i32, @intFromFloat((text_y + start.height) * scale))) : (py += 1) {
        var px: i32 = @intFromFloat((text_x + start.x) * scale);
        while (px < @as(i32, @intFromFloat((text_x + end.x) * scale))) : (px += 1) {
            if (!std.meta.eql(
                rl.getImageColor(selection_before, px, py),
                rl.getImageColor(selection_after, px, py),
            )) highlighted += 1;
        }
    }
    try std.testing.expect(highlighted > 100);
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 5,
        .params = .{
            0,
            0,
            0,
            0,
        },
    });
    app.draw(scale);
    try std.testing.expect(!app.message_selection.dragging);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());

    // An uncertain send stays before a newer reply and retains its recovery action.
    group_messages[group_messages.len - 1].timestamp = "2026-01-01T00:02:00Z";
    var pending = [_]Store.Pending{.{
        .input = .{
            .request_id = "pending-fixture",
            .server_epoch = "",
            .target = .{ .conversation_id = "fixture-0" },
            .text = "Keep this uncertain send available as a draft.",
        },
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
    try std.testing.expectEqualStrings(
        group_messages[group_messages.len - 1].id,
        app.history_rows[app.history_rows.len - 1].id,
    );
    try std.testing.expectEqualStrings("message", app.message_selection.selected());
    clickTestFrame(
        &app,
        areas.history.x + 66 + App.historyTextWidth(areas.history) - 59,
        areas.history.y + @as(f32, @floatCast(pending_row.top - app.scroll)) + pending_row.measured.? + 37,
    );
    try std.testing.expectEqualStrings(pending[0].input.text, app.composer.text.items);
    try std.testing.expect(app.duplicate_risk);

    // Successful sends can pass through each of these states before their echo
    // arrives. The recovery action must neither render nor accept clicks yet.
    try app.composer.set("");
    pending[0].sent_at = try u.timestamp(arena.allocator(), (u.now() - 978307200000) * 1000000);
    for ([_][]const u8{
        "sending",
        "queued",
        "dispatching",
        "submitted",
        "unknown",
        "unconfirmed",
    }) |state| {
        pending[0].state = state;
        view.generation += 1;
        app.draw(scale);
        const recent_row = app.history_rows[app.history_rows.len - 1];
        try std.testing.expect(recent_row.pending);
        const copy_x = areas.history.x + 66 + App.historyTextWidth(areas.history) - 59;
        const copy_y = areas.history.y + @as(f32, @floatCast(recent_row.top - app.scroll)) + recent_row.measured.? + 37;
        const recent = try captureTestFrame(&app, scale);
        defer rl.unloadImage(recent);
        try std.testing.expectEqual(theme.colors.paper, rl.getImageColor(
            recent,
            @intFromFloat(copy_x * scale),
            @intFromFloat(copy_y * scale),
        ));
        clickTestFrame(&app, copy_x, copy_y);
        try std.testing.expectEqualStrings("", app.composer.text.items);
    }
    pending[0].state = "failed";
    view.generation += 1;
    app.draw(scale);
    const failed_row = app.history_rows[app.history_rows.len - 1];
    clickTestFrame(
        &app,
        areas.history.x + 66 + App.historyTextWidth(areas.history) - 59,
        areas.history.y + @as(f32, @floatCast(failed_row.top - app.scroll)) + failed_row.measured.? + 37,
    );
    try std.testing.expectEqualStrings(pending[0].input.text, app.composer.text.items);
    try std.testing.expect(!app.duplicate_risk);
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
    // Reconnect now scrolls with the status row instead of staying in the header.
    app.details_scroll = 0;
    app.draw(scale);
    clickTestFrame(
        &app,
        areas.sidebar.x + 32 + 122 + app.text.lineSize(view.status, 14, 400).x + 6 + 12,
        98 + 50 + 260 + 26 + 18 + 32 + 12,
    );
    try std.testing.expect(!app.send_wait and app.show_details);
    try std.testing.expect(worker.commands.items[worker.commands.items.len - 1].kind == .reconnect);
    clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + 40);
    try std.testing.expect(!app.show_details);
    // The fixture worker does not run; complete its queued return to Messages.
    try std.testing.expectEqualStrings(view.snapshot.selected, app.pending_key.?);
    try app.completeSelection(view.snapshot.selected);
    clickTestFrame(&app, areas.sidebar.x + 40, areas.sidebar.y + 30);
    try std.testing.expect(app.focus == .search);
    app.focus = .none;
    try app.composer.set("");

    // A chat becoming read-only blocks keyboard and pointer editing without
    // discarding its draft. Writable chats still support drafting offline.
    try app.composer.set("Saved draft");
    app.draft_dirty = false;
    const next_loaded_key = try a.dupe(u8, app.key);
    a.free(app.loaded_key);
    app.loaded_key = next_loaded_key;
    chats[0].value.sendable = false;
    view.online = true;
    view.reply_existing = true;
    app.focus = .composer;
    for ([_]rl.KeyboardKey{ .backspace, .enter }) |key| {
        rl.playAutomationEvent(.{
            .frame = 0,
            .type = 2,
            .params = .{
                @intFromEnum(key),
                0,
                0,
                0,
            },
        });
        try app.update();
        rl.playAutomationEvent(.{
            .frame = 0,
            .type = 1,
            .params = .{
                @intFromEnum(key),
                0,
                0,
                0,
            },
        });
        try std.testing.expectEqualStrings("Saved draft", app.composer.text.items);
        try std.testing.expect(!app.send_wait and !app.draft_dirty and !app.canSend());
    }
    const disabled_box = App.composerBox(areas.composer);
    clickTestFrame(&app, disabled_box.x + 40, disabled_box.y + 16);
    try std.testing.expect(app.focus == .none);
    const disabled = try captureTestFrame(&app, scale);
    defer rl.unloadImage(disabled);
    try std.testing.expectEqual(
        theme.colors.incoming,
        rl.getImageColor(disabled, @intFromFloat((disabled_box.x + 5) * scale), @intFromFloat((disabled_box.y + disabled_box.height / 2) * scale)),
    );
    clickTestFrame(
        &app,
        areas.composer.x + areas.composer.width - layout.action_right_padding - 38,
        disabled_box.y + disabled_box.height / 2,
    );
    for (worker.commands.items) |command| try std.testing.expect(command.kind != .send);
    // You uses direct iMessage capability even if its grouped route is disabled.
    const participants = chats[0].value.participants;
    chats[0].value.is_self = true;
    chats[0].value.participants = &.{"self@example.invalid"};
    view.reply_existing = false;
    view.send_direct = true;
    try std.testing.expect(!app.readOnlyChat() and app.canSend());
    view.online = false;
    try std.testing.expect(!app.canSend());
    view.online = true;
    view.send_direct = false;
    try std.testing.expect(!app.canSend());
    chats[0].value.is_self = false;
    chats[0].value.participants = participants;
    try std.testing.expect(app.readOnlyChat());
    chats[0].value.sendable = true;
    view.online = false;
    view.reply_existing = false;
    clickTestFrame(&app, disabled_box.x + 40, disabled_box.y + 16);
    try std.testing.expect(app.focus == .composer);
    app.composer.caret = app.composer.text.items.len;
    app.composer.anchor = app.composer.caret;
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 2,
        .params = .{
            @intFromEnum(rl.KeyboardKey.backspace),
            0,
            0,
            0,
        },
    });
    try app.update();
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 1,
        .params = .{
            @intFromEnum(rl.KeyboardKey.backspace),
            0,
            0,
            0,
        },
    });
    try std.testing.expectEqualStrings("Saved draf", app.composer.text.items);
    app.focus = .none;
    app.draft_dirty = false;
    try app.composer.set("");

    // A large cached conversation must settle over multiple frames, keeping
    // input responsive and never painting full text into estimated row heights.
    app.show_details = false;
    app.heights.clearRetainingCapacity();
    var messages: [420]t.Message = undefined;
    const bodies = [_][]const u8{
        "Normal é 👩‍💻 שלום مرحبا",
        "https://example.invalid/" ++ "W" ** 65500,
        "\n" ** 65536,
        "a" ++ "́" ** 1000,
        "nul\x00tail",
        "bad\xff",
    };
    for (&messages, 0..) |*m, i| m.* = .{
        .id = try std.fmt.allocPrint(arena.allocator(), "message-{d}", .{i}),
        .conversation_id = "fixture-0",
        .sender = "long-sender-" ** 100,
        .direction = if (i % 2 == 0) .incoming else .outgoing,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = try std.fmt.allocPrint(
            arena.allocator(),
            "{d}: {s}",
            .{ i, bodies[i % bodies.len] },
        ),
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
    // A settled frame retains geometry while viewport changes still keep the
    // latest message at the bottom. New content invalidates that geometry.
    try std.testing.expect(!app.history_needs_position and !app.history_needs_measurement);
    const settled_rows = app.history_rows.ptr;
    app.draw(WindowMetrics.current().scale);
    try std.testing.expectEqual(settled_rows, app.history_rows.ptr);
    try app.composer.set("A taller\nthree-line\ncomposer");
    app.draw(WindowMetrics.current().scale);
    const history = layout.frame(
        @floatFromInt(rl.getScreenWidth()),
        @floatFromInt(rl.getScreenHeight()),
        app.composerHeight(),
    ).history;
    try std.testing.expectApproxEqAbs(app.historyLimit(history.height), app.scroll, 0.000001);
    const settled_height = app.content_height;
    messages[messages.len - 1].text = "Changed\nMore\nLines\nTo\nMeasure";
    view.generation += 1;
    app.draw(WindowMetrics.current().scale);
    try std.testing.expect(app.content_height != settled_height);
    try std.testing.expect(app.text.texture_bytes <= 32 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);
}

fn expectScrollbarPixel(shot: rl.Image, viewport: rl.Rectangle, content: f64, offset: f64) !void {
    const g = Scrollbar.geometry(viewport, content, offset) orelse return error.MissingScrollbar;
    const scale = WindowMetrics.current().scale;
    const pixel = rl.getImageColor(
        shot,
        @intFromFloat((g.thumb.x + g.thumb.width / 2) * scale),
        @intFromFloat((g.thumb.y + g.thumb.height / 2) * scale),
    );
    try std.testing.expect(std.meta.eql(pixel, theme.colors.muted) or std.meta.eql(
        pixel,
        theme.colors.accent,
    ));
}

test "sidebar highlight stays selected while Messages and Hidden wait for history" {
    const fixture = struct {
        fn publish(app: *App, chats: []const Store.Chat, key: []const u8) !void {
            const v = try a.create(Worker.View);
            v.* = .{
                .arena = .init(a),
                .snapshot = .{
                    .chats = chats,
                    .messages = &.{},
                    .pending = &.{},
                    .selected = key,
                    .draft = "",
                    .epoch = "fixture",
                    .more = false,
                },
                .status = "Offline",
                .online = false,
                .send_direct = false,
                .reply_existing = false,
                .generation = if (app.view) |old| old.generation + 1 else 1,
                .ack = 0,
            };
            app.worker.view = v;
            try app.update();
        }
        fn expectHighlight(app: *App, viewport: rl.Rectangle, index: usize) !void {
            const scale = WindowMetrics.current().scale;
            const shot = try captureTestFrame(app, scale);
            defer rl.unloadImage(shot);
            const color = if (app.show_hidden) theme.colors.line else theme.colors.selected;
            for (0..2) |row| {
                const pixel = rl.getImageColor(
                    shot,
                    @intFromFloat((viewport.x + viewport.width - 40) * scale),
                    @intFromFloat((viewport.y + @as(f32, @floatFromInt(row)) * App.sidebar_row_height + 16) * scale),
                );
                if (row == index) try std.testing.expectEqual(color, pixel) else try std.testing.expect(!std.meta.eql(color, pixel));
            }
        }
    };
    const reset_context: *const fn (?*clay.Context) callconv(.c) void = @ptrCast(&clay.setCurrentContext);
    reset_context(null);
    defer reset_context(null);
    rl.setTraceLogLevel(.none);
    rl.initWindow(1120, 780, "Zimbr sidebar selection checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    const clay_memory = try std.testing.allocator.alloc(u8, clay.minMemorySize());
    defer std.testing.allocator.free(clay_memory);
    _ = clay.initialize(
        .init(clay_memory),
        .{ .w = 1120, .h = 780 },
        .{ .error_handler_function = clayError },
    );
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var chats: [4]Store.Chat = undefined;
    for (&chats, [_][]const u8{
        "visible-first",
        "visible-second",
        "hidden-first",
        "hidden-second",
    }, 0..) |*chat, key, i| chat.* = .{
        .value = .{
            .id = key,
            .title = key,
            .service = "imessage",
            .sendable = i < 2,
        },
        .preview = "",
        .unread = 0,
        .hidden = i >= 2,
    };
    var app = App{ .worker = &worker };
    defer app.deinit();
    try fixture.publish(&app, &chats, "visible-first");
    for (0..4) |_| app.draw(WindowMetrics.current().scale);
    const areas = layout.frame(1120, 780, app.composerHeight());
    const viewport = App.sidebarViewport(areas.sidebar);
    try fixture.expectHighlight(&app, viewport, 0);
    for ([_]bool{ true, false }) |hidden| {
        const previous = if (hidden) "visible-first" else "hidden-first";
        const next = if (hidden) "hidden-first" else "visible-first";
        clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + @as(f32, if (hidden) 110 else 40));
        try std.testing.expectEqual(hidden, app.show_hidden);
        for (0..3) |_| {
            try app.update();
            try std.testing.expectEqualStrings(previous, app.key);
            try fixture.expectHighlight(&app, viewport, 0);
        }
        try fixture.publish(&app, &chats, next);
        try fixture.expectHighlight(&app, viewport, 0);
    }
    // A response from the other list must not move the requested highlight.
    clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + 110);
    clickTestFrame(&app, areas.rail.x + 32, areas.rail.y + 40);
    try fixture.publish(&app, &chats, "hidden-first");
    try fixture.expectHighlight(&app, viewport, 0);
    try fixture.publish(&app, &chats, "visible-first");
    try fixture.expectHighlight(&app, viewport, 0);
    // Changing the requested row again keeps exactly one highlight, in either direction.
    for ([_]usize{ 1, 0 }) |row| {
        clickTestFrame(
            &app,
            viewport.x + 60,
            viewport.y + @as(f32, @floatFromInt(row)) * App.sidebar_row_height + 16,
        );
        try fixture.expectHighlight(&app, viewport, row);
    }
}

test "conversation switches keep the previous frame until the latest selection is ready" {
    const fixture = struct {
        fn view(key: []const u8, generation: u64) !*Worker.View {
            const v = try a.create(Worker.View);
            errdefer a.destroy(v);
            var arena = std.heap.ArenaAllocator.init(a);
            errdefer arena.deinit();
            const ar = arena.allocator();
            const messages = try ar.alloc(t.Message, 30);
            for (messages, 0..) |*m, i| m.* = .{
                .id = try std.fmt.allocPrint(ar, "{s}-{d}", .{ key, i }),
                .conversation_id = key,
                .sender = "friend",
                .direction = .incoming,
                .service = "imessage",
                .timestamp = "2026-01-01T00:00:00Z",
                .kind = .text,
                .text = try std.fmt.allocPrint(ar, "{s} message {d}", .{ key, i }),
                .decoding = .plain,
                .observed_status = .received,
            };
            const draft = try std.fmt.allocPrint(ar, "{s} draft", .{key});
            v.* = .{
                .arena = arena,
                .snapshot = .{
                    .chats = &.{},
                    .messages = messages,
                    .pending = &.{},
                    .selected = key,
                    .draft = draft,
                    .epoch = "fixture",
                    .more = false,
                },
                .status = "Online",
                .online = true,
                .send_direct = true,
                .reply_existing = true,
                .generation = generation,
                .ack = 0,
            };
            return v;
        }
        fn expectHistory(before: rl.Image, after: rl.Image, r: rl.Rectangle, scale: f32) !void {
            var ink: usize = 0;
            var y: i32 = @intFromFloat(@ceil(r.y * scale));
            while (y < @as(i32, @intFromFloat((r.y + r.height) * scale))) : (y += 1) {
                var x: i32 = @intFromFloat(@ceil(r.x * scale));
                while (x < @as(i32, @intFromFloat((r.x + r.width) * scale))) : (x += 1) {
                    const pixel = rl.getImageColor(before, x, y);
                    if (!std.meta.eql(pixel, theme.colors.paper)) ink += 1;
                    try std.testing.expectEqual(pixel, rl.getImageColor(after, x, y));
                }
            }
            try std.testing.expect(ink > 100);
        }
    };
    const reset_context: *const fn (?*clay.Context) callconv(.c) void = @ptrCast(&clay.setCurrentContext);
    reset_context(null);
    defer reset_context(null);
    rl.setTraceLogLevel(.none);
    rl.initWindow(1120, 780, "Zimbr conversation switch checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    const clay_memory = try std.testing.allocator.alloc(u8, clay.minMemorySize());
    defer std.testing.allocator.free(clay_memory);
    _ = clay.initialize(
        .init(clay_memory),
        .{ .w = 1120, .h = 780 },
        .{ .error_handler_function = clayError },
    );
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    worker.view = try fixture.view("new:first", 1);
    try app.update();
    const scale = WindowMetrics.current().scale;
    for (0..4) |_| app.draw(scale);
    app.following = false;
    app.scroll = 150;
    app.focus = .none;
    try app.composer.set("Unsaved first draft");
    app.draft_dirty = true;
    const before = try captureTestFrame(&app, scale);
    defer rl.unloadImage(before);
    const areas = layout.frame(1120, 780, app.composerHeight());
    const scroll = app.scroll;
    const commands = worker.commands.items.len;
    try app.select("new:second");
    try std.testing.expectEqual(.draft, worker.commands.items[commands].kind);
    try std.testing.expectEqualStrings("new:first", worker.commands.items[commands].key);
    try std.testing.expectEqualStrings("Unsaved first draft", worker.commands.items[commands].text);
    for (0..3) |_| {
        try app.update();
        const waiting = try captureTestFrame(&app, scale);
        defer rl.unloadImage(waiting);
        try fixture.expectHistory(before, waiting, areas.history, scale);
        try std.testing.expectEqual(scroll, app.scroll);
        try std.testing.expectEqualStrings("new:first", app.key);
        try std.testing.expectEqualStrings("Unsaved first draft", app.composer.text.items);
        try std.testing.expect(!app.canSend());
    }
    // A superseded response must not flash on screen or replace the saved draft.
    try app.select("new:third");
    worker.view = try fixture.view("new:second", 2);
    try app.update();
    const superseded = try captureTestFrame(&app, scale);
    defer rl.unloadImage(superseded);
    try fixture.expectHistory(before, superseded, areas.history, scale);
    try std.testing.expectEqualStrings("new:first", app.view.?.snapshot.selected);
    worker.view = try fixture.view("new:third", 3);
    try app.update();
    try std.testing.expectEqualStrings("new:third", app.key);
    try std.testing.expectEqualStrings("new:third", app.view.?.snapshot.selected);
    try std.testing.expectEqualStrings("new:third draft", app.composer.text.items);
    try std.testing.expect(app.canSend());
    const switched = try captureTestFrame(&app, scale);
    defer rl.unloadImage(switched);
    try std.testing.expect(app.following);
    try std.testing.expectEqualStrings("new:third-29", app.history_rows[29].id);
    const settled = try captureTestFrame(&app, scale);
    defer rl.unloadImage(settled);
    try fixture.expectHistory(switched, settled, areas.history, scale);
}

test "shared message presentations survive replaced views and refresh edited text" {
    const SharedSnapshot = @import("client.zig").SharedSnapshot;
    const store = try Store.open(":memory:");
    defer store.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var message = t.Message{
        .id = "m1",
        .conversation_id = "c1",
        .sender = "peer",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .text,
        .text = "Long " ++ "x" ** 6000,
        .decoding = .plain,
        .observed_status = .received,
    };
    _ = try store.upsert(ar, "message", try u.json(ar, message));
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    rl.setTraceLogLevel(.none);
    rl.initWindow(780, 560, "Zimbr shared view checks");
    defer rl.closeWindow();
    var app = App{
        .worker = &worker,
        .key = try a.dupe(u8, "c1"),
        .focus = .none,
    };
    defer app.deinit();
    var first_rows: ?[*]App.HistoryRow = null;
    for (0..3) |iteration| {
        if (iteration == 2) {
            message.revision = "1";
            message.text = "Edited 👩‍💻";
            _ = try store.upsert(ar, "message", try u.json(ar, message));
        }
        const shared = try SharedSnapshot.create(
            store,
            "c1",
            iteration + 1,
            if (app.view) |old| old.shared else null,
        );
        const view = try a.create(Worker.View);
        view.* = .{
            .arena = .init(a),
            .snapshot = shared.snapshot,
            .shared = shared,
            .content_generation = shared.generation,
            .status = "Offline",
            .online = false,
            .send_direct = false,
            .reply_existing = false,
            .generation = iteration + 1,
            .ack = 0,
        };
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
    view.* = .{
        .arena = std.heap.ArenaAllocator.init(a),
        .snapshot = .{
            .chats = &.{},
            .messages = &.{},
            .pending = &.{},
            .selected = "large-history",
            .draft = "",
            .epoch = "",
            .more = false,
        },
        .status = "Offline",
        .online = false,
        .send_direct = false,
        .reply_existing = false,
        .generation = 1,
        .ack = 0,
    };
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
        try std.testing.expectApproxEqAbs(
            500 - @as(f64, rows[rows.len - 1].height()),
            last_y,
            0.000001,
        );
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
        const text = try std.fmt.allocPrint(
            arena.allocator(),
            "Message {d}\nLine two\nLine three",
            .{i},
        );
        row.* = .{
            .id = text,
            .text = text,
            .key = std.hash.Wyhash.hash(0, text),
            .measured = null,
            .padding = 54,
        };
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
        .{
            .id = "old",
            .text = "",
            .key = 0,
            .measured = null,
            .padding = 54,
        },
        .{
            .id = "recent",
            .text = "",
            .key = 1,
            .measured = 31.2,
            .padding = 54,
        },
        .{
            .id = "latest",
            .text = "",
            .key = 2,
            .measured = 31.2,
            .padding = 54,
        },
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
    for ([_]f32{
        1,
        1.25,
        1.5,
        2,
    }) |scale| {
        text.nextFrame(scale);
        for ([_][]const u8{
            "Hello",
            "Café 👩‍💻 שלום مرحبا\nSecond line",
            "wrapped " ** 150,
            "bad\xff",
            "a" ++ "́" ** 1000,
        }) |body| {
            const drawn_height = text.height(body, 16, 320);
            const count = text.entries.items.len;
            try std.testing.expectEqual(drawn_height, text.measure(body, 16, 320));
            try std.testing.expectEqual(count, text.entries.items.len);
        }
    }
}

fn clickTestFrame(app: *App, x: f32, y: f32) void {
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 7,
        .params = .{
            @intFromFloat(x),
            @intFromFloat(y),
            0,
            0,
        },
    });
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 6,
        .params = .{
            0,
            0,
            0,
            0,
        },
    });
    app.draw(WindowMetrics.current().scale);
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 5,
        .params = .{
            0,
            0,
            0,
            0,
        },
    });
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

test "message dates keep font alignment across glyphs and fractional row positions" {
    const Ink = struct {
        fn center(shot: rl.Image, left: i32, right: i32, top: i32, bottom: i32) !f32 {
            try std.testing.expectEqual(rl.PixelFormat.uncompressed_r8g8b8a8, shot.format);
            const width: usize = @intCast(shot.width);
            const data: [*]const rl.Color = @ptrCast(shot.data);
            const pixels = data[0 .. width * @as(usize, @intCast(shot.height))];
            const left_column: usize = @intCast(left);
            const right_column: usize = @intCast(right);
            var first = bottom;
            var last = top;
            var y = top;
            while (y < bottom) : (y += 1) {
                const offset = @as(usize, @intCast(y)) * width;
                const row = pixels[offset + left_column .. offset + right_column];
                for (row) |pixel| {
                    if (@max(pixel.r, pixel.g, pixel.b) <= 32) continue;
                    first = @min(first, y);
                    last = @max(last, y);
                }
            }
            try std.testing.expect(first <= last);
            return @as(f32, @floatFromInt(first + last)) / 2;
        }
    };
    rl.setTraceLogLevel(.none);
    rl.setConfigFlags(.{ .window_highdpi = true });
    rl.initWindow(640, 480, "Zimbr message header checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    const target = try rl.loadRenderTexture(1024, 512);
    defer rl.unloadRenderTexture(target);
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    var app = App{ .worker = &worker };
    defer app.deinit();
    for ([_]f32{
        1,
        1.25,
        1.5,
        2,
    }) |scale| {
        var reference_center: ?f32 = null;
        for ([_][]const u8{
            "You",
            "Alice",
            "Gregory",
            "Renée 👋",
            "민수",
        }) |name| for ([_]display.MessageStatus{
            .none,
            .{ .checks = .sent },
            .{ .checks = .group_sent },
            .{ .checks = .delivered },
            .{ .label = "Sending" },
        }) |status| for ([_][]const u8{
            "Sep 25 · 16:00",
            "Dec 25 · 16:00",
            "Aug 25 · 16:00",
            "Sep 25 · 09:55",
            "Sep 25 · 10:11",
        }) |stamp| {
            app.text.nextFrame(scale);
            rl.beginTextureMode(target);
            rl.clearBackground(rl.Color.black);
            rl.beginMode2D(.{
                .offset = .{ .x = 0, .y = 0 },
                .target = .{ .x = 0, .y = 0 },
                .rotation = 0,
                .zoom = scale,
            });
            // Message heights and scrolling can put a row at any subpixel phase.
            for (0..8) |i| {
                const row: f32 = @floatFromInt(i);
                _ = app.drawMessageHeader(name, stamp, status, .{
                    .x = 10,
                    .y = (12 + row * 40 + row / 8) / scale,
                    .width = 490,
                }, rl.Color.white, rl.Color.black);
            }
            const name_width = app.text.lineSize(name, 14, 490 * 0.55).x;
            const stamp_x = 10 + name_width + 6;
            const stamp_width = app.text.lineSize(stamp, 11, 250).x;
            // Control for glyph hinting and horizontal subpixel coverage by
            // rendering the same date without header positioning as a reference.
            app.text.drawLine(stamp, stamp_x, 400 / scale, 11, 250, theme.colors.muted, rl.Color.black);
            rl.endMode2D();
            rl.endTextureMode();
            var shot = try rl.loadImageFromTexture(target.texture);
            defer rl.unloadImage(shot);
            rl.imageFlipVertical(&shot);
            var first_offset: ?f32 = null;
            for (0..8) |i| {
                const top: i32 = 10 + @as(i32, @intCast(i)) * 40;
                const name_center = try Ink.center(
                    shot,
                    @intFromFloat(10 * scale),
                    @intFromFloat((stamp_x - 2) * scale),
                    top,
                    top + 38,
                );
                const date_center = try Ink.center(
                    shot,
                    @intFromFloat(stamp_x * scale),
                    @intFromFloat((stamp_x + stamp_width) * scale),
                    top,
                    top + 38,
                );
                const offset = date_center - name_center;
                if (first_offset) |expected| {
                    try std.testing.expectEqual(expected, offset);
                } else first_offset = offset;
            }
            // Font alignment keeps the unchanged clock digits at the same height;
            // centering each string's ink shifts them for descenders and emoji.
            const reference_clock = try Ink.center(
                shot,
                @intFromFloat((stamp_x + stamp_width - 20) * scale),
                @intFromFloat((stamp_x + stamp_width) * scale),
                400,
                438,
            ) - 400;
            const clock_center = try Ink.center(
                shot,
                @intFromFloat((stamp_x + stamp_width - 20) * scale),
                @intFromFloat((stamp_x + stamp_width) * scale),
                10,
                48,
            ) - reference_clock;
            if (reference_center) |expected| {
                try std.testing.expectEqual(expected, clock_center);
            } else reference_center = clock_center;
        };
    }
}

test "text and attachment messages retain identical sender and date alignment" {
    const reset_context: *const fn (?*clay.Context) callconv(.c) void = @ptrCast(&clay.setCurrentContext);
    reset_context(null);
    defer reset_context(null);
    rl.setTraceLogLevel(.none);
    rl.setConfigFlags(.{ .window_highdpi = true });
    rl.initWindow(1120, 900, "Zimbr mixed message checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    _ = clay.initialize(
        .init(try ar.alloc(u8, clay.minMemorySize())),
        .{ .w = 1120, .h = 900 },
        .{ .error_handler_function = clayError },
    );
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    const attachments = [_]t.Attachment{.{
        .id = "sample",
        .name = "Sample.png",
        .mime_type = "image/png",
        .bytes = "100",
        .image = .{
            .id = "sample",
            .version = "1",
            .variant = .inline_image,
            .width = 160,
            .height = 60,
            .availability = .ready,
        },
    }};
    var messages: [4]t.Message = undefined;
    for (&messages, 0..) |*message, i| message.* = .{
        .id = try std.fmt.allocPrint(ar, "message-{d}", .{i}),
        .conversation_id = "alignment",
        .sender = if (i < 2) "Alice" else "Gregory",
        .service = "imessage",
        .direction = .incoming,
        .timestamp = "2026-09-25T12:00:00Z",
        .kind = if (i % 2 == 0) .text else .attachment,
        .text = if (i % 2 == 0) "A plain text message" else "An attachment message",
        .attachments = if (i % 2 == 0) &.{} else &attachments,
        .decoding = .plain,
        .observed_status = .received,
        .enrichment = .{ .state = .complete },
    };
    const chats = [_]Store.Chat{.{
        .value = .{
            .id = "alignment",
            .title = "Synthetic alignment comparison",
            .service = "imessage",
            .participants = &.{ "Alice", "Gregory" },
        },
        .preview = "",
        .unread = 0,
    }};
    const view = try a.create(Worker.View);
    view.* = .{
        .arena = .init(a),
        .snapshot = .{
            .chats = &chats,
            .messages = &messages,
            .pending = &.{},
            .selected = "alignment",
            .draft = "",
            .epoch = "fixture",
            .more = false,
        },
        .status = "Offline",
        .online = false,
        .send_direct = false,
        .reply_existing = false,
        .generation = 1,
        .ack = 0,
    };
    var app = App{
        .worker = &worker,
        .view = view,
        .key = try a.dupe(u8, "alignment"),
        .focus = .none,
    };
    defer app.deinit();
    const scale = WindowMetrics.current().scale;
    for (0..4) |_| app.draw(scale);
    const shot = try captureTestFrame(&app, scale);
    defer rl.unloadImage(shot);
    const areas = layout.frame(
        @floatFromInt(rl.getScreenWidth()),
        @floatFromInt(rl.getScreenHeight()),
        app.composerHeight(),
    );
    try std.testing.expectEqual(@as(usize, 4), app.history_rows.len);
    for (0..2) |pair| {
        const plain = app.history_rows[pair * 2];
        const attached = app.history_rows[pair * 2 + 1];
        try std.testing.expect(attached.height() > plain.height());
        const plain_y: i32 = @intFromFloat(@round((areas.history.y + @as(f32, @floatCast(plain.top - app.scroll))) * scale));
        const attached_y: i32 = @intFromFloat(@round((areas.history.y + @as(f32, @floatCast(attached.top - app.scroll))) * scale));
        var ink: usize = 0;
        var dy: i32 = 0;
        while (dy < @as(i32, @intFromFloat(21 * scale))) : (dy += 1) {
            var x: i32 = @intFromFloat((areas.history.x + 66) * scale);
            while (x < @as(i32, @intFromFloat((areas.history.x + 330) * scale))) : (x += 1) {
                const left = rl.getImageColor(shot, x, plain_y + dy);
                const right = rl.getImageColor(shot, x, attached_y + dy);
                const left_ink = @max(left.r, left.g, left.b) > 80;
                const right_ink = @max(right.r, right.g, right.b) > 80;
                try std.testing.expectEqual(left_ink, right_ink);
                if (left_ink) ink += 1;
            }
        }
        try std.testing.expect(ink > 100);
    }
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
        text.draw(
            "Message text must retain its glyphs and proportions",
            20,
            20,
            16,
            500,
            rl.Color.black,
            rl.Color.white,
        );
        // Recoloring and selection share metrics but replace the texture.
        text.drawSelection(
            "Message text must retain its glyphs and proportions",
            20,
            60,
            16,
            500,
            rl.Color.red,
            0,
            7,
            rl.Color.white,
        );
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
            try std.testing.expectEqual(
                rl.getImageColor(before, x, y),
                rl.getImageColor(after, x, y),
            );
        }
    }
    try std.testing.expect(ink > 100);
    // Even a viewport spanning multiple 2048-pixel tiles must draw to its
    // bottom. Synthetic 8x scale exercises this on an ordinary display.
    text.nextFrame(8);
    rl.beginDrawing();
    rl.clearBackground(rl.Color.white);
    text.draw(
        "Visible text at every height\n" ** 40,
        20,
        0,
        16,
        300,
        rl.Color.black,
        rl.Color.white,
    );
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

test "enriched messages render captions, photos, cards and chips with keyboard viewer controls" {
    const Browser = struct {
        var url: [8192]u8 = undefined;
        var url_len: usize = 0;
        var count: usize = 0;

        fn open(target: link_targets.Target) bool {
            @memcpy(url[0..target.url.len], target.url);
            url_len = target.url.len;
            count += 1;
            return true;
        }
    };
    // Clay keeps a process-global pointer; prior tests have freed their arena.
    const reset_context: *const fn (?*clay.Context) callconv(.c) void = @ptrCast(&clay.setCurrentContext);
    reset_context(null);
    defer reset_context(null);
    rl.setTraceLogLevel(.none);
    rl.initWindow(1120, 900, "Zimbr enrichment checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    _ = clay.initialize(
        .init(try ar.alloc(u8, clay.minMemorySize())),
        .{ .w = 1120, .h = 900 },
        .{ .error_handler_function = clayError },
    );
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/zimbr-rich-ui-test" } };
    defer worker.shutdown();
    var media = Media{ .io = std.testing.io, .config = .{ .data = "" } };
    defer media.shutdown();
    _ = try media.context("epoch", "chat", 0, false, true);
    const photo = t.AssetRef{
        .id = "image-1",
        .version = "v1",
        .variant = .inline_image,
        .width = 160,
        .height = 90,
        .availability = .ready,
    };
    var avatar = photo;
    avatar.id = "avatar";
    avatar.variant = .avatar;
    var directory: @import("client.zig").IdentityDirectory = .{};
    try directory.put(ar, .{
        .id = "person",
        .revision = "1",
        .service = "imessage",
        .address = "peer@example.invalid",
        .display_name = "Renée 👋",
        .match_state = .matched,
        .avatar = avatar,
    });
    const attachments = [_]t.Attachment{ .{
        .id = "one",
        .name = "One.png",
        .mime_type = "image/png",
        .bytes = "100",
        .image = photo,
    }, .{
        .id = "two",
        .name = "Two.png",
        .mime_type = "image/png",
        .bytes = "100",
        .image = photo,
    } };
    var messages = [_]t.Message{
        .{
            .id = "target",
            .revision = "1",
            .conversation_id = "chat",
            .sender = "peer@example.invalid",
            .service = "imessage",
            .direction = .incoming,
            .timestamp = "2026-01-01T00:00:00Z",
            .kind = .attachment,
            .decoding = .plain,
            .observed_status = .received,
            .text = "Caption stays copyable 👩🏽‍💻 https://plain.example.invalid/path",
            .attachments = &attachments,
            .enrichment = .{ .state = .complete },
            .reactions = &.{ .{
                .id = "r1",
                .key = "heart",
                .emoji = "❤️",
                .actor = .{ .service = "imessage", .address = "peer@example.invalid" },
            }, .{
                .id = "r2",
                .key = "heart",
                .emoji = "❤️",
                .actor = .{ .service = "imessage", .is_self = true },
            } },
            .link_previews = &.{.{
                .id = "card",
                .part_id = "url",
                .title = "Stored title <literal>",
                .original_url = "https://shared.example.invalid/original",
                .metadata_url = "https://other.example.invalid/final",
                .state = .complete,
            }},
        },
        .{
            .id = "raw",
            .revision = "2",
            .conversation_id = "chat",
            .sender = "peer@example.invalid",
            .service = "imessage",
            .direction = .incoming,
            .timestamp = "2026-01-01T00:00:01Z",
            .kind = .reaction,
            .decoding = .plain,
            .observed_status = .received,
            .reaction_event = .{
                .target_message_id = "target",
                .actor = .{ .service = "imessage", .is_self = true },
                .operation = .add,
                .resolution = .resolved,
            },
        },
    };
    const chats = [_]Store.Chat{.{
        .value = .{
            .id = "chat",
            .service = "imessage",
            .participants = &.{"peer@example.invalid"},
        },
        .preview = "Caption",
        .unread = 0,
    }};
    const view = try a.create(Worker.View);
    view.* = .{
        .arena = .init(a),
        .snapshot = .{
            .chats = &chats,
            .messages = &messages,
            .pending = &.{},
            .selected = "chat",
            .draft = "",
            .epoch = "epoch",
            .more = false,
            .directory = directory,
        },
        .status = "Offline",
        .online = false,
        .send_direct = false,
        .reply_existing = false,
        .generation = 1,
        .ack = 0,
    };
    var app = App{
        .worker = &worker,
        .media = &media,
        .view = view,
        .open_link = Browser.open,
        .key = try a.dupe(u8, "chat"),
        .loaded_key = try a.dupe(u8, "chat"),
        .focus = .none,
    };
    defer app.deinit();
    for ([_]t.AssetRef{ photo, avatar }, [_]rl.Color{ rl.Color.red, rl.Color.sky_blue }) |asset, color| {
        const pixels = rl.genImageColor(160, 90, color);
        defer rl.unloadImage(pixels);
        const texture = try rl.loadTextureFromImage(pixels);
        try app.images.entries.put(std.heap.c_allocator, media.key(asset), .{
            .texture = texture,
            .bytes = 160 * 90 * 4,
            .state = .ready,
        });
        app.images.bytes += 160 * 90 * 4;
    }
    for ([_]f32{
        1,
        1.25,
        2,
    }) |scale| {
        for (0..3) |_| app.draw(scale);
        try std.testing.expectEqual(@as(usize, 1), app.history_rows.len);
        try std.testing.expect(app.rich_count >= 4);
        try std.testing.expect(app.images.bytes <= Media.texture_budget);
    }
    const areas = layout.frame(1120, 900, app.composerHeight());
    const row = app.history_rows[0];
    const x = areas.history.x + 66;
    var top = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 22;
    var first_image: ?rl.Rectangle = null;
    for (row.blocks) |block| {
        const h = app.blockHeight(block, App.historyTextWidth(areas.history), true);
        const r = rl.Rectangle{
            .x = x,
            .y = top,
            .width = 160,
            .height = h,
        };
        if (block.value == .attachment and first_image == null) first_image = r;
        if (block.value == .text) {
            const text_h = app.text.height(block.value.text, 16, App.historyTextWidth(areas.history));
            clickTestFrame(&app, r.x + 18, r.y + text_h + 14);
            try std.testing.expect(app.detail_body == null);
            try std.testing.expectEqual(@as(usize, 1), Browser.count);
            try std.testing.expectEqualStrings(
                "https://plain.example.invalid/path",
                Browser.url[0..Browser.url_len],
            );
        }
        if (block.value == .reactions) {
            clickTestFrame(&app, r.x + 18, r.y + 14);
            try std.testing.expect(app.detail_body != null);
            try std.testing.expect(std.mem.indexOf(u8, app.detail_body.?, "Renée 👋") != null);
            try std.testing.expect(std.mem.indexOf(u8, app.detail_body.?, "You (your reaction)") != null);
            try std.testing.expect(std.mem.indexOf(u8, app.detail_body.?, "whole message") != null);
            try view.snapshot.directory.put(ar, .{
                .id = "person",
                .revision = "2",
                .service = "imessage",
                .address = "peer@example.invalid",
                .display_name = "Renamed peer",
                .match_state = .matched,
                .avatar = avatar,
            });
            app.refreshReactionDetail();
            try std.testing.expect(std.mem.indexOf(u8, app.detail_body.?, "Renamed peer") != null);
            view.snapshot.directory.available = false;
            app.refreshReactionDetail();
            try std.testing.expect(std.mem.indexOf(u8, app.detail_body.?, "Renamed peer") == null);
            view.snapshot.directory.available = true;
            app.closeContentDetail();
        }
        if (block.value == .card) {
            clickTestFrame(&app, r.x + 18, r.y + 14);
            try std.testing.expect(app.detail_body == null);
            try std.testing.expectEqual(@as(usize, 2), Browser.count);
            try std.testing.expectEqualStrings(
                "https://shared.example.invalid/original",
                Browser.url[0..Browser.url_len],
            );
        }
        top += h + 8;
    }
    const image_r = first_image.?;
    const shot = try captureTestFrame(&app, 1);
    defer rl.unloadImage(shot);
    const dpi = WindowMetrics.current().scale;
    try std.testing.expectEqual(
        rl.Color.red,
        rl.getImageColor(shot, @intFromFloat((image_r.x + 80) * dpi), @intFromFloat((image_r.y + 45) * dpi)),
    );
    clickTestFrame(&app, image_r.x + 80, image_r.y + 45);
    try std.testing.expectEqualStrings("target", app.viewer_message);
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 2,
        .params = .{
            @intFromEnum(rl.KeyboardKey.right),
            0,
            0,
            0,
        },
    });
    try app.update();
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 1,
        .params = .{
            @intFromEnum(rl.KeyboardKey.right),
            0,
            0,
            0,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), app.viewer_attachment);
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 2,
        .params = .{
            @intFromEnum(rl.KeyboardKey.escape),
            0,
            0,
            0,
        },
    });
    try app.update();
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 1,
        .params = .{
            @intFromEnum(rl.KeyboardKey.escape),
            0,
            0,
            0,
        },
    });
    try std.testing.expectEqual(@as(usize, 0), app.viewer_message.len);
    try app.message_selection.begin(
        "target",
        false,
        row.blocks[0].value.text,
        messages[0].text.?,
        0,
    );
    try std.testing.expectEqualStrings(messages[0].text.?, app.message_selection.selected());
    messages[0].reactions = &.{};
    messages[0].revision = "3";
    view.generation += 1;
    app.draw(1);
    for (app.history_rows[0].blocks) |block| try std.testing.expect(block.value != .reactions);
}

test "inline photos reuse the viewer variant only when display pixels need it" {
    var item = t.Attachment{
        .id = "photo",
        .name = "photo.png",
        .mime_type = "image/png",
        .bytes = "1",
        .image = .{
            .id = "photo",
            .version = "1",
            .variant = .inline_image,
            .width = 1024,
            .height = 768,
        },
        .viewer = .{
            .id = "photo",
            .version = "1",
            .variant = .viewer,
            .width = 2560,
            .height = 1920,
        },
    };
    const size = App.imageSize(item.image, 480);
    for ([_]f32{
        1,
        1.25,
        2,
    }) |scale| try std.testing.expect(App.inlineAsset(item, size, scale).?.variant == .inline_image);
    try std.testing.expect(App.inlineAsset(item, size, 3).?.variant == .viewer);
    item.viewer.?.availability = .retired;
    try std.testing.expect(App.inlineAsset(item, size, 3).?.variant == .inline_image);
}

test "reading anchor follows the visible image part when an earlier image gains dimensions" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    defer worker.shutdown();
    var app = App{
        .worker = &worker,
        .following = false,
        .history_width = 320,
    };
    defer app.deinit();
    var blocks = [_]message_content.Block{
        .{ .value = .{ .attachment = .{
            .id = "first",
            .name = "",
            .mime_type = "image/png",
            .bytes = "0",
            .image = .{
                .id = "a",
                .version = "1",
                .variant = .inline_image,
                .width = 100,
                .height = 100,
            },
        } } },
        .{ .value = .{ .attachment = .{
            .id = "second",
            .name = "",
            .mime_type = "image/png",
            .bytes = "0",
            .image = .{
                .id = "b",
                .version = "1",
                .variant = .inline_image,
                .width = 100,
                .height = 100,
            },
        } } },
    };
    var rows = [_]App.HistoryRow{.{
        .id = "message",
        .text = "",
        .key = 1,
        .measured = 400,
        .padding = 38,
        .blocks = &blocks,
    }};
    app.scroll = 54 + 22 + 136 + 10;
    app.positionHistory(&rows, 80);
    app.rememberHistoryAnchor(&rows);
    try std.testing.expectEqualStrings("second", app.anchor_block);
    const before = app.scroll;
    blocks[0].value.attachment.image.?.height = 300;
    rows[0].measured = 600;
    app.positionHistory(&rows, 80);
    try std.testing.expectApproxEqAbs(before + 200, app.scroll, 0.001);
}

test "attachment updates preserve the visible part through history preparation and measurement" {
    rl.setTraceLogLevel(.none);
    rl.initWindow(780, 560, "Zimbr attachment scroll checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .key = try a.dupe(u8, "chat") };
    defer app.deinit();
    const view = try a.create(Worker.View);
    view.* = .{
        .arena = .init(a),
        .snapshot = .{
            .chats = &.{},
            .messages = &.{},
            .pending = &.{},
            .selected = "chat",
            .draft = "",
            .epoch = "",
            .more = false,
        },
        .status = "Offline",
        .online = false,
        .send_direct = false,
        .reply_existing = false,
        .generation = 1,
        .ack = 0,
    };
    app.view = view;
    var attachments = [_]t.Attachment{ .{
        .id = "first",
        .name = "First.png",
        .mime_type = "image/png",
        .bytes = "0",
        .image = .{
            .id = "first",
            .version = "1",
            .variant = .inline_image,
            .width = 100,
            .height = 100,
        },
    }, .{
        .id = "second",
        .name = "Second.png",
        .mime_type = "image/png",
        .bytes = "0",
        .image = .{
            .id = "second",
            .version = "1",
            .variant = .inline_image,
            .width = 100,
            .height = 100,
        },
    } };
    const messages = [_]t.Message{.{
        .id = "message",
        .conversation_id = "chat",
        .sender = "peer",
        .direction = .incoming,
        .service = "imessage",
        .timestamp = "2026-01-01T00:00:00Z",
        .kind = .attachment,
        .decoding = .plain,
        .observed_status = .received,
        .attachments = &attachments,
    }};
    view.snapshot.messages = &messages;
    const Frame = struct {
        const viewport = rl.Rectangle{ .x = 0, .y = 0, .width = 500, .height = 80 };

        fn draw(s: *App) void {
            s.text.nextFrame(1);
            _ = s.frame_arena.reset(.retain_capacity);
            rl.beginDrawing();
            defer rl.endDrawing();
            s.drawHistory(viewport, s.frame_arena.allocator());
        }
    };
    Frame.draw(&app);
    app.following = false;
    app.scroll = app.history_rows[0].top + 22 + 136 + 10;
    Frame.draw(&app);
    try std.testing.expectEqualStrings("second", app.anchor_block);
    const offset = app.anchor_block_offset;
    var scroll = app.scroll;

    // The refreshed row loses its cached height before its new dimensions
    // are measured, including when it is the last row in the conversation.
    for ([_]u32{ 300, 100 }) |height| {
        const old_height = attachments[0].image.?.height.?;
        attachments[0].image.?.height = height;
        view.generation += 1;
        const delta = @as(f64, @floatFromInt(height)) - @as(f64, @floatFromInt(old_height));
        scroll += delta;
        for (0..3) |_| {
            Frame.draw(&app);
            try std.testing.expectEqualStrings("message", app.history_anchor);
            try std.testing.expectEqualStrings("second", app.anchor_block);
            try std.testing.expectApproxEqAbs(offset, app.anchor_block_offset, 0.001);
            try std.testing.expectApproxEqAbs(scroll, app.scroll, 0.001);
            try std.testing.expect(!app.following);
        }
    }

    // Wheel input arriving with new dimensions must use the restored geometry.
    attachments[0].image.?.height = 300;
    attachments[0].image.?.version = "wheel-update";
    view.generation += 1;
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 7,
        .params = .{
            20,
            20,
            0,
            0,
        },
    });
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = 8,
        .params = .{
            0,
            1,
            0,
            0,
        },
    });
    Frame.draw(&app);
    try std.testing.expectApproxEqAbs(scroll + 200 - 57.5, app.scroll, 0.001);
    try std.testing.expect(!app.following);
    const after_wheel = app.scroll;
    Frame.draw(&app);
    try std.testing.expectApproxEqAbs(after_wheel, app.scroll, 0.001);
    attachments[0].image.?.height = 100;

    var surrounding = [_]t.Message{messages[0]} ** 3;
    var photos = [_][2]t.Attachment{attachments} ** 3;
    for (&surrounding, &photos, [_][]const u8{
        "earlier",
        "reading",
        "later",
    }) |*message, *items, id| {
        message.id = id;
        message.attachments = items;
    }
    view.snapshot.messages = &surrounding;
    view.generation += 1;
    app.following = true;
    Frame.draw(&app);
    app.following = false;
    app.scroll = app.history_rows[1].top + 22 + 136 + 10;
    Frame.draw(&app);
    try std.testing.expectEqualStrings("reading", app.history_anchor);
    try std.testing.expectEqualStrings("second", app.anchor_block);

    // Loading, growing, and shrinking previews above, within, or below the
    // viewport preserves the reading position; follow mode stays at the bottom.
    for ([_]bool{ false, true }) |following| {
        app.following = following;
        for (&photos) |*items| {
            for ([_]?u32{
                null,
                300,
                100,
            }) |height| {
                items[0].image = if (height) |h| preview: {
                    var asset = attachments[0].image.?;
                    asset.height = h;
                    break :preview asset;
                } else null;
                view.generation += 1;
                Frame.draw(&app);
                if (following) {
                    const last = app.history_rows[2];
                    try std.testing.expectApproxEqAbs(
                        @as(f64, Frame.viewport.height),
                        last.top + last.height() - app.scroll,
                        0.001,
                    );
                } else {
                    try std.testing.expectEqualStrings("reading", app.history_anchor);
                    try std.testing.expectEqualStrings("second", app.anchor_block);
                    try std.testing.expectApproxEqAbs(offset, app.anchor_block_offset, 0.001);
                }
                try std.testing.expectEqual(following, app.following);
            }
        }
    }
}

test "metadata and reaction rows cannot create a new-message indicator" {
    const old_chats = [_]Store.Chat{.{
        .value = .{ .id = "chat", .service = "imessage" },
        .preview = "Caption",
        .unread = 0,
    }};
    var next_chats = old_chats;
    const old = Store.Snapshot{
        .chats = &old_chats,
        .messages = &.{},
        .pending = &.{},
        .selected = "chat",
        .draft = "",
        .epoch = "epoch",
        .more = false,
    };
    var next = old;
    next.chats = &next_chats;
    next_chats[0].preview = "Updated caption";
    try std.testing.expect(!App.newUnread(old, next));
    next_chats[0].unread = 1;
    try std.testing.expect(App.newUnread(old, next));
    next.selected = "other";
    try std.testing.expect(!App.newUnread(old, next));
}

test "required settings block navigation and invalid saves keep setup open" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = App{
        .worker = &worker,
        .settings = try Settings.init(worker.config),
        .config_allocator = arena.allocator(),
    };
    defer app.deinit();
    app.toggleDetails();
    try app.toggleHidden();
    try app.newMessage();
    try app.select("chat");
    try app.reconcileSelection();
    try app.saveSettings();
    try std.testing.expect(app.settings.visible and app.settings.required);
    try std.testing.expect(!app.show_details and !app.show_hidden and !app.new_mode);
    try std.testing.expectEqualStrings("", app.key);
    try std.testing.expectEqual(@as(usize, 0), worker.commands.items.len);
    try std.testing.expect(app.next_config == null);
    try std.testing.expect(!app.canSend());
}

fn testKey(key: rl.KeyboardKey, down: bool) void {
    // Raylib exposes playback but keeps its automation event enum private.
    rl.playAutomationEvent(.{
        .frame = 0,
        .type = if (down) 2 else 1,
        .params = .{
            @intFromEnum(key),
            0,
            0,
            0,
        },
    });
}

test "Details streams logs, preserves scrollback, and supports latest copy and clear" {
    const reset_context: *const fn (?*clay.Context) callconv(.c) void = @ptrCast(&clay.setCurrentContext);
    reset_context(null);
    rl.setTraceLogLevel(.none);
    rl.setConfigFlags(.{ .window_highdpi = true });
    rl.initWindow(1120, 780, "Zimbr log checks");
    defer rl.closeWindow();
    rl.pollInputEvents();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    defer reset_context(null);
    _ = clay.initialize(
        .init(try arena.allocator().alloc(u8, clay.minMemorySize())),
        .{ .w = 1120, .h = 780 },
        .{ .error_handler_function = clayError },
    );
    var logs: LogBuffer = .{};
    for (0..LogBuffer.capacity) |i| logs.append(.info, .fixture, "Image {d}: disk cache hit", .{i});
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .show_details = true, .logs = &logs };
    defer app.deinit();
    const scale = WindowMetrics.current().scale;
    app.draw(scale);
    try std.testing.expect(app.logs_limit > 0);
    try std.testing.expectEqual(app.logs_limit, app.logs_scroll);
    const shot = try captureTestFrame(&app, scale);
    defer rl.unloadImage(shot);
    try std.testing.expectEqual(theme.colors.surface, rl.getImageColor(
        shot,
        @intFromFloat(100 * scale),
        @intFromFloat(160 * scale),
    ));
    // Drive the nested scrollbar: the outer Details position must stay fixed.
    const details_scroll = app.details_scroll;
    const width: f32 = @floatFromInt(rl.getScreenWidth());
    clickTestFrame(&app, width - 66, 220);
    try std.testing.expect(!app.logs_follow and app.logs_focused);
    try std.testing.expect(app.logs_scroll > 0 and app.logs_scroll < app.logs_limit);
    try std.testing.expectEqual(details_scroll, app.details_scroll);
    const anchor = app.logs_anchor;
    const offset = app.logs_anchor_offset;
    logs.append(.info, .fixture, "New download while reading earlier logs", .{});
    app.draw(scale);
    try std.testing.expectEqual(anchor, app.logs_anchor);
    try std.testing.expectApproxEqAbs(offset, app.logs_anchor_offset, 0.01);

    // Focused keyboard scrolling uses the textbox rather than the page.
    testKey(.home, true);
    try app.update();
    app.draw(scale);
    testKey(.home, false);
    try std.testing.expectEqual(@as(f32, 0), app.logs_scroll);
    try std.testing.expectEqual(details_scroll, app.details_scroll);
    clickTestFrame(&app, width - 217, 128);
    try std.testing.expect(app.logs_follow);
    try std.testing.expectEqual(app.logs_limit, app.logs_scroll);
    logs.append(.info, .fixture, "Newest visible event", .{});
    app.draw(scale);
    try std.testing.expectEqual(app.logs_limit, app.logs_scroll);

    clickTestFrame(&app, width - 142, 128);
    const clipboard = rl.getClipboardText();
    try std.testing.expect(std.mem.endsWith(u8, clipboard, "Newest visible event\n"));
    try std.testing.expect(std.mem.indexOf(u8, clipboard, "disk cache hit") != null);
    clickTestFrame(&app, width - 68, 128);
    const cleared = try logs.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
    try std.testing.expectEqual(@as(f32, 0), app.logs_scroll);
    try std.testing.expect(app.logs_follow);
    logs.append(.info, .fixture, "Streaming resumes after clear", .{});
    app.draw(scale);
    try std.testing.expect(app.logs_anchor != null);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);
}

test "settings validate credentials and commit through the pane before unlocking navigation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const data = try ar.dupeZ(u8, path_buffer[0..length]);
    try std.testing.expectEqual(@as(c_int, 0), u.c.chmod(data, 0o700));
    const tls = try std.fmt.allocPrint(ar, "{s}/tls", .{data});
    // Reuse the integration suite's ephemeral certificates, valid at test time.
    const fixture = try std.process.run(ar, std.testing.io, .{ .argv = &.{
        "python3",
        "-c",
        "import sys; sys.path.insert(0, 'tests'); from tls_fixture import PKI; PKI(sys.argv[1])",
        tls,
    } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, fixture.term);
    const path = try std.fmt.allocPrintSentinel(ar, "{s}/client.db", .{data}, 0);
    const store = try Store.open(path);
    defer store.close();
    try store.saveDraft("chat", "Keep this draft");
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = data } };
    defer worker.shutdown();
    rl.setTraceLogLevel(.none);
    rl.setConfigFlags(.{ .window_highdpi = true, .msaa_4x_hint = true });
    rl.initWindow(780, 560, "Zimbr settings checks");
    defer rl.closeWindow();
    rl.setExitKey(.null);
    rl.pollInputEvents();
    _ = clay.initialize(
        .init(try ar.alloc(u8, clay.minMemorySize())),
        .{ .w = 780, .h = 560 },
        .{ .error_handler_function = clayError },
    );
    var app = App{
        .worker = &worker,
        .settings = try Settings.init(worker.config),
        .config_allocator = ar,
        .focus = .settings_relay,
    };
    defer app.deinit();
    app.draw(WindowMetrics.current().scale);
    // Raylib automation injects the same key states consumed by App.update.
    testKey(.escape, true);
    try app.update();
    try std.testing.expect(app.settings.visible);
    testKey(.escape, false);
    testKey(.tab, true);
    try app.update();
    try std.testing.expectEqual(.settings_ca, app.focus);
    testKey(.tab, false);
    try app.settings.fields[0].set("https://localhost:1");
    try app.settings.fields[1].set(try std.fmt.allocPrint(ar, "{s}/ca.pem", .{tls}));
    try app.settings.fields[2].set(try std.fmt.allocPrint(ar, "{s}/client.pem", .{tls}));
    try app.settings.fields[3].set(try std.fmt.allocPrint(ar, "{s}/missing-key.pem", .{tls}));
    try app.saveSettings();
    try std.testing.expect(app.next_config == null and app.settings.required);
    try std.testing.expectEqual(@as(c_int, bridge.ZC_CREDENTIALS), app.settings.failure.kind);
    try std.testing.expect(try Config.read(ar, store) == null);
    try app.settings.fields[3].set(try std.fmt.allocPrint(ar, "{s}/client-key.pem", .{tls}));
    app.settings.enter_to_send = false;
    try store.db.exec("CREATE TRIGGER reject_settings BEFORE INSERT ON settings BEGIN SELECT RAISE(ABORT,'failure'); END");
    try std.testing.expectError(error.DatabaseFailure, app.saveSettings());
    try std.testing.expect(app.next_config == null and app.settings.required);
    try store.db.exec("DROP TRIGGER reject_settings");
    testKey(.left_control, true);
    testKey(.enter, true);
    try app.update();
    const next = app.next_config.?;
    try std.testing.expectEqualStrings("https://localhost:1", (try Config.read(ar, store)).?.relay_url);
    try std.testing.expectEqualStrings("", worker.config.relay_url);
    try std.testing.expect(!next.enter_to_send);
    try std.testing.expectEqualStrings("Keep this draft", try store.draft(ar, "chat"));
    var reopened = try Settings.init(next);
    defer reopened.deinit();
    try std.testing.expect(!reopened.required and !reopened.visible);
}
