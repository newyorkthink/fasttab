from pathlib import Path
import re

ROOT = Path('.')
APP = ROOT / 'src/app.zig'
MAIN = ROOT / 'src/main.zig'
TEST = ROOT / 'src/tests/app_filter_test.zig'
BUILD = ROOT / 'build.zig'


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f'expected one occurrence, found {text.count(old)}: {old[:80]!r}')
    return text.replace(old, new, 1)

app = APP.read_text()
app = replace_once(app, '''pub const SwitchMode = enum {
    all_windows, // Alt+Tab: show everything
    same_app, // Win+Tab: filter by WM_CLASS of the active window
};''', '''pub const SwitchMode = enum {
    all_windows, // Alt+Tab: show every tracked window
    current_workspace, // Win+Tab: show windows on the active workspace
};''')
app = replace_once(app, '''    // Win+Tab same-app filtering
    switch_mode: SwitchMode,
    filtered_items: std.ArrayList(ui.DisplayWindow), // non-owning shallow copies; strings owned by items
    active_app_class: ?[]const u8, // owned; null when not filtering
''', '''    // Win+Tab current-workspace filtering
    switch_mode: SwitchMode,
    filtered_items: std.ArrayList(ui.DisplayWindow), // non-owning shallow copies; strings owned by items
''')
app = app.replace('            .active_app_class = null,\n', '', 1)
app = re.sub(r'''        if \(self\.active_app_class\) \|class\| \{\n            self\.allocator\.free\(class\);\n        \}\n''', '', app, count=1)
app = replace_once(app, '''            if (self.switch_mode == .same_app) {
                // Rebuild filtered view now that self.items has changed.
                self.buildFilteredItems();

                // If all same-app windows disappear while the user is switching, cancel cleanly.
                if (self.state == .switching and self.filtered_items.items.len == 0) {
                    log.debug("All same-app windows removed during switching, cancelling", .{});
                    self.cancelSwitching(); // ungrabs keyboard, hides window, resets switch_mode
                    return;
                }

                // Clamp selected_index against the (now-fresh) filtered list.
''', '''            if (self.switch_mode == .current_workspace) {
                self.buildCurrentWorkspaceItems();

                if (self.state == .switching and self.filtered_items.items.len == 0) {
                    log.debug("All current-workspace windows disappeared during switching, cancelling", .{});
                    self.cancelSwitching();
                    return;
                }

''')

start = app.index('    /// Handle Win+Tab press: start (or cycle) same-app switching.')
end = app.index('    /// Handle a key event during switching.', start)
app = app[:start] + '''    /// Handle Win+Tab press: switch only between windows on the current workspace.
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

''' + app[end:]

app = re.sub(r'''    /// Reset to all_windows mode and release same_app filtering state\.[\s\S]*?    fn resetSwitchMode\(self: \*Self\) void \{\n        self\.switch_mode = \.all_windows;\n        self\.filtered_items\.clearRetainingCapacity\(\);\n        if \(self\.active_app_class\) \|class\| \{\n            self\.allocator\.free\(class\);\n            self\.active_app_class = null;\n        \}\n    \}\n''', '''    /// Reset to all-windows mode after a switch completes or is cancelled.
    fn resetSwitchMode(self: *Self) void {
        self.switch_mode = .all_windows;
        self.filtered_items.clearRetainingCapacity();
    }
''', app, count=1)

start = app.index('    /// Returns the slice to render/navigate: filtered list in same_app mode')
end = app.index('    /// Propagate mutable rendering state from self.items into filtered_items.', start)
app = app[:start] + '''    /// Returns the slice used by rendering and navigation.
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

''' + app[end:]
app = app.replace('filtered_items holds VALUE copies taken at buildFilteredItems() time.', 'filtered_items holds VALUE copies taken when the current-workspace view is built.')
app = app.replace('        if (self.switch_mode == .same_app) self.syncFilteredItems();', '        if (self.switch_mode == .current_workspace) self.buildCurrentWorkspaceItems();', 1)
app = app.replace('        if (self.switch_mode == .same_app) self.syncFilteredItems();', '        if (self.switch_mode == .current_workspace) self.syncFilteredItems();', 1)

start = app.index('/// Filter DisplayWindow items by WM_CLASS')
end = app.index('pub fn findMonitorAtPosition', start)
app = app[:start] + '''/// Filter DisplayWindow items by workspace.
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

''' + app[end:]
for token in ('same_app', 'active_app_class', 'filterItemsByClass'):
    if token in app:
        raise SystemExit(f'{token} remains in src/app.zig')
APP.write_text(app)

main = MAIN.read_text()
main = main.replace('const MRU_CAP: usize = 128;\nconst SHOW_DELAY_FRAMES: u8 = 1;\n', '')
main = main.replace('    var workspace_switching = false;\n\n', '')
main = main.replace('        processXcbEvents(&application, &conn, &workspace_switching);\n\n        if (application.state == .idle) {\n            workspace_switching = false;\n        }\n\n        // filtered_items contains shallow copies while Win+Tab is active. Delay\n        // worker updates until switching ends so app.zig does not rebuild the list\n        // using the retired same-application filter.\n        if (!workspace_switching) {\n            application.drainUpdateQueue();\n        }', '        processXcbEvents(&application, &conn);\n\n        application.drainUpdateQueue();')
main = main.replace('fn processXcbEvents(application: *app.App, conn: *x11.Connection, workspace_switching: *bool) void {', 'fn processXcbEvents(application: *app.App, conn: *x11.Connection) void {')
main = re.sub(r'''                    workspace_switching\.\* = handleWorkspaceTab\(\n                        application,\n                        conn,\n                        is_shift or base_keysym == x11\.XK_ISO_Left_Tab,\n                    \);''', '                    application.handleWinTab(is_shift or base_keysym == x11.XK_ISO_Left_Tab);', main, count=1)
main = main.replace('\n        if (application.state == .idle) {\n            workspace_switching.* = false;\n        }\n', '\n')
marker = '\n/// Start or continue Win+Tab switching for the current workspace.'
main = main[:main.index(marker)].rstrip() + '\n'
for token in ('same_app', 'active_app_class', 'handleWorkspaceTab', 'workspace_switching'):
    if token in main:
        raise SystemExit(f'{token} remains in src/main.zig')
MAIN.write_text(main)

TEST.write_text('''const std = @import("std");
const app = @import("app");
const testing = std.testing;
const DisplayWindow = app.DisplayWindow;

fn makeWindow(id: u32, workspace: ?u32) DisplayWindow {
    var window = std.mem.zeroes(DisplayWindow);
    window.id = id;
    window.icon_id = "test-app";
    window.workspace = workspace;
    return window;
}

fn filtered(items: []const DisplayWindow, workspace: u32, out: *std.ArrayList(DisplayWindow)) void {
    app.filterItemsByWorkspace(items, workspace, out);
}

test "current workspace filter includes matches only" {
    const items = [_]DisplayWindow{ makeWindow(1, 1), makeWindow(2, 2), makeWindow(3, 1) };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    filtered(&items, 1, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].id);
    try testing.expectEqual(@as(u32, 3), out.items[1].id);
}

test "current workspace filter includes sticky and unknown windows" {
    const items = [_]DisplayWindow{ makeWindow(1, 4), makeWindow(2, 0xFFFFFFFF), makeWindow(3, null), makeWindow(4, 7) };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    filtered(&items, 4, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].id);
    try testing.expectEqual(@as(u32, 2), out.items[1].id);
    try testing.expectEqual(@as(u32, 3), out.items[2].id);
}

test "current workspace filter preserves ordering and shallow copies" {
    const items = [_]DisplayWindow{ makeWindow(10, 2), makeWindow(20, 1), makeWindow(30, 2) };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    filtered(&items, 2, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 10), out.items[0].id);
    try testing.expectEqual(@as(u32, 30), out.items[1].id);
    try testing.expect(items[0].icon_id.ptr == out.items[0].icon_id.ptr);
}
''')
BUILD.write_text(BUILD.read_text().replace('// App filter test (filterItemsByClass + SwitchMode infrastructure)', '// Current-workspace filter test'))
(ROOT / 'VERSION').write_text('1.0.2\n')
