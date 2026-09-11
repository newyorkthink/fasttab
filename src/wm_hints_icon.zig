const std = @import("std");
const x11 = @import("x11.zig");

const xcb = x11.xcb;

const ICON_PIXMAP_HINT: u32 = 1 << 2;
const ICON_MASK_HINT: u32 = 1 << 5;
const MAX_ICON_DIMENSION: u16 = 4096;
const MAX_ICON_PIXELS: u64 = 16 * 1024 * 1024;

const WmHintsIcon = struct {
    pixmap: xcb.xcb_pixmap_t,
    mask: xcb.xcb_pixmap_t,
};

const VisualMasks = struct {
    red: u32,
    green: u32,
    blue: u32,
};

fn internAtom(conn: *xcb.xcb_connection_t, name: []const u8) ?xcb.xcb_atom_t {
    const cookie = xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    return reply.*.atom;
}

fn parseWmHints(values: []const u32) ?WmHintsIcon {
    if (values.len < 4) return null;

    const flags = values[0];
    if ((flags & ICON_PIXMAP_HINT) == 0 or values[3] == 0) return null;

    const mask: xcb.xcb_pixmap_t = if (values.len >= 8 and (flags & ICON_MASK_HINT) != 0)
        @intCast(values[7])
    else
        0;

    return .{
        .pixmap = @intCast(values[3]),
        .mask = mask,
    };
}

fn getWmHintsIcon(conn: *xcb.xcb_connection_t, window: xcb.xcb_window_t) ?WmHintsIcon {
    const wm_hints = internAtom(conn, "WM_HINTS") orelse return null;
    const cookie = xcb.xcb_get_property(
        conn,
        0,
        window,
        wm_hints,
        xcb.XCB_GET_PROPERTY_TYPE_ANY,
        0,
        9,
    );
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);

    const byte_len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
    if (reply.*.format != 32 or byte_len < 4 * @sizeOf(u32)) return null;

    const values_ptr: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    return parseWmHints(values_ptr[0 .. byte_len / @sizeOf(u32)]);
}

fn rootVisualMasks(screen: *xcb.xcb_screen_t) ?VisualMasks {
    var depth_iter = xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (xcb.xcb_depth_next(&depth_iter)) {
        const depth = depth_iter.data orelse continue;
        var visual_iter = xcb.xcb_depth_visuals_iterator(depth);
        while (visual_iter.rem > 0) : (xcb.xcb_visualtype_next(&visual_iter)) {
            const visual = visual_iter.data orelse continue;
            if (visual.*.visual_id == screen.*.root_visual) {
                return .{
                    .red = visual.*.red_mask,
                    .green = visual.*.green_mask,
                    .blue = visual.*.blue_mask,
                };
            }
        }
    }
    return null;
}

fn channelFromMask(pixel: u32, mask: u32) u8 {
    if (mask == 0) return 0;
    const shift: u5 = @intCast(@ctz(mask));
    const component_max = mask >> shift;
    const component = (pixel & mask) >> shift;
    if (component_max == 0) return 0;

    const scaled = (@as(u64, component) * 255 + @as(u64, component_max) / 2) / @as(u64, component_max);
    return @intCast(scaled);
}

fn pixelToArgb(pixel: u32, depth: u8, masks: ?VisualMasks, alpha: u8) u32 {
    if (depth == 1) {
        const level: u8 = if ((pixel & 1) != 0) 255 else 0;
        return (@as(u32, alpha) << 24) |
            (@as(u32, level) << 16) |
            (@as(u32, level) << 8) |
            @as(u32, level);
    }

    const m = masks orelse return @as(u32, alpha) << 24;
    const red = channelFromMask(pixel, m.red);
    const green = channelFromMask(pixel, m.green);
    const blue = channelFromMask(pixel, m.blue);
    return (@as(u32, alpha) << 24) |
        (@as(u32, red) << 16) |
        (@as(u32, green) << 8) |
        @as(u32, blue);
}

fn getPixmapGeometry(conn: *xcb.xcb_connection_t, pixmap: xcb.xcb_pixmap_t) ?struct { width: u16, height: u16, depth: u8 } {
    const cookie = xcb.xcb_get_geometry(conn, pixmap);
    var err: ?*xcb.xcb_generic_error_t = null;
    const reply = xcb.xcb_get_geometry_reply(conn, cookie, &err);
    if (err) |xcb_err| {
        std.c.free(xcb_err);
        return null;
    }
    if (reply == null) return null;
    defer std.c.free(reply);

    if (reply.*.width == 0 or reply.*.height == 0) return null;
    if (reply.*.width > MAX_ICON_DIMENSION or reply.*.height > MAX_ICON_DIMENSION) return null;

    return .{
        .width = reply.*.width,
        .height = reply.*.height,
        .depth = reply.*.depth,
    };
}

/// ICCCM fallback matching alttab's addIconFromHints(): read IconPixmapHint and
/// optional IconMaskHint when desktop/AppImage/_NET_WM_ICON did not provide an icon.
/// This uses only the worker's XCB connection, so it does not introduce Xlib calls
/// on the background thread.
pub fn getWindowIcon(
    allocator: std.mem.Allocator,
    conn: *x11.Connection,
    window: xcb.xcb_window_t,
) ?x11.IconData {
    const hints = getWmHintsIcon(conn.conn, window) orelse return null;
    const geometry = getPixmapGeometry(conn.conn, hints.pixmap) orelse return null;

    const pixel_count_u64 = @as(u64, geometry.width) * @as(u64, geometry.height);
    if (pixel_count_u64 == 0 or pixel_count_u64 > MAX_ICON_PIXELS) return null;
    const pixel_count: usize = @intCast(pixel_count_u64);

    const image = xcb.xcb_image_get(
        conn.conn,
        hints.pixmap,
        0,
        0,
        geometry.width,
        geometry.height,
        std.math.maxInt(u32),
        xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
    ) orelse return null;
    defer xcb.xcb_image_destroy(image);

    var mask_image: ?*xcb.xcb_image_t = null;
    defer if (mask_image) |mask| xcb.xcb_image_destroy(mask);

    if (hints.mask != 0) {
        if (getPixmapGeometry(conn.conn, hints.mask)) |mask_geometry| {
            if (mask_geometry.width >= geometry.width and mask_geometry.height >= geometry.height) {
                mask_image = xcb.xcb_image_get(
                    conn.conn,
                    hints.mask,
                    0,
                    0,
                    geometry.width,
                    geometry.height,
                    std.math.maxInt(u32),
                    xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
                );
            }
        }
    }

    const masks: ?VisualMasks = if (geometry.depth == 1) null else rootVisualMasks(conn.screen) orelse return null;
    const pixels = allocator.alloc(u32, pixel_count) catch return null;

    var y: u32 = 0;
    while (y < geometry.height) : (y += 1) {
        var x: u32 = 0;
        while (x < geometry.width) : (x += 1) {
            const pixel = xcb.xcb_image_get_pixel(image, x, y);
            const alpha: u8 = if (mask_image) |mask|
                if (xcb.xcb_image_get_pixel(mask, x, y) == 0) 0 else 255
            else
                255;
            const index: usize = @as(usize, @intCast(y)) * @as(usize, geometry.width) + @as(usize, @intCast(x));
            pixels[index] = pixelToArgb(pixel, geometry.depth, masks, alpha);
        }
    }

    return .{
        .data = pixels,
        .width = geometry.width,
        .height = geometry.height,
        .allocator = allocator,
    };
}

test "WM_HINTS parser requires IconPixmapHint and preserves optional mask" {
    const with_mask = [_]u32{
        ICON_PIXMAP_HINT | ICON_MASK_HINT,
        0,
        0,
        0x1234,
        0,
        0,
        0,
        0x5678,
        0,
    };
    const parsed = parseWmHints(&with_mask) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(xcb.xcb_pixmap_t, 0x1234), parsed.pixmap);
    try std.testing.expectEqual(@as(xcb.xcb_pixmap_t, 0x5678), parsed.mask);

    const no_pixmap_flag = [_]u32{ 0, 0, 0, 0x1234 };
    try std.testing.expect(parseWmHints(&no_pixmap_flag) == null);
}

test "visual mask channel scaling handles common TrueColor masks" {
    try std.testing.expectEqual(@as(u8, 0x12), channelFromMask(0x00123456, 0x00ff0000));
    try std.testing.expectEqual(@as(u8, 0x34), channelFromMask(0x00123456, 0x0000ff00));
    try std.testing.expectEqual(@as(u8, 0x56), channelFromMask(0x00123456, 0x000000ff));
}
