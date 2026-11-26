const std = @import("std");
const sysinfo = @import("builtin");
const symbols = @import("../symbols.zig");

noinline fn marker() usize {
    return @intFromPtr(&marker);
}

test "a function of this binary is found by its address" {
    // the sampler is Windows's (its PDB); elsewhere the test binary's DWARF
    // is loaded whole, which hung CI's unit tests on Linux and macOS
    if (sysinfo.target.os.tag != .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const n = try symbols.name(std.testing.io, arena.allocator(), marker(), false);
    try std.testing.expect(std.mem.find(u8, n, "marker") != null);
}
