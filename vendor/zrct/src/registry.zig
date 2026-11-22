//! Frame-local semantic targets. All published strings are owned by the snapshot arena.
const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn from(r: anytype) Rect {
        return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    }

    pub fn intersection(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        return .{ .x = x, .y = y, .width = @max(0, @min(a.x + a.width, b.x + b.width) - x), .height = @max(0, @min(a.y + a.height, b.y + b.height) - y) };
    }

    pub fn contains(r: Rect, x: f32, y: f32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height;
    }
};

pub const Target = struct {
    id: []const u8,
    role: []const u8,
    label: []const u8 = "",
    bounds: Rect,
    clip: ?Rect = null,
    parent: []const u8 = "",
    enabled: bool = true,
    selected: bool = false,
    expanded: ?bool = null,
    visible: bool = true,
    obscured: bool = false,
    status: []const u8 = "",
    value: []const u8 = "",
    // Later registered interactive targets win hit tests, matching painter order.
    interactive: bool = true,
    /// Populated by the registry; snapshot text is a UTF-8 preview, never a full-value claim.
    strings: Strings = .{},

    pub const TextInfo = struct { bytes: usize = 0, truncated: bool = false, sha256: ?[]const u8 = null };
    pub const Strings = struct { label: TextInfo = .{}, status: TextInfo = .{}, value: TextInfo = .{} };

    pub fn visibleBounds(t: Target) Rect {
        return if (t.clip) |clip| t.bounds.intersection(clip) else t.bounds;
    }
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    // Arrays outlive a frame so registration does not regrow and copy them on
    // every draw. Their strings remain owned by the resettable frame arena.
    targets: std.ArrayList(Target) = .empty,
    frame_id: u64 = 0,
    overflow: bool = false,
    full_text: std.ArrayList(FullText) = .empty,
    full_bytes: usize = 0,
    pub const capacity = 2048;
    pub const preview_limit = 4096;
    pub const content_limit = 65536;
    pub const content_budget = 512 * 1024;
    const FullText = struct { index: usize, field: []const u8, text: []const u8 };

    pub fn init(a: std.mem.Allocator) Registry {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(s: *Registry) void {
        s.targets.deinit(s.arena.child_allocator);
        s.full_text.deinit(s.arena.child_allocator);
        s.arena.deinit();
        s.* = undefined;
    }
    pub fn clear(s: *Registry, frame_id: u64) void {
        _ = s.arena.reset(.retain_capacity);
        s.targets.clearRetainingCapacity();
        s.frame_id = frame_id;
        s.overflow = false;
        s.full_text.clearRetainingCapacity();
        s.full_bytes = 0;
    }
    pub fn add(s: *Registry, input: Target) !void {
        if (s.targets.items.len == capacity) {
            s.overflow = true;
            return;
        }
        const a = s.arena.allocator();
        var target = input;
        inline for (.{ "id", "role", "label", "parent", "status", "value" }) |field| {
            const bytes = @field(input, field);
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            if (comptime std.mem.eql(u8, field, "id") or std.mem.eql(u8, field, "role") or std.mem.eql(u8, field, "parent")) {
                if (bytes.len > preview_limit) return error.IdentityTooLong;
            } else {
                var info = &@field(target.strings, field);
                info.* = .{ .bytes = bytes.len, .truncated = bytes.len > preview_limit };
                if (info.truncated) {
                    var digest: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                    info.sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
                    if (bytes.len <= content_limit and s.full_bytes + bytes.len <= content_budget) {
                        try s.full_text.append(s.arena.child_allocator, .{ .index = s.targets.items.len, .field = field, .text = try a.dupe(u8, bytes) });
                        s.full_bytes += bytes.len;
                    }
                }
            }
            @field(target, field) = try a.dupe(u8, bytes[0..utf8Prefix(bytes, preview_limit)]);
        }
        const bounds = target.visibleBounds();
        target.visible = target.visible and bounds.width > 0 and bounds.height > 0;
        try s.targets.append(s.arena.child_allocator, target);
    }
    pub const Query = struct {
        id: ?[]const u8 = null,
        role: ?[]const u8 = null,
        text: ?[]const u8 = null,
        within: ?[]const u8 = null,
    };

    /// Return borrowed targets in registration order; the result array belongs to allocator.
    /// Expand ancestry before filtering, including cycles and duplicate parent identities.
    pub fn select(s: *const Registry, allocator: std.mem.Allocator, query: Query) ![]const Target {
        var parents: std.StringHashMapUnmanaged(void) = .empty;
        defer parents.deinit(allocator);
        if (query.within) |within| if (within.len > 0) {
            try parents.put(allocator, within, {});
            while (true) {
                const before = parents.count();
                for (s.targets.items) |target| {
                    if (parents.contains(target.parent)) try parents.put(allocator, target.id, {});
                }
                if (parents.count() == before) break;
            }
        };
        var selected: std.ArrayList(Target) = .empty;
        errdefer selected.deinit(allocator);
        for (s.targets.items) |target| {
            if (parents.count() > 0 and !parents.contains(target.parent)) continue;
            if (query.id) |id| if (!std.mem.eql(u8, target.id, id)) continue;
            if (query.role) |role| if (!std.mem.eql(u8, target.role, role)) continue;
            if (query.text) |text| if (std.mem.find(u8, target.label, text) == null) continue;
            try selected.append(allocator, target);
        }
        return selected.toOwnedSlice(allocator);
    }
    pub const Point = struct { x: f32, y: f32 };
    pub const ResolveError = error{ MissingTarget, AmbiguousTarget, DisabledTarget, OffscreenTarget, ObscuredTarget, TruncatedSnapshot };
    pub fn lookup(s: *const Registry, id: []const u8) ResolveError!usize {
        if (s.overflow) return error.TruncatedSnapshot;
        var found: ?usize = null;
        for (s.targets.items, 0..) |t, i| {
            if (!std.mem.eql(u8, t.id, id)) continue;
            if (found != null) return error.AmbiguousTarget;
            found = i;
        }
        return found orelse error.MissingTarget;
    }
    pub fn content(s: *const Registry, id: []const u8, field: []const u8, limit: usize) ![]const u8 {
        const index = try s.lookup(id);
        inline for (.{ "label", "status", "value" }) |name| {
            if (std.mem.eql(u8, name, field)) {
                const t = s.targets.items[index];
                const info = @field(t.strings, name);
                if (info.bytes > limit) return error.ContentLimit;
                if (!info.truncated) return @field(t, name);
                for (s.full_text.items) |full| {
                    if (full.index == index and std.mem.eql(u8, full.field, name)) return full.text;
                }
                return error.ContentUnavailable;
            }
        }
        return error.InvalidTextField;
    }
    pub fn resolve(s: *const Registry, id: []const u8) ResolveError!Point {
        return s.resolvePoint(id, false);
    }
    pub fn resolveScroll(s: *const Registry, id: []const u8) ResolveError!Point {
        return s.resolvePoint(id, true);
    }
    fn descendant(s: *const Registry, target: Target, id: []const u8) bool {
        var parent = target.parent;
        for (0..s.targets.items.len) |_| {
            if (parent.len == 0) return false;
            if (std.mem.eql(u8, parent, id)) return true;
            parent = for (s.targets.items) |item| {
                if (std.mem.eql(u8, item.id, parent)) break item.parent;
            } else return false;
        }
        return false;
    }
    fn resolvePoint(s: *const Registry, id: []const u8, scroll: bool) ResolveError!Point {
        const index = try s.lookup(id);
        const t = s.targets.items[index];
        if (!t.enabled) return error.DisabledTarget;
        if (!t.visible) return error.OffscreenTarget;
        if (t.obscured) return error.ObscuredTarget;
        const bounds = t.visibleBounds();
        // Try a small inset grid so an overlapping disclosure doesn't hide an entire row.
        for ([_]f32{ 0.5, 0.25, 0.75, 0.1, 0.9 }) |xf| {
            for ([_]f32{ 0.5, 0.25, 0.75 }) |yf| {
                const x = bounds.x + bounds.width * xf;
                const y = bounds.y + bounds.height * yf;
                const obscured = for (s.targets.items[index + 1 ..]) |other| {
                    if (scroll and s.descendant(other, id)) continue;
                    if (other.visible and other.interactive and other.visibleBounds().contains(x, y)) break true;
                } else false;
                if (!obscured) return .{ .x = x, .y = y };
            }
        }
        return error.ObscuredTarget;
    }
};

test "query retains registration order, duplicate identities and ancestry through filtered parents" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const box = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try r.add(.{ .id = "leaf", .role = "button", .label = "Hello 👋", .parent = "branch", .bounds = box });
    try r.add(.{ .id = "branch", .role = "group", .parent = "root", .bounds = box });
    try r.add(.{ .id = "root", .role = "group", .parent = "branch", .bounds = box });
    try r.add(.{ .id = "leaf", .role = "button", .label = "Another 👋", .parent = "root", .bounds = box });
    try r.add(.{ .id = "outside", .role = "button", .label = "👋", .bounds = box });
    const matches = try r.select(std.testing.allocator, .{ .within = "root", .role = "button", .text = "👋" });
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(2, matches.len);
    try std.testing.expectEqualStrings("Hello 👋", matches[0].label);
    try std.testing.expectEqualStrings("Another 👋", matches[1].label);
    try std.testing.expectError(error.AmbiguousTarget, r.lookup("leaf"));
}

/// Input must be valid UTF-8. Return the largest complete prefix within the byte limit.
pub fn utf8Prefix(bytes: []const u8, limit: usize) usize {
    var end = @min(bytes.len, limit);
    while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

test "long Unicode previews report truncation and retain bounded full content" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const text = &@as([4095:0]u8, @splat('a')) ++ "🙂" ++ "tail";
    try r.add(.{ .id = "draft", .role = "textbox", .value = text, .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } });
    const target = r.targets.items[0];
    try std.testing.expectEqual(4095, target.value.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(target.value));
    try std.testing.expect(target.strings.value.truncated);
    try std.testing.expectEqual(text.len, target.strings.value.bytes);
    try std.testing.expectEqual(64, target.strings.value.sha256.?.len);
    try std.testing.expectError(error.ContentLimit, r.content("draft", "value", 4096));
    try std.testing.expectEqualStrings(text, try r.content("draft", "value", 65536));
    r.clear(1);
    try std.testing.expectError(error.MissingTarget, r.content("draft", "value", 65536));
}

test "identity is never silently shortened and oversized values remain digestible" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const box = Rect{ .x = 0, .y = 0, .width = 1, .height = 1 };
    try std.testing.expectError(error.IdentityTooLong, r.add(.{ .id = &@as([4097:0]u8, @splat('x')), .role = "button", .bounds = box }));
    try std.testing.expectError(error.InvalidUtf8, r.add(.{ .id = "bad", .role = "label", .label = "\xff", .bounds = box }));
    try r.add(.{ .id = "large", .role = "textbox", .value = &@as([65537:0]u8, @splat('x')), .bounds = box });
    try std.testing.expect(r.targets.items[0].strings.value.sha256 != null);
    try std.testing.expectError(error.ContentUnavailable, r.content("large", "value", 65537));
}

test "frame replacement drops stale geometry and owns text" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var label = "label".*;
    try r.add(.{ .id = "one", .role = "button", .label = &label, .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 } });
    label[0] = 'X';
    try std.testing.expectEqualStrings("label", r.targets.items[0].label);
    r.clear(2);
    try std.testing.expectError(error.MissingTarget, r.resolve("one"));
}

test "scroll reaches a filled container but not an unrelated overlay" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const box = Rect{ .x = 0, .y = 0, .width = 100, .height = 40 };
    try r.add(.{ .id = "list", .role = "scroll", .bounds = box, .interactive = false });
    try r.add(.{ .id = "row", .role = "row", .bounds = box, .parent = "list" });
    _ = try r.resolveScroll("list");
    try r.add(.{ .id = "dialog", .role = "dialog", .bounds = box });
    try std.testing.expectError(error.ObscuredTarget, r.resolveScroll("list"));
}

test "actions honor clipping, overlays, ambiguity and disabled targets" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const box = Rect{ .x = 0, .y = 0, .width = 100, .height = 40 };
    try r.add(.{ .id = "row", .role = "row", .bounds = box, .clip = .{ .x = 80, .y = 0, .width = 20, .height = 40 } });
    try std.testing.expect((try r.resolve("row")).x >= 80);
    try r.add(.{ .id = "overlay", .role = "dialog", .bounds = box });
    try std.testing.expectError(error.ObscuredTarget, r.resolve("row"));
    try r.add(.{ .id = "disabled", .role = "button", .bounds = box, .enabled = false });
    try std.testing.expectError(error.DisabledTarget, r.resolve("disabled"));
    try r.add(.{ .id = "row", .role = "row", .bounds = box });
    try std.testing.expectError(error.AmbiguousTarget, r.resolve("row"));
}
