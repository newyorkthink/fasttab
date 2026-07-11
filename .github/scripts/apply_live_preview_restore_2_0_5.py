from __future__ import annotations

import re
from pathlib import Path


APP = Path("src/app.zig")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def replace_function(text: str, signature: str, replacement: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"function not found: {signature}")
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"opening brace not found: {signature}")

    depth = 0
    i = brace
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                while end < len(text) and text[end] in " \t":
                    end += 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                return text[:start] + replacement.rstrip() + "\n" + text[end:]
        i += 1
    raise SystemExit(f"closing brace not found: {signature}")


def remove_function(text: str, signature: str) -> str:
    return replace_function(text, signature, "")


def patch_app() -> None:
    text = APP.read_text(encoding="utf-8")

    text = replace_once(
        text,
        """    snapshot_pending: bool,\n    snapshot_cursor: usize,\n""",
        "",
        "remove deferred snapshot fields",
    )
    text = replace_once(
        text,
        """            .snapshot_pending = false,\n            .snapshot_cursor = 0,\n""",
        "",
        "remove deferred snapshot initializers",
    )
    text = replace_once(
        text,
        """            } else {\n                // Build at most one fallback snapshot per hidden frame. This keeps\n                // confirm/cancel paths immediate instead of copying every window at once.\n                self.processSnapshotQueue();\n                std.time.sleep(16 * std.time.ns_per_ms);\n                return;\n            }\n""",
        """            } else {\n                std.time.sleep(16 * std.time.ns_per_ms);\n                return;\n            }\n""",
        "restore hidden idle loop",
    )
    text = replace_once(
        text,
        """            self.updateLayout();\n            if (self.window_hidden) self.scheduleSnapshotRefresh();\n""",
        """            self.updateLayout();\n""",
        "remove deferred snapshot scheduling",
    )

    hide_window = r'''    /// Hide the switcher window. Cache valid frames, then release every
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
'''
    text = replace_function(text, "    pub fn hideWindow(self: *Self) void", hide_window)

    show_window = r'''    /// Show the switcher window (public for socket commands)
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
'''
    text = replace_function(text, "    pub fn showWindow(self: *Self) void", show_window)

    damage = r'''    /// Handle damage using the upstream live-pixmap lifecycle. A stale
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
'''
    text = replace_function(text, "    pub fn handleDamageEvent(self: *Self, drawable: x11.xcb.xcb_window_t) void", damage)

    text = remove_function(text, "    fn refreshViewableThumbnailsForShow(self: *Self) void")
    text = remove_function(text, "    fn scheduleSnapshotRefresh(self: *Self) void")
    text = remove_function(text, "    fn processSnapshotQueue(self: *Self) void")

    cache_window = r'''    /// Ensure one visible origin window has a valid live texture before
    /// taking its fallback frame. This preserves cross-workspace previews without
    /// keeping every GLX pixmap bound while FastTab is hidden.
    fn cacheSnapshotForWindow(self: *Self, window_id: x11.xcb.xcb_window_t) bool {
        const item = self.findItemByWindowId(window_id) orelse return false;

        if (!item.thumbnail_ready {
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
'''
    # Correct Zig syntax before insertion.
    cache_window = cache_window.replace("if (!item.thumbnail_ready {", "if (!item.thumbnail_ready) {")
    text = replace_function(text, "    fn cacheSnapshotForWindow(self: *Self, window_id: x11.xcb.xcb_window_t) bool", cache_window)

    cache_all = r'''    /// Cache all currently valid live thumbnails before releasing their
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

'''
    marker = "    fn cacheSnapshotForWindow(self: *Self, window_id: x11.xcb.xcb_window_t) bool"
    pos = text.find(marker)
    if pos < 0:
        raise SystemExit("cacheSnapshotForWindow marker not found")
    text = text[:pos] + cache_all + text[pos:]

    if "snapshot_pending" in text or "processSnapshotQueue" in text or "refreshViewableThumbnailsForShow" in text:
        raise SystemExit("obsolete preview lifecycle code remains")

    APP.write_text(text, encoding="utf-8")


def update_release_metadata() -> None:
    for name in [
        "VERSION",
        "src/main.zig",
        "packaging/fasttab.desktop",
        "README.md",
        "README.zh-CN.md",
        ".github/workflows/ci.yml",
        "build_packages.sh",
    ]:
        path = Path(name)
        text = path.read_text(encoding="utf-8")
        text = text.replace("2.0.3", "2.0.5").replace("2.0.4", "2.0.5")
        path.write_text(text, encoding="utf-8")

    readme = Path("README.md")
    text = readme.read_text(encoding="utf-8")
    text = re.sub(
        r"FastTab 2\.0\.5 .*?It includes:\n",
        "FastTab 2.0.5 restores the upstream live XComposite/GLX preview lifecycle while preserving the fork's i3 workspace UI. It includes:\n",
        text,
        count=1,
    )
    bullets_start = text.find("- Capture the active window once before i3 changes workspace")
    if bullets_start >= 0:
        bullets_end = text.find("\n\n## Shortcuts", bullets_start)
        if bullets_end < 0:
            raise SystemExit("README bullet section end not found")
        bullets = """- Restore generic live GLX previews for browsers, video, Remmina, and other X11 clients; no per-application capture rules.\n- Release XComposite/GLX pixmap bindings while hidden and reacquire fresh backing pixmaps when FastTab opens.\n- Keep cached snapshots only as cross-workspace or temporarily-unmapped fallbacks.\n- Preserve the current-window default selection, i3 workspace overview, workspace badges, mouse support, and multi-monitor layout.\n- Retain x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages."""
        text = text[:bullets_start] + bullets + text[bullets_end:]
    readme.write_text(text, encoding="utf-8")

    readme_zh = Path("README.zh-CN.md")
    text = readme_zh.read_text(encoding="utf-8")
    text = re.sub(
        r"FastTab 2\.0\.5 .*?主要包括：\n",
        "FastTab 2.0.5 恢复上游通用的 XComposite/GLX 实时预览机制，同时保留本分支的 i3 工作区界面，主要包括：\n",
        text,
        count=1,
    )
    bullets_start = text.find("- 在 i3 切换工作区前同步保存当前活动窗口")
    if bullets_start >= 0:
        bullets_end = text.find("\n\n## 快捷键", bullets_start)
        if bullets_end < 0:
            raise SystemExit("README.zh-CN bullet section end not found")
        bullets = """- 恢复浏览器、视频、Remmina 等所有 X11 客户端共用的 GLX 实时预览，不再按应用名称打补丁。\n- FastTab 隐藏时释放 XComposite/GLX 绑定，再次显示时重新获取最新的窗口 backing pixmap。\n- 缓存截图仅用于跨工作区或窗口暂时未映射时的兜底。\n- 保留默认选中当前窗口、i3 工作区总览、工作区角标、鼠标操作和多显示器布局。\n- 继续提供 x86_64 与 ARM64/AArch64 的 AppImage、DEB 和 RPM 安装包。"""
        text = text[:bullets_start] + bullets + text[bullets_end:]
    readme_zh.write_text(text, encoding="utf-8")

    ci = Path(".github/workflows/ci.yml")
    text = ci.read_text(encoding="utf-8")
    text = text.replace("grep -Fq 'fn processSnapshotQueue' src/app.zig\n", "")
    text = text.replace("grep -Fq 'fn refreshViewableThumbnailsForShow' src/app.zig\n", "")
    text = text.replace("grep -Fq 'preserving cached preview and retrying later' src/app.zig\n", "")
    anchor = "          grep -Fq 'fn cacheSnapshotForWindow' src/app.zig\n"
    checks = """          grep -Fq 'fn cacheSnapshotForWindow' src/app.zig\n          grep -Fq 'self.releaseAllBindings();' src/app.zig\n          grep -Fq 'if (self.window_hidden) return;' src/app.zig\n          grep -Fq 'GLX rebind failed for window' src/app.zig\n"""
    if anchor in text:
        text = text.replace(anchor, checks, 1)

    old_notes = re.compile(
        r"          FastTab 2\.0\.5 .*?          FastTab requires Linux, X11, and hardware-accelerated OpenGL\.\n",
        re.S,
    )
    new_notes = """          FastTab 2.0.5 restores the generic upstream live-preview lifecycle while preserving the fork's i3 workspace features.\n\n          Highlights:\n\n          - Removes application-specific Edge/Remmina/root-framebuffer capture logic.\n          - Releases XComposite/GLX bindings while hidden and reacquires fresh backing pixmaps on show.\n          - Restores dynamic browser, video, and remote-desktop previews through one common path.\n          - Keeps cached snapshots only as cross-workspace and temporarily-unmapped fallbacks.\n          - Retains x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages.\n\n          FastTab requires Linux, X11, and hardware-accelerated OpenGL.\n"""
    text, count = old_notes.subn(new_notes, text, count=1)
    if count != 1:
        raise SystemExit("release notes block not replaced")
    ci.write_text(text, encoding="utf-8")


def main() -> None:
    patch_app()
    update_release_metadata()


if __name__ == "__main__":
    main()
