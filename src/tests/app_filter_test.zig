const std = @import("std");
const app = @import("app");
const testing = std.testing;
const DisplayWindow = app.DisplayWindow;

fn makeWindow(id: u32, workspace: ?u32) DisplayWindow {
    var window = std.mem.zeroes(DisplayWindow);
    window.id = id;
    window.icon_id = "test-app";
    window.workspace = workspace;
    return window;
}

fn filtered(items: []const DisplayWindow, workspace: u32, out: *std.ArrayList(DisplayWindow)) void {
    app.filterItemsByWorkspace(items, workspace, out);
}

test "current workspace filter includes matches only" {
    const items = [_]DisplayWindow{ makeWindow(1, 1), makeWindow(2, 2), makeWindow(3, 1) };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    filtered(&items, 1, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].id);
    try testing.expectEqual(@as(u32, 3), out.items[1].id);
}

test "current workspace filter includes sticky and unknown windows" {
    const items = [_]DisplayWindow{ makeWindow(1, 4), makeWindow(2, 0xFFFFFFFF), makeWindow(3, null), makeWindow(4, 7) };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    filtered(&items, 4, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].id);
    try testing.expectEqual(@as(u32, 2), out.items[1].id);
    try testing.expectEqual(@as(u32, 3), out.items[2].id);
}

test "current workspace filter preserves ordering and shallow copies" {
    const items = [_]DisplayWindow{ makeWindow(10, 2), makeWindow(20, 1), makeWindow(30, 2) };
    var out = std.ArrayList(DisplayWindow).init(testing.allocator);
    defer out.deinit();
    filtered(&items, 2, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 10), out.items[0].id);
    try testing.expectEqual(@as(u32, 30), out.items[1].id);
    try testing.expect(items[0].icon_id.ptr == out.items[0].icon_id.ptr);
}

test "workspace grouping keeps current first and reunites interleaved workspaces" {
    var items = [_]DisplayWindow{
        makeWindow(1, 5), makeWindow(2, 2), makeWindow(3, 0),
        makeWindow(4, 5), makeWindow(5, 4), makeWindow(6, 2),
        makeWindow(7, 1), makeWindow(8, 3), makeWindow(9, 2),
    };
    app.groupItemsByWorkspace(&items, 5);
    const expected = [_]u32{ 1, 4, 3, 7, 2, 6, 9, 8, 5 };
    for (items, expected) |item, id| try testing.expectEqual(id, item.id);
    // A repeated open must not reverse the MRU order inside any group.
    app.groupItemsByWorkspace(&items, 5);
    for (items, expected) |item, id| try testing.expectEqual(id, item.id);
}

test "workspace grouping handles sticky unknown and changed current workspace" {
    var items = [_]DisplayWindow{
        makeWindow(1, null), makeWindow(2, 2), makeWindow(3, 0xFFFFFFFF),
        makeWindow(4, 0),    makeWindow(5, 2),
    };
    app.groupItemsByWorkspace(&items, 2);
    for (items, [_]u32{ 2, 3, 5, 4, 1 }) |item, id| try testing.expectEqual(id, item.id);
    app.groupItemsByWorkspace(&items, 0);
    for (items, [_]u32{ 3, 4, 2, 5, 1 }) |item, id| try testing.expectEqual(id, item.id);
    app.groupItemsByWorkspace(&items, null);
    for (items, [_]u32{ 3, 4, 2, 5, 1 }) |item, id| try testing.expectEqual(id, item.id);
}
