//! The declarations of Fortran 2018 and 2023: the SIMPLE and NON_RECURSIVE
//! prefixes, TYPEOF and CLASSOF, the RANK clause.

const std = @import("std");
const h = @import("harness.zig");

test "the SIMPLE (F2023) and NON_RECURSIVE (F2018) prefixes (#727)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m_simple
        \\  implicit none
        \\contains
        \\  simple function twice(x) result(y)
        \\    real, intent(in) :: x
        \\    real :: y
        \\    y = 2*x
        \\  end function
        \\  non_recursive subroutine once(k)
        \\    integer, intent(inout) :: k
        \\    k = k + 1
        \\  end subroutine
        \\  simple elemental subroutine inc(k)
        \\    integer, intent(inout) :: k
        \\    k = k + 1
        \\  end subroutine
        \\  subroutine user()
        \\    integer :: n
        \\    n = 1
        \\    call once(n)
        \\    call inc(n)
        \\    print *, twice(1.0)
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
    const syms = try w.documentSymbols("t.f90");
    for ([_][]const u8{ "twice", "once", "inc" }) |name| {
        var found = false;
        for (syms) |s| found = found or std.mem.eql(u8, s, name);
        try h.expect(found, "{s} not among the symbols: {any}", .{ name, syms });
    }
    try w.expectHoverContains("t.f90", w.pos("t.f90", "twice(1.0)", 0, 0), "SIMPLE FUNCTION twice(x) RESULT(y)");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "once(n)", 0, 0), "NON_RECURSIVE SUBROUTINE once(k)");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "inc(n)", 0, 0), "SIMPLE ELEMENTAL SUBROUTINE inc(k)");
}

test "TYPEOF and CLASSOF declare entities of the type of another (F2023, #728)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m_typeof
        \\  implicit none
        \\  type :: pt
        \\    real :: x = 0
        \\    integer :: n(3) = 0
        \\  end type
        \\contains
        \\  subroutine s(p)
        \\    class(pt), intent(in) :: p
        \\    classof(p), allocatable :: q
        \\    typeof(p%x) :: y
        \\    typeof(p) :: r
        \\    typeof(p%n) :: m
        \\    allocate(q, source=p)
        \\    y = q%x
        \\    r = p
        \\    m = 1
        \\    print *, y, r%x, m
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "q, source", 0, 0), "CLASS(pt), ALLOCATABLE :: q");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "y = q%x", 0, 0), "REAL :: y");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "r = p", 0, 0), "TYPE(pt) :: r");
    // the type, not the rank
    try w.expectHoverContains("t.f90", w.pos("t.f90", "m = 1", 0, 0), "INTEGER :: m");
    // the components of the type
    try w.expectHoverContains("t.f90", w.pos("t.f90", "q%x", 0, 2), "REAL :: x");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "r%x", 0, 2), "REAL :: x");
}

test "the RANK clause (F2023) gives the rank and keeps the other attributes (#729)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "c.f90", .text =
        \\module consts
        \\  implicit none
        \\  integer, parameter :: three = 3
        \\end module
        \\
        },
        .{ .name = "t.f90", .text =
        \\module m_rank
        \\  use consts, only: three
        \\  implicit none
        \\  integer, parameter :: two = 2
        \\contains
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_m(v)
        \\    real, intent(in) :: v(:,:)
        \\  end subroutine
        \\  subroutine s(d)
        \\    real, rank(1), intent(in) :: d
        \\    real, rank(2), allocatable :: a
        \\    real, rank(1), pointer :: p
        \\    real, allocatable, rank(two) :: b
        \\    real, rank(three), allocatable :: c
        \\    real, rank(0), pointer :: e
        \\    call takes_v(d)
        \\    call takes_m(a)
        \\    call takes_v(p)
        \\    call takes_m(b)
        \\    call takes_v(a)
        \\    print *, size(c), associated(e)
        \\  end subroutine
        \\end module
        \\
        },
    }, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "d)\n    call takes_m", 0, 0), "REAL, DIMENSION(:), INTENT(IN) :: d");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "a)\n    call takes_v(p)", 0, 0), "REAL, DIMENSION(:,:), ALLOCATABLE :: a");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "p)\n", 0, 0), "REAL, DIMENSION(:), POINTER :: p");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "b)\n", 0, 0), "REAL, ALLOCATABLE, DIMENSION(:,:) :: b");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "c), associated", 0, 0), "REAL, DIMENSION(:,:,:), ALLOCATABLE :: c");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "e)\n", 0, 0), "REAL, POINTER :: e");
    // the one call of another rank, as Flang and ifx report it
    try w.expectDiagnostics("t.f90", &.{"23: Argument v of takes_v: rank 1 expected, rank 2 given"});
}

test "a RANK clause whose rank cannot be told is no rank to check (#729)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m_rank
        \\  use unknown_module, only: nd
        \\  implicit none
        \\contains
        \\  subroutine takes_s(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine s(d)
        \\    real, rank(nd), intent(in) :: d
        \\    call takes_s(d)
        \\    call takes_v(d)
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnosticLike("t.f90", "Argument");
}
