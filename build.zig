const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = b.option([]const u8, "macos-sdk", "macOS SDK for native or cross compilation") orelse
        if (target.result.os.tag == .macos and builtin.os.tag == .macos)
            std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \r\n")
        else
            null;
    for ([_]bool{ false, true }) |fake| {
        const mod = module(b, target, optimize, sdk, fake);
        const exe = b.addExecutable(.{ .name = if (fake) "fake-relay" else "relay", .root_module = mod });
        const install = b.addInstallArtifact(exe, .{});
        b.step(if (fake) "fake-relay" else "relay", if (fake) "Build the fixture relay" else "Build the macOS relay").dependOn(&install.step);
        if (!fake) {
            b.getInstallStep().dependOn(&install.step);
            b.step("macos-check", "Compile the relay (use -Dtarget and -Dmacos-sdk to cross compile)").dependOn(&exe.step);
        }
    }
    const tests = b.addTest(.{ .root_module = module(b, target, optimize, sdk, true) });
    b.step("test", "Run relay and protocol tests").dependOn(&b.addRunArtifact(tests).step);
}
fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdk: ?[]const u8, fake: bool) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const opts = b.addOptions();
    opts.addOption(bool, "fake", fake);
    m.addOptions("options", opts);
    m.linkSystemLibrary("sqlite3", .{});
    m.addIncludePath(b.path("src"));
    m.addCSourceFile(.{ .file = b.path("src/platform.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    if (sdk) |s| {
        m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/include" }) });
        m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/lib" }) });
    }
    return m;
}
