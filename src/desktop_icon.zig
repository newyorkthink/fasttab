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

const ICON_SIZES = [_][]const u8{ "16x16", "22x22", "24x24", "32x32", "36x36", "48x48", "64x64", "72x72", "96x96", "128x128", "192x192", "256x256", "512x512", "1024x1024" };
const MAX_PROC_ENV_BYTES = 1024 * 1024;

pub fn getAppIcon(allocator: mem.Allocator, app_names: []const []const u8, target_size: u32, pid: ?std.posix.pid_t) !IconResult {
    // Both WM_CLASS strings are useful; a custom instance must not hide the class.
    for (app_names) |app_name| {
        if (app_name.len == 0 or mem.eql(u8, app_name, "(unknown)")) continue;
        if (try findIconNameFromDesktop(allocator, app_name)) |icon_id| {
            defer allocator.free(icon_id);
            if (fs.path.isAbsolute(icon_id)) {
                if (loadPng(icon_id)) |icon| return icon else |_| {}
            } else if (try resolveIconPath(allocator, icon_id, target_size)) |icon_path| {
                defer allocator.free(icon_path);
                if (loadPng(icon_path)) |icon| return icon else |_| {}
            }
        }
    }

    // The window PID identifies the AppImage, even with a custom WM_CLASS.
    // Never scan unrelated processes or require a matching desktop filename.
    if (pid) |process_id| {
        if (try getProcessAppImageIcon(allocator, process_id)) |icon| return icon;
    }
    return error.IconFileNotFound;
}

fn appDirFromEnvironment(environment: []const u8) ?[]const u8 {
    var entries = mem.splitScalar(u8, environment, 0);
    while (entries.next()) |entry| {
        if (!mem.startsWith(u8, entry, "APPDIR=")) continue;
        const path = entry[7..];
        return if (fs.path.isAbsolute(path)) path else null;
    }
    return null;
}

fn getProcessAppImageIcon(allocator: mem.Allocator, pid: std.posix.pid_t) !?IconResult {
    if (pid <= 0) return null;
    const path = try std.fmt.allocPrint(allocator, "/proc/{d}/environ", .{pid});
    defer allocator.free(path);
    var file = fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const environment = file.readToEndAlloc(allocator, MAX_PROC_ENV_BYTES) catch return null;
    defer allocator.free(environment);
    const appdir = appDirFromEnvironment(environment) orelse return null;
    return loadAppDirIcon(allocator, appdir);
}

fn loadAppDirIcon(allocator: mem.Allocator, appdir: []const u8) !?IconResult {
    var dir = fs.openDirAbsolute(appdir, .{}) catch return null;
    defer dir.close();
    const diricon = try fs.path.join(allocator, &.{ appdir, ".DirIcon" });
    defer allocator.free(diricon);
    if (loadPng(diricon)) |icon| return icon else |_| {}

    // Some bundles use an absolute /usr/... symlink relative to their AppDir.
    var link_buf: [fs.max_path_bytes]u8 = undefined;
    if (dir.readLink(".DirIcon", &link_buf)) |target| {
        if (try loadAppDirIconValue(allocator, appdir, target)) |icon| return icon;
    } else |_| {}

    for ([_][]const u8{ ".", "usr/share/applications" }) |subdir| {
        var desktop_dir = dir.openDir(subdir, .{ .iterate = true }) catch continue;
        defer desktop_dir.close();
        var iter = desktop_dir.iterate();
        while (iter.next() catch null) |entry| {
            if (!mem.endsWith(u8, entry.name, ".desktop")) continue;
            const icon_id = try scanDesktopForIcon(allocator, desktop_dir, entry.name, null) orelse continue;
            defer allocator.free(icon_id);
            if (try loadAppDirIconValue(allocator, appdir, icon_id)) |icon| return icon;
        }
    }
    return null;
}

/// Read only the main Desktop Entry group, never an action's Icon/WMClass.
fn scanDesktopForIcon(allocator: mem.Allocator, dir: fs.Dir, filename: []const u8, wm_class: ?[]const u8) !?[]const u8 {
    var file = dir.openFile(filename, .{}) catch return null;
    defer file.close();
    var icon_val: ?[]const u8 = null;
    errdefer if (icon_val) |v| allocator.free(v);
    var matches = wm_class == null;
    var in_entry = false;
    var reader = std.io.bufferedReader(file.reader());
    var buf: [4096]u8 = undefined;
    while (reader.reader().readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
        const t = mem.trim(u8, line, " \r");
        if (mem.startsWith(u8, t, "[")) {
            in_entry = mem.eql(u8, t, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        if (icon_val == null and mem.startsWith(u8, t, "Icon=") and t.len > 5)
            icon_val = try allocator.dupe(u8, t[5..]);
        if (wm_class) |name| {
            if (mem.startsWith(u8, t, "StartupWMClass=") and std.ascii.eqlIgnoreCase(t[15..], name)) matches = true;
        }
    }
    if (matches) return icon_val;
    if (icon_val) |v| allocator.free(v);
    return null;
}

fn appDirPath(allocator: mem.Allocator, appdir: []const u8, path: []const u8) ![]const u8 {
    const root = mem.trimRight(u8, appdir, "/");
    if (fs.path.isAbsolute(path) and mem.startsWith(u8, path, root) and
        (path.len == root.len or path[root.len] == '/')) return allocator.dupe(u8, path);
    return fs.path.join(allocator, &.{ appdir, mem.trimLeft(u8, path, "/") });
}

fn loadAppDirIconValue(allocator: mem.Allocator, appdir: []const u8, icon_id: []const u8) !?IconResult {
    const candidate = try appDirPath(allocator, appdir, icon_id);
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

    // A bare Icon= name can live in the bundle's standard icon tree.
    if (!fs.path.isAbsolute(icon_id) and mem.indexOfScalar(u8, icon_id, '/') == null) {
        const filename = if (mem.endsWith(u8, icon_id, ".png"))
            try allocator.dupe(u8, icon_id)
        else
            try std.fmt.allocPrint(allocator, "{s}.png", .{icon_id});
        defer allocator.free(filename);
        for (ICON_SIZES) |size| {
            const path = try fs.path.join(allocator, &.{ appdir, "usr/share/icons/hicolor", size, "apps", filename });
            defer allocator.free(path);
            if (loadPng(path)) |icon| return icon else |_| {}
        }
        const path = try fs.path.join(allocator, &.{ appdir, "usr/share/pixmaps", filename });
        defer allocator.free(path);
        if (loadPng(path)) |icon| return icon else |_| {}
    }

    return null;
}

/// Returns an owned copy of the XDG data home directory path.
fn xdgDataHome(allocator: mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |v| return allocator.dupe(u8, v);
    const home = std.posix.getenv("HOME") orelse "";
    return fs.path.join(allocator, &.{ home, ".local/share" });
}

fn desktopFileMatchesAppName(filename: []const u8, app_name: []const u8) bool {
    const suffix = ".desktop";
    if (filename.len <= suffix.len) return false;
    if (!std.ascii.eqlIgnoreCase(filename[filename.len - suffix.len ..], suffix)) return false;

    const file_id = filename[0 .. filename.len - suffix.len];
    const app_id = if (app_name.len > suffix.len and
        std.ascii.eqlIgnoreCase(app_name[app_name.len - suffix.len ..], suffix))
        app_name[0 .. app_name.len - suffix.len]
    else
        app_name;
    return std.ascii.eqlIgnoreCase(file_id, app_id);
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

    // Pass 1: match desktop file IDs case-insensitively. WM_CLASS capitalization
    // does not have to match the package's lowercase desktop filename.
    for (search_dirs.items) |base| {
        if (!fs.path.isAbsolute(base)) continue;
        var dir = fs.openDirAbsolute(base, .{ .iterate = true }) catch continue;
        defer dir.close();
        var dir_iter = dir.iterate();
        while (dir_iter.next() catch null) |entry| {
            if (!desktopFileMatchesAppName(entry.name, app_name)) continue;
            if (try scanDesktopForIcon(allocator, dir, entry.name, null)) |icon| return icon;
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
            if (try scanDesktopForIcon(allocator, dir, entry.name, app_name)) |icon| {
                return icon;
            }
        }
    }

    return null;
}

fn pngIconFilename(allocator: mem.Allocator, icon_id: []const u8) ![]const u8 {
    const suffix = ".png";
    if (icon_id.len >= suffix.len and std.ascii.eqlIgnoreCase(icon_id[icon_id.len - suffix.len ..], suffix)) {
        return allocator.dupe(u8, icon_id);
    }
    return std.fmt.allocPrint(allocator, "{s}.png", .{icon_id});
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

    const icon_filename = try pngIconFilename(allocator, icon_id);
    defer allocator.free(icon_filename);

    // Strategy: Check requested size, then crawl UP for higher fidelity.
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

    // If only a smaller raster exists, use it rather than dropping the icon.
    var lower_idx = start_idx;
    while (lower_idx > 0) {
        lower_idx -= 1;
        const size_dir = ICON_SIZES[lower_idx];
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

test "desktop filename matching is case-insensitive" {
    try std.testing.expect(desktopFileMatchesAppName("mailclient.desktop", "MailClient"));
    try std.testing.expect(desktopFileMatchesAppName("MailClient.desktop", "mailclient.desktop"));
    try std.testing.expect(!desktopFileMatchesAppName("other.desktop", "MailClient"));
    try std.testing.expect(!desktopFileMatchesAppName("mailclient.txt", "MailClient"));
}

test "PNG icon filename preserves an existing extension" {
    const allocator = std.testing.allocator;
    const plain = try pngIconFilename(allocator, "mailclient");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("mailclient.png", plain);

    const existing = try pngIconFilename(allocator, "mailclient.PNG");
    defer allocator.free(existing);
    try std.testing.expectEqualStrings("mailclient.PNG", existing);
}

test "hicolor sizes include large application icons" {
    try std.testing.expectEqualStrings("1024x1024", ICON_SIZES[ICON_SIZES.len - 1]);
}

test "APPDIR parsing rejects unrelated variables and relative paths" {
    try std.testing.expectEqualStrings("/bundle", appDirFromEnvironment("OTHER=value\x00APPDIR=/bundle\x00TAIL=value\x00").?);
    try std.testing.expect(appDirFromEnvironment("APPDIR=relative\x00") == null);
    try std.testing.expect(appDirFromEnvironment("APPDIR=\x00") == null);
    try std.testing.expect(appDirFromEnvironment("OTHER_APPDIR=/bundle\x00") == null);
}

test "AppDir absolute paths require a directory boundary" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "/bundle/icon.png", "/bundle/icon.png" },
        .{ "/bundle-other/icon.png", "/bundle/bundle-other/icon.png" },
        .{ "/usr/share/icon.png", "/bundle/usr/share/icon.png" },
        .{ "icon.png", "/bundle/icon.png" },
    };
    for (cases) |case| {
        const actual = try appDirPath(allocator, "/bundle", case[0]);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case[1], actual);
    }
}

test "desktop lookup uses application class and ignores desktop actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "terminal.desktop", .data = "[Desktop Action Other]\nIcon=wrong\nStartupWMClass=wrong\n" ++
        "[Desktop Entry]\nIcon=terminal\nStartupWMClass=TerminalApp\n" ++
        "[Desktop Action New]\nIcon=also-wrong\n" });
    const allocator = std.testing.allocator;
    const icon = (try scanDesktopForIcon(allocator, tmp.dir, "terminal.desktop", "terminalapp")).?;
    defer allocator.free(icon);
    try std.testing.expectEqualStrings("terminal", icon);
    try std.testing.expect((try scanDesktopForIcon(allocator, tmp.dir, "terminal.desktop", "wrong")) == null);
}

// One opaque red pixel, decoded through the same STB path as application icons.
const test_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0dIDAT\x08\xd7\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d\x00\x00\x00\x00IEND\xaeB\x60\x82";

test "AppDir icon works without desktop metadata or matching WM_CLASS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = ".DirIcon", .data = test_png });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    var icon = (try loadAppDirIcon(std.testing.allocator, path)).?;
    defer icon.deinit();
    try std.testing.expectEqual(@as(i32, 1), icon.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, icon.pixels);
}

test "AppDir resolves root-relative DirIcon symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("usr/share/pixmaps");
    try tmp.dir.writeFile(.{ .sub_path = "usr/share/pixmaps/fasttab-test-icon.png", .data = test_png });
    try tmp.dir.symLink("/usr/share/pixmaps/fasttab-test-icon.png", ".DirIcon", .{});
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    var icon = (try loadAppDirIcon(std.testing.allocator, path)).?;
    defer icon.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, icon.pixels);
}

test "AppDir resolves nested desktop and themed PNG with extension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("usr/share/applications");
    try tmp.dir.makePath("usr/share/icons/hicolor/32x32/apps");
    try tmp.dir.writeFile(.{ .sub_path = "usr/share/applications/unrelated.desktop", .data = "[Desktop Entry]\nIcon=embedded.png\n" });
    try tmp.dir.writeFile(.{ .sub_path = "usr/share/icons/hicolor/32x32/apps/embedded.png", .data = test_png });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    var icon = (try loadAppDirIcon(std.testing.allocator, path)).?;
    defer icon.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, icon.pixels);
}

test "AppImage fallback reads only the supplied process APPDIR" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = ".DirIcon", .data = test_png });
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    var environment = std.process.EnvMap.init(allocator);
    defer environment.deinit();
    try environment.put("APPDIR", path);
    var child = std.process.Child.init(&.{ "/bin/sleep", "30" }, allocator);
    child.env_map = &environment;
    try child.spawn();
    defer _ = child.kill() catch {};
    try child.waitForSpawn();
    var icon = (try getProcessAppImageIcon(allocator, child.id)).?;
    defer icon.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, icon.pixels);
    try std.testing.expect((try getProcessAppImageIcon(allocator, 0)) == null);
}
