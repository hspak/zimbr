const std = @import("std");
const builtin = @import("builtin");
const nghttp2 = @import("build/nghttp2.zig");
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
    if (target.result.os.tag == .linux) try client(b, target, optimize, profile_name);
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
) !void {
    const fps_counter = b.option(
        bool,
        "fps-counter",
        "Show the FPS counter in the bottom-right corner",
    ) orelse false;
    const options = b.addOptions();
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
    const clay = b.lazyDependency("zclay", .{ .target = target, .optimize = optimize }) orelse return;
    const ray = b.lazyDependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .raudio = false,
        .rmodels = false,
        .linux_display_backend = .Wayland,
    }) orelse return;
    const ray_module = ray.module("raylib");
    const artifact = ray.artifact("raylib");
    artifact.root_module.addCMacro("RAYLIB_WAYLAND_APP_ID", "\"zimbr\"");
    try patchRaylibWayland(b, artifact);
    // Zig 0.16 must link Linux shared libraries at the executable, not archive them.
    var retained: usize = 0;
    for (artifact.root_module.link_objects.items) |object| switch (object) {
        .system_lib => |lib| ray_module.linkSystemLibrary(lib.name, .{
            .needed = lib.needed,
            .weak = lib.weak,
            .use_pkg_config = lib.use_pkg_config,
            .preferred_link_mode = lib.preferred_link_mode,
            .search_strategy = lib.search_strategy,
        }),
        .static_path, .other_step, .assembly_file, .c_source_file, .c_source_files, .win32_resource_file => {
            artifact.root_module.link_objects.items[retained] = object;
            retained += 1;
        },
    };
    artifact.root_module.link_objects.items.len = retained;
    const m = clientModule(b, target, optimize, "src/client_main.zig", options);
    // Use the protocol XML already pinned with raylib/GLFW.
    const activation_xml = artifact.root_module.owner.path("src/external/glfw/deps/wayland/xdg-activation-v1.xml");
    const activation_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    activation_header.addFileArg(activation_xml);
    m.addIncludePath(activation_header.addOutputFileArg("xdg-activation-v1-client-protocol.h").dirname());
    const activation_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    activation_code.addFileArg(activation_xml);
    m.addCSourceFile(.{ .file = activation_code.addOutputFileArg("xdg-activation-v1-protocol.c") });
    m.addCSourceFile(.{ .file = b.path("src/client/activation.c"), .flags = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
    } });
    m.linkSystemLibrary("wayland-client", .{});
    m.addImport("raylib", ray_module);
    m.addImport("zclay", clay.module("zclay"));
    const gui_tests = b.addTest(.{ .root_module = m });
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
    const install = b.addInstallArtifact(exe, .{});
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

fn patchRaylibWayland(b: *std.Build, artifact: *std.Build.Step.Compile) !void {
    const dependency = artifact.root_module.owner;
    const platform_path = dependency.path("src/platforms/rcore_desktop_glfw.c");
    const source = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        platform_path.getPath(b),
        b.allocator,
        // A 1 MiB read cap bounds pinned dependency source patching; larger files need review.
        .limited(1024 * 1024),
    );
    // Flamez's workaround: raylib clears GLFW hints before creating its window.
    // Keep the patch in the build so clean package builds get the same app ID.
    const hint =
        "#if defined(_GLFW_WAYLAND) && defined(RAYLIB_WAYLAND_APP_ID)\n" ++
        "    glfwWindowHintString(GLFW_WAYLAND_APP_ID, RAYLIB_WAYLAND_APP_ID);\n" ++
        "#endif\n";
    const defaults = "    glfwDefaultWindowHints();                       // Set default windows hints\n";
    // Existing development dependency trees may already carry Flamez's patch.
    const unpatched = try std.mem.replaceOwned(u8, b.allocator, source, hint, "");
    if (std.mem.count(u8, unpatched, defaults) != 1) return error.RaylibWindowHintsChanged;
    const with_hint = try std.mem.replaceOwned(u8, b.allocator, unpatched, defaults, defaults ++ hint);
    const patched = try replaceCSection(
        b.allocator,
        with_hint,
        "static void WindowDropCallback(GLFWwindow *window, int count, const char **paths)\n{",
        "// GLFW3: Keyboard callback, runs on key pressed",
        @embedFile("src/client/drop/window.h"),
    );
    const files = b.addWriteFiles();
    _ = files.add("platforms/rcore_desktop_glfw.c", patched);
    const core = files.addCopyFile(dependency.path("src/rcore.c"), "rcore.c");
    artifact.root_module.addIncludePath(dependency.path("src"));
    artifact.root_module.addIncludePath(dependency.path("src/external/glfw/src"));
    artifact.root_module.addIncludePath(b.path("src/client"));

    // A 1 MiB read cap bounds pinned dependency source patching; larger files need review.
    const init_source = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, dependency.path("src/external/glfw/src/init.c").getPath(b), b.allocator, .limited(1024 * 1024));
    _ = files.add("external/glfw/src/init.c", try replaceCSection(
        b.allocator,
        init_source,
        "char** _glfwParseUriList(char* text, int* count)\n{",
        "char* _glfw_strdup(const char* source)",
        @embedFile("src/client/drop/uri_list.h"),
    ));
    // A 1 MiB read cap bounds pinned dependency source patching; larger files need review.
    const wayland_source = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, dependency.path("src/external/glfw/src/wl_window.c").getPath(b), b.allocator, .limited(1024 * 1024));
    const reader = "static char* readDataOfferAsString(struct wl_data_offer* offer, const char* mimeType)\n{";
    if (std.mem.count(u8, wayland_source, reader) != 1) return error.GlfwDropReaderChanged;
    const with_reader = try std.mem.replaceOwned(
        u8,
        b.allocator,
        wayland_source,
        reader,
        @embedFile("src/client/drop/offer.h") ++ reader ++ "\n    if (!strcmp(mimeType, \"text/uri-list\")) return readDropOffer(offer);",
    );
    _ = files.add("external/glfw/src/wl_window.c", try replaceCSection(
        b.allocator,
        with_reader,
        "const struct wl_data_device_listener dataDeviceListener =\n{",
        "static void xdgActivationHandleDone(void* userData,",
        @embedFile("src/client/drop/hover.h"),
    ));
    const glfw = files.addCopyFile(dependency.path("src/rglfw.c"), "rglfw.c");
    try replaceCSource(b, artifact, "src/rcore.c", core);
    try replaceCSource(b, artifact, "src/rglfw.c", glfw);
}

fn replaceCSection(a: std.mem.Allocator, source: []const u8, start: []const u8, end: []const u8, replacement: []const u8) ![]const u8 {
    if (std.mem.count(u8, source, start) != 1 or std.mem.count(u8, source, end) != 1)
        return error.DropBackendChanged;
    const first = std.mem.indexOf(u8, source, start).?;
    const last = std.mem.indexOfPos(u8, source, first, end) orelse return error.DropBackendChanged;
    return std.mem.concat(a, u8, &.{ source[0..first], replacement, source[last..] });
}

fn replaceCSource(b: *std.Build, artifact: *std.Build.Step.Compile, name: []const u8, replacement: std.Build.LazyPath) !void {
    // Compile the generated copy; leave the downloaded dependency untouched.
    for (artifact.root_module.link_objects.items) |object| {
        if (object != .c_source_files) continue;
        const sources = object.c_source_files;
        for (sources.files, 0..) |file, index| {
            if (!std.mem.eql(u8, file, name)) continue;
            const remaining = try b.allocator.alloc([]const u8, sources.files.len - 1);
            @memcpy(remaining[0..index], sources.files[0..index]);
            @memcpy(remaining[index..], sources.files[index + 1 ..]);
            sources.files = remaining;
            artifact.root_module.addCSourceFile(.{
                .file = replacement,
                .flags = sources.flags,
                .language = sources.language,
            });
            return;
        }
    }
    return error.RaylibSourceNotFound;
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
