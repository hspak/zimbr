//! Contacts data stays on the relay; only matches for observed handles are
//! published. Native calls and index construction never hold the Core mutex.
const std = @import("std");
const u = @import("../../common.zig");
const t = @import("../../protocol/types.zig");
const Journal = @import("../Journal.zig");
const Assets = @import("../Assets.zig");
const native = !@import("options").fake and @import("builtin").os.tag == .macos;
pub const normalization_version = 1;
extern fn zr_contacts_status() c_int;
extern fn zr_contacts_raw_status() c_int;
extern fn zr_contacts_reader() c_int;
extern fn zr_contacts_monitor_status() void;
extern fn zr_contacts_refresh_status() void;
extern fn zr_contacts_generation() u64;
extern fn zr_contacts_pump_main() void;
extern fn zr_contacts_request() c_int;
extern fn zr_contacts_snapshot(region: [*:0]const u8) ?[*:0]u8;
extern fn zr_contacts_phone_key(value: [*:0]const u8, region: [*:0]const u8, out: [*]u8, capacity: usize) c_int;
extern fn zr_contacts_email_key(value: [*:0]const u8, fold_local: c_int, out: [*]u8, capacity: usize) c_int;
extern fn zr_contacts_region_valid(region: [*:0]const u8) c_int;
extern fn zr_contacts_suggest_region(out: [*]u8, capacity: usize) c_int;
extern fn zr_contacts_thumbnail(identifier: [*:0]const u8, generation: u64, output: c_int) c_int;

pub const Permission = enum { not_determined, restricted, denied, authorized, unsupported, unavailable };
pub const Status = struct {
    permission: Permission = .unavailable,
    ready: bool = false,
    reason: []const u8 = "starting",
    last_refresh_ms: ?i64 = null,
    stale: bool = false,
};
pub const Contact = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    emails: []const []const u8 = &.{},
    // Native bridge supplies keys from the pinned parser. Synthetic fixtures
    // supply explicit phone:/exact: keys, never a fake national-number parser.
    phones: []const []const u8 = &.{},
    has_image: bool = false,
    // Synthetic fake-relay input only; never supplied by the native snapshot.
    thumbnail: ?[]const u8 = null,
};
const Candidate = struct { index: usize, ambiguous: bool = false };
pub const Index = struct {
    contacts: []const Contact,
    exact_emails: std.StringHashMapUnmanaged(Candidate) = .empty,
    folded_emails: std.StringHashMapUnmanaged(Candidate) = .empty,
    phones: std.StringHashMapUnmanaged(Candidate) = .empty,

    pub fn init(a: u.Allocator, contacts: []const Contact) !Index {
        var index = Index{ .contacts = contacts };
        for (contacts, 0..) |contact, i| {
            if (contact.id.len == 0 or contact.id.len > 1024) return error.InvalidContacts;
            if (contact.name) |name| if (name.len > 1024 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidContacts;
            for (contact.emails) |email| if (try emailKey(a, email, false)) |key| {
                try index.insert(a, &index.exact_emails, key, i);
                try index.insert(a, &index.folded_emails, (try emailKey(a, email, true)).?, i);
            };
            for (contact.phones) |phone| {
                if (phone.len > 300 or (!std.mem.startsWith(u8, phone, "phone:") and !std.mem.startsWith(u8, phone, "exact:"))) return error.InvalidContacts;
                try index.insert(a, &index.phones, phone, i);
            }
        }
        return index;
    }
    fn insert(self: Index, a: u.Allocator, map: *std.StringHashMapUnmanaged(Candidate), key: []const u8, i: usize) !void {
        const entry = try map.getOrPut(a, key);
        if (!entry.found_existing) entry.value_ptr.* = .{ .index = i } else if (!u.eq(self.contacts[entry.value_ptr.index].id, self.contacts[i].id)) entry.value_ptr.ambiguous = true;
    }
    pub fn match(self: Index, a: u.Allocator, address: []const u8, region: []const u8) !?Candidate {
        if (try emailKey(a, address, false)) |key| {
            return self.exact_emails.get(key) orelse self.folded_emails.get((try emailKey(a, address, true)).?);
        }
        return self.phones.get(try phoneKey(a, address, region));
    }
};

fn emailKey(a: u.Allocator, address: []const u8, fold_local: bool) !?[]const u8 {
    if (address.len > 254 or std.mem.indexOfScalar(u8, address, 0) != null) return null;
    if (native) {
        var out: [1024]u8 = undefined;
        const n = zr_contacts_email_key(try a.dupeZ(u8, address), @intFromBool(fold_local), &out, out.len);
        return if (n < 0) null else try a.dupe(u8, out[0..@intCast(n)]);
    }
    const trimmed = std.mem.trim(u8, address, " \t\r\n");
    const at = std.mem.indexOfScalar(u8, trimmed, '@') orelse return null;
    if (trimmed.len > 254 or at == 0 or at + 1 == trimmed.len or std.mem.indexOfScalar(u8, trimmed[at + 1 ..], '@') != null) return null;
    const result = try a.dupe(u8, trimmed);
    for (result[at + 1 ..]) |*ch| ch.* = std.ascii.toLower(ch.*);
    if (fold_local) for (result[0..at]) |*ch| {
        ch.* = std.ascii.toLower(ch.*);
    };
    return result;
}
pub fn phoneKey(a: u.Allocator, address: []const u8, region: []const u8) ![]const u8 {
    if (native) {
        if (std.mem.indexOfScalar(u8, address, 0) != null) return error.InvalidContacts;
        var out: [512]u8 = undefined;
        const n = zr_contacts_phone_key(try a.dupeZ(u8, address), try a.dupeZ(u8, region), &out, out.len);
        if (n < 0) return error.InvalidContacts;
        return a.dupe(u8, out[0..@intCast(n)]);
    }
    const trimmed = std.mem.trim(u8, address, " \t\r\n");
    return std.fmt.allocPrint(a, "{s}:{s}", .{ if (std.mem.startsWith(u8, trimmed, "+") and t.validAddress(trimmed)) "phone" else "exact", trimmed });
}
pub fn validateRegion(a: u.Allocator, region: []const u8) !void {
    if (region.len == 0) return;
    if (region.len != 2 or !std.ascii.isUpper(region[0]) or !std.ascii.isUpper(region[1])) return error.InvalidContactsPhoneRegion;
    if (native and zr_contacts_region_valid(try a.dupeZ(u8, region)) == 0) return error.InvalidContactsPhoneRegion;
}
pub fn suggestedRegion(a: u.Allocator) !?[]const u8 {
    if (!native) return null;
    var out: [16]u8 = undefined;
    const n = zr_contacts_suggest_region(&out, out.len);
    return if (n < 0) null else try a.dupe(u8, out[0..@intCast(n)]);
}
fn permissionCode(code: c_int) Permission {
    return switch (code) {
        -1 => .unavailable,
        0 => .not_determined,
        1 => .restricted,
        2 => .denied,
        3 => .authorized,
        else => .unsupported,
    };
}
pub fn permission() Permission {
    return if (native) permissionCode(zr_contacts_status()) else .unavailable;
}
pub fn pumpMain() void {
    if (native) zr_contacts_pump_main();
}
pub fn permissionProbeExit() noreturn {
    std.process.exit(if (native) @intCast(100 + zr_contacts_raw_status()) else 104);
}
pub fn readerProbeExit() noreturn {
    std.process.exit(if (native) @intCast(zr_contacts_reader()) else 105);
}
pub fn startAuthorizationChecks() void {
    if (native) zr_contacts_monitor_status();
}
pub fn authorizationLoop(core: *@import("../Core.zig")) void {
    while (!core.stop.load(.acquire)) {
        core.sleep(1000);
        if (native) zr_contacts_refresh_status();
    }
}
pub fn canPresent(status: Status) bool {
    return status.permission == .authorized and (!native or permission() == .authorized);
}
pub fn currentStatus(status: Status) Status {
    return if (native) withPermission(status, permission()) else status;
}
fn withPermission(status: Status, observed: Permission) Status {
    var result = status;
    // A read/conversion can outlast the permission monitor. Report its fresh
    // decision immediately; a grant still waits for directory reconciliation.
    if (observed != status.permission) {
        result.permission = observed;
        result.ready = false;
        result.stale = false;
        result.reason = if (observed == .authorized) "reconciling" else @tagName(observed);
    }
    return result;
}
pub fn requestPermission() !Permission {
    if (!native) return error.UnsupportedPlatform;
    const code = zr_contacts_request();
    if (code == -2) return error.InstalledAppRequired;
    if (code == -1) return error.ContactsPromptTimedOut;
    return permissionCode(code);
}
const Snapshot = struct { permission: Permission, generation: u64, contacts: []const Contact = &.{}, failed: bool = false };
pub const PhotoSource = struct { contact_id: []const u8, generation: u64, token: []const u8 };
pub fn photoCurrent(a: u.Allocator, core: *@import("../Core.zig"), photo: PhotoSource) bool {
    if (native) return permission() == .authorized and zr_contacts_generation() == photo.generation;
    const observed = snapshot(a, core, null, null, true) catch return false;
    return observed.permission == .authorized and !observed.failed and observed.generation == photo.generation;
}
pub fn thumbnail(a: u.Allocator, core: *@import("../Core.zig"), photo: PhotoSource, output: c_int) !c_int {
    if (native) return zr_contacts_thumbnail(try a.dupeZ(u8, photo.contact_id), photo.generation, output);
    const observed = try snapshot(a, core, null, null, true);
    if (observed.permission != .authorized or observed.failed or observed.generation != photo.generation) return -7;
    for (observed.contacts) |contact| if (u.eq(contact.id, photo.contact_id)) {
        const bytes = contact.thumbnail orelse return -2;
        if (bytes.len > 8 * 1024 * 1024) return -4;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = u.c.write(output, bytes[offset..].ptr, bytes.len - offset);
            if (n <= 0) return -1;
            offset += @intCast(n);
        }
        return 0;
    };
    return -2;
}
fn snapshot(a: u.Allocator, core: *@import("../Core.zig"), previous: ?u64, previous_permission: ?Permission, refresh: bool) !Snapshot {
    if (native) {
        const p = permission();
        const generation = zr_contacts_generation();
        // Permission changes need a fresh index even without a store-change
        // notification; a grant must not publish an empty cached snapshot.
        if (p != .authorized or (!refresh and previous == generation and previous_permission == p)) return .{ .permission = p, .generation = generation };
        const raw = zr_contacts_snapshot(try a.dupeZ(u8, core.contacts_phone_region)) orelse return .{ .permission = permission(), .generation = generation, .failed = true };
        defer u.c.free(raw);
        if (zr_contacts_generation() != generation) return .{ .permission = p, .generation = generation, .failed = true };
        const contacts = (try std.json.parseFromSlice([]const Contact, a, std.mem.span(raw), .{ .allocate = .alloc_always })).value;
        return .{ .permission = p, .generation = generation, .contacts = contacts };
    }
    // Fake relay only: explicit synthetic fixture adjacent to its required DB.
    const path = try std.fmt.allocPrint(a, "{s}.contacts.json", .{core.source_path});
    const bytes = std.Io.Dir.cwd().readFileAlloc(core.io, path, a, .limited(32 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return .{ .permission = .unavailable, .generation = 0 };
        return err;
    };
    var observed = (try std.json.parseFromSlice(Snapshot, a, bytes, .{ .allocate = .alloc_always })).value;
    if (!refresh and previous == observed.generation and previous_permission == observed.permission) observed.contacts = &.{};
    return observed;
}
const Work = struct { value: t.Identity, generation: i64 };
fn work(j: Journal, a: u.Allocator) ![]Work {
    var s = try j.db.prepare("SELECT i.record,w.generation FROM identity_work w JOIN identities i ON i.id=w.identity_id ORDER BY w.attempt_ms,i.id LIMIT 100");
    defer s.close();
    var jobs: std.ArrayList(Work) = .empty;
    while (try s.step()) try jobs.append(a, .{ .value = (try std.json.parseFromSlice(t.Identity, a, s.bytes(0), .{ .allocate = .alloc_always })).value, .generation = s.int(1) });
    return jobs.toOwnedSlice(a);
}

pub fn loop(core: *@import("../Core.zig")) void {
    var cache = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cache.deinit();
    var index: ?Index = null;
    var generation: ?u64 = null;
    var old_permission: ?Permission = null;
    var next_refresh: i64 = 0;
    var query_failed = false;
    var source_version: []const u8 = "";
    while (!core.stop.load(.acquire)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const refresh = u.now() >= next_refresh;
        const observed = snapshot(a, core, generation, old_permission, refresh) catch Snapshot{ .permission = old_permission orelse .unavailable, .generation = generation orelse 0, .failed = true };
        const changed = generation != observed.generation or old_permission != observed.permission;
        const needs_refresh = changed or refresh or (observed.failed and !query_failed);
        var failed = observed.permission == .authorized and (observed.failed or (!needs_refresh and query_failed));
        if (observed.permission == .authorized and (changed or refresh) and !failed) {
            // Build a replacement index before dropping the usable old snapshot.
            var replacement = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            const copied = u.json(replacement.allocator(), observed.contacts) catch null;
            const parsed = if (copied) |bytes| std.json.parseFromSlice([]const Contact, replacement.allocator(), bytes, .{ .allocate = .alloc_always }) catch null else null;
            const next_index = if (parsed) |v| Index.init(replacement.allocator(), v.value) catch null else null;
            if (next_index) |v| {
                const version = u.id(replacement.allocator()) catch null;
                if (version) |id| {
                    cache.deinit();
                    cache = replacement;
                    index = v;
                    source_version = id;
                } else {
                    replacement.deinit();
                    failed = true;
                }
            } else {
                replacement.deinit();
                failed = true;
            }
        }
        // Snapshot results and queue invalidation share one journal transaction.
        core.lock();
        const j = core.journal;
        const jobs = blk: {
            j.begin() catch break :blk null;
            const result = prepare(j, a, needs_refresh) catch {
                j.rollback();
                break :blk null;
            };
            j.commit() catch {
                j.rollback();
                break :blk null;
            };
            break :blk result;
        };
        const epoch = j.epoch(a) catch null;
        core.contacts_status.permission = observed.permission;
        core.contacts_status.stale = failed;
        core.contacts_status.ready = false;
        core.contacts_status.reason = if (failed) "contacts_query_failed" else if (observed.permission != .authorized) @tagName(observed.permission) else "reconciling";
        if (jobs != null and epoch != null and needs_refresh and !failed and observed.permission == .authorized) core.contacts_status.last_refresh_ms = u.now();
        if (jobs == null or epoch == null) core.contacts_status.reason = "contacts_persistence_failure";
        core.unlock();
        if (jobs == null or epoch == null) {
            // Do not acknowledge a source generation whose queue transaction
            // failed; retry it so a rename cannot disappear until the next scan.
            core.sleep(1000);
            continue;
        }
        if (jobs != null and epoch != null) {
            for (jobs.?) |job| {
                var value = job.value;
                var contact_id: ?[]const u8 = null;
                var photo: ?PhotoSource = null;
                if (failed) {
                    value.freshness = .stale;
                } else if (observed.permission != .authorized) {
                    value.match_state = .unavailable;
                    value.freshness = .fresh;
                } else if (index) |idx| {
                    value.freshness = .fresh;
                    const candidate = idx.match(a, value.address, core.contacts_phone_region) catch null;
                    value.match_state = if (candidate == null) .unmatched else if (candidate.?.ambiguous) .ambiguous else .matched;
                    if (value.match_state == .matched) {
                        const contact = idx.contacts[candidate.?.index];
                        value.display_name = contact.name;
                        value.avatar = null;
                        contact_id = contact.id;
                        if (contact.has_image and core.assets_service != null) photo = .{ .contact_id = contact.id, .generation = observed.generation, .token = source_version };
                    }
                } else continue;
                // A notification/permission change during matching invalidates
                // the completion. Epoch and per-identity generation gate commits.
                if (native and (permission() != observed.permission or zr_contacts_generation() != observed.generation)) break;
                core.lock();
                complete(j, a, epoch.?, job.generation, value, contact_id, source_version, failed, photo) catch {};
                core.unlock();
            }
        }
        generation = observed.generation;
        old_permission = observed.permission;
        query_failed = failed;
        if (needs_refresh) next_refresh = u.now() + if (failed) @as(i64, 30000) else 15 * 60 * 1000;
        core.lock();
        const remaining = j.db.scalar("SELECT count(*) FROM identity_work") catch 1;
        core.contacts_status.ready = !failed and observed.permission == .authorized and remaining == 0;
        if (core.contacts_status.ready) core.contacts_status.reason = "";
        core.unlock();
        if (!failed and observed.permission == .authorized) Assets.contactWork(core, a) catch {};
        core.sleep(if (remaining > 0 and !failed) 10 else 1000);
    }
}

fn prepare(j: Journal, a: u.Allocator, refresh: bool) ![]Work {
    if (refresh) try j.db.exec("INSERT INTO identity_work(identity_id) SELECT id FROM identities WHERE true ON CONFLICT(identity_id) DO UPDATE SET generation=generation+1");
    return work(j, a);
}
pub fn complete(j: Journal, a: u.Allocator, epoch: []const u8, generation: i64, value: t.Identity, contact_id: ?[]const u8, source_version: []const u8, failed: bool, photo: ?PhotoSource) !void {
    try j.begin();
    errdefer j.rollback();
    var s = try j.db.prepare("SELECT generation FROM identity_work WHERE identity_id=?");
    defer s.close();
    try s.bind(&.{.{ .text = value.id }});
    if (!u.eq(epoch, try j.epoch(a)) or !try s.step() or s.int(0) != generation) {
        j.rollback();
        return;
    }
    var updated = value;
    if (!failed) updated.avatar = try Assets.avatar(j, a, value.id, photo);
    try j.updateIdentity(a, updated);
    if (!failed) {
        try j.execute("DELETE FROM contact_mappings WHERE identity_id=?", &.{.{ .text = value.id }});
        if (contact_id) |id| try j.execute("INSERT INTO contact_mappings VALUES(?,?,?,?)", &.{ .{ .text = value.id }, .{ .text = id }, .{ .text = source_version }, .{ .int = normalization_version } });
    }
    try j.execute("DELETE FROM identity_work WHERE identity_id=?", &.{.{ .text = value.id }});
    try j.commit();
}

test "fresh permission gates status while the contacts worker is busy" {
    const ready = Status{ .permission = .authorized, .ready = true, .reason = "", .last_refresh_ms = 123 };
    for ([_]Permission{ .denied, .restricted, .unavailable }) |observed| {
        const revoked = withPermission(ready, observed);
        try std.testing.expectEqual(observed, revoked.permission);
        try std.testing.expect(!revoked.ready);
        try std.testing.expectEqualStrings(@tagName(observed), revoked.reason);
        try std.testing.expectEqual(ready.last_refresh_ms, revoked.last_refresh_ms);
        const granted = withPermission(revoked, .authorized);
        try std.testing.expect(!granted.ready);
        try std.testing.expectEqualStrings("reconciling", granted.reason);
    }
    const failed = Status{ .permission = .authorized, .stale = true, .reason = "contacts_query_failed" };
    const unchanged = withPermission(failed, .authorized);
    try std.testing.expect(unchanged.stale and !unchanged.ready);
    try std.testing.expectEqualStrings("contacts_query_failed", unchanged.reason);
    try std.testing.expect(withPermission(ready, .authorized).ready);
}

test "contact matching prefers exact email local part, preserves aliases, and rejects ambiguous contacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const index = try Index.init(a, &.{
        .{ .id = "unified-a", .name = "Élodie 👩‍💻", .emails = &.{ "Alice@Example.invalid", "alias+tag@example.invalid" }, .phones = &.{"phone:+14155550123"} },
        .{ .id = "unified-b", .emails = &.{"alice@example.invalid"}, .phones = &.{"phone:+14155550123"} },
        .{ .id = "unified-a", .emails = &.{"Alice@Example.invalid"} },
    });
    try std.testing.expectEqual(@as(usize, 0), (try index.match(a, " Alice@EXAMPLE.invalid ", "")).?.index);
    try std.testing.expect(!(try index.match(a, "Alice@example.invalid", "")).?.ambiguous);
    try std.testing.expect((try index.match(a, "ALICE@example.invalid", "")).?.ambiguous);
    try std.testing.expect((try index.match(a, "+14155550123", "")).?.ambiguous);
    try std.testing.expect((try index.match(a, "alias@example.invalid", "")) == null);
    try std.testing.expect((try index.match(a, "unknown@example.invalid", "")) == null);
}
test "native phone matching uses explicit regions and keeps short codes and extensions exact" {
    if (!native) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("phone:+14155550123", try phoneKey(a, "(415) 555-0123", "US"));
    try std.testing.expectEqualStrings("phone:+442079460123", try phoneKey(a, "020 7946 0123", "GB"));
    try std.testing.expectEqualStrings("phone:+14155550123", try phoneKey(a, "+1 (415) 555-0123", ""));
    try std.testing.expectEqualStrings("exact:4155550123", try phoneKey(a, "4155550123", ""));
    try std.testing.expectEqualStrings("exact:911", try phoneKey(a, "911", "US"));
    try std.testing.expectEqualStrings("exact:+14155550123 ext 9", try phoneKey(a, "+14155550123 ext 9", "US"));
    try std.testing.expectError(error.InvalidContactsPhoneRegion, validateRegion(a, "ZZ"));
    try std.testing.expectEqualStrings("Älice@éxample.invalid", (try emailKey(a, " Älice@ÉXAMPLE.invalid ", false)).?);
    try std.testing.expectEqualStrings("älice@éxample.invalid", (try emailKey(a, "Älice@ÉXAMPLE.invalid", true)).?);
}

test "stale contact completions cannot publish across work generations or epoch reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try Journal.open(":memory:");
    defer j.close();
    try j.begin();
    const id = (try j.observeIdentity(a, "imessage", "peer@example.invalid")).?;
    try j.commit();
    const epoch = try j.epoch(a);
    const v: t.Identity = .{ .id = id, .service = "imessage", .address = "peer@example.invalid", .match_state = .matched, .display_name = "Private name" };
    try j.db.exec("UPDATE identity_work SET generation=2");
    const before = try j.sequence();
    try complete(j, a, epoch, 1, v, "private-contact-id", "version", false, null);
    try std.testing.expectEqual(before, try j.sequence());
    try complete(j, a, epoch, 2, v, "private-contact-id", "version", false, null);
    try std.testing.expect((try j.sequence()) > before);
    try std.testing.expectEqual(@as(i64, 1), try j.db.scalar("SELECT count(*) FROM contact_mappings"));
    for (try j.eventsWithIdentities(a, 0, true)) |frame| try std.testing.expect(std.mem.indexOf(u8, frame.frame, "private-contact-id") == null);
    try j.begin();
    try j.reset(a);
    try j.commit();
    const reset_sequence = try j.sequence();
    try complete(j, a, epoch, 2, v, "private-contact-id", "version", false, null);
    try std.testing.expectEqual(reset_sequence, try j.sequence());
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM identities"));
    try std.testing.expectEqual(@as(i64, 0), try j.db.scalar("SELECT count(*) FROM contact_mappings"));
}
