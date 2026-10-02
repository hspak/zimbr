//! Compile pinned SDL with a cached renderer patch; system libraries supply platform headers and drivers.
const std = @import("std");
const sources = @import("sdl/sources.zig");
const manifest = @import("../build.zig.zon");

pub const Library = struct {
    artifact: *std.Build.Step.Compile,
    source: *std.Build.Dependency,

    pub fn link(library: Library, module: *std.Build.Module) void {
        module.addIncludePath(library.source.path("include"));
        module.linkLibrary(library.artifact);
    }
};

/// Returns null while Zig fetches the lazy source dependency and reruns configuration.
pub fn addLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?Library {
    const source = b.lazyDependency("sdl", .{}) orelse return null;
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // SDL's pinned protocol headers must precede the installed Wayland headers.
    const protocols = b.addWriteFiles();
    module.addIncludePath(protocols.getDirectory());
    const revision = revisionHeader(b);
    module.addConfigHeader(revision);
    module.addIncludePath(b.path("build/sdl"));
    module.addIncludePath(source.path("include"));
    module.addIncludePath(source.path("src"));
    module.addIncludePath(source.path("src/video/khronos"));
    // Resolve the generated renderer's quoted and relative includes against upstream.
    module.addIncludePath(source.path("src/render/vulkan"));
    module.addCMacro("SDL_STATIC_LIB", "1");
    module.addCMacro("USING_GENERATED_CONFIG_H", "1");
    module.addCMacro("SDL_BUILD_MAJOR_VERSION", "3");
    module.addCMacro("SDL_BUILD_MINOR_VERSION", "4");
    module.addCMacro("SDL_BUILD_MICRO_VERSION", "16");
    module.addCMacro("EGL_NO_X11", "1");
    module.addCMacro("MESA_EGL_NO_X11_HEADERS", "1");
    module.addCMacro("_REENTRANT", "1");
    if (optimize != .Debug) module.addCMacro("NDEBUG", "1");
    for ([_][]const u8{ "m", "dl", "pthread" }) |name| {
        module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-std=gnu11", "-fno-strict-aliasing" }) catch @panic("OOM");
    // Header-only dependencies: SDL loads these libraries at runtime. In particular,
    // linking libibus here would turn an optional input service into a runtime dependency.
    const required_packages = &[_][]const u8{
        "wayland-client >= 1.18",
        "wayland-cursor",
        "wayland-egl",
        "xkbcommon >= 0.5.0",
        "egl",
        "dbus-1",
        "libdecor-0 >= 0.2.0",
    };
    // Keep missing desktop dependencies from breaking headless build steps.
    // The prerequisite reports them before compiling SDL when it is requested.
    const check_headers = b.addSystemCommand(&.{pkgConfig(b)});
    check_headers.addArgs(&.{ "--exists", "--print-errors" });
    check_headers.addArgs(required_packages);
    check_headers.has_side_effects = true;
    for (required_packages) |package| _ = addHeaderFlags(b, &flags, package);
    const ibus = b.option(bool, "ibus", "Enable SDL IBus support (default: detect development files)");
    if (ibus orelse true) {
        if (addHeaderFlags(b, &flags, "ibus-1.0")) module.addCMacro("HAVE_IBUS_IBUS_H", "1");
        if (ibus == true) check_headers.addArg("ibus-1.0");
    }
    addVersion(b, module, "xkbcommon", "SDL_XKBCOMMON_VERSION", "0.5.0");
    addVersion(b, module, "libdecor-0", "SDL_LIBDECOR_VERSION", "0.2.0");
    module.addCMacro("HAVE_LIBDECOR_H", "1");
    module.addCMacro("SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_LIBDECOR", "\"libdecor-0.so.0\"");

    const Driver = struct {
        package: []const u8,
        enabled: []const u8,
        dynamic: []const u8,
        soname: []const u8,
    };
    for ([_]Driver{
        .{
            .package = "alsa",
            .enabled = "SDL_AUDIO_DRIVER_ALSA",
            .dynamic = "SDL_AUDIO_DRIVER_ALSA_DYNAMIC",
            .soname = "libasound.so.2",
        },
        .{
            .package = "jack",
            .enabled = "SDL_AUDIO_DRIVER_JACK",
            .dynamic = "SDL_AUDIO_DRIVER_JACK_DYNAMIC",
            .soname = "libjack.so.0",
        },
        .{
            .package = "libpipewire-0.3 >= 0.3.44",
            .enabled = "SDL_AUDIO_DRIVER_PIPEWIRE",
            .dynamic = "SDL_AUDIO_DRIVER_PIPEWIRE_DYNAMIC",
            .soname = "libpipewire-0.3.so.0",
        },
        .{
            .package = "libpulse",
            .enabled = "SDL_AUDIO_DRIVER_PULSEAUDIO",
            .dynamic = "SDL_AUDIO_DRIVER_PULSEAUDIO_DYNAMIC",
            .soname = "libpulse.so.0",
        },
        .{
            .package = "sndio",
            .enabled = "SDL_AUDIO_DRIVER_SNDIO",
            .dynamic = "SDL_AUDIO_DRIVER_SNDIO_DYNAMIC",
            .soname = "libsndio.so.7",
        },
        .{
            .package = "libusb-1.0",
            .enabled = "HAVE_LIBUSB",
            .dynamic = "SDL_LIBUSB_DYNAMIC",
            .soname = "libusb-1.0.so.0",
        },
        .{
            .package = "libudev",
            .enabled = "HAVE_LIBUDEV_H",
            .dynamic = "SDL_UDEV_DYNAMIC",
            .soname = "libudev.so.1",
        },
    }) |driver| {
        if (!addHeaderFlags(b, &flags, driver.package)) continue;
        module.addCMacro(driver.enabled, "1");
        module.addCMacro(driver.dynamic, b.fmt("\"{s}\"", .{driver.soname}));
        if (std.mem.eql(u8, driver.enabled, "SDL_AUDIO_DRIVER_PIPEWIRE")) {
            module.addCMacro("SDL_CAMERA_DRIVER_PIPEWIRE", "1");
            module.addCMacro("SDL_CAMERA_DRIVER_PIPEWIRE_DYNAMIC", "\"libpipewire-0.3.so.0\"");
        }
    }
    if (addHeaderFlags(b, &flags, "liburing-ffi >= 2.3")) {
        module.addCMacro("HAVE_LIBURING_H", "1");
    }

    for (sources.protocols) |name| {
        const xml = source.path(b.fmt("wayland-protocols/{s}.xml", .{name}));
        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header.addFileArg(xml);
        const filename = b.fmt("{s}-client-protocol.h", .{name});
        _ = protocols.addCopyFile(header.addOutputFileArg(filename), filename);
        const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code.addFileArg(xml);
        module.addCSourceFile(.{ .file = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{name})) });
    }
    module.addCSourceFiles(.{
        .root = source.path(""),
        .files = sources.files,
        .flags = flags.items,
    });
    module.addCSourceFile(.{
        .file = patchRenderer(b, source),
        .flags = flags.items,
    });
    const artifact = b.addLibrary(.{
        .name = "SDL3",
        .linkage = .static,
        .root_module = module,
    });
    artifact.step.dependOn(&check_headers.step);
    return .{
        .artifact = artifact,
        .source = source,
    };
}

fn patchRenderer(b: *std.Build, source: *std.Build.Dependency) std.Build.LazyPath {
    // Only the declared output is writable; the shared dependency cache stays pristine.
    const patch = b.addSystemCommand(&.{
        "patch",
        "--batch",
        "--forward",
        "--fuzz=0",
        "--reject-file=-",
        "--no-backup-if-mismatch",
        "--output",
    });
    const renderer = patch.addOutputFileArg("SDL_render_vulkan.c");
    patch.addFileArg(source.path("src/render/vulkan/SDL_render_vulkan.c"));
    patch.addFileArg(b.path("build/sdl/vulkan.patch"));
    return renderer;
}

fn addHeaderFlags(
    b: *std.Build,
    flags: *std.ArrayList([]const u8),
    package: []const u8,
) bool {
    const output = queryPackage(b, "--cflags", package) orelse return false;
    var args = std.process.Args.IteratorGeneral(.{ .single_quotes = true }).init(b.allocator, output) catch @panic("OOM");
    defer args.deinit();
    while (args.next()) |arg| flags.append(b.allocator, b.dupe(arg)) catch @panic("OOM");
    return true;
}

fn addVersion(
    b: *std.Build,
    module: *std.Build.Module,
    package: []const u8,
    prefix: []const u8,
    minimum: []const u8,
) void {
    const output = queryPackage(b, "--modversion", package) orelse minimum;
    var parts = std.mem.tokenizeAny(u8, output, ". \t\r\n");
    for ([_][]const u8{ "MAJOR", "MINOR", "PATCH" }) |suffix| {
        const part = parts.next() orelse std.process.fatal("invalid {s} version: {s}", .{ package, output });
        const number = std.fmt.parseInt(u32, part, 10) catch std.process.fatal("invalid {s} version: {s}", .{ package, output });
        module.addCMacro(b.fmt("{s}_{s}", .{ prefix, suffix }), b.fmt("{d}", .{number}));
    }
}

fn revisionHeader(b: *std.Build) *std.Build.Step.ConfigHeader {
    // Identify both upstream contents and local changes without reading generated files.
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(manifest.dependencies.sdl.hash);
    hash.update(@embedFile("sdl/vulkan.patch"));
    hash.final(&digest);
    return b.addConfigHeader(.{ .include_path = "SDL3/SDL_revision.h" }, .{
        .SDL_REVISION = b.fmt("release-3.4.16-zimbr-vulkan-{s}", .{
            std.fmt.bytesToHex(digest[0..6], .lower),
        }),
    });
}

fn pkgConfig(b: *std.Build) []const u8 {
    return b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
}

fn queryPackage(b: *std.Build, option: []const u8, package: []const u8) ?[]const u8 {
    var exit_code: u8 = undefined;
    return b.runAllowFail(&.{ pkgConfig(b), option, package }, &exit_code, .ignore) catch |err| switch (err) {
        error.ExitCodeFailure, error.FileNotFound => null,
        else => std.process.fatal("cannot query SDL dependency {s}: {t}", .{ package, err }),
    };
}
