//! Time grows in step with the number of continuation lines of a fixed-form
//! file, and with the number of procedures a whole-file request covers
//! (#796).

const std = @import("std");
const h = @import("harness.zig");
const counting = @import("counting.zig");
const linear = @import("linear.zig");

fn emptyContinuations(n: usize, counts: *counting.Counts) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..n) |_| try text.appendSlice(a, "     1\n");
    try text.appendSlice(a, "      end\n");
    const w = try h.Workspace.init(&.{.{ .name = "c.f", .text = text.items }}, .{ .counts = counts });
    defer w.deinit();
    _ = try w.diagnostics("c.f");
}

test "a fixed-form file of 4000 empty continuation lines is indexed in seconds (#796)" {
    // 2,000 lines took about 18 seconds before, a fraction of one now
    try linear.expectLinear(emptyContinuations, 500, 4000);
}

fn continuedCall(n: usize, counts: *counting.Counts) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "      call s(a,\n");
    for (0..n) |_| try text.appendSlice(a, "     1 a,\n");
    try text.appendSlice(a, "     1 b)\n      end\n");
    const w = try h.Workspace.init(&.{.{ .name = "k.f", .text = text.items }}, .{ .counts = counts });
    defer w.deinit();
    _ = try w.diagnostics("k.f");
}

test "a fixed-form call of 4000 continuation lines is indexed in seconds (#796)" {
    try linear.expectLinear(continuedCall, 500, 4000);
}

fn procedures(n: usize, counts: *counting.Counts) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..n) |i| try text.print(a, "subroutine s{d}()\nend subroutine s{d}\n", .{ i, i });
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = text.items }}, .{ .counts = counts });
    defer w.deinit();
    _ = try w.diagnostics("p.f90");
    _ = try w.inlayHints("p.f90");
}

test "a file of 16000 procedures has its diagnostics and inlay hints in seconds (#796)" {
    // minutes before (22 seconds for 16000): resting and waking its summary
    // took out each name of the global tree in turn
    try linear.expectLinear(procedures, 2000, 16000);
}
