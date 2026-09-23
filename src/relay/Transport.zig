//! Bounded POSIX transport beneath Zig's standard HTTP parser. In Zig 0.16 the
//! stock threaded socket reader treats EAGAIN from SO_RCVTIMEO as an invariant
//! failure, so timeout handling stays here until that API supports deadlines.
const std = @import("std");
const u = @import("../common.zig");
pub const Reader = struct {
    interface: std.Io.Reader,
    fd: c_int,
    deadline: i64,
    pub fn init(fd: c_int, buffer: []u8) Reader {
        return .{ .fd = fd, .deadline = u.c.zr_monotonic_ms() + 10000, .interface = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = stream, .readVec = readVec } } };
    }
    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try w.writableSliceGreedy(1));
        var vec = [_][]u8{dest};
        const n = try readVec(r, &vec);
        w.advance(n);
        return n;
    }
    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
        var vectors: [8][]u8 = undefined;
        const count, const data_size = try r.writableVector(&vectors, data);
        _ = count;
        const n = u.c.zr_recv(self.fd, vectors[0].ptr, vectors[0].len, self.deadline);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        const size: usize = @intCast(n);
        if (size > data_size) {
            r.end += size - data_size;
            return data_size;
        }
        return size;
    }
};
pub const Writer = struct {
    interface: std.Io.Writer,
    fd: c_int,
    pub fn init(fd: c_int, buffer: []u8) Writer {
        return .{ .fd = fd, .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        try self.send(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.send(bytes);
            n += bytes.len;
        }
        for (0..splat) |_| {
            try self.send(data[data.len - 1]);
            n += data[data.len - 1].len;
        }
        return n;
    }
    fn send(self: *Writer, bytes: []const u8) !void {
        if (u.c.zr_send(self.fd, bytes.ptr, bytes.len) != 0) return error.WriteFailed;
    }
};
