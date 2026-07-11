const std = @import("std");
const x11 = @import("x11.zig");
const ui = @import("ui.zig");
const worker = @import("worker.zig");
const thumbnail = @import("thumbnail.zig");
const nav = @import("navigation.zig");

const rl = ui.rl;
const log = std.log.scoped(.fasttab);

const PROFILE_SLOW_SHOW_WINDOW_US: i128 = 5_000;
const PROFILE_SLOW_HIDE_WINDOW_US: i128 = 5_000;
const PROFILE_SLOW_REACQUIRE_WINDOW_US: i128 = 4_000;
const PROFILE_SLOW_REACQUIRE_FRAME_US: i128 = 8_000;

/// State machine for the Alt+Tab switcher

/// State machine for the Alt+Tab switcher
pub const SwitcherState = enum {
    idle,
    switching,
};

/// Which set of windows to display
pub const SwitchMode = enum {
    all_windows, // Alt+Tab: show every tracked window
    current_workspace, // Win+Tab: show windows on the active workspace
};

// Re-exported so test files can construct DisplayWindow values without importing ui directly.
pub const DisplayWindow = ui.DisplayWindow;

/// Monitor information for window positioning
pub const MonitorInfo = struct {
    index: i32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Application state encapsulating all raylib window and UI management
pub const App = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ui.DisplayWindow),
    selected_index: usize,
    mouseover_index: ?usize,
    mouse_left_was_down: bool,
    current_layout: ui.GridLayout,
    font: rl.Font,
    monitor: MonitorInfo,
    window_hidden: bool,
    daemon_mode: bool,
    should_quit: bool,
    update_queue: ?*worker.TaskQueue,
    temp_tasks: std.ArrayList(worker.UpdateTask),
    conn: *x11.Connection,
    state: SwitcherState,
    icon_texture_cache: std.StringHashMap(rl.Texture2D),
    window_textures: std.AutoHashMap(x11.xcb.xcb_window_t, x11.WindowTexture),
    focus_grace_frames: u8,
    downsample_shader: ?ui.DownsampleShader,
    show_delay_frames: ?u8,
    reacquire_pending: bool,
    reacquire_cursor: usize,
    switch_origin_window: x11.xcb.xcb_window_t,
    switch_origin_snapshot_ready: bool,
    mru_list: std.ArrayList(x11.xcb.xcb_window_t),
    workspace_names: std.ArrayList([]u8),
    current_workspace: ?u32,

    // Shift-tap tracking: press-and-release Shift (without Tab) selects previous window
    shift_held: bool,
    tab_pressed_during_shift: bool,

    // Win+Tab current-workspace filtering
    switch_mode: SwitchMode,
    filtered_items: std.ArrayList(ui.DisplayWindow), // non-owning shallow copies; strings owned by items

    const MRU_CAP: usize = 128;

    const Self = @This();

    /// Initialize the application with items from the worker
    pub fn init(
        allocator: std.mem.Allocator,
        task_queue: *worker.TaskQueue,
        daemon_mode: bool,
        conn: *x11.Connection,
    ) !Self {
        const items = std.ArrayList(ui.DisplayWindow).init(allocator);
        const icon_texture_cache = std.StringHashMap(rl.Texture2D).init(allocator);
        const window_textures = std.AutoHashMap(x11.xcb.xcb_window_t, x11.WindowTexture).init(allocator);
        const temp_tasks = std.ArrayList(worker.UpdateTask).init(allocator);

        // Create raylib window (hidden initially via FLAG_WINDOW_HIDDEN)
        rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST | rl.FLAG_WINDOW_HIDDEN);
        rl.SetTraceLogLevel(rl.LOG_ERROR);
        rl.InitWindow(800, 600, "FastTab");
        rl.SetTargetFPS(60);
        const font = ui.loadSystemFont(ui.TITLE_FONT_SIZE);
        const downsample_shader = ui.DownsampleShader.load();

        const layout = ui.GridLayout{
            .columns = 0,
            .rows = 0,
            .item_height = ui.THUMBNAIL_HEIGHT,
            .total_width = ui.PADDING * 2,
            .total_height = ui.PADDING * 2,
        };

        // Default monitor (updated on show)
        const monitor = MonitorInfo{
            .index = 0,
            .x = 0,
            .y = 0,
            .width = 1920,
            .height = 1080,
        };

        var mru_list = std.ArrayList(x11.xcb.xcb_window_t).init(allocator);
        const workspace_names = std.ArrayList([]u8).init(allocator);

        // Seed MRU list with the currently active window (single entry)
        const initial_active = x11.getActiveWindow(conn.conn, conn.root, conn.atoms);
        if (initial_active != 0) {
            mru_list.append(initial_active) catch {};
        }

        var self = Self{
            .allocator = allocator,
            .items = items,
            .selected_index = 0,
            .mouseover_index = null,
            .mouse_left_was_down = false,
            .current_layout = layout,
            .font = font,
            .monitor = monitor,
            .window_hidden = true,
            .daemon_mode = daemon_mode,
            .should_quit = false,
            .update_queue = task_queue,
            .temp_tasks = temp_tasks,
            .conn = conn,
            .state = .idle,
            .icon_texture_cache = icon_texture_cache,
            .window_textures = window_textures,
            .focus_grace_frames = 0,
            .downsample_shader = downsample_shader,
            .show_delay_frames = null,
            .reacquire_pending = false,
            .reacquire_cursor = 0,
            .switch_origin_window = 0,
            .switch_origin_snapshot_ready = false,
            .mru_list = mru_list,
            .workspace_names = workspace_names,
            .current_workspace = null,
            .shift_held = false,
            .tab_pressed_during_shift = false,
            .switch_mode = .all_windows,
            .filtered_items = std.ArrayList(ui.DisplayWindow).init(allocator),
        };

        self.drainUpdateQueue();

        log.debug("App initialized: {d} windows tracked", .{self.items.items.len});

        return self;
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        // filtered_items are shallow copies; deinit the ArrayList only (do NOT free strings)
        self.filtered_items.deinit();

        // Free owned fields from items (textures are cleaned up via window_textures)
        for (self.items.items) |*item| {
            // Don't unload thumbnail_texture here - it's owned by window_textures
            // Don't unload icon_texture here - it's shared via icon_texture_cache
            if (item.cached_snapshot) |snapshot| {
                rl.UnloadRenderTexture(snapshot);
            }
            self.allocator.free(item.title);
            self.allocator.free(item.icon_id);
        }
        self.items.deinit();

        // Clean up window textures
        var tex_iter = self.window_textures.valueIterator();
        while (tex_iter.next()) |tex| {
            var t = tex.*;
            t.deinit(self.conn);
        }
        self.window_textures.deinit();

        // Unload icon textures from cache
        var icon_iter = self.icon_texture_cache.iterator();
        while (icon_iter.next()) |entry| {
            rl.UnloadTexture(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.icon_texture_cache.deinit();

        // Clean up temp tasks
        for (self.temp_tasks.items) |*task| {
            task.deinit();
        }
        self.temp_tasks.deinit();

        self.clearWorkspaceInfo();
        self.workspace_names.deinit();

        self.mru_list.deinit();

        // Unload downsample shader
        if (self.downsample_shader) |*shader| {
            shader.unload();
        }

        rl.UnloadFont(self.font);
        rl.CloseWindow();
    }

    /// Check if the app should continue running
    pub fn isRunning(self: *const Self) bool {
        return !self.should_quit;
    }

    /// Get the number of windows
    pub fn windowCount(self: *const Self) usize {
        return self.items.items.len;
    }

    /// Process one frame: check for window close, render
    pub fn update(self: *Self) void {
        if (self.window_hidden) {
            // Check if the deferred show countdown has elapsed
            if (self.show_delay_frames) |*remaining| {
                if (remaining.* == 0) {
                    self.show_delay_frames = null;
                    self.showWindow();
                    // Fall through to render the first frame immediately
                } else {
                    remaining.* -= 1;
                    std.time.sleep(16 * std.time.ns_per_ms);
                    return;
                }
            } else {
                std.time.sleep(16 * std.time.ns_per_ms);
                return;
            }
        }

        // Check if window should close
        if (rl.WindowShouldClose()) {
            if (self.daemon_mode) {
                self.cancelSwitching();
            } else {
                self.should_quit = true;
                return;
            }
        }

        // Handle mouse input with X11 global pointer state.
        // Raylib mouse press/release can be unreliable while Alt is held and the keyboard is grabbed.
        const mouse_state = x11.getMouseState(self.conn.conn, self.conn.root);
        defer self.mouse_left_was_down = mouse_state.left_down;

        const switcher_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const switcher_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        const mouse_pos = rl.Vector2{
            .x = @floatFromInt(mouse_state.x - switcher_x),
            .y = @floatFromInt(mouse_state.y - switcher_y),
        };
        const mouse_pressed = mouse_state.left_down and !self.mouse_left_was_down;
        const mouse_released = !mouse_state.left_down and self.mouse_left_was_down;

        if (ui.getItemAtPosition(self.displayItems(), self.current_layout, mouse_pos, ui.workspaceBarOffset(self.workspace_names.items))) |idx| {
            rl.SetMouseCursor(rl.MOUSE_CURSOR_POINTING_HAND);
            self.mouseover_index = idx;
            if (mouse_pressed or mouse_released) {
                self.selected_index = idx;
                self.confirmSwitching();
                return;
            }
        } else {
            rl.SetMouseCursor(rl.MOUSE_CURSOR_DEFAULT);
            self.mouseover_index = null;
        }

        // Cancel switching if window loses focus.
        // Do not cancel while the user is holding the mouse button; otherwise i3 can drop the click.
        if (self.focus_grace_frames > 0) {
            self.focus_grace_frames -= 1;
        } else if (self.state == .switching and !mouse_state.left_down and !rl.IsWindowFocused()) {
            self.cancelSwitching();
            return;
        }

        self.processReacquireQueue();

        // Render
        self.render();
    }

    pub fn drainUpdateQueue(self: *Self) void {
        const queue = self.update_queue orelse return;

        _ = queue.drainAll(&self.temp_tasks);
        if (self.temp_tasks.items.len == 0) return;

        var any_changes = false;

        for (self.temp_tasks.items) |*task| {
            any_changes = true;
            switch (task.*) {
                .window_added => |*data| {
                    var texture: rl.Texture2D = std.mem.zeroes(rl.Texture2D);
                    var source_width: u32 = 0;
                    var source_height: u32 = 0;
                    var has_texture = false;

                    // Attempt to create GLX texture (may fail for minimized windows, etc.)
                    if (!data.is_minimized) {
                        if (x11.createWindowTexture(self.conn, data.window_id)) |win_tex| {
                            texture = win_tex.toRaylibTexture();
                            source_width = win_tex.width;
                            source_height = win_tex.height;

                            self.window_textures.put(data.window_id, win_tex) catch {
                                var t = win_tex;
                                t.deinit(self.conn);
                                // Fall through — window still gets added without a texture
                            };

                            if (self.window_textures.contains(data.window_id)) {
                                has_texture = true;
                            }
                        } else |err| {
                            log.debug("GLX texture failed for {x}: {}, showing icon fallback", .{ data.window_id, err });
                        }
                    } else {
                        log.debug("Minimized window {x}, showing icon fallback", .{data.window_id});
                    }

                    // Look up icon
                    var icon_tex: ?rl.Texture2D = null;
                    if (self.icon_texture_cache.get(data.icon_id)) |tex| {
                        icon_tex = tex;
                    }

                    // Create display window (taking ownership of title and icon_id)
                    // Windows without a texture will render with the icon fallback (Tier 3)
                    const new_item = ui.DisplayWindow{
                        .id = data.window_id,
                        .title = data.title,
                        .thumbnail_texture = texture,
                        .icon_texture = icon_tex,
                        .icon_id = data.icon_id,
                        .title_version = 1,
                        .thumbnail_version = 1,
                        .source_width = source_width,
                        .source_height = source_height,
                        .display_width = 0,
                        .display_height = 0,
                        .thumbnail_ready = has_texture,
                        .cached_snapshot = null,
                        .workspace = data.workspace,
                    };

                    self.items.append(new_item) catch {
                        // Free the strings since we failed to append
                        self.allocator.free(data.title);
                        self.allocator.free(data.icon_id);
                        if (self.window_textures.fetchRemove(data.window_id)) |entry| {
                            var t = entry.value;
                            t.deinit(self.conn);
                        }
                        continue;
                    };

                    // Clear ownership from task
                    data.title = &[_]u8{};
                    data.icon_id = &[_]u8{};
                },

                .window_removed => |*data| {
                    for (self.items.items, 0..) |*item, i| {
                        if (item.id == data.window_id) {
                            // Clean up WindowTexture
                            if (self.window_textures.fetchRemove(data.window_id)) |entry| {
                                var tex = entry.value;
                                tex.deinit(self.conn);
                            }
                            if (item.cached_snapshot) |snapshot| {
                                rl.UnloadRenderTexture(snapshot);
                                item.cached_snapshot = null;
                            }
                            self.allocator.free(item.title);
                            self.allocator.free(item.icon_id);
                            _ = self.items.orderedRemove(i);
                            break;
                        }
                    }
                },

                .title_updated => |*data| {
                    var found = false;
                    for (self.items.items) |*item| {
                        if (item.id == data.window_id) {
                            found = true;
                            if (data.title_version > item.title_version) {
                                self.allocator.free(item.title);
                                item.title = data.title;
                                item.title_version = data.title_version;
                                // Clear from task
                                data.title = &[_]u8{};
                            }
                            break;
                        }
                    }
                    if (!found or data.title.len > 0) {
                        // If not used, free it
                        if (data.title.len > 0) data.allocator.free(data.title);
                        data.title = &[_]u8{};
                    }
                },

                .icon_added => |*data| {
                    const thumb = thumbnail.Thumbnail{
                        .data = data.icon_data,
                        .width = data.icon_width,
                        .height = data.icon_height,
                        .allocator = data.allocator,
                    };
                    const texture = ui.loadTextureFromThumbnail(&thumb);

                    self.icon_texture_cache.put(data.icon_id, texture) catch {
                        rl.UnloadTexture(texture);
                        data.allocator.free(data.icon_id);
                        data.allocator.free(data.icon_data);
                        data.icon_id = &[_]u8{};
                        data.icon_data = &[_]u8{};
                        continue;
                    };

                    // Update all items that use this icon
                    for (self.items.items) |*item| {
                        if (std.mem.eql(u8, item.icon_id, data.icon_id)) {
                            item.icon_texture = texture;
                        }
                    }

                    // Clear ownership from task
                    // icon_id is now owned by map key
                    data.icon_id = &[_]u8{};
                    // icon_data uploaded to GPU, free it
                    data.allocator.free(data.icon_data);
                    data.icon_data = &[_]u8{};
                },
            }
        }

        // Clean up tasks
        for (self.temp_tasks.items) |*task| {
            task.deinit();
        }
        self.temp_tasks.clearRetainingCapacity();

        if (any_changes) {
            if (self.switch_mode == .current_workspace) {
                self.buildCurrentWorkspaceItems();

                if (self.state == .switching and self.filtered_items.items.len == 0) {
                    log.debug("All current-workspace windows disappeared during switching, cancelling", .{});
                    self.cancelSwitching();
                    return;
                }

                const dlen = self.displayItems().len;
                if (dlen == 0) {
                    self.selected_index = 0;
                } else if (self.selected_index >= dlen) {
                    self.selected_index = dlen - 1;
                }
            } else {
                if (self.items.items.len == 0) {
                    self.selected_index = 0;
                } else if (self.selected_index >= self.items.items.len) {
                    self.selected_index = self.items.items.len - 1;
                }
            }

            // Recalculate layout
            self.updateLayout();
        }
    }

    /// Move selection to next window (wraps around)
    pub fn selectNext(self: *Self) void {
        const items = self.displayItems();
        if (items.len == 0) return;
        self.selected_index = (self.selected_index + 1) % items.len;
    }

    /// Move selection to previous window (wraps around)
    pub fn selectPrev(self: *Self) void {
        const items = self.displayItems();
        if (items.len == 0) return;
        if (self.selected_index == 0) {
            self.selected_index = items.len - 1;
        } else {
            self.selected_index -= 1;
        }
    }

    /// Hide the switcher window. Snapshot work is deliberately deferred so
    /// releasing Alt/Super never blocks on one FBO copy per tracked window.
    /// Hide the switcher window. Cache valid frames, then release every
    /// XComposite/GLX binding exactly as upstream does. Keeping those bindings
    /// alive while hidden can leave Chromium, Firefox, and remote-desktop windows
    /// attached to stale or recycled backing pixmaps.
    pub fn hideWindow(self: *Self) void {
        log.debug("Hiding window", .{});
        const start_ns = std.time.nanoTimestamp();

        if (self.update_queue) |queue| {
            queue.setWindowVisible(false);
        }
        const after_notify_ns = std.time.nanoTimestamp();

        rl.SetWindowState(rl.FLAG_WINDOW_HIDDEN);
        const after_hide_ns = std.time.nanoTimestamp();

        self.window_hidden = true;
        self.reacquire_pending = false;
        self.mouse_left_was_down = false;

        self.cacheAllSnapshots();
        const after_snapshot_ns = std.time.nanoTimestamp();

        self.releaseAllBindings();
        const after_release_ns = std.time.nanoTimestamp();

        const total_us = @divTrunc(after_release_ns - start_ns, std.time.ns_per_us);
        if (total_us >= PROFILE_SLOW_HIDE_WINDOW_US) {
            log.debug(
                "profile hideWindow(us): total={d} notify={d} hide={d} snapshot={d} release={d} windows={d}",
                .{
                    total_us,
                    @divTrunc(after_notify_ns - start_ns, std.time.ns_per_us),
                    @divTrunc(after_hide_ns - after_notify_ns, std.time.ns_per_us),
                    @divTrunc(after_snapshot_ns - after_hide_ns, std.time.ns_per_us),
                    @divTrunc(after_release_ns - after_snapshot_ns, std.time.ns_per_us),
                    self.window_textures.count(),
                },
            );
        }
    }

    /// Show the switcher window (public for socket commands)
    /// Show the switcher window (public for socket commands)
    pub fn showWindow(self: *Self) void {
        const start_ns = std.time.nanoTimestamp();
        log.debug("Showing window with {d} items", .{self.displayItems().len});

        if (self.update_queue) |queue| {
            queue.setWindowVisible(true);
        }
        const after_notify_ns = std.time.nanoTimestamp();

        const mouse_pos = x11.getMousePosition(self.conn.conn, self.conn.root);
        self.monitor = findMonitorAtPosition(mouse_pos);
        const after_monitor_ns = std.time.nanoTimestamp();

        self.refreshWorkspaceInfo();
        self.refreshItemWorkspaces();

        self.current_layout = ui.calculateBestLayoutForMonitor(
            self.displayItems(),
            self.monitor.width,
            self.monitor.height,
            self.workspace_names.items,
        );
        const after_layout_ns = std.time.nanoTimestamp();

        rl.ClearWindowState(rl.FLAG_WINDOW_HIDDEN);
        const after_map_ns = std.time.nanoTimestamp();

        rl.SetWindowSize(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height));
        const after_size_ns = std.time.nanoTimestamp();

        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);
        const after_position_ns = std.time.nanoTimestamp();

        rl.SetWindowFocused();
        const after_focus_ns = std.time.nanoTimestamp();

        self.focus_grace_frames = 5;
        self.window_hidden = false;
        self.mouse_left_was_down = false;

        // All bindings were released while hidden. Reacquire ordinary live GLX
        // textures progressively; cached snapshots remain visible until each
        // window has a valid fresh binding.
        self.reacquire_pending = self.hasPendingReacquire();
        self.reacquire_cursor = if (self.items.items.len > 0) self.selected_index % self.items.items.len else 0;

        const total_us = @divTrunc(after_focus_ns - start_ns, std.time.ns_per_us);
        if (total_us >= PROFILE_SLOW_SHOW_WINDOW_US) {
            log.debug(
                "profile showWindow(us): total={d} notify={d} monitor={d} layout={d} map={d} size={d} position={d} focus={d}",
                .{
                    total_us,
                    @divTrunc(after_notify_ns - start_ns, std.time.ns_per_us),
                    @divTrunc(after_monitor_ns - after_notify_ns, std.time.ns_per_us),
                    @divTrunc(after_layout_ns - after_monitor_ns, std.time.ns_per_us),
                    @divTrunc(after_map_ns - after_layout_ns, std.time.ns_per_us),
                    @divTrunc(after_size_ns - after_map_ns, std.time.ns_per_us),
                    @divTrunc(after_position_ns - after_size_ns, std.time.ns_per_us),
                    @divTrunc(after_focus_ns - after_position_ns, std.time.ns_per_us),
                },
            );
        }
    }

    /// Number of frames to wait before showing the switcher window.
    /// If Alt is released before this, the window is never shown.
    const SHOW_DELAY_FRAMES: u8 = 1;

    /// Handle initial Alt+Tab press
    pub fn handleAltTab(self: *Self, shift: bool) void {
        if (self.state == .switching) {
            if (shift) {
                self.selectPrev();
            } else {
                self.selectNext();
            }
            return;
        }

        self.mouse_left_was_down = false;

        if (!x11.grabKeyboard(self.conn.conn, self.conn.root)) {
            log.err("Could not grab keyboard, aborting Alt+Tab", .{});
            return;
        }

        const active_win = x11.getActiveWindow(self.conn.conn, self.conn.root, self.conn.atoms);
        self.switch_origin_window = active_win;
        self.switch_origin_snapshot_ready = active_win != 0 and self.cacheSnapshotForWindow(active_win);
        if (active_win != 0) {
            self.recordMruActivation(active_win);
        }

        self.reorderByMru();

        const n = self.items.items.len;
        if (n == 0) {
            self.selected_index = 0;
        } else if (active_win != 0) {
            if (self.findItemIndexByWindowId(active_win)) |current_idx| {
                // Alt+Tab opens on the real current window.
                // Alt+Shift+Tab starts one slot before it for reverse navigation.
                self.selected_index = if (shift)
                    (if (current_idx == 0) n - 1 else current_idx - 1)
                else
                    current_idx;
            } else if (shift) {
                self.selected_index = n - 1;
            } else {
                self.selected_index = 0;
            }
        } else if (shift) {
            self.selected_index = n - 1;
        } else {
            self.selected_index = 0;
        }

        // Don't show the window yet — wait a couple of frames.  If Alt is
        // released before the countdown expires we switch without ever
        // mapping the window, avoiding the show/hide race during rapid Alt+Tab.
        self.show_delay_frames = SHOW_DELAY_FRAMES;
        self.state = .switching;
        log.debug("Alt+Tab switching started (shift={}, selected={d})", .{ shift, self.selected_index });
    }

    /// Handle Win+Tab press: switch only between windows on the current workspace.
    pub fn handleWinTab(self: *Self, shift: bool) void {
        if (self.state == .switching) {
            if (shift) {
                self.tab_pressed_during_shift = true;
                self.selectPrev();
            } else {
                self.selectNext();
            }
            return;
        }

        self.mouse_left_was_down = false;
        if (!x11.grabKeyboard(self.conn.conn, self.conn.root)) {
            log.err("Could not grab keyboard, aborting Win+Tab", .{});
            return;
        }

        const active_win = x11.getActiveWindow(self.conn.conn, self.conn.root, self.conn.atoms);
        if (active_win == 0) {
            log.debug("Win+Tab: no active window, aborting", .{});
            x11.ungrabKeyboard(self.conn.conn);
            return;
        }

        self.switch_origin_window = active_win;
        self.switch_origin_snapshot_ready = self.cacheSnapshotForWindow(active_win);
        self.recordMruActivation(active_win);
        self.reorderByMru();
        self.refreshWorkspaceInfo();
        self.refreshItemWorkspaces();

        const current_workspace = self.current_workspace orelse blk: {
            const active_workspace = x11.getWindowDesktop(self.conn.conn, active_win, self.conn.atoms) orelse {
                log.debug("Win+Tab: current workspace unavailable, aborting", .{});
                x11.ungrabKeyboard(self.conn.conn);
                return;
            };
            if (active_workspace == 0xFFFFFFFF) {
                log.debug("Win+Tab: active window is sticky and current workspace is unavailable", .{});
                x11.ungrabKeyboard(self.conn.conn);
                return;
            }
            self.current_workspace = active_workspace;
            break :blk active_workspace;
        };

        self.switch_mode = .current_workspace;
        self.buildCurrentWorkspaceItems();
        if (self.filtered_items.items.len <= 1) {
            log.debug("Win+Tab: current workspace {d} has {d} switchable window(s)", .{ current_workspace, self.filtered_items.items.len });
            x11.ungrabKeyboard(self.conn.conn);
            self.resetSwitchMode();
            return;
        }

        const n = self.filtered_items.items.len;
        var current_index: ?usize = null;
        for (self.filtered_items.items, 0..) |item, index| {
            if (item.id == active_win) {
                current_index = index;
                break;
            }
        }
        if (current_index) |index| {
            self.selected_index = if (shift) (if (index == 0) n - 1 else index - 1) else index;
        } else if (shift) {
            self.selected_index = n - 1;
        } else {
            self.selected_index = 0;
        }

        self.show_delay_frames = SHOW_DELAY_FRAMES;
        self.state = .switching;
        log.debug("Win+Tab current-workspace switching started (workspace={d}, count={d}, shift={}, selected={d})", .{ current_workspace, n, shift, self.selected_index });
    }

    /// Handle a key event during switching.
    pub fn handleKeyEvent(self: *Self, keysym: u32, is_press: bool) bool {
        if (self.state != .switching) {
            return false;
        }

        if (!is_press) {
            if (keysym == x11.XK_Alt_L or keysym == x11.XK_Alt_R or
                keysym == x11.XK_Super_L or keysym == x11.XK_Super_R)
            {
                self.confirmSwitching();
                return true;
            }
            if (keysym == x11.XK_Shift_L or keysym == x11.XK_Shift_R) {
                if (self.shift_held and !self.tab_pressed_during_shift) {
                    self.selectPrev();
                }
                self.shift_held = false;
                return true;
            }
            return false;
        }

        switch (keysym) {
            x11.XK_Shift_L, x11.XK_Shift_R => {
                self.shift_held = true;
                self.tab_pressed_during_shift = false;
                return true;
            },
            x11.XK_Tab => {
                if (self.shift_held) {
                    self.tab_pressed_during_shift = true;
                    self.selectPrev();
                } else {
                    self.selectNext();
                }
                return true;
            },
            x11.XK_ISO_Left_Tab => {
                self.tab_pressed_during_shift = true;
                self.selectPrev();
                return true;
            },
            x11.XK_Escape => {
                self.cancelSwitching();
                return true;
            },
            x11.XK_Return => {
                self.confirmSwitching();
                return true;
            },
            0x006c, 0x004c => { // l / L
                self.selected_index = nav.moveSelectionRight(self.selected_index, self.displayItems().len);
                return true;
            },
            0x0068, 0x0048 => { // h / H
                self.selected_index = nav.moveSelectionLeft(self.selected_index, self.displayItems().len);
                return true;
            },
            0x006a, 0x004a => { // j / J
                self.selected_index = nav.moveSelectionDown(self.selected_index, self.current_layout.columns, self.displayItems().len);
                return true;
            },
            0x006b, 0x004b => { // k / K
                self.selected_index = nav.moveSelectionUp(self.selected_index, self.current_layout.columns);
                return true;
            },
            x11.XK_Right => {
                self.selected_index = nav.moveSelectionRight(self.selected_index, self.displayItems().len);
                return true;
            },
            x11.XK_Left => {
                self.selected_index = nav.moveSelectionLeft(self.selected_index, self.displayItems().len);
                return true;
            },
            x11.XK_Down => {
                self.selected_index = nav.moveSelectionDown(self.selected_index, self.current_layout.columns, self.displayItems().len);
                return true;
            },
            x11.XK_Up => {
                self.selected_index = nav.moveSelectionUp(self.selected_index, self.current_layout.columns);
                return true;
            },
            else => return false,
        }
    }

    /// Confirm switching
    pub fn confirmSwitching(self: *Self) void {
        if (self.state != .switching) return;

        const start_ns = std.time.nanoTimestamp();

        const display = self.displayItems();
        if (display.len > 0 and self.selected_index < display.len) {
            const selected_id = display[self.selected_index].id;
            if (self.switch_origin_window != 0 and
                self.switch_origin_window != selected_id and
                !self.switch_origin_snapshot_ready)
            {
                self.switch_origin_snapshot_ready = self.cacheSnapshotForWindow(self.switch_origin_window);
            }
            self.recordMruActivation(selected_id);
            x11.activateWindow(self.conn.conn, self.conn.root, selected_id, self.conn.atoms);
            log.debug("Confirmed: activating window {x}", .{selected_id});
        }
        const after_activate_ns = std.time.nanoTimestamp();

        x11.ungrabKeyboard(self.conn.conn);
        const after_ungrab_ns = std.time.nanoTimestamp();

        self.show_delay_frames = null;
        if (!self.window_hidden) {
            self.hideWindow();
        }
        const after_hide_ns = std.time.nanoTimestamp();

        self.state = .idle;
        self.shift_held = false;
        self.tab_pressed_during_shift = false;
        self.switch_origin_window = 0;
        self.switch_origin_snapshot_ready = false;
        self.resetSwitchMode();

        log.debug(
            "profile confirmSwitching(us): total={d} activate={d} ungrab={d} hide={d}",
            .{
                @divTrunc(after_hide_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_activate_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_ungrab_ns - after_activate_ns, std.time.ns_per_us),
                @divTrunc(after_hide_ns - after_ungrab_ns, std.time.ns_per_us),
            },
        );
    }

    /// Cancel switching
    pub fn cancelSwitching(self: *Self) void {
        if (self.state != .switching) return;

        const start_ns = std.time.nanoTimestamp();
        log.debug("Switching cancelled", .{});
        x11.ungrabKeyboard(self.conn.conn);
        const after_ungrab_ns = std.time.nanoTimestamp();

        self.show_delay_frames = null;
        if (!self.window_hidden) {
            self.hideWindow();
        }
        const after_hide_ns = std.time.nanoTimestamp();

        self.state = .idle;
        self.shift_held = false;
        self.tab_pressed_during_shift = false;
        self.switch_origin_window = 0;
        self.switch_origin_snapshot_ready = false;
        self.resetSwitchMode();

        log.debug(
            "profile cancelSwitching(us): total={d} ungrab={d} hide={d}",
            .{
                @divTrunc(after_hide_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_ungrab_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_hide_ns - after_ungrab_ns, std.time.ns_per_us),
            },
        );
    }

    /// Handle damage events without treating a transient GLX error as window death.
    /// Handle damage using the upstream live-pixmap lifecycle. A stale
    /// backing pixmap is reacquired immediately while FastTab is visible; while
    /// hidden, bindings are released and damage is only acknowledged.
    pub fn handleDamageEvent(self: *Self, drawable: x11.xcb.xcb_window_t) void {
        if (self.window_textures.getPtr(drawable)) |tex| {
            _ = x11.xcb.xcb_damage_subtract(self.conn.conn, tex.damage, 0, 0);

            if (self.window_hidden) return;

            if (!tex.rebind(self.conn)) {
                log.debug("GLX rebind failed for window {x}, reacquiring pixmap", .{drawable});
                _ = self.cacheSnapshotForWindow(drawable);
                tex.invalidate(self.conn);

                if (!tex.reacquire(self.conn)) {
                    self.markThumbnailReady(drawable, false);
                    self.reacquire_pending = true;
                    if (self.findItemIndexByWindowId(drawable)) |index| {
                        self.reacquire_cursor = index;
                    }
                    return;
                }
            }

            self.markThumbnailReady(drawable, true);
            if (self.findItemByWindowId(drawable)) |item| {
                item.thumbnail_texture = tex.toRaylibTexture();
                if (item.source_width != tex.width or item.source_height != tex.height) {
                    item.source_width = tex.width;
                    item.source_height = tex.height;
                    self.updateLayout();
                }
            }
        }
    }

    /// Reorder internal items to match stacking order (reversed = MRU first)
    fn reorderByStacking(self: *Self) void {
        const stacking = x11.getStackingWindowList(self.allocator, self.conn.conn, self.conn.root, self.conn.atoms) catch |err| {
            log.debug("Could not get stacking list: {}", .{err});
            return;
        };
        defer self.allocator.free(stacking);

        if (stacking.len == 0) return;

        var new_items = std.ArrayList(ui.DisplayWindow).init(self.allocator);
        defer new_items.deinit();
        new_items.ensureTotalCapacity(self.items.items.len) catch return;

        var si: usize = stacking.len;
        while (si > 0) {
            si -= 1;
            const stacking_id = stacking[si];
            for (self.items.items) |item| {
                if (item.id == stacking_id) {
                    new_items.appendAssumeCapacity(item);
                    break;
                }
            }
        }

        for (self.items.items) |item| {
            var found = false;
            for (new_items.items) |new_item| {
                if (new_item.id == item.id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                new_items.append(item) catch continue;
            }
        }

        self.items.clearRetainingCapacity();
        for (new_items.items) |item| {
            self.items.append(item) catch continue;
        }
    }

    /// Release all GLX texture bindings (frees pixmaps for other compositors)
    fn releaseAllBindings(self: *Self) void {
        var iter = self.window_textures.valueIterator();
        while (iter.next()) |tex| {
            tex.release(self.conn);
        }
        for (self.items.items) |*item| {
            item.thumbnail_ready = false;
        }
        log.debug("Released {d} GLX bindings", .{self.window_textures.count()});
    }

    /// Refresh mapped windows in place. If GLX rejects a refresh, keep the old
    /// cached snapshot and let the progressive reacquire queue retry later.


    /// Ensure one visible origin window has a valid live texture before
    /// taking its fallback frame. This preserves cross-workspace previews without
    /// keeping every GLX pixmap bound while FastTab is hidden.
    /// Cache all currently valid live thumbnails before releasing their
    /// GLX bindings. Previous snapshots are replaced only after a new copy succeeds.
    fn cacheAllSnapshots(self: *Self) void {
        var cached_count: usize = 0;
        for (self.items.items) |*item| {
            if (self.cacheSnapshotForItem(item)) cached_count += 1;
        }
        if (cached_count > 0) {
            log.debug("Cached {d} thumbnail snapshots", .{cached_count});
        }
    }

    fn cacheSnapshotForWindow(self: *Self, window_id: x11.xcb.xcb_window_t) bool {
        const item = self.findItemByWindowId(window_id) orelse return false;

        if (!item.thumbnail_ready) {
            if (self.window_textures.getPtr(window_id)) |tex| {
                if (!tex.bound and !tex.reacquire(self.conn)) return false;
                item.thumbnail_texture = tex.toRaylibTexture();
                item.thumbnail_ready = true;
                item.source_width = tex.width;
                item.source_height = tex.height;
            } else {
                const created = x11.createWindowTexture(self.conn, window_id) catch return false;
                self.window_textures.put(window_id, created) catch {
                    var to_free = created;
                    to_free.deinit(self.conn);
                    return false;
                };
                const stored = self.window_textures.getPtr(window_id) orelse return false;
                item.thumbnail_texture = stored.toRaylibTexture();
                item.thumbnail_ready = true;
                item.source_width = stored.width;
                item.source_height = stored.height;
            }
        }

        return self.cacheSnapshotForItem(item);
    }



    /// Copy one live thumbnail into a replacement FBO. The previous snapshot is
    /// unloaded only after the new one succeeds, so no refresh can erase fallback data.
    fn cacheSnapshotForItem(self: *Self, item: *ui.DisplayWindow) bool {
        if (!item.thumbnail_ready or item.thumbnail_texture.id == 0) return false;
        if (item.display_width == 0 or item.display_height == 0) return false;

        const rt = rl.LoadRenderTexture(@intCast(item.display_width), @intCast(item.display_height));
        if (rt.id == 0) return false;

        const source_rect = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(item.thumbnail_texture.width),
            .height = @floatFromInt(item.thumbnail_texture.height),
        };
        const dest_rect = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(item.display_width),
            .height = @floatFromInt(item.display_height),
        };

        rl.BeginTextureMode(rt);
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        if (self.downsample_shader) |*shader| {
            shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
            rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            shader.end();
        } else {
            rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
        }
        rl.EndTextureMode();

        if (item.cached_snapshot) |previous| {
            rl.UnloadRenderTexture(previous);
        }
        item.cached_snapshot = rt;
        return true;
    }

    /// Perform no more than one GPU snapshot copy while hidden. Cheaply skip
    /// ineligible items until one copy succeeds or the pass is complete.


    const REACQUIRE_FRAME_BUDGET_NS: i128 = 10 * std.time.ns_per_ms;

    /// Incrementally reacquire GLX textures during update() to avoid blocking showWindow.
    /// Each pending window is attempted at most once per frame; failures remain tracked.
    fn processReacquireQueue(self: *Self) void {
        if (!self.reacquire_pending or self.window_hidden) return;

        const start_ns = std.time.nanoTimestamp();
        var layout_dirty = false;
        var reacquired_count: usize = 0;
        var failed_count: usize = 0;
        var max_window_us: i128 = 0;
        var max_window_id: x11.xcb.xcb_window_t = 0;
        var attempts_remaining = self.items.items.len;
        var prefer_selected = true;

        while (attempts_remaining > 0 and std.time.nanoTimestamp() - start_ns < REACQUIRE_FRAME_BUDGET_NS) {
            const target_id = self.nextPendingReacquireWindowId(prefer_selected) orelse break;
            prefer_selected = false;
            attempts_remaining -= 1;
            const window_start_ns = std.time.nanoTimestamp();

            if (self.window_textures.getPtr(target_id)) |tex| {
                if (!tex.reacquire(self.conn)) {
                    self.markThumbnailReady(target_id, false);
                    failed_count += 1;
                    continue;
                }

                const window_us = @divTrunc(std.time.nanoTimestamp() - window_start_ns, std.time.ns_per_us);
                if (window_us > max_window_us) {
                    max_window_us = window_us;
                    max_window_id = target_id;
                }
                if (window_us >= PROFILE_SLOW_REACQUIRE_WINDOW_US) {
                    log.debug("profile reacquire window: id={x} duration_us={d}", .{ target_id, window_us });
                }
                reacquired_count += 1;

                const new_w = tex.width;
                const new_h = tex.height;
                self.markThumbnailReady(target_id, true);
                if (self.findItemByWindowId(target_id)) |item| {
                    item.thumbnail_texture = tex.toRaylibTexture();
                    if (item.source_width != new_w or item.source_height != new_h) {
                        item.source_width = new_w;
                        item.source_height = new_h;
                        layout_dirty = true;
                    }
                }
            } else {
                const win_tex = x11.createWindowTexture(self.conn, target_id) catch {
                    self.markThumbnailReady(target_id, false);
                    failed_count += 1;
                    continue;
                };

                self.window_textures.put(target_id, win_tex) catch {
                    var texture_to_free = win_tex;
                    texture_to_free.deinit(self.conn);
                    failed_count += 1;
                    continue;
                };

                const window_us = @divTrunc(std.time.nanoTimestamp() - window_start_ns, std.time.ns_per_us);
                if (window_us > max_window_us) {
                    max_window_us = window_us;
                    max_window_id = target_id;
                }
                if (window_us >= PROFILE_SLOW_REACQUIRE_WINDOW_US) {
                    log.debug("profile acquire new texture: id={x} duration_us={d}", .{ target_id, window_us });
                }
                reacquired_count += 1;

                self.markThumbnailReady(target_id, true);
                if (self.findItemByWindowId(target_id)) |item| {
                    if (self.window_textures.getPtr(target_id)) |stored_tex| {
                        item.thumbnail_texture = stored_tex.toRaylibTexture();
                    }
                    if (item.source_width != win_tex.width or item.source_height != win_tex.height) {
                        item.source_width = win_tex.width;
                        item.source_height = win_tex.height;
                        layout_dirty = true;
                    }
                }
            }
        }

        if (layout_dirty) self.updateLayout();
        self.reacquire_pending = self.hasPendingReacquire();

        const frame_us = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_us);
        if (false and (frame_us >= PROFILE_SLOW_REACQUIRE_FRAME_US or failed_count > 0)) {
            log.debug(
                "profile reacquire frame(us): total={d} reacquired={d} failed={d} max_window={d} max_window_id={x} pending={}",
                .{ frame_us, reacquired_count, failed_count, max_window_us, max_window_id, self.reacquire_pending },
            );
        }
    }

    fn hasPendingReacquire(self: *Self) bool {
        for (self.items.items) |item| {
            if (!item.thumbnail_ready) {
                if (self.window_textures.getPtr(item.id)) |tex| {
                    if (!tex.bound) {
                        return true;
                    }
                } else {
                    // No texture at all (minimized or initial creation failed) — needs acquire
                    return true;
                }
            }
        }
        return false;
    }

    fn nextPendingReacquireWindowId(self: *Self, prefer_selected: bool) ?x11.xcb.xcb_window_t {
        if (self.items.items.len == 0) return null;

        if (prefer_selected and self.selected_index < self.items.items.len) {
            const index = self.selected_index;
            const selected = self.items.items[index];
            if (!selected.thumbnail_ready) {
                if (self.window_textures.getPtr(selected.id)) |tex| {
                    if (!tex.bound) {
                        self.reacquire_cursor = (index + 1) % self.items.items.len;
                        return selected.id;
                    }
                } else {
                    self.reacquire_cursor = (index + 1) % self.items.items.len;
                    return selected.id;
                }
            }
        }

        const start = self.reacquire_cursor % self.items.items.len;
        var offset: usize = 0;
        while (offset < self.items.items.len) : (offset += 1) {
            const index = (start + offset) % self.items.items.len;
            const item = self.items.items[index];
            if (item.thumbnail_ready) continue;

            if (self.window_textures.getPtr(item.id)) |tex| {
                if (!tex.bound) {
                    self.reacquire_cursor = (index + 1) % self.items.items.len;
                    return item.id;
                }
            } else {
                self.reacquire_cursor = (index + 1) % self.items.items.len;
                return item.id;
            }
        }

        return null;
    }

    fn findItemByWindowId(self: *Self, wid: x11.xcb.xcb_window_t) ?*ui.DisplayWindow {
        for (self.items.items) |*item| {
            if (item.id == wid) {
                return item;
            }
        }
        return null;
    }

    fn findItemIndexByWindowId(self: *Self, wid: x11.xcb.xcb_window_t) ?usize {
        for (self.items.items, 0..) |item, i| {
            if (item.id == wid) {
                return i;
            }
        }
        return null;
    }

    fn markThumbnailReady(self: *Self, wid: x11.xcb.xcb_window_t, ready: bool) void {
        if (self.findItemByWindowId(wid)) |item| {
            item.thumbnail_ready = ready;
        }
    }

    /// Remove a DisplayWindow from self.items by window ID, freeing owned strings.
    fn removeItemByWindowId(self: *Self, wid: x11.xcb.xcb_window_t) void {
        self.removeMruEntry(wid);
        for (self.items.items, 0..) |*item, i| {
            if (item.id == wid) {
                if (item.cached_snapshot) |snapshot| {
                    rl.UnloadRenderTexture(snapshot);
                }
                self.allocator.free(item.title);
                self.allocator.free(item.icon_id);
                _ = self.items.orderedRemove(i);
                return;
            }
        }
    }

    /// Reset to all-windows mode after a switch completes or is cancelled.
    fn resetSwitchMode(self: *Self) void {
        self.switch_mode = .all_windows;
        self.filtered_items.clearRetainingCapacity();
    }

    /// Remove a window ID from the MRU list (linear scan).
    fn removeMruEntry(self: *Self, wid: x11.xcb.xcb_window_t) void {
        for (self.mru_list.items, 0..) |entry, i| {
            if (entry == wid) {
                _ = self.mru_list.orderedRemove(i);
                return;
            }
        }
    }

    /// Record a window activation immediately so the next Alt+Tab order is stable.
    fn recordMruActivation(self: *Self, wid: x11.xcb.xcb_window_t) void {
        if (wid == 0) return;
        self.removeMruEntry(wid);
        self.mru_list.insert(0, wid) catch return;
        if (self.mru_list.items.len > MRU_CAP) {
            self.mru_list.items.len = MRU_CAP;
        }
    }

    /// Update the MRU list when _NET_ACTIVE_WINDOW changes.
    pub fn handleActiveWindowChanged(self: *Self) void {
        const wid = x11.getActiveWindow(self.conn.conn, self.conn.root, self.conn.atoms);
        if (wid == 0) return;

        // Skip our own switcher window (it's not in items, but check by process)
        // We identify it as "not tracked" — harmless to include since reorderByMru
        // only picks up windows that exist in self.items. We still skip the known
        // case where focus returns to us during switching.
        if (self.state == .switching) return;

        self.recordMruActivation(wid);
    }

    /// Reorder self.items by MRU history, falling back to current order for unlisted windows.
    fn reorderByMru(self: *Self) void {
        if (self.items.items.len == 0) return;

        var new_items = std.ArrayList(ui.DisplayWindow).init(self.allocator);
        defer new_items.deinit();
        new_items.ensureTotalCapacity(self.items.items.len) catch return;

        // First pass: add items in MRU order
        for (self.mru_list.items) |mru_id| {
            for (self.items.items) |item| {
                if (item.id == mru_id) {
                    new_items.appendAssumeCapacity(item);
                    break;
                }
            }
        }

        // Second pass: append any items not in the MRU list (preserve their current order)
        for (self.items.items) |item| {
            var found = false;
            for (new_items.items) |new_item| {
                if (new_item.id == item.id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                new_items.append(item) catch continue;
            }
        }

        self.items.clearRetainingCapacity();
        for (new_items.items) |item| {
            self.items.append(item) catch continue;
        }
    }

    /// Returns the slice used by rendering and navigation.
    pub fn displayItems(self: *Self) []ui.DisplayWindow {
        return switch (self.switch_mode) {
            .all_windows => self.items.items,
            .current_workspace => self.filtered_items.items,
        };
    }

    /// Rebuild the non-owning current-workspace view.
    fn buildCurrentWorkspaceItems(self: *Self) void {
        self.filtered_items.clearRetainingCapacity();
        const workspace = self.current_workspace orelse return;
        filterItemsByWorkspace(self.items.items, workspace, &self.filtered_items);
    }

    /// Propagate mutable rendering state from self.items into filtered_items.
    ///
    /// filtered_items holds VALUE copies taken when the current-workspace view is built.  Several
    /// fields are updated on self.items after that point (reacquire, damage, icon/title
    /// worker updates) and the copies go stale.  We sync here rather than on each write
    /// site to keep the rest of the code unchanged.
    ///
    /// Fields intentionally NOT synced:
    ///   display_width / display_height — set by calculateBestLayout on the filtered
    ///   slice; self.items values are from a different (all_windows) layout pass.
    fn syncFilteredItems(self: *Self) void {
        for (self.filtered_items.items) |*fi| {
            const src = self.findItemByWindowId(fi.id) orelse continue;
            fi.thumbnail_ready = src.thumbnail_ready;
            fi.thumbnail_texture = src.thumbnail_texture;
            fi.cached_snapshot = src.cached_snapshot; // may be null after reacquire freed it
            fi.icon_texture = src.icon_texture;
            fi.workspace = src.workspace;
            fi.title = src.title; // same heap allocation; sync pointer in case title was updated
        }
    }

    fn clearWorkspaceInfo(self: *Self) void {
        for (self.workspace_names.items) |name| {
            self.allocator.free(name);
        }
        self.workspace_names.clearRetainingCapacity();
        self.current_workspace = null;
    }

    fn refreshWorkspaceInfo(self: *Self) void {
        self.clearWorkspaceInfo();

        var info = x11.getWorkspaceInfo(self.allocator, self.conn.conn, self.conn.root, self.conn.atoms);
        defer info.deinit();

        self.current_workspace = info.current;
        for (info.names) |name| {
            const owned = self.allocator.dupe(u8, name) catch continue;
            self.workspace_names.append(owned) catch {
                self.allocator.free(owned);
                continue;
            };
        }
    }

    fn refreshItemWorkspaces(self: *Self) void {
        for (self.items.items) |*item| {
            item.workspace = x11.getWindowDesktop(self.conn.conn, item.id, self.conn.atoms);
        }
        if (self.switch_mode == .current_workspace) self.buildCurrentWorkspaceItems();
    }

    fn render(self: *Self) void {
        // Keep filtered_items in sync with self.items before every draw.
        // processReacquireQueue() and handleDamageEvent() update self.items directly;
        // without this sync filtered_items would have stale thumbnail_ready / cached_snapshot.
        if (self.switch_mode == .current_workspace) self.syncFilteredItems();

        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);

        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        const shader_ptr: ?*const ui.DownsampleShader = if (self.downsample_shader) |*s| s else null;
        ui.renderSwitcher(
            self.displayItems(),
            self.current_layout,
            self.selected_index,
            self.mouseover_index,
            self.font,
            shader_ptr,
            self.workspace_names.items,
            self.current_workspace,
        );
        rl.EndDrawing();
    }

    fn updateLayout(self: *Self) void {
        const prev_width = self.current_layout.total_width;
        const prev_height = self.current_layout.total_height;
        self.current_layout = ui.calculateBestLayoutForMonitor(
            self.displayItems(),
            self.monitor.width,
            self.monitor.height,
            self.workspace_names.items,
        );

        if (!self.window_hidden and (self.current_layout.total_width != prev_width or self.current_layout.total_height != prev_height)) {
            rl.SetWindowSize(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height));
            const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
            const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
            rl.SetWindowPosition(win_x, win_y);
            log.debug("Window resized to {d}x{d}", .{ self.current_layout.total_width, self.current_layout.total_height });
        }
    }
};

/// Filter DisplayWindow items by workspace.
/// Sticky windows and windows without workspace metadata remain switchable.
/// Items appended to out are shallow (non-owning) copies.
pub fn filterItemsByWorkspace(
    items: []const ui.DisplayWindow,
    current_workspace: u32,
    out: *std.ArrayList(ui.DisplayWindow),
) void {
    for (items) |item| {
        const belongs = if (item.workspace) |workspace|
            workspace == current_workspace or workspace == 0xFFFFFFFF
        else
            true;
        if (belongs) out.append(item) catch {};
    }
}

pub fn findMonitorAtPosition(pos: x11.MousePosition) MonitorInfo {
    const monitor_count = rl.GetMonitorCount();

    var m: i32 = 0;
    while (m < monitor_count) : (m += 1) {
        const mx = rl.GetMonitorPosition(m).x;
        const my = rl.GetMonitorPosition(m).y;
        const mw = rl.GetMonitorWidth(m);
        const mh = rl.GetMonitorHeight(m);

        if (pos.x >= @as(i32, @intFromFloat(mx)) and
            pos.x < @as(i32, @intFromFloat(mx)) + mw and
            pos.y >= @as(i32, @intFromFloat(my)) and
            pos.y < @as(i32, @intFromFloat(my)) + mh)
        {
            return MonitorInfo{
                .index = m,
                .x = @intFromFloat(mx),
                .y = @intFromFloat(my),
                .width = mw,
                .height = mh,
            };
        }
    }

    return MonitorInfo{
        .index = 0,
        .x = 0,
        .y = 0,
        .width = 1920,
        .height = 1080,
    };
}
