const std = @import("std");
const x11 = @import("x11.zig");
const wm_hints_icon = @import("wm_hints_icon.zig");

const xcb = x11.xcb;

const IconSelection = struct {
    offset: usize,
    width: u32,
    height: u32,
};

/// Keep FastTab's default icon-source order aligned with the verified AltTab setup:
/// _NET_WM_ICON -> WM_HINTS -> existing desktop/AppImage/process-root file lookup.
pub fn getWindowIcon(
    allocator: std.mem.Allocator,
    conn: *x11.Connection,
    window: xcb.xcb_window_t,
    target_size: u32,
) ?x11.IconData {
    return getNetWmIcon(allocator, conn.conn, window, conn.atoms, target_size) orelse
        wm_hints_icon.getWindowIcon(allocator, conn, window) orelse
        x11.getWindowIcon(allocator, conn.conn, window, conn.atoms, target_size);
}

fn getNetWmIcon(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: x11.Atoms,
    target_size: u32,
) ?x11.IconData {
    const cookie = xcb.xcb_get_property(
        conn,
        0,
        window,
        atoms.net_wm_icon,
        xcb.XCB_ATOM_CARDINAL,
        0,
        std.math.maxInt(u32),
    );
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);

    if (reply.*.format != 32) return null;
    const byte_len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
    const u32_count = byte_len / @sizeOf(u32);
    if (u32_count < 3) return null;

    const data: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const values = data[0..u32_count];
    const selection = selectBestIcon(values, target_size) orelse return null;

    const pixel_count: usize = @as(usize, selection.width) * @as(usize, selection.height);
    const icon_pixels = allocator.alloc(u32, pixel_count) catch return null;
    @memcpy(icon_pixels, values[selection.offset + 2 .. selection.offset + 2 + pixel_count]);

    return .{
        .data = icon_pixels,
        .width = selection.width,
        .height = selection.height,
        .allocator = allocator,
    };
}

fn selectBestIcon(values: []const u32, target_size: u32) ?IconSelection {
    var best: ?IconSelection = null;
    var best_diff: u32 = std.math.maxInt(u32);
    var offset: usize = 0;

    while (offset + 2 <= values.len) {
        const width = values[offset];
        const height = values[offset + 1];
        if (width == 0 or height == 0) break;

        const pixel_count_u64 = @as(u64, width) * @as(u64, height);
        if (pixel_count_u64 > @as(u64, std.math.maxInt(usize))) break;
        const pixel_count: usize = @intCast(pixel_count_u64);
        if (offset + 2 + pixel_count > values.len) break;

        const size = @max(width, height);
        const diff = if (size >= target_size)
            size - target_size
        else
            (target_size - size) * 2;

        if (best == null or diff < best_diff) {
            best = .{ .offset = offset, .width = width, .height = height };
            best_diff = diff;
        }

        offset += 2 + pixel_count;
    }

    return best;
}

test "NET_WM_ICON selection prefers a slightly larger icon over a much smaller one" {
    var values = [_]u32{0} ** 72;
    values[0] = 2;
    values[1] = 2;
    values[6] = 8;
    values[7] = 8;

    const selected = selectBestIcon(&values, 6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 6), selected.offset);
    try std.testing.expectEqual(@as(u32, 8), selected.width);
    try std.testing.expectEqual(@as(u32, 8), selected.height);
}

test "NET_WM_ICON selection rejects truncated icon data" {
    const values = [_]u32{ 4, 4, 0, 0 };
    try std.testing.expect(selectBestIcon(&values, 32) == null);
}
