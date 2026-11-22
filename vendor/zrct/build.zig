const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!b.isRoot()) return;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Test target lifetime, action resolution and lossless capture");
    for ([_][]const u8{ "src/registry.zig", "src/keys.zig", "src/png.zig", "src/benchmark.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        }) });
        if (std.mem.eql(u8, source, "src/png.zig")) {
            tests.root_module.link_libc = true;
            tests.root_module.linkSystemLibrary("z", .{});
        }
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    if (!supportedHost(b)) {
        inline for (.{ "tools", "python", "zrct", "desktop" }) |name|
            b.step(name, "Requires the supported native tool platform").dependOn(&b.addFail(tools_platform_error).step);
        return;
    }
    const uv = b.lazyDependency("uv_linux_x86_64", .{}) orelse return;
    const native = NativeTools.create(b, b.path("."), uv.path("uv"));
    const install_tools = b.step("tools", "Fetch and install pinned uv, Weston, FFmpeg and ImageMagick");
    inline for (.{ "weston", "ffmpeg", "imagemagick" }) |name| {
        const install = b.addInstallDirectory(.{
            .source_dir = @field(native, name),
            .install_dir = .prefix,
            .install_subdir = "tools/" ++ name,
        });
        install_tools.dependOn(&install.step);
    }
    install_tools.dependOn(&b.addInstallDirectory(.{
        .source_dir = uv.path("."),
        .install_dir = .prefix,
        .install_subdir = "tools/uv",
    }).step);

    const python = pythonCommand(b, b.path("."), native, &.{"zimbr"}, &.{});
    python.addPassthruArgs();
    b.step("python", "Run managed Python with the pinned native tools").dependOn(&python.step);

    const cli = pythonCommand(b, b.path("."), native, &.{"zimbr"}, &.{});
    cli.addArgs(&.{ "-m", "zrct" });
    cli.addPassthruArgs();
    b.step("zrct", "Run the Zrct CLI (pass arguments after --)").dependOn(&cli.step);

    const desktop = desktopCommand(b, b.path("."), native, &.{});
    b.step("desktop", "Build the Weston input module and Wayland drop client").dependOn(&desktop.step);
}

pub const ModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    sdl: *std.Build.Module,
    posix: *std.Build.Module,
    link_system_sdl: bool,
};

/// Share the application's translated SDL types with the event and renderer hooks.
pub fn createModule(b: *std.Build, dependency: *std.Build.Dependency, options: ModuleOptions) *std.Build.Module {
    const config = b.addOptions();
    config.addOption(bool, "enabled", true);
    config.addOption(bool, "native_sdl", true);
    config.addOption(enum { glfw, sdl3 }, "backend", .sdl3);
    const driver = b.createModule(.{
        .root_source_file = dependency.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    driver.addOptions("zrct_options", config);
    driver.addImport("desktop_c", options.sdl);
    driver.addImport("posix_c", options.posix);
    driver.linkSystemLibrary("z", .{});
    if (options.link_system_sdl) driver.linkSystemLibrary("sdl3", .{});
    return driver;
}

pub const EnvironmentPath = struct { name: []const u8, path: std.Build.LazyPath };

pub const RunOptions = struct {
    suite: std.Build.LazyPath,
    executable: *std.Build.Step.Compile,
    /// Defaults to the consuming project's root, regardless of the shell's cwd.
    repository: ?std.Build.LazyPath = null,
    python_extras: []const []const u8 = &.{},
    /// Build the optional Weston 15 helpers for suites using compositor input.
    desktop: bool = false,
    /// Run an explicit benchmark suite serially, with warmup and metric reports.
    benchmark: bool = false,
    environment: []const EnvironmentPath = &.{},
};

/// Build the app before running its suite. Tests always run, even on a cache hit.
/// Attach the returned step to any consumer step and add fixture dependencies as needed.
pub fn addRun(b: *std.Build, dependency: *std.Build.Dependency, options: RunOptions) *std.Build.Step.Run {
    if (!supportedHost(b)) {
        const fail = std.Build.Step.Run.create(b, "unsupported native tools");
        fail.step.dependOn(&b.addFail(tools_platform_error).step);
        return fail;
    }
    // A missing lazy dependency causes Zig to fetch and repeat configuration;
    // no make steps execute until the dependency is available.
    const uv = dependency.builder.lazyDependency("uv_linux_x86_64", .{}) orelse return std.Build.Step.Run.create(b, "fetch uv");
    const native = NativeTools.create(b, dependency.path("."), uv.path("uv"));
    const run = pythonCommand(b, dependency.path("."), native, options.python_extras, options.environment);
    run.addArgs(&.{ "-m", "zrct", if (options.benchmark) "bench" else "run" });
    run.addFileArg(options.suite);
    run.addArgs(&.{ "--no-build", "--repository" });
    run.addDirectoryArg(options.repository orelse b.path("."));
    run.addArg("--executable");
    run.addArtifactArg(options.executable);
    run.addPassthruArgs();
    if (options.desktop) {
        const desktop = desktopCommand(b, dependency.path("."), native, options.python_extras);
        run.step.dependOn(&desktop.step);
    }
    return run;
}

const tools_platform_error = "Zrct's pinned native tools require a Linux x86_64 host with compatible shared libraries (Arch Linux ABI).";

fn supportedHost(b: *std.Build) bool {
    return b.graph.host.result.os.tag == .linux and b.graph.host.result.cpu.arch == .x86_64;
}

const NativeTools = struct {
    uv: std.Build.LazyPath,
    weston: std.Build.LazyPath,
    ffmpeg: std.Build.LazyPath,
    imagemagick: std.Build.LazyPath,

    fn create(b: *std.Build, root: std.Build.LazyPath, uv: std.Build.LazyPath) NativeTools {
        var result: NativeTools = undefined;
        result.uv = uv;
        inline for (.{ "weston", "ffmpeg", "imagemagick" }) |name| {
            const fetch = uvCommand(b, uv, &.{ "run", "--no-project", "--managed-python", "--python", python_version, "python" });
            fetch.addFileArg(root.path(b, "tools/provision.py"));
            fetch.addArg("--manifest");
            fetch.addFileArg(root.path(b, "native-tools.json"));
            fetch.addArgs(&.{ "--tool", name, "--output" });
            @field(result, name) = fetch.addOutputDirectoryArg(name);
            fetch.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
        }
        return result;
    }
};

pub const python_version = std.mem.trim(u8, @embedFile(".python-version"), "\r\n ");

fn uvCommand(b: *std.Build, uv: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, "uv");
    run.addFileArg(uv);
    run.addArgs(args);
    return run;
}

fn pythonCommand(b: *std.Build, root: std.Build.LazyPath, native: NativeTools, extras: []const []const u8, environment: []const EnvironmentPath) *std.Build.Step.Run {
    const sync = b.addSystemCommand(&.{"env"});
    const run = b.addSystemCommand(&.{"env"});
    // Dependencies may live in a read-only Zig package cache. Only the consumer's
    // build cache receives the environment; import sources directly without packaging.
    var hash = std.hash.Wyhash.init(0);
    hash.update(@embedFile("uv.lock"));
    for (extras) |extra| {
        hash.update("\x00");
        hash.update(extra);
    }
    const venv = b.graph.path(.local_cache, b.fmt("zrct/venv-{x}", .{hash.final()}));
    for ([_]*std.Build.Step.Run{ sync, run }) |command| {
        envPath(command, "UV_PROJECT_ENVIRONMENT", venv);
        envPath(command, "PYTHONPATH", root);
        envPath(command, "ZRCT_PLATFORM_DIR", platformDirectory(b));
        if (command == run) for (environment) |entry| envPath(run, entry.name, entry.path);
        command.addFileArg(native.uv);
        if (command == sync) {
            sync.addArgs(&.{ "sync", "--locked", "--managed-python", "--no-install-project" });
            for (extras) |extra| sync.addArgs(&.{ "--extra", extra });
        } else run.addArgs(&.{ "run", "--no-sync", "--managed-python" });
        command.addArg("--project");
        command.addDirectoryArg(root);
        command.addArgs(&.{ "--python", python_version });
        command.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
        command.setCwd(b.path("."));
        command.has_side_effects = true;
    }
    run.addArg("python");
    run.addFileArg(root.path(b, "tools/with_tools.py"));
    run.addArg("--uv");
    run.addFileArg(native.uv);
    inline for (.{ "weston", "ffmpeg", "imagemagick" }) |name| {
        run.addArg("--" ++ name);
        run.addDirectoryArg(@field(native, name));
    }
    run.addArg("--");
    run.step.dependOn(&sync.step);
    return run;
}

fn envPath(run: *std.Build.Step.Run, name: []const u8, path: std.Build.LazyPath) void {
    run.addDirectoryArg2(path, .{ .prefix = run.step.owner.fmt("{s}=", .{name}), .make_absolute = true });
}

fn platformDirectory(b: *std.Build) std.Build.LazyPath {
    return b.graph.path(.local_cache, "zrct/platform");
}

fn desktopCommand(b: *std.Build, root: std.Build.LazyPath, native: NativeTools, extras: []const []const u8) *std.Build.Step.Run {
    const run = pythonCommand(b, root, native, extras, &.{});
    run.addFileArg(root.path(b, "platform/build.py"));
    run.addArg("--output");
    run.addDirectoryArg(platformDirectory(b));
    return run;
}
