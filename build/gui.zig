//! Run GUI suites with the pinned native tools supplied by the build graph.
const std = @import("std");

/// Adds Zimbr's software Vulkan driver to Zrct's managed test tools.
pub fn addRun(
    comptime Zrct: type,
    b: *std.Build,
    dependency: *std.Build.Dependency,
    options: Zrct.RunOptions,
) *std.Build.Step.Run {
    const run = Zrct.addRun(b, dependency, options);
    // Zrct reports unsupported hosts before any native tooling is downloaded.
    if (b.graph.host.result.os.tag != .linux or b.graph.host.result.cpu.arch != .x86_64)
        return run;
    const uv = dependency.builder.lazyDependency("uv_linux_x86_64", .{}) orelse return run;
    const python_version = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        dependency.path(".python-version").getPath(b),
        b.allocator,
        .limited(64),
    ) catch |err| {
        run.step.dependOn(&b.addFail(b.fmt("Cannot read Zrct's Python version: {t}", .{err})).step);
        return run;
    };
    const fetch = std.Build.Step.Run.create(b, "provision Lavapipe");
    fetch.addFileArg(uv.path("uv"));
    fetch.addArgs(&.{
        "run",
        "--no-project",
        "--managed-python",
        "--python",
    });
    fetch.addArg(std.mem.trim(u8, python_version, " \r\n"));
    fetch.addArg("python");
    fetch.addFileArg(dependency.path("tools/provision.py"));
    fetch.addArg("--manifest");
    fetch.addFileArg(b.path("build/native-tools.json"));
    fetch.addArgs(&.{
        "--tool",
        "lavapipe",
        "--output",
    });
    const package = fetch.addOutputDirectoryArg("lavapipe");
    fetch.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    const install = b.addInstallDirectory(.{
        .source_dir = package,
        .install_dir = .prefix,
        .install_subdir = "tools/lavapipe",
    });
    run.step.dependOn(&install.step);
    run.setEnvironmentVariable("ZIMBR_LAVAPIPE_ROOT", b.getInstallPath(.prefix, "tools/lavapipe"));
    return run;
}
