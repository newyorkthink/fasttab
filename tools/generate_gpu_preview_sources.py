#!/usr/bin/env python3
from __future__ import annotations

import shutil
import sys
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_gpu_preview_sources.py OUTPUT_DIR")

    source_dir = Path("src")
    output_dir = Path(sys.argv[1])
    if output_dir.exists():
        shutil.rmtree(output_dir)
    shutil.copytree(source_dir, output_dir)

    x11 = output_dir / "x11.zig"

    replace_once(
        x11,
        """    texture_format: c_int,
    bound: bool,
""",
        """    texture_format: c_int,
    bound: bool,
    root_capture: bool = false,
""",
    )

    replace_once(
        x11,
        """    pub fn deinit(self: *WindowTexture, conn: *Connection) void {
        if (self.gl_display) |display| {
            clearGlxError(display);
            if (self.bound) {
                conn.glx_release.?(display, self.glx_pixmap, xlib.GLX_FRONT_LEFT_EXT);
            }
            xlib.glDeleteTextures(1, &self.gl_texture);
            xlib.glXDestroyPixmap(display, self.glx_pixmap);
            _ = xlib.XSync(display, xlib.False);
        }
        _ = xcb.xcb_free_pixmap(conn.conn, self.pixmap);
        _ = xcb.xcb_damage_destroy(conn.conn, self.damage);
    }
""",
        """    pub fn deinit(self: *WindowTexture, conn: *Connection) void {
        if (self.root_capture) {
            xlib.glDeleteTextures(1, &self.gl_texture);
            _ = xcb.xcb_damage_destroy(conn.conn, self.damage);
            return;
        }

        if (self.gl_display) |display| {
            clearGlxError(display);
            if (self.bound) {
                conn.glx_release.?(display, self.glx_pixmap, xlib.GLX_FRONT_LEFT_EXT);
            }
            xlib.glDeleteTextures(1, &self.gl_texture);
            xlib.glXDestroyPixmap(display, self.glx_pixmap);
            _ = xlib.XSync(display, xlib.False);
        }
        _ = xcb.xcb_free_pixmap(conn.conn, self.pixmap);
        _ = xcb.xcb_damage_destroy(conn.conn, self.damage);
    }
""",
    )

    replace_once(
        x11,
        """    pub fn release(self: *WindowTexture, conn: *Connection) void {
        const display = self.gl_display orelse return;
""",
        """    pub fn release(self: *WindowTexture, conn: *Connection) void {
        if (self.root_capture) {
            self.bound = false;
            return;
        }

        const display = self.gl_display orelse return;
""",
    )

    replace_once(
        x11,
        """    pub fn invalidate(self: *WindowTexture, conn: *Connection) void {
        if (!self.bound) return;
""",
        """    pub fn invalidate(self: *WindowTexture, conn: *Connection) void {
        if (self.root_capture) {
            self.bound = false;
            return;
        }
        if (!self.bound) return;
""",
    )

    replace_once(
        x11,
        """    pub fn reacquire(self: *WindowTexture, conn: *Connection) bool {
        const display = self.gl_display orelse return false;
        if (self.bound) return true;
""",
        """    pub fn reacquire(self: *WindowTexture, conn: *Connection) bool {
        if (self.root_capture) {
            if (self.bound) return true;
            var width = self.width;
            var height = self.height;
            if (!uploadWindowFromRoot(conn, self.window_id, self.gl_texture, &width, &height)) {
                log.debug("Root capture refresh failed for window {x}", .{self.window_id});
                return false;
            }
            self.width = width;
            self.height = height;
            self.bound = true;
            return true;
        }

        const display = self.gl_display orelse return false;
        if (self.bound) return true;
""",
    )

    replace_once(
        x11,
        """    pub fn rebind(self: *WindowTexture, conn: *Connection) bool {
        const display = self.gl_display orelse return false;
""",
        """    pub fn rebind(self: *WindowTexture, conn: *Connection) bool {
        // Root-captured previews are refreshed before FastTab is mapped. Do not
        // capture again while the switcher itself is covering the desktop.
        if (self.root_capture) return true;

        const display = self.gl_display orelse return false;
""",
    )

    helper_marker = """/// Create a GLX texture bound to a window's pixmap (zero-copy thumbnail).
"""
    helper_code = r'''fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var offset: usize = 0;
    while (offset + needle.len <= haystack.len) : (offset += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[offset .. offset + needle.len], needle)) return true;
    }
    return false;
}

fn shouldUseRootCapture(conn: *Connection, window: xcb.xcb_window_t) bool {
    const allocator = std.heap.c_allocator;
    const class = getWindowClass(allocator, conn.conn, window, conn.atoms);
    defer {
        if (!std.mem.eql(u8, class, "(unknown)")) allocator.free(class);
    }

    return containsAsciiIgnoreCase(class, "microsoft-edge") or
        containsAsciiIgnoreCase(class, "msedge") or
        containsAsciiIgnoreCase(class, "remmina");
}

fn expandRootChannel(pixel: u32, mask: u32) u8 {
    if (mask == 0) return 0;
    const shift: u5 = @intCast(@ctz(mask));
    const channel_max = mask >> shift;
    if (channel_max == 0) return 0;
    const value = (pixel & mask) >> shift;
    return @intCast((value * 255 + channel_max / 2) / channel_max);
}

fn readRootPixel(data: [*]const u8, offset: usize, bytes_per_pixel: usize, lsb_first: bool) u32 {
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

/// Upload the visible, already-composited window rectangle from the root
/// framebuffer into an ordinary OpenGL texture. This avoids permanently black
/// XComposite pixmaps produced by Chromium video and Remmina GPU surfaces.
fn uploadWindowFromRoot(
    conn: *Connection,
    window: xcb.xcb_window_t,
    gl_texture: c_uint,
    width_out: *u16,
    height_out: *u16,
) bool {
    const geom_cookie = xcb.xcb_get_geometry(conn.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(conn.conn, geom_cookie, null) orelse return false;
    defer std.c.free(geom_reply);
    if (geom_reply.*.width == 0 or geom_reply.*.height == 0) return false;

    const translate_cookie = xcb.xcb_translate_coordinates(conn.conn, window, conn.root, 0, 0);
    const translate_reply = xcb.xcb_translate_coordinates_reply(conn.conn, translate_cookie, null) orelse return false;
    defer std.c.free(translate_reply);

    const origin_x: i32 = @intCast(translate_reply.*.dst_x);
    const origin_y: i32 = @intCast(translate_reply.*.dst_y);
    const root_width: i32 = @intCast(conn.screen.*.width_in_pixels);
    const root_height: i32 = @intCast(conn.screen.*.height_in_pixels);
    const left = @max(@as(i32, 0), origin_x);
    const top = @max(@as(i32, 0), origin_y);
    const right = @min(root_width, origin_x + @as(i32, @intCast(geom_reply.*.width)));
    const bottom = @min(root_height, origin_y + @as(i32, @intCast(geom_reply.*.height)));
    if (right <= left or bottom <= top) return false;

    const width: u16 = @intCast(right - left);
    const height: u16 = @intCast(bottom - top);
    const image = xcb.xcb_image_get(
        conn.conn,
        conn.root,
        @intCast(left),
        @intCast(top),
        width,
        height,
        std.math.maxInt(u32),
        xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
    ) orelse return false;
    defer xcb.xcb_image_destroy(image);

    const bytes_per_pixel: usize = (@as(usize, image.*.bpp) + 7) / 8;
    if (bytes_per_pixel < 2 or bytes_per_pixel > 4) return false;
    if (@as(usize, image.*.stride) < @as(usize, width) * bytes_per_pixel) return false;

    const allocator = std.heap.c_allocator;
    const pixel_count = @as(usize, width) * @as(usize, height);
    const rgba = allocator.alloc(u8, pixel_count * 4) catch return false;
    defer allocator.free(rgba);

    const raw: [*]const u8 = @ptrCast(image.*.data);
    const lsb_first = image.*.byte_order == xcb.XCB_IMAGE_ORDER_LSB_FIRST;
    var y: usize = 0;
    while (y < @as(usize, height)) : (y += 1) {
        const row_offset = y * @as(usize, image.*.stride);
        var x: usize = 0;
        while (x < @as(usize, width)) : (x += 1) {
            const pixel = readRootPixel(raw, row_offset + x * bytes_per_pixel, bytes_per_pixel, lsb_first);
            const output = (y * @as(usize, width) + x) * 4;
            rgba[output + 0] = expandRootChannel(pixel, conn.screen.*.red_mask);
            rgba[output + 1] = expandRootChannel(pixel, conn.screen.*.green_mask);
            rgba[output + 2] = expandRootChannel(pixel, conn.screen.*.blue_mask);
            rgba[output + 3] = 255;
        }
    }

    xlib.glBindTexture(xlib.GL_TEXTURE_2D, gl_texture);
    xlib.glPixelStorei(xlib.GL_UNPACK_ALIGNMENT, 1);
    xlib.glTexParameteri(xlib.GL_TEXTURE_2D, xlib.GL_TEXTURE_MIN_FILTER, xlib.GL_LINEAR);
    xlib.glTexParameteri(xlib.GL_TEXTURE_2D, xlib.GL_TEXTURE_MAG_FILTER, xlib.GL_LINEAR);
    xlib.glTexParameteri(xlib.GL_TEXTURE_2D, xlib.GL_TEXTURE_WRAP_S, xlib.GL_CLAMP_TO_EDGE);
    xlib.glTexParameteri(xlib.GL_TEXTURE_2D, xlib.GL_TEXTURE_WRAP_T, xlib.GL_CLAMP_TO_EDGE);
    xlib.glTexImage2D(
        xlib.GL_TEXTURE_2D,
        0,
        @intCast(xlib.GL_RGBA),
        @intCast(width),
        @intCast(height),
        0,
        xlib.GL_RGBA,
        xlib.GL_UNSIGNED_BYTE,
        @ptrCast(rgba.ptr),
    );
    xlib.glBindTexture(xlib.GL_TEXTURE_2D, 0);

    width_out.* = width;
    height_out.* = height;
    return true;
}

/// Create a GLX texture bound to a window's pixmap (zero-copy thumbnail).
'''
    replace_once(x11, helper_marker, helper_code)

    replace_once(
        x11,
        """    xlib.glTexParameteri(xlib.GL_TEXTURE_2D, xlib.GL_TEXTURE_WRAP_T, xlib.GL_CLAMP_TO_EDGE);
    xlib.glBindTexture(xlib.GL_TEXTURE_2D, 0);

    // Acquire pixmap binding (composite pixmap + GLX pixmap + bind)
""",
        """    xlib.glTexParameteri(xlib.GL_TEXTURE_2D, xlib.GL_TEXTURE_WRAP_T, xlib.GL_CLAMP_TO_EDGE);
    xlib.glBindTexture(xlib.GL_TEXTURE_2D, 0);

    if (shouldUseRootCapture(conn, window)) {
        var capture_width = width;
        var capture_height = height;
        if (!uploadWindowFromRoot(conn, window, gl_texture, &capture_width, &capture_height)) {
            xlib.glDeleteTextures(1, &gl_texture);
            return error.ImageCaptureFailed;
        }

        const damage = xcb.xcb_generate_id(conn.conn);
        _ = xcb.xcb_damage_create(conn.conn, damage, window, xcb.XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
        log.debug("Using root-framebuffer preview for GPU-backed window {x}", .{window});
        return WindowTexture{
            .window_id = window,
            .visual_id = visual_id,
            .width = capture_width,
            .height = capture_height,
            .pixmap = 0,
            .glx_pixmap = 0,
            .gl_texture = gl_texture,
            .damage = damage,
            .gl_display = gl_display,
            .texture_format = xlib.GLX_TEXTURE_FORMAT_RGBA_EXT,
            .bound = true,
            .root_capture = true,
        };
    }

    // Acquire pixmap binding (composite pixmap + GLX pixmap + bind)
""",
    )

    replace_once(
        output_dir / "main.zig",
        'const FASTTAB_VERSION = "2.0.3";',
        'const FASTTAB_VERSION = "2.0.4";',
    )


if __name__ == "__main__":
    main()
