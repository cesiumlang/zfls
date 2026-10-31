//! Upstream issues about completion.

const std = @import("std");
const h = @import("harness.zig");

const calls = [_]h.File{.{ .name = "t.f90", .text =
    \\module geometry
    \\  implicit none
    \\  type :: point
    \\    real :: x, y
    \\  contains
    \\    procedure :: shift
    \\  end type point
    \\  interface area
    \\    module procedure area_circle, area_rect
    \\  end interface area
    \\contains
    \\  subroutine move(p, dx, dy, scale)
    \\    type(point), intent(inout) :: p
    \\    real, intent(in) :: dx, dy
    \\    real, intent(in), optional :: scale
    \\  end subroutine move
    \\  subroutine shift(self, by)
    \\    class(point), intent(inout) :: self
    \\    real, intent(in) :: by
    \\  end subroutine shift
    \\  real function area_circle(radius)
    \\    real, intent(in) :: radius
    \\    area_circle = 3.14159 * radius**2
    \\  end function area_circle
    \\  real function area_rect(width, height)
    \\    real, intent(in) :: width, height
    \\    area_rect = width * height
    \\  end function area_rect
    \\end module geometry
    \\program main
    \\  use geometry
    \\  type(point) :: q
    \\  real :: dist
    \\  call move(q, d
    \\  call move(q, dx=1.0, d
    \\  call move(q, 1.0 + d
    \\  call q%shift(b
    \\  print *, area(r
    \\  print *, area(w
    \\  q = point(x
    \\  print *, size(q, d
    \\end program main
    \\
}};

fn has(items: []const []const u8, label: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i, label)) return true;
    return false;
}

fn expectKeywordArguments(w: *h.Workspace) !void {
    // the arguments of `move` starting with d, and the variables
    var items = try w.completion("t.f90", w.pos("t.f90", "call move(q, d", 0, 14));
    try h.expect(has(items, "dx=") and has(items, "dy="), "move(q, d: {any}", .{items});
    try h.expect(has(items, "dist"), "variables are still offered: {any}", .{items});
    try h.expect(std.mem.eql(u8, items[0], "dx="), "keywords come first: {any}", .{items});
    // a keyword given already is not offered again
    items = try w.completion("t.f90", w.pos("t.f90", "dx=1.0, d", 0, 9));
    try h.expect(has(items, "dy=") and !has(items, "dx="), "move(q, dx=1.0, d: {any}", .{items});
    // only where the argument is a bare name
    items = try w.completion("t.f90", w.pos("t.f90", "1.0 + d", 0, 7));
    try h.expect(!has(items, "dx="), "in an expression: {any}", .{items});
    // a type-bound procedure, without its passed object
    items = try w.completion("t.f90", w.pos("t.f90", "q%shift(b", 0, 9));
    try h.expect(has(items, "by="), "q%shift(b: {any}", .{items});
    // the procedures of a generic interface
    items = try w.completion("t.f90", w.pos("t.f90", "area(r", 0, 6));
    try h.expect(has(items, "radius="), "area(r: {any}", .{items});
    items = try w.completion("t.f90", w.pos("t.f90", "area(w", 0, 6));
    try h.expect(has(items, "width="), "area(w: {any}", .{items});
    // the components of a type, in its structure constructor
    items = try w.completion("t.f90", w.pos("t.f90", "point(x", 0, 7));
    try h.expect(has(items, "x="), "point(x: {any}", .{items});
    // an intrinsic procedure
    items = try w.completion("t.f90", w.pos("t.f90", "size(q, d", 0, 9));
    try h.expect(has(items, "dim=") or has(items, "DIM="), "size(q, d: {any}", .{items});
}

test "hansec #133 completion of keyword arguments inside a call" {
    const w = try h.Workspace.init(&calls, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 133, .fixed, expectKeywordArguments(w));
}
