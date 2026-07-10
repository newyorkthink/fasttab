// Visual design constants
pub const THUMBNAIL_HEIGHT: u32 = 200;
pub const MAX_THUMBNAIL_WIDTH: u32 = 356;
pub const SPACING: u32 = 12;
pub const PADDING: u32 = 16;
pub const MAX_GRID_WIDTH: u32 = 1840;
pub const MAX_GRID_HEIGHT: u32 = 1040;
pub const TITLE_FONT_SIZE: i32 = 16;
pub const TITLE_SPACING: u32 = 8;

pub const ThumbnailSize = struct {
    width: u32,
    height: u32,
};

pub const GridLayout = struct {
    columns: u32,
    rows: u32,
    item_height: u32,
    total_width: u32,
    total_height: u32,
};

/// Calculate display dimensions for a thumbnail while preserving aspect ratio.
/// Integer arithmetic avoids floating-point precision loss for very large windows.
pub fn calculateThumbnailSize(thumb_width: u32, thumb_height: u32, max_width: u32, max_height: u32) ThumbnailSize {
    if (max_width == 0 or max_height == 0) {
        return .{ .width = 0, .height = 0 };
    }

    if (thumb_width == 0 or thumb_height == 0) {
        return .{ .width = max_width, .height = max_height };
    }

    const width_at_max_height = (@as(u64, max_height) * @as(u64, thumb_width)) / @as(u64, thumb_height);
    if (width_at_max_height <= max_width) {
        return .{
            .width = @max(1, @as(u32, @intCast(width_at_max_height))),
            .height = max_height,
        };
    }

    const height_at_max_width = (@as(u64, max_width) * @as(u64, thumb_height)) / @as(u64, thumb_width);
    return .{
        .width = max_width,
        .height = @max(1, @as(u32, @intCast(height_at_max_width))),
    };
}
