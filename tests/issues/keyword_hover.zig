//! Hover on `.or.`, a type keyword or the words of DOUBLE PRECISION shows
//! no intrinsic procedure's documentation (#845); a call still does.

const std = @import("std");
const h = @import("harness.zig");

const text =
    \\double precision function f(x)
    \\  double precision :: x
    \\  f = x
    \\end function
    \\subroutine s(a, b, r)
    \\  logical r
    \\  logical, intent(in) :: a, b
    \\  integer :: i
    \\  r = a .or. b
    \\  r = a .and. .not. b
    \\  i = int(2.0d0)
    \\  r = logical(r)
    \\  r = a .eqv. b
    \\end subroutine
    \\subroutine u(it)
    \\  class(*) :: it
    \\  real, allocatable :: x
    \\  procedure(real) :: p
    \\  allocate(real :: x)
    \\  select type (it)
    \\  type is (real)
    \\  type is (character(len=*))
    \\  end select
    \\end subroutine
    \\
;

fn expectNoIntrinsic(w: *h.Workspace, needle: []const u8, nth: usize, plus: usize) !void {
    const md = (try w.hover("t.f90", w.pos("t.f90", needle, nth, plus))) orelse return;
    // the intrinsics' pages hold "(3)" and the table's text "(I,J)"
    try h.expect(std.mem.find(u8, md, "(3)") == null and std.mem.find(u8, md, "(I,J)") == null, "'{s}' ({d}): {s}", .{ needle, nth, md });
}

test "hover on an operator, a type keyword or DOUBLE PRECISION is no intrinsic's (#845)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
    defer w.deinit();
    try expectNoIntrinsic(w, "precision function", 0, 2);
    try expectNoIntrinsic(w, "precision ::", 0, 2);
    try expectNoIntrinsic(w, "logical r", 0, 2);
    try expectNoIntrinsic(w, "logical, intent", 0, 2);
    try expectNoIntrinsic(w, ".or.", 0, 2);
    try expectNoIntrinsic(w, ".and.", 0, 2);
    try expectNoIntrinsic(w, ".not.", 0, 2);
    try expectNoIntrinsic(w, ".eqv.", 0, 2);
    try expectNoIntrinsic(w, "real) :: p", 0, 2);
    try expectNoIntrinsic(w, "real :: x)", 0, 2);
    try expectNoIntrinsic(w, "real)\n  type is (char", 0, 2);
    try expectNoIntrinsic(w, "character(len=*))", 0, 2);
}

test "hover on a call of an intrinsic of the same name still shows it (#845)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "logical(r)", 0, 2), "(3)");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "int(2", 0, 1), "(3)");
}
