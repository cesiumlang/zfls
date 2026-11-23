//! Time grows in step with the length of a line of thousands of names or
//! statements, not with its square (#795).

const std = @import("std");
const h = @import("harness.zig");
const timing = @import("timing.zig");

fn names(n: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "program p\n  integer :: v0");
    for (1..n) |i| try text.print(a, ", v{d}", .{i});
    try text.appendSlice(a, "\nend program p\n");
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text = text.items }}, .{});
    defer w.deinit();
    // each name is unused: a hint with its column each
    const found = try w.diagnostics("d.f90");
    try std.testing.expectEqual(n, found.len);
    // the last name's column is right
    const last_name = try a.print(", v{d}\n", .{n - 1});
    const last = std.mem.findLast(u8, text.items, last_name).? + 2 - ("program p".len + 1);
    var at_last = false;
    for (found) |d| at_last = at_last or d.col == last;
    try std.testing.expect(at_last);
}

test "a declaration of 8000 names has its diagnostics and symbols in seconds (#795)" {
    // 8000 names took about 20 seconds before, a fraction of one now
    try timing.expectLinear(names, 1000, 8000);
}

fn statements(n: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "program p\n  integer :: x\n  x = 0");
    for (1..n) |_| try text.appendSlice(a, "; x = 1");
    try text.appendSlice(a, "\n  print *, x\nend program p\n");
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = text.items }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("s.f90");
}

test "8000 statements on a line have their diagnostics in seconds (#795)" {
    try timing.expectLinear(statements, 1000, 8000);
}
