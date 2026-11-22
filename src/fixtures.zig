//! Compile-time byte patterns for fixtures and benchmark workloads.
pub fn repeat(comptime pattern: []const u8, comptime count: usize) *const [pattern.len * count:0]u8 {
    const copies: [count][pattern.len]u8 = @splat(pattern[0..pattern.len].*);
    const flat: [count * pattern.len]u8 = @bitCast(copies);
    return comptime flat ++ "";
}
