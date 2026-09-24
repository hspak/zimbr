const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const openssl = b.option([]const u8, "openssl-prefix", "Target OpenSSL 3.5 LTS prefix (static libssl.a/libcrypto.a required)");
    const sdk = b.option([]const u8, "macos-sdk", "macOS SDK for native or cross compilation") orelse
        if (target.result.os.tag == .macos and builtin.os.tag == .macos)
            std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \r\n")
        else
            null;
    for ([_]bool{ false, true }) |fake| {
        const mod = module(b, target, optimize, sdk, openssl, fake);
        const exe = b.addExecutable(.{ .name = if (fake) "fake-relay" else "relay", .root_module = mod });
        const install = b.addInstallArtifact(exe, .{});
        b.step(if (fake) "fake-relay" else "relay", if (fake) "Build the fixture relay" else "Build the macOS relay").dependOn(&install.step);
        if (!fake) {
            if (target.result.os.tag == .macos) b.getInstallStep().dependOn(&install.step);
            b.step("macos-check", "Compile the relay (use -Dtarget and -Dmacos-sdk to cross compile)").dependOn(&exe.step);
        }
    }
    const tests = b.addTest(.{ .root_module = module(b, target, optimize, sdk, openssl, true) });
    b.step("test", "Run relay and protocol tests").dependOn(&b.addRunArtifact(tests).step);
    if (target.result.os.tag == .linux) client(b, target, optimize);
}

fn clientModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: []const u8) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .link_libc = true });
    m.addIncludePath(b.path("src"));
    m.addIncludePath(b.path("src/client"));
    m.addCSourceFiles(.{ .files = &.{ "src/platform.c", "src/client/bridge.c", "src/client/notifications.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    for ([_][]const u8{ "sqlite3", "libcurl", "openssl", "pangocairo", "gio-2.0" }) |lib| m.linkSystemLibrary(lib, .{});
    return m;
}
fn client(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const fps_counter = b.option(bool, "fps-counter", "Show the FPS counter in the bottom-right corner") orelse false;
    const core = clientModule(b, target, optimize, "src/client_tests.zig");
    const tests = b.addTest(.{ .root_module = core });
    const test_run = b.addRunArtifact(tests);
    b.step("test-client", "Test client persistence, synchronization, and Unicode editing").dependOn(&test_run.step);
    b.top_level_steps.get("test").?.step.dependOn(&test_run.step);
    const probe = b.addExecutable(.{ .name = "client-probe", .root_module = clientModule(b, target, optimize, "src/client_probe.zig") });
    b.step("client-probe", "Build headless client integration driver").dependOn(&b.addInstallArtifact(probe, .{}).step);
    const bench = b.addExecutable(.{ .name = "client-bench", .root_module = clientModule(b, target, optimize, "src/client_bench.zig") });
    b.step("client-bench", "Build synthetic cached-history benchmark").dependOn(&b.addInstallArtifact(bench, .{}).step);
    const step = b.step("client", "Build the Linux desktop client");
    const clay = b.lazyDependency("zclay", .{ .target = target, .optimize = optimize }) orelse return;
    const ray = b.lazyDependency("raylib_zig", .{ .target = target, .optimize = optimize, .raudio = false, .rmodels = false, .linux_display_backend = .Wayland }) orelse return;
    const ray_module = ray.module("raylib");
    const artifact = ray.artifact("raylib");
    artifact.root_module.addCMacro("RAYLIB_WAYLAND_APP_ID", "\"zimbr\"");
    // Zig 0.16 must link Linux shared libraries at the executable, not archive them.
    var retained: usize = 0;
    for (artifact.root_module.link_objects.items) |object| switch (object) {
        .system_lib => |lib| ray_module.linkSystemLibrary(lib.name, .{ .needed = lib.needed, .weak = lib.weak, .use_pkg_config = lib.use_pkg_config, .preferred_link_mode = lib.preferred_link_mode, .search_strategy = lib.search_strategy }),
        else => {
            artifact.root_module.link_objects.items[retained] = object;
            retained += 1;
        },
    };
    artifact.root_module.link_objects.items.len = retained;
    const m = clientModule(b, target, optimize, "src/client_main.zig");
    // Use the protocol XML already pinned with raylib/GLFW.
    const activation_xml = artifact.root_module.owner.path("src/external/glfw/deps/wayland/xdg-activation-v1.xml");
    const activation_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    activation_header.addFileArg(activation_xml);
    m.addIncludePath(activation_header.addOutputFileArg("xdg-activation-v1-client-protocol.h").dirname());
    const activation_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    activation_code.addFileArg(activation_xml);
    m.addCSourceFile(.{ .file = activation_code.addOutputFileArg("xdg-activation-v1-protocol.c") });
    m.addCSourceFile(.{ .file = b.path("src/client/activation.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    m.linkSystemLibrary("wayland-client", .{});
    const client_options = b.addOptions();
    client_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    client_options.addOption(bool, "fps_counter", fps_counter);
    m.addOptions("client_options", client_options);
    m.addImport("raylib", ray_module);
    m.addImport("zclay", clay.module("zclay"));
    const gui_tests = b.addTest(.{ .root_module = m });
    b.step("test-gui", "Check sidebar clipping and theme rendering on Wayland").dependOn(&b.addRunArtifact(gui_tests).step);
    const exe = b.addExecutable(.{ .name = "zimbr", .root_module = m });
    const install = b.addInstallArtifact(exe, .{});
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Linux client").dependOn(&run.step);
    const desktop = b.addInstallFileWithDir(b.path("packaging/linux/zimbr.desktop"), .prefix, "share/applications/zimbr.desktop");
    const icon = b.addInstallFileWithDir(b.path("packaging/linux/zimbr.svg"), .prefix, "share/icons/hicolor/scalable/apps/zimbr.svg");
    step.dependOn(&desktop.step);
    step.dependOn(&icon.step);
    b.getInstallStep().dependOn(&desktop.step);
    b.getInstallStep().dependOn(&icon.step);
}
fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdk: ?[]const u8, openssl: ?[]const u8, fake: bool) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const opts = b.addOptions();
    opts.addOption(bool, "fake", fake);
    m.addOptions("options", opts);
    m.linkSystemLibrary("sqlite3", .{});
    m.addIncludePath(b.path("src"));
    m.addCSourceFile(.{ .file = b.path("src/platform.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    m.addCSourceFile(.{ .file = b.path("src/relay/tls.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    if (openssl) |prefix| {
        m.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libssl.a" }) });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libcrypto.a" }) });
    } else if (target.result.os.tag == .macos) {
        @panic("macOS relay requires -Dopenssl-prefix=/absolute/path/to/target/openssl-3.5 (static archives)");
    } else {
        m.linkSystemLibrary("ssl", .{});
        m.linkSystemLibrary("crypto", .{});
    }
    if (sdk) |s| {
        m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/include" }) });
        m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/lib" }) });
    }
    return m;
}
