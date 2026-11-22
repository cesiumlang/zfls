//! Time grows in step with the number of continuation lines of a fixed-form
//! file, and with the number of procedures a whole-file request covers
//! (#796).

const std = @import("std");
const h = @import("harness.zig");
const io = std.testing.io;

fn expectWithin(seconds: i96, before: i96) !void {
    try std.testing.expect(std.Io.Clock.awake.now(io).nanoseconds - before < seconds * std.time.ns_per_s);
}

test "a fixed-form file of 4000 empty continuation lines is indexed in seconds (#796)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..4000) |_| try text.appendSlice(a, "     1\n");
    try text.appendSlice(a, "      end\n");
    // 2,000 lines took about 18 seconds before, a fraction of one now
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    const w = try h.Workspace.init(&.{.{ .name = "c.f", .text = text.items }}, .{});
    defer w.deinit();
    _ = try w.diagnostics("c.f");
    try expectWithin(8, before);
}

test "a fixed-form call of 4000 continuation lines is indexed in seconds (#796)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "      call s(a,\n");
    for (0..4000) |_| try text.appendSlice(a, "     1 a,\n");
    try text.appendSlice(a, "     1 b)\n      end\n");
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    const w = try h.Workspace.init(&.{.{ .name = "k.f", .text = text.items }}, .{});
    defer w.deinit();
    _ = try w.diagnostics("k.f");
    try expectWithin(8, before);
}

test "a file of 16000 procedures has its diagnostics and inlay hints in seconds (#796)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..16000) |i| try text.print(a, "subroutine s{d}()\nend subroutine s{d}\n", .{ i, i });
    // a file of thousands of procedures took minutes before: resting and
    // waking its summary took out each name of the global tree in turn
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = text.items }}, .{});
    defer w.deinit();
    _ = try w.diagnostics("p.f90");
    _ = try w.inlayHints("p.f90");
    // 22 seconds before, about 4 now
    try expectWithin(12, before);
}
