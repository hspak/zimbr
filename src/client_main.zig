const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.client);
const a = std.heap.page_allocator;

const graphics = @import("client/graphics.zig");
const client_options = @import("client_options");
const zrct = if (client_options.automation) @import("zrct") else void;
const u = @import("common.zig");
const t = @import("protocol.zig").types;
const outgoing_attachments = @import("protocol.zig").attachments;
const Settings = @import("client.zig").Settings;
const Config = @import("client.zig").Config;
const Store = @import("client.zig").Store;
const Worker = @import("client.zig").Worker;
const Notification = @import("client.zig").Notification;
const Editor = @import("client.zig").Editor;
const emoji = @import("client.zig").emoji;
const MessageSelection = @import("client.zig").MessageSelection;
const MessageHistory = @import("client.zig").MessageHistory;
const Text = @import("client.zig").Text;
const display = @import("client.zig").display;
const drop = @import("client.zig").drop;
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

const desktop = @import("client/desktop.zig");

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

const WindowMetrics = desktop.Metrics;

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
fn run(init: std.process.Init) !void {
    var config = try Config.parse(init);
    const cache_lock = try config.lockCache();
    defer _ = u.c.close(cache_lock);
    if (config.reset_cache) {
        try config.resetCache(init.io);
        std.debug.print("Local database and media reset. Saved settings and credentials retained when available.\n", .{});
        return;
    }
    log.info("Starting Zimbr {s}", .{client_options.version});
    try config.load(init.arena.allocator());
    // Start with room for navigation, conversation history, and a multiline composer.
    try openWindow(1120, 780, "Zimbr");
    defer closeWindow();
    if (comptime client_options.automation) {
        try zrct.init("zimbr", client_options.version);
        zrct.setDropHandler(bridge.zc_drop_paths);
        zrct.setRenderer(.{
            .window = @ptrCast(desktop.window()),
            .flush = graphics.flush,
            .overlay = automationOverlay,
        });
    }
    defer if (comptime client_options.automation) zrct.deinit();
    // Let Wayland deliver its initial scale before caching any text textures.
    desktop.poll();
    // Keep settings controls and the conversation usable beside the fixed-width sidebar.
    desktop.setMinSize(780, 560);
    while (true) {
        config = try runSession(init, config) orelse break;
        if (config.reset_cache) {
            // runSession's defers have joined both workers and closed SQLite.
            try config.resetCache(init.io);
            config.reset_cache = false;
            try config.load(init.arena.allocator());
        }
    }
}

fn runSession(init: std.process.Init, config: Config) !?Config {
    var worker = Worker{
        .io = init.io,
        .config = config,
        .on_ready = desktop.wake,
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
        .on_ready = desktop.wake,
    };
    const media_ready = if (media.start()) true else |err| failed: {
        log.err("Image cache unavailable: {s}", .{@errorName(err)});
        break :failed false;
    };
    defer if (media_ready) media.shutdown();
    if (app.settings.visible) app.focus = .settings_relay;
    app.syncTextInput();
    if (media_ready) app.media = &media;
    app.notifications.backend = bridge.zc_notifications_new(App.notificationAction, &app);
    const vsync = config.frames == 0 and desktop.c.SDL_SetRenderVSync(
        desktop.c.SDL_GetRenderer(desktop.window()),
        1,
    );
    if (config.frames == 0 and !vsync) log.warn("VSync unavailable; using the display frame timer", .{});
    var frames: usize = 0;
    var last_draw: u64 = 0;
    var next_draw: u64 = 0;
    var active_until: u64 = 0;
    var last_generation: u64 = 0;
    var last_revision: u64 = 0;
    var last_mouse = desktop.mouse();
    var last_drop_hovered = drop.hovered();
    var last_window = WindowMetrics{};
    var background_ready = false;
    var was_idle = true;
    while (!desktop.shouldClose()) {
        const automation_input = if (comptime client_options.automation) zrct.poll() else false;
        if (comptime client_options.automation) if (zrct.shouldClose()) break;
        bridge.zc_notifications_poll();
        try app.update();
        app.deliverNotifications();
        const generation = if (app.view) |v| v.generation else 0;
        const revision = app.composer.revision + app.search.revision + app.recipient.revision;
        const mouse = desktop.mouse();
        const drop_hovered = drop.hovered();
        const window = WindowMetrics.current();
        const input = app.had_input or mouse.x != last_mouse.x or mouse.y != last_mouse.y;
        const window_changed = !std.meta.eql(window, last_window);
        const now = desktop.ticks();
        // Keep rendering between input events so scrolling and key repeat do
        // not fall back to the idle polling cadence during an interaction.
        if (input or window_changed or revision != last_revision or drop_hovered != last_drop_hovered)
            // Match Flamez's short burst to bridge gaps in a gesture or key repeat.
            active_until = now + 120 * std.time.ns_per_ms;
        const syncing = !app.settings.visible and !app.show_details and app.syncActivity().active();
        const active = frames < 4 or config.frames > 0 or app.layout_pending or
            now < active_until or desktop.inputHeld() or syncing;
        const now_ms = u.now();
        const needs_draw = automation_input or active or background_ready or
            generation != last_generation or now_ms >= app.redraw_at;
        if (needs_draw and now >= next_draw) {
            // Sleeping between changes is not rendering time. Discard that first sample.
            if (!was_idle) app.frame_seconds = @as(f64, @floatFromInt(now - last_draw)) / std.time.ns_per_s;
            app.frame_idle = !active;
            app.capture_frame = config.screenshot != null and config.frames > 0 and frames + 1 >= config.frames;
            app.draw(window.scale);
            graphics.endFrame();
            background_ready = false;
            last_draw = now;
            // Swapchain recreation can make VSync return early during resize. Keep the
            // display deadline; time already spent drawing/presenting counts toward it.
            next_draw = now + if (config.frames > 0) std.time.ns_per_s / 120 else window.refresh_interval_ns;
            was_idle = false;
            last_generation = generation;
            last_revision = revision;
            last_mouse = mouse;
            last_drop_hovered = drop_hovered;
            last_window = window;
            frames += 1;
        } else {
            // Service GLib notifications, draft persistence, and transfers at least every
            // 25 ms, even when no SDL or worker event requests a frame.
            if (!needs_draw) was_idle = true;
            const ready = if (needs_draw)
                desktop.waitNs(next_draw -| now)
            else
                desktop.wait(@intCast(@min(25, @max(0, app.redraw_at - now_ms))));
            background_ready = ready or background_ready;
        }
        if (app.next_config != null) break;
        if (config.frames > 0 and frames >= config.frames) {
            if (config.screenshot) |path| {
                const shot = app.captured orelse return error.ScreenshotUnavailable;
                try graphics.saveImage(shot, path);
            }
            break;
        }
    }
    if (app.next_config == null or !app.next_config.?.reset_cache) {
        if (app.composer.preedit.items.len > 0) {
            try app.composer.commitPreedit();
            app.draft_dirty = true;
        }
        try app.saveDraft();
    }
    return app.next_config;
}
const App = struct {
    frame_seconds: f64 = 0,
    frame_idle: bool = false,
    redraw_at: i64 = std.math.maxInt(i64),
    controls: std.ArrayList(Control) = .empty,
    control_arena: std.heap.ArenaAllocator = .init(a),
    worker: *Worker,
    settings: Settings = .{},
    next_config: ?Config = null,
    config_allocator: u.Allocator = a,
    notifications: Notification.Queue = .{},
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
    rich_focus: ?usize = null,
    enter_to_send: bool = true,
    view: ?*Worker.View = null,
    text: Text = .{},
    heights: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    block_heights: std.AutoHashMapUnmanaged(u64, f32) = .empty,
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
    height_deadline: u64 = 0,
    composer: Editor = .{},
    emoji_completion: emoji.Completion = .{},
    recipient: Editor = .{},
    search: Editor = .{},
    focus: Focus = .composer,
    input_editor: ?*Editor = null,
    input_initialized: bool = false,
    reset_echo: std.ArrayList(u8) = .empty,
    had_input: bool = false,
    click_timestamp: f64 = 0,
    click_count: u8 = 0,
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
    files_serial: u64 = 0,
    attachment_index: usize = 0,
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
    text_click: ?TextClick = null,
    word_drag: ?Text.Range = null,
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
    captured: ?graphics.Image = null,

    const ButtonAction = enum {
        recipient_continue,
        settings_enter_to_send,
        settings_reset,
        settings_keep_data,
        settings_cancel,
        settings_save,
        logs_latest,
        logs_copy,
        logs_clear,
        conversation_visibility,
        load_older,
        new_messages,
        viewer_close,
        viewer_previous,
        viewer_next,
        content_close,
        attachment_previous,
        attachment_next,
        attachments_cancel,
        attachment_remove,
        viewer_retry,
        send,
        reconnect,
    };
    const Action = union(enum) {
        button: ButtonAction,
        recover: []const u8,
        rail: RailIcon,
        select: []const u8,
        retry: Media.Key,
        link: link_targets.Target,
        viewer: struct { message: []const u8, attachment: []const u8 },
        detail: []const u8,
        reaction: struct { message: []const u8, part: []const u8, label: []const u8 },
        enrichment: struct { message: []const u8, revision: []const u8, section: []const u8 },
        editor: struct { focus: Focus, origin: graphics.Point, width: f32, offset: f32 },
        emoji: ?usize,
        message: struct { id: []const u8, pending: bool, text: []const u8, full: []const u8, origin: graphics.Point, width: f32 },
        scroll: struct { pane: ScrollPane, viewport: graphics.Rect, content: f64 },
        history_background,
    };
    const ScrollPane = enum { sidebar, history, settings, details, logs, composer, content };
    const Control = struct {
        bounds: graphics.Rect,
        clip: ?graphics.Rect,
        action: Action,
        rich_index: ?usize = null,
    };
    fn addControl(s: *App, bounds: graphics.Rect, action: Action) void {
        if (input_obscured or bounds.width <= 0 or bounds.height <= 0) return;
        const owned = copyControl(Action, s.control_arena.allocator(), action) catch return;
        s.controls.append(a, .{
            .bounds = bounds,
            .clip = if (clip_depth > 0) clip_stack[clip_depth - 1] else null,
            .action = owned,
        }) catch {};
    }
    fn clickControl(s: *App, point: graphics.Point) bool {
        var i = s.controls.items.len;
        while (i > 0) {
            i -= 1;
            const control = s.controls.items[i];
            if (!control.bounds.contains(point)) continue;
            if (control.clip) |clip| if (!clip.contains(point)) continue;
            if (control.action != .emoji) s.emoji_completion.dismissed = true;
            if (control.action != .editor and control.action != .message) s.text_click = null;
            if (control.action == .scroll) {
                const scroll = control.action.scroll;
                if (scroll.pane == .logs) s.logs_focused = true;
                const bar = s.scrollbar(scroll.pane) orelse continue;
                const offset = s.scrollOffset(scroll.pane);
                const geometry = Scrollbar.geometry(scroll.viewport, scroll.content, offset) orelse continue;
                if (!geometry.track.contains(point)) continue;
                if (bar.update(scroll.viewport, scroll.content, offset, .{
                    .mouse = point,
                    .pressed = true,
                    .down = true,
                })) |next| s.setScroll(scroll.pane, next);
                s.dragging = false;
                s.layout_pending = true;
                return true;
            }
            if (control.rich_index != null) {
                s.focus = .none;
                s.rich_focus = null;
            }
            s.activate(control.action);
            s.layout_pending = true;
            return true;
        }
        return false;
    }
    const PointerInput = struct {
        pressed: bool = false,
        released: bool = false,
        down: bool,
        wheel: f32 = 0,
    };
    fn pointerInput(s: *App, input: PointerInput) void {
        const point = desktop.mouse();
        if (input.pressed) {
            s.word_drag = null;
            s.dragging = false;
            s.message_selection.dragging = false;
            s.logs_focused = false;
            if (!s.clickControl(point)) {
                s.text_click = null;
                s.emoji_completion.dismissed = true;
            }
        }
        if (input.wheel != 0) {
            var i = s.controls.items.len;
            while (i > 0) {
                i -= 1;
                const control = s.controls.items[i];
                if (control.action == .emoji and control.bounds.contains(point)) {
                    s.emoji_completion.cycle(input.wheel > 0);
                    s.layout_pending = true;
                    break;
                }
                if (control.action != .scroll or !control.bounds.contains(point)) continue;
                if (control.clip) |clip| if (!clip.contains(point)) continue;
                const scroll = control.action.scroll;
                if (scroll.pane == .history) {
                    _ = s.layoutHistory(scroll.viewport);
                    s.scrollHistory(input.wheel, scroll.viewport.height);
                    s.rememberHistoryAnchor(s.history_rows);
                } else {
                    const distance: f32 = switch (scroll.pane) {
                        .sidebar => 34 * Scrollbar.wheel_scale,
                        .composer => 46 * Scrollbar.wheel_scale,
                        .content => 40,
                        .settings, .details, .logs => 42 * Scrollbar.wheel_scale,
                        .history => unreachable,
                    };
                    const offset = std.math.clamp(s.scrollOffset(scroll.pane) - input.wheel * distance, 0, @max(0, scroll.content - scroll.viewport.height));
                    s.setScroll(scroll.pane, offset);
                }
                s.layout_pending = true;
                break;
            }
        }
        for (s.controls.items) |control| switch (control.action) {
            .editor => |field| if (s.dragging and s.focus == field.focus and
                (input.down or input.released))
            {
                const editor = s.focusedEditor() orelse continue;
                if (editor.preedit.items.len > 0) continue;
                const position = point.subtract(field.origin).add(.{ .x = 0, .y = field.offset });
                s.dragTextSelection(editor.text.items, field.width, position, &editor.anchor, &editor.caret);
            },
            .message => |message| if (s.focus == .none and s.message_selection.dragging and
                s.message_selection.matches(message.id, message.pending, message.text) and
                (input.down or input.released))
            {
                const selection = &s.message_selection;
                s.dragTextSelection(message.text, message.width, point.subtract(message.origin), &selection.anchor, &selection.caret);
                selection.whole = false;
            },
            .scroll => |scroll| {
                const bar = s.scrollbar(scroll.pane) orelse continue;
                if (!bar.dragging) continue;
                if (bar.update(scroll.viewport, scroll.content, s.scrollOffset(scroll.pane), .{
                    .mouse = point,
                    .pressed = false,
                    .down = input.down,
                })) |offset| s.setScroll(scroll.pane, offset);
            },
            .button, .recover, .rail, .select, .retry, .link, .viewer, .detail, .reaction, .enrichment, .emoji, .history_background => {},
        };
        if (s.text_click) |click| if ((input.down or input.released) and !click.near(point)) {
            s.text_click = null;
        };
        if (!input.down) {
            s.dragging = false;
            s.message_selection.dragging = false;
        }
    }
    fn scrollbar(s: *App, pane: ScrollPane) ?*Scrollbar {
        return switch (pane) {
            .sidebar => &s.sidebar_bar,
            .history => &s.history_bar,
            .settings => &s.settings_bar,
            .details => &s.details_bar,
            .logs => &s.logs_bar,
            .composer => &s.composer_bar,
            .content => null,
        };
    }
    fn scrollOffset(s: *const App, pane: ScrollPane) f64 {
        return switch (pane) {
            .sidebar => s.sidebar_scroll,
            .history => s.scroll,
            .settings => s.settings_scroll,
            .details => s.details_scroll,
            .logs => s.logs_scroll,
            .composer => s.composer_scroll,
            .content => s.content_detail_scroll,
        };
    }
    fn setScroll(s: *App, pane: ScrollPane, offset: f64) void {
        switch (pane) {
            .sidebar => s.sidebar_scroll = @floatCast(offset),
            .history => {
                s.scroll = offset;
                for (s.controls.items) |control| if (control.action == .scroll and control.action.scroll.pane == .history) {
                    s.following = offset >= s.historyLimit(control.action.scroll.viewport.height) - 1;
                    break;
                };
                s.rememberHistoryAnchor(s.history_rows);
                s.worker.push(.{ .kind = .viewed, .text = if (s.following and desktop.focused()) "yes" else "no" }) catch {};
            },
            .settings => s.settings_scroll = @floatCast(offset),
            .details => s.details_scroll = @floatCast(offset),
            .logs => {
                s.logs_scroll = @floatCast(offset);
                s.logs_follow = s.logs_scroll >= s.logs_limit;
                s.logs_anchor = null;
            },
            .composer => s.composer_scroll = @floatCast(offset),
            .content => s.content_detail_scroll = @floatCast(offset),
        }
    }
    fn moveCaretVertically(s: *App, up: bool, shift: bool) void {
        const editor = s.focusedEditor() orelse return;
        for (s.controls.items) |control| if (control.action == .editor and control.action.editor.focus == s.focus) {
            const width = control.action.editor.width;
            const caret = s.text.caret(editor.text.items, width, editor.caret);
            editor.caret = s.text.hit(editor.text.items, width, caret.x, caret.y + (if (up) -1 else caret.height + 1));
            if (!shift) editor.anchor = editor.caret;
            s.layout_pending = true;
            return;
        };
    }
    fn copyControl(comptime T: type, allocator: std.mem.Allocator, item: T) std.mem.Allocator.Error!T {
        if (T == []const u8) return allocator.dupe(u8, item);
        if (T == [:0]const u8) return allocator.dupeZ(u8, item);
        switch (@typeInfo(T)) {
            .@"struct" => |fields| {
                var result: T = undefined;
                inline for (fields.fields) |field| @field(result, field.name) = try copyControl(field.type, allocator, @field(item, field.name));
                return result;
            },
            .@"union" => return switch (item) {
                inline else => |payload, tag| @unionInit(T, @tagName(tag), try copyControl(@TypeOf(payload), allocator, payload)),
            },
            .type,
            .void,
            .bool,
            .noreturn,
            .int,
            .float,
            .pointer,
            .array,
            .comptime_float,
            .comptime_int,
            .undefined,
            .null,
            .optional,
            .error_union,
            .error_set,
            .@"enum",
            .@"fn",
            .@"opaque",
            .frame,
            .@"anyframe",
            .vector,
            .enum_literal,
            => return item,
        }
    }
    fn activate(s: *App, action: Action) void {
        switch (action) {
            .emoji => |index| if (index) |selected| s.chooseEmoji(selected),
            .editor => |field| {
                s.message_selection.clear();
                s.focus = field.focus;
                const editor = s.focusedEditor() orelse {
                    s.focus = .none;
                    s.syncTextInput();
                    return;
                };
                s.syncTextInput();
                const point = desktop.mouse().subtract(field.origin).add(.{ .x = 0, .y = field.offset });
                const at = s.text.hit(editor.text.items, field.width, point.x, point.y);
                editor.caret = at;
                if (desktop.modifiers() & desktop.c.SDL_KMOD_SHIFT == 0) editor.anchor = at;
                s.dragging = true;
                if (s.doubleTextClick(.{ .field = .{ .focus = field.focus, .revision = editor.revision } }))
                    s.word_drag = s.text.wordHit(editor.text.items, field.width, point.x, point.y);
            },
            .message => |message| {
                const point = desktop.mouse().subtract(message.origin);
                const at = s.text.hit(message.text, message.width, point.x, point.y);
                s.message_selection.begin(message.id, message.pending, message.text, message.full, at) catch {
                    s.info("Could not select message text.");
                    return;
                };
                s.focus = .none;
                s.dragging = false;
                if (s.doubleTextClick(.{ .message = .{
                    .id = std.hash.Wyhash.hash(0, message.id),
                    .text = std.hash.Wyhash.hash(0, message.text),
                    .pending = message.pending,
                } })) s.word_drag = s.text.wordHit(message.text, message.width, point.x, point.y);
                s.info("Double-click a word or drag to select · Ctrl+C to copy · Ctrl+A for the whole message");
            },
            .history_background => s.message_selection.clear(),
            .scroll => {},
            .button => |kind| s.activateButton(kind),
            .recover => |id| s.recoverMessage(id),
            .rail => |icon| switch (icon) {
                .messages, .hidden => {
                    if (s.settings.required) return;
                    s.settings.close();
                    if (s.show_hidden != (icon == .hidden)) s.toggleHidden() catch s.info("Could not switch conversations.");
                    if (s.show_details) s.toggleDetails();
                    s.new_mode = false;
                    s.focus = .composer;
                },
                .settings => s.openSettings() catch s.info("Could not open Settings."),
                .details => s.toggleDetails(),
            },
            .select => |id| s.select(id) catch s.info("Could not open conversation."),
            .retry => |key| if (s.images.entries.getPtr(key)) |entry| {
                ImageCache.retry(entry);
            },
            .link => |link| {
                _ = s.open_link(link);
            },
            .viewer => |photo| {
                const view = s.view orelse return;
                for (view.snapshot.messages) |message| if (u.eq(message.id, photo.message)) {
                    s.openViewer(message, photo.attachment);
                    break;
                };
            },
            .detail => |body| s.showContentDetail(body),
            .reaction => |reaction| {
                s.showContentDetail("");
                s.detail_reaction_message = a.dupe(u8, reaction.message) catch "";
                s.detail_reaction_part = a.dupe(u8, reaction.part) catch "";
                s.detail_reaction_label = a.dupe(u8, reaction.label) catch "";
                s.refreshReactionDetail();
            },
            .enrichment => |section| s.worker.push(.{
                .kind = .enrichment,
                .key = section.message,
                .recipient = section.revision,
                .text = section.section,
            }) catch {},
        }
    }
    fn activateButton(s: *App, kind: ButtonAction) void {
        switch (kind) {
            .recipient_continue => {
                s.startDirect() catch s.info("Could not open conversation.");
            },
            .settings_enter_to_send => {
                s.settings.enter_to_send = !s.settings.enter_to_send;
            },
            .settings_reset => {
                if (s.settings.confirm_reset) {
                    s.resetLocalData() catch |err| {
                        const message = if (err == error.RelayConnectionRequired)
                            "Save valid connection settings and connect before resetting the relay. Local data was kept."
                        else
                            "Could not request a reset. Local data was kept; try again.";
                        s.settings.failure = std.mem.zeroes(bridge.ZcError);
                        @memcpy(s.settings.failure.message[0..message.len], message);
                    };
                } else s.settings.confirm_reset = true;
            },
            .settings_keep_data => {
                s.settings.confirm_reset = false;
            },
            .settings_cancel => {
                s.settings.close();
                s.focus = .composer;
            },
            .settings_save => {
                s.saveSettings() catch s.settingsSaveError();
            },
            .logs_latest => {
                s.logs_follow = true;
            },
            .logs_copy => {
                s.copyLogs();
            },
            .logs_clear => {
                s.logs.clear();
                s.logs_scroll = 0;
                s.logs_follow = true;
                s.logs_anchor = null;
            },
            .conversation_visibility => {
                if (s.view) |view| for (view.snapshot.chats) |chat| {
                    if (u.eq(chat.value.id, s.key)) {
                        s.setSelectedHidden(!chat.hidden) catch s.info("Could not save conversation visibility. Try again.");
                        break;
                    }
                };
            },
            .load_older => {
                s.worker.push(.{ .kind = .older }) catch {};
                s.following = false;
            },
            .new_messages => {
                s.following = true;
                s.new_messages = false;
                s.worker.push(.{ .kind = .viewed, .text = "yes" }) catch {};
            },
            .viewer_close => {
                s.closeViewer();
                return;
            },
            .viewer_previous => {
                s.moveViewer(-1);
            },
            .viewer_next => {
                s.moveViewer(1);
            },
            .content_close => {
                s.closeContentDetail();
                return;
            },
            .attachment_previous => {
                const files = s.draftFiles();
                if (files.len == 0) return;
                s.attachment_index = (s.attachment_index + files.len - 1) % files.len;
            },
            .attachment_next => {
                const files = s.draftFiles();
                if (files.len == 0) return;
                s.attachment_index = (s.attachment_index + 1) % files.len;
            },
            .attachments_cancel => s.fileCommand(.cancel_preparation, s.key, "") catch s.info("Could not cancel file preparation."),
            .attachment_remove => {
                const files = s.draftFiles();
                if (s.attachment_index >= files.len or s.send_wait) return;
                s.fileCommand(.remove_attachment, s.key, files[s.attachment_index].id) catch s.info("Could not remove the attachment.");
            },
            .viewer_retry => {
                const message = s.viewerMessage() orelse return;
                if (s.viewer_attachment >= message.attachments.len) return;
                const item = message.attachments[s.viewer_attachment];
                const asset = item.viewer orelse item.image orelse return;
                const media = s.media orelse return;
                if (s.images.get(media, asset)) |entry| ImageCache.retry(entry);
            },
            .send => s.send() catch s.info("Could not queue message. Your draft is retained."),
            .reconnect => {
                s.worker.push(.{ .kind = .reconnect }) catch {};
                s.send_wait = false;
            },
        }
    }
    fn recoverMessage(s: *App, id: []const u8) void {
        const v = s.view orelse return;
        for (v.snapshot.pending) |p| {
            if (!u.eq(p.input.request_id, id)) continue;
            if (p.input.attachments.len > 0 and u.eq(p.state, "uploading")) {
                s.fileCommand(.cancel_upload, id, "") catch s.info("Could not cancel the upload. Check its status.");
            } else if (s.readOnlyChat()) s.info("This conversation is read-only.") else if (s.composer.text.items.len > 0 or s.draftFiles().len > 0 or v.preparing_attachments or s.filesPending()) s.info("Your composer has a draft. Save or clear it before copying another message.") else {
                s.composer.set(p.input.text) catch return;
                s.draft_dirty = true;
                s.draft_at = 0;
                s.focus = .composer;
                s.duplicate_risk = display.captionMayHaveSent(p.record, p.state);
                if (p.input.attachments.len > 0) s.info("Caption copied. Files remain with the earlier send; drop files into this draft to attach them.");
            }
            return;
        }
    }

    const Focus = enum {
        composer,
        recipient,
        search,
        settings_relay,
        settings_ca,
        settings_cert,
        settings_key,
        none,
    };

    const TextClick = struct {
        target: Target,
        position: graphics.Point,
        time: f64,
        frame: u64,

        const Target = union(enum) {
            field: struct { focus: Focus, revision: u64 },
            message: struct { id: u64, text: u64, pending: bool },
        };

        fn near(click: TextClick, position: graphics.Point) bool {
            const dx = position.x - click.position.x;
            const dy = position.y - click.position.y;
            // Treat clicks within a five-pixel radius as the same target.
            return dx * dx + dy * dy <= 25;
        }

        fn follows(click: TextClick, previous: TextClick) bool {
            const interval = click.time - previous.time;
            // A 400 ms interval permits ordinary double/triple clicks without merging slow clicks.
            return interval >= 0 and interval <= 0.4 and previous.near(click.position) and
                std.meta.eql(click.target, previous.target);
        }
    };

    fn doubleTextClick(s: *App, target: TextClick.Target) bool {
        const click = TextClick{
            .target = target,
            .position = desktop.mouse(),
            .time = s.click_timestamp,
            .frame = s.text.frame,
        };
        const double = if (s.text_click) |previous|
            if (s.click_count == 0) click.follows(previous) else s.click_count > 1 and previous.near(click.position) and std.meta.eql(click.target, previous.target)
        else
            false;
        s.text_click = if (double) null else click;
        return double;
    }

    fn dragTextSelection(
        s: *App,
        text: []const u8,
        width: f32,
        position: graphics.Point,
        anchor: *usize,
        caret: *usize,
    ) void {
        if (s.word_drag) |origin| {
            const word = s.text.wordHit(text, width, position.x, position.y);
            if (word.start < origin.start) {
                anchor.* = origin.end;
                caret.* = word.start;
            } else {
                anchor.* = origin.start;
                caret.* = @max(origin.end, word.end);
            }
        } else caret.* = s.text.hit(text, width, position.x, position.y);
    }

    fn deinit(s: *App) void {
        s.reset_echo.deinit(a);
        s.controls.deinit(a);
        s.control_arena.deinit();
        if (s.input_initialized) desktop.resetTextInput(false);
        s.notifications.deinit();
        s.settings.deinit();
        s.closeContentDetail();
        a.free(s.viewer_message);
        s.images.deinit();
        if (s.captured) |shot| graphics.destroyImage(shot);
        if (s.view) |v| v.destroy();
        s.text.deinit();
        s.heights.deinit(a);
        s.block_heights.deinit(a);
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
        s.layout_pending = true;
        // Keep notices visible for seven seconds so longer errors can be read.
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
        desktop.restore();
        if (!desktop.activate(token)) desktop.raise();
    }
    fn readingConversation(s: *const App) bool {
        return s.pending_key == null and desktop.focused() and !desktop.minimized() and s.following and !s.show_details and !s.settings.visible and !s.new_mode;
    }
    fn deliverNotifications(s: *App) void {
        while (s.worker.takeNotification()) |n| {
            if (s.readingConversation() and u.eq(s.key, n.chat)) {
                n.destroy();
                continue;
            }
            s.notifications.submit(n, s.media, u.now());
        }
        if (s.readingConversation()) {
            const key = a.dupeZ(u8, s.key) catch return;
            defer a.free(key);
            s.notifications.dismiss(key);
        }
        s.notifications.poll(s.media, u.now());
        if (s.media) |media| if (media.take()) |result| {
            defer media.release(result);
            s.notifications.accept(media, result);
            if (result.generation == media.generation) {
                s.images.accept(result);
                s.layout_pending = true;
            }
        };
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
        if (!s.finishPreedit(&s.composer)) return;
        if (s.settings.required) return;
        s.settings.close();
        s.closeViewer();
        s.closeContentDetail();
        s.show_details = false;
        if (s.pending_key == null and u.eq(s.key, key) and u.eq(s.loaded_key, key)) {
            s.focus = .composer;
            s.new_mode = false;
            s.dragging = false;
            return;
        }
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
            if (s.settings.reset_pending) switch (v.reset) {
                .idle, .pending => {},
                .complete => s.finishReset(),
                .failed => {
                    s.settings.reset_pending = false;
                    s.settings.failure = std.mem.zeroes(bridge.ZcError);
                    const message = v.status[0..@min(v.status.len, s.settings.failure.message.len - 1)];
                    @memcpy(s.settings.failure.message[0..message.len], message);
                },
            };
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
        // Debounce draft writes for 300 ms to avoid a database transaction per keystroke.
        if (s.draft_dirty and u.now() - s.draft_at > 300) try s.saveDraft();
        s.handleDrops();
        const reading = s.readingConversation();
        if (s.was_reading == null or reading != s.was_reading.?) {
            s.worker.push(.{ .kind = .viewed, .text = if (reading) "yes" else "no" }) catch return;
            s.was_reading = reading;
        }
        try s.processEvents();
    }
    fn keyInput(s: *App, key: desktop.KeyPress, composing: bool) !void {
        const ctrl = key.modifiers & desktop.c.SDL_KMOD_CTRL != 0;
        const shift = key.modifiers & desktop.c.SDL_KMOD_SHIFT != 0;
        defer s.syncTextInput();
        defer if (s.settings.visible and (key.pressed(.tab) or (!ctrl and (key.pressed(.enter) or key.pressed(.kp_enter))))) s.revealSettingsFocus();
        if (composing and key.pressed(.escape)) {
            if (s.focusedEditor()) |e| {
                s.rememberReset(e);
                e.cancelPreedit();
            }
            desktop.resetTextInput(s.focusedEditor() != null);
            s.layout_pending = true;
            return;
        }
        if (ctrl and key.pressed(.comma)) try s.openSettings();
        if (s.settings.visible) {
            if (key.pressed(.escape)) {
                s.settings.close();
                if (!s.settings.visible) s.focus = .composer;
                return;
            }
            if (!composing and key.pressed(.tab)) {
                const index = s.settingsFocus() orelse 0;
                s.focus = settings_focus[(index + (if (shift) @as(usize, 3) else 1)) % 4];
            }
        } else {
            if (s.viewer_message.len > 0) {
                if (key.pressed(.escape)) s.closeViewer();
                if (key.pressed(.left)) s.moveViewer(-1);
                if (key.pressed(.right)) s.moveViewer(1);
                if (key.pressed(.r)) s.activateButton(.viewer_retry);
                return;
            }
            if (s.detail_body) |body| {
                if (key.pressed(.escape)) {
                    s.closeContentDetail();
                    return;
                }
                if (ctrl and key.pressed(.c)) desktop.setClipboardText(body);
                // Move expanded content in 100-pixel keyboard steps so long text remains navigable.
                if (key.matches(.page_down) or key.matches(.down)) s.content_detail_scroll += 100;
                if (key.matches(.page_up) or key.matches(.up)) s.content_detail_scroll -= 100;
                return;
            }
            s.updateEmojiCompletion();
            if (!composing and !ctrl and s.emoji_completion.visible()) {
                if (key.matches(.tab) or key.matches(.up) or key.matches(.down)) {
                    s.emoji_completion.cycle(key.matches(.up) or (key.matches(.tab) and shift));
                    s.layout_pending = true;
                    return;
                }
                if (!shift and (key.pressed(.enter) or key.pressed(.kp_enter))) {
                    s.chooseEmoji(s.emoji_completion.selected);
                    return;
                }
                if (key.pressed(.escape)) {
                    s.emoji_completion.dismissed = true;
                    s.layout_pending = true;
                    return;
                }
            }
            if (!composing and s.pending_key == null and key.pressed(.tab) and s.rich_count > 0) {
                s.focus = .none;
                const old = s.rich_focus orelse (if (shift) 0 else s.rich_count - 1);
                s.rich_focus = if (shift) (old + s.rich_count - 1) % s.rich_count else (old + 1) % s.rich_count;
            }
            if (!composing and s.focus == .none and key.pressed(.enter)) {
                if (s.rich_focus) |index| for (s.controls.items) |control| {
                    if (control.rich_index == index) {
                        s.activate(control.action);
                        return;
                    }
                };
            }
            if (ctrl and key.pressed(.f) and !s.show_details) {
                s.message_selection.clear();
                s.focus = .search;
            }
            if (ctrl and key.pressed(.d)) s.toggleDetails();
            if (ctrl and key.pressed(.n)) try s.newMessage();
            if (s.show_details) {
                if (key.pressed(.escape)) {
                    s.toggleDetails();
                    return;
                }
                if (s.logs_focused) {
                    if (ctrl and key.matches(.c)) s.copyLogs();
                    var offset = s.logs_scroll;
                    // Diagnostic panes use 160-pixel page steps and 24-pixel line steps.
                    if (key.matches(.page_down)) offset += 160;
                    if (key.matches(.page_up)) offset -= 160;
                    if (key.matches(.down)) offset += 24;
                    if (key.matches(.up)) offset -= 24;
                    if (key.matches(.home)) offset = 0;
                    if (key.matches(.end)) offset = s.logs_limit;
                    if (offset != s.logs_scroll) {
                        s.logs_scroll = std.math.clamp(offset, 0, s.logs_limit);
                        s.logs_follow = s.logs_scroll >= s.logs_limit;
                        s.logs_anchor = null;
                    }
                    return;
                }
                if (key.matches(.page_down)) s.details_scroll += @as(
                    f32,
                    @floatFromInt(desktop.height()),
                ) * 0.7;
                if (key.matches(.page_up)) s.details_scroll -= @as(
                    f32,
                    @floatFromInt(desktop.height()),
                ) * 0.7;
                if (key.matches(.home)) s.details_scroll = 0;
                if (key.matches(.end)) s.details_scroll = s.details_height;
                // Do not route keystrokes to hidden conversation inputs.
                return;
            }
            if (key.pressed(.escape)) {
                s.message_selection.clear();
                s.new_mode = false;
                s.focus = .composer;
            }
        }
        if (s.focus == .composer and s.readOnlyChat()) {
            s.focus = .none;
            s.dragging = false;
        }
        const editor = s.focusedEditor();
        if (editor) |e| {
            const editing_shortcut = ctrl and (key.pressed(.a) or
                key.pressed(.c) or key.pressed(.x) or key.pressed(.v) or
                key.pressed(.z) or key.pressed(.y));
            // Preserve the IME's final Backspace/Enter, even if it cleared preedit
            // in this batch. Explicit clipboard/undo commands first confirm it.
            if (composing and !editing_shortcut) return;
            if (editing_shortcut and !s.finishPreedit(e)) return;
            const revision = e.revision;
            if (ctrl and key.pressed(.a)) {
                e.anchor = 0;
                e.caret = e.text.items.len;
            }
            if (ctrl and (key.pressed(.c) or key.pressed(.x))) {
                if (e.selected().len > 0) {
                    const clip = try a.dupeZ(u8, e.selected());
                    defer a.free(clip);
                    desktop.setClipboardText(clip);
                    if (key.pressed(.x)) try e.insert("");
                }
            }
            if (ctrl and key.pressed(.v)) {
                if (desktop.clipboardText()) |clip| {
                    s.insertText(e, clip) catch s.info("Text exceeds the 16 KiB limit or has invalid encoding.");
                } else s.info("Could not read the clipboard.");
            }
            if (ctrl and key.pressed(.z)) try e.history(shift);
            if (ctrl and key.pressed(.y)) try e.history(true);
            if (key.matches(.up) or key.matches(.down)) s.moveCaretVertically(key.matches(.up), shift);
            if (key.matches(.left)) e.move(-1, shift);
            if (key.matches(.right)) e.move(1, shift);
            if (key.matches(.backspace)) try e.delete(true);
            if (key.matches(.delete)) try e.delete(false);
            if (key.matches(.home)) {
                e.caret = if (ctrl) 0 else lineStart(e.text.items, e.caret);
                if (!shift) e.anchor = e.caret;
            }
            if (key.matches(.end)) {
                e.caret = if (ctrl) e.text.items.len else lineEnd(e.text.items, e.caret);
                if (!shift) e.anchor = e.caret;
            }
            if (key.pressed(.enter) or key.pressed(.kp_enter)) {
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
                if (ctrl and key.pressed(.a)) s.message_selection.selectAll();
                if (ctrl and key.pressed(.c) and s.message_selection.selected().len > 0) {
                    const clip = try a.dupeZ(u8, s.message_selection.selected());
                    defer a.free(clip);
                    desktop.setClipboardText(clip);
                    s.info("Selected text copied");
                }
            }
            // Discard typing while an input is disabled instead of replaying
            // it when a writable conversation gains focus.
        }
    }
    fn insertText(s: *App, editor: *Editor, text: []const u8) Editor.InsertError!void {
        const start = @min(editor.caret, editor.anchor);
        const composing = editor.preedit.items.len > 0;
        try editor.insert(text);
        if (editor == &s.composer and !composing) {
            emoji.expand(editor, start) catch s.info("Could not replace emoji; the shortcode is kept in your draft.");
        }
    }
    fn updateEmojiCompletion(s: *App) void {
        s.emoji_completion.update(&s.composer, s.focusedEditor() == &s.composer);
    }
    fn chooseEmoji(s: *App, index: usize) void {
        s.updateEmojiCompletion();
        const completion = &s.emoji_completion;
        if (!completion.visible() or index >= completion.items.len) return;
        s.composer.replace(completion.range, completion.items[index].text) catch {
            s.info("Could not insert emoji; the draft is unchanged.");
            return;
        };
        completion.* = .{};
        s.draft_dirty = true;
        s.draft_at = u.now();
        s.layout_pending = true;
    }
    fn focusedEditor(s: *App) ?*Editor {
        if (s.settings.visible) return if (s.settingsFocus()) |index| &s.settings.fields[index] else null;
        if (s.show_details or s.viewer_message.len > 0 or s.detail_body != null) return null;
        return switch (s.focus) {
            .composer => if (s.new_mode or s.pending_key != null or s.send_wait or
                !u.eq(s.key, s.loaded_key) or s.readOnlyChat()) null else &s.composer,
            .recipient => if (s.new_mode) &s.recipient else null,
            .search => &s.search,
            .settings_relay, .settings_ca, .settings_cert, .settings_key, .none => null,
        };
    }
    fn finishPreedit(s: *App, e: *Editor) bool {
        if (e.preedit.items.len == 0) return true;
        s.rememberReset(e);
        e.commitPreedit() catch {
            s.info("Could not confirm the composing text. Your draft is retained.");
            return false;
        };
        if (e == &s.composer) {
            s.draft_dirty = true;
            s.draft_at = u.now();
        }
        desktop.resetTextInput(s.focusedEditor() != null);
        s.layout_pending = true;
        return true;
    }
    fn syncTextInput(s: *App) void {
        const next = s.focusedEditor();
        if (s.input_initialized and next == s.input_editor) return;
        if (s.input_editor) |previous| if (!s.finishPreedit(previous)) return;
        desktop.resetTextInput(next != null);
        s.input_editor = next;
        s.input_initialized = true;
        s.layout_pending = true;
    }
    fn rememberReset(s: *App, editor: *const Editor) void {
        if (editor.preedit.items.len == 0) return;
        s.reset_echo.clearRetainingCapacity();
        s.reset_echo.appendSlice(a, editor.preedit.items) catch {};
    }
    fn processEvents(s: *App) !void {
        desktop.poll();
        s.had_input = false;
        if (s.focus == .composer and s.readOnlyChat()) {
            s.focus = .none;
            s.dragging = false;
        }
        s.syncTextInput();
        // A commit/empty preedit can precede the key which confirmed it. Own
        // that next key within this pump, while subsequent keys retain order.
        var composition_key = false;
        while (desktop.nextEvent()) |event| {
            const c = desktop.c;
            s.had_input = true;
            switch (event.type) {
                c.SDL_EVENT_KEY_DOWN => {
                    s.reset_echo.clearRetainingCapacity();
                    const composing = composition_key or if (s.focusedEditor()) |editor| editor.preedit.items.len > 0 else false;
                    composition_key = false;
                    try s.keyInput(.{
                        .code = event.key.key,
                        .modifiers = event.key.mod,
                        .repeat = event.key.repeat,
                    }, composing);
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const committed = if (event.text.text != null) std.mem.span(event.text.text) else "";
                    if (s.reset_echo.items.len > 0) {
                        const echo = u.eq(committed, s.reset_echo.items);
                        s.reset_echo.clearRetainingCapacity();
                        if (echo) continue;
                    }
                    if (s.focusedEditor()) |editor| {
                        composition_key = composition_key or editor.preedit.items.len > 0;
                        const revision = editor.revision;
                        s.insertText(editor, committed) catch {
                            s.info("Text exceeds the 16 KiB limit or has invalid encoding.");
                            editor.cancelPreedit();
                            desktop.resetTextInput(true);
                            continue;
                        };
                        editor.cancelPreedit();
                        if (editor == &s.composer and revision != editor.revision) {
                            s.draft_dirty = true;
                            s.draft_at = u.now();
                        }
                    }
                    s.layout_pending = true;
                },
                c.SDL_EVENT_TEXT_EDITING => {
                    const text = if (event.edit.text != null) std.mem.span(event.edit.text) else "";
                    if (text.len > 0) s.reset_echo.clearRetainingCapacity();
                    if (s.focusedEditor()) |editor| {
                        composition_key = composition_key or editor.preedit.items.len > 0;
                        editor.setPreedit(text, event.edit.start, event.edit.length) catch {
                            s.info("Text exceeds the 16 KiB limit or has invalid encoding.");
                            editor.cancelPreedit();
                            desktop.resetTextInput(true);
                        };
                    }
                    s.layout_pending = true;
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (event.button.button != c.SDL_BUTTON_LEFT) continue;
                    if (event.button.down) {
                        if (s.input_editor) |editor| if (!s.finishPreedit(editor)) continue;
                        s.click_timestamp = if (event.button.timestamp == 0) desktop.time() else @as(f64, @floatFromInt(event.button.timestamp)) / std.time.ns_per_s;
                        s.click_count = event.button.clicks;
                    }
                    s.pointerInput(.{
                        .pressed = event.button.down,
                        .released = !event.button.down,
                        .down = desktop.leftDown(),
                    });
                    s.syncTextInput();
                    s.layout_pending = true;
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    s.pointerInput(.{ .down = desktop.leftDown() });
                    s.layout_pending = true;
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    s.pointerInput(.{ .down = desktop.leftDown(), .wheel = event.wheel.y * @as(f32, if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1) });
                    s.layout_pending = true;
                },
                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    if (s.input_editor) |editor| editor.cancelPreedit();
                    s.pointerInput(.{ .down = false });
                    s.text_click = null;
                    composition_key = false;
                },
                else => {},
            }
        }
    }
    fn revealSettingsFocus(s: *App) void {
        var viewport: ?graphics.Rect = null;
        for (s.controls.items) |control| if (control.action == .scroll and control.action.scroll.pane == .settings) {
            viewport = control.action.scroll.viewport;
            break;
        };
        const clip = viewport orelse return;
        for (s.controls.items) |control| if (control.action == .editor and control.action.editor.focus == s.focus) {
            if (control.bounds.y < clip.y) s.settings_scroll -= clip.y - control.bounds.y;
            if (control.bounds.y + control.bounds.height > clip.y + clip.height) s.settings_scroll += control.bounds.y + control.bounds.height - clip.y - clip.height;
            break;
        };
    }
    fn newMessage(s: *App) !void {
        if (s.settings.required) return;
        if (!s.finishPreedit(&s.composer)) return;
        s.settings.close();
        try s.saveDraft();
        s.message_selection.clear();
        s.show_details = false;
        s.show_hidden = false;
        s.new_mode = true;
        s.focus = .recipient;
    }
    fn startDirect(s: *App) !void {
        if (!s.finishPreedit(&s.recipient)) return;
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
        if (!v.online or s.send_wait or v.preparing_attachments or s.filesPending() or
            s.key.len == 0 or !u.eq(s.loaded_key, s.key)) return false;
        const files = s.draftFiles();
        if (files.len > 0 and !v.send_attachments) return false;
        if (files.len == 0 and std.mem.trim(
            u8,
            s.composer.text.items,
            " \r\n\t",
        ).len == 0 and std.mem.trim(u8, s.composer.preedit.items, " \r\n\t").len == 0) return false;
        if (std.mem.startsWith(u8, s.key, "new:")) return v.send_direct;
        for (v.snapshot.chats) |chat| if (u.eq(chat.value.id, s.key)) {
            if (Store.selfRecipient(chat.value) != null) return v.send_direct;
            return v.reply_existing and chat.value.sendable;
        };
        return false;
    }
    fn draftFiles(s: *const App) []const outgoing_attachments.Upload {
        const v = s.view orelse return &.{};
        return if (u.eq(s.key, v.snapshot.selected)) v.snapshot.draft_attachments else &.{};
    }
    fn filesPending(s: *const App) bool {
        return if (s.view) |v| v.command_serial < s.files_serial else false;
    }
    fn fileCommand(
        s: *App,
        kind: @FieldType(Worker.Command, "kind"),
        key: []const u8,
        text: []const u8,
    ) !void {
        const serial = @max(s.files_serial, if (s.view) |v| v.command_serial else 0) + 1;
        try s.worker.push(.{
            .kind = kind,
            .key = key,
            .text = text,
            .serial = serial,
        });
        s.files_serial = serial;
    }
    fn canAttach(s: *const App) bool {
        return s.pending_key == null and !s.settings.visible and !s.new_mode and !s.show_details and
            s.viewer_message.len == 0 and s.detail_body == null and !s.send_wait and s.key.len > 0 and
            u.eq(s.key, s.loaded_key) and !s.readOnlyChat();
    }
    fn handleDrops(s: *App) void {
        if (drop.rejected()) s.info("Drop up to 16 local files with valid, complete filenames.");
        const files = drop.take() orelse return;
        if (!s.canAttach()) {
            s.info("Select a sendable conversation before dropping files.");
            return;
        }
        s.attachment_index = s.draftFiles().len;
        for (0..@intCast(files.count)) |i| s.fileCommand(.attach, s.key, std.mem.sliceTo(&files.paths[i], 0)) catch {
            s.info("Could not queue every file. Review the attachments, then drop the missing files again.");
            return;
        };
        s.focus = .composer;
    }
    fn send(s: *App) !void {
        if (!s.finishPreedit(&s.composer)) return;
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
    fn redrawAt(s: *App, when: i64) void {
        s.redraw_at = @min(s.redraw_at, when);
    }
    fn redrawAfterGrace(s: *App, timestamp: []const u8, now: i64) void {
        var sent_ms: i64 = undefined;
        if (bridge.zc_timestamp_ms(timestamp.ptr, timestamp.len, &sent_ms) == 0) return;
        const deadline = sent_ms + display.unknown_grace_ms;
        if (deadline > now) s.redrawAt(deadline);
    }
    fn draw(s: *App, scale: f32) void {
        s.redraw_at = std.math.maxInt(i64);
        s.controls.clearRetainingCapacity();
        _ = s.control_arena.reset(.{ .retain_with_limit = 256 * 1024 });
        if (comptime client_options.automation) zrct.beginFrame();
        // Reuse 1 MiB of frame scratch space but release exceptional large-frame allocations.
        defer _ = s.frame_arena.reset(.{ .retain_with_limit = 1024 * 1024 });
        const ar = s.frame_arena.allocator();
        if (s.text.scale != scale) s.text_click = null;
        s.text.nextFrame(scale);
        s.images.nextFrame();
        s.rich_count = 0;
        input_obscured = s.detail_body != null or s.viewer_message.len > 0;
        s.layout_pending = false;
        const areas = layout.frame(
            @floatFromInt(desktop.width()),
            @floatFromInt(desktop.height()),
            s.composerHeight(),
        );
        std.debug.assert(clip_depth == 0);
        graphics.beginFrame();
        defer if (comptime client_options.automation) zrct.endFrame();
        if (comptime client_options.automation) zrct.add(.{
            .id = "window",
            .role = "window",
            .value = std.fmt.allocPrint(ar, "{d}x{d}", .{ desktop.width(), desktop.height() }) catch "",
            .status = if (s.frame_idle) "idle" else "active",
            .bounds = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(desktop.width()),
                .height = @floatFromInt(desktop.height()),
            },
            .interactive = false,
        });
        graphics.clear(theme.colors.paper);
        desktop.setCursor(.default);
        s.drawRail(areas.rail);
        const pane = graphics.Rect{
            .x = areas.sidebar.x,
            .y = 0,
            .width = @as(f32, @floatFromInt(desktop.width())) - areas.sidebar.x,
            .height = @floatFromInt(desktop.height()),
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
                const field = graphics.Rect{
                    .x = r.x + 32,
                    .y = r.y + 110,
                    .width = r.width - 64,
                    .height = 46,
                };
                if (comptime client_options.automation) zrct.add(.{
                    .id = "recipient",
                    .role = "textbox",
                    .label = "Recipient",
                    .bounds = .from(field),
                    .value = s.recipient.text.items,
                });
                s.inputBox(
                    &s.recipient,
                    field,
                    "+1 415 555 0123 or name@example.com",
                    .recipient,
                    false,
                    theme.colors.paper,
                );
                s.button("recipient-continue", .{
                    .x = r.x + 32,
                    .y = r.y + 176,
                    .width = 164,
                    .height = 36,
                }, "Continue", true);
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
            graphics.rectangle(footer, theme.colors.sidebar);
            graphics.line(.{ .x = @trunc(footer.x), .y = @trunc(footer.y) }, .{ .x = @trunc(footer.x + footer.width), .y = @trunc(footer.y) }, 1, theme.colors.line);
            const online = s.view != null and s.view.?.online;
            const activity = s.syncActivity();
            // Fit the bounded combination of active sync labels without allocating each frame.
            var sync_buffer: [96]u8 = undefined;
            const status = if (activity.active()) display.syncLabel(activity, &sync_buffer) else if (online) status: {
                const endpoint = std.Uri.parse(s.worker.config.relay_url) catch break :status "Connected";
                const host = endpoint.host orelse break :status "Connected";
                break :status std.fmt.allocPrint(ar, "Connected to {s}", .{host.percent_encoded}) catch
                    "Connected";
            } else "Offline · drafts saved locally";
            const status_x = footer.x + sidebar_padding + sidebar_text_inset;
            const status_width = footer.x + footer.width - sidebar_padding - status_x;
            const center_y = footer.y + footer.height / 2;
            // Center visible glyphs in the footer, excluding font and texture padding.
            const ink_center_y = s.text.lineInkCenterY(status, 11, status_width);
            const status_y = @round((center_y - ink_center_y) * scale) / scale;
            const icon_center = graphics.Point{
                .x = footer.x + sidebar_padding + sidebar_icon_inset + sidebar_icon_size / 2,
                .y = center_y,
            };
            if (activity.active()) {
                shapes.drawRefresh(icon_center, desktop.time(), theme.colors.muted);
            } else drawStatusDot(icon_center, scale, if (online) theme.colors.success else theme.colors.danger);
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
                s.redrawAt(u.now() + 1000);
                // Reserve 72 pixels so FPS updates do not shift the connection status.
                const fps_width: f32 = 72;
                // Fit the numeric FPS diagnostic and suffix without per-frame allocation.
                var buffer: [32]u8 = undefined;
                const fps = if (s.frame_idle) "Idle" else std.fmt.bufPrint(&buffer, "{d} FPS", .{if (s.frame_seconds > 0) @as(u32, @intFromFloat(@round(1 / s.frame_seconds))) else 0}) catch unreachable;
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
        // Only images used in this frame can require a visible retry.
        var images = s.images.entries.valueIterator();
        while (images.next()) |entry| {
            if (entry.used != s.images.frame) continue;
            if (entry.content == .unavailable and entry.content.unavailable.retry_at > 0)
                s.redrawAt(entry.content.unavailable.retry_at);
        }
        if (s.capture_frame) {
            // Read the completed frame before swapping; Wayland may discard the
            // back buffer afterwards, making post-swap screenshots unreliable.
            graphics.flush();
            if (s.captured) |old| graphics.destroyImage(old);
            s.captured = graphics.capture() catch null;
        }
    }
    fn syncActivity(s: *App) t.SyncActivity {
        const view = s.view orelse return .{};
        var activity = view.sync_activity;
        if (view.online) if (s.media) |media| {
            activity.images = activity.images or media.syncing();
        };
        return activity;
    }

    fn drawStatusDot(center: graphics.Point, scale: f32, color: graphics.Color) void {
        // Keep this six-pixel dot symmetric on the physical pixel grid, with
        // a one-pixel antialiased edge even at fractional display scales.
        const cx = @round(center.x * scale * 2) / 2;
        const cy = @round(center.y * scale * 2) / 2;
        // A six-pixel status dot remains legible without competing with the footer label.
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
                graphics.rectangle(.{
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
        if (s.settings.reset_pending) return;
        if (s.focusedEditor()) |e| if (!s.finishPreedit(e)) return;
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
    fn resetLocalData(s: *App) !void {
        if (s.settings.reset_pending) return;
        if (s.settings.required or (if (s.view) |v| v.cache_unavailable else false)) return error.RelayConnectionRequired;
        try s.worker.push(.{ .kind = .reset });
        s.settings.reset_pending = true;
        s.settings.failure = std.mem.zeroes(bridge.ZcError);
    }
    fn finishReset(s: *App) void {
        var next = s.worker.config;
        next.reset_cache = true;
        next.settings = false;
        next.details = false;
        s.next_config = next;
    }
    fn drawPaneHeader(s: *App, title: []const u8, subtitle: []const u8, r: graphics.Rect) void {
        const x = r.x + 32;
        // Cap form line length at 760 pixels and retain 32-pixel side margins.
        const width = @min(760, r.width - 64);
        s.text.drawLine(title, x, r.y + 22, 25, width, theme.colors.ink, theme.colors.paper);
        s.text.drawLine(subtitle, x, r.y + 58, 15, width, theme.colors.muted, theme.colors.paper);
    }
    fn drawSettings(s: *App, r: graphics.Rect) void {
        const x = r.x + 32;
        // Cap form line length at 760 pixels and retain 32-pixel side margins.
        const width = @min(760, r.width - 64);
        s.drawPaneHeader(
            "Settings",
            if (s.settings.required) "Set up your relay and certificates to continue." else "Connection and message preferences",
            r,
        );
        const helper = "Use absolute paths to your enrolled device credentials. Files must be owned 0600, in private 0700 directories.";
        // Place credential rows after the URL, send preference, and wrapped helper text.
        const paths_y = 144 + s.text.height(helper, 14, width) + 20;
        const failure = std.mem.sliceTo(&s.settings.failure.message, 0);
        // Three credential rows each need 66 pixels for label, input, and spacing.
        const failure_y = paths_y + 3 * 66 + 8;
        const reset_y = failure_y + (if (failure.len > 0)
            s.text.height(failure, 14, width) + 12
        else
            @as(f32, 0)) + 20;
        const reset_help = if (s.settings.reset_pending)
            "Waiting for the relay to confirm its reset. Local data will be cleared after it succeeds."
        else if (s.settings.confirm_reset)
            "Reset the relay for all connected clients, then delete local history, media, drafts and pending-send records? Messages on your Mac, settings and certificates are kept. Relay sends are held for review."
        else
            "Rebuild cached history and media on this device and the relay. Local drafts and pending-send records are removed after the relay confirms. Settings and certificates are kept.";
        const reset_buttons_y = reset_y + 25 + s.text.height(reset_help, 14, width) + 12;
        const content_height = reset_buttons_y + 48;
        const viewport = graphics.Rect{
            .x = x,
            .y = r.y + 98,
            .width = r.width - 48,
            .height = @max(0, r.height - 170),
        };
        if (comptime client_options.automation) zrct.add(.{
            .id = "settings-form",
            .role = "scroll",
            .bounds = .from(viewport),
            .status = failure,
            .interactive = false,
        });
        s.addControl(viewport, .{ .scroll = .{
            .pane = .settings,
            .viewport = viewport,
            .content = content_height,
        } });
        s.settings_scroll = std.math.clamp(
            s.settings_scroll,
            0,
            @max(0, content_height - viewport.height),
        );
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
            }, placeholder, settings_focus[index], false, theme.colors.paper);
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
        s.button("settings-enter-to-send", .{
            .x = x,
            .y = top + 96,
            .width = toggle_size.x,
            .height = toggle_size.y,
        }, toggle_label, false);
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
        s.text.drawLine("Client and relay data", x, top + reset_y, 16, width, theme.colors.ink, theme.colors.paper);
        s.text.draw(reset_help, x, top + reset_y + 25, 14, width, theme.colors.muted, theme.colors.paper);
        const reset_label = if (s.settings.reset_pending) "Resetting…" else if (s.settings.confirm_reset) "Reset and resync" else "Reset client and relay…";
        const reset_size = s.buttonSize(reset_label);
        s.button("settings-reset", .{
            .x = x,
            .y = top + reset_buttons_y,
            .width = reset_size.x,
            .height = reset_size.y,
        }, reset_label, false);
        if (s.settings.confirm_reset and !s.settings.reset_pending) {
            const keep_size = s.buttonSize("Keep local data");
            s.button("settings-keep-data", .{
                .x = x + reset_size.x + 12,
                .y = top + reset_buttons_y,
                .width = keep_size.x,
                .height = keep_size.y,
            }, "Keep local data", false);
        }
        endClip();
        s.settings_bar.draw(viewport, content_height, s.settings_scroll);

        const save_size = s.buttonSize("Save and connect");
        const save = graphics.Rect{
            .x = r.x + r.width - 32 - save_size.x,
            .y = r.y + r.height - 50,
            .width = save_size.x,
            .height = 32,
        };
        if (!s.settings.required) {
            const cancel_size = s.buttonSize("Cancel");
            s.button("settings-cancel", .{
                .x = save.x - 12 - cancel_size.x,
                .y = save.y,
                .width = cancel_size.x,
                .height = save.height,
            }, "Cancel", false);
        }
        s.button("settings-save", save, "Save and connect", true);
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
        s.worker.push(.{ .kind = .viewed, .text = if (!s.show_details and s.following and desktop.focused()) "yes" else "no" }) catch {};
    }
    // Small semibold labels remain distinguishable beneath the navigation icons.
    const rail_label_style = Text.Style{ .size = 10, .weight = .semibold };
    const RailIcon = enum {
        messages,
        hidden,
        settings,
        details,
    };
    // A 40x36 tile centers a roughly 20-pixel icon; 1.5-pixel strokes keep the small glyphs
    // legible.
    fn railItem(s: *App, r: graphics.Rect, label: []const u8, icon: RailIcon, selected: bool) void {
        if (comptime client_options.automation) zrct.add(.{
            .id = @tagName(icon),
            .role = "tab",
            .label = label,
            .bounds = .from(r),
            .selected = selected,
            .enabled = !s.settings.required or icon == .settings,
            .obscured = input_obscured,
        });
        const hot = hover(r);
        const bg = if (selected) theme.colors.selected else if (hot) theme.colors.avatar else theme.colors.rail;
        const tile = graphics.Rect{
            .x = r.x + 12,
            .y = r.y + 3,
            .width = 40,
            .height = 36,
        };
        if (selected or hot) shapes.drawRectangle(tile, 5, bg);
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
                }, 5, 1.5, color);
                graphics.line(
                    .{ .x = x + 4, .y = y + 15 },
                    .{ .x = x + 4, .y = y + 19 },
                    1.5,
                    color,
                );
                graphics.line(
                    .{ .x = x + 4, .y = y + 19 },
                    .{ .x = x + 9, .y = y + 15 },
                    1.5,
                    color,
                );
                graphics.line(.{ .x = x + 5, .y = y + 6 }, .{ .x = x + 15, .y = y + 6 }, 1.5, color);
            },
            .hidden => {
                graphics.outline(.{
                    .x = x,
                    .y = y + 1,
                    .width = 20,
                    .height = 5,
                }, 1.5, color);
                graphics.outline(.{
                    .x = x + 2,
                    .y = y + 6,
                    .width = 16,
                    .height = 12,
                }, 1.5, color);
                graphics.line(
                    .{ .x = x + 7, .y = y + 10 },
                    .{ .x = x + 13, .y = y + 10 },
                    1.5,
                    color,
                );
            },
            .settings => {
                for (0..3) |i| {
                    const row = y + 3 + @as(f32, @floatFromInt(i)) * 7;
                    graphics.line(.{ .x = x, .y = row }, .{ .x = x + 20, .y = row }, 1.5, color);
                    shapes.drawCircle(.{ .x = x + (if (i == 1) @as(f32, 14) else 6), .y = row }, 3, color);
                }
            },
            .details => {
                shapes.drawCircleLines(.{ .x = x + 10, .y = y + 9 }, 10, 1, color);
                shapes.drawCircle(.{ .x = x + 10, .y = y + 4 }, 1, color);
                graphics.line(
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
        if (hot) desktop.setCursor(.pointing_hand);
        if (!s.settings.required or icon == .settings) s.addControl(r, .{ .rail = icon });
    }
    // 62-pixel items pair icon tiles with captions; larger end gaps separate navigation from
    // settings.
    fn drawRail(s: *App, r: graphics.Rect) void {
        graphics.rectangle(r, theme.colors.rail);
        s.railItem(.{
            .x = r.x,
            .y = r.y + 16,
            .width = r.width,
            .height = 62,
        }, "Messages", .messages, !s.show_hidden and !s.show_details and !s.settings.visible);
        s.railItem(.{
            .x = r.x,
            .y = r.y + 86,
            .width = r.width,
            .height = 62,
        }, "Hidden", .hidden, s.show_hidden and !s.show_details and !s.settings.visible);
        s.railItem(.{
            .x = r.x,
            .y = r.y + r.height - 142,
            .width = r.width,
            .height = 62,
        }, "Settings", .settings, s.settings.visible);
        const footer = layout.footer(r);
        const details_size = s.text.lineSizeStyled("Details", rail_label_style, r.width);
        s.railItem(.{
            .x = r.x,
            .y = footer.y + (footer.height - details_size.y) / 2 - 43,
            .width = r.width,
            .height = 62,
        }, "Details", .details, s.show_details and !s.settings.visible);
    }
    // 36 pixels fits a 22-pixel avatar with vertical breathing room.
    const sidebar_row_height: f32 = 36;
    // Eight-pixel margins separate rows and search from the sidebar edge.
    const sidebar_padding: f32 = 8;
    // Align icons with the sidebar's eight-pixel inner margin.
    const sidebar_icon_inset: f32 = 8;
    // 22 pixels keeps avatars recognizable within compact 36-pixel rows.
    const sidebar_icon_size: f32 = 22;
    // Eight-pixel inset plus 22-pixel avatar plus an eight-pixel text gap.
    const sidebar_text_inset: f32 = 38;
    // 30 pixels fits one search line while preserving list space.
    const sidebar_search_height: f32 = 30;
    const sidebar_search_gap: f32 = sidebar_padding;
    const sidebar_header_height = sidebar_padding + sidebar_search_height + sidebar_search_gap;
    // A four-pixel gap separates search from the first conversation row.
    const sidebar_list_gap: f32 = 4;
    fn sidebarViewport(r: graphics.Rect) graphics.Rect {
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
    fn drawSidebar(s: *App, r: graphics.Rect, ar: u.Allocator) void {
        graphics.rectangle(r, theme.colors.sidebar);
        graphics.line(.{ .x = @trunc(r.x + r.width - 1), .y = @trunc(r.y) }, .{ .x = @trunc(r.x + r.width - 1), .y = @trunc(r.y + r.height) }, 1, theme.colors.line);
        const viewport = sidebarViewport(r);
        if (comptime client_options.automation) zrct.add(.{
            .id = "conversations",
            .role = "scroll",
            .bounds = .from(viewport),
            .interactive = false,
            .obscured = input_obscured,
        });
        var clip = viewport;
        clip.width -= Scrollbar.gutter;
        var count: usize = 0;
        if (s.view) |v| for (v.snapshot.chats) |chat| {
            if (s.matchesSidebar(chat)) count += 1;
        };
        const content_height = @as(f32, @floatFromInt(count)) * sidebar_row_height;
        s.addControl(viewport, .{ .scroll = .{
            .pane = .sidebar,
            .viewport = viewport,
            .content = content_height,
        } });
        s.sidebar_scroll = std.math.clamp(
            s.sidebar_scroll,
            0,
            @max(0, content_height - clip.height),
        );
        const selected_key = s.pending_key orelse s.key;
        beginClip(clip);
        var y = clip.y - s.sidebar_scroll;
        if (s.view) |v| {
            // The snapshot is ordered by latest message activity, newest first.
            // Preserve that order across group and direct conversations.
            for (v.snapshot.chats) |chat| {
                if (!s.matchesSidebar(chat)) continue;
                const row = graphics.Rect{
                    .x = clip.x,
                    .y = y,
                    .width = clip.width,
                    .height = sidebar_row_height - 2,
                };
                y += sidebar_row_height;
                if (row.y + row.height < clip.y or row.y > clip.y + clip.height) continue;
                const selected = u.eq(selected_key, chat.value.id) and !s.new_mode and !s.show_details;
                const hot = hover(row) and hover(clip);
                s.addControl(row, .{ .select = chat.value.id });
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
                if (selected or hot) shapes.drawRectangle(row, 4, bg);
                const name = display.label(ar, v.snapshot.directory.conversation(ar, chat.value) catch "Group conversation") catch "…";
                if (comptime client_options.automation) zrct.add(.{
                    .id = std.fmt.allocPrint(ar, "conversation/{s}", .{chat.value.id}) catch "",
                    .role = "row",
                    .label = name,
                    .bounds = .from(row),
                    .clip = .from(clip),
                    .parent = "conversations",
                    .selected = selected,
                    .obscured = input_obscured,
                });
                const avatar = graphics.Rect{
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
                    const badge = graphics.Rect{
                        .x = row.x + row.width - 30,
                        .y = row.y + 8,
                        .width = 24,
                        .height = 19,
                    };
                    const badge_color = if (read_only) theme.colors.muted else theme.colors.accent;
                    shapes.drawRectangle(badge, 5, badge_color);
                    // Cap the badge at 99+ so large unread counts fit its fixed width.
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
                if (hot) desktop.setCursor(.pointing_hand);
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
        const search = graphics.Rect{
            .x = clip.x,
            .y = r.y + sidebar_padding,
            .width = clip.width,
            .height = sidebar_search_height,
        };
        s.inputBox(&s.search, search, "Search conversations", .search, false, theme.colors.sidebar);
        const divider_y = r.y + sidebar_header_height;
        graphics.line(.{ .x = @trunc(search.x), .y = @trunc(divider_y) }, .{ .x = @trunc(search.x + search.width), .y = @trunc(divider_y) }, 1, theme.colors.line);
    }
    fn drawAvatar(s: *App, r: graphics.Rect, name: []const u8, style: theme.Participant, size: i32) void {
        ImageCache.drawAvatar(null, r, style.bubble);
        // Inspect at most 128 bytes of one line to extract a bounded avatar initial.
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
    // An 18-pixel lead-in and 32-pixel heading row distinguish groups from 14-pixel detail values.
    fn detailSection(s: *App, label: []const u8, r: graphics.Rect, y: *f32) void {
        y.* += 18;
        s.text.draw(label, r.x, y.*, 17, r.width, theme.colors.ink, theme.colors.paper);
        y.* += 32;
    }
    // 122 pixels aligns diagnostic values after their short labels.
    const detail_label_width: f32 = 122;
    // Use 12-pixel labels, 14-pixel values, and a ten-pixel row gap for dense but readable
    // diagnostics.
    fn detailRow(s: *App, label: []const u8, value: []const u8, r: graphics.Rect, y: *f32) void {
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
    fn reconnectButton(s: *App, bounds: graphics.Rect, viewport: graphics.Rect) void {
        const hot = hover(bounds);
        const color = if (hot) theme.colors.ink else theme.colors.muted;
        if (hot) {
            desktop.setCursor(.pointing_hand);
            shapes.drawRectangle(bounds, 5, theme.colors.incoming);
            const size = s.buttonSize("Reconnect");
            const tooltip = graphics.Rect{
                .x = @max(viewport.x, @min(bounds.x, viewport.x + viewport.width - size.x)),
                .y = @max(viewport.y, bounds.y - size.y - 6),
                .width = size.x,
                .height = size.y,
            };
            shapes.drawRectangle(tooltip, 4, theme.colors.incoming);
            s.text.drawLineCentered("Reconnect", tooltip, button_font_size, color, theme.colors.incoming);
        }
        // Rasterize the symbol through Pango for smooth edges at the display scale.
        s.text.drawLineCentered("↻", bounds, 22, color, null);
        s.addControl(bounds, .{ .button = .reconnect });
    }
    fn detailStatus(s: *App, r: graphics.Rect, y: *f32) void {
        const status = if (s.view) |v| v.status else "Opening cache…";
        const value_width = @max(1, r.width - detail_label_width - 12 - 30);
        const text_width = s.text.lineSize(status, 14, value_width).x;
        const text_y = y.* + 2;
        s.text.draw("Status", r.x, y.* + 3, 12, detail_label_width - 8, theme.colors.muted, theme.colors.paper);
        s.text.draw(status, r.x + detail_label_width, text_y, 14, value_width, theme.colors.ink, theme.colors.paper);
        s.reconnectButton(.{
            .x = r.x + detail_label_width + text_width + 6,
            .y = text_y + s.text.inkCenterY(status, 14, value_width) - 12,
            .width = 24,
            .height = 24,
        }, r);
        y.* += @max(24, s.text.height(status, 14, value_width) + 4) + 10;
    }
    fn drawDetails(s: *App, r: graphics.Rect, ar: u.Allocator) void {
        // Relative ages and reconnect countdowns have one-second precision.
        s.redrawAt(u.now() + 1000);
        s.drawPaneHeader("Details", "Connection, synchronization and this client", r);
        const viewport = graphics.Rect{
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
        s.addControl(viewport, .{ .scroll = .{
            .pane = .details,
            .viewport = viewport,
            .content = s.details_height,
        } });
        beginClip(clip);
        var y = clip.y - s.details_scroll;
        _ = s.drawLogs(clip, &y, ar);
        s.detailSection("Connection", clip, &y);
        s.detailStatus(clip, &y);
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
            "SDL3 · Pango / Cairo · RGB subpixel (grayscale fallback)",
            clip,
            &y,
        );
        s.detailRow("Display", std.fmt.allocPrint(ar, "{d} × {d} logical · {d} × {d} pixels · {d:.0}% scale", .{
            desktop.width(),
            desktop.height(),
            desktop.pixelWidth(),
            desktop.pixelHeight(),
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
        s.details_height = y - clip.y + s.details_scroll + 12;
        endClip();
        const clamped = std.math.clamp(s.details_scroll, 0, @max(0, s.details_height - clip.height));
        s.layout_pending = s.layout_pending or clamped != s.details_scroll;
        s.details_scroll = clamped;
        s.details_bar.draw(viewport, s.details_height, s.details_scroll);
    }

    fn copyLogs(s: *App) void {
        const copied = s.logs.copy(a) catch return;
        defer a.free(copied);
        desktop.setClipboardText(copied);
    }

    // Keep logs between 120 and 260 pixels tall, with ten-pixel inner padding and 28-pixel actions.
    fn drawLogs(s: *App, r: graphics.Rect, y: *f32, ar: u.Allocator) bool {
        s.detailSection("Logs", r, y);
        const box = graphics.Rect{
            .x = r.x,
            .y = y.*,
            .width = r.width - 16,
            .height = @min(260, @max(120, r.height - 90)),
        };
        const header_y = y.* - 34;
        // Four pixels separates the adjacent log actions without consuming the header width.
        const button_gap = 4;
        const latest_size = s.buttonSize("Latest");
        const copy_size = s.buttonSize("Copy");
        const clear_size = s.buttonSize("Clear");
        const clear_x = box.x + box.width - clear_size.x;
        const copy_x = clear_x - button_gap - copy_size.x;
        s.button("logs-latest", .{
            .x = copy_x - button_gap - latest_size.x,
            .y = header_y,
            .width = latest_size.x,
            .height = 28,
        }, "Latest", false);
        s.button("logs-copy", .{
            .x = copy_x,
            .y = header_y,
            .width = copy_size.x,
            .height = 28,
        }, "Copy", false);
        s.button("logs-clear", .{
            .x = clear_x,
            .y = header_y,
            .width = clear_size.x,
            .height = 28,
        }, "Clear", false);
        y.* += box.height + 26;
        const hot = hover(box);
        // Logs remain available while Details is closed, but hidden rows need
        // no snapshots, text layouts, or textures.
        if (box.y >= r.y + r.height or box.y + box.height <= r.y) return false;
        const entries = s.logs.snapshot(ar) catch return hot;
        if (comptime client_options.automation) zrct.add(.{
            .id = "logs",
            .role = "scroll",
            .bounds = .from(box),
            .clip = .from(r),
            .value = std.fmt.allocPrint(ar, "{d}", .{entries.len}) catch "",
            .status = if (s.logs_follow) "live" else "scrolled_back",
            .interactive = false,
        });
        graphics.rectangle(box, theme.colors.surface);
        graphics.outline(box, 1, if (s.logs_focused) theme.colors.focus else theme.colors.line);
        const viewport = graphics.Rect{
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
        s.addControl(box, .{ .scroll = .{
            .pane = .logs,
            .viewport = viewport,
            .content = total,
        } });
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
        // Fit a localized timezone name and offset in the log footer.
        var zone: [80]u8 = undefined;
        const latest_label = std.fmt.comptimePrint("latest {d} entries", .{LogBuffer.capacity});
        const status = std.fmt.allocPrint(ar, "{s} · {s} · {s}", .{
            if (s.logs_follow) "Live" else "Scrolled back",
            LogBuffer.timeZone(&zone),
            if (s.logs_follow) latest_label else "Latest resumes live updates",
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
    // A 34-pixel avatar and 20/12-pixel title/subtitle fit the shared 64-pixel conversation header.
    fn drawHeader(s: *App, r: graphics.Rect, ar: u.Allocator) void {
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
                title = v.snapshot.directory.conversation(ar, chat.value) catch "Group conversation";
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
            display.label(ar, title) catch "…",
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
            s.button("conversation-visibility", .{
                .x = r.x + r.width - layout.action_right_padding - size.x,
                .y = r.y + 16,
                .width = size.x,
                .height = 30,
            }, label, false);
        }
        graphics.line(.{ .x = @trunc(r.x), .y = @trunc(r.y + r.height) }, .{ .x = @trunc(r.x + r.width), .y = @trunc(r.y + r.height) }, 1, theme.colors.line);
    }
    // Reserve 22 pixels for sender/time metadata before the inter-message gap.
    const message_padding = 22 + layout.message_spacing;
    // 118 pixels leaves room for the uncertain-send recovery action beside status text.
    const recovery_width: f32 = 118;
    const recovery_slot = recovery_width + 8;

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
            // Use one approximate text line until deferred measurement supplies the exact height.
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
            s.block_heights.clearRetainingCapacity();
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
                .padding = message_padding,
                .source_index = i,
                .blocks = prepared.blocks,
            };
        }
        for (snapshot.pending, rows[count..][0..snapshot.pending.len], 0..) |p, *row, i| {
            const text = display.message(ar, p.input.text) catch display.unavailable;
            var message = pendingMessage(p);
            const files = try ar.alloc(t.Attachment, p.input.attachments.len);
            for (files, p.input.attachments) |*item, file| item.* = .{
                .id = file.id,
                .name = file.name,
                .mime_type = file.mime_type,
                .bytes = file.bytes,
            };
            message.attachments = files;
            const blocks = try message_content.prepare(ar, message);
            const key = std.hash.Wyhash.hash(0, if (blocks.len == 0) text else try u.json(ar, message));
            row.* = .{
                .id = p.input.request_id,
                .text = text,
                .key = key,
                .measured = s.heights.get(key),
                .padding = message_padding,
                .pending = true,
                .source_index = i,
                .blocks = blocks,
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
    fn pendingMessage(p: Store.Pending) t.Message {
        return .{
            .id = p.input.request_id,
            .sender = "",
            .direction = .outgoing,
            .service = "imessage",
            .timestamp = p.sent_at,
            .kind = .text,
            .text = p.input.text,
            .decoding = .plain,
            .observed_status = .unknown,
        };
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
        // Reserve the top history strip for the older-messages control and its spacing.
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
    // Measure at most 256 rows per frame so large histories yield to input and rendering.
    const max_height_work = 256;
    fn hasHeightBudget(s: *App) bool {
        // Guarantee progress even when preparing a large snapshot took time.
        return s.height_budget > 0 and (s.height_budget == max_height_work or desktop.ticks() < s.height_deadline);
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
        // Reserve most of a 120 Hz frame for drawing and input. A single synchronous row
        // can overrun the deadline; visible rows still take priority and always make progress.
        s.height_deadline = desktop.ticks() + 2 * std.time.ns_per_ms;
        var anchor = s.historyStart(rows);
        var top = if (anchor < rows.len) rows[anchor].top else s.content_height;
        // The visible block may be deeper than its row's temporary estimate.
        // Resolve the saved row first so it cannot be skipped by the frame budget.
        const at_anchor = anchor < rows.len and rows[anchor].pending == s.anchor_pending and
            u.eq(rows[anchor].id, s.history_anchor);
        if (!s.following and s.history_anchor.len > 0 and !at_anchor) {
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
    fn layoutHistory(s: *App, r: graphics.Rect) ?[]HistoryRow {
        const view = s.view orelse return null;
        if (!u.eq(s.key, view.snapshot.selected)) return null;
        const inner = historyTextWidth(r);
        const rows = s.prepareHistory(inner) catch return null;
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
        if (!reposition and s.history_needs_measurement) {
            s.measureHistory(rows, inner, r.height);
        }
        s.rememberHistoryAnchor(rows);
        return rows;
    }
    fn historyRowY(s: *const App, viewport: graphics.Rect, top: f64) f32 {
        const scale: f64 = s.text.scale;
        // Following history moves with the bottom edge. Round that edge and the
        // distance from it separately, so resizing translates every row equally.
        const pixels = if (s.following)
            @round(@as(f64, viewport.y + viewport.height) * scale) -
                @round((s.content_height - top) * scale)
        else
            @round((@as(f64, viewport.y) + top - s.scroll) * scale);
        return @floatCast(pixels / scale);
    }
    fn drawHistory(s: *App, r: graphics.Rect, ar: u.Allocator) void {
        if (comptime client_options.automation) zrct.add(.{
            .id = "history",
            .role = "scroll",
            .bounds = .from(r),
            .interactive = false,
            .obscured = input_obscured,
            .value = std.fmt.allocPrint(ar, "{d}", .{if (s.view) |v| v.snapshot.messages.len else 0}) catch "",
            .status = if (s.view != null and s.view.?.loading_history) "loading" else "ready",
        });
        const v = s.view orelse return;
        if (!u.eq(s.key, v.snapshot.selected)) return;
        const inner = historyTextWidth(r);
        const rows = s.layoutHistory(r) orelse return;
        var clip = r;
        clip.width -= Scrollbar.gutter;
        s.addControl(clip, .history_background);
        s.addControl(r, .{ .scroll = .{
            .pane = .history,
            .viewport = r,
            .content = s.content_height,
        } });
        beginClip(clip);
        var participants: []const []const u8 = &.{};
        var is_group = false;
        for (v.snapshot.chats) |chat| if (u.eq(chat.value.id, s.key)) {
            participants = chat.value.participants;
            is_group = !chat.value.is_self and participants.len > 1;
            break;
        };
        const empty_history = v.snapshot.messages.len == 0 and v.snapshot.pending.len == 0;
        if (!(empty_history and v.loading_history) and s.scroll < 54 and
            v.snapshot.more and !std.mem.startsWith(u8, s.key, "new:"))
        {
            const y = s.historyRowY(r, 16);
            s.button("load-older", .{
                .x = r.x + r.width / 2 - 86,
                .y = y,
                .width = 172,
                .height = 30,
            }, "Load older messages", false);
        }
        if (empty_history) {
            if (v.loading_history) {
                s.text.drawLineCentered(
                    "Loading history…",
                    r,
                    17,
                    theme.colors.muted,
                    theme.colors.paper,
                );
            } else s.text.draw(
                if (v.online) "The start of something good.\nWrite your first message below." else "No cached messages in this conversation.",
                r.x + 40,
                r.y + 90,
                17,
                r.width - 80,
                theme.colors.muted,
                theme.colors.paper,
            );
        }
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
            // Coalesce visible metadata requests for a quarter second while scrolling.
            s.hydration_at = u.now() + 250;
            if (ids.items.len > 0) s.redrawAt(s.hydration_at);
        } else if (v.online) s.redrawAt(s.hydration_at);
        const status_now = u.now();
        var message_hint: ?MessageHint = null;
        for (rows[visible.start..visible.end]) |row| {
            if (row.pending) continue;
            const m = v.snapshot.messages[row.source_index];
            if (m.direction == .outgoing and m.observed_status == .unknown)
                s.redrawAfterGrace(m.timestamp, status_now);
            const text = row.text;
            const h = row.measured.?;
            // Subtract in double precision before drawing. Accumulating tens
            // of thousands of f32 heights caused visible fractional-DPI drift.
            const y = s.historyRowY(r, row.top);
            if (comptime client_options.automation) {
                const status = display.messageStatus(m, is_group, status_now);
                zrct.add(.{
                    .id = std.fmt.allocPrint(ar, "message/{s}", .{row.id}) catch "",
                    .role = "message",
                    .label = row.text,
                    .bounds = .{
                        .x = r.x + 66,
                        .y = y,
                        .width = inner,
                        .height = row.height(),
                    },
                    .clip = .from(clip),
                    .parent = "history",
                    .interactive = false,
                    .status = switch (status) {
                        .checks => |checks| @tagName(checks),
                        .label => |label| label,
                        .none => "",
                    },
                });
            }
            const outgoing = m.direction == .outgoing;
            const style = if (outgoing) theme.Participant{ .bubble = theme.colors.selected, .label = theme.colors.focus } else theme.participant(
                m.sender,
                participants,
            );
            if (y + row.height() >= r.y and y < r.y + r.height) {
                const hover_padding = (row.padding - 22) / 2;
                const bounds = graphics.Rect{
                    .x = r.x,
                    .y = y - hover_padding,
                    .width = clip.width,
                    .height = row.height(),
                };
                const bg = if (hover(bounds)) theme.colors.surface else theme.colors.paper;
                if (hover(bounds)) graphics.rectangle(bounds, bg);
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
                ) catch "…";
                if (s.drawMessageHeader(
                    name,
                    localTime(ar, m.timestamp, false),
                    display.messageStatus(m, is_group, status_now),
                    .{
                        .x = x,
                        .y = y,
                        .width = inner - (if (outgoing) recovery_slot else @as(f32, 0)),
                    },
                    if (outgoing) theme.colors.ink else style.label,
                    bg,
                )) |hint| message_hint = hint;
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
                }, theme.colors.ink, bg, ar);
            }
        }
        for (rows[visible.start..visible.end]) |row| {
            if (!row.pending) continue;
            const p = v.snapshot.pending[row.source_index];
            if (!u.eq(p.state, "uploading") and !u.eq(p.state, "delivered") and
                !display.canCopyPending(p.state, p.sent_at, status_now))
                s.redrawAfterGrace(p.sent_at, status_now);
            const h = row.measured.?;
            const y = s.historyRowY(r, row.top);
            const x = r.x + 66;
            if (comptime client_options.automation) zrct.add(.{
                .id = std.fmt.allocPrint(ar, "message/{s}", .{row.id}) catch "",
                .role = "message",
                .label = row.text,
                .bounds = .{
                    .x = x,
                    .y = y,
                    .width = inner,
                    .height = row.height(),
                },
                .clip = .from(clip),
                .parent = "history",
                .interactive = false,
                .status = p.state,
            });
            const needs_recovery = display.canCopyPending(p.state, p.sent_at, status_now);
            const style: theme.Participant = if (needs_recovery)
                .{ .bubble = theme.colors.incoming, .label = theme.colors.muted }
            else
                .{ .bubble = theme.colors.selected, .label = theme.colors.focus };
            const foreground = if (needs_recovery) theme.colors.muted else theme.colors.ink;
            if (y + row.height() >= r.y and y < r.y + r.height) {
                s.drawAvatar(.{
                    .x = r.x + 20,
                    .y = y,
                    .width = 34,
                    .height = 34,
                }, "You", style, 17);
                const status = if (u.eq(p.state, "uploading") and u.eq(v.upload.request_id, p.input.request_id))
                    std.fmt.allocPrint(ar, "Uploading {d}% · {s}", .{
                        if (v.upload.total == 0) 0 else @min(100, v.upload.bytes * 100 / v.upload.total),
                        display.label(ar, v.upload.filename) catch "…",
                    }) catch "Uploading…"
                else
                    display.pendingStatus(ar, p.state, p.detail, p.sent_at, status_now) catch "Status unavailable";
                if (s.drawMessageHeader(
                    "You",
                    localTime(ar, p.sent_at, false),
                    .{ .label = status },
                    .{
                        .x = x,
                        .y = y,
                        .width = inner - recovery_slot,
                    },
                    foreground,
                    theme.colors.paper,
                )) |hint| message_hint = hint;
                const body = graphics.Rect{
                    .x = x,
                    .y = y + 22,
                    .width = inner,
                    .height = h,
                };
                if (row.blocks.len == 0) {
                    s.drawMessageText(row, p.input.text, body, foreground, theme.colors.paper);
                } else s.drawBlocks(row, pendingMessage(p), body, foreground, theme.colors.paper, ar);
                const can_cancel = p.input.attachments.len > 0 and u.eq(p.state, "uploading");
                const recovery_id = if (comptime client_options.automation)
                    std.fmt.allocPrint(ar, "message/{s}/recover", .{row.id}) catch ""
                else
                    "";
                if (can_cancel or (needs_recovery and p.input.text.len > 0)) s.actionButton(recovery_id, .{
                    .x = x + inner - recovery_width,
                    .y = y - 3,
                    .width = recovery_width,
                    .height = 22,
                }, if (can_cancel) "Cancel upload" else if (p.input.attachments.len > 0) "Copy caption" else "Copy to draft", false, .{ .recover = p.input.request_id });
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
        if (!s.following and s.new_messages) s.button("new-messages", .{
            .x = r.x + r.width / 2 - 74,
            .y = r.y + r.height - 42,
            .width = 148,
            .height = 32,
        }, "New messages ↓", true);
        if (message_hint) |hint| s.drawMessageHint(hint, clip);
    }
    fn drawPeerAvatar(
        s: *App,
        r: graphics.Rect,
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
                ImageCache.drawAvatar(texture, r, graphics.Color.white);
                return;
            };
        };
        s.drawAvatar(r, name, style, size);
    }
    fn drawAsset(s: *App, asset: t.AssetRef, r: graphics.Rect, chat: []const u8) void {
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
            const label = entry.reason();
            s.text.draw(
                display.prefix(if (label.len > 0) label else "Loading photo…", 256, 3),
                r.x + 8,
                r.y + 8,
                12,
                @max(1, r.width - 16),
                theme.colors.muted,
                theme.colors.incoming,
            );
            if (s.viewer_message.len == 0 and r.width >= 140 and r.height >= 70 and entry.canRetry()) {
                const retry_rect = graphics.Rect{
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
                s.richControl(retry_rect, .{ .retry = media.key(asset) });
            }
            if (entry.takeRefresh()) {
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
    // 24-pixel side margins and 65-pixel top/bottom bands keep image content clear of viewer
    // controls.
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
        const w: f32 = @floatFromInt(desktop.width());
        const h: f32 = @floatFromInt(desktop.height());
        graphics.rectangle(.{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
        }, theme.colors.paper);
        s.text.drawLine(
            display.label(ar, item.name) catch "…",
            24,
            20,
            16,
            w - 160,
            theme.colors.ink,
            theme.colors.paper,
        );
        s.button("viewer-close", .{
            .x = w - 100,
            .y = 12,
            .width = 80,
            .height = 32,
        }, "Close", false);
        const image_r = graphics.Rect{
            .x = 24,
            .y = 65,
            .width = w - 48,
            .height = h - 130,
        };
        s.drawAsset(asset, image_r, m.conversation_id);
        if (comptime client_options.automation) zrct.add(.{
            .id = "viewer-image",
            .role = "image",
            .label = item.name,
            .value = item.id,
            .bounds = .from(image_r),
            .interactive = false,
            .status = if (s.media) |media| if (s.images.entries.getPtr(media.key(asset))) |entry|
                @tagName(entry.content)
            else
                "pending" else "unavailable",
        });
        s.button("viewer-previous", .{
            .x = 24,
            .y = h - 52,
            .width = 120,
            .height = 32,
        }, "← Previous", false);
        s.button("viewer-next", .{
            .x = w - 144,
            .y = h - 52,
            .width = 120,
            .height = 32,
        }, "Next →", false);
        if (s.media) |media| if (s.images.get(media, asset)) |entry| if (entry.availableTexture() == null and entry.canRetry()) {
            s.button("viewer-retry", .{
                .x = w / 2 - 50,
                .y = h - 52,
                .width = 100,
                .height = 32,
            }, "Retry", false);
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
    // Use a 320x200 placeholder; cap photos at 480x320 with a 32-pixel minimum hit area.
    fn imageSize(asset: ?t.AssetRef, width: f32) graphics.Point {
        const w: f32 = if (asset) |v| @floatFromInt(v.width orelse 320) else 320;
        const h: f32 = if (asset) |v| @floatFromInt(v.height orelse 200) else 200;
        const scale = @min(@min(@min(width, 480) / @max(1, w), 320 / @max(1, h)), 1);
        return .{ .x = @max(32, w * scale), .y = @max(32, h * scale) };
    }
    // Missing dimensions use the relay's 1024/2560 inline/viewer derivative bounds.
    fn inlineAsset(item: t.Attachment, size: graphics.Point, scale: f32) ?t.AssetRef {
        const inline_image = item.image orelse return null;
        const viewer = item.viewer orelse return inline_image;
        const w: f32 = @floatFromInt(inline_image.width orelse 1024);
        const h: f32 = @floatFromInt(inline_image.height orelse 1024);
        // Reuse the existing larger variant at high DPI; layout stays anchored
        // to the inline descriptor and there are still only two cached variants.
        if (viewer.availability != .retired and (size.x * scale > w or size.y * scale > h) and ((viewer.width orelse 2560) > (inline_image.width orelse 1024) or (viewer.height orelse 2560) > (inline_image.height orelse 1024))) return viewer;
        return inline_image;
    }
    // Keep these heights aligned with drawBlocks: 28-pixel link rows, 32-pixel chip rows,
    // 48-pixel file cards, and a three-line (54-pixel) optional preview summary.
    fn blockHeight(s: *App, block: message_content.Block, width: f32, visible: bool) f32 {
        switch (block.value) {
            .attachment => |item| return if (item.image != null) imageSize(item.image, width).y + 28 else 48,
            .card => |card| return 76 + (if (card.summary != null) @as(f32, 54) else 0) + (if (card.image) |asset| imageSize(
                asset,
                width - 24,
            ).y + 8 else 0),
            .more => return 30,
            .text, .reactions => {},
        }
        var hash = std.hash.Wyhash.init(@intFromEnum(std.meta.activeTag(block.value)));
        hash.update(std.mem.asBytes(&width));
        hash.update(std.mem.asBytes(&s.text.scale));
        switch (block.value) {
            .text => |value| {
                hash.update(value);
                hash.update(std.mem.asBytes(&block.links.len));
            },
            .reactions => |chips| for (chips) |chip| {
                hash.update(std.mem.asBytes(&chip.label.len));
                hash.update(chip.label);
                hash.update(std.mem.asBytes(&chip.actors.len));
            },
            // Fixed-size blocks returned above; only text-dependent heights need caching.
            .attachment, .card, .more => unreachable,
        }
        const key = hash.final();
        if (s.block_heights.get(key)) |height| return height;
        const height = switch (block.value) {
            .text => |value| (if (visible) s.text.height(value, 16, width) else s.text.measure(
                value,
                16,
                width,
            )) + @as(
                f32,
                @floatFromInt(block.links.len),
            ) * 28,
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
            .attachment, .card, .more => unreachable,
        };
        s.block_heights.put(a, key, height) catch {};
        return height;
    }
    fn chipWidth(s: *App, label: []const u8, width: f32) f32 {
        return @min(width, s.text.lineSize(label, 15, @max(1, width - 16)).x + 16);
    }
    fn richControl(s: *App, r: graphics.Rect, action: Action) void {
        const index = s.rich_count;
        s.rich_count += 1;
        const focused = s.focus == .none and s.rich_focus == index;
        if (focused) graphics.outline(r, 1, theme.colors.focus);
        if (input_obscured or s.detail_body != null or s.viewer_message.len > 0) return;
        if (comptime client_options.automation) {
            const ar = s.frame_arena.allocator();
            const target: ?zrct.Target = switch (action) {
                .viewer => |item| .{
                    .id = std.fmt.allocPrint(ar, "message/{s}/attachment/{s}", .{ item.message, item.attachment }) catch "",
                    .role = "button",
                    .label = "Open image",
                    .parent = std.fmt.allocPrint(ar, "message/{s}", .{item.message}) catch "",
                    .bounds = .from(r),
                },
                .reaction => |item| .{
                    .id = std.fmt.allocPrint(ar, "message/{s}/reaction/{s}/{s}", .{
                        item.message,
                        item.part,
                        item.label,
                    }) catch "",
                    .role = "button",
                    .label = item.label,
                    .parent = std.fmt.allocPrint(ar, "message/{s}", .{item.message}) catch "",
                    .bounds = .from(r),
                },
                .button,
                .recover,
                .rail,
                .select,
                .retry,
                .link,
                .detail,
                .enrichment,
                .editor,
                .emoji,
                .message,
                .scroll,
                .history_background,
                => null,
            };
            if (target) |value| {
                var clipped = value;
                clipped.clip = if (clip_depth > 0) .from(clip_stack[clip_depth - 1]) else null;
                zrct.add(clipped);
            }
        }
        if (hover(r)) desktop.setCursor(.pointing_hand);
        const before = s.controls.items.len;
        s.addControl(r, action);
        if (s.controls.items.len > before) s.controls.items[before].rich_index = index;
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
        bounds: graphics.Rect,
        foreground: graphics.Color,
        bg: graphics.Color,
        ar: u.Allocator,
    ) void {
        var y = bounds.y;
        for (row.blocks) |block| {
            const h = s.blockHeight(block, bounds.width, true);
            const r = graphics.Rect{
                .x = bounds.x,
                .y = y,
                .width = bounds.width,
                .height = h,
            };
            y += h + 8;
            if (clip_depth > 0) {
                const viewport = clip_stack[clip_depth - 1];
                // Prefetch within 200 pixels of the viewport so nearby images can be ready after
                // scrolling.
                if (r.y + r.height < viewport.y - 200 or r.y > viewport.y + viewport.height + 200) continue;
            }
            switch (block.value) {
                .text => |value| {
                    var part_row = row;
                    part_row.text = value;
                    const text_h = h - @as(f32, @floatFromInt(block.links.len)) * 28;
                    s.drawMessageText(part_row, m.text orelse block.source_text orelse value, .{
                        .x = r.x,
                        .y = r.y,
                        .width = r.width,
                        .height = text_h,
                    }, foreground, bg);
                    for (block.links, 0..) |link, i| {
                        const link_r = graphics.Rect{
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
                        s.richControl(link_r, .{ .link = link });
                    }
                },
                .attachment => |item| {
                    if (row.pending) {
                        const p = s.view.?.snapshot.pending[row.source_index];
                        for (p.input.attachments) |file| if (u.eq(file.id, item.id)) {
                            s.drawLocalFile(file, r, display.attachmentStatus(p.record, file.id), bg, ar);
                            break;
                        };
                        continue;
                    }
                    if (item.image) |asset| {
                        const size = imageSize(asset, r.width);
                        const image_r = graphics.Rect{
                            .x = r.x,
                            .y = r.y,
                            .width = size.x,
                            .height = size.y,
                        };
                        shapes.drawRectangle(image_r, 6, theme.colors.incoming);
                        s.richControl(image_r, .{ .viewer = .{ .message = m.id, .attachment = item.id } });
                        s.drawAsset(
                            inlineAsset(item, size, s.text.scale).?,
                            image_r,
                            m.conversation_id,
                        );
                        s.text.drawLine(
                            if (asset.still_preview) "Still preview" else display.label(ar, item.name) catch "…",
                            r.x,
                            r.y + size.y + 5,
                            12,
                            r.width,
                            theme.colors.muted,
                            bg,
                        );
                    } else {
                        s.text.drawLine(
                            display.label(ar, item.name) catch "…",
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
                    shapes.drawRectangle(r, 6, theme.colors.incoming);
                    const link = link_targets.target(ar, card) catch null;
                    var top = r.y + 10;
                    if (card.image) |asset| {
                        const size = imageSize(asset, r.width - 24);
                        const image_r = graphics.Rect{
                            .x = r.x + 12,
                            .y = top,
                            .width = size.x,
                            .height = size.y,
                        };
                        graphics.rectangle(image_r, theme.colors.avatar);
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
                        display.label(ar, card.title orelse "Shared link") catch "…",
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
                            // Limit card summaries to 2 KiB and three lines so cards remain
                            // compact.
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
                    s.richControl(r, if (link) |target| .{ .link = target } else .{
                        .detail = card.original_url orelse card.metadata_url orelse "Stored link metadata is unavailable",
                    });
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
                        const chip_r = graphics.Rect{
                            .x = x,
                            .y = top,
                            .width = w,
                            .height = 28,
                        };
                        shapes.drawRectangle(chip_r, 8, theme.colors.incoming);
                        s.text.drawLineCentered(label, .{
                            .x = x + 8,
                            .y = top,
                            .width = @max(1, w - 16),
                            .height = chip_r.height,
                        }, 15, theme.colors.ink, theme.colors.incoming);
                        s.richControl(chip_r, .{ .reaction = .{
                            .message = m.id,
                            .part = block.part_id orelse "",
                            .label = chip.label,
                        } });
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
                    s.richControl(r, .{ .enrichment = .{
                        .message = m.id,
                        .revision = m.revision,
                        .section = @tagName(section),
                    } });
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
    // An 80%-sized panel leaves 10% margins; alpha 190 dims the conversation without hiding it.
    fn drawContentDetail(s: *App) void {
        const body = s.detail_body orelse return;
        const width: f32 = @floatFromInt(desktop.width());
        const height: f32 = @floatFromInt(desktop.height());
        graphics.rectangle(.{
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
        const r = graphics.Rect{
            .x = width * 0.1,
            .y = height * 0.1,
            .width = width * 0.8,
            .height = height * 0.8,
        };
        shapes.drawRectangle(r, 8, theme.colors.paper);
        s.button("content-close", .{
            .x = r.x + r.width - 90,
            .y = r.y + 10,
            .width = 80,
            .height = 30,
        }, "Close", false);
        const viewport = graphics.Rect{
            .x = r.x + 20,
            .y = r.y + 52,
            .width = r.width - 40,
            .height = r.height - 72,
        };
        const content_height = s.text.height(body, 16, viewport.width);
        if (comptime client_options.automation) zrct.add(.{
            .id = "content-detail",
            .role = "text",
            .value = body,
            .bounds = .from(viewport),
            .interactive = false,
        });
        s.addControl(viewport, .{ .scroll = .{
            .pane = .content,
            .viewport = viewport,
            .content = content_height,
        } });
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
    const MessageHint = struct { bounds: graphics.Rect, text: []const u8 };

    // Return hover details so they can be drawn above the completed timeline.
    fn drawMessageHeader(
        s: *App,
        name: []const u8,
        stamp: []const u8,
        status: display.MessageStatus,
        r: struct { x: f32, y: f32, width: f32 },
        foreground: graphics.Color,
        background: graphics.Color,
    ) ?MessageHint {
        // Give the sender at most 55% of the row, leaving space for time and delivery status.
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
        // Status length must not change the timestamp's width or position.
        const stamp_width = @max(1, meta_width - 28);
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
                const bounds = graphics.Rect{
                    .x = status_x - 3,
                    .y = status_y - 3,
                    .width = 26,
                    .height = 18,
                };
                if (checks == .group_sent and hover(bounds)) return .{
                    .bounds = bounds,
                    .text = "Sent · group delivery receipts unavailable.",
                };
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
                const bounds = graphics.Rect{
                    .x = status_x,
                    .y = r.y,
                    .width = width,
                    .height = 20,
                };
                if (hover(bounds) and s.text.lineSize(label, 11, width + 32).x > width)
                    return .{ .bounds = bounds, .text = label };
            },
        }
        return null;
    }
    // Draw checks within a 20x12 box using a 1.5-pixel stroke; dotted tips mark partial delivery.
    fn drawDeliveryChecks(x: f32, y: f32, checks: display.MessageStatus.Checks) void {
        // Neutral checks indicate transport status; the relay has no read receipts.
        const color = theme.colors.muted;
        graphics.line(.{ .x = x + 1, .y = y + 6 }, .{ .x = x + 5, .y = y + 10 }, 1.5, color);
        graphics.line(.{ .x = x + 5, .y = y + 10 }, .{ .x = x + 13, .y = y + 2 }, 1.5, color);
        switch (checks) {
            .sent => {},
            .group_sent => {
                const dots = [_]graphics.Point{
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
                graphics.line(.{ .x = x + 9, .y = y + 8 }, .{ .x = x + 11, .y = y + 10 }, 1.5, color);
                graphics.line(.{ .x = x + 11, .y = y + 10 }, .{ .x = x + 19, .y = y + 2 }, 1.5, color);
            },
        }
    }
    // Cap tooltips at 420 pixels, with 10x6 padding, so recovery explanations fit inside history.
    fn drawMessageHint(s: *App, hint: MessageHint, viewport: graphics.Rect) void {
        const anchor = hint.bounds;
        const label = hint.text;
        const size = s.text.lineSize(label, 12, @max(1, @min(420, viewport.width - 32)));
        const width = size.x + 20;
        const height = @min(s.text.height(label, 12, size.x) + 12, viewport.height - 12);
        const above = anchor.y - height - 6;
        const bounds = graphics.Rect{
            .x = std.math.clamp(anchor.x, viewport.x + 6, viewport.x + viewport.width - width - 6),
            .y = std.math.clamp(
                if (above >= viewport.y + 6) above else anchor.y + anchor.height + 6,
                viewport.y + 6,
                @max(viewport.y + 6, viewport.y + viewport.height - height - 6),
            ),
            .width = width,
            .height = height,
        };
        shapes.drawRectangle(bounds, 4, theme.colors.incoming);
        shapes.drawRectangleLines(bounds, 4, 1, theme.colors.line);
        beginClip(bounds);
        s.text.draw(label, bounds.x + 10, bounds.y + 6, 12, size.x, theme.colors.ink, theme.colors.incoming);
        endClip();
    }
    // Reserve 90 pixels for avatar/margins and keep at least 80 pixels for text layout.
    fn historyTextWidth(r: graphics.Rect) f32 {
        return @max(80, r.width - 90);
    }
    fn drawMessageText(
        s: *App,
        row: HistoryRow,
        full: []const u8,
        bounds: graphics.Rect,
        color: graphics.Color,
        background: graphics.Color,
    ) void {
        const x = bounds.x;
        const y = bounds.y;
        const width = bounds.width;
        const hot = hover(bounds);
        const selection = &s.message_selection;
        if (hot) desktop.setCursor(.ibeam);
        s.addControl(bounds, .{ .message = .{
            .id = row.id,
            .pending = row.pending,
            .text = row.text,
            .full = full,
            .origin = .{ .x = x, .y = y },
            .width = width,
        } });
        const active = s.focus == .none and selection.matches(row.id, row.pending, row.text);
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
    // Reserve 80 pixels for the file selector/card and 28 more while preparation is in progress.
    fn attachmentsHeight(s: *const App) f32 {
        if (s.key.len == 0 or s.new_mode) return 0;
        const preparing = if (s.view) |v| v.preparing_draft else false;
        return (if (s.draftFiles().len > 0) @as(f32, 80) else 0) +
            (if (preparing or s.filesPending()) @as(f32, 28) else 0);
    }
    fn drawDraftFiles(s: *App, bounds: graphics.Rect, ar: u.Allocator) void {
        var top = bounds.y;
        const preparing = if (s.view) |v| v.preparing_draft else false;
        if (preparing or s.filesPending()) {
            s.text.drawLine(
                if (preparing) "Preparing files…" else "Updating attachments…",
                bounds.x,
                top + 3,
                12,
                bounds.width - 86,
                theme.colors.muted,
                theme.colors.paper,
            );
            if (preparing) s.button("attachments-cancel", .{
                .x = bounds.x + bounds.width - 78,
                .y = top,
                .width = 78,
                .height = 22,
            }, "Cancel", false);
            top += 28;
        }
        const files = s.draftFiles();
        if (files.len == 0) return;
        s.attachment_index = @min(s.attachment_index, files.len - 1);
        s.text.drawLine(
            std.fmt.allocPrint(ar, "Attachment {d} of {d}", .{ s.attachment_index + 1, files.len }) catch "Attachments",
            bounds.x,
            top + 3,
            12,
            bounds.width - 80,
            theme.colors.muted,
            theme.colors.paper,
        );
        if (files.len > 1) {
            s.button("attachment-previous", .{
                .x = bounds.x + bounds.width - 66,
                .y = top,
                .width = 30,
                .height = 22,
            }, "←", false);
            s.button("attachment-next", .{
                .x = bounds.x + bounds.width - 30,
                .y = top,
                .width = 30,
                .height = 22,
            }, "→", false);
        }
        const file = files[s.attachment_index];
        if (comptime client_options.automation) zrct.add(.{
            .id = "draft-attachments",
            .role = "group",
            .label = file.name,
            .value = std.fmt.allocPrint(ar, "{d}", .{files.len}) catch "",
            .bounds = .from(bounds),
            .interactive = false,
            .obscured = input_obscured,
        });
        const card = graphics.Rect{
            .x = bounds.x,
            .y = top + 25,
            .width = bounds.width - 82,
            .height = 48,
        };
        s.drawLocalFile(file, card, "Saved in draft", theme.colors.paper, ar);
        if (!s.send_wait) s.button("attachment-remove", .{
            .x = bounds.x + bounds.width - 76,
            .y = card.y + 10,
            .width = 76,
            .height = 28,
        }, "Remove", false);
    }
    // A 48-pixel thumbnail fits two text rows; the 58-pixel text inset leaves a ten-pixel gap.
    fn drawLocalFile(
        s: *App,
        file: outgoing_attachments.Upload,
        bounds: graphics.Rect,
        status: []const u8,
        background: graphics.Color,
        ar: u.Allocator,
    ) void {
        const thumb = graphics.Rect{
            .x = bounds.x,
            .y = bounds.y,
            .width = 48,
            .height = 48,
        };
        shapes.drawRectangle(thumb, 6, theme.colors.incoming);
        const preview = preview: {
            if (std.mem.startsWith(u8, file.mime_type, "image/")) if (s.media) |media| {
                if (s.images.getLocal(media, file)) |entry| break :preview entry.availableTexture();
            };
            break :preview null;
        };
        if (preview) |texture| {
            ImageCache.draw(texture, thumb);
        } else {
            s.text.drawLine(
                "File",
                thumb.x + 10,
                thumb.y + 16,
                11,
                38,
                theme.colors.muted,
                theme.colors.incoming,
            );
        }
        s.text.drawLine(
            display.label(ar, file.name) catch "…",
            bounds.x + 58,
            bounds.y + 3,
            14,
            @max(1, bounds.width - 58),
            theme.colors.ink,
            background,
        );
        s.text.drawLine(
            std.fmt.allocPrint(ar, "{s} bytes · {s}", .{ file.bytes, status }) catch status,
            bounds.x + 58,
            bounds.y + 27,
            11,
            @max(1, bounds.width - 58),
            theme.colors.muted,
            background,
        );
    }
    fn composerHeight(s: *App) f32 {
        // Ag includes ascender and descender; width 400 prevents wrapping the line-height probe.
        const one_line = s.text.height("Ag", 16, 400);
        var height = one_line;
        if (!s.readOnlyChat() and s.key.len > 0 and !s.new_mode) {
            const pane = graphics.Rect{
                .x = 0,
                .y = 0,
                .width = layout.conversationWidth(@floatFromInt(desktop.width())),
                .height = 0,
            };
            const editor = composerEditor(composerBox(pane));
            // Match the editor's wrapping width, including its scrollbar gutter.
            const width = editor.width - 22 - Scrollbar.gutter;
            var buffer: [t.max_text]u8 = undefined;
            const visible = s.composer.display(&buffer);
            const caret = s.text.caret(visible.text, width, visible.caret);
            const content_height = @max(
                s.text.height(visible.text, 16, width),
                caret.y + caret.height,
            );
            // Show at most three composer lines before scrolling to preserve conversation space.
            height = std.math.clamp(content_height, one_line, s.text.height("Ag\nAg\nAg", 16, 400));
        }
        // Round up so fractional layout arithmetic cannot scroll a fitting draft.
        return @ceil(height) + 22 + layout.composer_top_padding + layout.footer_height + s.attachmentsHeight();
    }
    fn composerBox(r: graphics.Rect) graphics.Rect {
        return .{
            .x = r.x + layout.conversation_padding,
            // The outline extends one pixel below the box, onto the sidebar divider.
            .y = r.y + layout.composer_top_padding - 1,
            .width = r.width - 2 * layout.conversation_padding,
            .height = r.height - layout.composer_top_padding - layout.footer_height,
        };
    }
    // Reserve 100 pixels at the right of the composer for Send and its surrounding padding.
    fn composerEditor(box: graphics.Rect) graphics.Rect {
        // Keep the text clear of the Send button.
        return .{
            .x = box.x + 1,
            .y = box.y + 1,
            .width = box.width - 100,
            .height = box.height - 2,
        };
    }
    fn composerFooter(r: graphics.Rect) graphics.Rect {
        var footer = layout.footer(r);
        footer.x += 24;
        footer.width -= 48 + (if (comptime client_options.fps_counter) @as(f32, 72) else 0);
        return footer;
    }
    fn drawFooterLabel(s: *App, label: []const u8, r: graphics.Rect, color: graphics.Color) void {
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
    fn drawNotice(s: *App, r: graphics.Rect, ar: u.Allocator) void {
        if (u.now() >= s.notice_until) return;
        s.redrawAt(s.notice_until);
        const warning_visible = s.duplicate_risk and s.key.len > 0 and !s.new_mode and !s.show_details;
        var notice = composerFooter(r);
        if (warning_visible) notice.height /= 2;
        graphics.rectangle(notice, theme.colors.paper);
        s.drawFooterLabel(display.label(ar, s.notice) catch "…", notice, theme.colors.muted);
    }
    fn drawComposer(s: *App, r: graphics.Rect, ar: u.Allocator) void {
        graphics.rectangle(r, theme.colors.paper);
        // Draw footer feedback first so the input always appears above it.
        s.drawNotice(r, ar);
        if (s.key.len == 0 or s.new_mode) return;
        var box = composerBox(r);
        const files_height = s.attachmentsHeight();
        if (files_height > 0) s.drawDraftFiles(.{
            .x = box.x,
            .y = box.y,
            .width = box.width,
            .height = files_height,
        }, ar);
        box.y += files_height;
        box.height -= files_height;
        const read_only = s.readOnlyChat();
        const drop_hovered = drop.hovered() and s.canAttach();
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
                const hint = if (s.view != null and s.view.?.attachment_error.len > 0)
                    s.view.?.attachment_error
                else if (s.draftFiles().len > 0 and s.view != null and !s.view.?.send_attachments)
                    "Attachment sending is unavailable · files are kept in this draft"
                else if (s.view != null and s.view.?.preparing_attachments)
                    "Wait for file preparation before sending"
                else if (s.enter_to_send) "Enter to send · Shift+Enter for a new line · drop files to attach" else "Ctrl+Enter to send · Enter for a new line · drop files to attach";
                s.drawFooterLabel(hint, footer, theme.colors.muted);
            }
        }
        const background = if (read_only) theme.colors.incoming else if (drop_hovered)
            theme.colors.drop_surface
        else
            theme.colors.surface;
        shapes.drawRectangle(box, 6, background);
        const editor = composerEditor(box);
        if (comptime client_options.automation) zrct.add(.{
            .id = "composer",
            .role = "textbox",
            .label = "Message",
            .value = s.composer.text.items,
            .bounds = .from(editor),
            .enabled = !read_only,
            .obscured = input_obscured,
        });
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
                if (drop_hovered) "Drop files to attach…" else if (s.view != null and s.view.?.online) "Message this conversation…" else "Write a draft while offline…",
                .composer,
                true,
                background,
            );
        }
        if (drop_hovered) {
            shapes.drawRectangleDots(box, 6, 2, theme.colors.drop);
        } else {
            shapes.drawRectangleLines(
                box,
                6,
                1,
                if (!read_only and s.focus == .composer) theme.colors.focus else theme.colors.line,
            );
        }
        if (read_only) return;
        // 76x28 fits both Send and Saving labels; its eight-pixel bottom inset aligns with the
        // editor.
        const send_button = graphics.Rect{
            .x = r.x + r.width - layout.action_right_padding - 76,
            .y = box.y + box.height - 36,
            .width = 76,
            .height = 28,
        };
        const enabled = s.canSend();
        if (comptime client_options.automation) zrct.add(.{
            .id = "send-button",
            .role = "button",
            .label = "Send",
            .bounds = .from(send_button),
            .enabled = enabled,
            .obscured = input_obscured,
        });
        const hot = hover(send_button);
        const bg = if (enabled)
            (if (hot) theme.colors.accent_hover else theme.colors.accent)
        else
            theme.colors.incoming;
        shapes.drawRectangle(send_button, 5, bg);
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
        if (hot and enabled) desktop.setCursor(.pointing_hand);
        if (enabled) s.addControl(send_button, .{ .button = .send });
        s.drawEmojiCompletion(editor, ar);
    }
    fn drawEmojiCompletion(s: *App, editor: graphics.Rect, ar: std.mem.Allocator) void {
        s.updateEmojiCompletion();
        const completion = &s.emoji_completion;
        if (!completion.visible()) return;
        // Keep all matches reachable in pages of six, without covering the draft.
        const page_size = 6;
        const first = completion.selected / page_size * page_size;
        const last = @min(first + page_size, completion.items.len);
        const rows: f32 = @floatFromInt(last - first);
        const width = @min(390, editor.width);
        const caret = s.text.caret(s.composer.text.items, editor.width - 22 - Scrollbar.gutter, s.composer.caret);
        const panel = graphics.Rect{
            .x = std.math.clamp(editor.x + 11 + caret.x, editor.x, editor.x + editor.width - width),
            .y = editor.y - (rows * 34 + 58) - 6,
            .width = width,
            .height = rows * 34 + 58,
        };
        shapes.drawRectangle(panel, 8, theme.colors.surface);
        shapes.drawRectangleLines(panel, 8, 1, theme.colors.line);
        s.addControl(panel, .{ .emoji = null });
        if (comptime client_options.automation) zrct.add(.{
            .id = "emoji-completion",
            .role = "listbox",
            .label = "Emoji",
            .bounds = .from(panel),
        });
        s.text.drawLine("Emoji", panel.x + 12, panel.y + 7, 12, width - 24, theme.colors.muted, theme.colors.surface);
        for (completion.items[first..last], first..) |entry, index| {
            const row = graphics.Rect{
                .x = panel.x + 5,
                .y = panel.y + 28 + @as(f32, @floatFromInt(index - first)) * 34,
                .width = width - 10,
                .height = 34,
            };
            const selected = index == completion.selected;
            const hot = hover(row);
            const background = if (selected or hot) theme.colors.selected else theme.colors.surface;
            if (selected or hot) shapes.drawRectangle(row, 4, background);
            if (selected) shapes.drawRectangleLines(row, 4, 1, theme.colors.focus);
            s.text.drawLine(entry.text, row.x + 8, row.y + 4, 20, 32, theme.colors.ink, background);
            const label = std.fmt.allocPrint(ar, ":{s}:", .{entry.name}) catch entry.name;
            s.text.drawLine(label, row.x + 45, row.y + 7, 14, row.width - 53, theme.colors.ink, background);
            s.addControl(row, .{ .emoji = index });
            if (hot) desktop.setCursor(.pointing_hand);
            if (comptime client_options.automation) zrct.add(.{
                .id = std.fmt.allocPrint(ar, "emoji/{s}", .{entry.name}) catch "",
                .role = "option",
                .parent = "emoji-completion",
                .label = label,
                .value = entry.text,
                .selected = selected,
                .bounds = .from(row),
            });
        }
        const hint = std.fmt.allocPrint(ar, "Tab ↹ · Enter to insert · Esc · {d}/{d}", .{
            completion.selected + 1,
            completion.items.len,
        }) catch "Tab ↹ · Enter to insert · Esc";
        s.text.drawLine(hint, panel.x + 12, panel.y + panel.height - 23, 11, width - 24, theme.colors.muted, theme.colors.surface);
    }
    // 11-pixel side insets separate text from the border; multiline inputs use ten-pixel vertical
    // insets.
    fn inputBox(
        s: *App,
        e: *Editor,
        r: graphics.Rect,
        placeholder: []const u8,
        focus: @FieldType(App, "focus"),
        multiline: bool,
        background: graphics.Color,
    ) void {
        var buffer: [t.max_text]u8 = undefined;
        const visible = e.display(&buffer);
        if (comptime client_options.automation) if (focus != .composer and focus != .recipient) zrct.add(.{
            .id = @tagName(focus),
            .role = "textbox",
            .label = placeholder,
            .value = e.text.items,
            .bounds = .from(r),
            .clip = if (clip_depth > 0) .from(clip_stack[clip_depth - 1]) else null,
            .obscured = input_obscured,
        });
        if (!multiline) {
            shapes.drawRectangle(r, 4, background);
            shapes.drawRectangleLines(
                r,
                4,
                1,
                if (s.focus == focus) theme.colors.focus else theme.colors.line,
            );
        }
        var viewport = graphics.Rect{
            .x = r.x + 11,
            .y = r.y + (if (multiline) @as(f32, 10) else 6),
            .width = r.width - 22,
            .height = r.height - (if (multiline) @as(f32, 20) else 10),
        };
        if (focus == .search) {
            const label = if (visible.text.len == 0) placeholder else visible.text;
            const size = s.text.lineSize(label, 16, viewport.width);
            viewport.height = @min(size.y, r.height - 2);
            viewport.y = r.y + r.height / 2 - s.text.lineInkCenterY(label, 16, viewport.width);
        }
        var inner = viewport;
        if (multiline) inner.width -= Scrollbar.gutter;
        const width = inner.width;
        const caret = s.text.caret(visible.text, width, visible.caret);
        const content_height = if (multiline) @max(
            s.text.height(visible.text, 16, width),
            caret.y + caret.height,
        ) else 0;
        if (multiline) {
            // Only typing, cursor movement, or a new layout should reveal the
            // caret. Manual scrolling must not snap back to it each frame.
            if (s.composer_revision != e.revision + e.preedit_revision or s.composer_caret != e.caret or s.composer_width != width) s.revealComposerCaret(
                caret,
                inner.height,
            );
            s.addControl(r, .{ .scroll = .{
                .pane = .composer,
                .viewport = viewport,
                .content = content_height,
            } });
            s.composer_scroll = std.math.clamp(
                s.composer_scroll,
                0,
                @max(0, content_height - inner.height),
            );
        }
        const settings_field = for (settings_focus) |item| {
            if (focus == item) break true;
        } else false;
        const offset = if (multiline) s.composer_scroll else if (settings_field) @max(0, caret.y + caret.height - inner.height) else 0;
        s.addControl(if (multiline) inner else r, .{ .editor = .{
            .focus = focus,
            .origin = .{ .x = inner.x, .y = inner.y },
            .width = width,
            .offset = offset,
        } });
        if (multiline) {
            s.composer_revision = e.revision + e.preedit_revision;
            s.composer_caret = e.caret;
            s.composer_width = width;
        }
        beginClip(inner);
        if (visible.text.len == 0) s.text.draw(
            placeholder,
            inner.x,
            inner.y,
            16,
            width,
            theme.colors.muted,
            background,
        ) else s.text.drawSelection(
            visible.text,
            inner.x,
            inner.y - offset,
            16,
            width,
            theme.colors.ink,
            visible.selection.start,
            visible.selection.end,
            background,
        );
        if (visible.composition) |range| s.text.underline(
            visible.text,
            .{ .x = inner.x, .y = inner.y - offset },
            width,
            .{ .start = range.start, .end = range.end },
        );
        if (comptime client_options.automation) if (visible.composition != null) zrct.add(.{
            .id = "ime-preedit",
            .role = "text",
            .label = "Composing",
            .value = e.preedit.items,
            .bounds = .from(inner),
            .obscured = input_obscured,
        });
        const caret_box = graphics.Rect{
            .x = inner.x + caret.x,
            .y = inner.y + caret.y - offset,
            .width = 1.5,
            .height = caret.height,
        };
        if (!input_obscured and s.focusedEditor() == e) {
            var area = caret_box;
            area.x = std.math.clamp(area.x, inner.x, inner.x + inner.width - area.width);
            area.y = std.math.clamp(area.y, inner.y, inner.y + inner.height - @min(area.height, inner.height));
            area.height = @min(area.height, inner.height);
            desktop.textInputArea(area);
        }
        // Blink once per second with 600 ms visible so the insertion point is easy to locate.
        if (s.focus == focus) {
            const now = u.now();
            const phase = @mod(now, 1000);
            const clip = clip_stack[clip_depth - 1];
            if (visible.composition == null and !input_obscured and
                caret_box.x < clip.x + clip.width and caret_box.x + caret_box.width > clip.x and
                caret_box.y < clip.y + clip.height and caret_box.y + caret_box.height > clip.y)
                s.redrawAt(now + (if (phase < 600) @as(i64, 600) else 1000) - phase);
            if (visible.composition != null or phase < 600)
                graphics.rectangle(caret_box, theme.colors.accent);
        }
        endClip();
        if (multiline) s.composer_bar.draw(viewport, content_height, s.composer_scroll);
    }
    fn revealComposerCaret(s: *App, caret: graphics.Rect, viewport: f32) void {
        if (caret.y < s.composer_scroll) s.composer_scroll = caret.y;
        if (caret.y + caret.height > s.composer_scroll + viewport) s.composer_scroll = caret.y + caret.height - viewport;
    }
    // Twelve horizontal and four vertical pixels make text buttons easy to target.
    const button_padding = graphics.Point{ .x = 12, .y = 4 };
    // 13-pixel labels fit compact toolbar actions without matching body-text emphasis.
    const button_font_size = 13;
    // Bound label measurement at 512 pixels before adding button padding.
    const button_label_width = 512;
    fn buttonSize(s: *App, label: []const u8) graphics.Point {
        const text_size = s.text.lineSize(label, button_font_size, button_label_width);
        return .{ .x = text_size.x + 2 * button_padding.x, .y = text_size.y + 2 * button_padding.y };
    }
    fn button(s: *App, comptime id: []const u8, bounds: graphics.Rect, label: []const u8, primary: bool) void {
        const action = comptime action: {
            var name: [id.len]u8 = id[0..id.len].*;
            for (&name) |*ch| if (ch.* == '-') {
                ch.* = '_';
            };
            break :action std.meta.stringToEnum(ButtonAction, &name).?;
        };
        s.actionButton(id, bounds, label, primary, .{ .button = action });
    }
    fn actionButton(s: *App, id: []const u8, bounds: graphics.Rect, label: []const u8, primary: bool, action: Action) void {
        const size = s.buttonSize(label);
        const r = graphics.Rect{
            .x = bounds.x + (bounds.width - size.x) / 2,
            .y = bounds.y + (bounds.height - size.y) / 2,
            .width = size.x,
            .height = size.y,
        };
        if (comptime client_options.automation) zrct.add(.{
            .id = id,
            .role = "button",
            .label = label,
            .bounds = .from(r),
            .clip = if (clip_depth > 0) .from(clip_stack[clip_depth - 1]) else null,
            .obscured = input_obscured,
        });
        const hot = hover(r);
        if (hot) desktop.setCursor(.pointing_hand);
        const background = if (primary) (if (hot) theme.colors.accent_hover else theme.colors.accent) else if (hot) theme.colors.line else theme.colors.incoming;
        shapes.drawRectangle(r, 4, background);
        s.text.drawLine(
            label,
            r.x + button_padding.x,
            r.y + button_padding.y,
            button_font_size,
            button_label_width,
            if (primary) theme.colors.on_accent else theme.colors.muted,
            background,
        );
        s.addControl(r, action);
    }
};
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
var input_obscured = false;
fn hover(r: graphics.Rect) bool {
    if (input_obscured) return false;
    const point = desktop.mouse();
    return r.contains(point) and (clip_depth == 0 or clip_stack[clip_depth - 1].contains(point));
}
// Sixteen nested clips covers panes, cards, and editors without allocating during drawing.
var clip_stack: [16]graphics.Rect = undefined;
var clip_depth: usize = 0;
fn beginClip(requested: graphics.Rect) void {
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
fn applyClip(r: graphics.Rect) void {
    graphics.clip(r);
}
fn endClip() void {
    std.debug.assert(clip_depth > 0);
    clip_depth -= 1;
    if (clip_depth == 0) graphics.endClip() else applyClip(clip_stack[clip_depth - 1]);
}
fn chatName(v: t.Conversation) []const u8 {
    if (v.title.len > 0) return v.title;
    if (v.participants.len > 0) return v.participants[0];
    return "Conversation";
}
fn localTime(ar: u.Allocator, value: []const u8, compact: bool) []const u8 {
    const stamp = ar.dupeZ(u8, value) catch return value;
    // 64 bytes covers localized display timestamps; fall back to source text if formatting fails.
    const buffer = ar.alloc(u8, 64) catch return value;
    const n = bridge.zc_local_time(stamp, buffer.ptr, buffer.len, @intFromBool(compact));
    return if (n > 0) buffer[0..@intCast(n)] else value;
}
fn messageText(ar: u.Allocator, m: t.Message) []const u8 {
    return display.record(ar, m) catch display.unavailable;
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

/// Synthetic chat used only by the rendering benchmark; owns no database or worker thread.
pub const RenderFixture = struct {
    worker: Worker,
    app: App,

    pub const InitError = std.mem.Allocator.Error;
    pub const Workload = enum {
        cached,
        scroll,
        cold_text,
        image_upload,
        rich_anchor,
        caret,
        reflow,
        resize_width,
        resize_height,
    };
    pub const Avatars = enum { shared, distinct };

    /// Initialize in final storage because App borrows the embedded worker.
    pub fn init(s: *RenderFixture, io: std.Io, avatars: Avatars, workload: Workload) InitError!void {
        s.worker = .{ .io = io, .config = .{ .data = "" } };
        s.app = .{ .worker = &s.worker, .focus = .none };
        errdefer s.deinit();
        const view = try a.create(Worker.View);
        view.* = .{
            .arena = .init(a),
            .snapshot = .{
                .chats = &.{},
                .messages = &.{},
                .pending = &.{},
                .selected = "render-bench",
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
        s.app.view = view;
        const ar = view.arena.allocator();
        const chats = try ar.alloc(Store.Chat, 32);
        for (chats, 0..) |*chat, i| chat.* = .{
            .value = .{
                .id = if (i == 0) "render-bench" else try std.fmt.allocPrint(ar, "chat-{d}", .{i}),
                .service = "imessage",
                .title = switch (avatars) {
                    .shared => try std.fmt.allocPrint(ar, "Conversation {d}", .{i}),
                    .distinct => try std.fmt.allocPrint(ar, "{c} Conversation {d}", .{
                        @as(u8, @intCast('A' + i % 26)), i,
                    }),
                },
                .last_activity = "2026-01-01T00:00:00Z",
                .sendable = true,
            },
            .preview = "Synthetic rendering benchmark 👋",
            .unread = 1,
        };
        const messages = try ar.alloc(t.Message, 1000);
        for (messages, 0..) |*message, i| message.* = .{
            .id = try std.fmt.allocPrint(ar, "message-{d}", .{i}),
            .conversation_id = "render-bench",
            .sender = "fixture@example.invalid",
            .direction = if (i % 3 == 0) .outgoing else .incoming,
            .service = "imessage",
            .timestamp = "2026-01-01T00:00:00Z",
            .kind = .text,
            .text = try std.fmt.allocPrint(ar, "Message {d}: cached text, emoji 👩‍💻 and é.\nA second line exercises wrapping and clipping.", .{i}),
            .decoding = .plain,
            .observed_status = .received,
        };
        switch (workload) {
            .cached, .scroll, .cold_text, .image_upload, .resize_width, .resize_height => {},
            .rich_anchor => {
                messages[messages.len - 1].text = "A long message with a link https://example.invalid/ and mixed text café 世界. " ** 48;
                s.app.following = false;
            },
            .caret => {
                s.app.composer.set("A long draft with several words and punctuation. " ** 80) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // The synthetic draft is bounded, valid UTF-8.
                    error.InvalidText => unreachable,
                };
                s.app.focus = .composer;
            },
            .reflow => for (messages, 0..) |*message, i| {
                message.text = try std.fmt.allocPrint(ar, "Message {d}: " ++ "History text with wrapping and mixed scripts café 世界. " ** 16, .{i});
            },
        }
        view.snapshot.chats = chats;
        view.snapshot.messages = messages;
        s.app.key = try a.dupe(u8, "render-bench");
        s.app.loaded_key = try a.dupe(u8, "render-bench");
    }

    pub fn deinit(s: *RenderFixture) void {
        s.app.deinit();
        s.worker.shutdown();
        s.* = undefined;
    }

    /// Workload preparation is included in each measured draw interval.
    pub fn draw(s: *RenderFixture, workload: Workload, frame: usize) void {
        switch (workload) {
            .cached, .image_upload => {},
            .scroll => {
                s.app.following = false;
                // Sweep the same 3000 logical pixels in both directions, independent of FPS.
                const step = frame % 200;
                const offset: f64 = @floatFromInt(@min(step, 200 - step) * 30);
                s.app.scroll = @max(0, s.app.content_height - 800 - offset);
            },
            .cold_text => {
                s.app.text.deinit();
                s.app.text = .{};
            },
            .rich_anchor => {
                // Keep the first visible row's reading anchor inside its long text block.
                s.app.scroll = s.app.history_rows[s.app.history_rows.len - 1].top + 120;
            },
            .caret => {
                // Cycle more positions than the raster cache can retain, without selecting text.
                s.app.composer.caret = frame % 64;
                s.app.composer.anchor = s.app.composer.caret;
            },
            .reflow => if (!s.app.layout_pending) {
                // Rebuild heights at a fixed width; repeat only after the last pass settles.
                s.app.height_context = 0;
            },
            .resize_width, .resize_height => {
                const step = frame % 200;
                const offset: i32 = @intCast(@min(step, 200 - step) * 2);
                desktop.setSize(
                    if (workload == .resize_width) 1120 + offset else 1120,
                    if (workload == .resize_height) 780 + offset else 780,
                );
                desktop.poll();
            },
        }
        s.app.draw(WindowMetrics.current().scale);
    }

    pub fn measuredRows(s: *const RenderFixture) usize {
        var count: usize = 0;
        for (s.app.history_rows) |row| if (row.measured != null) {
            count += 1;
        };
        return count;
    }

    pub fn settled(s: *const RenderFixture) bool {
        return !s.app.layout_pending and s.app.history_rows.len == 1000;
    }
};

test "rich reading anchors reuse text measurements between unchanged frames" {
    try openWindow(1120, 780, "Rich history measurement reuse");
    defer closeWindow();
    desktop.poll();
    var fixture: RenderFixture = undefined;
    try fixture.init(std.testing.io, .shared, .rich_anchor);
    defer fixture.deinit();
    for (0..2000) |_| {
        fixture.draw(.cached, 0);
        graphics.endFrame();
        if (fixture.settled()) break;
    } else return error.LayoutDidNotSettle;
    fixture.draw(.rich_anchor, 0);
    graphics.endFrame();
    const calls = fixture.app.text.measure_calls;
    const offset = fixture.app.anchor_block_offset;
    const height = fixture.app.content_height;
    try std.testing.expectEqualStrings("fallback-text", fixture.app.anchor_block);
    for (0..3) |frame| {
        fixture.draw(.rich_anchor, frame);
        graphics.endFrame();
        try std.testing.expectEqual(calls, fixture.app.text.measure_calls);
        try std.testing.expectEqual(height, fixture.app.content_height);
        try std.testing.expectEqual(offset, fixture.app.anchor_block_offset);
    }
}

test "rich block measurements follow text width scale and link count" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    var block = message_content.Block{ .value = .{ .text = "Wrapped message words with café and 世界. " ** 8 } };
    const wide = app.blockHeight(block, 500, false);
    try std.testing.expect(app.blockHeight(block, 160, false) > wide);
    const calls = app.text.measure_calls;
    try std.testing.expectEqual(wide, app.blockHeight(block, 500, true));
    try std.testing.expectEqual(calls, app.text.measure_calls);
    block.links = &.{.{ .url = "https://example.invalid/", .hostname = "example.invalid" }};
    try std.testing.expectEqual(wide + 28, app.blockHeight(block, 500, false));
    block.value.text = "Short text";
    try std.testing.expect(app.blockHeight(block, 500, false) < wide);
    app.text.nextFrame(1.25);
    const scaled = app.blockHeight(block, 500, false);
    try std.testing.expectEqual(@as(usize, 1), app.text.measure_calls);
    try std.testing.expectEqual(app.text.measure(block.value.text, 16, 500) + 28, scaled);
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

test "double text clicks require a nearby matching target within the time limit" {
    const first = App.TextClick{
        .target = .{ .field = .{ .focus = .composer, .revision = 1 } },
        .position = .{ .x = 100, .y = 200 },
        .time = 10,
        .frame = 1,
    };
    var second = first;
    second.time += 0.2;
    second.position.x += 2;
    try std.testing.expect(second.follows(first));
    second.time = 10.5;
    try std.testing.expect(!second.follows(first));
    second.time = 10.2;
    second.position.x = 110;
    try std.testing.expect(!second.follows(first));
    second.position = first.position;
    second.target.field.focus = .search;
    try std.testing.expect(!second.follows(first));
    second.target.field.focus = .composer;
    second.target.field.revision = 2;
    try std.testing.expect(!second.follows(first));
}

test "idle redraw deadlines follow visible caret and notice changes" {
    // No relay or elapsed-time sleeps: inspect deadlines produced by the real draw path.
    if (comptime client_options.fps_counter) return error.SkipZigTest;
    try openWindow(1120, 780, "Idle redraw checks");
    defer closeWindow();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .focus = .none };
    defer app.deinit();
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(std.math.maxInt(i64), app.redraw_at);

    app.info("Notice after idle");
    try std.testing.expect(app.layout_pending);
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(app.notice_until, app.redraw_at);

    app.focus = .search;
    const before_blink = u.now();
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expect(app.redraw_at > before_blink);
    try std.testing.expect(app.redraw_at <= u.now() + 600);

    try app.search.setPreedit("한", 0, 1);
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(app.notice_until, app.redraw_at);

    app.search.cancelPreedit();
    app.focus = .none;
    app.notice_until = u.now() - 1;
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(std.math.maxInt(i64), app.redraw_at);

    const view = try a.create(Worker.View);
    view.* = .{
        .arena = .init(std.testing.allocator),
        .snapshot = .{
            .chats = &.{},
            .messages = &.{},
            .pending = &.{},
            .selected = "chat",
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
    app.view = view;
    app.key = try a.dupe(u8, "chat");
    const sent_ms = u.now() - 10000;
    var messages = [_]t.Message{.{
        .id = "uncertain",
        .conversation_id = "chat",
        .sender = "You",
        .direction = .outgoing,
        .service = "imessage",
        .timestamp = try u.timestamp(view.arena.allocator(), (sent_ms - 978307200000) * 1000000),
        .kind = .text,
        .text = "Waiting for confirmation",
        .decoding = .plain,
        .observed_status = .unknown,
    }};
    view.snapshot.messages = &messages;
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(sent_ms + 30000, app.redraw_at);
    messages[0].observed_status = .delivered;
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(std.math.maxInt(i64), app.redraw_at);
}

test "workspace navigation, compact lists, message selection, and scrollbars render correctly" {
    // Four samples smooth rounded shapes at fractional display scales.
    try openWindow(1120, 780, "Zimbr UI checks");
    defer closeWindow();
    // Coalesced worker signals wake an idle UI without dispatching or clearing
    // input callbacks. Draining must leave the next wait idle.
    for (0..10000) |_| desktop.wake();
    try std.testing.expectEqual(@as(c_int, 1), @intFromBool(desktop.wait(0)));
    try std.testing.expectEqual(@as(c_int, 0), @intFromBool(desktop.wait(0)));
    desktop.poll();
    // Test frames advance explicitly; a display-rate cap only adds idle time.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
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
        .loaded_key = try a.dupe(u8, "fixture-0"),
        .focus = .none,
    };
    defer app.deinit();
    for (0..4) |_| testDraw(&app, WindowMetrics.current().scale);
    const before = try captureTestFrame(&app, WindowMetrics.current().scale);
    defer graphics.destroyImage(before);
    const scale = WindowMetrics.current().scale;
    for ([_]f32{
        25,
        53,
        107,
        345,
    }) |scroll| {
        app.sidebar_scroll = scroll;
        const after = try captureTestFrame(&app, scale);
        defer graphics.destroyImage(after);
        const fixed = layout.frame(1120, 780, app.composerHeight());
        const right: i32 = @intFromFloat((fixed.sidebar.x + fixed.sidebar.width - 1) * scale);
        const bottom: i32 = @intFromFloat(App.sidebarViewport(fixed.sidebar).y * scale);
        var y: i32 = 0;
        while (y < bottom) : (y += 1) {
            var x: i32 = 0;
            while (x < right) : (x += 1) try std.testing.expectEqual(
                graphics.imageColor(before, x, y),
                graphics.imageColor(after, x, y),
            );
        }
        try std.testing.expectEqual(@as(usize, 0), clip_depth);
    }
    const dark = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(dark);
    try std.testing.expectEqual(
        theme.colors.rail,
        graphics.imageColor(dark, @intFromFloat(5 * scale), @intFromFloat(50 * scale)),
    );
    try std.testing.expectEqual(
        theme.colors.sidebar,
        graphics.imageColor(dark, @intFromFloat(70 * scale), @intFromFloat(50 * scale)),
    );
    try std.testing.expectEqual(
        theme.colors.paper,
        graphics.imageColor(dark, @intFromFloat(320 * scale), @intFromFloat(50 * scale)),
    );
    app.toggleDetails();
    testDraw(&app, scale);
    try std.testing.expect(app.details_height > 0);
    app.details_scroll = 100000;
    testDraw(&app, scale);
    try std.testing.expect(app.details_scroll < 100000);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);
    app.toggleDetails();
    testDraw(&app, scale);
    try std.testing.expect(!app.show_details);
    // A narrow, short window exercises wrapping and the diagnostics scroll path.
    desktop.setSize(780, 560);
    for (0..4) |_| testDraw(&app, WindowMetrics.current().scale);
    app.toggleDetails();
    testDraw(&app, WindowMetrics.current().scale);
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
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expect(app.composer_scroll > 0);
    app.composer_scroll = 0;
    {
        const shot = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer graphics.destroyImage(shot);
        try std.testing.expectEqual(@as(f32, 0), app.composer_scroll);
        const areas = layout.frame(
            @floatFromInt(desktop.width()),
            @floatFromInt(desktop.height()),
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
        const composer_viewport = graphics.Rect{
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
            const pixel = graphics.imageColor(
                shot,
                @intFromFloat((areas.history.x + 24) * WindowMetrics.current().scale),
                @intFromFloat(y * WindowMetrics.current().scale),
            );
            try std.testing.expectEqual(style.bubble, pixel);
            checked += 1;
        }
        try std.testing.expect(checked >= 2);
        app.toggleDetails();
        testDraw(&app, WindowMetrics.current().scale);
        const details = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer graphics.destroyImage(details);
        try expectScrollbarPixel(details, .{
            .x = areas.sidebar.x + 32,
            .y = 98,
            .width = areas.sidebar.width + areas.header.width - 48,
            .height = areas.composer.y + areas.composer.height - 106,
        }, app.details_height, app.details_scroll);
        app.toggleDetails();
    }
    app.composer.caret = 0;
    testDraw(&app, WindowMetrics.current().scale);
    app.composer.caret = app.composer.text.items.len;
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expect(app.composer_scroll > 0);
    try app.composer.set("");

    // Drive the actual mouse path: drag backwards within a message, release,
    // and verify the selected range stays highlighted and ready to copy.
    testDraw(&app, scale);
    const selection_before = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(selection_before);
    const areas = layout.frame(
        @floatFromInt(desktop.width()),
        @floatFromInt(desktop.height()),
        app.composerHeight(),
    );
    const row = app.history_rows[app.history_rows.len - 1];
    const text_width = App.historyTextWidth(areas.history);
    const text_x = areas.history.x + 66;
    const text_y = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 22;
    const start = app.text.caret(row.text, text_width, "A ".len);
    const end = app.text.caret(row.text, text_width, "A message".len);
    testInput(.{ .motion = .{ .x = @intFromFloat(text_x + end.x), .y = @intFromFloat(text_y + end.y + end.height / 2) } });
    testInput(.{ .button_down = .left });
    testDraw(&app, scale);
    testInput(.{ .motion = .{ .x = @intFromFloat(text_x + start.x), .y = @intFromFloat(text_y + start.y + start.height / 2) } });
    const selection_after = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(selection_after);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());
    var highlighted: usize = 0;
    var py: i32 = @intFromFloat(text_y * scale);
    while (py < @as(i32, @intFromFloat((text_y + start.height) * scale))) : (py += 1) {
        var px: i32 = @intFromFloat((text_x + start.x) * scale);
        while (px < @as(i32, @intFromFloat((text_x + end.x) * scale))) : (px += 1) {
            if (!std.meta.eql(
                graphics.imageColor(selection_before, px, py),
                graphics.imageColor(selection_after, px, py),
            )) highlighted += 1;
        }
    }
    try std.testing.expect(highlighted > 100);
    testInput(.{ .button_up = .left });
    testDraw(&app, scale);
    try std.testing.expect(!app.message_selection.dragging);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());

    // Both clicks land in the right half of the word's final letter.
    const last_letter = app.text.caret(row.text, text_width, "A messag".len);
    const word_x = text_x + last_letter.x + (end.x - last_letter.x) * 0.75;
    const word_y = text_y + end.y + end.height / 2;
    clickTestFrame(&app, word_x, word_y);
    clickTestFrame(&app, word_x, word_y);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());
    testDraw(&app, scale);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());

    clickTestFrame(&app, text_x + 1, text_y + 1);
    try std.testing.expectEqualStrings(row.text, app.message_selection.selected());
    clickTestFrame(&app, text_x - 1, text_y + 1);
    clickTestFrame(&app, text_x + 1, text_y + 1);
    try std.testing.expectEqualStrings(row.text, app.message_selection.selected());
    clickTestFrame(&app, word_x, word_y);
    clickTestFrame(&app, word_x, word_y);
    try std.testing.expectEqualStrings("message", app.message_selection.selected());

    // An uncertain send stays before a newer reply and retains recovery in its header.
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
    testDraw(&app, scale);
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
        areas.history.y + @as(f32, @floatCast(pending_row.top - app.scroll)) + 8,
    );
    try std.testing.expectEqualStrings(pending[0].input.text, app.composer.text.items);
    try std.testing.expect(app.duplicate_risk);

    try app.composer.set("A follow-up, don’t stop.");
    testDraw(&app, scale);
    const composer_box = App.composerEditor(App.composerBox(areas.composer));
    const composer_width = composer_box.width - 22 - Scrollbar.gutter;
    const hyphen = app.text.caret(app.composer.text.items, composer_width, "A follow".len);
    const composer_x = composer_box.x + 11;
    const composer_y = composer_box.y + 10;
    const hyphen_x = composer_x + hyphen.x + 1;
    const hyphen_y = composer_y + hyphen.y + hyphen.height / 2;
    clickTestFrame(&app, hyphen_x, hyphen_y);
    try std.testing.expectEqualStrings("", app.composer.selected());
    pressTestFrame(&app, hyphen_x, hyphen_y);
    try std.testing.expectEqualStrings("follow-up", app.composer.selected());
    const contraction = app.text.caret(app.composer.text.items, composer_width, "A follow-up, do".len);
    testInput(.{ .motion = .{ .x = @intFromFloat(composer_x + contraction.x + 1), .y = @intFromFloat(hyphen_y) } });
    testDraw(&app, scale);
    try std.testing.expectEqualStrings("follow-up, don’t", app.composer.selected());
    testInput(.{ .motion = .{ .x = @intFromFloat(composer_x + 1), .y = @intFromFloat(hyphen_y) } });
    testDraw(&app, scale);
    try std.testing.expectEqualStrings("A follow-up", app.composer.selected());
    testInput(.{ .button_up = .left });
    testDraw(&app, scale);
    try std.testing.expectEqualStrings("A follow-up", app.composer.selected());
    try app.composer.insert("One");
    try std.testing.expectEqualStrings("One, don’t stop.", app.composer.text.items);
    try app.composer.history(false);
    try std.testing.expectEqualStrings("A follow-up, don’t stop.", app.composer.text.items);
    try std.testing.expectEqualStrings("A follow-up", app.composer.selected());

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
        testDraw(&app, scale);
        const recent_row = app.history_rows[app.history_rows.len - 1];
        try std.testing.expect(recent_row.pending);
        const copy_x = areas.history.x + 66 + App.historyTextWidth(areas.history) - 59;
        const copy_y = areas.history.y + @as(f32, @floatCast(recent_row.top - app.scroll)) + 8;
        const recent = try captureTestFrame(&app, scale);
        defer graphics.destroyImage(recent);
        try std.testing.expectEqual(theme.colors.selected, graphics.imageColor(
            recent,
            @intFromFloat((areas.history.x + 37) * scale),
            @intFromFloat((areas.history.y + @as(f32, @floatCast(recent_row.top - app.scroll)) + 4) * scale),
        ));
        try std.testing.expectEqual(theme.colors.paper, graphics.imageColor(
            recent,
            @intFromFloat(copy_x * scale),
            @intFromFloat(copy_y * scale),
        ));
        clickTestFrame(&app, copy_x, copy_y);
        try std.testing.expectEqualStrings("", app.composer.text.items);
    }
    pending[0].state = "failed";
    view.generation += 1;
    testDraw(&app, scale);
    const failed_row = app.history_rows[app.history_rows.len - 1];
    const failed = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(failed);
    try std.testing.expectEqual(theme.colors.incoming, graphics.imageColor(
        failed,
        @intFromFloat((areas.history.x + 37) * scale),
        @intFromFloat((areas.history.y + @as(f32, @floatCast(failed_row.top - app.scroll)) + 4) * scale),
    ));
    clickTestFrame(
        &app,
        areas.history.x + 66 + App.historyTextWidth(areas.history) - 59,
        areas.history.y + @as(f32, @floatCast(failed_row.top - app.scroll)) + 8,
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
    testDraw(&app, scale);
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
    for ([_]desktop.Key{ .backspace, .enter }) |key| {
        testInput(.{ .key_down = key });
        try app.update();
        testInput(.{ .key_up = key });
        try std.testing.expectEqualStrings("Saved draft", app.composer.text.items);
        try std.testing.expect(!app.send_wait and !app.draft_dirty and !app.canSend());
    }
    const disabled_box = App.composerBox(areas.composer);
    clickTestFrame(&app, disabled_box.x + 40, disabled_box.y + 16);
    try std.testing.expect(app.focus == .none);
    const disabled = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(disabled);
    try std.testing.expectEqual(
        theme.colors.incoming,
        graphics.imageColor(disabled, @intFromFloat((disabled_box.x + 5) * scale), @intFromFloat((disabled_box.y + disabled_box.height / 2) * scale)),
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
    // Publish the changed fixture capabilities before clicking its retained controls.
    testDraw(&app, scale);
    clickTestFrame(&app, disabled_box.x + 40, disabled_box.y + 16);
    try std.testing.expect(app.focus == .composer);
    app.composer.caret = app.composer.text.items.len;
    app.composer.anchor = app.composer.caret;
    testInput(.{ .key_down = desktop.Key.backspace });
    try app.update();
    testInput(.{ .key_up = desktop.Key.backspace });
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
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expect(app.layout_pending);
    try std.testing.expect(app.heights.count() <= App.max_height_work);
    const newest = messageText(arena.allocator(), messages[messages.len - 1]);
    try std.testing.expect(app.heights.contains(std.hash.Wyhash.hash(0, newest)));
    var frames: usize = 0;
    while (app.layout_pending and frames < 200) : (frames += 1) testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expect(!app.layout_pending);
    try std.testing.expectEqual(messages.len, app.heights.count());
    // A settled frame retains geometry while viewport changes still keep the
    // latest message at the bottom. New content invalidates that geometry.
    try std.testing.expect(!app.history_needs_position and !app.history_needs_measurement);
    const settled_rows = app.history_rows.ptr;
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(settled_rows, app.history_rows.ptr);
    try app.composer.set("A taller\nthree-line\ncomposer");
    testDraw(&app, WindowMetrics.current().scale);
    const history = layout.frame(
        @floatFromInt(desktop.width()),
        @floatFromInt(desktop.height()),
        app.composerHeight(),
    ).history;
    try std.testing.expectApproxEqAbs(app.historyLimit(history.height), app.scroll, 0.000001);
    const settled_height = app.content_height;
    messages[messages.len - 1].text = "Changed\nMore\nLines\nTo\nMeasure";
    view.generation += 1;
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expect(app.content_height != settled_height);
    try std.testing.expect(app.text.texture_bytes <= 32 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 0), clip_depth);
}

fn expectScrollbarPixel(shot: graphics.Image, viewport: graphics.Rect, content: f64, offset: f64) !void {
    const g = Scrollbar.geometry(viewport, content, offset) orelse return error.MissingScrollbar;
    const scale = WindowMetrics.current().scale;
    const pixel = graphics.imageColor(
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
        fn expectHighlight(app: *App, viewport: graphics.Rect, index: usize) !void {
            const scale = WindowMetrics.current().scale;
            const shot = try captureTestFrame(app, scale);
            defer graphics.destroyImage(shot);
            const color = if (app.show_hidden) theme.colors.line else theme.colors.selected;
            for (0..2) |row| {
                const pixel = graphics.imageColor(
                    shot,
                    @intFromFloat((viewport.x + viewport.width - 40) * scale),
                    @intFromFloat((viewport.y + @as(f32, @floatFromInt(row)) * App.sidebar_row_height + 16) * scale),
                );
                if (row == index) try std.testing.expectEqual(color, pixel) else try std.testing.expect(!std.meta.eql(color, pixel));
            }
        }
    };
    try openWindow(1120, 780, "Zimbr sidebar selection checks");
    defer closeWindow();
    desktop.poll();
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
    for (0..4) |_| testDraw(&app, WindowMetrics.current().scale);
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
        fn expectHistory(before: graphics.Image, after: graphics.Image, r: graphics.Rect, scale: f32) !void {
            var ink: usize = 0;
            var y: i32 = @intFromFloat(@ceil(r.y * scale));
            while (y < @as(i32, @intFromFloat((r.y + r.height) * scale))) : (y += 1) {
                var x: i32 = @intFromFloat(@ceil(r.x * scale));
                while (x < @as(i32, @intFromFloat((r.x + r.width) * scale))) : (x += 1) {
                    const pixel = graphics.imageColor(before, x, y);
                    if (!std.meta.eql(pixel, theme.colors.paper)) ink += 1;
                    try std.testing.expectEqual(pixel, graphics.imageColor(after, x, y));
                }
            }
            try std.testing.expect(ink > 100);
        }
    };
    try openWindow(1120, 780, "Zimbr conversation switch checks");
    defer closeWindow();
    desktop.poll();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    worker.view = try fixture.view("new:first", 1);
    try app.update();
    const scale = WindowMetrics.current().scale;
    for (0..4) |_| testDraw(&app, scale);
    app.following = false;
    app.scroll = 150;
    app.focus = .none;
    try app.composer.set("Unsaved first draft");
    app.draft_dirty = true;
    const before = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(before);
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
        defer graphics.destroyImage(waiting);
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
    defer graphics.destroyImage(superseded);
    try fixture.expectHistory(before, superseded, areas.history, scale);
    try std.testing.expectEqualStrings("new:first", app.view.?.snapshot.selected);
    worker.view = try fixture.view("new:third", 3);
    try app.update();
    try std.testing.expectEqualStrings("new:third", app.key);
    try std.testing.expectEqualStrings("new:third", app.view.?.snapshot.selected);
    try std.testing.expectEqualStrings("new:third draft", app.composer.text.items);
    try std.testing.expect(app.canSend());
    const switched = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(switched);
    try std.testing.expect(app.following);
    try std.testing.expectEqualStrings("new:third-29", app.history_rows[29].id);
    const settled = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(settled);
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
    try openWindow(780, 560, "Zimbr shared view checks");
    defer closeWindow();
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

test "send status and echo transitions preserve message positions and heights" {
    const SharedSnapshot = @import("client.zig").SharedSnapshot;
    const fixture = struct {
        fn draw(app: *App, store: Store, generation: u64, scale: f32) !void {
            const shared = try SharedSnapshot.create(
                store,
                "chat",
                generation,
                if (app.view) |old| old.shared else null,
            );
            errdefer shared.release();
            const view = try a.create(Worker.View);
            view.* = .{
                .arena = .init(a),
                .snapshot = shared.snapshot,
                .shared = shared,
                .content_generation = generation,
                .status = "Offline",
                .online = false,
                .send_direct = false,
                .reply_existing = false,
                .generation = generation,
                .ack = 0,
            };
            if (app.view) |old| old.destroy();
            app.view = view;
            testDraw(app, scale);
        }

        fn expectPositions(app: *App, positions: [2]f64, height: f64) !void {
            try std.testing.expectEqual(@as(usize, 2), app.history_rows.len);
            try std.testing.expectEqual(height, app.content_height);
            for (app.history_rows, positions) |row, expected| {
                try std.testing.expectApproxEqAbs(expected, row.top - app.scroll, 0.000001);
            }
        }
    };
    try openWindow(780, 560, "Zimbr send geometry checks");
    defer closeWindow();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const epoch = "EjRWeBI0EjQSNBI0VniQEg";
    for ([_]f32{
        1,
        1.25,
        2,
    }) |scale| for ([_][]const u8{
        "A short reply",
        "A wrapped reply 👋 " ** 12,
        "A link: https://example.invalid/page\nAnd another line",
    }) |body| {
        const store = try Store.open(":memory:");
        defer store.close();
        try store.beginSync(epoch, epoch ++ ":0");
        var message = t.Message{
            .id = "previous",
            .revision = "1",
            .conversation_id = "chat",
            .sender = "peer",
            .direction = .incoming,
            .service = "imessage",
            .timestamp = "2026-01-01T00:00:00Z",
            .kind = .text,
            .text = "The preceding message must stay put too.",
            .decoding = .plain,
            .observed_status = .received,
        };
        _ = try store.upsert(ar, "message", try u.json(ar, message));
        try store.persistSend(ar, "chat", .{
            .request_id = epoch,
            .server_epoch = epoch,
            .target = .{ .recipient = .{ .address = "peer@example.invalid", .service = "imessage" } },
            .text = body,
        });
        const sent_at = (try store.snapshot(ar, "chat")).pending[0].sent_at;
        var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
        defer worker.shutdown();
        var app = App{ .worker = &worker, .key = try a.dupe(u8, "chat") };
        defer app.deinit();
        var generation: u64 = 1;
        try fixture.draw(&app, store, generation, scale);
        try std.testing.expectEqual(@as(usize, 2), app.history_rows.len);
        const positions = [2]f64{
            app.history_rows[0].top - app.scroll,
            app.history_rows[1].top - app.scroll,
        };
        const height = app.content_height;
        for ([_][]const u8{
            "queued",
            "dispatching",
            "unknown",
            "failed",
            "unconfirmed",
        }) |state| {
            try store.outcome(epoch, state, "A long error explanation that must stay out of message layout. " ** 12);
            generation += 1;
            try fixture.draw(&app, store, generation, scale);
            try fixture.expectPositions(&app, positions, height);
        }
        try store.outcome(epoch, "unknown", "");
        message.id = "echo";
        message.direction = .outgoing;
        message.text = body;
        message.timestamp = sent_at;
        inline for (.{
            .sent,
            .delivered,
            .failed,
        }) |status| {
            generation += 1;
            message.revision = try std.fmt.allocPrint(ar, "{d}", .{generation});
            message.observed_status = status;
            _ = try store.upsert(ar, "message", try u.json(ar, message));
            try fixture.draw(&app, store, generation, scale);
            try std.testing.expect(!app.history_rows[1].pending);
            try fixture.expectPositions(&app, positions, height);
        }
    };
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

test "deferred heights make progress then yield without blocking cached measurements" {
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .height_budget = App.max_height_work };
    defer app.deinit();
    var first = App.HistoryRow{
        .id = "first",
        .text = "A measured message",
        .key = 1,
        .measured = null,
        .padding = 54,
    };
    _ = app.measureRow(&first, 320, false);
    try std.testing.expect(first.measured != null);
    var deferred = App.HistoryRow{
        .id = "deferred",
        .text = "A different message",
        .key = 2,
        .measured = null,
        .padding = 54,
    };
    _ = app.measureRow(&deferred, 320, false);
    try std.testing.expectEqual(null, deferred.measured);
    var cached = first;
    cached.measured = null;
    _ = app.measureRow(&cached, 320, false);
    try std.testing.expectEqual(first.measured, cached.measured);
    try std.testing.expectEqual(@as(usize, 1), app.text.measure_calls);
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

test "horizontal resizing preserves fixed text and geometry pixels" {
    try expectResizePixels(true);
}

test "vertical resizing preserves fixed text and geometry pixels" {
    try expectResizePixels(false);
}

test "vertical resizing translates message history without changing its pixels" {
    try expectHistoryResizePixels(true);
}

test "vertical resizing preserves pixels at the history reading position" {
    try expectHistoryResizePixels(false);
}

fn expectHistoryResizePixels(following: bool) !void {
    try openWindow(1120, 780, "History resize pixel stability");
    defer closeWindow();
    desktop.poll();
    var fixture: RenderFixture = undefined;
    try fixture.init(std.testing.io, .shared, .cached);
    defer fixture.deinit();
    for (0..2000) |_| {
        fixture.draw(.cached, 0);
        graphics.endFrame();
        if (fixture.settled()) break;
    } else return error.LayoutDidNotSettle;
    if (!following) fixture.app.scrollHistory(4, 600);
    const scale = WindowMetrics.current().scale;
    var baseline: ?graphics.Image = null;
    defer if (baseline) |shot| graphics.destroyImage(shot);
    var baseline_bottom: i32 = 0;
    for ([_]i32{
        0,
        1,
        2,
        3,
        4,
        3,
        2,
        1,
        0,
    }) |delta| {
        desktop.setSize(1120, 780 + delta);
        try std.testing.expect(desktop.c.SDL_SyncWindow(desktop.window()));
        desktop.poll();
        try std.testing.expectEqual(@as(i32, 780) + delta, desktop.height());
        try std.testing.expectEqual(scale, WindowMetrics.current().scale);
        fixture.draw(.cached, 0);
        const shot = try graphics.capture();
        graphics.endFrame();
        const history = layout.frame(1120, @floatFromInt(desktop.height()), fixture.app.composerHeight()).history;
        try std.testing.expectEqual(following, fixture.app.following);
        const anchor_y = if (following) history.y + history.height else 600;
        const bottom: i32 = @intFromFloat(@round(anchor_y * scale));
        if (baseline) |before| {
            defer graphics.destroyImage(shot);
            var changed: usize = 0;
            // Compare the message text after accounting for bottom anchoring.
            for (40..400) |distance| {
                const before_y = baseline_bottom - @as(i32, @intCast(distance));
                const after_y = bottom - @as(i32, @intCast(distance));
                for (470..900) |x| {
                    if (!std.meta.eql(
                        graphics.imageColor(before, @intCast(x), before_y),
                        graphics.imageColor(shot, @intCast(x), after_y),
                    )) changed += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 0), changed);
        } else {
            baseline = shot;
            baseline_bottom = bottom;
        }
    }
}

fn expectResizePixels(horizontal: bool) !void {
    try openWindow(780, 560, "Resize pixel stability");
    defer closeWindow();
    desktop.poll();
    const c = desktop.c;
    const display_scale = c.SDL_GetWindowDisplayScale(desktop.window());
    var text = Text{};
    defer text.deinit();
    var baseline: ?graphics.Image = null;
    defer if (baseline) |shot| graphics.destroyImage(shot);
    // Cross the 125% rounding phases in both resize directions.
    for ([_]i32{
        0,
        1,
        2,
        3,
        4,
        3,
        2,
        1,
        0,
    }, 0..) |delta, frame| {
        const width = 780 + if (horizontal) delta else @as(i32, 0);
        const height = 560 + if (horizontal) @as(i32, 0) else delta;
        desktop.setSize(width, height);
        try std.testing.expect(c.SDL_SyncWindow(desktop.window()));
        desktop.poll();
        try std.testing.expectEqual(width, desktop.width());
        try std.testing.expectEqual(height, desktop.height());
        try std.testing.expectEqual(display_scale, c.SDL_GetWindowDisplayScale(desktop.window()));
        text.nextFrame(WindowMetrics.current().scale);
        graphics.beginFrame();
        graphics.clear(.white);
        text.drawLine("Conversation preview", 66, 254, 16, 244, .black, .white);
        graphics.rectangle(.{
            .x = 66,
            .y = 294,
            .width = 120,
            .height = 2,
        }, .black);
        const shot = try graphics.capture();
        graphics.endFrame();
        if (baseline) |before| {
            defer graphics.destroyImage(shot);
            var changed: usize = 0;
            for (0..@intFromFloat(320 * display_scale)) |y| {
                for (0..@intFromFloat(320 * display_scale)) |x| {
                    if (!std.meta.eql(
                        graphics.imageColor(before, @intCast(x), @intCast(y)),
                        graphics.imageColor(shot, @intCast(x), @intCast(y)),
                    )) changed += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 0), changed);
        } else baseline = shot;
        try std.testing.expectEqual(frame + 1, text.frame);
    }
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

fn pressTestFrame(app: *App, x: f32, y: f32) void {
    testInput(.{ .motion = .{ .x = @intFromFloat(x), .y = @intFromFloat(y) } });
    testInput(.{ .button_down = .left });
    testDraw(app, WindowMetrics.current().scale);
}

fn clickTestFrame(app: *App, x: f32, y: f32) void {
    pressTestFrame(app, x, y);
    testInput(.{ .button_up = .left });
    testDraw(app, WindowMetrics.current().scale);
}

fn captureTestFrame(app: *App, scale: f32) !graphics.Image {
    app.capture_frame = true;
    defer app.capture_frame = false;
    testDraw(app, scale);
    const shot = app.captured orelse return error.ScreenshotUnavailable;
    app.captured = null;
    return shot;
}

test "message header keeps sender and timestamp pixels stable across send statuses" {
    try openWindow(640, 480, "Zimbr status geometry checks");
    defer closeWindow();
    const target = try graphics.createTarget(512, 128);
    defer graphics.destroyTarget(target);
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    for ([_]f32{
        1,
        1.25,
        1.5,
        2,
    }) |scale| {
        var reference: ?graphics.Image = null;
        defer if (reference) |shot| graphics.destroyImage(shot);
        const stamp = "Sep 25 · 16:00";
        for ([_]display.MessageStatus{
            .none,
            .{ .label = "Sending…" },
            .{ .checks = .sent },
            .{ .checks = .delivered },
            .{ .label = "Failed · A long error must not squeeze the timestamp or move its text." },
        }) |status| {
            app.text.nextFrame(scale);
            graphics.beginTarget(target);
            graphics.clear(graphics.Color.black);
            graphics.setScale(scale);
            _ = app.drawMessageHeader("You", stamp, status, .{
                .x = 10,
                .y = 10,
                .width = 160,
            }, graphics.Color.white, graphics.Color.black);
            graphics.resetScale();
            graphics.endTarget();
            const shot = try graphics.readTexture(target);

            if (reference) |before| {
                defer graphics.destroyImage(shot);
                const right = 10 + app.text.lineSize("You", 14, 110).x + 6 +
                    app.text.lineSize(stamp, 11, 160).x;
                for (0..@as(usize, @intFromFloat(32 * scale))) |y| {
                    for (0..@as(usize, @intFromFloat(right * scale))) |x| {
                        try std.testing.expectEqual(
                            graphics.imageColor(before, @intCast(x), @intCast(y)),
                            graphics.imageColor(shot, @intCast(x), @intCast(y)),
                        );
                    }
                }
            } else reference = shot;
        }
    }
}

test "message dates keep font alignment across glyphs and fractional row positions" {
    const Ink = struct {
        fn center(shot: graphics.Image, left: i32, right: i32, top: i32, bottom: i32) !f32 {
            var first = bottom;
            var last = top;
            var y = top;
            while (y < bottom) : (y += 1) {
                var x = left;
                while (x < right) : (x += 1) {
                    const pixel = graphics.imageColor(shot, x, y);
                    if (@max(pixel.r, pixel.g, pixel.b) <= 32) continue;
                    first = @min(first, y);
                    last = @max(last, y);
                }
            }
            try std.testing.expect(first <= last);
            return @as(f32, @floatFromInt(first + last)) / 2;
        }
    };
    try openWindow(640, 480, "Zimbr message header checks");
    defer closeWindow();
    desktop.poll();
    const target = try graphics.createTarget(1024, 512);
    defer graphics.destroyTarget(target);
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
            graphics.beginTarget(target);
            graphics.clear(graphics.Color.black);
            graphics.setScale(scale);
            // Message heights and scrolling can put a row at any subpixel phase.
            for (0..8) |i| {
                const row: f32 = @floatFromInt(i);
                _ = app.drawMessageHeader(name, stamp, status, .{
                    .x = 10,
                    .y = (12 + row * 40 + row / 8) / scale,
                    .width = 490,
                }, graphics.Color.white, graphics.Color.black);
            }
            const name_width = app.text.lineSize(name, 14, 490 * 0.55).x;
            const stamp_x = 10 + name_width + 6;
            const stamp_width = app.text.lineSize(stamp, 11, 250).x;
            // Control for glyph hinting and horizontal subpixel coverage by
            // rendering the same date without header positioning as a reference.
            app.text.drawLine(stamp, stamp_x, 400 / scale, 11, 250, theme.colors.muted, graphics.Color.black);
            graphics.resetScale();
            graphics.endTarget();
            const shot = try graphics.readTexture(target);
            defer graphics.destroyImage(shot);

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
    try openWindow(1120, 900, "Zimbr mixed message checks");
    defer closeWindow();
    desktop.poll();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
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
    for (0..4) |_| testDraw(&app, scale);
    const shot = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(shot);
    const areas = layout.frame(
        @floatFromInt(desktop.width()),
        @floatFromInt(desktop.height()),
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
                const left = graphics.imageColor(shot, x, plain_y + dy);
                const right = graphics.imageColor(shot, x, attached_y + dy);
                const left_ink = @max(left.r, left.g, left.b) > 80;
                const right_ink = @max(right.r, right.g, right.b) > 80;
                try std.testing.expectEqual(left_ink, right_ink);
                if (left_ink) ink += 1;
            }
        }
        try std.testing.expect(ink > 100);
    }
}

test "retired texture storage is reused without changing queued draws" {
    try openWindow(320, 160, "Texture reuse ordering");
    defer closeWindow();
    desktop.poll();
    const target = try graphics.createTarget(64, 32);
    defer graphics.destroyTarget(target);
    graphics.beginTarget(target);
    graphics.clear(.black);
    const red = try graphics.upload(&.{
        255,
        0,
        0,
        255,
    }, 1, 1, .nearest);
    const properties = desktop.c.SDL_GetTextureProperties(red);
    graphics.drawTexture(red, .{
        .x = 0,
        .y = 0,
        .width = 32,
        .height = 32,
    });
    graphics.destroyTexture(red);
    const green = try graphics.upload(&.{
        0,
        255,
        0,
        255,
    }, 1, 1, .nearest);
    defer graphics.destroyTexture(green);
    try std.testing.expectEqual(properties, desktop.c.SDL_GetTextureProperties(green));
    graphics.drawTexture(green, .{
        .x = 32,
        .y = 0,
        .width = 32,
        .height = 32,
    });
    graphics.endTarget();
    const shot = try graphics.readTexture(target);
    defer graphics.destroyImage(shot);
    try std.testing.expectEqual(graphics.Color{
        .r = 255,
        .g = 0,
        .b = 0,
        .a = 255,
    }, graphics.imageColor(shot, 16, 16));
    try std.testing.expectEqual(graphics.Color{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    }, graphics.imageColor(shot, 48, 16));
}

test "shared avatar initials retain colored rasters across redraws" {
    try openWindow(320, 160, "Shared avatar raster cache");
    defer closeWindow();
    desktop.poll();
    var text = Text{};
    defer text.deinit();
    const target = try graphics.createTarget(160, 48);
    defer graphics.destroyTarget(target);
    const colors = [_]graphics.Color{
        .red,
        .sky_blue,
        .white,
        .{
            .r = 0,
            .g = 255,
            .b = 0,
            .a = 255,
        },
    };
    var first_bytes: usize = 0;
    for (0..3) |_| {
        text.nextFrame(1);
        graphics.beginTarget(target);
        graphics.clear(.black);
        for (colors, 0..) |color, i| {
            text.drawLine("C", @floatFromInt(i * 40 + 4), 4, 24, 32, color, null);
            if (first_bytes == 0) first_bytes = text.texture_bytes;
        }
        graphics.endTarget();
        try std.testing.expect(first_bytes > 0);
        // Four appearances share one shaped layout and retain all four GPU rasters.
        try std.testing.expectEqual(@as(usize, 1), text.entries.items.len);
        try std.testing.expectEqual(first_bytes * colors.len, text.texture_bytes);
        const shot = try graphics.readTexture(target);
        defer graphics.destroyImage(shot);
        for (colors, 0..) |color, i| {
            var ink: usize = 0;
            for (0..48) |y| for (0..40) |x| {
                const pixel = graphics.imageColor(shot, @intCast(i * 40 + x), @intCast(y));
                if (std.meta.eql(pixel, color)) ink += 1;
            };
            try std.testing.expect(ink > 10);
        }
    }
}

test "text raster variants evict old appearances without unbounded texture growth" {
    try openWindow(320, 160, "Text raster limits");
    defer closeWindow();
    desktop.poll();
    var text = Text{};
    defer text.deinit();
    const target = try graphics.createTarget(80, 48);
    defer graphics.destroyTarget(target);
    var single_bytes: usize = 0;
    for (0..64) |i| {
        text.nextFrame(1);
        graphics.beginTarget(target);
        graphics.clear(.black);
        text.drawLine("C", 4, 4, 24, 32, .{
            .r = @intCast(i),
            .g = 127,
            .b = 255,
            .a = 255,
        }, null);
        graphics.endTarget();
        if (single_bytes == 0) single_bytes = text.texture_bytes;
        try std.testing.expect(text.texture_bytes <= 16 * single_bytes);
    }
    try std.testing.expect(single_bytes > 0);
    try std.testing.expectEqual(16 * single_bytes, text.texture_bytes);
    try std.testing.expectEqual(@as(usize, 1), text.entries.items.len);
    for (text.entries.items[0].rasters.items) |raster| {
        try std.testing.expect(raster.key.color.r >= 48);
    }
}

test "collapsed selections reuse rasters while real selections change pixels" {
    try openWindow(640, 360, "Collapsed selection raster reuse");
    defer closeWindow();
    desktop.poll();
    var text = Text{};
    defer text.deinit();
    const body = "Unchanged text while the caret moves across the message.";
    for (0..32) |position| {
        text.nextFrame(desktop.scale().x);
        graphics.beginFrame();
        graphics.clear(.white);
        text.drawSelection(body, 20, 20, 16, 500, .black, position, position, .white);
        graphics.endFrame();
        try std.testing.expectEqual(@as(usize, 1), text.entries.items.len);
        try std.testing.expectEqual(@as(usize, 1), text.entries.items[0].rasters.items.len);
    }
    const plain = text.entries.items[0].rasters.items[0].texture;
    const before = try graphics.readTexture(plain);
    defer graphics.destroyImage(before);
    text.drawSelection(body, 20, 20, 16, 500, .black, 2, 8, .white);
    try std.testing.expectEqual(@as(usize, 2), text.entries.items[0].rasters.items.len);
    const selected = text.entries.items[0].rasters.items[1].texture;
    const after = try graphics.readTexture(selected);
    defer graphics.destroyImage(after);
    try std.testing.expectEqual(before.w, after.w);
    try std.testing.expectEqual(before.h, after.h);
    var changed: usize = 0;
    for (0..@intCast(before.h)) |y| for (0..@intCast(before.w)) |x| {
        if (!std.meta.eql(
            graphics.imageColor(before, @intCast(x), @intCast(y)),
            graphics.imageColor(after, @intCast(x), @intCast(y)),
        )) changed += 1;
    };
    try std.testing.expect(changed > 100);
}

test "text remains intact when layouts evict textures queued in the same frame" {
    try openWindow(640, 360, "Zimbr text cache checks");
    defer closeWindow();
    desktop.poll();
    var text = Text{};
    defer text.deinit();
    for (0..4) |_| {
        graphics.beginFrame();
        graphics.clear(graphics.Color.white);
        graphics.endFrame();
        desktop.poll();
    }
    var images: [2]graphics.Image = undefined;
    for (&images, 0..) |*shot, pass| {
        text.nextFrame(1);
        graphics.beginFrame();
        graphics.clear(graphics.Color.white);
        text.draw(
            "Message text must retain its glyphs and proportions",
            20,
            20,
            16,
            500,
            graphics.Color.black,
            graphics.Color.white,
        );
        // Recoloring and selection share metrics but use distinct raster variants.
        text.drawSelection(
            "Message text must retain its glyphs and proportions",
            20,
            60,
            16,
            500,
            graphics.Color.red,
            0,
            7,
            graphics.Color.white,
        );
        if (pass == 1) {
            var buf: [64]u8 = undefined;
            for (0..400) |i| {
                const label = try std.fmt.bufPrint(&buf, "Offscreen message {d}", .{i});
                _ = text.height(label, 16, 320);
            }
        }
        graphics.flush();
        shot.* = try graphics.capture();
        graphics.endFrame();
    }
    defer for (images) |shot| graphics.destroyImage(shot);
    const before = images[0];
    const after = images[1];
    try std.testing.expectEqual(before.w, after.w);
    try std.testing.expectEqual(before.h, after.h);
    var ink: usize = 0;
    var y: i32 = 0;
    while (y < before.h) : (y += 1) {
        var x: i32 = 0;
        while (x < before.w) : (x += 1) {
            if (!std.meta.eql(graphics.Color.white, graphics.imageColor(before, x, y))) ink += 1;
            try std.testing.expectEqual(
                graphics.imageColor(before, x, y),
                graphics.imageColor(after, x, y),
            );
        }
    }
    try std.testing.expect(ink > 100);
    // Even a viewport spanning multiple 2048-pixel tiles must draw to its
    // bottom. Synthetic 8x scale exercises this on an ordinary display.
    text.nextFrame(8);
    graphics.beginFrame();
    graphics.clear(graphics.Color.white);
    text.draw(
        "Visible text at every height\n" ** 40,
        20,
        0,
        16,
        300,
        graphics.Color.black,
        graphics.Color.white,
    );
    graphics.flush();
    const tall = try graphics.capture();
    graphics.endFrame();
    defer graphics.destroyImage(tall);
    ink = 0;
    y = @divTrunc(tall.h * 3, 4);
    while (y < tall.h) : (y += 1) {
        var x: i32 = 0;
        while (x < tall.w) : (x += 1) {
            if (!std.meta.eql(graphics.Color.white, graphics.imageColor(tall, x, y))) ink += 1;
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
    try openWindow(1120, 900, "Zimbr enrichment checks");
    defer closeWindow();
    desktop.poll();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
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
    for ([_]t.AssetRef{ photo, avatar }, [_]graphics.Color{ graphics.Color.red, graphics.Color.sky_blue }) |asset, color| {
        const pixels = try graphics.solidImage(160, 90, color);
        defer graphics.destroyImage(pixels);
        const texture = try graphics.upload(@ptrCast(pixels.pixels.?), pixels.w, pixels.h, .linear);
        try app.images.entries.put(std.heap.c_allocator, media.key(asset), .{
            .content = .{ .ready = texture },
        });
        app.images.bytes += 160 * 90 * 4;
    }
    for ([_]f32{
        1,
        1.25,
        2,
    }) |scale| {
        for (0..3) |_| testDraw(&app, scale);
        try std.testing.expectEqual(@as(usize, 1), app.history_rows.len);
        try std.testing.expect(app.rich_count >= 4);
        try std.testing.expect(app.images.bytes <= Media.texture_budget);
    }
    const areas = layout.frame(1120, 900, app.composerHeight());
    const row = app.history_rows[0];
    const x = areas.history.x + 66;
    var top = areas.history.y + @as(f32, @floatCast(row.top - app.scroll)) + 22;
    var first_image: ?graphics.Rect = null;
    for (row.blocks) |block| {
        const h = app.blockHeight(block, App.historyTextWidth(areas.history), true);
        const r = graphics.Rect{
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
    defer graphics.destroyImage(shot);
    const dpi = WindowMetrics.current().scale;
    try std.testing.expectEqual(
        graphics.Color.red,
        graphics.imageColor(shot, @intFromFloat((image_r.x + 80) * dpi), @intFromFloat((image_r.y + 45) * dpi)),
    );
    clickTestFrame(&app, image_r.x + 80, image_r.y + 45);
    try std.testing.expectEqualStrings("target", app.viewer_message);
    testInput(.{ .key_down = desktop.Key.right });
    try app.update();
    testInput(.{ .key_up = desktop.Key.right });
    try std.testing.expectEqual(@as(usize, 1), app.viewer_attachment);
    testInput(.{ .key_down = desktop.Key.escape });
    try app.update();
    testInput(.{ .key_up = desktop.Key.escape });
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
    testDraw(&app, 1);
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
    try openWindow(780, 560, "Zimbr attachment scroll checks");
    defer closeWindow();
    desktop.poll();
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
        const viewport = graphics.Rect{
            .x = 0,
            .y = 0,
            .width = 500,
            .height = 80,
        };

        fn draw(s: *App) void {
            s.processEvents() catch unreachable;
            s.controls.clearRetainingCapacity();
            _ = s.control_arena.reset(.retain_capacity);
            s.text.nextFrame(1);
            _ = s.frame_arena.reset(.retain_capacity);
            graphics.beginFrame();
            defer graphics.endFrame();
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
    testInput(.{ .motion = .{ .x = 20, .y = 20 } });
    testInput(.{ .wheel = 1 });
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

test "settings reset waits for relay confirmation before stopping the session for deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const data = try ar.dupeZ(u8, path_buffer[0..length]);
    const path = try std.fmt.allocPrintSentinel(ar, "{s}/client.db", .{data}, 0);
    const store = try Store.open(path);
    defer store.close();
    try store.saveDraft("chat", "Keep until confirmed and workers stop");
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = data } };
    defer worker.shutdown();
    try openWindow(780, 560, "Zimbr reset checks");
    defer closeWindow();
    desktop.poll();
    var app = App{
        .worker = &worker,
        .settings = try Settings.init(worker.config),
        .settings_scroll = std.math.inf(f32),
    };
    defer app.deinit();
    try app.settings.fields[0].set("https://unsaved.example");
    // This inert worker stands in for a configured connection in the UI test.
    app.settings.required = false;
    testDraw(&app, WindowMetrics.current().scale);
    const x = layout.frame(1120, 780, 0).sidebar.x + 32;
    const y = @as(f32, @floatFromInt(desktop.height())) - 120;
    const reset_size = app.buttonSize("Reset client and relay…");
    clickTestFrame(&app, x + reset_size.x / 2, y + reset_size.y / 2);
    try std.testing.expect(app.settings.confirm_reset and app.next_config == null);
    app.settings_scroll = std.math.inf(f32);
    testDraw(&app, WindowMetrics.current().scale);
    const confirm_size = app.buttonSize("Reset and resync");
    const keep_size = app.buttonSize("Keep local data");
    clickTestFrame(&app, x + confirm_size.x + 12 + keep_size.x / 2, y + keep_size.y / 2);
    try std.testing.expect(!app.settings.confirm_reset and app.next_config == null);
    app.settings_scroll = std.math.inf(f32);
    testDraw(&app, WindowMetrics.current().scale);
    clickTestFrame(&app, x + reset_size.x / 2, y + reset_size.y / 2);
    app.settings_scroll = std.math.inf(f32);
    testDraw(&app, WindowMetrics.current().scale);
    clickTestFrame(&app, x + confirm_size.x / 2, y + confirm_size.y / 2);
    // The contract now requires a relay acknowledgment before any local wipe.
    try std.testing.expect(app.next_config == null and app.settings.reset_pending);
    try std.testing.expectEqual(.reset, worker.commands.items[worker.commands.items.len - 1].kind);
    const publish = struct {
        fn result(target: *App, reset: Worker.Reset) !void {
            const view = try a.create(Worker.View);
            view.* = .{
                .arena = std.heap.ArenaAllocator.init(a),
                .snapshot = .{
                    .chats = &.{},
                    .messages = &.{},
                    .pending = &.{},
                    .selected = "",
                    .draft = "",
                    .epoch = "",
                    .more = false,
                },
                .status = "Reset result",
                .online = false,
                .send_direct = false,
                .reply_existing = false,
                .generation = 1,
                .ack = 0,
                .reset = reset,
            };
            target.worker.view = view;
            try target.update();
        }
    }.result;
    try publish(&app, .failed);
    try std.testing.expect(app.next_config == null and !app.settings.reset_pending);
    try std.testing.expectEqualStrings("Keep until confirmed and workers stop", try store.draft(ar, "chat"));
    try app.resetLocalData();
    try publish(&app, .complete);
    const next = app.next_config.?;
    try std.testing.expect(next.reset_cache and !next.settings);
    try std.testing.expectEqualStrings(data, next.data);
    try std.testing.expectEqualStrings("", next.relay_url);
    try std.testing.expectEqualStrings("Keep until confirmed and workers stop", try store.draft(ar, "chat"));
}

fn testKey(key: desktop.Key, down: bool) void {
    testInput(if (down) .{ .key_down = key } else .{ .key_up = key });
}

test "Details streams logs, preserves scrollback, and supports latest copy and clear" {
    try openWindow(1120, 780, "Zimbr log checks");
    defer closeWindow();
    desktop.poll();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var logs: LogBuffer = .{};
    for (0..LogBuffer.capacity) |i| logs.append(.info, .fixture, "Image {d}: disk cache hit", .{i});
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    defer worker.shutdown();
    var app = App{
        .worker = &worker,
        .show_details = true,
        .logs = &logs,
    };
    defer app.deinit();
    const scale = WindowMetrics.current().scale;
    testDraw(&app, scale);
    try std.testing.expect(app.logs_limit > 0);
    try std.testing.expectEqual(app.logs_limit, app.logs_scroll);
    const shot = try captureTestFrame(&app, scale);
    defer graphics.destroyImage(shot);
    try std.testing.expectEqual(theme.colors.surface, graphics.imageColor(
        shot,
        @intFromFloat(100 * scale),
        @intFromFloat(160 * scale),
    ));
    // Drive the nested scrollbar: the outer Details position must stay fixed.
    const details_scroll = app.details_scroll;
    const width: f32 = @floatFromInt(desktop.width());
    clickTestFrame(&app, width - 66, 220);
    try std.testing.expect(!app.logs_follow and app.logs_focused);
    try std.testing.expect(app.logs_scroll > 0 and app.logs_scroll < app.logs_limit);
    try std.testing.expectEqual(details_scroll, app.details_scroll);
    const anchor = app.logs_anchor;
    const offset = app.logs_anchor_offset;
    logs.append(.info, .fixture, "New download while reading earlier logs", .{});
    testDraw(&app, scale);
    try std.testing.expectEqual(anchor, app.logs_anchor);
    try std.testing.expectApproxEqAbs(offset, app.logs_anchor_offset, 0.01);

    // Focused keyboard scrolling uses the textbox rather than the page.
    testKey(.home, true);
    try app.update();
    testDraw(&app, scale);
    testKey(.home, false);
    try std.testing.expectEqual(@as(f32, 0), app.logs_scroll);
    try std.testing.expectEqual(details_scroll, app.details_scroll);
    clickTestFrame(&app, width - 217, 128);
    try std.testing.expect(app.logs_follow);
    try std.testing.expectEqual(app.logs_limit, app.logs_scroll);
    logs.append(.info, .fixture, "Newest visible event", .{});
    testDraw(&app, scale);
    try std.testing.expectEqual(app.logs_limit, app.logs_scroll);

    clickTestFrame(&app, width - 142, 128);
    const clipboard = (desktop.clipboardText() orelse "");
    try std.testing.expect(std.mem.endsWith(u8, clipboard, "Newest visible event\n"));
    try std.testing.expect(std.mem.indexOf(u8, clipboard, "disk cache hit") != null);
    clickTestFrame(&app, width - 68, 128);
    const cleared = try logs.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
    try std.testing.expectEqual(@as(f32, 0), app.logs_scroll);
    try std.testing.expect(app.logs_follow);
    logs.append(.info, .fixture, "Streaming resumes after clear", .{});
    testDraw(&app, scale);
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
    // Four samples smooth rounded shapes at fractional display scales.
    try openWindow(780, 560, "Zimbr settings checks");
    defer closeWindow();
    desktop.poll();
    var app = App{
        .worker = &worker,
        .settings = try Settings.init(worker.config),
        .config_allocator = ar,
        .focus = .settings_relay,
    };
    defer app.deinit();
    testDraw(&app, WindowMetrics.current().scale);
    // SDL events reach the same input consumer used by App.update.
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

test "Wayland drop backend preserves local filenames and never truncates rejected paths" {
    try openWindow(780, 560, "File drop backend");
    defer closeWindow();
    const uri = "file:///tmp/photo%20%F0%9F%91%8B.png\r\nfile://localhost/tmp/empty.txt\r\n";
    bridge.zc_drop_offer(uri, uri.len);
    const dropped = drop.take() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, 2), dropped.count);
    try std.testing.expectEqualStrings("/tmp/photo 👋.png", std.mem.sliceTo(&dropped.paths[0], 0));
    try std.testing.expectEqualStrings("/tmp/empty.txt", std.mem.sliceTo(&dropped.paths[1], 0));
    try std.testing.expect(drop.take() == null);
    const remote = "file://remote/tmp/photo.png";
    bridge.zc_drop_offer(remote, remote.len);
    try std.testing.expect(drop.take() == null);
    try std.testing.expect(drop.rejected());
    const too_long = "/" ++ "x" ** 4095;
    const invalid = [_][*c]const u8{too_long};
    bridge.zc_drop_paths(1, &invalid);
    try std.testing.expect(!(bridge.zc_drop_pending() != 0));
    try std.testing.expect(@import("client.zig").drop.rejected());
}

test "Korean composition owns Backspace and Enter without editing the committed draft" {
    const sdl = desktop.c;
    try openWindow(780, 560, "Korean input checks");
    defer closeWindow();
    desktop.poll();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .focus = .search };
    defer app.deinit();
    try app.search.set("앞 ");
    try app.update();

    var event = std.mem.zeroes(sdl.SDL_Event);
    event.edit.type = sdl.SDL_EVENT_TEXT_EDITING;
    event.edit.windowID = sdl.SDL_GetWindowID(desktop.window());
    event.edit.text = "ㅎ";
    event.edit.start = 1;
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    testKey(.backspace, true);
    try app.update();
    try std.testing.expectEqualStrings("앞 ", app.search.text.items);
    testKey(.backspace, false);

    event.edit.text = "한";
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    desktop.poll();
    try app.update();
    event = std.mem.zeroes(sdl.SDL_Event);
    event.text.type = sdl.SDL_EVENT_TEXT_INPUT;
    event.text.windowID = sdl.SDL_GetWindowID(desktop.window());
    event.text.text = "한";
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    testKey(.enter, true);
    try app.update();
    try std.testing.expectEqualStrings("앞 한", app.search.text.items);
    try std.testing.expectEqual(.search, app.focus);
    try app.search.history(false);
    try std.testing.expectEqualStrings("앞 ", app.search.text.items);
}

test "Korean preedit preserves selection and follows commits cancellation and editor focus" {
    const sdl = desktop.c;
    try openWindow(780, 560, "Korean preedit lifecycle");
    defer closeWindow();
    desktop.poll();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .focus = .search };
    defer app.deinit();
    try app.search.set("앞 old 뒤");
    app.search.anchor = "앞 ".len;
    app.search.caret = "앞 old".len;
    try app.update();
    try std.testing.expect(sdl.SDL_TextInputActive(desktop.window()));
    const id = sdl.SDL_GetWindowID(desktop.window());
    var edit = std.mem.zeroes(sdl.SDL_Event);
    edit.edit.type = sdl.SDL_EVENT_TEXT_EDITING;
    edit.edit.windowID = id;
    edit.edit.text = "한";
    edit.edit.start = 1;
    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    desktop.poll();
    try app.update();
    var buffer: [t.max_text]u8 = undefined;
    try std.testing.expectEqualStrings("앞 한 뒤", app.search.display(&buffer).text);
    try std.testing.expectEqualStrings("old", app.search.selected());
    try std.testing.expectEqual(@as(usize, 0), app.search.undo.items.len);
    try std.testing.expect(app.layout_pending);

    // A Korean syllable can commit and start its successor in the same poll.
    var commit = std.mem.zeroes(sdl.SDL_Event);
    commit.text.type = sdl.SDL_EVENT_TEXT_INPUT;
    commit.text.windowID = id;
    commit.text.text = "한";
    try std.testing.expect(sdl.SDL_PushEvent(&commit));
    edit.edit.text = "ㄱ";
    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    desktop.poll();
    try app.update();
    try std.testing.expectEqualStrings("앞 한 뒤", app.search.text.items);
    try std.testing.expectEqualStrings("앞 한ㄱ 뒤", app.search.display(&buffer).text);
    testKey(.escape, true);
    try app.update();
    try std.testing.expectEqualStrings("앞 한 뒤", app.search.display(&buffer).text);
    try std.testing.expectEqual(.search, app.focus);
    testKey(.escape, false);
    try app.search.history(false);
    try std.testing.expectEqualStrings("앞 old 뒤", app.search.text.items);
    try std.testing.expectEqualStrings("old", app.search.selected());

    app.focus = .composer;
    try app.update();
    edit.edit.text = "한";
    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    desktop.poll();
    try app.update();
    try std.testing.expect(!app.draft_dirty);
    testKey(.left_control, true);
    testKey(.f, true);
    try app.update();
    try std.testing.expectEqual(.search, app.focus);
    try std.testing.expectEqualStrings("한", app.composer.text.items);
    try std.testing.expect(app.draft_dirty);
    try std.testing.expectEqualStrings("", app.composer.preedit.items);
    testKey(.f, false);
    testKey(.left_control, false);

    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    desktop.poll();
    try app.update();
    var lost = std.mem.zeroes(sdl.SDL_Event);
    lost.window.type = sdl.SDL_EVENT_WINDOW_FOCUS_LOST;
    lost.window.windowID = id;
    try std.testing.expect(sdl.SDL_PushEvent(&lost));
    desktop.poll();
    try app.update();
    try std.testing.expectEqualStrings("", app.search.preedit.items);
    try std.testing.expectEqualStrings("앞 old 뒤", app.search.text.items);
    app.show_details = true;
    try app.update();
    try std.testing.expect(!sdl.SDL_TextInputActive(desktop.window()));
}

test "Korean preedit wraps scrolls and positions the native candidate area at the visible caret" {
    try openWindow(780, 560, "Korean preedit rendering");
    defer closeWindow();
    desktop.poll();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker };
    defer app.deinit();
    try app.update();
    const sdl = desktop.c;
    var event = std.mem.zeroes(sdl.SDL_Event);
    event.edit.type = sdl.SDL_EVENT_TEXT_EDITING;
    event.edit.windowID = sdl.SDL_GetWindowID(desktop.window());
    event.edit.text = "한글 " ** 20;
    event.edit.start = 60;
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    desktop.poll();
    try app.update();
    try std.testing.expectEqualStrings("", app.composer.text.items);
    const scale = WindowMetrics.current().scale;
    app.text.nextFrame(scale);
    graphics.beginFrame();
    defer graphics.endFrame();
    app.inputBox(&app.composer, .{
        .x = 40,
        .y = 40,
        .width = 160,
        .height = 74,
    }, "Message", .composer, true, theme.colors.surface);
    try std.testing.expect(app.composer_scroll > 0);
    var area: sdl.SDL_Rect = undefined;
    var cursor: c_int = undefined;
    try std.testing.expect(sdl.SDL_GetTextInputArea(desktop.window(), &area, &cursor));
    try std.testing.expect(area.x >= 51 and area.x < 189);
    try std.testing.expect(area.y >= 50 and area.y + area.h <= 104);
    try std.testing.expectEqual(@as(c_int, 0), cursor);
    const shot = try graphics.capture();
    defer graphics.destroyImage(shot);
    var accented: usize = 0;
    for (50..104) |y| for (51..189) |x| {
        const color = graphics.imageColor(shot, @intFromFloat(@as(f32, @floatFromInt(x)) * scale), @intFromFloat(@as(f32, @floatFromInt(y)) * scale));
        if (std.meta.eql(color, theme.colors.accent)) accented += 1;
    };
    // The underline spans text, beyond the narrow insertion caret.
    try std.testing.expect(accented > @as(usize, @intCast(area.h)) * 2);
}

test "Korean reset echoes are discarded once and fresh identical input is preserved" {
    try openWindow(780, 560, "Korean reset commits");
    defer closeWindow();
    desktop.poll();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .focus = .search };
    defer app.deinit();
    try app.update();
    const sdl = desktop.c;
    const id = sdl.SDL_GetWindowID(desktop.window());
    var edit = std.mem.zeroes(sdl.SDL_Event);
    edit.edit.type = sdl.SDL_EVENT_TEXT_EDITING;
    edit.edit.windowID = id;
    edit.edit.text = "한";
    edit.edit.start = 1;
    var commit = std.mem.zeroes(sdl.SDL_Event);
    commit.text.type = sdl.SDL_EVENT_TEXT_INPUT;
    commit.text.windowID = id;
    commit.text.text = "한";
    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    try app.update();
    app.rememberReset(&app.search);
    app.search.cancelPreedit();
    desktop.resetTextInput(true);
    try std.testing.expect(sdl.SDL_PushEvent(&commit));
    try app.update();
    try std.testing.expectEqualStrings("", app.search.text.items);
    try std.testing.expect(sdl.SDL_PushEvent(&commit));
    try app.update();
    try std.testing.expectEqualStrings("한", app.search.text.items);
    try app.search.set("");

    // Engines that cancel on reset produce no echo. Fresh typing must still work.
    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    try app.update();
    app.rememberReset(&app.search);
    app.search.cancelPreedit();
    desktop.resetTextInput(true);
    testKey(.a, true);
    try std.testing.expect(sdl.SDL_PushEvent(&commit));
    try app.update();
    try std.testing.expectEqualStrings("한", app.search.text.items);
    try app.search.set("");
    testKey(.a, false);
    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    try app.update();
    app.rememberReset(&app.search);
    app.search.cancelPreedit();
    desktop.resetTextInput(true);
    try std.testing.expect(sdl.SDL_PushEvent(&edit));
    try std.testing.expect(sdl.SDL_PushEvent(&commit));
    try app.update();
    try std.testing.expectEqualStrings("한", app.search.text.items);
    try app.search.set("");
}

test "SDL commits complete Unicode strings and preserves long clipboard pastes" {
    const sdl = @cImport({
        @cInclude("SDL3/SDL.h");
    });
    try openWindow(780, 560, "SDL input checks");
    defer closeWindow();
    desktop.poll();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .focus = .search };
    defer app.deinit();
    const window_id = sdl.SDL_GetWindowID(@ptrCast(desktop.window()));
    const committed = "你好 👋 e\u{301} " ** 64;
    var event = std.mem.zeroes(sdl.SDL_Event);
    event.text.type = sdl.SDL_EVENT_TEXT_INPUT;
    event.text.windowID = window_id;
    event.text.text = committed;
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    desktop.poll();
    try app.update();
    try std.testing.expectEqualStrings(committed, app.search.text.items);
    // A single IME commit is one editor operation and one undo step.
    try app.search.history(false);
    try std.testing.expectEqualStrings("", app.search.text.items);

    const clip = "clipboard 👋\n" ** 300;
    desktop.setClipboardText(clip);
    testKey(.left_control, true);
    testKey(.v, true);
    try app.update();
    testKey(.v, false);
    testKey(.left_control, false);
    try std.testing.expectEqualStrings(clip, app.search.text.items);
    try std.testing.expectEqualStrings(clip, desktop.clipboardText().?);
    try app.search.set("");

    // The Enter that accepts a composition must not activate the search field.
    event = std.mem.zeroes(sdl.SDL_Event);
    event.edit.type = sdl.SDL_EVENT_TEXT_EDITING;
    event.edit.windowID = window_id;
    event.edit.text = "にほん";
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    event = std.mem.zeroes(sdl.SDL_Event);
    event.key.type = sdl.SDL_EVENT_KEY_DOWN;
    event.key.windowID = window_id;
    event.key.scancode = sdl.SDL_SCANCODE_RETURN;
    event.key.key = sdl.SDLK_RETURN;
    event.key.key = sdl.SDLK_RETURN;
    event.key.down = true;
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    desktop.poll();
    try app.update();
    try std.testing.expectEqual(@TypeOf(app.focus).search, app.focus);
    try std.testing.expectEqualStrings("", app.search.text.items);
    event.key.type = sdl.SDL_EVENT_KEY_UP;
    event.key.down = false;
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    event = std.mem.zeroes(sdl.SDL_Event);
    event.text.type = sdl.SDL_EVENT_TEXT_INPUT;
    event.text.windowID = window_id;
    event.text.text = "日本語";
    try std.testing.expect(sdl.SDL_PushEvent(&event));
    desktop.poll();
    try app.update();
    try std.testing.expectEqualStrings("日本語", app.search.text.items);

    for (0..10000) |_| desktop.wake();
    try std.testing.expect(desktop.wait(100));
    try std.testing.expect(!desktop.wait(0));
}

test "composer consumes file drops and waits for reviewed attachments before an attachment-only send" {
    // Four samples smooth rounded shapes at fractional display scales.
    try openWindow(780, 560, "Attachment composer");
    defer closeWindow();
    desktop.poll();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = "new:peer@example.invalid";
    const files = [_]outgoing_attachments.Upload{
        .{
            .id = "ABEiM0RVZneImaq7zN3u_w",
            .name = "photo 👋.png",
            .mime_type = "image/png",
            .bytes = "71",
            .sha256 = "0" ** 64,
        },
        .{
            .id = "BBEiM0RVZneImaq7zN3u_w",
            .name = "empty.txt",
            .mime_type = "text/plain",
            .bytes = "0",
            .sha256 = "1" ** 64,
        },
    };
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "" } };
    defer worker.shutdown();
    const view = try a.create(Worker.View);
    view.* = .{
        .arena = .init(a),
        .snapshot = .{
            .chats = &.{},
            .messages = &.{},
            .pending = &.{},
            .selected = key,
            .draft = "",
            .epoch = "epoch",
            .more = false,
        },
        .status = "Connected",
        .online = true,
        .send_direct = true,
        .reply_existing = true,
        .send_attachments = true,
        .generation = 1,
        .ack = 0,
    };
    var app = App{
        .worker = &worker,
        .view = view,
        .key = try a.dupe(u8, key),
        .loaded_key = try a.dupe(u8, key),
    };
    defer app.deinit();
    testDraw(&app, WindowMetrics.current().scale);
    const empty_height = app.composerHeight();
    const scale = WindowMetrics.current().scale;
    const empty_box = App.composerBox(layout.frame(780, 560, empty_height).composer);
    const sample_x: i32 = @intFromFloat((empty_box.x + 8) * scale);
    const sample_y: i32 = @intFromFloat((empty_box.y + empty_box.height - 8) * scale);
    bridge.zc_drop_set_hovered(1);
    defer bridge.zc_drop_set_hovered(0);
    {
        const shot = try captureTestFrame(&app, scale);
        defer graphics.destroyImage(shot);
        try std.testing.expectEqual(theme.colors.drop_surface, graphics.imageColor(shot, sample_x, sample_y));
        // A solid outline has no gaps; a missing outline has no blue dots.
        var dots: usize = 0;
        var gaps: usize = 0;
        var previous_blue = false;
        var x: i32 = @intFromFloat((empty_box.x + 12) * scale);
        while (x < @as(i32, @intFromFloat((empty_box.x + empty_box.width - 12) * scale))) : (x += 1) {
            const pixel = graphics.imageColor(shot, x, @intFromFloat((empty_box.y - 1) * scale));
            const blue = pixel.b > 100 and pixel.b > pixel.r;
            if (blue and !previous_blue) dots += 1;
            if (!blue) gaps += 1;
            previous_blue = blue;
        }
        try std.testing.expect(dots > 10 and gaps > 10);
        if (u.c.getenv("ZIMBR_GUI_DROP_SCREENSHOT")) |path|
            try graphics.saveImage(shot, std.mem.span(path));
    }
    bridge.zc_drop_set_hovered(0);
    {
        const shot = try captureTestFrame(&app, scale);
        defer graphics.destroyImage(shot);
        try std.testing.expectEqual(theme.colors.surface, graphics.imageColor(shot, sample_x, sample_y));
    }
    bridge.zc_drop_set_hovered(1);
    app.send_wait = true;
    {
        const shot = try captureTestFrame(&app, scale);
        defer graphics.destroyImage(shot);
        try std.testing.expectEqual(theme.colors.surface, graphics.imageColor(shot, sample_x, sample_y));
    }
    app.send_wait = false;
    const paths = [_][*c]const u8{ "/tmp/photo 👋.png", "/tmp/empty.txt" };
    bridge.zc_drop_paths(paths.len, &paths);
    try std.testing.expect(!drop.hovered());
    try app.update();
    try std.testing.expect(!(bridge.zc_drop_pending() != 0) and app.filesPending() and !app.canSend());
    var count: usize = 0;
    for (worker.commands.items) |command| if (command.kind == .attach) {
        try std.testing.expectEqualStrings(key, command.key);
        try std.testing.expectEqualStrings(std.mem.span(paths[count]), command.text);
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), count);
    view.command_serial = app.files_serial;
    view.preparing_attachments = true;
    view.preparing_draft = true;
    try std.testing.expect(!app.canSend());
    view.snapshot.draft_attachments = &files;
    view.preparing_attachments = false;
    view.preparing_draft = false;
    try std.testing.expect(app.canSend());
    try std.testing.expectEqual(empty_height + 80, app.composerHeight());
    testDraw(&app, WindowMetrics.current().scale);
    if (u.c.getenv("ZIMBR_GUI_SCREENSHOT")) |path| {
        const shot = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer graphics.destroyImage(shot);
        try graphics.saveImage(shot, std.mem.span(path));
    }
    const areas = layout.frame(780, 560, app.composerHeight());
    const box = App.composerBox(areas.composer);
    clickTestFrame(&app, box.x + box.width - 15, box.y + 11);
    try std.testing.expectEqual(@as(usize, 1), app.attachment_index);
    clickTestFrame(&app, box.x + box.width - 38, box.y + 49);
    const removal = worker.commands.items[worker.commands.items.len - 1];
    try std.testing.expectEqual(.remove_attachment, removal.kind);
    try std.testing.expectEqualStrings(files[1].id, removal.text);
    try std.testing.expect(!app.canSend());
    view.snapshot.draft_attachments = files[0..1];
    view.command_serial = app.files_serial;
    view.online = false;
    try std.testing.expect(!app.canSend());
    view.online = true;
    view.send_attachments = false;
    try std.testing.expect(!app.canSend());
    view.send_attachments = true;
    try std.testing.expect(app.canSend());
    testKey(.left_control, false);
    testKey(.right_control, false);
    testKey(.enter, true);
    try app.update();
    testKey(.enter, false);
    const send_command = worker.commands.items[worker.commands.items.len - 1];
    try std.testing.expectEqual(.send, send_command.kind);
    try std.testing.expectEqualStrings(key, send_command.key);
    try std.testing.expectEqualStrings("", send_command.text);
    try std.testing.expect(app.send_wait and !app.canSend());

    app.send_wait = false;
    view.snapshot.draft_attachments = &.{};
    var pending = [_]Store.Pending{.{
        .input = .{
            .request_id = "request",
            .server_epoch = "epoch",
            .target = .{ .recipient = .{ .address = "peer@example.invalid", .service = "imessage" } },
            .text = "Caption",
            .attachments = &files,
        },
        .state = "uploading",
        .detail = "",
        .record = null,
        .sent_at = "2026-01-01T00:00:00Z",
    }};
    view.snapshot.pending = &pending;
    view.upload = .{
        .request_id = "request",
        .filename = files[0].name,
        .bytes = 35,
        .total = 71,
        .phase = "transfer",
    };
    view.generation += 1;
    testDraw(&app, WindowMetrics.current().scale);
    try std.testing.expectEqual(@as(usize, 3), app.history_rows[0].blocks.len);
    try std.testing.expect(!display.canCopyPending("uploading", pending[0].sent_at, u.now()));
    const history = layout.frame(780, 560, app.composerHeight()).history;
    const action_x = history.x + 66 + App.historyTextWidth(history) - 59;
    const action_y = history.y + @as(f32, @floatCast(app.history_rows[0].top - app.scroll)) + 8;
    clickTestFrame(&app, action_x, action_y);
    const cancellation = worker.commands.items[worker.commands.items.len - 1];
    try std.testing.expectEqual(.cancel_upload, cancellation.kind);
    try std.testing.expectEqualStrings("request", cancellation.key);
    try std.testing.expectEqualStrings("", app.composer.text.items);
    view.command_serial = app.files_serial;
    pending[0].state = "cancelled";
    view.generation += 1;
    testDraw(&app, WindowMetrics.current().scale);
    clickTestFrame(&app, action_x, action_y);
    try std.testing.expectEqualStrings("Caption", app.composer.text.items);
    try std.testing.expect(!app.duplicate_risk);
    try std.testing.expectEqual(@as(usize, 0), app.draftFiles().len);
    try std.testing.expectEqual(@as(usize, 2), pending[0].input.attachments.len);
}

test "native file drops reach the synthetic relay with reviewed original bytes" {
    const io = std.testing.io;
    var fixture = try std.process.spawn(io, .{
        .argv = &.{ "python3", "tests/gui_attachment_fixture.py" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer {
        if (fixture.stdin) |input| input.close(io);
        fixture.stdin = null;
        if (fixture.id != null) _ = fixture.wait(io) catch {
            fixture.kill(io);
        };
    }
    var buffer: [16384]u8 = undefined;
    var reader = fixture.stdout.?.readerStreaming(io, &buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ready = try std.json.parseFromSliceLeaky(struct {
        config: Config,
        paths: []const [:0]const u8,
    }, arena.allocator(), try reader.interface.takeDelimiterInclusive('\n'), .{ .allocate = .alloc_always });

    // Four samples smooth rounded shapes at fractional display scales.
    try openWindow(780, 560, "Attachment integration");
    defer closeWindow();
    desktop.poll();
    var worker = Worker{ .io = io, .config = ready.config };
    var media = Media{ .io = io, .config = ready.config };
    var app = App{ .worker = &worker, .media = &media };
    defer app.deinit();
    try worker.start();
    defer worker.shutdown();
    try media.start();
    defer media.shutdown();
    const key = "new:alice@example.invalid";
    try app.select(key);
    const ready_deadline = u.now() + 10000;
    while (true) {
        try attachmentTestFrame(&app, ready_deadline);
        if (app.view) |view| if (view.online and view.send_attachments and app.pending_key == null and u.eq(app.loaded_key, key)) break;
    }

    var paths: [3][*c]const u8 = undefined;
    try std.testing.expectEqual(paths.len, ready.paths.len);
    for (&paths, ready.paths) |*dest, path| dest.* = path.ptr;
    bridge.zc_drop_paths(paths.len, &paths);
    try app.update();
    try std.testing.expect(!app.canSend());
    const stage_deadline = u.now() + 10000;
    while (app.draftFiles().len != 3 or !app.canSend()) try attachmentTestFrame(&app, stage_deadline);
    try std.testing.expectEqualStrings("photo 👋.png", app.draftFiles()[0].name);
    try std.testing.expectEqualStrings("0", app.draftFiles()[1].bytes);
    try std.testing.expectEqualStrings("262144", app.draftFiles()[2].bytes);
    while (true) {
        try attachmentTestFrame(&app, stage_deadline);
        if (app.images.getLocal(&media, app.draftFiles()[0])) |entry| if (entry.availableTexture()) |texture| {
            try std.testing.expectEqual(@as(i32, 2), texture.w);
            try std.testing.expectEqual(@as(i32, 3), texture.h);
            break;
        };
    }
    try fixture.stdin.?.writeStreamingAll(io, "staged\n");
    try std.testing.expectEqualStrings("\"changed\"\n", try reader.interface.takeDelimiterInclusive('\n'));
    try app.composer.insert("Reviewed caption 👋");
    app.draft_dirty = true;
    app.draft_at = u.now();
    if (u.c.getenv("ZIMBR_GUI_ATTACHMENT_SCREENSHOT")) |path| {
        const shot = try captureTestFrame(&app, WindowMetrics.current().scale);
        defer graphics.destroyImage(shot);
        try graphics.saveImage(shot, std.mem.span(path));
    }
    testKey(.left_control, false);
    testKey(.right_control, false);
    testKey(.enter, true);
    try app.update();
    testKey(.enter, false);
    try std.testing.expect(app.send_wait);

    const delivery_deadline = u.now() + 25000;
    while (true) {
        try attachmentTestFrame(&app, delivery_deadline);
        const snapshot = app.view.?.snapshot;
        var captions: usize = 0;
        var files: usize = 0;
        for (snapshot.messages) |message| {
            if (message.direction != .outgoing or message.observed_status != .delivered) continue;
            if (message.text) |text| if (u.eq(text, "Reviewed caption 👋")) {
                captions += 1;
            };
            files += message.attachments.len;
        }
        if (captions == 1 and files == 3 and snapshot.pending.len == 0) break;
    }
    while (std.mem.startsWith(u8, app.key, "new:")) try attachmentTestFrame(&app, delivery_deadline);
    try std.testing.expectEqual(@as(usize, 0), app.draftFiles().len);
    try std.testing.expectEqualStrings("", app.composer.text.items);
    try fixture.stdin.?.writeStreamingAll(io, "verify\n");
    try std.testing.expectEqualStrings("\"verified\"\n", try reader.interface.takeDelimiterInclusive('\n'));
    fixture.stdin.?.close(io);
    fixture.stdin = null;
    const term = try fixture.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

fn attachmentTestFrame(app: *App, deadline: i64) !void {
    if (u.now() >= deadline) {
        std.debug.print("Attachment GUI timeout: selected={s}, notice={s}, status={s}\n", .{
            app.key,
            app.notice,
            if (app.view) |view| view.status else "no snapshot",
        });
        return error.TestUnexpectedResult;
    }
    try app.update();
    app.deliverNotifications();
    testDraw(app, WindowMetrics.current().scale);
    desktop.sleep(0.01);
}

fn testDraw(app: *App, scale: f32) void {
    app.processEvents() catch unreachable;
    app.draw(scale);
    graphics.endFrame();
}

fn openWindow(width: i32, height: i32, title: [:0]const u8) !void {
    try desktop.open(width, height, title);
    errdefer desktop.close();
    try graphics.init();
    if (comptime builtin.is_test) {
        test_pointer = .{ .x = 0, .y = 0 };
        test_modifiers = 0;
    }
}
fn closeWindow() void {
    graphics.deinit();
    desktop.close();
}

const TestInput = union(enum) {
    motion: struct { x: i32, y: i32 },
    button_down: desktop.Button,
    button_up: desktop.Button,
    key_down: desktop.Key,
    key_up: desktop.Key,
    wheel: f32,
};
var test_pointer: graphics.Point = .{ .x = 0, .y = 0 };
var test_modifiers: desktop.c.SDL_Keymod = 0;
fn testInput(input: TestInput) void {
    const sdl = desktop.c;
    var event = std.mem.zeroes(sdl.SDL_Event);
    const id = sdl.SDL_GetWindowID(desktop.window());
    switch (input) {
        .motion => |point| {
            test_pointer = .{ .x = @floatFromInt(point.x), .y = @floatFromInt(point.y) };
            event.motion.type = sdl.SDL_EVENT_MOUSE_MOTION;
            event.motion.windowID = id;
            event.motion.x = @floatFromInt(point.x);
            event.motion.y = @floatFromInt(point.y);
        },
        .button_down, .button_up => |button| {
            event.button.type = if (input == .button_down) sdl.SDL_EVENT_MOUSE_BUTTON_DOWN else sdl.SDL_EVENT_MOUSE_BUTTON_UP;
            event.button.windowID = id;
            event.button.button = @intCast(@intFromEnum(button));
            event.button.down = input == .button_down;
            event.button.x = test_pointer.x;
            event.button.y = test_pointer.y;
        },
        .key_down, .key_up => |key| {
            event.key.type = if (input == .key_down) sdl.SDL_EVENT_KEY_DOWN else sdl.SDL_EVENT_KEY_UP;
            event.key.windowID = id;
            const bit: sdl.SDL_Keymod = switch (key) {
                .left_control => sdl.SDL_KMOD_LCTRL,
                .right_control => sdl.SDL_KMOD_RCTRL,
                .left_shift => sdl.SDL_KMOD_LSHIFT,
                .right_shift => sdl.SDL_KMOD_RSHIFT,
                .left_alt => sdl.SDL_KMOD_LALT,
                .right_alt => sdl.SDL_KMOD_RALT,
                .left_super => sdl.SDL_KMOD_LGUI,
                .right_super => sdl.SDL_KMOD_RGUI,
                .a,
                .b,
                .c,
                .d,
                .e,
                .f,
                .g,
                .h,
                .i,
                .j,
                .k,
                .l,
                .m,
                .n,
                .o,
                .p,
                .q,
                .r,
                .s,
                .t,
                .u,
                .v,
                .w,
                .x,
                .y,
                .z,
                .enter,
                .escape,
                .backspace,
                .tab,
                .space,
                .comma,
                .home,
                .page_up,
                .delete,
                .end,
                .page_down,
                .right,
                .left,
                .down,
                .up,
                .kp_enter,
                => 0,
            };
            if (input == .key_down) test_modifiers |= bit else test_modifiers &= ~bit;
            event.key.mod = test_modifiers;
            event.key.key = @intFromEnum(key);
            event.key.scancode = sdl.SDL_GetScancodeFromKey(@intFromEnum(key), null);
            event.key.down = input == .key_down;
        },
        .wheel => |delta| {
            event.wheel.type = sdl.SDL_EVENT_MOUSE_WHEEL;
            event.wheel.windowID = id;
            event.wheel.y = delta;
            event.wheel.mouse_x = test_pointer.x;
            event.wheel.mouse_y = test_pointer.y;
        },
    }
    std.debug.assert(sdl.SDL_PushEvent(&event));
    desktop.poll();
}

fn automationOverlay(bounds: zrct.Rect, label: []const u8) void {
    graphics.outline(.{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    }, 1, .{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    });
    var text: Text = .{};
    defer text.deinit();
    text.nextFrame(desktop.scale().x);
    text.drawLine(label, bounds.x, bounds.y, 12, bounds.width, .{
        .r = 255,
        .g = 255,
        .b = 0,
        .a = 255,
    }, null);
}

test "SDL event queue retains short clicks repeat wheel precision and focus release" {
    try openWindow(640, 480, "SDL event ordering");
    defer closeWindow();
    desktop.poll();
    while (desktop.nextEvent() != null) {}
    const c = desktop.c;
    const id = c.SDL_GetWindowID(desktop.window());
    var event = std.mem.zeroes(c.SDL_Event);
    event.button = .{
        .type = c.SDL_EVENT_MOUSE_BUTTON_DOWN,
        .windowID = id,
        .button = c.SDL_BUTTON_LEFT,
        .down = true,
        .x = 31.5,
        .y = 40.25,
    };
    try std.testing.expect(c.SDL_PushEvent(&event));
    event.button.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.down = false;
    event.button.x = 90;
    try std.testing.expect(c.SDL_PushEvent(&event));
    const down = desktop.nextEvent().?;
    try std.testing.expectEqual(@as(u32, c.SDL_EVENT_MOUSE_BUTTON_DOWN), down.type);
    try std.testing.expect(desktop.leftDown());
    try std.testing.expect(desktop.inputHeld());
    try std.testing.expectEqual(graphics.Point{ .x = 31.5, .y = 40.25 }, desktop.mouse());
    const up = desktop.nextEvent().?;
    try std.testing.expectEqual(@as(u32, c.SDL_EVENT_MOUSE_BUTTON_UP), up.type);
    try std.testing.expect(!desktop.leftDown());
    try std.testing.expect(!desktop.inputHeld());
    try std.testing.expectEqual(@as(f32, 90), desktop.mouse().x);

    event = std.mem.zeroes(c.SDL_Event);
    event.key.type = c.SDL_EVENT_KEY_DOWN;
    event.key.windowID = id;
    event.key.key = c.SDLK_BACKSPACE;
    event.key.scancode = c.SDL_SCANCODE_BACKSPACE;
    event.key.mod = c.SDL_KMOD_SHIFT;
    event.key.down = true;
    try std.testing.expect(c.SDL_PushEvent(&event));
    event.key.repeat = true;
    try std.testing.expect(c.SDL_PushEvent(&event));
    try std.testing.expect(!desktop.nextEvent().?.key.repeat);
    try std.testing.expect(desktop.nextEvent().?.key.repeat);
    try std.testing.expect(desktop.inputHeld());
    try std.testing.expectEqual(@as(c.SDL_Keymod, c.SDL_KMOD_SHIFT), desktop.modifiers());
    event.key.type = c.SDL_EVENT_KEY_UP;
    event.key.down = false;
    event.key.repeat = false;
    try std.testing.expect(c.SDL_PushEvent(&event));
    _ = desktop.nextEvent();
    try std.testing.expect(!desktop.inputHeld());
    event.key.type = c.SDL_EVENT_KEY_DOWN;
    event.key.down = true;
    try std.testing.expect(c.SDL_PushEvent(&event));
    _ = desktop.nextEvent();
    try std.testing.expect(desktop.inputHeld());
    event = std.mem.zeroes(c.SDL_Event);
    event.wheel.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.windowID = id;
    event.wheel.y = 0.25;
    for (0..2) |_| try std.testing.expect(c.SDL_PushEvent(&event));
    for (0..2) |_| try std.testing.expectEqual(@as(f32, 0.25), desktop.nextEvent().?.wheel.y);
    event = std.mem.zeroes(c.SDL_Event);
    event.window.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
    event.window.windowID = id;
    try std.testing.expect(c.SDL_PushEvent(&event));
    _ = desktop.nextEvent();
    try std.testing.expectEqual(@as(c.SDL_Keymod, 0), desktop.modifiers());
    try std.testing.expect(!desktop.leftDown());
    try std.testing.expect(!desktop.inputHeld());
}

test "text shortcuts and repeated keys preserve SDL event order and modifiers" {
    try openWindow(780, 560, "Ordered editing");
    defer closeWindow();
    var worker = Worker{ .io = std.testing.io, .config = .{ .data = "/tmp/unused" } };
    defer worker.shutdown();
    var app = App{ .worker = &worker, .focus = .search };
    defer app.deinit();
    try app.update();
    try app.search.set("abc");
    const c = desktop.c;
    var text = std.mem.zeroes(c.SDL_Event);
    text.text.type = c.SDL_EVENT_TEXT_INPUT;
    text.text.windowID = c.SDL_GetWindowID(desktop.window());
    testKey(.left, true);
    text.text.text = "X";
    try std.testing.expect(c.SDL_PushEvent(&text));
    testKey(.left, false);
    testKey(.left, true);
    text.text.text = "Y";
    try std.testing.expect(c.SDL_PushEvent(&text));
    try app.update();
    try std.testing.expectEqualStrings("abYXc", app.search.text.items);
    try std.testing.expectEqual(@as(usize, 3), app.search.caret);

    var repeated = std.mem.zeroes(c.SDL_Event);
    repeated.key.type = c.SDL_EVENT_KEY_DOWN;
    repeated.key.key = c.SDLK_BACKSPACE;
    repeated.key.down = true;
    repeated.key.repeat = true;
    for (0..2) |_| try std.testing.expect(c.SDL_PushEvent(&repeated));
    try app.update();
    try std.testing.expectEqualStrings("aXc", app.search.text.items);
    testKey(.left_control, true);
    testKey(.a, true);
    testKey(.a, false);
    testKey(.left_control, false);
    try app.update();
    try std.testing.expectEqualStrings("aXc", app.search.selected());

    // Semantic shortcuts follow the translated key, even on a different physical key.
    var shortcut = std.mem.zeroes(c.SDL_Event);
    shortcut.key.type = c.SDL_EVENT_KEY_DOWN;
    shortcut.key.key = c.SDLK_N;
    shortcut.key.scancode = c.SDL_SCANCODE_Q;
    shortcut.key.mod = c.SDL_KMOD_CTRL;
    shortcut.key.down = true;
    try std.testing.expect(c.SDL_PushEvent(&shortcut));
    text.text.text = "new@example.invalid";
    try std.testing.expect(c.SDL_PushEvent(&text));
    try app.update();
    try std.testing.expect(app.new_mode);
    try std.testing.expectEqualStrings("new@example.invalid", app.recipient.text.items);
    try std.testing.expectEqualStrings("aXc", app.search.text.items);

    testDraw(&app, WindowMetrics.current().scale);
    try app.search.set("");
    try app.recipient.set("");
    // Both clicks and commits arrive before another frame; each event owns its target.
    for ([_]App.Focus{ .search, .recipient }, [_][*:0]const u8{ "Find", "peer@example.invalid" }) |focus, committed| {
        const bounds = for (app.controls.items) |control| {
            if (control.action == .editor and control.action.editor.focus == focus) break control.bounds;
        } else return error.TestUnexpectedResult;
        testInput(.{ .motion = .{ .x = @intFromFloat(bounds.x + 8), .y = @intFromFloat(bounds.y + 8) } });
        testInput(.{ .button_down = .left });
        testInput(.{ .button_up = .left });
        text.text.text = committed;
        try std.testing.expect(c.SDL_PushEvent(&text));
    }
    try app.update();
    try std.testing.expectEqualStrings("Find", app.search.text.items);
    try std.testing.expectEqualStrings("peer@example.invalid", app.recipient.text.items);
}
