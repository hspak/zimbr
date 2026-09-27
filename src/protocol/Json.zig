//! Validated JSON preserved as bytes when only its envelope needs decoding.
const std = @import("std");
const Json = @This();

bytes: []const u8,

pub const InitError = std.mem.Allocator.Error || error{SyntaxError};

/// Validate one complete value without building a tree. The caller owns bytes
/// and must keep them alive while this value is serialized.
pub fn init(gpa: std.mem.Allocator, bytes: []const u8) InitError!Json {
    if (!try std.json.validate(gpa, bytes)) return error.SyntaxError;
    return .{ .bytes = bytes };
}

/// Decode from complete input. With alloc_if_needed, bytes borrow the input;
/// alloc_always makes an allocator-owned copy. Grammar and UTF-8 are validated.
pub fn jsonParse(
    gpa: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!Json {
    if (comptime @TypeOf(source.*) != std.json.Scanner)
        @compileError("Json requires a complete-input Scanner");
    std.debug.assert(source.is_end_of_input);
    switch (try source.peekNextTokenType()) {
        .object_end, .array_end, .end_of_document => return error.UnexpectedToken,
        .object_begin, .array_begin, .number, .string, .true, .false, .null => {},
    }
    const start = source.cursor;
    try source.skipValue();
    const bytes = source.input[start..source.cursor];
    return .{ .bytes = if (options.allocate == .alloc_always) try gpa.dupe(u8, bytes) else bytes };
}

pub fn jsonStringify(value: Json, writer: *std.json.Stringify) std.json.Stringify.Error!void {
    try writer.beginWriteRaw();
    // Valid JSON has no literal CR/LF inside strings. Remove formatting line
    // breaks so an embedded record also remains safe in a single SSE data line.
    var lines = std.mem.splitAny(u8, value.bytes, "\r\n");
    while (lines.next()) |line| try writer.writer.writeAll(line);
    writer.endWriteRaw();
}

test "stored JSON embeds as a value and preserves unknown fields and exact integers" {
    const gpa = std.testing.allocator;
    const raw = "{\"text\":\"é\\n\\\"\",\"future\":[9223372036854775807,true,null]}";
    const value = try Json.init(gpa, raw);
    const encoded = try std.json.Stringify.valueAlloc(gpa, .{ .record = value }, .{});
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings("{\"record\":" ++ raw ++ "}", encoded);
    for ([_][]const u8{
        "{}{}",
        "{\"text\":\"bad\\x\"}",
        "{\"text\":\"bad\xff\"}",
        "{\"missing\":}",
        "[1,",
    }) |invalid| try std.testing.expectError(error.SyntaxError, Json.init(gpa, invalid));
}

test "raw JSON decoding preserves nested values and strips only literal line breaks on output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "{\r\n\"text\":\"line\\r\\nnext\",\n\"future\":[1.234567890123456789,1e400]}";
    const decoded = try std.json.parseFromSliceLeaky(struct { record: Json }, a, "{\"record\":" ++ raw ++ "}", .{});
    try std.testing.expectEqualStrings(raw, decoded.record.bytes);
    const encoded = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expectEqualStrings("{\"record\":{\"text\":\"line\\r\\nnext\",\"future\":[1.234567890123456789,1e400]}}", encoded);
    for ([_][]const u8{
        "null",
        "false",
        "[{},[],\"\\u0061\",-1e2]",
    }) |value| {
        const parsed = try std.json.parseFromSliceLeaky(Json, a, value, .{});
        try std.testing.expectEqualStrings(value, parsed.bytes);
    }
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSliceLeaky(Json, a, "{\"bad\":\"\\q\"}", .{}));
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSliceLeaky(Json, a, "[1,]", .{}));
}
