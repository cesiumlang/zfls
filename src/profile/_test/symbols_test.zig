const std = @import("std");
const symbols = @import("../symbols.zig");

noinline fn marker() usize {
    return @intFromPtr(&marker);
}

test "a function of this binary is found by its address" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const n = try symbols.name(std.testing.io, arena.allocator(), marker(), false);
    try std.testing.expect(std.mem.find(u8, n, "marker") != null);
}
