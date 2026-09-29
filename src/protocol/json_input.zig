//! Allocation-free bounds before the JSON parser sees untrusted input. This
//! checks structure, not the JSON grammar; the typed parser still validates it.
const std = @import("std");
// 32 levels leaves room for nested metadata while bounding the parser's stack.
pub const max_depth = 32;

/// Decode T once while retaining its exact wire representation for persistence.
/// With alloc_if_needed, raw and unescaped strings borrow the complete input;
/// alloc_always gives the allocator ownership of both representations.
pub fn Decoded(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,
        raw: []const u8,

        pub fn jsonParse(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!Self {
            if (comptime @TypeOf(source.*) != std.json.Scanner)
                @compileError("Decoded requires a complete-input Scanner");
            std.debug.assert(source.is_end_of_input);
            _ = try source.peekNextTokenType();
            const start = source.cursor;
            const value = try std.json.innerParse(T, gpa, source, options);
            const raw = source.input[start..source.cursor];
            return .{
                .value = value,
                .raw = if (options.allocate == .alloc_always) try gpa.dupe(u8, raw) else raw,
            };
        }
    };
}

test "decoded records retain exact wire bytes and use typed field validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Entry = struct { text: []const u8, count: i64 };
    const Envelope = struct { records: []const Decoded(Entry), next: ?[]const u8 };
    const raw = "{ \"text\":\"é\\n\\\"\", \"count\":9223372036854775807,\"future\":1.234567890123456789 }";
    const envelope = "{\"records\":[" ++ raw ++ "],\"next\":null}";
    const decoded = try std.json.parseFromSliceLeaky(Envelope, a, envelope, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings(raw, decoded.records[0].raw);
    try std.testing.expectEqualStrings("é\n\"", decoded.records[0].value.text);
    try std.testing.expectEqual(std.math.maxInt(i64), decoded.records[0].value.count);
    try std.testing.expectEqual(envelope[12..].ptr, decoded.records[0].raw.ptr);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.next);
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSliceLeaky(
        Decoded(Entry),
        a,
        "{\"text\":\"one\",\"text\":\"two\",\"count\":1}",
        .{},
    ));
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSliceLeaky(
        Decoded(Entry),
        a,
        "{\"text\":\"one\",\"count\":1,\"future\":\"bad\\q\"}",
        .{ .ignore_unknown_fields = true },
    ));
    var mutable = "{\"text\":\"owned\",\"count\":7}".*;
    const owned = try std.json.parseFromSliceLeaky(Decoded(Entry), a, &mutable, .{ .allocate = .alloc_always });
    @memset(&mutable, 'x');
    try std.testing.expectEqualStrings("owned", owned.value.text);
    try std.testing.expectEqualStrings("{\"text\":\"owned\",\"count\":7}", owned.raw);
}

pub const CheckError = error{
    InvalidJson,
    JsonTooComplex,
    JsonTooDeep,
    JsonTooLarge,
};

pub fn check(bytes: []const u8, max_bytes: usize, max_tokens: usize) CheckError!void {
    return checkImpl(true, bytes, max_bytes, max_tokens);
}
fn checkImpl(comptime vectorize: bool, bytes: []const u8, max_bytes: usize, max_tokens: usize) !void {
    if (bytes.len > max_bytes) return error.JsonTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidJson;
    var stack: [max_depth]u8 = undefined;
    var depth: usize = 0;
    var tokens: usize = 0;
    var quoted = false;
    var escaped = false;
    var primitive = false;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        // Message bodies dominate these documents. Skip ordinary string bytes
        // in 128-bit blocks (NEON on M1), leaving escapes and delimiters to the
        // same scalar state machine. UTF-8 was validated above.
        if (vectorize and quoted and !escaped) {
            while (bytes.len - i >= 16) {
                const block: @Vector(16, u8) = bytes[i..][0..16].*;
                const special = (block == @as(@Vector(16, u8), @splat('"'))) |
                    (block == @as(@Vector(16, u8), @splat('\\')));
                const ordinary: usize = if (std.simd.firstTrue(special)) |at| at else 16;
                i += ordinary;
                if (ordinary != 16) break;
            }
            if (i == bytes.len) break;
        }
        const byte = bytes[i];
        if (quoted) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
            continue;
        }
        switch (byte) {
            '"', '{', '[' => {
                tokens += 1;
                primitive = false;
                if (byte == '"') {
                    quoted = true;
                } else {
                    if (depth == stack.len) return error.JsonTooDeep;
                    stack[depth] = if (byte == '{') '}' else ']';
                    depth += 1;
                }
            },
            '}', ']' => {
                if (depth == 0 or stack[depth - 1] != byte) return error.InvalidJson;
                depth -= 1;
                primitive = false;
            },
            ',', ':', ' ', '\t', '\r', '\n' => primitive = false,
            else => if (!primitive) {
                tokens += 1;
                primitive = true;
            },
        }
        if (tokens > max_tokens) return error.JsonTooComplex;
    }
    if (quoted or depth != 0) return error.InvalidJson;
}

test "JSON bounds include unknown fields but ignore escaped delimiters" {
    try check("{\"text\":\"[\\\"}\\\\\",\"future\":[true,null,2]}", 1024, 32);
    try check("[" ** max_depth ++ "0" ++ "]" ** max_depth, 1024, 64);
    try std.testing.expectError(
        error.JsonTooDeep,
        check("[" ** (max_depth + 1) ++ "0" ++ "]" ** (max_depth + 1), 1024, 64),
    );
    try std.testing.expectError(error.JsonTooComplex, check("[0,0,0,0]", 1024, 4));
    try std.testing.expectError(error.JsonTooLarge, check("[0]", 2, 10));
    try std.testing.expectError(error.InvalidJson, check("{]", 1024, 10));
    try std.testing.expectError(error.InvalidJson, check("\"bad\xff\"", 1024, 10));
}

test "vector string scanning matches scalar bounds across escapes and tails" {
    var random = std.Random.DefaultPrng.init(0x7e57);
    var bytes: [256]u8 = undefined;
    const alphabet = "abcdef0123{}[],: \t\n\r\"\\";
    for (0..4000) |_| {
        const len = random.random().uintLessThan(usize, bytes.len + 1);
        for (bytes[0..len]) |*byte| byte.* = alphabet[
            random.random().uintLessThan(
                usize,
                alphabet.len,
            )
        ];
        const tokens = random.random().uintLessThan(usize, 40);
        const expected: ?CheckError = if (checkImpl(false, bytes[0..len], bytes.len, tokens)) null else |err| err;
        const actual: ?CheckError = if (check(bytes[0..len], bytes.len, tokens)) null else |err| err;
        try std.testing.expectEqual(expected, actual);
    }
    // Put each escape/delimiter and UTF-8 sequence at every SIMD alignment.
    for (0..48) |prefix| {
        @memset(&bytes, 'a');
        bytes[0] = '"';
        const suffix = "\\\"\\\\👩‍💻\"}";
        @memcpy(bytes[1 + prefix ..][0..suffix.len], suffix);
        const input = bytes[0 .. 1 + prefix + suffix.len];
        for (0..input.len + 1) |len| {
            const expected: ?CheckError = if (checkImpl(false, input[0..len], 256, 32)) null else |err| err;
            const actual: ?CheckError = if (check(input[0..len], 256, 32)) null else |err| err;
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "long quoted prefixes cannot hide depth token or byte limits" {
    const a = std.testing.allocator;
    for (0..32) |padding| {
        const prefix = try std.fmt.allocPrint(
            a,
            "{{\"padding\":\"{s}\\\"\\\\\",\"unknown\":",
            .{("a" ** 96)[0 .. 64 + padding]},
        );
        defer a.free(prefix);
        const deep = try std.mem.concat(a, u8, &.{ prefix, "[" ** 31 ++ "0" ++ "]" ** 31 ++ "}" });
        defer a.free(deep);
        try check(deep, deep.len, 8192);
        const too_deep = try std.mem.concat(
            a,
            u8,
            &.{ prefix, "[" ** 32 ++ "0" ++ "]" ** 32 ++ "}" },
        );
        defer a.free(too_deep);
        try std.testing.expectError(error.JsonTooDeep, check(too_deep, too_deep.len, 8192));
        // Object, two keys, string value, array, and 8,187 number tokens.
        const wide = try std.mem.concat(a, u8, &.{ prefix, "[" ++ "0," ** 8186 ++ "0]}" });
        defer a.free(wide);
        try check(wide, wide.len, 8192);
        try std.testing.expectError(error.JsonTooComplex, check(wide, wide.len, 8191));
        try std.testing.expectError(error.JsonTooLarge, check(wide, wide.len - 1, 8192));
    }
}
