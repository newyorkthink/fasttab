from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {text.count(old)}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


# Add a root-framebuffer capture fallback for GPU-backed windows whose XComposite
# pixmap is valid but contains only black pixels (Chromium video, Remmina OpenGL,
# remote-desktop surfaces, and similar clients).
x11_marker = """}

/// Raw icon data from _NET_WM_ICON (ARGB u32 pixels)
"""
x11_insert = r''' }

/// CPU-owned RGBA snapshot captured from the composed root framebuffer.
pub const RootCapture = struct {
    pixels: []u8,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RootCapture) void {
        self.allocator.free(self.pixels);
    }
};

fn expandMaskedChannel(pixel: u32, mask: u32) u8 {
    if (mask == 0) return 0;
    const shift: u5 = @intCast(@ctz(mask));
    const channel_max = mask >> shift;
    if (channel_max == 0) return 0;
    const value = (pixel & mask) >> shift;
    return @intCast((value * 255 + channel_max / 2) / channel_max);
}

fn readPackedPixel(data: [*]const u8, offset: usize, bytes_per_pixel: usize, lsb_first: bool) u32 {
    var pixel: u32 = 0;
    if (lsb_first) {
        var i: usize = 0;
        while (i < bytes_per_pixel) : (i += 1) {
            pixel |= @as(u32, data[offset + i]) << @intCast(i * 8);
        }
    } else {
        var i: usize = 0;
        while (i < bytes_per_pixel) : (i += 1) {
            pixel = (pixel << 8) | @as(u32, data[offset + i]);
        }
    }
    return pixel;
}

/// Capture the visible portion of a top-level window from the composed root
/// framebuffer. This is a compatibility fallback for GPU surfaces that appear
/// black through GLX_EXT_texture_from_pixmap even while they are visible.
pub fn captureWindowFromRoot(
    allocator: std.mem.Allocator,
    conn: *Connection,
    window: xcb.xcb_window_t,
) (X11Error || std.mem.Allocator.Error)!RootCapture {
    const geom_cookie = xcb.xcb_get_geometry(conn.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(conn.conn, geom_cookie, null) orelse return error.GeometryFetchFailed;
    defer std.c.free(geom_reply);

    if (geom_reply.*.width == 0 or geom_reply.*.height == 0) return error.InvalidGeometry;

    const translate_cookie = xcb.xcb_translate_coordinates(conn.conn, window, conn.root, 0, 0);
    const translate_reply = xcb.xcb_translate_coordinates_reply(conn.conn, translate_cookie, null) orelse return error.GeometryFetchFailed;
    defer std.c.free(translate_reply);

    const origin_x: i32 = translate_reply.*.dst_x;
    const origin_y: i32 = translate_reply.*.dst_y;
    const root_width: i32 = @intCast(conn.screen.*.width_in_pixels);
    const root_height: i32 = @intCast(conn.screen.*.height_in_pixels);

    const capture_x = @max(@as(i32, 0), origin_x);
    const capture_y = @max(@as(i32, 0), origin_y);
    const capture_right = @min(root_width, origin_x + @as(i32, @intCast(geom_reply.*.width)));
    const capture_bottom = @min(root_height, origin_y + @as(i32, @intCast(geom_reply.*.height)));
    if (capture_right <= capture_x or capture_bottom <= capture_y) return error.InvalidGeometry;

    const width: u16 = @intCast(capture_right - capture_x);
    const height: u16 = @intCast(capture_bottom - capture_y);
    const image = xcb.xcb_image_get(
        conn.conn,
        conn.root,
        @intCast(capture_x),
        @intCast(capture_y),
        width,
        height,
        std.math.maxInt(u32),
        xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
    ) orelse return error.ImageCaptureFailed;
    defer xcb.xcb_image_destroy(image);

    const bytes_per_pixel: usize = (@as(usize, image.*.bpp) + 7) / 8;
    if (bytes_per_pixel < 2 or bytes_per_pixel > 4) return error.ImageCaptureFailed;
    if (image.*.stride < @as(u32, width) * bytes_per_pixel) return error.ImageCaptureFailed;

    const pixel_count = @as(usize, width) * @as(usize, height);
    const rgba = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(rgba);

    const lsb_first = image.*.byte_order == xcb.XCB_IMAGE_ORDER_LSB_FIRST;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_offset = y * @as(usize, image.*.stride);
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixel = readPackedPixel(image.*.data, row_offset + x * bytes_per_pixel, bytes_per_pixel, lsb_first);
            const output = (y * @as(usize, width) + x) * 4;
            rgba[output + 0] = expandMaskedChannel(pixel, conn.screen.*.red_mask);
            rgba[output + 1] = expandMaskedChannel(pixel, conn.screen.*.green_mask);
            rgba[output + 2] = expandMaskedChannel(pixel, conn.screen.*.blue_mask);
            rgba[output + 3] = 255;
        }
    }

    return RootCapture{
        .pixels = rgba,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

/// Raw icon data from _NET_WM_ICON (ARGB u32 pixels)
'''
replace_once("src/x11.zig", x11_marker, x11_insert)

# Track when a last-good root framebuffer snapshot must take precedence over a
# black live GLX pixmap.
replace_once(
    "src/ui.zig",
    """    thumbnail_ready: bool,
    cached_snapshot: ?rl.RenderTexture2D,
    workspace: ?u32 = null,
""",
    """    thumbnail_ready: bool,
    cached_snapshot: ?rl.RenderTexture2D,
    prefer_cached_snapshot: bool,
    workspace: ?u32 = null,
""",
)

old_render = """            if (item.thumbnail_ready) {
                // Use downsample shader for high-quality scaling if available
                if (downsample_shader) |shader| {
                    shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                    shader.end();
                } else {
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                }
            } else if (item.cached_snapshot) |snapshot| {
                // Show cached snapshot of last-known thumbnail while reacquiring.
                // Negate height to flip Y — raylib RenderTextures are rendered bottom-up.
                const snap_src = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(snapshot.texture.width),
                    .height = -@as(f32, @floatFromInt(snapshot.texture.height)),
                };
                rl.DrawTexturePro(snapshot.texture, snap_src, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            } else {
"""
new_render = """            if (item.prefer_cached_snapshot and item.cached_snapshot != null) {
                // Some GPU-backed clients expose a permanently black XComposite
                // pixmap. Prefer the last composed root-framebuffer snapshot.
                const snapshot = item.cached_snapshot.?;
                const snap_src = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(snapshot.texture.width),
                    .height = -@as(f32, @floatFromInt(snapshot.texture.height)),
                };
                rl.DrawTexturePro(snapshot.texture, snap_src, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            } else if (item.thumbnail_ready) {
                // Use downsample shader for high-quality scaling if available
                if (downsample_shader) |shader| {
                    shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                    shader.end();
                } else {
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                }
            } else if (item.cached_snapshot) |snapshot| {
                // Show cached snapshot of last-known thumbnail while reacquiring.
                // Negate height to flip Y — raylib RenderTextures are rendered bottom-up.
                const snap_src = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(snapshot.texture.width),
                    .height = -@as(f32, @floatFromInt(snapshot.texture.height)),
                };
                rl.DrawTexturePro(snapshot.texture, snap_src, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            } else {
"""
replace_once("src/ui.zig", old_render, new_render)

replace_once(
    "src/app.zig",
    """                        .thumbnail_ready = has_texture,
                        .cached_snapshot = null,
                        .workspace = data.workspace,
""",
    """                        .thumbnail_ready = has_texture,
                        .cached_snapshot = null,
                        .prefer_cached_snapshot = false,
                        .workspace = data.workspace,
""",
)

replace_once(
    "src/app.zig",
    "self.switch_origin_snapshot_ready = active_win != 0 and self.cacheSnapshotForWindow(active_win);",
    "self.switch_origin_snapshot_ready = active_win != 0 and self.cacheSwitchOriginSnapshot(active_win);",
)
replace_once(
    "src/app.zig",
    "self.switch_origin_snapshot_ready = self.cacheSnapshotForWindow(active_win);",
    "self.switch_origin_snapshot_ready = self.cacheSwitchOriginSnapshot(active_win);",
)

app_marker = """    fn cacheSnapshotForWindow(self: *Self, window_id: x11.xcb.xcb_window_t) bool {
        const item = self.findItemByWindowId(window_id) orelse return false;
        return self.cacheSnapshotForItem(item);
    }

    fn scheduleSnapshotRefresh(self: *Self) void {
"""
app_insert = r'''    fn cacheSnapshotForWindow(self: *Self, window_id: x11.xcb.xcb_window_t) bool {
        const item = self.findItemByWindowId(window_id) orelse return false;
        return self.cacheSnapshotForItem(item);
    }

    /// Capture the active window before FastTab is mapped. Use the zero-copy GLX
    /// path when it contains real pixels; otherwise fall back to the composed root
    /// framebuffer so Chromium video, Remmina, and other GPU clients are visible.
    fn cacheSwitchOriginSnapshot(self: *Self, window_id: x11.xcb.xcb_window_t) bool {
        const item = self.findItemByWindowId(window_id) orelse return false;
        const live_cached = self.cacheSnapshotForItem(item);
        if (live_cached) {
            if (item.cached_snapshot) |snapshot| {
                if (!snapshotLooksBlank(snapshot)) {
                    item.prefer_cached_snapshot = false;
                    return true;
                }
            }
        }

        if (self.cacheRootSnapshotForItem(item)) {
            item.prefer_cached_snapshot = true;
            return true;
        }

        return live_cached or item.cached_snapshot != null;
    }

    /// Detect the failure mode where a valid GLX texture contains almost no RGB
    /// data. Sampling a downscaled FBO keeps the readback small and bounded.
    fn snapshotLooksBlank(snapshot: rl.RenderTexture2D) bool {
        const image = rl.LoadImageFromTexture(snapshot.texture);
        if (image.data == null or image.width <= 0 or image.height <= 0) return false;
        defer rl.UnloadImage(image);

        const colors = rl.LoadImageColors(image);
        if (colors == null) return false;
        defer rl.UnloadImageColors(colors);

        const total: usize = @intCast(image.width * image.height);
        if (total == 0) return false;
        const step = @max(@as(usize, 1), total / 1024);
        var sampled: usize = 0;
        var visible: usize = 0;
        var index: usize = 0;
        while (index < total) : (index += step) {
            const color = colors[index];
            if (color.r > 12 or color.g > 12 or color.b > 12) visible += 1;
            sampled += 1;
        }

        return sampled > 0 and visible * 1000 < sampled * 5;
    }

    fn cacheRootSnapshotForItem(self: *Self, item: *ui.DisplayWindow) bool {
        if (item.display_width == 0 or item.display_height == 0) return false;

        var capture = x11.captureWindowFromRoot(self.allocator, self.conn, item.id) catch |err| {
            log.debug("Root framebuffer capture failed for window {x}: {}", .{ item.id, err });
            return false;
        };
        defer capture.deinit();

        const image = rl.Image{
            .data = capture.pixels.ptr,
            .width = @intCast(capture.width),
            .height = @intCast(capture.height),
            .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
            .mipmaps = 1,
        };
        const texture = rl.LoadTextureFromImage(image);
        if (texture.id == 0) return false;
        defer rl.UnloadTexture(texture);
        rl.SetTextureFilter(texture, rl.TEXTURE_FILTER_BILINEAR);

        const rt = rl.LoadRenderTexture(@intCast(item.display_width), @intCast(item.display_height));
        if (rt.id == 0) return false;

        const source_rect = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(texture.width),
            .height = @floatFromInt(texture.height),
        };
        const dest_rect = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(item.display_width),
            .height = @floatFromInt(item.display_height),
        };

        rl.BeginTextureMode(rt);
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
        if (self.downsample_shader) |*shader| {
            shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
            rl.DrawTexturePro(texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            shader.end();
        } else {
            rl.DrawTexturePro(texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
        }
        rl.EndTextureMode();

        if (item.cached_snapshot) |previous| {
            rl.UnloadRenderTexture(previous);
        }
        item.cached_snapshot = rt;
        log.debug("Using composed root snapshot for black GLX window {x}", .{item.id});
        return true;
    }

    fn scheduleSnapshotRefresh(self: *Self) void {
'''
replace_once("src/app.zig", app_marker, app_insert)

replace_once(
    "src/app.zig",
    """        rl.EndTextureMode();

        if (item.cached_snapshot) |previous| {
""",
    """        rl.EndTextureMode();

        // Never let a known-black live pixmap overwrite a good root snapshot.
        if (item.prefer_cached_snapshot and snapshotLooksBlank(rt)) {
            rl.UnloadRenderTexture(rt);
            return false;
        }
        if (item.prefer_cached_snapshot) item.prefer_cached_snapshot = false;

        if (item.cached_snapshot) |previous| {
""",
)

# Release as 2.0.4.
Path("VERSION").write_text("2.0.4\n", encoding="utf-8")
replace_once("src/main.zig", 'const FASTTAB_VERSION = "2.0.3";', 'const FASTTAB_VERSION = "2.0.4";')
replace_once("packaging/fasttab.desktop", "X-AppImage-Version=2.0.3", "X-AppImage-Version=2.0.4")

replace_once(
    "README.md",
    """## FastTab 2.0.2

FastTab 2.0.2 is a cross-workspace preview persistence release. It includes:

- Capture the active window once before i3 changes workspace, preserving Firefox, Code Desktop, Antigravity, and other previews across repeated switches.
""",
    """## FastTab 2.0.4

FastTab 2.0.4 fixes black previews from GPU-backed X11 clients while retaining the previous Firefox and i3 fixes. It includes:

- Detect nearly empty GLX thumbnails and capture the active window from the composed root framebuffer instead.
- Preserve Chromium/Edge video, Remmina, remote-desktop, and similar GPU-rendered previews after switching workspaces.
- Capture the active window once before i3 changes workspace, preserving Firefox, Code Desktop, Antigravity, and other previews across repeated switches.
""",
)
replace_once(
    "README.md",
    "FastTab-2.0.2-x86_64.AppImage",
    "FastTab-2.0.4-x86_64.AppImage",
)
replace_once("README.md", "fasttab_2.0.2_amd64.deb", "fasttab_2.0.4_amd64.deb")
replace_once("README.md", "fasttab_2.0.2_arm64.deb", "fasttab_2.0.4_arm64.deb")
replace_once("README.md", "fasttab-2.0.2-1.x86_64.rpm", "fasttab-2.0.4-1.x86_64.rpm")

replace_once(
    "README.zh-CN.md",
    """## FastTab 2.0.2

FastTab 2.0.2 是跨工作区预览修复版本，主要包括：

- 在 i3 切换工作区前同步保存当前活动窗口的一张预览，修复 Firefox、Code Desktop、Antigravity 等窗口切换两次后退化为应用图标的问题。
""",
    """## FastTab 2.0.4

FastTab 2.0.4 修复 GPU 渲染类 X11 客户端的黑屏预览，并保留此前的 Firefox 与 i3 修复，主要包括：

- 检测接近全黑的 GLX 缩略图，并从已合成的根窗口画面捕获当前活动窗口。
- 修复 Chromium/Edge 视频、Remmina、远程桌面等 GPU 渲染窗口的黑屏预览。
- 在 i3 切换工作区前同步保存当前活动窗口的一张预览，修复 Firefox、Code Desktop、Antigravity 等窗口切换两次后退化为应用图标的问题。
""",
)
replace_once("README.zh-CN.md", "FastTab-2.0.2-x86_64.AppImage", "FastTab-2.0.4-x86_64.AppImage")
replace_once("README.zh-CN.md", "fasttab_2.0.2_amd64.deb", "fasttab_2.0.4_amd64.deb")
replace_once("README.zh-CN.md", "fasttab_2.0.2_arm64.deb", "fasttab_2.0.4_arm64.deb")
replace_once("README.zh-CN.md", "fasttab-2.0.2-1.x86_64.rpm", "fasttab-2.0.4-1.x86_64.rpm")

replace_once(".github/workflows/ci.yml", '[[ "$VERSION" == "2.0.3" ]]', '[[ "$VERSION" == "2.0.4" ]]')
replace_once(
    ".github/workflows/ci.yml",
    """          grep -Fq 'fn refreshViewableThumbnailsForShow' src/app.zig
          grep -Fq 'preserving cached preview and retrying later' src/app.zig
""",
    """          grep -Fq 'fn refreshViewableThumbnailsForShow' src/app.zig
          grep -Fq 'captureWindowFromRoot' src/x11.zig
          grep -Fq 'prefer_cached_snapshot' src/app.zig
          grep -Fq 'preserving cached preview and retrying later' src/app.zig
""",
)
replace_once(
    ".github/workflows/ci.yml",
    """          FastTab 2.0.3 fixes transparent Firefox previews and retains the i3 cross-workspace preview corrections.

          Highlights:

          - Forces rendered window-thumbnail alpha to opaque when Firefox exposes valid RGB pixels with a zero or undefined alpha channel.
          - Captures the real active window once before i3 unmaps it during a workspace switch.
          - Preserves Firefox, Code Desktop, Antigravity, Vivaldi, and other previews across repeated Alt+Tab and Win+Tab sessions.
          - Keeps exit latency low and retains x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages.
""",
    """          FastTab 2.0.4 fixes black previews from GPU-backed X11 clients and retains the Firefox and i3 corrections.

          Highlights:

          - Detects nearly empty GLX thumbnails and captures the active window from the composed root framebuffer.
          - Restores Chromium/Edge video, Remmina, remote-desktop, and similar GPU-rendered previews.
          - Retains Firefox alpha handling and cross-workspace preview persistence under i3.
          - Keeps x86_64 and ARM64/AArch64 AppImage, DEB, and RPM packages.
""",
)
