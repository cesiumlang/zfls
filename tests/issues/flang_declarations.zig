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

test "a statement function is a function of its scope, with its dummy arguments (#555)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text =
        \\subroutine s(n)
        \\  implicit none
        \\  integer, intent(inout) :: n
        \\  integer :: i, j
        \\  integer :: sf
        \\  real :: area, r
        \\  sf(i, j) = i * 2 + j
        \\  area(r) = 3.14159 * r**2
        \\  n = sf(n, 1) + int(area(2.0))
        \\end subroutine s
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("s.f90");
    try w.expectHoverContains("s.f90", w.pos("s.f90", "sf(n, 1)", 0, 0), "FUNCTION sf(i, j)");
    try w.expectHoverContains("s.f90", w.pos("s.f90", "sf(n, 1)", 0, 0), "INTEGER :: sf");
    try w.expectHoverContains("s.f90", w.pos("s.f90", "area(2.0)", 0, 0), "FUNCTION area(r)");
    try w.expectHoverContains("s.f90", w.pos("s.f90", "area(2.0)", 0, 0), "REAL :: area");
    const def = (try w.definition("s.f90", w.pos("s.f90", "sf(n, 1)", 0, 0))) orelse return h.unmet("no definition of sf", .{});
    try h.expect(def.line == w.pos("s.f90", "sf(i, j) =", 0, 0).line, "sf defined on line {d}", .{def.line});
    // its dummy argument, of the type of the scope's variable of its name
    try w.expectHoverContains("s.f90", w.pos("s.f90", "i * 2", 0, 0), "INTEGER");
}

test "a statement function without a declaration, under implicit typing (#555)" {
    const w = try h.Workspace.init(&.{.{ .name = "f.f", .text =
        \\      SUBROUTINE F77(Y)
        \\      REAL Y
        \\      SQ(X) = X*X
        \\      Y = SQ(2.0)
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("f.f");
    try w.expectHoverContains("f.f", w.pos("f.f", "SQ(2.0)", 0, 0), "FUNCTION SQ(x)");
    try w.expectHoverContains("f.f", w.pos("f.f", "SQ(2.0)", 0, 0), "REAL :: SQ");
    try w.expectHoverContains("f.f", w.pos("f.f", "X*X", 0, 0), "REAL :: X");
}

test "an assignment to an array element is no statement function (#555)" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module a
        \\  implicit none
        \\  real :: marr(10)
        \\contains
        \\  subroutine first(i)
        \\    integer, intent(in) :: i
        \\    marr(i) = 0
        \\  end subroutine first
        \\end module a
        \\subroutine second(i)
        \\  integer, intent(in) :: i
        \\  real :: v
        \\  dimension v(10)
        \\  real :: w(10), u
        \\  common /c/ cv(10)
        \\  v(i) = 1
        \\  w(i) = 2
        \\  cv(i) = 3
        \\  u = 4
        \\end subroutine second
        \\
    }}, .{});
    defer w.deinit();
    const symbols = try w.documentSymbols("a.f90");
    for (symbols) |s| for ([_][]const u8{ "marr", "v", "w", "cv" }) |n| {
        if (!std.mem.eql(u8, s, n)) continue;
        // as a variable it is there once, from its declaration
        var count: usize = 0;
        for (symbols) |t| if (std.mem.eql(u8, t, n)) {
            count += 1;
        };
        try h.expect(count == 1, "{s} {d} times in {any}", .{ n, count, symbols });
    };
    try w.expectHoverContains("a.f90", w.pos("a.f90", "marr(i) = 0", 0, 0), "DIMENSION(10)");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "v(i) = 1", 0, 0), "DIMENSION(10)");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "w(i) = 2", 0, 0), "DIMENSION(10)");
    const cv = try w.hover("a.f90", w.pos("a.f90", "cv(i) = 3", 0, 0));
    if (cv) |text| try h.expect(std.mem.find(u8, text, "FUNCTION") == null, "cv: {s}", .{text});
}

test "an ENTRY is a procedure of the scope that has its procedure, with its arguments (#554)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "e.f90", .text =
        \\module ents
        \\  implicit none
        \\contains
        \\  subroutine with_entry(x)
        \\    integer :: x, y
        \\    x = 1
        \\    entry other_entry(x, y)
        \\    x = y
        \\  end subroutine with_entry
        \\  real function f(a)
        \\    real :: a, g
        \\    f = a
        \\    return
        \\    entry g(a)
        \\    g = 2 * a
        \\  end function f
        \\end module ents
        \\subroutine ext(p)
        \\  integer :: p
        \\  p = 0
        \\  entry ext2(p)
        \\  p = 1
        \\end subroutine ext
        \\
        },
        .{ .name = "u.f90", .text =
        \\program u
        \\  use ents
        \\  implicit none
        \\  integer :: k, m
        \\  real :: r
        \\  call other_entry(k, m)
        \\  r = g(1.0)
        \\  call ext2(k)
        \\end program u
        \\
        },
    }, .{ .hierarchical_symbols = true });
    defer w.deinit();
    try w.expectNoDiagnostics("e.f90");
    try w.expectNoDiagnostics("u.f90");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "other_entry", 0, 0), "SUBROUTINE other_entry(x, y)");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "other_entry", 0, 0), "INTEGER :: y");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "g(1.0)", 0, 0), "FUNCTION g(a)");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "g(1.0)", 0, 0), "REAL :: a");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "ext2", 0, 0), "SUBROUTINE ext2(p)");
    const def = (try w.definition("u.f90", w.pos("u.f90", "other_entry", 0, 0))) orelse return h.unmet("no definition of other_entry", .{});
    try h.expect(def.line == w.pos("e.f90", "entry other_entry", 0, 0).line, "other_entry defined on line {d}", .{def.line});
    const sig = (try w.signature("u.f90", w.pos("u.f90", "other_entry(k", 0, 12))) orelse return h.unmet("no signature help in other_entry(", .{});
    try h.expect(std.mem.find(u8, sig.label, "other_entry(x, y)") != null, "signature {s}", .{sig.label});
    const symbols = try w.symbolPaths("e.f90");
    for ([_][]const u8{ "ents/other_entry", "ents/g", "ext2" }) |want| {
        for (symbols) |s| {
            if (std.mem.eql(u8, s, want)) break;
        } else return h.unmet("{s} not in {any}", .{ want, symbols });
    }
    // the names on the ENTRY line are the procedure's
    try w.expectHoverContains("e.f90", w.pos("e.f90", "y)", 0, 0), "INTEGER :: y");
}

test "COMMON blocks are symbols: hover lists their variables, references across program units (#556)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "c1.f90", .text =
        \\subroutine s1()
        \\  implicit none
        \\  real :: a, b, c, x
        \\  common /blk/ a, b(10), /other/ c
        \\  common /x/ x
        \\  a = b(1) + c + x
        \\end subroutine s1
        \\
        },
        .{ .name = "c2.f", .text =
        \\      SUBROUTINE S2()
        \\      REAL A2
        \\      COMMON /BLK/ A2
        \\      SAVE /BLK/
        \\      A2 = 0
        \\      END
        \\
        },
    }, .{ .hierarchical_symbols = true });
    defer w.deinit();
    try w.expectNoDiagnostics("c1.f90");
    try w.expectNoDiagnostics("c2.f");
    try w.expectHoverContains("c1.f90", w.pos("c1.f90", "blk/", 0, 0), "COMMON /blk/ a, b(10)");
    try w.expectHoverContains("c1.f90", w.pos("c1.f90", "other/", 0, 0), "COMMON /other/ c");
    // the block x and the variable x
    try w.expectHoverContains("c1.f90", w.pos("c1.f90", "x/ x", 0, 0), "COMMON /x/ x");
    try w.expectHoverContains("c1.f90", w.pos("c1.f90", "+ x", 0, 2), "REAL :: x");
    // the bounds a COMMON statement gives
    try w.expectHoverContains("c1.f90", w.pos("c1.f90", "b(1)", 0, 0), "DIMENSION(10)");
    const def = (try w.definition("c2.f", w.pos("c2.f", "BLK/ A2", 0, 0))) orelse return h.unmet("no definition of /BLK/", .{});
    try h.expect(def.line == 2, "/BLK/ defined on line {d}", .{def.line});
    const refs = try w.references("c1.f90", w.pos("c1.f90", "blk/", 0, 0));
    try h.expect(refs.len == 3, "{d} references of /blk/: {any}", .{ refs.len, refs });
    const symbols = try w.symbolPaths("c1.f90");
    for ([_][]const u8{ "s1//blk/", "s1//other/", "s1//x/" }) |want| {
        for (symbols) |s| {
            if (std.mem.eql(u8, s, want)) break;
        } else return h.unmet("{s} not in {any}", .{ want, symbols });
    }
    const found = try w.workspaceSymbols("blk");
    try h.expect(found.len == 2, "workspace symbols of blk: {any}", .{found});
}

test "NAMELIST groups are symbols; WRITE (*, NL) names the group (#556, #520)" {
    const w = try h.Workspace.init(&.{.{ .name = "n.f90", .text =
        \\program p
        \\  implicit none
        \\  integer :: a = 1
        \\  real :: r = 2.0
        \\  namelist /nl/ a, r
        \\  write (*, nl)
        \\  write (*, nml=nl)
        \\  read (*, nl)
        \\end program p
        \\
    }}, .{ .hierarchical_symbols = true });
    defer w.deinit();
    try w.expectNoDiagnostics("n.f90");
    try w.expectHoverContains("n.f90", w.pos("n.f90", "nl)", 0, 0), "NAMELIST /nl/ a, r");
    try w.expectHoverContains("n.f90", w.pos("n.f90", "nml=nl", 0, 4), "NAMELIST /nl/ a, r");
    const def = (try w.definition("n.f90", w.pos("n.f90", "nl)", 0, 0))) orelse return h.unmet("no definition of nl", .{});
    try h.expect(def.line == 4, "nl defined on line {d}", .{def.line});
    const refs = try w.references("n.f90", w.pos("n.f90", "nl/", 0, 0));
    try h.expect(refs.len == 4, "{d} references of nl: {any}", .{ refs.len, refs });
    const symbols = try w.symbolPaths("n.f90");
    for (symbols) |s| {
        if (std.mem.eql(u8, s, "p/nl")) break;
    } else return h.unmet("p/nl not in {any}", .{symbols});
}
