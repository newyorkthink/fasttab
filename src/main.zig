const std = @import("std");
const x11 = @import("x11.zig");
const worker = @import("worker.zig");
const app = @import("app.zig");

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/file.h");
    @cInclude("unistd.h");
});

const log = std.log.scoped(.fasttab);
const SHOW_DELAY_FRAMES: u8 = 1;
const FASTTAB_VERSION = "1.0.8";

const IdleTabRoute = enum {
    all_windows,
    current_workspace,
};

/// Idle Tab events can only arrive through FastTab's passive Alt+Tab or Win+Tab grabs.
/// Some X11 setups deliver the Win+Tab event without MOD4 in the event state, so Alt is
/// the reliable discriminator: Alt means global switching; every other grabbed Tab means
/// current-workspace switching.
fn routeIdleTab(state_mask: u16) IdleTabRoute {
    return if ((state_mask & x11.MOD_ALT) != 0) .all_windows else .current_workspace;
}

fn shouldStartSingleWindowFallback(window_count: usize) bool {
    return window_count == 1;
}

fn printHelp() void {
    std.debug.print(
        "FastTab {s}\n" ++
            "Fast GPU-accelerated X11 window switcher.\n\n" ++
            "Usage:\n" ++
            "  fasttab [COMMAND] [OPTIONS]\n\n" ++
            "Commands:\n" ++
            "  daemon              Run the FastTab daemon (default)\n" ++
            "  help                Show this help and exit\n" ++
            "  version             Show version information and exit\n\n" ++
            "Options:\n" ++
            "  --daemon            Run the FastTab daemon\n" ++
            "  -h, --help          Show this help and exit\n" ++
            "  -v, -V, --version   Show version information and exit\n",
        .{FASTTAB_VERSION},
    );
}

fn printVersion() void {
    std.debug.print("FastTab {s}\n", .{FASTTAB_VERSION});
}

pub fn main() !void {
    installFastSignalExit();
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "daemon") or std.mem.eql(u8, arg, "--daemon")) continue;

        if (std.mem.eql(u8, arg, "help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            printHelp();
            return;
        }

        if (std.mem.eql(u8, arg, "version") or
            std.mem.eql(u8, arg, "-v") or
            std.mem.eql(u8, arg, "-V") or
            std.mem.eql(u8, arg, "--version"))
        {
            printVersion();
            return;
        }

        std.debug.print("Error: unknown argument: {s}\n", .{arg});
        std.debug.print("Try 'fasttab --help' for more information.\n", .{});
        std.process.exit(2);
    }

    var instance_lock = (try InstanceLock.acquire()) orelse {
        std.debug.print("Error: an instance of FastTab is already running.\n", .{});
        std.process.exit(1);
    };
    defer instance_lock.deinit();

    return runDaemon();
}

fn fastExitFromSignal(sig: c_int) callconv(.C) void {
    const code: c_int = if (sig == c.SIGINT) 130 else 143;
    c._exit(code);
}

fn installFastSignalExit() void {
    _ = c.signal(c.SIGINT, fastExitFromSignal);
    _ = c.signal(c.SIGTERM, fastExitFromSignal);
}

const InstanceLock = struct {
    file: std.fs.File,

    fn acquire() !?InstanceLock {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/fasttab-{d}.lock", .{c.getuid()});
        const file = try std.fs.createFileAbsolute(path, .{
            .read = true,
            .truncate = false,
            .mode = 0o600,
        });
        errdefer file.close();

        if (c.flock(file.handle, c.LOCK_EX | c.LOCK_NB) != 0) {
            file.close();
            return null;
        }

        try file.setEndPos(0);
        try file.seekTo(0);
        var pid_buf: [32]u8 = undefined;
        const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.c.getpid()});
        try file.writeAll(pid_text);

        return .{ .file = file };
    }

    fn deinit(self: *InstanceLock) void {
        _ = c.flock(self.file.handle, c.LOCK_UN);
        self.file.close();
    }
};

/// Run the daemon with XCB key grabbing
fn runDaemon() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conn = try x11.Connection.init();
    defer conn.deinit();

    // Register for PropertyNotify events on root window
    const event_mask = [_]u32{x11.xcb.XCB_EVENT_MASK_PROPERTY_CHANGE};
    _ = x11.xcb.xcb_change_window_attributes(conn.conn, conn.root, x11.xcb.XCB_CW_EVENT_MASK, &event_mask);
    conn.flush();

    // Grab Alt+Tab passively
    x11.grabAltTab(conn.conn, conn.root);
    defer x11.ungrabAltTab(conn.conn, conn.root);

    // Grab Win+Tab passively
    x11.grabWinTab(conn.conn, conn.root);
    defer x11.ungrabWinTab(conn.conn, conn.root);

    var task_queue = worker.TaskQueue.init(allocator);

    const worker_thread = std.Thread.spawn(.{}, worker.backgroundWorker, .{ &task_queue, allocator }) catch |err| {
        log.err("Failed to spawn background worker: {}", .{err});
        return err;
    };

    if (!task_queue.waitForFirstScan(10000)) {
        log.err("Timeout waiting for worker scan", .{});
        task_queue.requestStop();
        worker_thread.join();
        task_queue.deinit();
        return;
    }

    // Initialize app in daemon mode (window created but hidden)
    // App init drains the queue for initial windows
    var application = try app.App.init(allocator, &task_queue, true, &conn);
    defer application.deinit();
    application.hideWindow();

    log.debug("Daemon ready: {d} windows tracked", .{application.windowCount()});

    // Main loop: poll on XCB file descriptor
    const xcb_fd = x11.getXcbFd(conn.conn);
    var pollfds = [_]std.posix.pollfd{
        .{ .fd = xcb_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (application.isRunning()) {
        // Poll for XCB events (16ms timeout ~= 60fps)
        _ = std.posix.poll(&pollfds, 16) catch {};

        // Always drain XCB events
        processXcbEvents(&application, &conn);

        application.drainUpdateQueue();
        application.update();
    }

    task_queue.requestStop();
    worker_thread.join();
    task_queue.deinit();

    log.debug("Daemon stopped", .{});
}

/// Process all pending XCB events (key press/release, damage)
fn processXcbEvents(application: *app.App, conn: *x11.Connection) void {
    while (true) {
        const event = x11.xcb.xcb_poll_for_event(conn.conn);
        if (event == null) break;
        defer std.c.free(event);

        const response_type = event.*.response_type & 0x7f;

        switch (response_type) {
            x11.xcb.XCB_KEY_PRESS => {
                const key_event: *x11.xcb.xcb_key_press_event_t = @ptrCast(event);
                const base_keysym = x11.keycodeToKeysym(conn, key_event.detail, 0);
                const shifted_keysym = x11.keycodeToKeysym(conn, key_event.detail, 1);
                const state_mask = key_event.state;

                const is_shift = (state_mask & x11.MOD_SHIFT) != 0;

                // Some X layouts report Shift+Tab as ISO_Left_Tab, others keep the
                // same Tab keycode and only set the Shift modifier. Treat both as Tab.
                const is_tab_key = base_keysym == x11.XK_Tab or
                    base_keysym == x11.XK_ISO_Left_Tab or
                    shifted_keysym == x11.XK_Tab or
                    shifted_keysym == x11.XK_ISO_Left_Tab;
                const reverse = is_shift or base_keysym == x11.XK_ISO_Left_Tab;

                if (application.state == .idle) {
                    if (is_tab_key) {
                        switch (routeIdleTab(state_mask)) {
                            .all_windows => application.handleAltTab(reverse),
                            .current_workspace => handleWinTabIncludingSingle(application, conn, reverse),
                        }
                    }
                } else {
                    // Switching: normalize Tab keycodes so Shift+Tab always means previous.
                    var effective_keysym = base_keysym;
                    if (is_tab_key) {
                        effective_keysym = if (reverse)
                            x11.XK_ISO_Left_Tab
                        else
                            x11.XK_Tab;
                    }
                    _ = application.handleKeyEvent(effective_keysym, true);
                }
            },
            x11.xcb.XCB_KEY_RELEASE => {
                const key_event: *x11.xcb.xcb_key_release_event_t = @ptrCast(event);
                const keysym = x11.keycodeToKeysym(conn, key_event.detail, 0);

                _ = application.handleKeyEvent(keysym, false);
            },
            x11.xcb.XCB_PROPERTY_NOTIFY => {
                const prop_event: *x11.xcb.xcb_property_notify_event_t = @ptrCast(event);
                if (prop_event.atom == conn.atoms.net_active_window and prop_event.window == conn.root) {
                    application.handleActiveWindowChanged();
                }
            },
            else => {
                // Check for damage events
                if (response_type == conn.damage_event_base + x11.xcb.XCB_DAMAGE_NOTIFY) {
                    const damage_event: *x11.xcb.xcb_damage_notify_event_t = @ptrCast(event);
                    application.handleDamageEvent(damage_event.drawable);
                }
            },
        }
    }
}

/// app.handleWinTab intentionally returns without showing when the filtered list has one item.
/// Preserve its normal multi-window behavior, then start the same current-workspace mode for the
/// single-window case so Win+Tab remains visually consistent on every non-empty workspace.
fn handleWinTabIncludingSingle(application: *app.App, conn: *x11.Connection, shift: bool) void {
    application.handleWinTab(shift);
    if (application.state != .idle) return;

    const active_win = x11.getActiveWindow(conn.conn, conn.root, conn.atoms);
    if (active_win == 0) return;

    var workspace_info = x11.getWorkspaceInfo(application.allocator, conn.conn, conn.root, conn.atoms);
    defer workspace_info.deinit();

    const current_workspace = workspace_info.current orelse blk: {
        const active_workspace = x11.getWindowDesktop(conn.conn, active_win, conn.atoms) orelse return;
        if (active_workspace == 0xFFFFFFFF) return;
        break :blk active_workspace;
    };

    application.current_workspace = current_workspace;
    for (application.items.items) |*item| {
        item.workspace = x11.getWindowDesktop(conn.conn, item.id, conn.atoms);
    }

    application.filtered_items.clearRetainingCapacity();
    app.filterItemsByWorkspace(application.items.items, current_workspace, &application.filtered_items);
    if (!shouldStartSingleWindowFallback(application.filtered_items.items.len)) {
        application.filtered_items.clearRetainingCapacity();
        return;
    }

    application.mouse_left_was_down = false;
    if (!x11.grabKeyboard(conn.conn, conn.root)) {
        application.filtered_items.clearRetainingCapacity();
        return;
    }

    application.switch_mode = .current_workspace;
    application.selected_index = 0;
    application.show_delay_frames = SHOW_DELAY_FRAMES;
    application.state = .switching;
    log.debug("Win+Tab single-window current-workspace switching started (workspace={d})", .{current_workspace});
}

test "idle Alt+Tab routes to all windows" {
    try std.testing.expectEqual(IdleTabRoute.all_windows, routeIdleTab(x11.MOD_ALT));
    try std.testing.expectEqual(IdleTabRoute.all_windows, routeIdleTab(x11.MOD_ALT | x11.MOD_SHIFT));
}

test "idle grabbed Tab without Alt routes to current workspace" {
    try std.testing.expectEqual(IdleTabRoute.current_workspace, routeIdleTab(x11.MOD_SUPER));
    try std.testing.expectEqual(IdleTabRoute.current_workspace, routeIdleTab(x11.MOD_SUPER | x11.MOD_SHIFT));
    // Regression: some X11 setups omit MOD4 from the delivered Win+Tab state.
    try std.testing.expectEqual(IdleTabRoute.current_workspace, routeIdleTab(0));
}

test "Alt remains authoritative when extra modifier bits are present" {
    try std.testing.expectEqual(IdleTabRoute.all_windows, routeIdleTab(x11.MOD_ALT | x11.MOD_SUPER));
}

test "single current-workspace window starts the visual fallback" {
    try std.testing.expect(!shouldStartSingleWindowFallback(0));
    try std.testing.expect(shouldStartSingleWindowFallback(1));
    try std.testing.expect(!shouldStartSingleWindowFallback(2));
}
