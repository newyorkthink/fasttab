const std = @import("std");
const builtin = @import("builtin");

// main 在创建 worker 前注入标准 I/O；测试使用测试运行器提供的 I/O。
pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.real.now(io).nanoseconds;
}

pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(io, .fromNanoseconds(nanoseconds), .awake) catch {};
}

pub fn getenv(name: [:0]const u8) ?[:0]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}
