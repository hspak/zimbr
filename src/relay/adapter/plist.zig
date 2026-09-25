//! Bounded primitive property lists. No Objective-C unarchiving, class loading,
//! external entities, or network/file resolution. Callers own an arena.
const std = @import("std");
const u = @import("../../common.zig");
const max_bytes = @import("../../protocol.zig").types.max_decode;
pub const max_objects = 8192;
pub const max_depth = 32;
pub const Node = union(enum) {
    none,
    boolean: bool,
    integer: u64,
    string: []const u8,
    data: []const u8,
    uid: usize,
    array: []Node,
    dict: []Entry,
    pub fn get(self: Node, key: []const u8) ?Node {
        if (self != .dict) return null;
        for (self.dict) |entry| if (u.eq(entry.key, key)) return entry.value;
        return null;
    }
    pub fn text(self: Node) ?[]const u8 {
        return if (self == .string) self.string else null;
    }
};
pub const Entry = struct { key: []const u8, value: Node };
const Failure = error{
    Malformed,
    Unsupported,
    Oversized,
    OutOfMemory,
};
pub fn parse(a: u.Allocator, bytes: []const u8) Failure!Node {
    if (bytes.len > max_bytes) return error.Oversized;
    if (std.mem.startsWith(u8, bytes, "bplist00")) return Binary.parse(a, bytes);
    var xml = Xml{ .a = a, .bytes = bytes };
    return xml.parse();
}
fn unsigned(bytes: []const u8) Failure!u64 {
    if (bytes.len == 0 or bytes.len > 8) return error.Malformed;
    var n: u64 = 0;
    for (bytes) |byte| n = (n << 8) | byte;
    return n;
}
const Binary = struct {
    a: u.Allocator,
    bytes: []const u8,
    offsets: []usize,
    values: []Node,
    marks: []u8,
    ref_width: usize,
    table: usize,
    allocated: usize = 0,
    // Offsets may alias. Input size alone does not bound repeated decoding or
    // hashing of the same large string under many different object indices.
    work: usize = 0,
    fn charge(self: *Binary, bytes: usize) Failure!void {
        if (bytes > max_bytes * 8 - self.work) return error.Oversized;
        self.work += bytes;
    }
    fn parse(a: u.Allocator, bytes: []const u8) Failure!Node {
        if (bytes.len < 40) return error.Malformed;
        const trailer = bytes[bytes.len - 32 ..];
        const count = try unsigned(trailer[8..16]);
        const root = try unsigned(trailer[16..24]);
        const table = try unsigned(trailer[24..32]);
        const width: usize = trailer[6];
        const refs: usize = trailer[7];
        if (count == 0 or count > max_objects) return error.Oversized;
        if (root >= count or width == 0 or width > 8 or refs == 0 or refs > 8 or table < 8 or table > bytes.len - 32 or count * width > bytes.len - 32 - table) return error.Malformed;
        var self = Binary{
            .a = a,
            .bytes = bytes,
            .offsets = try a.alloc(usize, @intCast(count)),
            .values = try a.alloc(Node, @intCast(count)),
            .marks = try a.alloc(u8, @intCast(count)),
            .ref_width = refs,
            .table = @intCast(table),
        };
        @memset(self.marks, 0);
        for (self.offsets, 0..) |*offset, i| {
            const value = try unsigned(bytes[@as(usize, @intCast(table)) + i * width ..][0..width]);
            if (value < 8 or value >= table) return error.Malformed;
            offset.* = @intCast(value);
        }
        return self.object(@intCast(root), 0);
    }
    fn take(self: *Binary, position: *usize, length: usize) Failure![]const u8 {
        if (position.* > self.table or length > self.table - position.*) return error.Malformed;
        try self.charge(length);
        const bytes = self.bytes[position.*..][0..length];
        position.* += length;
        return bytes;
    }
    fn size(self: *Binary, position: *usize, small: u8) Failure!usize {
        if (small != 15) return small;
        const tag = (try self.take(position, 1))[0];
        if (tag >> 4 != 1 or tag & 15 > 3) return error.Malformed;
        const n = try unsigned(try self.take(position, @as(usize, 1) << @intCast(tag & 15)));
        if (n > max_bytes) return error.Oversized;
        return @intCast(n);
    }
    fn reference(self: *Binary, bytes: []const u8, depth: usize) Failure!Node {
        const index = try unsigned(bytes);
        if (index >= self.offsets.len) return error.Malformed;
        return self.object(@intCast(index), depth);
    }
    fn object(self: *Binary, index: usize, depth: usize) Failure!Node {
        if (depth >= max_depth) return error.Oversized;
        if (self.marks[index] == 1) return error.Malformed;
        if (self.marks[index] == 2) return self.values[index];
        self.marks[index] = 1;
        var position = self.offsets[index];
        const tag = (try self.take(&position, 1))[0];
        const small = tag & 15;
        const value: Node = switch (tag >> 4) {
            0 => switch (small) {
                0 => .none,
                8 => .{ .boolean = false },
                9 => .{ .boolean = true },
                else => return error.Unsupported,
            },
            1 => if (small <= 3) .{ .integer = try unsigned(try self.take(
                &position,
                @as(usize, 1) << @intCast(small),
            )) } else return error.Unsupported,
            2, 3 => object: { // irrelevant real/date values still have strict bounds
                if (small > 3) return error.Unsupported;
                _ = try self.take(&position, @as(usize, 1) << @intCast(small));
                break :object .none;
            },
            4, 5, 6 => object: {
                const length = try self.size(&position, small);
                const bytes = try self.take(
                    &position,
                    length * (if (tag >> 4 == 6) @as(usize, 2) else 1),
                );
                if (tag >> 4 == 4) break :object .{ .data = bytes };
                if (tag >> 4 == 5) {
                    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Malformed;
                    break :object .{ .string = bytes };
                }
                self.allocated += length * 3;
                if (self.allocated > max_bytes * 2) return error.Oversized;
                const units = try self.a.alloc(u16, length);
                for (units, 0..) |*unit, i| unit.* = std.mem.readInt(
                    u16,
                    bytes[i * 2 ..][0..2],
                    .big,
                );
                break :object .{ .string = std.unicode.utf16LeToUtf8Alloc(self.a, units) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.DanglingSurrogateHalf, error.ExpectedSecondSurrogateHalf, error.UnexpectedSecondSurrogateHalf => return error.Malformed,
                } };
            },
            8 => object: {
                const value = try unsigned(try self.take(&position, @as(usize, small) + 1));
                if (value > max_objects) return error.Malformed;
                break :object .{ .uid = @intCast(value) };
            },
            10, 13 => object: {
                const length = try self.size(&position, small);
                if (length > max_objects) return error.Oversized;
                self.allocated += length * @sizeOf(Entry);
                if (self.allocated > max_bytes * 2) return error.Oversized;
                const dict = tag >> 4 == 13;
                const refs = try self.take(
                    &position,
                    length * self.ref_width * (if (dict) @as(usize, 2) else 1),
                );
                if (dict) {
                    const entries = try self.a.alloc(Entry, length);
                    var keys: std.StringHashMapUnmanaged(void) = .empty;
                    for (entries, 0..) |*entry, i| {
                        const key = (try self.reference(
                            refs[i * self.ref_width ..][0..self.ref_width],
                            depth + 1,
                        )).text() orelse return error.Malformed;
                        try self.charge(key.len);
                        if ((try keys.getOrPut(self.a, key)).found_existing) return error.Malformed;
                        entry.* = .{ .key = key, .value = try self.reference(
                            refs[(i + length) * self.ref_width ..][0..self.ref_width],
                            depth + 1,
                        ) };
                    }
                    break :object .{ .dict = entries };
                }
                const array = try self.a.alloc(Node, length);
                for (array, 0..) |*item, i| item.* = try self.reference(
                    refs[i * self.ref_width ..][0..self.ref_width],
                    depth + 1,
                );
                break :object .{ .array = array };
            },
            else => return error.Unsupported,
        };
        self.marks[index] = 2;
        self.values[index] = value;
        return value;
    }
};

const Xml = struct {
    a: u.Allocator,
    bytes: []const u8,
    pos: usize = 0,
    objects: usize = 0,
    fn starts(self: Xml, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.bytes[self.pos..], prefix);
    }
    fn consume(self: *Xml, prefix: []const u8) bool {
        if (!self.starts(prefix)) return false;
        self.pos += prefix.len;
        return true;
    }
    fn whitespace(self: *Xml) Failure!void {
        while (self.pos < self.bytes.len) {
            if (std.ascii.isWhitespace(self.bytes[self.pos])) {
                self.pos += 1;
                continue;
            }
            if (self.consume("<!--")) {
                const end = std.mem.indexOf(u8, self.bytes[self.pos..], "-->") orelse return error.Malformed;
                self.pos += end + 3;
                continue;
            }
            break;
        }
    }
    fn parse(self: *Xml) Failure!Node {
        try self.whitespace();
        if (self.consume("<?xml ")) {
            const end = std.mem.indexOf(u8, self.bytes[self.pos..], "?>") orelse return error.Malformed;
            self.pos += end + 2;
            try self.whitespace();
        }
        if (self.consume("<!DOCTYPE plist ")) {
            const end = std.mem.indexOfScalar(u8, self.bytes[self.pos..], '>') orelse return error.Malformed;
            // External DTD declarations are inert; internal subsets/entities are rejected.
            if (std.mem.indexOfScalar(u8, self.bytes[self.pos..][0..end], '[') != null) return error.Unsupported;
            self.pos += end + 1;
            try self.whitespace();
        }
        if (!self.consume("<plist version=\"1.0\">")) return error.Unsupported;
        const root = try self.value(0);
        try self.whitespace();
        if (!self.consume("</plist>")) return error.Malformed;
        try self.whitespace();
        if (self.pos != self.bytes.len) return error.Malformed;
        return root;
    }
    fn content(self: *Xml, closing: []const u8) Failure![]const u8 {
        const end = std.mem.indexOf(u8, self.bytes[self.pos..], closing) orelse return error.Malformed;
        const raw = self.bytes[self.pos..][0..end];
        if (std.mem.indexOfScalar(u8, raw, '<') != null) return error.Malformed;
        self.pos += end + closing.len;
        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try result.append(self.a, raw[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return error.Malformed;
            const entity = raw[i + 1 .. semi];
            const character: u21 = if (u.eq(entity, "amp")) '&' else if (u.eq(entity, "lt")) '<' else if (u.eq(
                entity,
                "gt",
            )) '>' else if (u.eq(
                entity,
                "quot",
            )) '"' else if (u.eq(
                entity,
                "apos",
            )) '\'' else if (std.mem.startsWith(
                u8,
                entity,
                "#x",
            )) std.fmt.parseInt(
                u21,
                entity[2..],
                16,
            ) catch return error.Malformed else if (std.mem.startsWith(
                u8,
                entity,
                "#",
            )) std.fmt.parseInt(
                u21,
                entity[1..],
                10,
            ) catch return error.Malformed else return error.Unsupported;
            if (character == 0 or (character < 32 and character != 9 and character != 10 and character != 13)) return error.Malformed;
            var buffer: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(character, &buffer) catch return error.Malformed;
            try result.appendSlice(self.a, buffer[0..n]);
            i = semi + 1;
        }
        if (!std.unicode.utf8ValidateSlice(result.items)) return error.Malformed;
        return result.toOwnedSlice(self.a);
    }
    fn value(self: *Xml, depth: usize) Failure!Node {
        self.objects += 1;
        if (depth >= max_depth or self.objects > max_objects) return error.Oversized;
        try self.whitespace();
        if (self.consume("<true/>")) return .{ .boolean = true };
        if (self.consume("<false/>")) return .{ .boolean = false };
        if (self.consume("<string/>")) return .{ .string = "" };
        if (self.consume("<string>")) return .{ .string = try self.content("</string>") };
        if (self.consume("<integer>")) return .{ .integer = std.fmt.parseInt(
            u64,
            std.mem.trim(u8, try self.content("</integer>"), " \t\r\n"),
            0,
        ) catch return error.Malformed };
        if (self.consume("<real>")) {
            _ = try self.content("</real>");
            return .none;
        }
        if (self.consume("<date>")) {
            _ = try self.content("</date>");
            return .none;
        }
        if (self.consume("<data/>")) return .{ .data = "" };
        if (self.consume("<data>")) {
            const raw = try self.content("</data>");
            var compact: std.ArrayList(u8) = .empty;
            for (raw) |byte| if (!std.ascii.isWhitespace(byte)) {
                try compact.append(self.a, byte);
            };
            const decoder = std.base64.standard.Decoder;
            const bytes = try self.a.alloc(
                u8,
                decoder.calcSizeForSlice(compact.items) catch return error.Malformed,
            );
            decoder.decode(bytes, compact.items) catch return error.Malformed;
            return .{ .data = bytes };
        }
        if (self.consume("<array/>")) return .{ .array = &.{} };
        if (self.consume("<array>")) {
            var array: std.ArrayList(Node) = .empty;
            while (true) {
                try self.whitespace();
                if (self.consume("</array>")) break;
                try array.append(self.a, try self.value(depth + 1));
            }
            return .{ .array = try array.toOwnedSlice(self.a) };
        }
        if (self.consume("<dict/>")) return .{ .dict = &.{} };
        if (self.consume("<dict>")) {
            var dict: std.ArrayList(Entry) = .empty;
            var keys: std.StringHashMapUnmanaged(void) = .empty;
            while (true) {
                try self.whitespace();
                if (self.consume("</dict>")) break;
                if (!self.consume("<key>")) return error.Malformed;
                const key = try self.content("</key>");
                if ((try keys.getOrPut(self.a, key)).found_existing) return error.Malformed;
                try dict.append(self.a, .{ .key = key, .value = try self.value(depth + 1) });
            }
            // XML's documented UID wrapper is inert until archive resolution.
            if (dict.items.len == 1 and u.eq(dict.items[0].key, "CF$UID") and dict.items[0].value == .integer) {
                const uid = dict.items[0].value.integer;
                if (uid > max_objects) return error.Malformed;
                return .{ .uid = @intCast(uid) };
            }
            return .{ .dict = try dict.toOwnedSlice(self.a) };
        }
        return error.Unsupported;
    }
};
