//! Derived types and ALLOCATABLE dummy arguments against their actual
//! arguments, for procedures with an explicit interface (#848). gfortran
//! 16.1, Flang 23.1.5 and ifx 2026.2.0 all report the first cases.

const std = @import("std");
const h = @import("harness.zig");

const module =
    \\module m2
    \\  implicit none
    \\  type :: tt
    \\    integer :: a
    \\  end type tt
    \\  type, extends(tt) :: t2
    \\    integer :: b
    \\  end type t2
    \\  type :: other
    \\    integer :: a
    \\  end type other
    \\contains
    \\  subroutine st(x)
    \\    type(tt) :: x
    \\  end subroutine st
    \\  subroutine sc(x)
    \\    class(t2) :: x
    \\  end subroutine sc
    \\  subroutine sca(x)
    \\    class(tt) :: x
    \\  end subroutine sca
    \\  subroutine al(x)
    \\    integer, allocatable :: x(:)
    \\  end subroutine al
    \\  integer function fn(x)
    \\    integer :: x
    \\    fn = x
    \\  end function fn
    \\  subroutine sb(x)
    \\    integer :: x
    \\  end subroutine sb
    \\end module m2
    \\
;

fn collect(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, "argument-mismatch")) {
        try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    };
    return out.items;
}

test "derived types and ALLOCATABLE dummies: another type, a variable that is not allocatable" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use m2
        \\  implicit none
        \\  type(tt) :: a
        \\  type(t2) :: b
        \\  type(other) :: o
        \\  integer :: j(5)
        \\  integer, allocatable :: k(:)
        \\  integer, pointer :: pp(:)
        \\  integer :: i
        \\  call st(b)
        \\  call st(o)
        \\  call sc(a)
        \\  call sca(o)
        \\  call al(j)
        \\  call al(pp)
        \\  call fn(1)
        \\  i = sb(1)
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    const got = try collect(w, "p.f90");
    const want = [_][]const u8{
        "11: Argument x of st: type(tt) expected, type(t2) given",
        "12: Argument x of st: type(tt) expected, type(other) given",
        "13: Argument x of sc: class(t2) expected, type(tt) given",
        "14: Argument x of sca: class(tt) expected, type(other) given",
        "15: Argument x of al: an ALLOCATABLE variable expected",
        "16: Argument x of al: an ALLOCATABLE variable expected",
        "17: fn is a function, not a subroutine",
        "18: sb is a subroutine, not a function",
    };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "derived types and ALLOCATABLE dummies: silent for the same type, an extension for CLASS, allocatables, and an attribute statement" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use m2
        \\  implicit none
        \\  type(tt) :: a
        \\  type(t2) :: b
        \\  class(tt), allocatable :: c
        \\  integer :: k(:)
        \\  allocatable :: k
        \\  integer, allocatable :: e(:)
        \\  integer :: i
        \\  call st(a)
        \\  call sc(b)
        \\  call sca(a)
        \\  call sca(b)
        \\  call sca(c)
        \\  call al(k)
        \\  call al(e)
        \\  call sb(i)
        \\  i = fn(i) + fn(2)
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try collect(w, "p.f90")).len);
}
