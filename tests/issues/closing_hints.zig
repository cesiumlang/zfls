//! Inlay hints after the END of long constructs and procedures, and hint
//! labels that link to what they name (#981).

const std = @import("std");
const h = @import("harness.zig");

/// A program whose DO loop and IF block are 26 lines long, an inner DO of
/// 3, and a named loop whose END names it
fn source(a: std.mem.Allocator) ![]const u8 {
    var t: std.ArrayList(u8) = .empty;
    try t.appendSlice(a, "program p\n  implicit none\n  integer, parameter :: n = 3\n  integer :: i, k\n  do i = 1, n\n");
    for (0..24) |_| try t.appendSlice(a, "    k = i\n");
    try t.appendSlice(a, "  end do\n  if (n > 0) then\n");
    for (0..24) |_| try t.appendSlice(a, "    k = 1\n");
    try t.appendSlice(a, "  end if\n  do k = 1, 2\n    i = k\n  end do\n  outer: do k = 1, 2\n");
    for (0..24) |_| try t.appendSlice(a, "    i = k\n");
    try t.appendSlice(a, "  end do outer\n  call s(n)\ncontains\n  subroutine s(width)\n    integer, intent(in) :: width\n    print *, width\n  end subroutine\nend program p\n");
    return t.items;
}

fn closing(hints: []const h.Workspace.Hint) usize {
    var count: usize = 0;
    for (hints) |x| count += @intFromBool(std.mem.startsWith(u8, x.label, "! "));
    return count;
}

test "the END of a long construct shows its opening statement (#981)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try source(arena.allocator());
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = text }}, .{});
    defer w.deinit();
    try w.open("p.f90", "fortran");
    const hints = try w.inlayHints("p.f90");
    var do_end = false;
    var if_end = false;
    for (hints) |x| {
        if (std.mem.eql(u8, x.label, "! do i = 1, n")) do_end = x.line == 29 and x.col == 8;
        if (std.mem.eql(u8, x.label, "! if (n > 0) then")) if_end = x.line == 55;
    }
    try h.expect(do_end, "no closing hint after the long DO's END DO", .{});
    try h.expect(if_end, "no closing hint after the long IF's END IF", .{});
    // the program's END names it; the short DO and the named one have none
    try h.expect(closing(hints) == 2, "{d} closing hints", .{closing(hints)});
}

test "closing_hint_lines sets the length, 0 turns the hints off (#981)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try source(arena.allocator());
    {
        const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = text }}, .{ .init_options = "{\"closing_hint_lines\": 0}" });
        defer w.deinit();
        try w.open("p.f90", "fortran");
        try h.expect(closing(try w.inlayHints("p.f90")) == 0, "closing hints with 0", .{});
    }
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = text }}, .{ .init_options = "{\"closing_hint_lines\": 3}" });
    defer w.deinit();
    try w.open("p.f90", "fortran");
    // the short DO and the subroutine too
    try h.expect(closing(try w.inlayHints("p.f90")) == 4, "{d} closing hints with 3", .{closing(try w.inlayHints("p.f90"))});
}

test "argument and constant hints link to the declarations (#981)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try source(arena.allocator());
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = text }}, .{});
    defer w.deinit();
    try w.open("p.f90", "fortran");
    var arg = false;
    var constant = false;
    for (try w.inlayHints("p.f90")) |x| {
        if (std.mem.eql(u8, x.label, "width:")) arg = x.linked;
        if (std.mem.eql(u8, x.label, "= 3")) constant = constant or x.linked;
    }
    try h.expect(arg, "the argument hint does not link", .{});
    try h.expect(constant, "the constant hint does not link", .{});
}
