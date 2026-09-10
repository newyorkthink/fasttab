const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const IconResult = struct {
    width: i32,
    height: i32,
    pixels: []u8,

    pub fn deinit(self: *IconResult) void {
        c.stbi_image_free(self.pixels.ptr);
    }
};

const ICON_SIZES = [_][]const u8{ "16x16", "22x22", "24x24", "32x32", "48x48", "64x64", "128x128", "256x256", "512x512" };
const MAX_PROC_ENV_BYTES = 1024 * 1024;

pub fn getAppIcon(allocator: mem.Allocator, app_name: []const u8, target_size: u32) !IconResult {
    var host_icon_found = false;

    if (try findIconNameFromDesktop(allocator, app_name)) |icon_id| {
        host_icon_found = true;
        defer allocator.free(icon_id);

        if (fs.path.isAbsolute(icon_id)) {
            if (loadPng(icon_id)) |icon| {
                return icon;
            } else |_| {}
        } else if (try resolveIconPath(allocator, icon_id, target_size)) |icon_path| {
            defer allocator.free(icon_path);
            if (loadPng(icon_path)) |icon| {
                return icon;
            } else |_| {}
        }
    }

    // AppImage fallback: mirror the working AltTab behavior by locating
    // running AppImage mounts through APPDIR and using their embedded icon.
    if (try getRunningAppImageIcon(allocator, app_name)) |icon| {
        return icon;
    }

    if (host_icon_found) return error.IconFileNotFound;
    return error.IconNameNotFound;
}

fn isDecimalName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn getRunningAppImageIcon(allocator: mem.Allocator, app_name: []const u8) !?IconResult {
    var proc_dir = fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer proc_dir.close();

    var proc_iter = proc_dir.iterate();
    while (proc_iter.next() catch null) |entry| {
        if (!isDecimalName(entry.name)) continue;

        const environ_path = try fs.path.join(allocator, &.{ "/proc", entry.name, "environ" });
        defer allocator.free(environ_path);

        var file = fs.openFileAbsolute(environ_path, .{}) catch continue;
        defer file.close();

        const environment = file.readToEndAlloc(allocator, MAX_PROC_ENV_BYTES) catch continue;
        defer allocator.free(environment);

        var env_iter = mem.splitScalar(u8, environment, 0);
        while (env_iter.next()) |item| {
            if (!mem.startsWith(u8, item, "APPDIR=")) continue;

            const appdir = item[7..];
            if (appdir.len == 0 or !fs.path.isAbsolute(appdir)) break;
            fs.accessAbsolute(appdir, .{}) catch break;

            if (try loadMatchingAppDirIcon(allocator, appdir, app_name)) |icon| {
                return icon;
            }
            break;
        }
    }

    return null;
}

fn loadMatchingAppDirIcon(allocator: mem.Allocator, appdir: []const u8, app_name: []const u8) !?IconResult {
    var dir = fs.openDirAbsolute(appdir, .{ .iterate = true }) catch return null;
    defer dir.close();

    const desktop_file = if (mem.endsWith(u8, app_name, ".desktop"))
        try allocator.dupe(u8, app_name)
    else
        try std.fmt.allocPrint(allocator, "{s}.desktop", .{app_name});
    defer allocator.free(desktop_file);

    var dir_iter = dir.iterate();
    while (dir_iter.next() catch null) |entry| {
        if (!mem.endsWith(u8, entry.name, ".desktop")) continue;

        const filename_matches = mem.eql(u8, entry.name, desktop_file);
        const icon_id = try scanAppDirDesktopForIcon(allocator, dir, entry.name, app_name, filename_matches) orelse continue;
        defer allocator.free(icon_id);

        // AppImage convention: .DirIcon normally points at the application icon.
        const diricon = try fs.path.join(allocator, &.{ appdir, ".DirIcon" });
        defer allocator.free(diricon);
        if (loadPng(diricon)) |icon| {
            return icon;
        } else |_| {}

        if (try loadAppDirIconValue(allocator, appdir, icon_id)) |icon| {
            return icon;
        }
    }

    return null;
}

fn scanAppDirDesktopForIcon(
    allocator: mem.Allocator,
    dir: fs.Dir,
    filename: []const u8,
    app_name: []const u8,
    filename_matches: bool,
) !?[]const u8 {
    var file = dir.openFile(filename, .{}) catch return null;
    defer file.close();

    var icon_val: ?[]const u8 = null;
    errdefer if (icon_val) |v| allocator.free(v);

    var wm_class_matches = false;
    var reader = std.io.bufferedReader(file.reader());
    var buf: [1024]u8 = undefined;
    while (reader.reader().readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
        const t = mem.trim(u8, line, " \r");
        if (icon_val == null and mem.startsWith(u8, t, "Icon=")) {
            icon_val = try allocator.dupe(u8, t[5..]);
        }
        if (mem.startsWith(u8, t, "StartupWMClass=") and mem.eql(u8, t[15..], app_name)) {
            wm_class_matches = true;
        }
    }

    if (filename_matches or wm_class_matches) return icon_val;
    if (icon_val) |v| allocator.free(v);
    return null;
}

fn loadAppDirIconValue(allocator: mem.Allocator, appdir: []const u8, icon_id: []const u8) !?IconResult {
    const candidate = if (fs.path.isAbsolute(icon_id)) blk: {
        if (mem.startsWith(u8, icon_id, appdir)) {
            break :blk try allocator.dupe(u8, icon_id);
        }
        break :blk try fs.path.join(allocator, &.{ appdir, mem.trimLeft(u8, icon_id, "/") });
    } else try fs.path.join(allocator, &.{ appdir, icon_id });
    defer allocator.free(candidate);

    if (loadPng(candidate)) |icon| {
        return icon;
    } else |_| {}

    if (!mem.endsWith(u8, candidate, ".png")) {
        const png_candidate = if (mem.endsWith(u8, candidate, ".svg"))
            try std.fmt.allocPrint(allocator, "{s}.png", .{candidate[0 .. candidate.len - 4]})
        else
            try std.fmt.allocPrint(allocator, "{s}.png", .{candidate});
        defer allocator.free(png_candidate);

        if (loadPng(png_candidate)) |icon| {
            return icon;
        } else |_| {}
    }

    return null;
}

/// Returns an owned copy of the XDG data home directory path.
fn xdgDataHome(allocator: mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |v| return allocator.dupe(u8, v);
    const home = std.posix.getenv("HOME") orelse "";
    return fs.path.join(allocator, &.{ home, ".local/share" });
}

fn findIconNameFromDesktop(allocator: mem.Allocator, app_name: []const u8) !?[]const u8 {
    const data_home = try xdgDataHome(allocator);
    defer allocator.free(data_home);

    // Build search dirs per XDG Base Directory spec:
    // $XDG_DATA_HOME/applications, then each $XDG_DATA_DIRS entry/applications
    var search_dirs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (search_dirs.items) |dir| allocator.free(dir);
        search_dirs.deinit();
    }

    try search_dirs.append(try fs.path.join(allocator, &.{ data_home, "applications" }));

    const xdg_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = mem.splitScalar(u8, xdg_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        try search_dirs.append(try fs.path.join(allocator, &.{ dir, "applications" }));
    }

    const desktop_file = if (mem.endsWith(u8, app_name, ".desktop"))
        try allocator.dupe(u8, app_name)
    else
        try std.fmt.allocPrint(allocator, "{s}.desktop", .{app_name});
    defer allocator.free(desktop_file);

    // Pass 1: exact filename match
    for (search_dirs.items) |base| {
        if (!fs.path.isAbsolute(base)) continue;

        var dir = fs.openDirAbsolute(base, .{}) catch continue;
        defer dir.close();

        var file = dir.openFile(desktop_file, .{}) catch continue;
        defer file.close();

        var reader = std.io.bufferedReader(file.reader());
        var buf: [1024]u8 = undefined;
        while (try reader.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const trimmed = mem.trim(u8, line, " \r");
            if (mem.startsWith(u8, trimmed, "Icon=")) {
                return try allocator.dupe(u8, trimmed[5..]);
            }
        }
    }

    // Pass 2: scan all .desktop files for StartupWMClass= match.
    // Handles apps like JetBrains Toolbox that append UUIDs to desktop filenames.
    for (search_dirs.items) |base| {
        if (!fs.path.isAbsolute(base)) continue;
        var dir = fs.openDirAbsolute(base, .{ .iterate = true }) catch continue;
        defer dir.close();
        var dir_iter = dir.iterate();
        while (dir_iter.next() catch null) |entry| {
            if (!mem.endsWith(u8, entry.name, ".desktop")) continue;
            if (try scanDesktopForWMClass(allocator, dir, entry.name, app_name)) |icon| {
                return icon;
            }
        }
    }

    return null;
}

/// Read a single .desktop file and return the Icon= value if StartupWMClass= matches wm_class.
/// Returns null if the file doesn't match or can't be read.
fn scanDesktopForWMClass(allocator: mem.Allocator, dir: fs.Dir, filename: []const u8, wm_class: []const u8) !?[]const u8 {
    var file = dir.openFile(filename, .{}) catch return null;
    defer file.close();

    var icon_val: ?[]const u8 = null;
    errdefer if (icon_val) |v| allocator.free(v);

    var wm_class_matches = false;
    var reader = std.io.bufferedReader(file.reader());
    var buf: [1024]u8 = undefined;
    while (reader.reader().readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
        const t = mem.trim(u8, line, " \r");
        if (icon_val == null and mem.startsWith(u8, t, "Icon="))
            icon_val = try allocator.dupe(u8, t[5..]);
        if (mem.startsWith(u8, t, "StartupWMClass=") and mem.eql(u8, t[15..], wm_class))
            wm_class_matches = true;
    }

    if (wm_class_matches) return icon_val;
    if (icon_val) |v| allocator.free(v);
    return null;
}

fn resolveIconPath(allocator: mem.Allocator, icon_id: []const u8, target_size: u32) !?[]const u8 {
    const data_home = try xdgDataHome(allocator);
    defer allocator.free(data_home);

    // Build hicolor roots per XDG spec:
    // $XDG_DATA_HOME/icons/hicolor, then each $XDG_DATA_DIRS entry/icons/hicolor
    var hicolor_roots = std.ArrayList([]const u8).init(allocator);
    defer {
        for (hicolor_roots.items) |dir| allocator.free(dir);
        hicolor_roots.deinit();
    }

    try hicolor_roots.append(try fs.path.join(allocator, &.{ data_home, "icons/hicolor" }));

    const xdg_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = mem.splitScalar(u8, xdg_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        try hicolor_roots.append(try fs.path.join(allocator, &.{ dir, "icons/hicolor" }));
    }

    // Find starting index for target size
    var start_idx: usize = 0;
    const target_str = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ target_size, target_size });
    defer allocator.free(target_str);
    for (ICON_SIZES, 0..) |size_str, i| {
        if (mem.eql(u8, size_str, target_str)) {
            start_idx = i;
            break;
        }
    }

    const icon_filename = try std.fmt.allocPrint(allocator, "{s}.png", .{icon_id});
    defer allocator.free(icon_filename);

    // Strategy: Check requested size, then crawl UP for higher fidelity
    for (ICON_SIZES[start_idx..]) |size_dir| {
        for (hicolor_roots.items) |root| {
            const path = try fs.path.join(allocator, &.{ root, size_dir, "apps", icon_filename });
            fs.accessAbsolute(path, .{}) catch {
                allocator.free(path);
                continue;
            };
            return path;
        }
    }

    // Last resort: check pixmaps in each XDG data dir (common for non-themed apps)
    var it2 = mem.splitScalar(u8, xdg_dirs, ':');
    while (it2.next()) |dir| {
        if (dir.len == 0) continue;
        const path = try fs.path.join(allocator, &.{ dir, "pixmaps", icon_filename });
        fs.accessAbsolute(path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }

    return null;
}

fn loadPng(path: []const u8) !IconResult {
    var width: i32 = 0;
    var height: i32 = 0;
    var channels: i32 = 0;

    // stb_image expects a null-terminated C string. fs.path.join returns a normal slice,
    // so copying into a sentinel buffer avoids random icon-load failures or over-read.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const zpath = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});

    // We force 4 channels to ensure we get RGBA/ARGB consistently
    const data = c.stbi_load(zpath.ptr, &width, &height, &channels, 4);
    if (data == null) return error.StbLoadError;

    return IconResult{
        .width = width,
        .height = height,
        .pixels = data[0..@intCast(width * height * 4)],
    };
}
