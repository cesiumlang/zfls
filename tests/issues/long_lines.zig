//! Time grows in step with the length of a line of thousands of names or
//! statements, not with its square (#795).

const std = @import("std");
const h = @import("harness.zig");
const io = std.testing.io;

fn expectWithin(seconds: i96, before: i96) !void {
    try std.testing.expect(std.Io.Clock.awake.now(io).nanoseconds - before < seconds * std.time.ns_per_s);
}

test "a declaration of 8000 names has its diagnostics and symbols in seconds (#795)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "program p\n  integer :: v0");
    for (1..8000) |i| try text.print(a, ", v{d}", .{i});
    try text.appendSlice(a, "\nend program p\n");
    // 8000 names took about 20 seconds before, a fraction of one now
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text = text.items }}, .{});
    defer w.deinit();
    // each name is unused: a hint with its column each
    const found = try w.diagnostics("d.f90");
    try std.testing.expectEqual(@as(usize, 8000), found.len);
    // the last name's column is right
    const last = std.mem.findLast(u8, text.items, "v7999").? - ("program p".len + 1);
    var at_last = false;
    for (found) |d| at_last = at_last or d.col == last;
    try std.testing.expect(at_last);
    try expectWithin(8, before);
}

test "8000 statements on a line have their diagnostics in seconds (#795)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "program p\n  integer :: x\n  x = 0");
    for (1..8000) |_| try text.appendSlice(a, "; x = 1");
    try text.appendSlice(a, "\n  print *, x\nend program p\n");
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = text.items }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("s.f90");
    try expectWithin(8, before);
}
