//! Run GUI suites with the pinned native tools supplied by the build graph.
const std = @import("std");

/// Adds Zimbr's software Vulkan driver to Zrct's managed test tools.
pub fn addRun(
    comptime Zrct: type,
    b: *std.Build,
    dependency: *std.Build.Dependency,
    options: Zrct.RunOptions,
) *std.Build.Step.Run {
    // Zrct reports unsupported hosts before any native tooling is downloaded.
    if (b.graph.host.result.os.tag != .linux or b.graph.host.result.cpu.arch != .x86_64)
        return Zrct.addRun(b, dependency, options);
    const uv = dependency.builder.lazyDependency("uv_linux_x86_64", .{}) orelse return Zrct.addRun(b, dependency, options);
    const fetch = std.Build.Step.Run.create(b, "provision Lavapipe");
    fetch.addFileArg(uv.path("uv"));
    fetch.addArgs(&.{
        "run",
        "--no-project",
        "--managed-python",
        "--python",
    });
    fetch.addArg(Zrct.python_version);
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
    var suite = options;
    suite.environment = &.{
        .{ .name = "ZIMBR_LAVAPIPE_ROOT", .path = b.graph.path(.install_prefix, "tools/lavapipe") },
        .{ .name = "ZIMBR_TEST_BIN", .path = b.graph.path(.install_bin, "") },
    };
    const run = Zrct.addRun(b, dependency, suite);
    run.step.dependOn(&install.step);
    return run;
}
