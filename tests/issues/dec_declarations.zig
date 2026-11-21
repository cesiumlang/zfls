//! DEC's declarations, which ifx (and gfortran, with its options) accepts:
//! the AUTOMATIC, STATIC and VIRTUAL statements and PARAMETER without
//! parentheses (#503; the ifx and gfortran audits, #489 and #488), and Cray
//! pointers (#692).

const std = @import("std");
const h = @import("harness.zig");

test "AUTOMATIC and STATIC statements and attributes declare no names of their own" {
    // ifx: exit 0; gfortran: with -fdec-static
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\subroutine autos(n)
        \\  implicit none
        \\  integer n
        \\  real, automatic :: work(10)
        \\  integer, static :: calls = 0
        \\  automatic :: tmp
        \\  static saved
        \\  real tmp, saved
        \\  calls = calls + 1
        \\  work = n
        \\  tmp = work(1)
        \\  saved = tmp
        \\end subroutine autos
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("a.f90");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "work = n", 0, 0), "REAL, AUTOMATIC, DIMENSION(10) :: work");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "calls = calls", 0, 0), "INTEGER, STATIC :: calls");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "tmp = work", 0, 0), "REAL, AUTOMATIC :: tmp");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "saved = tmp", 0, 0), "REAL, STATIC :: saved");
}

test "VIRTUAL is DIMENSION, and PARAMETER without parentheses is typed by its value (fixed form)" {
    // ifx: exit 0
    const w = try h.Workspace.init(&.{.{ .name = "v.f", .text =
        \\      PROGRAM V
        \\      IMPLICIT NONE
        \\      INTEGER I
        \\      VIRTUAL W(5)
        \\      REAL W
        \\      PARAMETER NMAX = 10, PI = 3.14, BIG = 2.0D0, S = 'ab'
        \\      I = 0
        \\      DO WHILE (I .LT. NMAX)
        \\        I = I + 1
        \\      END DO
        \\      W(1) = PI + BIG
        \\      PRINT *, S, W
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("v.f");
    try w.expectHoverContains("v.f", w.pos("v.f", "W(1) =", 0, 0), "REAL, DIMENSION(5) :: W");
    try w.expectHoverContains("v.f", w.pos("v.f", "NMAX)", 0, 0), "INTEGER, PARAMETER :: NMAX = 10");
    try w.expectHoverContains("v.f", w.pos("v.f", "PI + BIG", 0, 0), "REAL, PARAMETER :: PI = 3.14");
    try w.expectHoverContains("v.f", w.pos("v.f", "BIG", 0, 0), "DOUBLE PRECISION, PARAMETER :: BIG");
    try w.expectHoverContains("v.f", w.pos("v.f", "S, W", 0, 0), "CHARACTER(LEN=2), PARAMETER :: S");
}

test "a PARAMETER without parentheses gives an argument the type of its value" {
    // ifx: only `call takei(ival)` is an error (#6633)
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m2
        \\contains
        \\  subroutine takei(i)
        \\    integer :: i
        \\  end subroutine
        \\  subroutine taker(r)
        \\    real :: r
        \\  end subroutine
        \\end module
        \\subroutine t
        \\  use m2
        \\  parameter ival = 3.7, rval = 2
        \\  call taker(ival)
        \\  call takei(rval)
        \\  call takei(ival)
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    var errors: std.ArrayList(h.Diagnostic) = .empty;
    for (try w.diagnostics("t.f90")) |d| if (d.severity == 1) try errors.append(w.a(), d);
    try std.testing.expectEqual(1, errors.items.len);
    try std.testing.expectEqual(14, errors.items[0].line);
    try std.testing.expect(std.mem.find(u8, errors.items[0].message, "takei") != null);
}

test "Cray pointers: the pointer an address, the pointee with the bounds of the POINTER statement (#692)" {
    // gfortran -fcray-pointer, ifx and Flang: ptr INTEGER(8), arr(n, 2) of
    // rank 2
    const w = try h.Workspace.init(&.{.{ .name = "c.f90", .text =
        \\subroutine cray(n)
        \\  implicit none
        \\  integer :: n
        \\  real :: pointee(10)
        \\  pointer (ptr, pointee), (p2, arr(n, 2))
        \\  real :: arr
        \\  print *, ptr, pointee(1), p2, arr(1, 1)
        \\end subroutine cray
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("c.f90");
    const line = "print *, ptr, pointee(1), p2, arr(1, 1)";
    const want = [_]struct { []const u8, []const u8 }{
        .{ "ptr", "INTEGER(8) :: ptr" },
        .{ "ptr", "Cray pointer to `pointee`" },
        .{ "pointee", "REAL, DIMENSION(10) :: pointee" },
        .{ "pointee", "Cray pointee of `ptr`" },
        .{ "p2", "INTEGER(8) :: p2" },
        .{ "arr", "REAL, DIMENSION(n, 2) :: arr" },
        .{ "arr", "Cray pointee of `p2`" },
    };
    for (want) |c| try w.expectHoverContains("c.f90", w.pos("c.f90", line, 0, std.mem.find(u8, line, c[0]).?), c[1]);
}
