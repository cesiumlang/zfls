//! The types of expressions (#987): hover on a parenthesis shows the type
//! and rank of what it encloses; completion after `%` on a function's
//! result and on an array's element.

const std = @import("std");
const h = @import("harness.zig");

const source = h.File{ .name = "e.f90", .text =
    \\module shapes
    \\  implicit none
    \\  type :: point
    \\    real :: x, y
    \\  end type
    \\contains
    \\  function origin() result(o)
    \\    type(point) :: o
    \\    o = point(0.0, 0.0)
    \\  end function
    \\  integer function twice(k)
    \\    integer, intent(in) :: k
    \\    twice = 2 * k
    \\  end function
    \\end module shapes
    \\
    \\program p
    \\  use shapes
    \\  implicit none
    \\  integer :: n
    \\  real :: v(5), s
    \\  type(point) :: pts(3)
    \\  n = 2
    \\  s = (n + v(1)) * (twice(n))
    \\  v(2:3) = (v(1:2))
    \\  s = pts(2)%x + origin()%y
    \\end program p
    \\
};

fn hoverAt(w: *h.Workspace, needle: []const u8, plus: usize) !?[]const u8 {
    return w.hover("e.f90", w.pos("e.f90", needle, 0, plus));
}

test "hover on a parenthesis: the type and rank of what it encloses (#987)" {
    const w = try h.Workspace.init(&.{source}, .{});
    defer w.deinit();
    try w.open("e.f90", "fortran");
    const sum = (try hoverAt(w, "(n + v(1))", 0)) orelse return h.unmet("no hover on the parenthesis of (n + v(1))", .{});
    try h.expect(std.mem.find(u8, sum, "REAL") != null, "(n + v(1)): {s}", .{sum});
    const call = (try hoverAt(w, "(twice(n))", 9)) orelse return h.unmet("no hover on the parenthesis closing (twice(n))", .{});
    try h.expect(std.mem.find(u8, call, "INTEGER") != null, "twice(n): {s}", .{call});
    const section = (try hoverAt(w, "(v(1:2))", 0)) orelse return h.unmet("no hover on the parenthesis of (v(1:2))", .{});
    try h.expect(std.mem.find(u8, section, "DIMENSION(:)") != null, "v(1:2): {s}", .{section});
}

test "completion after % on an element and on a function's result (#987)" {
    const w = try h.Workspace.init(&.{source}, .{});
    defer w.deinit();
    try w.open("e.f90", "fortran");
    for ([_][]const u8{ "pts(2)%", "origin()%" }) |at| {
        const items = try w.completion("e.f90", w.pos("e.f90", at, 0, at.len));
        var x = false;
        for (items) |label| x = x or std.mem.eql(u8, label, "x");
        try h.expect(x, "no component x after {s} ({d} items)", .{ at, items.len });
    }
}
