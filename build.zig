const std = @import("std");

fn linkFastTabDependencies(step: *std.Build.Step.Compile, b: *std.Build) void {
    step.root_module.addIncludePath(b.path("include"));
    step.root_module.addIncludePath(b.path("lib/raylib-5.5/include"));

    step.root_module.linkSystemLibrary("xcb", .{});
    step.root_module.linkSystemLibrary("xcb-composite", .{});
    step.root_module.linkSystemLibrary("xcb-image", .{});
    step.root_module.linkSystemLibrary("xcb-keysyms", .{});
    step.root_module.linkSystemLibrary("xcb-damage", .{});

    step.root_module.addObjectFile(b.path("lib/raylib-5.5/lib/libraylib.a"));
    step.root_module.linkSystemLibrary("GL", .{});
    step.root_module.linkSystemLibrary("m", .{});
    step.root_module.linkSystemLibrary("pthread", .{});
    step.root_module.linkSystemLibrary("dl", .{});
    step.root_module.linkSystemLibrary("rt", .{});
    step.root_module.linkSystemLibrary("X11", .{});
    step.root_module.linkSystemLibrary("X11-xcb", .{});
    step.root_module.linkSystemLibrary("Xrandr", .{});
    step.root_module.linkSystemLibrary("Xinerama", .{});
    step.root_module.linkSystemLibrary("Xi", .{});
    step.root_module.linkSystemLibrary("Xcursor", .{});
    step.root_module.link_libc = true;
}

const CModules = struct {
    posix_c: *std.Build.Module,
    stb_image: *std.Build.Module,
    stb_resize: *std.Build.Module,
    raylib: *std.Build.Module,
    xcb: *std.Build.Module,
    xlib: *std.Build.Module,
};

fn translateHeader(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    header: []const u8,
    includes: []const []const u8,
) *std.Build.Module {
    const translated = b.addTranslateC(.{
        .root_source_file = b.path(header),
        .target = target,
        .optimize = optimize,
    });
    for (includes) |include| translated.addIncludePath(b.path(include));
    return translated.createModule();
}

fn makeCModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) CModules {
    const local = [_][]const u8{ "include", "lib/raylib-5.5/include" };
    return .{
        .posix_c = translateHeader(b, target, optimize, "src/cabi/posix_wrap.h", &.{}),
        .stb_image = translateHeader(b, target, optimize, "src/cabi/stb_image_wrap.h", &local),
        .stb_resize = translateHeader(b, target, optimize, "src/cabi/stb_resize_wrap.h", &local),
        .raylib = translateHeader(b, target, optimize, "src/cabi/raylib_wrap.h", &local),
        .xcb = translateHeader(b, target, optimize, "src/cabi/xcb_wrap.h", &.{}),
        .xlib = translateHeader(b, target, optimize, "src/cabi/xlib_wrap.h", &.{}),
    };
}

fn addAppCImports(module: *std.Build.Module, c: CModules) void {
    module.addImport("stb_image", c.stb_image);
    module.addImport("stb_resize", c.stb_resize);
    module.addImport("raylib", c.raylib);
    module.addImport("xcb", c.xcb);
    module.addImport("xlib", c.xlib);
}

fn addProgramCImports(module: *std.Build.Module, c: CModules) void {
    addAppCImports(module, c);
    module.addImport("posix_c", c.posix_c);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const c = makeCModules(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "fasttab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addProgramCImports(exe.root_module, c);
    linkFastTabDependencies(exe, b);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run fasttab");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkFastTabDependencies(exe_unit_tests, b);
    addProgramCImports(exe_unit_tests.root_module, c);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const desktop_icon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/desktop_icon.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkFastTabDependencies(desktop_icon_tests, b);
    desktop_icon_tests.root_module.addImport("stb_image", c.stb_image);
    test_step.dependOn(&b.addRunArtifact(desktop_icon_tests).step);

    const app_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkFastTabDependencies(app_unit_tests, b);
    addAppCImports(app_unit_tests.root_module, c);
    test_step.dependOn(&b.addRunArtifact(app_unit_tests).step);

    const ui_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/ui_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_module.addIncludePath(b.path("include"));
    ui_module.addIncludePath(b.path("lib/raylib-5.5/include"));
    addAppCImports(ui_module, c);
    ui_test.root_module.addImport("ui", ui_module);
    linkFastTabDependencies(ui_test, b);
    test_step.dependOn(&b.addRunArtifact(ui_test).step);

    const navigation_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/navigation_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    navigation_test.root_module.addImport("navigation", b.createModule(.{
        .root_source_file = b.path("src/navigation.zig"),
        .target = target,
        .optimize = optimize,
    }));
    test_step.dependOn(&b.addRunArtifact(navigation_test).step);

    const hardening_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/hardening_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hardening_test.root_module.addImport("navigation", b.createModule(.{
        .root_source_file = b.path("src/navigation.zig"),
        .target = target,
        .optimize = optimize,
    }));
    hardening_test.root_module.addImport("layout", b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
    }));
    test_step.dependOn(&b.addRunArtifact(hardening_test).step);

    const app_filter_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/app_filter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const app_module = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addIncludePath(b.path("include"));
    app_module.addIncludePath(b.path("lib/raylib-5.5/include"));
    addAppCImports(app_module, c);
    app_filter_test.root_module.addImport("app", app_module);
    linkFastTabDependencies(app_filter_test, b);
    test_step.dependOn(&b.addRunArtifact(app_filter_test).step);
}
