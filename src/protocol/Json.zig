//! Allocation-free bounds before the JSON parser sees untrusted input. This
//! checks structure, not the JSON grammar; the typed parser still validates it.
const std = @import("std");
pub const max_depth = 32;
pub fn check(bytes: []const u8, max_bytes: usize, max_tokens: usize) !void {
    if (bytes.len > max_bytes) return error.JsonTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidJson;
    var stack: [max_depth]u8 = undefined;
    var depth: usize = 0;
    var tokens: usize = 0;
    var quoted = false;
    var escaped = false;
    var primitive = false;
    for (bytes) |byte| {
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
    try std.testing.expectError(error.JsonTooDeep, check("[" ** (max_depth + 1) ++ "0" ++ "]" ** (max_depth + 1), 1024, 64));
    try std.testing.expectError(error.JsonTooComplex, check("[0,0,0,0]", 1024, 4));
    try std.testing.expectError(error.JsonTooLarge, check("[0]", 2, 10));
    try std.testing.expectError(error.InvalidJson, check("{]", 1024, 10));
    try std.testing.expectError(error.InvalidJson, check("\"bad\xff\"", 1024, 10));
}
