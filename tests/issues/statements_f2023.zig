//! The statements and expressions of Fortran 2018 and 2023: QUIET= of STOP
//! and ERROR STOP, NOTIFY WAIT and NOTIFY=, conditional expressions.

const std = @import("std");
const h = @import("harness.zig");

test "QUIET= of STOP and ERROR STOP is no name (F2018, #732)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program stops
        \\  implicit none
        \\  logical :: shh
        \\  shh = .true.
        \\  if (shh) stop 2, quiet=shh
        \\  if (.not. shh) error stop "x", quiet=.false.
        \\  stop 3, QUIET = shh
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
}

test "QUIET is still a name elsewhere (#732)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program stops
        \\  implicit none
        \\  integer :: k
        \\  k = 1
        \\  print *, k, quiet
        \\  stop 2
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectDiagnostics("t.f90", &.{"5: Name \"quiet\" is not declared (IMPLICIT NONE)"});
}

test "NOTIFY WAIT and the NOTIFY= of an image selector are no names (F2023, #732)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program notify
        \\  use iso_fortran_env, only: notify_type
        \\  implicit none
        \\  type(notify_type) :: nt[*]
        \\  real :: b(10)[*]
        \\  if (this_image() == 1) then
        \\    b(1)[2, notify=nt] = 1.0
        \\  else
        \\    notify wait (nt, until_count=1)
        \\  end if
        \\  print *, b(1)
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
}

test "a conditional expression (F2023) has the type of its values (#733)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m_cond
        \\  implicit none
        \\  type :: pt
        \\    real :: x = 0
        \\  end type
        \\contains
        \\  subroutine takes_int(k)
        \\    integer, intent(in) :: k
        \\  end subroutine
        \\  subroutine takes_real(r)
        \\    real, intent(in) :: r
        \\  end subroutine
        \\  subroutine s(flag, a, b, p, q)
        \\    logical, intent(in) :: flag
        \\    real, intent(in) :: a, b
        \\    type(pt), intent(in) :: p, q
        \\    real :: m
        \\    m = (a > b ? a : b)
        \\    associate (c => (flag ? a : b), r => (flag ? p : q))
        \\      print *, c, r%x
        \\    end associate
        \\    call takes_real(((flag ? a : b)))
        \\    call takes_real(((flag ? a : flag ? b : 1.0)))
        \\    call takes_int(((flag ? a : b)))
        \\    print *, m
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "c, r%x", 0, 0), "REAL :: c");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "r%x", 0, 0), "TYPE(pt)");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "r%x", 0, 2), "REAL :: x");
    // as Flang and ifx report it (gfortran 16 reads no conditional
    // expression of a derived type)
    try w.expectDiagnostics("t.f90", &.{"24: Argument k of takes_int: integer expected, real given"});
}
