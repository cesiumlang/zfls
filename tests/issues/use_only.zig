//! A name in a USE ONLY list that the module does not export (#847).

const std = @import("std");
const h = @import("harness.zig");

const base =
    \\module base
    \\  integer :: deep
    \\  integer, private :: hidden
    \\end module base
    \\module m
    \\  use base
    \\  implicit none
    \\  integer :: a
    \\  integer, private :: b
    \\  integer :: c
    \\  private :: c
    \\end module m
    \\
;

test "USE ONLY of a name the module does not have, or has PRIVATE" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = base },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use m, only: nosuch
        \\  use m, only: b, c
        \\  use m, only: zz => b
        \\  use m, only: a, deep
        \\  use m, only: hidden
        \\  implicit none
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    var found: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics("p.f90")) |d| if (std.mem.eql(u8, d.code, "use-name-not-found")) {
        try found.append(w.a(), try w.a().print("{d}:{d}: {s}", .{ d.line + 1, d.col, d.message }));
    };
    const want = [_][]const u8{
        "2:15: \"nosuch\" not found in module \"m\"",
        "3:15: \"b\" is PRIVATE in module \"m\"",
        "3:18: \"c\" is PRIVATE in module \"m\"",
        "4:21: \"b\" is PRIVATE in module \"m\"",
        "6:15: \"hidden\" not found in module \"m\"",
    };
    try std.testing.expectEqual(want.len, found.items.len);
    for (want, found.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "USE ONLY: silent for exported names, generics, operators, renames, re-exports and unknown modules" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text =
        \\module base
        \\  integer :: deep
        \\end module base
        \\module m
        \\  use base
        \\  use iso_c_binding, only: c_int
        \\  implicit none
        \\  private
        \\  public :: a, t, gen, operator(+), deep, c_int, e1, g1, pub
        \\  integer :: a
        \\  integer :: pub
        \\  type :: t
        \\    integer :: x
        \\  end type t
        \\  interface gen
        \\    module procedure f1
        \\  end interface gen
        \\  interface operator(+)
        \\    module procedure plus
        \\  end interface
        \\  enum, bind(c)
        \\    enumerator :: e1 = 1
        \\  end enum
        \\  namelist /g1/ a
        \\contains
        \\  integer function f1(i)
        \\    integer :: i
        \\    f1 = i
        \\  end function f1
        \\  function plus(x, y) result(r)
        \\    type(t), intent(in) :: x, y
        \\    type(t) :: r
        \\    r%x = x%x + y%x
        \\  end function plus
        \\end module m
        \\
        },
        .{ .name = "lib.f90", .text =
        \\module lib
        \\  use mpi
        \\end module lib
        \\
        },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use m, only: a, t, gen, operator(+), deep, c_int, e1, g1, pub
        \\  use m, only: aa => a
        \\  use lib, only: mpi_comm_world
        \\  use unknown_module, only: anything
        \\  use iso_c_binding, only: nosuch_intrinsic
        \\  implicit none
        \\  print *, a, aa, pub, deep, c_int, e1
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    for (try w.diagnostics("p.f90")) |d| try std.testing.expect(!std.mem.eql(u8, d.code, "use-name-not-found"));
}

test "USE ONLY: the code can be switched off" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = base },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use m, only: nosuch ! zfls: disable=use-name-not-found
        \\  implicit none
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    for (try w.diagnostics("p.f90")) |d| try std.testing.expect(!std.mem.eql(u8, d.code, "use-name-not-found"));
}
