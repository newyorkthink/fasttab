const std = @import("std");
const x11 = @import("x11.zig");
const worker = @import("worker.zig");
const app = @import("app.zig");

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const log = std.log.scoped(.fasttab);
const MRU_CAP: usize = 128;
const SHOW_DELAY_FRAMES: u8 = 1;

pub fn main() !void {
    installFastSignalExit();
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip program name

    var replace = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
        } else if (std.mem.eql(u8, arg, "daemon") or std.mem.eql(u8, arg, "--daemon")) {} else {
            std.debug.print("Unknown command: {s}\n", .{arg});
            std.debug.print("Usage: fasttab [daemon] [--replace]\n", .{});
            std.process.exit(1);
        }
    }

    if (replace) {
        try killExistingInstance();
        // Give it a moment to die and release X11 grabs
        std.time.sleep(200 * std.time.ns_per_ms);
    }

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

fn killExistingInstance() !void {
    const my_pid = std.c.getpid();
    var dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        if (pid == my_pid) continue;

        var buf: [256]u8 = undefined;
        const comm_path = try std.fmt.bufPrint(&buf, "/proc/{d}/comm", .{pid});
        const file = std.fs.openFileAbsolute(comm_path, .{}) catch continue;
        defer file.close();

        const bytes_read = try file.readAll(&buf);
        const comm = std.mem.trimRight(u8, buf[0..bytes_read], "\n");

        if (std.mem.eql(u8, comm, "fasttab")) {
            std.debug.print("Killing existing instance (PID {d})...\n", .{pid});
            std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
                std.debug.print("Failed to kill PID {d}: {}\n", .{ pid, err });
            };
        }
    }
}

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
    var workspace_switching = false;

    while (application.isRunning()) {
        // Poll for XCB events (16ms timeout ~= 60fps)
        _ = std.posix.poll(&pollfds, 16) catch {};

        // Always drain XCB events
        processXcbEvents(&application, &conn, &workspace_switching);

        if (application.state == .idle) {
            workspace_switching = false;
        }

        // filtered_items contains shallow copies while Win+Tab is active. Delay
        // worker updates until switching ends so app.zig does not rebuild the list
        // using the retired same-application filter.
        if (!workspace_switching) {
            application.drainUpdateQueue();
        }
        application.update();
    }

    task_queue.requestStop();
    worker_thread.join();
    task_queue.deinit();

    log.debug("Daemon stopped", .{});
}

/// Process all pending XCB events (key press/release, damage)
fn processXcbEvents(application: *app.App, conn: *x11.Connection, workspace_switching: *bool) void {
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
                const is_super = (state_mask & x11.MOD_SUPER) != 0;
                const is_alt = (state_mask & x11.MOD_ALT) != 0;

                // Some X layouts report Shift+Tab as ISO_Left_Tab, others keep the
                // same Tab keycode and only set the Shift modifier. Treat both as Tab.
                const is_tab_key = base_keysym == x11.XK_Tab or
                    base_keysym == x11.XK_ISO_Left_Tab or
                    shifted_keysym == x11.XK_Tab or
                    shifted_keysym == x11.XK_ISO_Left_Tab;

                if (is_tab_key and is_super and !is_alt) {
                    // Super+Tab (no Alt): switch only between windows on the current workspace.
                    workspace_switching.* = handleWorkspaceTab(
                        application,
                        conn,
                        is_shift or base_keysym == x11.XK_ISO_Left_Tab,
                    );
                } else if (application.state == .idle) {
                    // Idle: respond to Alt+Tab / Alt+Shift+Tab. Passive grabs guarantee Alt.
                    if (is_tab_key) {
                        application.handleAltTab(is_shift or base_keysym == x11.XK_ISO_Left_Tab);
                    }
                } else {
                    // Switching: normalize Tab keycodes so Alt+Shift+Tab always means previous.
                    var effective_keysym = base_keysym;
                    if (is_tab_key) {
                        effective_keysym = if (is_shift or base_keysym == x11.XK_ISO_Left_Tab)
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

        if (application.state == .idle) {
            workspace_switching.* = false;
        }
    }
}

/// Start or continue Win+Tab switching for the current workspace.
/// app.zig's filtered mode is reused so rendering and navigation keep using
/// filtered_items without duplicating the switcher state machine.
fn handleWorkspaceTab(application: *app.App, conn: *x11.Connection, shift: bool) bool {
    if (application.state == .switching) {
        if (shift) {
            application.tab_pressed_during_shift = true;
            application.selectPrev();
        } else {
            application.selectNext();
        }
        return application.switch_mode == .same_app;
    }

    application.mouse_left_was_down = false;

    if (!x11.grabKeyboard(conn.conn, conn.root)) {
        log.err("Could not grab keyboard, aborting Win+Tab", .{});
        return false;
    }

    const active_win = x11.getActiveWindow(conn.conn, conn.root, conn.atoms);
    if (active_win == 0) {
        log.debug("Win+Tab: no active window, aborting", .{});
        x11.ungrabKeyboard(conn.conn);
        return false;
    }

    recordMruActivation(application, active_win);
    reorderItemsByMru(application);

    const current_workspace = getCurrentWorkspace(application, conn, active_win) orelse {
        log.debug("Win+Tab: current workspace unavailable, aborting", .{});
        x11.ungrabKeyboard(conn.conn);
        return false;
    };
    application.current_workspace = current_workspace;

    for (application.items.items) |*item| {
        item.workspace = x11.getWindowDesktop(conn.conn, item.id, conn.atoms);
    }

    application.filtered_items.clearRetainingCapacity();
    for (application.items.items) |item| {
        if (windowBelongsToWorkspace(item.workspace, current_workspace)) {
            application.filtered_items.append(item) catch {};
        }
    }

    if (application.filtered_items.items.len <= 1) {
        log.debug("Win+Tab: current workspace has {d} switchable window(s)", .{application.filtered_items.items.len});
        x11.ungrabKeyboard(conn.conn);
        resetFilteredMode(application);
        return false;
    }

    if (application.active_app_class) |class| {
        application.allocator.free(class);
        application.active_app_class = null;
    }
    application.switch_mode = .same_app;

    const n = application.filtered_items.items.len;
    if (findFilteredItemIndex(application, active_win)) |current_idx| {
        application.selected_index = if (shift)
            (if (current_idx == 0) n - 1 else current_idx - 1)
        else
            current_idx;
    } else if (shift) {
        application.selected_index = n - 1;
    } else {
        application.selected_index = 0;
    }

    application.show_delay_frames = SHOW_DELAY_FRAMES;
    application.state = .switching;
    log.debug("Win+Tab current-workspace switching started (workspace={d}, count={d}, shift={}, selected={d})", .{
        current_workspace,
        n,
        shift,
        application.selected_index,
    });
    return true;
}

fn getCurrentWorkspace(
    application: *app.App,
    conn: *x11.Connection,
    active_win: x11.xcb.xcb_window_t,
) ?u32 {
    var info = x11.getWorkspaceInfo(application.allocator, conn.conn, conn.root, conn.atoms);
    defer info.deinit();

    if (info.current) |current| {
        return current;
    }

    const active_workspace = x11.getWindowDesktop(conn.conn, active_win, conn.atoms) orelse return null;
    if (active_workspace == 0xFFFFFFFF) return null;
    return active_workspace;
}

fn windowBelongsToWorkspace(workspace: ?u32, current_workspace: u32) bool {
    const value = workspace orelse return true;
    return value == current_workspace or value == 0xFFFFFFFF;
}

fn findFilteredItemIndex(application: *app.App, window_id: x11.xcb.xcb_window_t) ?usize {
    for (application.filtered_items.items, 0..) |item, index| {
        if (item.id == window_id) return index;
    }
    return null;
}

fn resetFilteredMode(application: *app.App) void {
    application.switch_mode = .all_windows;
    application.filtered_items.clearRetainingCapacity();
    if (application.active_app_class) |class| {
        application.allocator.free(class);
        application.active_app_class = null;
    }
}

fn recordMruActivation(application: *app.App, window_id: x11.xcb.xcb_window_t) void {
    if (window_id == 0) return;

    for (application.mru_list.items, 0..) |entry, index| {
        if (entry == window_id) {
            _ = application.mru_list.orderedRemove(index);
            break;
        }
    }

    application.mru_list.insert(0, window_id) catch return;
    if (application.mru_list.items.len > MRU_CAP) {
        application.mru_list.items.len = MRU_CAP;
    }
}

fn reorderItemsByMru(application: *app.App) void {
    if (application.items.items.len == 0) return;

    var ordered = std.ArrayList(app.DisplayWindow).init(application.allocator);
    defer ordered.deinit();
    ordered.ensureTotalCapacity(application.items.items.len) catch return;

    for (application.mru_list.items) |mru_id| {
        for (application.items.items) |item| {
            if (item.id == mru_id) {
                ordered.appendAssumeCapacity(item);
                break;
            }
        }
    }

    for (application.items.items) |item| {
        var found = false;
        for (ordered.items) |ordered_item| {
            if (ordered_item.id == item.id) {
                found = true;
                break;
            }
        }
        if (!found) {
            ordered.appendAssumeCapacity(item);
        }
    }

    application.items.clearRetainingCapacity();
    for (ordered.items) |item| {
        application.items.appendAssumeCapacity(item);
    }
}

test "current workspace filter includes matching windows" {
    try std.testing.expect(windowBelongsToWorkspace(2, 2));
    try std.testing.expect(!windowBelongsToWorkspace(1, 2));
}

test "current workspace filter includes sticky and unknown windows" {
    try std.testing.expect(windowBelongsToWorkspace(0xFFFFFFFF, 2));
    try std.testing.expect(windowBelongsToWorkspace(null, 2));
}
