//! Hover, definition and references on the elements of the language:
//! implicit types, keywords, directives, operators, defined assignment,
//! literals and the MPI stubs.

const std = @import("std");
const h = @import("harness.zig");

fn expectImplicitTypes(w: *h.Workspace) !void {
    // the IMPLICIT statement of the module, through host association
    try w.expectHoverContains("t.f90", w.pos("t.f90", "z = c*t", 0, 6), "REAL(c_double) :: t");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "beta*r", 0, 0), "REAL(c_double) :: beta");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "n2 = 1", 0, 0), "INTEGER(c_int) :: n2");
    // declared names keep their declaration
    try w.expectHoverContains("t.f90", w.pos("t.f90", "z = c*t", 0, 0), "COMPLEX(c_double_complex)");
    // the default rules in a unit without IMPLICIT statements
    try w.expectHoverContains("d.f90", w.pos("d.f90", "k = x", 0, 0), "INTEGER :: k");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "k = x", 0, 4), "REAL :: x");
    // nothing under IMPLICIT NONE, nor on keywords
    try h.expect((try w.hover("n.f90", w.pos("n.f90", "q = 1", 0, 0))) == null, "a name under IMPLICIT NONE has a type", .{});
    try h.expect((try w.hover("d.f90", w.pos("d.f90", "then", 0, 1))) == null, "THEN has a type", .{});
    try h.expect((try w.hover("d.f90", w.pos("d.f90", "call ext", 0, 6))) == null, "a subroutine called has a type", .{});
}

test "hansec #201 hover shows the type implicit typing gives a name that is not declared" {
    const w = try h.Workspace.init(&.{
        .{ .name = "t.f90", .text =
        \\module oumods
        \\  use, intrinsic :: iso_c_binding
        \\  implicit integer(c_int) (i-k), integer(c_int) (m,n), &
        \\       & real(c_double) (a-h), real(c_double) (l), real(c_double) (o-z)
        \\contains
        \\  subroutine zI12(t,c,alpha,beta,r)
        \\    complex(c_double_complex) c,r,    x,y,z
        \\     z = c*t
        \\     r = beta*r+alpha*((t*y - x)/c)
        \\     n2 = 1
        \\  end subroutine
        \\end module
        \\
        },
        .{ .name = "d.f90", .text =
        \\program d
        \\  if (.true.) then
        \\    k = x
        \\    call ext(k)
        \\  end if
        \\end program d
        \\
        },
        .{ .name = "n.f90", .text =
        \\program n
        \\  implicit none
        \\  q = 1
        \\end program n
        \\
        },
    }, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 201, .fixed, expectImplicitTypes(w));
}

fn expectKeywordHover(w: *h.Workspace) !void {
    try w.expectHoverContains("k.f90", w.pos("k.f90", "allocate(x", 0, 2), "Dynamically creates storage");
    try w.expectHoverContains("k.f90", w.pos("k.f90", "intent(in)", 0, 2), "INTENT(IN)");
    try w.expectHoverContains("k.f90", w.pos("k.f90", "call s", 0, 1), "Transfers control to a subroutine");
    // a variable spelled like a keyword is the variable
    try w.expectHoverContains("k.f90", w.pos("k.f90", "len = 2", 0, 0), "INTEGER :: len");
}

test "#547 hover on a statement or attribute keyword shows its documentation" {
    const w = try h.Workspace.init(&.{.{ .name = "k.f90", .text =
        \\program k
        \\  implicit none
        \\  real, allocatable :: x(:)
        \\  integer :: len
        \\  allocate(x(10))
        \\  len = 2
        \\  call s(x)
        \\contains
        \\  subroutine s(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine s
        \\end program k
        \\
    }}, .{});
    defer w.deinit();
    try h.check(547, .fixed, expectKeywordHover(w));
}

test "MPI stubs: hover, signature help and completion of mpi and mpi_f08" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text =
        \\program m
        \\  use mpi_f08
        \\  implicit none
        \\  integer :: rank, ierr
        \\  call MPI_Init(ierr)
        \\  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
        \\  call MPI_Finalize()
        \\end program m
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("m.f90", w.pos("m.f90", "MPI_COMM_WORLD", 0, 1), "TYPE(MPI_Comm)");
    try w.expectHoverContains("m.f90", w.pos("m.f90", "MPI_Comm_rank", 0, 1), "SUBROUTINE mpi_comm_rank(comm, rank, ierror)");
    const sig = (try w.signature("m.f90", w.pos("m.f90", "rank, ierr)", 0, 0))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), sig.active);
    // no module-not-found, and no warnings about MPI names
    try w.expectNoDiagnostics("m.f90");
}

test "coarrays: hover shows the codimension, from the name or the attribute" {
    const w = try h.Workspace.init(&.{.{ .name = "c.f90", .text =
        \\program c
        \\  implicit none
        \\  real :: x[*]
        \\  real, codimension[2,*] :: y(10)
        \\  x = 1.0
        \\  y(1)[1,1] = x[2]
        \\end program c
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("c.f90", w.pos("c.f90", "x = 1.0", 0, 0), "REAL, CODIMENSION[*] :: x");
    try w.expectHoverContains("c.f90", w.pos("c.f90", "y(1)[1,1]", 0, 0), "REAL, CODIMENSION[2,*], DIMENSION(10) :: y");
}

test "hover on the words of OpenMP and OpenACC directives" {
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text =
        \\program d
        \\  integer :: i, s
        \\  s = 0
        \\  !$omp parallel do private(i) reduction(+:s)
        \\  do i = 1, 10
        \\    s = s + i
        \\  end do
        \\  !$omp end parallel do
        \\  !$acc data copyin(s)
        \\  !$acc end data
        \\end program d
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("d.f90", w.pos("d.f90", "parallel do private", 0, 2), "Creates a team of threads");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "reduction(+", 0, 2), "!$OMP REDUCTION");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "copyin(s)", 0, 2), "Copies the variables to the accelerator");
    // not on the sentinel, nor on a variable of a clause
    try std.testing.expect((try w.hover("d.f90", w.pos("d.f90", "!$omp parallel", 0, 1))) == null);
}

fn expectOperators(w: *h.Workspace) !void {
    const d = (try w.definition("o.f90", w.pos("o.f90", ".ord. 3", 0, 2))) orelse return h.unmet("no definition of .ord.", .{});
    try h.expect(d.line == w.pos("o.f90", "interface operator", 0, 0).line, ".ord. goes to line {d}", .{d.line});
    try w.expectHoverContains("o.f90", w.pos("o.f90", ".ORD.k", 0, 3), "FUNCTION ord_int(a)");
    const refs = try w.references("o.f90", w.pos("o.f90", ".ord. 3", 0, 2));
    // the interface line, its END, and the two uses
    try h.expect(refs.len == 4, "{d} references", .{refs.len});
    // intrinsic operators are not
    try h.expect((try w.definition("o.f90", w.pos("o.f90", ".and.", 0, 2))) == null, ".and. has a definition", .{});
}

test "hansec #95 definition, hover and references of user-defined operators" {
    const w = try h.Workspace.init(&.{.{ .name = "o.f90", .text =
        \\module ops
        \\  interface operator (.ord.)
        \\    module procedure ord_int
        \\  end interface operator (.ord.)
        \\contains
        \\  integer function ord_int(a)
        \\    integer, intent(in) :: a
        \\    ord_int = a
        \\  end function ord_int
        \\end module ops
        \\program p
        \\  use ops
        \\  integer :: k
        \\  logical :: t
        \\  k = .ord. 3
        \\  k = .ORD.k
        \\  t = t .and. t
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 95, .fixed, expectOperators(w));
}

fn expectLiteralHover(w: *h.Workspace) !void {
    try w.expectHoverContains("l.f90", w.pos("l.f90", "3.0_dp", 0, 1), "REAL(dp)");
    try w.expectHoverContains("l.f90", w.pos("l.f90", "1d0", 0, 1), "DOUBLE PRECISION");
    try w.expectHoverContains("l.f90", w.pos("l.f90", "7_8", 0, 0), "INTEGER(8)");
    try w.expectHoverContains("l.f90", w.pos("l.f90", "'abc'", 0, 2), "CHARACTER(LEN=3)");
    try w.expectHoverContains("l.f90", w.pos("l.f90", ".false._1", 0, 2), "LOGICAL(1)");
    try w.expectHoverContains("l.f90", w.pos("l.f90", "z'ff'", 0, 2), "value 255");
}

test "#125 hover on a literal constant shows its type with its kind" {
    const w = try h.Workspace.init(&.{.{ .name = "l.f90", .text =
        \\program l
        \\  integer, parameter :: dp = kind(1d0)
        \\  real(dp) :: x
        \\  character(len=3) :: s
        \\  logical :: t
        \\  x = 3.0_dp + 1d0 + 7_8 + z'ff'
        \\  s = 'abc'
        \\  t = .false._1
        \\end program l
        \\
    }}, .{});
    defer w.deinit();
    try h.check(125, .fixed, expectLiteralHover(w));
}

fn expectLowercaseHover(w: *h.Workspace) !void {
    try w.expectHoverContains("c.f90", w.pos("c.f90", "X, name", 0, 0), "real, intent(in) :: X");
    try w.expectHoverContains("c.f90", w.pos("c.f90", "s(X)", 0, 0), "subroutine s(X)");
    try w.expectHoverContains("c.f90", w.pos("c.f90", "name = 'IN", 0, 0), "character(len=4), parameter :: name = 'IN T'");
}

test "#28 lowercase_hover: keywords in hover in lowercase" {
    const w = try h.Workspace.init(&.{.{ .name = "c.f90", .text =
        \\module c
        \\contains
        \\  subroutine s(X)
        \\    real, intent(in) :: X
        \\    character(len=4), parameter :: name = 'IN T'
        \\    print *, X, name
        \\  end subroutine s
        \\end module c
        \\
    }}, .{ .settings = .{ .lowercase_hover = true } });
    defer w.deinit();
    try h.check(28, .fixed, expectLowercaseHover(w));
}

fn expectAssignment(w: *h.Workspace) !void {
    // on the `=` of an assignment to a type with a GENERIC binding
    const d = (try w.definition("a.f90", w.pos("a.f90", "= 1 ! t", 0, 0))) orelse return h.unmet("no definition of = for t", .{});
    try h.expect(d.line == w.pos("a.f90", "generic :: assignment", 0, 0).line, "= of t goes to line {d}", .{d.line});
    // a type extending it has it too
    const e = (try w.definition("a.f90", w.pos("a.f90", "= 4 ! e", 0, 0))) orelse return h.unmet("no definition of = for e", .{});
    try h.expect(e.line == d.line, "= of e goes to line {d}", .{e.line});
    // an interface for the type
    const f = (try w.definition("a.f90", w.pos("a.f90", "= 2 ! u", 0, 0))) orelse return h.unmet("no definition of = for u", .{});
    try h.expect(f.line == w.pos("a.f90", "interface assignment", 0, 0).line, "= of u goes to line {d}", .{f.line});
    try w.expectHoverContains("a.f90", w.pos("a.f90", "= 2 ! u", 0, 0), "SUBROUTINE assign_u(lhs, rhs)");
    // the binding, and the assignments to t and e
    const refs = try w.references("a.f90", w.pos("a.f90", "assignment(=) =>", 0, 3));
    try h.expect(refs.len == 4, "{d} references of t's assignment", .{refs.len});
    // no defined assignment for an integer, nor for `==`
    try h.expect((try w.definition("a.f90", w.pos("a.f90", "= 3 ! i", 0, 0))) == null, "= of an integer has a definition", .{});
}

test "hansec #95 definition, hover and references of defined assignment" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module m
        \\  type :: t
        \\    integer :: v
        \\  contains
        \\    procedure :: assign_t
        \\    generic :: assignment(=) => assign_t
        \\  end type t
        \\  type, extends(t) :: e
        \\  end type e
        \\  type :: u
        \\    integer :: w
        \\  end type u
        \\  interface assignment(=)
        \\    module procedure assign_u
        \\  end interface assignment(=)
        \\contains
        \\  subroutine assign_t(lhs, rhs)
        \\    class(t), intent(out) :: lhs
        \\    integer, intent(in) :: rhs
        \\    lhs%v = rhs
        \\  end subroutine assign_t
        \\  subroutine assign_u(lhs, rhs)
        \\    type(u), intent(out) :: lhs
        \\    integer, intent(in) :: rhs
        \\    lhs%w = rhs
        \\  end subroutine assign_u
        \\end module m
        \\program p
        \\  use m
        \\  type(t) :: x
        \\  type(e) :: y
        \\  type(u) :: z
        \\  integer :: i
        \\  x = 1 ! t
        \\  z = 2 ! u
        \\  i = 3 ! i
        \\  y = 4 ! e
        \\  if (i == 3) x = 5
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 95, .fixed, expectAssignment(w));
}
