//! UI-thread delivery with a bounded wait for avatars from the shared media worker.
const std = @import("std");
const c = @import("../c.zig").api;
const Media = @import("../Media.zig");
const Notification = @import("../Notification.zig");
const Queue = @This();

backend: ?*c.ZcNotifications = null,
// Match the worker/backend notification bound while avatars are pending.
pending: [64]?Pending = @splat(null),

const Pending = struct {
    notice: *Notification,
    // Retain the packed identity while awaiting the avatar download.
    key: Media.Key,
    generation: u64,
    deadline: i64,
};

pub fn deinit(s: *Queue) void {
    for (s.pending) |pending| if (pending) |p| p.notice.destroy();
    c.zc_notifications_free(s.backend);
    s.* = undefined;
}

/// Takes ownership of the notice, including when images cannot be delivered.
pub fn submit(s: *Queue, notice: *Notification, media: ?*Media, now: i64) void {
    s.dismiss(notice.chat);
    const m = media orelse return s.show(notice, null);
    const asset = notice.avatar orelse return s.show(notice, null);
    if (!m.avatars or m.epoch.len == 0 or c.zc_notifications_images(s.backend) == 0)
        return s.show(notice, null);
    switch (asset.availability) {
        .ready, .pending => {},
        .not_local, .unavailable, .unsupported, .oversized, .retired => return s.show(notice, null),
    }
    m.request(asset) catch return s.show(notice, null);
    var slot: usize = 0;
    for (s.pending, 0..) |pending, i| {
        const p = pending orelse {
            slot = i;
            break;
        };
        if (p.deadline < s.pending[slot].?.deadline) slot = i;
    }
    if (s.pending[slot]) |p| s.show(p.notice, null);
    s.pending[slot] = .{
        .notice = notice,
        .key = m.key(asset),
        .generation = m.generation,
        // Wait at most 750 ms for an avatar so image loading cannot delay an alert indefinitely.
        .deadline = now + 750,
    };
}

/// Keeps downloads wanted while pending. Failure or timeout sends the text alert.
pub fn poll(s: *Queue, media: ?*Media, now: i64) void {
    for (&s.pending) |*pending| {
        const p = pending.* orelse continue;
        const m = media orelse {
            s.show(p.notice, null);
            pending.* = null;
            continue;
        };
        if (now >= p.deadline or p.generation != m.generation or !m.avatars or
            c.zc_notifications_images(s.backend) == 0)
        {
            s.show(p.notice, null);
            pending.* = null;
            continue;
        }
        m.request(p.notice.avatar.?) catch {
            s.show(p.notice, null);
            pending.* = null;
        };
    }
}

/// Borrows the result; the backend copies pixels before the media worker releases them.
pub fn accept(s: *Queue, media: *Media, result: *const Media.Result) void {
    if (result.generation != media.generation or !media.avatars) return;
    for (&s.pending) |*pending| {
        const p = pending.* orelse continue;
        if (p.generation != result.generation or !p.key.eql(result.key)) continue;
        s.show(p.notice, if (result.state == .ready) &result.pixels else null);
        pending.* = null;
    }
}

pub fn dismiss(s: *Queue, chat: [:0]const u8) void {
    for (&s.pending) |*pending| if (pending.*) |p| {
        if (!std.mem.eql(u8, p.notice.chat, chat)) continue;
        p.notice.destroy();
        pending.* = null;
    };
    c.zc_notifications_dismiss(s.backend, chat);
}

fn show(s: *Queue, notice: *Notification, pixels: ?*const c.ZcPixels) void {
    defer notice.destroy();
    c.zc_notifications_show(s.backend, notice.chat, notice.summary, notice.body, pixels);
}
