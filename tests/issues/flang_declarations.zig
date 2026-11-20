//! Declarations that the Flang oracle (tests/flang_oracle.zig, #399) found
//! zfls reading otherwise than LLVM Flang: in sources and in the module
//! files Flang writes (`.mod`, read since #468), whose interfaces are
//! Fortran as Flang prints it.

const std = @import("std");
const h = @import("harness.zig");

test "a bound with a keyword argument does not cut the entity's name (x(1_8:int(n,kind=8)))" {
    const w = try h.Workspace.init(&.{.{ .name = "b.f90", .text =
        \\subroutine s(n, x, y, z)
        \\  implicit none
        \\  integer, intent(in) :: n
        \\  real :: x(1_8:int(n,kind=8))
        \\  real :: y(int(n,kind=8)), z(n)
        \\  x = 0
        \\  y = 1
        \\  z = 2
        \\end subroutine s
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("b.f90");
    try w.expectHoverContains("b.f90", w.pos("b.f90", "x = 0", 0, 0), "REAL");
    try w.expectHoverContains("b.f90", w.pos("b.f90", "y = 1", 0, 0), "REAL");
}

test "old-style initial values (k /3/, v(3) /1, 2, 3/) are no names" {
    const w = try h.Workspace.init(&.{.{ .name = "o.f90", .text =
        \\module o
        \\  implicit none
        \\  integer :: k /3/, v(3) /1, 2, 3/, after
        \\  character*4 :: tag /'abcd'/
        \\contains
        \\  integer function total()
        \\    total = k + sum(v) + after + len(tag)
        \\  end function total
        \\end module o
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("o.f90");
    try w.expectHoverContains("o.f90", w.pos("o.f90", "sum(v)", 0, 4), "INTEGER");
    try w.expectHoverContains("o.f90", w.pos("o.f90", "after +", 0, 0), "INTEGER");
}

test "BYTE, PROCEDURE() and a Cray pointer declare their names" {
    const w = try h.Workspace.init(&.{.{ .name = "e.f90", .text =
        \\subroutine e(cb)
        \\  implicit none
        \\  byte :: small
        \\  procedure() :: cb
        \\  real :: pointee(10)
        \\  pointer (ptr, pointee)
        \\  small = 1
        \\  call cb()
        \\  ptr = 0
        \\  pointee(1) = small
        \\end subroutine e
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("e.f90");
    try w.expectHoverContains("e.f90", w.pos("e.f90", "small = 1", 0, 0), "BYTE");
    try w.expectHoverContains("e.f90", w.pos("e.f90", "ptr = 0", 0, 0), "INTEGER(8)");
}

test "a preprocessor #if with && continues no statement" {
    const w = try h.Workspace.init(&.{.{ .name = "p.F90", .text =
        \\#define WP 8
        \\#if defined(WP) && WP == 8
        \\#define HAVE_WP
        \\#endif
        \\module p
        \\  implicit none
        \\  real(WP) :: wide
        \\end module p
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("p.F90");
    const symbols = try w.documentSymbols("p.F90");
    for (symbols) |s| {
        if (std.mem.eql(u8, s, "p")) break;
    } else return h.unmet("module p not in {any}", .{symbols});
}

test "RECORD with :: (as LLVM Flang writes it in a module file)" {
    const w = try h.Workspace.init(&.{.{ .name = "r.f90", .text =
        \\module r
        \\  implicit none
        \\  structure /point/
        \\    real :: x, y
        \\  end structure
        \\  record/point/::origin
        \\contains
        \\  subroutine move()
        \\    origin%x = 1.0
        \\  end subroutine move
        \\end module r
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("r.f90");
    try w.expectHoverContains("r.f90", w.pos("r.f90", "origin%x", 0, 0), "point");
}

// a fixed-form declaration whose last name starts in column 75
const long_line_files = [_]h.File{.{ .name = "l.f", .text = "      SUBROUTINE LONGL(A)\n" ++
    "      IMPLICIT NONE\n" ++
    "      REAL A\n" ++
    "      INTEGER SHORT1, SHORT2                                            , PAST72\n" ++
    "      SHORT1 = 1\n" ++
    "      A = SHORT1 + SHORT2\n" ++
    "      END SUBROUTINE\n" }};

test "fixed form: the names past fixed_line_length declare nothing (#553)" {
    const w = try h.Workspace.init(&long_line_files, .{ .settings = .{ .fixed_line_length = 72 } });
    defer w.deinit();
    const symbols = try w.documentSymbols("l.f");
    for (symbols) |s| try h.expect(std.ascii.findIgnoreCase(s, "past72") == null, "{s} in {any}", .{ s, symbols });
    try h.expect(try w.hover("l.f", w.pos("l.f", "PAST72", 0, 1)) == null, "a hover on PAST72", .{});
    try w.expectHoverContains("l.f", w.pos("l.f", "SHORT2  ", 0, 0), "INTEGER");
    // without a limit (and with one past the name) it is declared
    const all = try h.Workspace.init(&long_line_files, .{ .settings = .{ .fixed_line_length = 132 } });
    defer all.deinit();
    try all.expectHoverContains("l.f", all.pos("l.f", "PAST72", 0, 1), "INTEGER");
}

test "fixed form: a continued statement past fixed_line_length, also in a file that switches forms (#553)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f", .text = "      MODULE S\n" ++
        "      IMPLICIT NONE\n" ++
        "      INTEGER FIRST,                                                    CUT1\n" ++
        "     &        SECOND                                                    , CUT2\n" ++
        "      END MODULE\n" ++
        "!dir$ free\n" ++
        "module t\n" ++
        "  implicit none\n" ++
        "  integer :: free_names_are_not_cut_past_column_72_in_free_form_lines, kept\n" ++
        "end module t\n" }}, .{ .settings = .{ .fixed_line_length = 72 } });
    defer w.deinit();
    const symbols = try w.documentSymbols("s.f");
    for (symbols) |s| try h.expect(std.ascii.findIgnoreCase(s, "cut") == null, "{s} in {any}", .{ s, symbols });
    try w.expectHoverContains("s.f", w.pos("s.f", "SECOND", 0, 1), "INTEGER");
    try w.expectHoverContains("s.f", w.pos("s.f", "kept", 0, 1), "INTEGER");
}
