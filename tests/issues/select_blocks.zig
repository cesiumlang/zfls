//! The blocks of SELECT TYPE and SELECT RANK: each guard's block is a
//! sibling of the one before (#708); the associate name of a RANK block
//! has its rank (#706); argument checking takes a guard name's (#707), a
//! RANK name's and a CLASS DEFAULT name's (#714).

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");

const gpa = std.testing.allocator;

const guards =
    \\subroutine g(items, n)
    \\  class(*), intent(in) :: items(:)
    \\  integer :: n
    \\  select type (it => items)
    \\  type is (integer)
    \\    select case (n)
    \\    case (1)
    \\      print *, it(1)
    \\    end select
    \\    print *, it(2)
    \\  type is (real)
    \\    print *, it(3)
    \\  class default
    \\    print *, size(it)
    \\  end select
    \\end subroutine
    \\
;

test "each guard's block is in its SELECT TYPE, not in the guard before (#708)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = guards }}, .{});
    defer w.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try zfls.debug.runTo(gpa, std.testing.io, .{ .debug_parser = true, .debug_filepath = try w.path("t.f90"), .debug_rootpath = w.root }, .{ .a = gpa, .out = &out });
    const decls = out.items[std.mem.find(u8, out.items, "Declarations").?..];
    for ([_][]const u8{
        "g::#select1::#select2::it: INTEGER, DIMENSION(:) :: it\n",
        "g::#select1::#select4::it: REAL, DIMENSION(:) :: it\n",
        "g::#select1::#select5::it: CLASS(*), DIMENSION(:) :: it\n",
    }) |want| if (std.mem.find(u8, decls, want) == null) {
        std.debug.print("\n'{s}' not in:\n{s}\n", .{ want, decls });
        return error.TestExpectedEqual;
    };
    // the SELECT CASE in a guard makes no associate name
    try std.testing.expectEqual(3, std.mem.count(u8, decls, "::it:"));
}

test "a SELECT CASE in a guard's block leaves the guard open (#708)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = guards }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "it(1)", 0, 0), "INTEGER, DIMENSION(:) :: it");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "it(2)", 0, 0), "INTEGER, DIMENSION(:) :: it");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "it(3)", 0, 0), "REAL, DIMENSION(:) :: it");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "size(it)", 0, 5), "CLASS(*), DIMENSION(:) :: it");
}

test "SELECT RANK: each block's name has the block's rank and the selector's attributes (#706)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine s(a, p, al)
        \\  real, intent(in) :: a(..)
        \\  real, pointer :: p(..)
        \\  real, allocatable :: al(..)
        \\  select rank (r => a)
        \\  rank (0)
        \\    print *, r
        \\  rank (2)
        \\    print *, r(1, 1)
        \\  rank (*)
        \\    print *, r(1)
        \\  rank default
        \\    print *, rank(r)
        \\  end select
        \\  select rank (p)
        \\  rank (1)
        \\    print *, p(1)
        \\  end select
        \\  select rank (q => al)
        \\  rank (3) ! a comment (x)
        \\    print *, q(1, 1, 1)
        \\  end select
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    const want = [_]struct { []const u8, []const u8 }{
        .{ "r\n", "REAL :: r" },
        .{ "r(1, 1)", "REAL, DIMENSION(:,:) :: r" },
        .{ "r(1)", "REAL, DIMENSION(*) :: r" },
        .{ "r)", "REAL, DIMENSION(..) :: r" },
        .{ "p(1)", "REAL, POINTER, DIMENSION(:) :: p" },
        .{ "q(1, 1, 1)", "REAL, ALLOCATABLE, DIMENSION(:,:,:) :: q" },
    };
    for (want) |c| try w.expectHoverContains("t.f90", w.pos("t.f90", c[0], 0, 0), c[1]);
}

test "argument checking takes a TYPE IS name's rank and type (#707)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  subroutine takes_s(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine t(items)
        \\    class(*), intent(in) :: items(:)
        \\    select type (it => items)
        \\    type is (real)
        \\      call takes_s(it)
        \\      call takes_v(it)
        \\      call takes_s(it(1))
        \\    type is (integer)
        \\      call takes_s(it(1))
        \\    end select
        \\    select type (el => items(2))
        \\    type is (real)
        \\      call takes_s(el)
        \\    end select
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 report lines 14 and 18
    // alone: "Rank mismatch in argument 'x' at (1) (scalar and rank-1)",
    // "Type mismatch in argument 'x' at (1); passed INTEGER(4) to REAL(4)"
    try w.expectDiagnostics("t.f90", &.{
        "14: Argument x of takes_s: a scalar expected, an array given",
        "18: Argument x of takes_s: real expected, integer given",
    });
}

test "argument checking takes a SELECT RANK name's rank and the selector's type (#714)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  integer, parameter :: zero = 0
        \\contains
        \\  subroutine takes_s(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_i(k)
        \\    integer, intent(in) :: k
        \\  end subroutine
        \\  subroutine t(a, z)
        \\    real, intent(in) :: a(..), z(..)
        \\    select rank (r => a)
        \\    rank (0)
        \\      call takes_s(r)
        \\    rank (1)
        \\      call takes_s(r)
        \\      call takes_v(r)
        \\      call takes_s(r(1))
        \\      call takes_i(r(1))
        \\    rank (*)
        \\      call takes_s(r)
        \\    rank default
        \\      call takes_s(r)
        \\    end select
        \\    select rank (w => z)
        \\    rank (zero)
        \\      call takes_s(w)
        \\    end select
        \\    select rank (z)
        \\    rank (1)
        \\      call takes_s(z)
        \\      call takes_v(z)
        \\    rank (0)
        \\      call takes_s(z)
        \\    end select
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 report lines 20, 23, 25,
    // 27 and 35 alone: "Rank mismatch in argument 'x' at (1) (scalar and
    // rank-1)", "Type mismatch in argument 'k' at (1); passed REAL(4) to
    // INTEGER(4)", "The assumed-rank array at (1) requires that the dummy
    // argument 'x' has assumed-rank"; `rank (zero)` is a scalar's
    try w.expectDiagnostics("t.f90", &.{
        "20: Argument x of takes_s: a scalar expected, an array given",
        "23: Argument k of takes_i: integer expected, real given",
        "25: Argument x of takes_s: a scalar expected, an array given",
        "27: Argument x of takes_s: a scalar expected, an array given",
        "35: Argument x of takes_s: a scalar expected, an array given",
    });
}

test "argument checking takes a CLASS DEFAULT name's rank and the selector's type (#714)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  type :: pt
        \\    real :: x
        \\  end type
        \\contains
        \\  subroutine takes_s(x)
        \\    class(*), intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_v(v)
        \\    class(*), intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_r(r)
        \\    real, intent(in) :: r
        \\  end subroutine
        \\  subroutine t(items, p)
        \\    class(*), intent(in) :: items(:)
        \\    class(pt), intent(in) :: p
        \\    select type (it => items)
        \\    class default
        \\      call takes_s(it)
        \\      call takes_v(it)
        \\      call takes_s(it(1))
        \\    end select
        \\    select type (el => items(2))
        \\    class default
        \\      call takes_s(el)
        \\    end select
        \\    select type (items)
        \\    class default
        \\      call takes_s(items)
        \\      call takes_v(items)
        \\    end select
        \\    select type (q => p)
        \\    class default
        \\      call takes_r(q)
        \\    end select
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 report lines 21, 31 and
    // 36 alone: "Rank mismatch in argument 'x' at (1) (scalar and rank-1)",
    // "Type mismatch in argument 'r' at (1); passed CLASS(pt) to REAL(4)"
    try w.expectDiagnostics("t.f90", &.{
        "21: Argument x of takes_s: a scalar expected, an array given",
        "31: Argument x of takes_s: a scalar expected, an array given",
        "36: Argument r of takes_r: real expected, derived given",
    });
}

test "SELECT RANK: a case's rank given by a named constant (#717)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "consts.f90", .text =
        \\module consts
        \\  implicit none
        \\  integer, parameter :: three = 3
        \\end module
        \\
        },
        .{ .name = "t.f90", .text =
        \\module m
        \\  use consts, only: three
        \\  implicit none
        \\  integer, parameter :: zero = 0, two = 2
        \\contains
        \\  subroutine takes_s(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_m(v)
        \\    real, intent(in) :: v(:,:)
        \\  end subroutine
        \\  subroutine t(z)
        \\    real, intent(in) :: z(..)
        \\    integer, parameter :: one = 1
        \\    select rank (w => z)
        \\    rank (zero)
        \\      call takes_s(w)
        \\    rank (one)
        \\      call takes_s(w)
        \\    rank (two)
        \\      call takes_s(w)
        \\      call takes_m(w)
        \\    rank (three)
        \\      print *, w(1, 1, 1)
        \\    end select
        \\  end subroutine
        \\end module
        \\
        },
    }, .{});
    defer w.deinit();
    const want = [_]struct { []const u8, []const u8 }{
        .{ "w)\n    rank (one)", "REAL :: w" },
        .{ "w)\n    rank (two)", "REAL, DIMENSION(:) :: w" },
        .{ "w)\n      call takes_m", "REAL, DIMENSION(:,:) :: w" },
        .{ "w(1, 1, 1)", "REAL, DIMENSION(:,:,:) :: w" },
    };
    for (want) |c| try w.expectHoverContains("t.f90", w.pos("t.f90", c[0], 0, 0), c[1]);
    // gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 report lines 19 and 21
    // alone: "Rank mismatch in argument 'x' at (1) (scalar and rank-1)"
    try w.expectDiagnostics("t.f90", &.{
        "19: Argument x of takes_s: a scalar expected, an array given",
        "21: Argument x of takes_s: a scalar expected, an array given",
    });
}
