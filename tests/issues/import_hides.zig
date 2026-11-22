//! IMPORT, ONLY and IMPORT, NONE hide the host names they leave out (#804).
//! gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 report each use of such a
//! name in a BLOCK or contained procedure as an error.

const std = @import("std");
const h = @import("harness.zig");

test "a host name that IMPORT leaves out is reported in a BLOCK, with and without IMPLICIT NONE (#804)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "none.f90", .text =
        \\subroutine s()
        \\  implicit none
        \\  integer, parameter :: wp = 8
        \\  real(wp) :: x, y
        \\  block
        \\    import, only: wp, y
        \\    real(wp) :: z
        \\    z = 1.0_wp
        \\    y = z
        \\    x = 1.0_wp
        \\  end block
        \\  block
        \\    import, none
        \\    integer :: k
        \\    k = 1
        \\    print *, wp
        \\  end block
        \\  x = 2.0_wp
        \\end subroutine
        \\
        },
        .{ .name = "implicit.f90", .text =
        \\subroutine s()
        \\  integer, parameter :: wp = 8
        \\  real(wp) :: x, y
        \\  block
        \\    import, only: wp, y
        \\    y = 1.0
        \\    x = 2.0
        \\    w2 = 3.0
        \\  end block
        \\end subroutine
        \\
        },
    }, .{});
    defer w.deinit();
    try w.expectDiagnostics("none.f90", &.{
        "10: Name \"x\" of the host is not accessible (not in the IMPORT list)",
        "16: Name \"wp\" of the host is not accessible (IMPORT, NONE)",
    });
    // w2 is declared nowhere: implicitly typed, as gfortran has it
    try w.expectDiagnostics("implicit.f90", &.{
        "7: Name \"x\" of the host is not accessible (not in the IMPORT list)",
    });
}

test "a host name that IMPORT leaves out is reported in a contained procedure (#804)" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text =
        \\module m
        \\  implicit none
        \\  integer :: mv
        \\contains
        \\  function ff(a) result(r)
        \\    integer :: a, r
        \\    r = a
        \\  end function
        \\  subroutine s()
        \\    integer :: x, y
        \\    call t()
        \\    call u()
        \\  contains
        \\    subroutine t()
        \\      import, none
        \\      integer :: q
        \\      q = 2
        \\      x = 2
        \\      mv = 3
        \\      q = ff(1)
        \\    end subroutine
        \\    subroutine u()
        \\      import, only: y
        \\      y = 1
        \\      x = 2
        \\    end subroutine
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectDiagnostics("m.f90", &.{
        "18: Name \"x\" of the host is not accessible (IMPORT, NONE)",
        "19: Name \"mv\" of the host is not accessible (IMPORT, NONE)",
        "20: Name \"ff\" of the host is not accessible (IMPORT, NONE)",
        "25: Name \"x\" of the host is not accessible (not in the IMPORT list)",
    });
}

test "imported names and names declared in the block stay silent (#804)" {
    const w = try h.Workspace.init(&.{.{ .name = "ok.f90", .text =
        \\module k
        \\  implicit none
        \\  integer, parameter :: kk = 8
        \\end module
        \\subroutine s(n, a)
        \\  use k, only: kk
        \\  implicit none
        \\  integer, intent(in) :: n
        \\  real(kk), intent(inout) :: a(n)
        \\  real(kk) :: x, y
        \\  integer :: i
        \\  x = 1.0_kk
        \\  block
        \\    import, only: kk, a, n, x
        \\    real(kk) :: y
        \\    integer :: i
        \\    y = x
        \\    do i = 1, size(a)
        \\      a(i) = y + n
        \\    end do
        \\    associate (q => a(1))
        \\      y = q + x
        \\    end associate
        \\    block
        \\      integer :: j
        \\      j = i
        \\      a(j) = y
        \\    end block
        \\  end block
        \\  block
        \\    import, none
        \\    integer :: i
        \\    i = 1
        \\    print *, i, sqrt(2.0)
        \\  end block
        \\  block
        \\    import
        \\    y = x
        \\  end block
        \\  block
        \\    import, only: y
        \\    import, only: x
        \\    y = x
        \\  end block
        \\  i = 2
        \\  y = x
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("ok.f90");
}
