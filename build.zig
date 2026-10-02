const std = @import("std");
const builtin = @import("builtin");
const nghttp2 = @import("build/nghttp2.zig");
const sdl = @import("build/sdl.zig");
const manifest = @import("build.zig.zon");
const log = std.log.scoped(.build);
const ProfileName = enum { dev, release };
const RelayProfile = struct {
    name: []const u8,
    display_name: []const u8,
    bundle_id: []const u8,
    data_directory: []const u8,
    command: []const u8,
    default_port: u16,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Default source builds to dev so experiments use separate identities, ports, and state.
    const profile_name = b.option(ProfileName, "profile", "Application profile: dev (default) or release") orelse .dev;
    const profiles = try std.json.parseFromSlice(
        struct { dev: RelayProfile, release: RelayProfile },
        b.allocator,
        @embedFile("packaging/macos/profiles.json"),
        .{},
    );
    const profile = switch (profile_name) {
        .dev => profiles.value.dev,
        .release => profiles.value.release,
    };
    const openssl = b.option(
        []const u8,
        "openssl-prefix",
        "Target OpenSSL 3.5 LTS prefix (static libssl.a/libcrypto.a required)",
    );
    if (target.result.os.tag == .macos and openssl == null) {
        log.err("macOS relay requires -Dopenssl-prefix pointing to target OpenSSL 3.5 static archives", .{});
        return error.OpenSslPrefixRequired;
    }
    const sdk = b.option([]const u8, "macos-sdk", "macOS SDK for native or cross compilation") orelse
        if (target.result.os.tag == .macos and builtin.os.tag == .macos)
            std.mem.trim(u8, b.run(&.{
                "xcrun",
                "--sdk",
                "macosx",
                "--show-sdk-path",
            }), " \r\n")
        else
            null;
    for ([_]bool{ false, true }) |fake| {
        const mod = module(b, target, optimize, sdk, openssl, fake, profile);
        const exe = b.addExecutable(.{ .name = if (fake) "fake-relay" else "relay", .root_module = mod });
        const install = b.addInstallArtifact(exe, .{});
        const http2_license = b.addInstallFile(
            b.path("licenses/nghttp2.txt"),
            "share/zimbr/licenses/nghttp2.txt",
        );
        install.step.dependOn(&http2_license.step);
        if (fake or target.result.os.tag == .macos) {
            const helper = imageHelper(b, target, optimize, sdk, fake);
            install.step.dependOn(&b.addInstallArtifact(helper, .{}).step);
        }
        if (!fake and target.result.os.tag == .macos) {
            if (b.lazyDependency("libphonenumber", .{})) |phone| {
                const license = b.addInstallFile(
                    phone.path("LICENSE"),
                    "share/zimbr/licenses/libPhoneNumber-LICENSE",
                );
                install.step.dependOn(&license.step);
            }
        }
        b.step(
            if (fake) "fake-relay" else "relay",
            if (fake) "Build the fixture relay" else "Build the macOS relay",
        ).dependOn(&install.step);
        if (!fake) {
            if (target.result.os.tag == .macos) b.getInstallStep().dependOn(&install.step);
            b.step(
                "macos-check",
                "Compile the relay (use -Dtarget and -Dmacos-sdk to cross compile)",
            ).dependOn(&exe.step);
        }
    }
    const tests = b.addTest(.{ .root_module = module(b, target, optimize, sdk, openssl, true, profile) });
    b.step("test", "Run relay and protocol tests").dependOn(&b.addRunArtifact(tests).step);
    if (target.result.os.tag == .macos) {
        const native_tests = b.addTest(.{ .root_module = module(
            b,
            target,
            optimize,
            sdk,
            openssl,
            false,
            profile,
        ) });
        b.step(
            "test-macos-enrichment",
            "Test native Contacts normalization without reading the address book",
        ).dependOn(&b.addRunArtifact(native_tests).step);
    }
    if (target.result.os.tag == .linux) client(b, target, optimize, profile_name);
}

fn clientModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addOptions("client_options", options);
    m.addIncludePath(b.path("src"));
    m.addIncludePath(b.path("src/client"));
    m.addCSourceFiles(.{ .files = &.{
        "src/platform.c",
        "src/client/bridge.c",
        "src/client/notifications.c",
        "src/client/media.c",
        "src/client/outgoing.c",
        "src/client/drop.c",
    }, .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    for ([_][]const u8{
        "sqlite3",
        "libcurl",
        "openssl",
        "pangocairo",
        "pangoft2",
        "fontconfig",
        "gio-2.0",
        "libpng",
        "libjpeg",
    }) |lib| m.linkSystemLibrary(lib, .{});
    return m;
}
fn client(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    profile: ProfileName,
) void {
    const fps_counter = b.option(
        bool,
        "fps-counter",
        "Show the FPS counter in the bottom-right corner",
    ) orelse false;
    const automation = b.option(bool, "automation", "Enable private Zrct GUI instrumentation") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "automation", automation);
    options.addOption([]const u8, "version", manifest.version);
    options.addOption(bool, "fps_counter", fps_counter);
    options.addOption(ProfileName, "profile", profile);
    const core = clientModule(b, target, optimize, "src/client_tests.zig", options);
    const tests = b.addTest(.{ .root_module = core });
    const test_run = b.addRunArtifact(tests);
    b.step("test-client", "Test client persistence, synchronization, and Unicode editing").dependOn(&test_run.step);
    b.top_level_steps.get("test").?.step.dependOn(&test_run.step);
    const probe = b.addExecutable(.{ .name = "client-probe", .root_module = clientModule(
        b,
        target,
        optimize,
        "src/client_probe.zig",
        options,
    ) });
    b.step("client-probe", "Build headless client integration driver").dependOn(&b.addInstallArtifact(
        probe,
        .{},
    ).step);
    const bench = b.addExecutable(.{ .name = "client-bench", .root_module = clientModule(
        b,
        target,
        optimize,
        "src/client_bench.zig",
        options,
    ) });
    b.step("client-bench", "Build synthetic cached-history benchmark").dependOn(&b.addInstallArtifact(
        bench,
        .{},
    ).step);
    const hotpaths = b.addExecutable(.{ .name = "hotpath-bench", .root_module = clientModule(
        b,
        target,
        optimize,
        "src/hotpath_bench.zig",
        options,
    ) });
    b.step("hotpath-bench", "Build client and relay hot-path microbenchmarks").dependOn(&b.addInstallArtifact(
        hotpaths,
        .{},
    ).step);
    const step = b.step("client", "Build the Linux desktop client");
    const desktop_sdl = sdl.addLibrary(b, target, optimize) orelse return;
    const m = clientModule(b, target, optimize, "src/client_main.zig", options);
    addDesktop(b, m, desktop_sdl);

    const render_options = b.addOptions();
    render_options.addOption(bool, "automation", false);
    render_options.addOption([]const u8, "version", manifest.version);
    render_options.addOption(bool, "fps_counter", false);
    render_options.addOption(ProfileName, "profile", profile);
    const render_module = clientModule(b, target, optimize, "src/render_bench.zig", render_options);
    addDesktop(b, render_module, desktop_sdl);
    const render_bench = b.addExecutable(.{ .name = "render-bench", .root_module = render_module });
    b.step("render-bench", "Build synthetic benchmarks of the production chat renderer").dependOn(
        &b.addInstallArtifact(render_bench, .{}).step,
    );

    const desktop_probe = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    desktop_probe.addIncludePath(b.path("src/client"));
    desktop_probe.addCSourceFiles(.{ .files = &.{ "tests/client_desktop_probe.c", "src/client/drop.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addDesktop(b, desktop_probe, desktop_sdl);
    const desktop_exe = b.addExecutable(.{ .name = "client-desktop-probe", .root_module = desktop_probe });
    b.step("client-desktop-probe", "Build the native desktop integration probe").dependOn(&b.addInstallArtifact(desktop_exe, .{}).step);
    if (b.option(bool, "desktop-tests", "Enable optional compositor diagnostics") orelse false) {
        const desktop_suite = @import("zrct").addRun(b, b.dependency("zrct", .{}), .{
            .suite = b.path("tests/zrct/desktop_native.py"),
            .executable = desktop_exe,
            .desktop = true,
            .args = b.args orelse &.{},
        });
        b.step("test-sdl-desktop", "Test SDL services through a real Wayland compositor").dependOn(&desktop_suite.step);
    }

    // Native SDL input and renderer hooks exist only in instrumented builds.
    if (automation) {
        const zrct_dep = b.dependency("zrct", .{});
        const zrct_module = @import("zrct").createModule(b, zrct_dep, .{
            .backend = .sdl3,
            .link_system_sdl = false,
            .target = target,
            .optimize = optimize,
        });
        desktop_sdl.link(zrct_module);
        m.addImport("zrct", zrct_module);
    }
    const gui_filter = b.option([]const u8, "gui-test-filter", "Filter existing GUI regressions");
    const gui_tests = b.addTest(.{ .root_module = m, .filters = if (gui_filter) |filter| &.{filter} else &.{} });
    const install_gui = b.addInstallArtifact(gui_tests, .{ .dest_sub_path = "zimbr-gui-tests" });
    b.step("gui-test-exe", "Install the GUI regression executable without running it").dependOn(&install_gui.step);
    const isolated_gui = @import("zrct").addRun(b, b.dependency("zrct", .{}), .{
        .suite = b.path("tests/zrct/native.py"),
        .executable = gui_tests,
        .python_extras = &.{"zimbr"},
        .args = b.args orelse &.{},
    });
    isolated_gui.step.dependOn(&b.top_level_steps.get("fake-relay").?.step);
    b.step("test-gui-isolated", "Run native GUI regressions in an isolated Wayland session").dependOn(&isolated_gui.step);
    const gui_run = b.addRunArtifact(gui_tests);
    gui_run.step.dependOn(&b.top_level_steps.get("fake-relay").?.step);
    b.step("test-gui", "Test rendering and client interactions on Wayland").dependOn(&gui_run.step);
    const attachment_tests = b.addTest(.{
        .root_module = m,
        .filters = &.{"native file drops reach the synthetic relay"},
    });
    const attachment_run = b.addRunArtifact(attachment_tests);
    attachment_run.step.dependOn(&b.top_level_steps.get("fake-relay").?.step);
    b.step("test-gui-attachments", "Send native file drops through the GUI to a synthetic relay").dependOn(&attachment_run.step);
    const exe = b.addExecutable(.{ .name = "zimbr", .root_module = m });
    if (automation) {
        const zrct_dep = b.dependency("zrct", .{});
        const gui = @import("zrct").addRun(b, zrct_dep, .{
            .suite = b.path("tests/zrct/scenarios.py"),
            .executable = exe,
            .desktop = true,
            .python_extras = &.{"zimbr"},
            .args = b.args orelse &.{},
        });
        gui.step.dependOn(&b.top_level_steps.get("fake-relay").?.step);
        b.step("test-zrct", "Run isolated GUI scenarios with Zrct").dependOn(&gui.step);
        const all_gui = @import("zrct").addRun(b, zrct_dep, .{
            .suite = b.path("tests/zrct/all_scenarios.py"),
            .executable = exe,
            .desktop = true,
            .python_extras = &.{"zimbr"},
            .args = b.args orelse &.{},
        });
        all_gui.step.dependOn(&b.top_level_steps.get("fake-relay").?.step);
        b.step("test-zrct-all", "Run all GUI workflow scenarios in one report").dependOn(&all_gui.step);
        inline for (.{
            .{
                .name = "test-zrct-recovery",
                .path = "tests/zrct/recovery.py",
                .benchmark = false,
            },
            .{
                .name = "test-zrct-content",
                .path = "tests/zrct/content_scenarios.py",
                .benchmark = false,
            },
            .{
                .name = "bench-zrct",
                .path = "tests/zrct/benchmarks.py",
                .benchmark = true,
            },
        }) |suite| {
            const run_suite = @import("zrct").addRun(b, zrct_dep, .{
                .suite = b.path(suite.path),
                .executable = exe,
                .benchmark = suite.benchmark,
                .python_extras = &.{"zimbr"},
                .args = b.args orelse &.{},
            });
            run_suite.step.dependOn(&b.top_level_steps.get("fake-relay").?.step);
            const description = if (suite.benchmark)
                "Measure serial GUI workflow latency"
            else
                "Run isolated GUI workflow scenarios";
            b.step(suite.name, description).dependOn(&run_suite.step);
        }
        const ime = @import("zrct").addRun(b, zrct_dep, .{
            .suite = b.path("tests/zrct/ime.py"),
            .executable = exe,
            .desktop = true,
            .python_extras = &.{"zimbr"},
            .args = b.args orelse &.{},
        });
        ime.step.dependOn(&b.top_level_steps.get("fake-relay").?.step);
        b.step("test-ime", "Test Korean composition with an isolated IBus/Hangul engine").dependOn(&ime.step);
    }
    const install = b.addInstallArtifact(exe, .{});
    const license = b.addInstallFile(desktop_sdl.source.path("LICENSE.txt"), "share/zimbr/licenses/SDL.txt");
    install.step.dependOn(&license.step);
    for ([_][2][]const u8{
        .{ "src/hidapi/LICENSE-orig.txt", "SDL-HIDAPI.txt" },
        .{ "src/video/yuv2rgb/LICENSE", "SDL-yuv2rgb.txt" },
    }) |notice| {
        const dependency_license = b.addInstallFile(
            desktop_sdl.source.path(notice[0]),
            b.fmt("share/zimbr/licenses/{s}", .{notice[1]}),
        );
        install.step.dependOn(&dependency_license.step);
    }
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Linux client").dependOn(&run.step);
    const desktop = b.addInstallFileWithDir(
        b.path("packaging/linux/zimbr.desktop"),
        .prefix,
        "share/applications/zimbr.desktop",
    );
    const icon = b.addInstallFileWithDir(
        b.path("packaging/linux/zimbr.svg"),
        .prefix,
        "share/icons/hicolor/scalable/apps/zimbr.svg",
    );
    step.dependOn(&desktop.step);
    step.dependOn(&icon.step);
    b.getInstallStep().dependOn(&desktop.step);
    b.getInstallStep().dependOn(&icon.step);
}

fn addDesktop(b: *std.Build, m: *std.Build.Module, desktop_sdl: sdl.Library) void {
    // Keep native protocol bindings independent of the rendering dependency.
    const activation_xml = b.path("src/client/desktop/xdg-activation-v1.xml");
    const activation_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    activation_header.addFileArg(activation_xml);
    m.addIncludePath(activation_header.addOutputFileArg("xdg-activation-v1-client-protocol.h").dirname());
    const activation_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    activation_code.addFileArg(activation_xml);
    m.addCSourceFile(.{ .file = activation_code.addOutputFileArg("xdg-activation-v1-protocol.c") });
    m.addCSourceFiles(.{ .files = &.{ "src/client/desktop.c", "src/client/desktop/wayland.c" }, .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    m.linkSystemLibrary("wayland-client", .{});
    desktop_sdl.link(m);
}

fn module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk: ?[]const u8,
    openssl: ?[]const u8,
    fake: bool,
    profile: RelayProfile,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const opts = b.addOptions();
    opts.addOption(bool, "fake", fake);
    inline for (std.meta.fields(RelayProfile)) |field|
        opts.addOption(field.type, "relay_" ++ field.name, @field(profile, field.name));
    m.addOptions("options", opts);
    const h2 = nghttp2.addLibrary(b, .{
        .target = target,
        .optimize = optimize,
        .sdk = sdk,
    }) orelse return m;
    m.linkLibrary(h2);
    m.linkSystemLibrary("sqlite3", .{});
    m.addIncludePath(b.path("src"));
    m.addCSourceFile(.{ .file = b.path("src/platform.c"), .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    m.addCSourceFile(.{ .file = b.path("src/relay/tls.c"), .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    m.addCSourceFile(.{ .file = b.path("src/relay/media.c"), .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    m.addCSourceFile(.{ .file = b.path("src/relay/uploads.c"), .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    if (openssl) |prefix| {
        m.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libssl.a" }) });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libcrypto.a" }) });
    } else {
        m.linkSystemLibrary("ssl", .{});
        m.linkSystemLibrary("crypto", .{});
    }
    if (sdk) |s| {
        m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/include" }) });
        m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/lib" }) });
        m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ s, "System/Library/Frameworks" }) });
    }
    if (!fake and target.result.os.tag == .macos) {
        const phone = b.lazyDependency("libphonenumber", .{}) orelse return m;
        m.addIncludePath(phone.path("libPhoneNumber"));
        m.addIncludePath(phone.path("libPhoneNumberInternal"));
        for ([_][]const u8{
            "NBMetadataHelper",
            "NBGeneratedPhoneNumberMetaData",
            "NBNumberFormat",
            "NBPhoneMetaData",
            "NBPhoneNumber",
            "NBPhoneNumberDefines",
            "NBPhoneNumberDesc",
            "NBPhoneNumberUtil",
            "NBRegExMatcher",
            "NBRegularExpressionCache",
            "NSArray+NBAdditions",
        }) |name| {
            m.addCSourceFile(.{ .file = phone.path(b.fmt("libPhoneNumber/{s}.m", .{name})), .flags = &.{ "-fobjc-arc", "-fblocks" } });
        }
        m.addCSourceFile(.{ .file = b.path("src/relay/adapter/contacts.m"), .flags = &.{
            "-fobjc-arc",
            "-fblocks",
            "-Wall",
            "-Wextra",
            "-Werror",
        } });
        m.addCSourceFile(.{ .file = b.path("src/relay/menu.m"), .flags = &.{
            "-fobjc-arc",
            "-fblocks",
            "-Wall",
            "-Wextra",
            "-Werror",
        } });
        m.linkFramework("AppKit", .{});
        m.linkFramework("Foundation", .{});
        m.linkFramework("Contacts", .{});
        m.linkSystemLibrary("objc", .{});
        m.linkSystemLibrary("z", .{});
    }
    return m;
}

fn imageHelper(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk: ?[]const u8,
    fake: bool,
) *std.Build.Step.Compile {
    const m = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addCSourceFile(.{ .file = b.path(if (fake) "src/relay/adapter/fake-image-helper.c" else "src/relay/adapter/image-helper.m"), .flags = if (fake) &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } else &.{
        "-fobjc-arc",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    if (sdk) |s| {
        m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/include" }) });
        m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr/lib" }) });
        m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ s, "System/Library/Frameworks" }) });
    }
    if (!fake) {
        m.linkFramework("Foundation", .{});
        m.linkFramework("ImageIO", .{});
        m.linkFramework("CoreGraphics", .{});
        m.linkSystemLibrary("objc", .{});
    }
    return b.addExecutable(.{ .name = if (fake) "fake-image-helper" else "image-helper", .root_module = m });
}
