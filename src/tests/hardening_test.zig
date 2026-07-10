const std = @import("std");
const navigation = @import("navigation");
const layout = @import("layout");

const testing = std.testing;
const max_usize = std.math.maxInt(usize);

test "navigation normalizes out-of-range indices" {
    try testing.expectEqual(@as(usize, 2), navigation.moveSelectionRight(6, 5));
    try testing.expectEqual(@as(usize, 0), navigation.moveSelectionLeft(6, 5));
    try testing.expectEqual(@as(usize, 3), navigation.moveSelectionDown(max_usize, 3, 5));
}

test "navigation avoids overflow at usize max" {
    try testing.expectEqual(@as(usize, 0), navigation.moveSelectionRight(max_usize, 1));
    try testing.expectEqual(@as(usize, 0), navigation.moveSelectionDown(max_usize, max_usize, 1));
}

test "thumbnail sizing stays within bounds" {
    const wide = layout.calculateThumbnailSize(4_294_967_295, 1, 356, 200);
    try testing.expectEqual(@as(u32, 356), wide.width);
    try testing.expectEqual(@as(u32, 1), wide.height);

    const tall = layout.calculateThumbnailSize(1, 4_294_967_295, 356, 200);
    try testing.expectEqual(@as(u32, 1), tall.width);
    try testing.expectEqual(@as(u32, 200), tall.height);
}

test "thumbnail sizing handles zero bounds" {
    const size = layout.calculateThumbnailSize(1920, 1080, 0, 200);
    try testing.expectEqual(@as(u32, 0), size.width);
    try testing.expectEqual(@as(u32, 0), size.height);
}
