//! Deadline-bounded TLS I/O beneath Zig's existing HTTP parser.
const std = @import("std");
const u = @import("../common.zig");
const tls = @import("Tls.zig").c;
pub const Reader = struct {
    interface: std.Io.Reader,
    connection: *tls.ZrTls,
    deadline: i64,
    pub fn init(connection: *tls.ZrTls, buffer: []u8) Reader {
        return .{ .connection = connection, .deadline = u.c.zr_monotonic_ms() + 10000, .interface = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = stream, .readVec = readVec } } };
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
        const n = tls.zr_tls_read(self.connection, vectors[0].ptr, vectors[0].len, self.deadline);
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
    connection: *tls.ZrTls,
    deadline: i64 = std.math.maxInt(i64),
    pub fn init(connection: *tls.ZrTls, buffer: []u8) Writer {
        return .{ .connection = connection, .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
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
        if (tls.zr_tls_write_deadline(self.connection, bytes.ptr, bytes.len, @min(self.deadline, u.c.zr_monotonic_ms() + 10000)) != 0) return error.WriteFailed;
    }
};
