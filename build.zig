const std = @import("std");

fn linkFastTabDependencies(step: *std.Build.Step.Compile, b: *std.Build) void {
    step.addIncludePath(b.path("include"));
    step.addIncludePath(b.path("lib/raylib-5.5/include"));

    step.linkSystemLibrary("xcb");
    step.linkSystemLibrary("xcb-composite");
    step.linkSystemLibrary("xcb-image");
    step.linkSystemLibrary("xcb-keysyms");
    step.linkSystemLibrary("xcb-damage");

    step.addObjectFile(b.path("lib/raylib-5.5/lib/libraylib.a"));
    step.linkSystemLibrary("GL");
    step.linkSystemLibrary("m");
    step.linkSystemLibrary("pthread");
    step.linkSystemLibrary("dl");
    step.linkSystemLibrary("rt");
    step.linkSystemLibrary("X11");
    step.linkSystemLibrary("X11-xcb");
    step.linkSystemLibrary("Xrandr");
    step.linkSystemLibrary("Xinerama");
    step.linkSystemLibrary("Xi");
    step.linkSystemLibrary("Xcursor");
    step.linkLibC();
}

fn generatedPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    return b.path(b.fmt("zig-cache/fasttab-generated-src/{s}", .{sub_path}));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Copy src/ into Zig's cache and apply the GPU-preview compatibility patch.
    // The tracked source tree stays clean and every build starts from a fresh copy.
    const prepare_sources = b.addSystemCommand(&.{
        "bash",
        "-lc",
        "python3 tools/generate_gpu_preview_sources.py zig-cache/fasttab-generated-src && python3 tools/fix_generated_gpu_source.py zig-cache/fasttab-generated-src",
    });

    const exe = b.addExecutable(.{
        .name = "fasttab",
        .root_source_file = generatedPath(b, "main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.step.dependOn(&prepare_sources.step);
    linkFastTabDependencies(exe, b);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run fasttab");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = generatedPath(b, "main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.step.dependOn(&prepare_sources.step);
    linkFastTabDependencies(exe_unit_tests, b);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const ui_test = b.addTest(.{
        .root_source_file = generatedPath(b, "tests/ui_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_test.step.dependOn(&prepare_sources.step);
    const ui_module = b.createModule(.{
        .root_source_file = generatedPath(b, "ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_module.addIncludePath(b.path("include"));
    ui_module.addIncludePath(b.path("lib/raylib-5.5/include"));
    ui_test.root_module.addImport("ui", ui_module);
    linkFastTabDependencies(ui_test, b);
    test_step.dependOn(&b.addRunArtifact(ui_test).step);

    const navigation_test = b.addTest(.{
        .root_source_file = generatedPath(b, "tests/navigation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    navigation_test.step.dependOn(&prepare_sources.step);
    navigation_test.root_module.addImport("navigation", b.createModule(.{
        .root_source_file = generatedPath(b, "navigation.zig"),
        .target = target,
        .optimize = optimize,
    }));
    test_step.dependOn(&b.addRunArtifact(navigation_test).step);

    const hardening_test = b.addTest(.{
        .root_source_file = generatedPath(b, "tests/hardening_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    hardening_test.step.dependOn(&prepare_sources.step);
    hardening_test.root_module.addImport("navigation", b.createModule(.{
        .root_source_file = generatedPath(b, "navigation.zig"),
        .target = target,
        .optimize = optimize,
    }));
    hardening_test.root_module.addImport("layout", b.createModule(.{
        .root_source_file = generatedPath(b, "layout.zig"),
        .target = target,
        .optimize = optimize,
    }));
    test_step.dependOn(&b.addRunArtifact(hardening_test).step);

    const app_filter_test = b.addTest(.{
        .root_source_file = generatedPath(b, "tests/app_filter_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_filter_test.step.dependOn(&prepare_sources.step);
    const app_module = b.createModule(.{
        .root_source_file = generatedPath(b, "app.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addIncludePath(b.path("include"));
    app_module.addIncludePath(b.path("lib/raylib-5.5/include"));
    app_filter_test.root_module.addImport("app", app_module);
    linkFastTabDependencies(app_filter_test, b);
    test_step.dependOn(&b.addRunArtifact(app_filter_test).step);
}
