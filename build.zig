const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) {
        @compileError("zigder requires Zig 0.17.x via `mise exec -- zig build`.");
    }
}

const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict>
    \\<key>CFBundleIdentifier</key><string>dev.fpcmotif.zigder</string>
    \\<key>CFBundleName</key><string>zigder</string>
    \\<key>CFBundleDisplayName</key><string>zigder</string>
    \\<key>CFBundleExecutable</key><string>zigder</string>
    \\<key>CFBundlePackageType</key><string>APPL</string>
    \\<key>CFBundleShortVersionString</key><string>0.1.0</string>
    \\<key>CFBundleVersion</key><string>1</string>
    \\<key>LSMinimumSystemVersion</key><string>14.0</string>
    \\<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    \\<key>NSHighResolutionCapable</key><true/>
    \\</dict></plist>
    \\
;

fn createAppModule(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    nanoui_mod: ?*std.Build.Module,
) *std.Build.Module {
    const imports: []const std.Build.Module.Import = if (nanoui_mod) |m|
        &.{.{ .name = "nanoui", .module = m }}
    else
        &.{};
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    if (target.result.os.tag == .macos) {
        mod.linkFramework("CoreServices", .{});
        mod.linkFramework("CoreGraphics", .{});
    }
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt_arg = b.option(std.builtin.Optimize, "optimize", "Prioritize performance, safety, or binary size");
    const app_optimize = opt_arg orelse .fast;
    const test_optimize = opt_arg orelse .debug;
    const portable = b.option(bool, "portable", "Use portable text and CPU rendering") orelse false;
    const filters = b.option([]const []const u8, "test-filter", "Run only matching tests") orelse &.{};

    const nanoui = b.dependency("nanoui", .{
        .target = target,
        .optimize = app_optimize,
        .portable = portable,
    }).module("nanoui");

    const exe = b.addExecutable(.{
        .name = "zigder",
        .root_module = createAppModule(b, "zig/main.zig", target, app_optimize, nanoui),
    });
    b.installArtifact(exe);

    const cli = b.addExecutable(.{
        .name = "zigder-cli",
        .root_module = createAppModule(b, "zig/cli.zig", target, app_optimize, nanoui),
    });
    b.installArtifact(cli);

    const plist = b.addWriteFiles().add("Info.plist", info_plist);
    const bundle = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        "set -e; mkdir -p \"$1/Contents/MacOS\"; cp \"$2\" \"$1/Contents/MacOS/zigder\"; cp \"$3\" \"$1/Contents/Info.plist\"; /usr/bin/codesign --force --sign - \"$1\" 2>/dev/null; /usr/bin/codesign --verify --strict \"$1\"",
        "bundle",
    });
    const app_dir = bundle.addOutputDirectoryArg("zigder.app");
    bundle.addFileArg(exe.getEmittedBin());
    bundle.addFileArg(plist);
    b.installDirectory(.{
        .source_dir = app_dir,
        .install_dir = .prefix,
        .install_subdir = "zigder.app",
    });

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run zigder").dependOn(&run.step);

    const bench_nanoui = if (app_optimize == .fast)
        nanoui
    else
        b.dependency("nanoui", .{
            .target = target,
            .optimize = .fast,
            .portable = portable,
        }).module("nanoui");
    const bench = b.addExecutable(.{
        .name = "zigder-bench",
        .root_module = createAppModule(b, "zig/bench.zig", target, .fast, bench_nanoui),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    bench_run.has_side_effects = true;
    b.step("bench", "Measure offscreen memory and search speed").dependOn(&bench_run.step);

    const test_nanoui = if (test_optimize == app_optimize)
        nanoui
    else
        b.dependency("nanoui", .{
            .target = target,
            .optimize = test_optimize,
            .portable = portable,
        }).module("nanoui");
    const tests = b.addTest(.{
        .filters = filters,
        .root_module = createAppModule(b, "zig/tests.zig", target, test_optimize, test_nanoui),
    });
    const test_run = b.addRunArtifact(tests);
    test_run.has_side_effects = true;
    b.step("test", "Run zigder tests").dependOn(&test_run.step);

    const lines_exe = b.addExecutable(.{
        .name = "lines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lines.zig"),
            .target = b.graph.host,
            .optimize = .fast,
        }),
    });
    const lines_run = b.addRunArtifact(lines_exe);
    lines_run.has_side_effects = true;
    b.step("lines", "Enforce 600-line limit").dependOn(&lines_run.step);
}
