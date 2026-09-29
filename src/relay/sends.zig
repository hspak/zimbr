//! Ordered attachment-send operations. A successful automation return allows
//! the next operation, but only observation can establish submission or delivery.
const std = @import("std");
const u = @import("../common.zig");
const t = @import("../protocol.zig").types;
pub const observation = @import("sends/observation.zig");
pub const Handoff = @import("sends/Handoff.zig");
pub const observation_window_ms = 10000;

pub const Outcome = union(enum) {
    invoked,
    unstarted: []const u8,
    uncertain: []const u8,
};

/// Allocate the ordered caption/file operations; the caller owns the slice.
/// Text-only requests retain their existing single-operation representation.
pub fn init(a: u.Allocator, input: t.SendInput) u.Allocator.Error![]t.SendPart {
    if (input.attachments.len == 0) return &.{};
    const caption: usize = @intFromBool(input.text.len != 0);
    const parts = try a.alloc(t.SendPart, caption + input.attachments.len);
    if (caption != 0) parts[0] = .{ .kind = .text };
    for (input.attachments, parts[caption..]) |file, *part| {
        part.* = .{ .kind = .attachment, .attachment_id = file.id };
    }
    return parts;
}

/// Return the next unstarted operation only when every predecessor can advance.
pub fn next(v: t.SendRequest) ?usize {
    for (v.parts, 0..) |part, i| switch (part.state) {
        .queued => return i,
        .invoked, .submitted, .delivered => {},
        .dispatching, .failed, .unknown, .skipped => return null,
    };
    return null;
}

/// Assert position is the next operation. Persist this change and the source
/// boundary in one transaction before invoking any external operation.
pub fn start(v: *t.SendRequest, position: usize) void {
    std.debug.assert(next(v.*) == position);
    v.parts[position].state = .dispatching;
    summarize(v);
}

/// Assert this part is dispatching. Failure holds all remaining operations;
/// retrying the request must never re-invoke an attempted or uncertain part.
pub fn finish(v: *t.SendRequest, position: usize, outcome: Outcome) void {
    const part = &v.parts[position];
    std.debug.assert(part.state == .dispatching);
    switch (outcome) {
        .invoked => {
            part.state = .invoked;
            part.error_info = null;
        },
        .unstarted, .uncertain => |code| {
            part.state = if (outcome == .unstarted) .failed else .unknown;
            part.error_info = .{
                .code = code,
                .message = "Messages automation could not complete this part.",
                .outcome = if (outcome == .unstarted) .unstarted else .uncertain,
            };
            skipQueued(v, "preceding_part_stopped");
        },
    }
    summarize(v);
}

/// Hold a multipart request after a crash or epoch change. Already invoked
/// operations retain their outcomes; no pending operation may start on recovery.
pub fn interrupt(v: *t.SendRequest, reset: bool) void {
    const code = if (reset) "source_reset" else "interrupted_dispatch";
    for (v.parts) |*part| {
        if (part.state == .dispatching) {
            part.state = .unknown;
            part.error_info = .{
                .code = code,
                .message = "Dispatch was interrupted; this part's outcome is uncertain.",
                .outcome = .uncertain,
            };
        }
        if (reset) {
            part.message_id = null;
            part.candidate_message_id = null;
        }
    }
    skipQueued(v, code);
    summarize(v);
}

fn skipQueued(v: *t.SendRequest, code: []const u8) void {
    for (v.parts) |*part| {
        if (part.state != .queued) continue;
        part.state = .skipped;
        part.error_info = .{ .code = code, .message = "This part was not attempted." };
    }
}

/// Record a uniquely matched outgoing message. Assume a first attachment match
/// has verified independent original bytes in Messages' attachment storage.
/// Assert automation has ended for this part. A reported failure holds any
/// remaining unstarted operations.
pub fn observe(v: *t.SendRequest, position: usize, message_id: []const u8, status: enum { submitted, delivered, failed }) void {
    const part = &v.parts[position];
    std.debug.assert(part.state == .invoked or part.state == .unknown or part.state == .submitted);
    part.message_id = message_id;
    part.candidate_message_id = null;
    part.state = switch (status) {
        .submitted => .submitted,
        .delivered => .delivered,
        .failed => .failed,
    };
    part.error_info = if (status == .failed) .{
        .code = "observed_failure",
        .message = "Messages reported failure for this part.",
        .outcome = .uncertain,
    } else null;
    if (status == .failed) skipQueued(v, "preceding_part_stopped");
    summarize(v);
}

/// Recompute the request outcome from its ordered parts, without claiming
/// delivery from automation success or hiding a partially completed request.
pub fn summarize(v: *t.SendRequest) void {
    std.debug.assert(v.parts.len != 0);
    var queued = false;
    var dispatching = false;
    var stopped = false;
    var attempted = false;
    var unresolved_or_successful = false;
    var observed: usize = 0;
    var delivered: usize = 0;
    var uncertain: ?t.SafeError = null;
    for (v.parts) |part| switch (part.state) {
        .queued => queued = true,
        .dispatching => dispatching = true,
        .invoked => {
            attempted = true;
            unresolved_or_successful = true;
        },
        .submitted, .delivered => {
            observed += 1;
            attempted = true;
            unresolved_or_successful = true;
            if (part.state == .delivered) delivered += 1;
        },
        .failed, .skipped => {
            stopped = true;
            if (part.error_info) |err| {
                if (err.outcome == .uncertain) attempted = true;
            }
        },
        .unknown => {
            attempted = true;
            unresolved_or_successful = true;
            uncertain = part.error_info;
        },
    };
    v.message_id = null;
    v.candidate_message_id = null;
    v.error_info = null;
    if (dispatching) {
        v.state = .dispatching;
    } else if (stopped) {
        v.state = if (unresolved_or_successful) .unknown else .failed;
        v.error_info = .{
            .code = if (unresolved_or_successful) "partial_send" else if (attempted) "observed_failure" else "dispatch_unstarted",
            .message = if (unresolved_or_successful)
                "Some parts were attempted; review their individual outcomes."
            else if (attempted)
                "Messages reported failure for every attempted part."
            else
                "No part of this request was sent.",
            .outcome = if (attempted) .uncertain else .unstarted,
        };
    } else if (queued) {
        v.state = .queued;
    } else if (delivered == v.parts.len) {
        v.state = .delivered;
    } else if (observed == v.parts.len) {
        v.state = .submitted;
    } else {
        v.state = .unknown;
        v.error_info = uncertain orelse .{
            .code = "awaiting_observation",
            .message = "Awaiting unambiguous outgoing Messages records for every part.",
            .outcome = .uncertain,
        };
    }
}

test "attachment-only operations stop on failure and never confuse invocation with delivery" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input: t.SendInput = .{
        .request_id = "request",
        .server_epoch = "epoch",
        .target = .{},
        .text = "",
        .attachments = &.{
            .{
                .id = "one",
                .name = "one",
                .mime_type = "application/octet-stream",
                .bytes = "0",
                .sha256 = "0" ** 64,
            },
            .{
                .id = "two",
                .name = "two",
                .mime_type = "application/octet-stream",
                .bytes = "0",
                .sha256 = "0" ** 64,
            },
        },
    };
    var v: t.SendRequest = .{
        .request_id = input.request_id,
        .server_epoch = input.server_epoch,
        .target = input.target,
        .text = input.text,
        .attachments = input.attachments,
        .parts = try init(a, input),
    };
    try testing.expectEqual(@as(usize, 2), v.parts.len);
    try testing.expectEqual(.attachment, v.parts[0].kind);
    start(&v, 0);
    finish(&v, 0, .{ .unstarted = "unsupported_target" });
    try testing.expectEqual(.failed, v.state);
    try testing.expectEqual(.skipped, v.parts[1].state);
    try testing.expectEqual(.unstarted, v.error_info.?.outcome);
    try testing.expectEqual(@as(?usize, null), next(v));

    v.parts = try init(a, input);
    start(&v, 0);
    finish(&v, 0, .invoked);
    try testing.expectEqual(.queued, v.state);
    start(&v, 1);
    finish(&v, 1, .{ .uncertain = "timeout" });
    try testing.expectEqual(.unknown, v.state);
    try testing.expectEqual(.invoked, v.parts[0].state);
    try testing.expectEqual(.unknown, v.parts[1].state);
    try testing.expectEqual(@as(?usize, null), next(v));

    v.parts = try init(a, input);
    start(&v, 0);
    finish(&v, 0, .invoked);
    start(&v, 1);
    finish(&v, 1, .invoked);
    try testing.expectEqual(.unknown, v.state);
    v.parts[0].state = .delivered;
    summarize(&v);
    try testing.expectEqual(.unknown, v.state);
    v.parts[1].state = .submitted;
    summarize(&v);
    try testing.expectEqual(.submitted, v.state);
    v.parts[1].state = .delivered;
    summarize(&v);
    try testing.expectEqual(.delivered, v.state);

    v.parts = try init(a, input);
    start(&v, 0);
    finish(&v, 0, .invoked);
    start(&v, 1);
    finish(&v, 1, .{ .unstarted = "permission_required" });
    try testing.expectEqual(.unknown, v.state);
    try testing.expectEqualStrings("partial_send", v.error_info.?.code);
    try testing.expectEqual(.invoked, v.parts[0].state);
    try testing.expectEqual(.failed, v.parts[1].state);
}

test "an observed earlier failure preserves an active part and skips unstarted successors" {
    var parts = [_]t.SendPart{
        .{ .kind = .text, .state = .invoked },
        .{
            .kind = .attachment,
            .attachment_id = "active",
            .state = .dispatching,
        },
        .{ .kind = .attachment, .attachment_id = "unstarted" },
    };
    var request: t.SendRequest = .{
        .request_id = "request",
        .server_epoch = "epoch",
        .target = .{},
        .text = "caption",
        .parts = &parts,
    };
    observe(&request, 0, "message", .failed);
    try std.testing.expectEqual(.dispatching, request.state);
    try std.testing.expectEqual(.failed, parts[0].state);
    try std.testing.expectEqualStrings("message", parts[0].message_id.?);
    try std.testing.expectEqual(.uncertain, parts[0].error_info.?.outcome);
    try std.testing.expectEqual(.dispatching, parts[1].state);
    try std.testing.expectEqual(.skipped, parts[2].state);
    finish(&request, 1, .invoked);
    try std.testing.expectEqual(.unknown, request.state);
    try std.testing.expectEqualStrings("partial_send", request.error_info.?.code);
    try std.testing.expectEqual(@as(?usize, null), next(request));
}
