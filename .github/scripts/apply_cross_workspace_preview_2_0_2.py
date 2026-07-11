from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


# Track the real application that was active before FastTab takes focus.
replace_once(
    "src/app.zig",
    "    snapshot_pending: bool,\n    snapshot_cursor: usize,\n    mru_list: std.ArrayList(x11.xcb.xcb_window_t),",
    "    snapshot_pending: bool,\n    snapshot_cursor: usize,\n    switch_origin_window: x11.xcb.xcb_window_t,\n    switch_origin_snapshot_ready: bool,\n    mru_list: std.ArrayList(x11.xcb.xcb_window_t),",
)
replace_once(
    "src/app.zig",
    "            .snapshot_pending = false,\n            .snapshot_cursor = 0,\n            .mru_list = mru_list,",
    "            .snapshot_pending = false,\n            .snapshot_cursor = 0,\n            .switch_origin_window = 0,\n            .switch_origin_snapshot_ready = false,\n            .mru_list = mru_list,",
)

# Capture the origin window while it is still mapped. A single thumbnail copy is
# cheap and prevents i3 from invalidating the only usable preview after workspace switch.
replace_once(
    "src/app.zig",
    "        const active_win = x11.getActiveWindow(self.conn.conn, self.conn.root, self.conn.atoms);\n        if (active_win != 0) {\n            self.recordMruActivation(active_win);\n        }",
    "        const active_win = x11.getActiveWindow(self.conn.conn, self.conn.root, self.conn.atoms);\n        self.switch_origin_window = active_win;\n        self.switch_origin_snapshot_ready = active_win != 0 and self.cacheSnapshotForWindow(active_win);\n        if (active_win != 0) {\n            self.recordMruActivation(active_win);\n        }",
)
replace_once(
    "src/app.zig",
    "        self.recordMruActivation(active_win);\n        self.reorderByMru();\n        self.refreshWorkspaceInfo();",
    "        self.switch_origin_window = active_win;\n        self.switch_origin_snapshot_ready = self.cacheSnapshotForWindow(active_win);\n        self.recordMruActivation(active_win);\n        self.reorderByMru();\n        self.refreshWorkspaceInfo();",
)

# Retry once immediately before activation if the early capture was not possible
# (for example, before the first layout has assigned thumbnail dimensions).
replace_once(
    "src/app.zig",
    "        const display = self.displayItems();\n        if (display.len > 0 and self.selected_index < display.len) {\n            const selected_id = display[self.selected_index].id;\n            self.recordMruActivation(selected_id);",
    "        const display = self.displayItems();\n        if (display.len > 0 and self.selected_index < display.len) {\n            const selected_id = display[self.selected_index].id;\n            if (self.switch_origin_window != 0 and\n                self.switch_origin_window != selected_id and\n                !self.switch_origin_snapshot_ready)\n            {\n                self.switch_origin_snapshot_ready = self.cacheSnapshotForWindow(self.switch_origin_window);\n            }\n            self.recordMruActivation(selected_id);",
)
replace_once(
    "src/app.zig",
    "        self.state = .idle;\n        self.shift_held = false;\n        self.tab_pressed_during_shift = false;\n        self.resetSwitchMode();\n\n        log.debug(\n            \"profile confirmSwitching",
    "        self.state = .idle;\n        self.shift_held = false;\n        self.tab_pressed_during_shift = false;\n        self.switch_origin_window = 0;\n        self.switch_origin_snapshot_ready = false;\n        self.resetSwitchMode();\n\n        log.debug(\n            \"profile confirmSwitching",
)
replace_once(
    "src/app.zig",
    "        self.state = .idle;\n        self.shift_held = false;\n        self.tab_pressed_during_shift = false;\n        self.resetSwitchMode();\n\n        log.debug(\n            \"profile cancelSwitching",
    "        self.state = .idle;\n        self.shift_held = false;\n        self.tab_pressed_during_shift = false;\n        self.switch_origin_window = 0;\n        self.switch_origin_snapshot_ready = false;\n        self.resetSwitchMode();\n\n        log.debug(\n            \"profile cancelSwitching",
)

# Before invalidating a GLX pixmap, preserve whatever valid frame is still in the
# texture. Replacement happens only after the new FBO has been created successfully.
replace_once(
    "src/app.zig",
    "            if (!tex.rebind(self.conn)) {\n                log.debug(\"GLX rebind failed for window {x}; preserving cached preview and retrying later\", .{drawable});\n                tex.invalidate(self.conn);",
    "            if (!tex.rebind(self.conn)) {\n                log.debug(\"GLX rebind failed for window {x}; preserving cached preview and retrying later\", .{drawable});\n                _ = self.cacheSnapshotForWindow(drawable);\n                tex.invalidate(self.conn);",
)
replace_once(
    "src/app.zig",
    "                if (tex.bound) tex.invalidate(self.conn);\n            }\n\n            item.thumbnail_ready = false;",
    "                _ = self.cacheSnapshotForItem(item);\n                if (tex.bound) tex.invalidate(self.conn);\n            }\n\n            item.thumbnail_ready = false;",
)

# Convenience wrapper used by the switch origin and GLX failure paths.
replace_once(
    "src/app.zig",
    "    fn scheduleSnapshotRefresh(self: *Self) void {",
    "    fn cacheSnapshotForWindow(self: *Self, window_id: x11.xcb.xcb_window_t) bool {\n        const item = self.findItemByWindowId(window_id) orelse return false;\n        return self.cacheSnapshotForItem(item);\n    }\n\n    fn scheduleSnapshotRefresh(self: *Self) void {",
)

# Release metadata.
Path("VERSION").write_text("2.0.2\n", encoding="utf-8")
replace_once("src/main.zig", 'const FASTTAB_VERSION = "2.0.1";', 'const FASTTAB_VERSION = "2.0.2";')
replace_once("packaging/fasttab.desktop", "X-AppImage-Version=2.0.1", "X-AppImage-Version=2.0.2")
replace_once(
    "build_packages.sh",
    "- FastTab 2.0.1 preview persistence and latency fixes",
    "- FastTab 2.0.2 cross-workspace preview persistence fix",
)

# Documentation: replace versioned filenames and describe the actual second-stage fix.
for path, chinese in (("README.md", False), ("README.zh-CN.md", True)):
    p = Path(path)
    text = p.read_text(encoding="utf-8").replace("2.0.1", "2.0.2")
    if chinese:
        text = text.replace(
            "FastTab 2.0.2 是稳定性修复版本，主要包括：",
            "FastTab 2.0.2 是跨工作区预览修复版本，主要包括：",
            1,
        )
        text = text.replace(
            "- 修复 Firefox、Vivaldi 等浏览器预览在多次切换后退化为应用图标的问题。",
            "- 在 i3 切换工作区前同步保存当前活动窗口的一张预览，修复 Firefox、Code Desktop、Antigravity 等窗口切换两次后退化为应用图标的问题。",
            1,
        )
    else:
        text = text.replace(
            "FastTab 2.0.2 is a stability release. It includes:",
            "FastTab 2.0.2 is a cross-workspace preview persistence release. It includes:",
            1,
        )
        text = text.replace(
            "- Preserve Firefox, Vivaldi, and other browser previews across repeated switches and transient GLX failures.",
            "- Capture the active window once before i3 changes workspace, preserving Firefox, Code Desktop, Antigravity, and other previews across repeated switches.",
            1,
        )
    p.write_text(text, encoding="utf-8")

# CI and release notes.
ci_path = Path(".github/workflows/ci.yml")
ci = ci_path.read_text(encoding="utf-8").replace("2.0.1", "2.0.2")
ci = ci.replace(
    "          grep -Fq 'fn processSnapshotQueue' src/app.zig\n",
    "          grep -Fq 'fn processSnapshotQueue' src/app.zig\n"
    "          grep -Fq 'switch_origin_snapshot_ready' src/app.zig\n"
    "          grep -Fq 'fn cacheSnapshotForWindow' src/app.zig\n",
    1,
)
old_notes = """          FastTab 2.0.2 is a stability release focused on preview persistence and switcher latency.

          Highlights:

          - Preserves Firefox, Vivaldi, and other browser previews across repeated Alt+Tab and Win+Tab sessions.
          - Keeps the previous cached preview when a transient GLX refresh or reacquire operation fails.
          - No longer removes a tracked window because of a temporary GLX error.
          - Generates fallback snapshots incrementally after the switcher is hidden, eliminating the pause when Alt or Super is released.
          - Replaces unsupported Nerd Font and Powerline private-use title glyphs with a plain separator instead of `?`.
          - Retains x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages.
"""
new_notes = """          FastTab 2.0.2 fixes cross-workspace preview loss under i3.

          Highlights:

          - Captures the real active window once before i3 unmaps it during a workspace switch.
          - Preserves Firefox, Code Desktop, Antigravity, Vivaldi, and other previews across repeated Alt+Tab and Win+Tab sessions.
          - Saves the last valid texture before GLX invalidation and retries transient failures without deleting the cached preview.
          - Keeps exit latency low: only the origin window is captured synchronously; remaining snapshots stay incremental.
          - Retains x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages.
"""
if old_notes not in ci:
    raise SystemExit("ci.yml: expected 2.0.2 release notes block not found")
ci = ci.replace(old_notes, new_notes, 1)
ci_path.write_text(ci, encoding="utf-8")
