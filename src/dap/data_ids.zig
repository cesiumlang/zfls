//! zfls dap's data breakpoints' ids, for gdb (gdb_data.zig) and the engine
//! (engine_data.zig) (#746): a variable's address, size and expression
//! (`0x1400a2004/4/a(2)`), and which variables have none.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The most bytes that a processor's data breakpoint watches (x86-64's
/// and AArch64's debug registers)
pub const max_size = 8;

pub const Id = struct { address: u64, size: u32, expr: []const u8 };

pub fn format(a: Allocator, address: u64, size: u64, expr: []const u8) ![]const u8 {
    return a.print("0x{x}/{d}/{s}", .{ address, size, expr });
}

pub fn parse(id: []const u8) ?Id {
    var it = std.mem.splitScalar(u8, id, '/');
    const at = std.fmt.parseInt(u64, it.next() orelse return null, 0) catch return null;
    const size = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    return .{ .address = at, .size = size, .expr = it.rest() };
}

/// Why `expr` has no data breakpoint (a whole array, too large, empty);
/// null when it may have one
pub fn refusal(a: Allocator, expr: []const u8, array: bool, size: u64) !?[]const u8 {
    if (array) return try a.print("{s} is a whole array: a data breakpoint watches a scalar, an element or a small component (`{s}(1)`)", .{ expr, expr });
    if (size == 0) return try a.print("{s} has no size", .{expr});
    if (size > max_size) return try a.print("{s} is {d} bytes: the processor watches {d} at most", .{ expr, size, max_size });
    return null;
}

/// Whether gdb's type of a Fortran value (`whatis`: `type = real(kind=4)
/// (3)`) is an array's
pub fn isArrayType(whatis: []const u8) bool {
    const t = std.mem.trim(u8, whatis, " \r\n");
    return t.len > 0 and t[t.len - 1] == ')' and std.mem.find(u8, t, " (") != null;
}

test "data breakpoint ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = parse(try format(a, 0x1400a2004, 4, "t%w(1)")).?;
    try std.testing.expectEqual(@as(u64, 0x1400a2004), id.address);
    try std.testing.expectEqual(@as(u32, 4), id.size);
    try std.testing.expectEqualStrings("t%w(1)", id.expr);
    try std.testing.expect(isArrayType("type = real(kind=4) (3)"));
    try std.testing.expect(!isArrayType("type = real(kind=4)"));
    try std.testing.expect(!isArrayType("type = character*6"));
    try std.testing.expect(try refusal(a, "a", true, 12) != null);
    try std.testing.expect(try refusal(a, "p", false, 12) != null);
    try std.testing.expect(try refusal(a, "k", false, 4) == null);
}
