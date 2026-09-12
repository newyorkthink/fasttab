const std = @import("std");
const app = @import("app.zig");
const x11 = @import("x11.zig");
const ui = @import("ui.zig");

const rl = ui.rl;

/// Keeps last-known previews while FastTab stays hidden. The focused window gets
/// activation/final-frame handling, while other currently viewable windows with no
/// cache are filled incrementally. GLX/XComposite bindings are held only long enough
/// to prepare or copy one frame, then released immediately.
pub const Tracker = struct {
    active_window: x11.xcb.xcb_window_t = 0,
    settle_frames: u8 = 0,
    activation_capture_done: bool = false,
    damage_seen: bool = false,
    sweep_cursor: usize = 0,

    const SETTLE_FRAMES: u8 = 2;

    pub fn seed(self: *Tracker, application: *app.App) void {
        if (!application.window_hidden or application.state != .idle) return;
        const wid = x11.getActiveWindow(application.conn.conn, application.conn.root, application.conn.atoms);
        if (wid != 0) self.switchTo(application, wid);
    }

    pub fn handleActiveWindowChanged(self: *Tracker, application: *app.App) void {
        if (!application.window_hidden or application.state != .idle) return;
        const wid = x11.getActiveWindow(application.conn.conn, application.conn.root, application.conn.atoms);
        if (wid != 0) self.switchTo(application, wid);
    }

    pub fn noteDamage(self: *Tracker, drawable: x11.xcb.xcb_window_t) void {
        if (drawable == self.active_window and drawable != 0) {
            self.damage_seen = true;
        }
    }

    /// Called once per daemon loop before App.update(). Keep the focused window
    /// semantics from the activation tracker, then use any spare pass to fill one
    /// missing snapshot for another currently viewable window on the same visible
    /// workspace. Every capture releases its GLX/XComposite binding immediately.
    pub fn update(self: *Tracker, application: *app.App) void {
        if (!application.window_hidden or application.state != .idle) return;

        const current = x11.getActiveWindow(application.conn.conn, application.conn.root, application.conn.atoms);
        if (current != 0 and current != self.active_window) {
            self.switchTo(application, current);
        }

        var copied_this_pass = false;
        if (self.active_window != 0 and !self.activation_capture_done) {
            if (self.settle_frames > 0) {
                self.settle_frames -= 1;
            } else if (findItem(application, self.active_window)) |item| {
                const has_snapshot = item.cached_snapshot != null;
                if (shouldCaptureOnActivation(has_snapshot, self.damage_seen)) {
                    if (captureWindow(application, self.active_window)) {
                        self.activation_capture_done = true;
                        self.damage_seen = false;
                        copied_this_pass = true;
                    }
                } else {
                    self.activation_capture_done = true;
                }
            }
        }

        if (!copied_this_pass) {
            _ = self.captureOneMissingVisibleWindow(application);
        }
    }

    fn captureOneMissingVisibleWindow(self: *Tracker, application: *app.App) bool {
        const count = application.items.items.len;
        if (count == 0) return false;

        const start = self.sweep_cursor % count;
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const index = (start + offset) % count;
            self.sweep_cursor = (index + 1) % count;

            const item = &application.items.items[index];
            const is_active = item.id == self.active_window;
            if (!shouldSweepMissingSnapshot(
                item.cached_snapshot != null,
                is_active,
                self.activation_capture_done,
                x11.isWindowViewable(application.conn.conn, item.id),
            )) continue;

            return captureWindow(application, item.id);
        }

        return false;
    }

    fn switchTo(self: *Tracker, application: *app.App, wid: x11.xcb.xcb_window_t) void {
        if (wid == 0 or wid == self.active_window) return;

        // If the previous active window changed after its activation snapshot, use
        // the last moment while it is still viewable to refresh the cached frame.
        if (self.active_window != 0) {
            if (findItem(application, self.active_window)) |previous| {
                if (previous.cached_snapshot == null or self.damage_seen) {
                    _ = captureWindow(application, self.active_window);
                }
            }
        }

        self.active_window = wid;
        self.settle_frames = SETTLE_FRAMES;
        self.activation_capture_done = false;
        self.damage_seen = false;

        // Install/retain the Damage monitor as early as possible, but never keep
        // the window's composite pixmap bound while FastTab is hidden.
        _ = prepareWindow(application, wid);
    }

    fn findItem(application: *app.App, wid: x11.xcb.xcb_window_t) ?*ui.DisplayWindow {
        for (application.items.items) |*item| {
            if (item.id == wid) return item;
        }
        return null;
    }

    fn ensureTexture(application: *app.App, wid: x11.xcb.xcb_window_t) ?*x11.WindowTexture {
        if (!x11.isWindowViewable(application.conn.conn, wid)) return null;

        if (application.window_textures.getPtr(wid)) |tex| {
            if (!tex.bound and !tex.reacquire(application.conn)) return null;
            return tex;
        }

        const created = x11.createWindowTexture(application.conn, wid) catch return null;
        application.window_textures.put(wid, created) catch {
            var to_free = created;
            to_free.deinit(application.conn);
            return null;
        };
        return application.window_textures.getPtr(wid);
    }

    fn syncDimensions(item: *ui.DisplayWindow, tex: *const x11.WindowTexture) void {
        item.source_width = tex.width;
        item.source_height = tex.height;
        if (item.display_width == 0 or item.display_height == 0) {
            const size = ui.calculateThumbnailSize(
                @as(u32, tex.width),
                @as(u32, tex.height),
                ui.MAX_THUMBNAIL_WIDTH,
                ui.THUMBNAIL_HEIGHT,
            );
            item.display_width = size.width;
            item.display_height = size.height;
        }
    }

    fn prepareWindow(application: *app.App, wid: x11.xcb.xcb_window_t) bool {
        const item = findItem(application, wid) orelse return false;
        const tex = ensureTexture(application, wid) orelse return false;
        syncDimensions(item, tex);
        item.thumbnail_texture = tex.toRaylibTexture();
        item.thumbnail_ready = false;
        if (tex.bound) tex.release(application.conn);
        return true;
    }

    fn captureWindow(application: *app.App, wid: x11.xcb.xcb_window_t) bool {
        const item = findItem(application, wid) orelse return false;
        if (!x11.isWindowViewable(application.conn.conn, wid)) return false;

        const tex = ensureTexture(application, wid) orelse return false;
        defer {
            if (tex.bound) tex.release(application.conn);
            item.thumbnail_ready = false;
        }

        syncDimensions(item, tex);
        if (item.display_width == 0 or item.display_height == 0) return false;

        const source_texture = tex.toRaylibTexture();
        item.thumbnail_texture = source_texture;

        const rt = rl.LoadRenderTexture(@intCast(item.display_width), @intCast(item.display_height));
        if (rt.id == 0) return false;

        const source_rect = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(source_texture.width),
            .height = @floatFromInt(source_texture.height),
        };
        const dest_rect = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(item.display_width),
            .height = @floatFromInt(item.display_height),
        };

        rl.BeginTextureMode(rt);
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        if (application.downsample_shader) |*shader| {
            shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
            rl.DrawTexturePro(source_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            shader.end();
        } else {
            rl.DrawTexturePro(source_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
        }
        rl.EndTextureMode();

        if (item.cached_snapshot) |previous| {
            rl.UnloadRenderTexture(previous);
        }
        item.cached_snapshot = rt;
        return true;
    }
};

fn shouldCaptureOnActivation(has_snapshot: bool, damage_seen: bool) bool {
    return !has_snapshot or damage_seen;
}

fn shouldSweepMissingSnapshot(
    has_snapshot: bool,
    is_active: bool,
    active_capture_done: bool,
    is_viewable: bool,
) bool {
    return !has_snapshot and is_viewable and (!is_active or active_capture_done);
}

test "hidden first visit can create a preview without damage" {
    try std.testing.expect(shouldCaptureOnActivation(false, false));
}

test "existing hidden preview is only replaced after damage" {
    try std.testing.expect(!shouldCaptureOnActivation(true, false));
    try std.testing.expect(shouldCaptureOnActivation(true, true));
}

test "hidden sweep fills unfocused visible siblings without overwriting cache" {
    try std.testing.expect(shouldSweepMissingSnapshot(false, false, false, true));
    try std.testing.expect(!shouldSweepMissingSnapshot(true, false, false, true));
    try std.testing.expect(!shouldSweepMissingSnapshot(false, false, false, false));
}

test "hidden sweep waits for the active window settle capture" {
    try std.testing.expect(!shouldSweepMissingSnapshot(false, true, false, true));
    try std.testing.expect(shouldSweepMissingSnapshot(false, true, true, true));
}
