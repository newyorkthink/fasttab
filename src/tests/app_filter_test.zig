const std = @import("std");
const app = @import("app");
const testing = std.testing;

const DisplayWindow = app.DisplayWindow;

fn makeWindow(id: u32, icon_id: []const u8) DisplayWindow {
    var w = std.mem.zeroes(DisplayWindow);
    w.id = id;
    w.icon_id = icon_id;
    return w;
}

test "filterItemsByClass: empty input yields empty output" {
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    app.filterItemsByClass(&.{}, "firefox", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "filterItemsByClass: matches items by icon_id" {
    const items = [_]DisplayWindow{
        makeWindow(1, "firefox"),
        makeWindow(2, "code"),
        makeWindow(3, "firefox"),
    };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    app.filterItemsByClass(&items, "firefox", &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].id);
    try testing.expectEqual(@as(u32, 3), out.items[1].id);
}

test "filterItemsByClass: no match yields empty output" {
    const items = [_]DisplayWindow{
        makeWindow(1, "firefox"),
        makeWindow(2, "code"),
    };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    app.filterItemsByClass(&items, "chrome", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "filterItemsByClass: all items match" {
    const items = [_]DisplayWindow{
        makeWindow(1, "code"),
        makeWindow(2, "code"),
        makeWindow(3, "code"),
    };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    app.filterItemsByClass(&items, "code", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
}

test "filterItemsByClass: preserves source ordering" {
    const items = [_]DisplayWindow{
        makeWindow(10, "code"),
        makeWindow(20, "firefox"),
        makeWindow(30, "code"),
        makeWindow(40, "code"),
    };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    app.filterItemsByClass(&items, "code", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(u32, 10), out.items[0].id);
    try testing.expectEqual(@as(u32, 30), out.items[1].id);
    try testing.expectEqual(@as(u32, 40), out.items[2].id);
}

test "filterItemsByClass: output items are shallow copies (same icon_id pointer)" {
    const items = [_]DisplayWindow{
        makeWindow(1, "code"),
    };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    app.filterItemsByClass(&items, "code", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    // Non-owning: icon_id must point into the same memory as the source
    try testing.expect(items[0].icon_id.ptr == out.items[0].icon_id.ptr);
}

test "filterItemsByClass: single item match" {
    const items = [_]DisplayWindow{
        makeWindow(1, "firefox"),
        makeWindow(2, "code"),
        makeWindow(3, "chrome"),
    };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    app.filterItemsByClass(&items, "chrome", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 3), out.items[0].id);
}
