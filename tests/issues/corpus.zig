//! Diagnostics that were wrong on valid code of large code bases: LAPACK
//! (fixed form, FORTRAN 77 and Fortran 90), the Fortran stdlib and
//! json-fortran, scanned with `workspace_diagnostics`. Each fixture is cut
//! down from the code that showed it, and gfortran compiles it.

const std = @import("std");
const h = @import("harness.zig");

fn expectClean(w: *h.Workspace, name: []const u8) !void {
    w.expectNoDiagnostics(name) catch |e| {
        std.debug.print("\n{s}\n", .{h.lastNote()});
        return e;
    };
}

test "LAPACK: a statement after the condition of an IF on the line that continues it" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f", .text =
        \\      SUBROUTINE S( N, X, TRACE )
        \\      IMPLICIT NONE
        \\      INTEGER N, NTRA
        \\      DOUBLE PRECISION X
        \\      LOGICAL TRACE
        \\      EXTERNAL FOO
        \\      NTRA = 6
        \\      IF( TRACE )
        \\     $   CALL FOO( N )
        \\      IF( TRACE )
        \\     $   WRITE( NTRA, * )N
        \\      IF( TRACE )
        \\     $   REWIND NTRA
        \\      IF( (N.EQ.0) .OR.
        \\     $    (N.GT.10) ) RETURN
        \\      IF( X.LT.0.0D0 )
        \\     $   GO TO 10
        \\      IF( TRACE .AND .( N.GT.2 ) ) X = 0.0D0
        \\   10 CONTINUE
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "s.f");
}

test "free form: a statement after an IF condition continued with &" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine t(x, n)
        \\  implicit none
        \\  real, intent(inout) :: x
        \\  integer, intent(in) :: n
        \\  if (n > 0) &
        \\     return
        \\  if (x < 0.0 .and. &
        \\      n > 1) x = 0.0
        \\  if (x > 1.0) then
        \\    x = 1.0
        \\  end if
        \\end subroutine t
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "t.f90");
}

test "stdlib: keyword arguments on the lines that continue a call" {
    const w = try h.Workspace.init(&.{.{ .name = "logs.f90", .text =
        \\module logs
        \\  implicit none
        \\contains
        \\  subroutine log_error(msg, module, procedure)
        \\    character(*), intent(in) :: msg
        \\    character(*), intent(in), optional :: module, procedure
        \\    print *, msg
        \\  end subroutine log_error
        \\  subroutine t()
        \\    call log_error('This message ' //  &
        \\        'is long.',                    &
        \\        module = 'N/A',                &
        \\        procedure = 'T')
        \\  end subroutine t
        \\end module logs
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "logs.f90");
}

test "LAPACK: the words of a character literal continued over two lines" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program t
        \\  implicit none
        \\  print *, 'Call to CGEDMD workspace query failed. &
        \\           &Check the calling sequence and the code.'
        \\  print *, "it's &
        \\     &continued, ""quoted"" &
        \\     &and done"
        \\end program t
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "t.f90");
}

test "LAPACK: specific names of intrinsic functions (DSQRT, FLOAT, IDNINT)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f", .text =
        \\      SUBROUTINE S( N, X, I )
        \\      IMPLICIT NONE
        \\      INTEGER N, I
        \\      DOUBLE PRECISION X
        \\      X = DSQRT( DABS( X ) ) + FLOAT( N ) + DSIGN( X, 1.0D0 )
        \\      I = IDNINT( DLOG( X ) ) + MAX0( N, 1 )
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "s.f");
}

test "LAPACK: labelled DO loops ended by END DO with their labels" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f", .text =
        \\      SUBROUTINE S( A, N )
        \\      IMPLICIT NONE
        \\      INTEGER N, I, J, K
        \\      DOUBLE PRECISION A( N, N )
        \\      DO 50 K = 1, 2
        \\         DO 20 J = 1, N
        \\            DO 30 I = 1, N
        \\               A( I, J ) = 0.0D0
        \\   30       END DO
        \\   20    END DO
        \\         DO 40 I = 1, N
        \\            A( I, I ) = 1.0D0
        \\   40    CONTINUE
        \\   50 CONTINUE
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "s.f");
    // the loops end where they should: the subroutine still holds `40`
    const syms = try w.documentSymbols("s.f");
    try h.expect(syms.len > 0, "no symbols", .{});
}

test "LAPACK: a main program without a PROGRAM statement" {
    const w = try h.Workspace.init(&.{.{ .name = "main.f", .text =
        \\*     tests DLAMCH
        \\      DOUBLE PRECISION X
        \\      X = 1.0D0
        \\      PRINT *, X
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "main.f");
}

test "json-fortran: dummy arguments declared in an #include file that is no source file" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.F90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  subroutine add(json, value)
        \\    integer, intent(in) :: value
        \\#include "decl.inc"
        \\    json = value
        \\  end subroutine add
        \\  subroutine other(x)
        \\    integer :: y
        \\  end subroutine other
        \\end module m
        \\
        },
        .{ .name = "decl.inc", .text =
        \\    integer, intent(inout) :: json
        \\
        },
    }, .{});
    defer w.deinit();
    const ds = try w.diagnostics("m.F90");
    var n: usize = 0;
    for (ds) |d| if (std.mem.eql(u8, d.code, "argument-not-declared")) {
        n += 1;
        // only the argument of the procedure without the include
        try h.expect(std.mem.find(u8, d.message, "\"x\"") != null, "{s}", .{d.message});
    };
    try h.expect(n == 1, "{d} argument-not-declared", .{n});
}

test "stdlib: names a used module makes public from a module zfls does not have" {
    const w = try h.Workspace.init(&.{
        .{ .name = "stats.f90", .text =
        \\module stats
        \\  use stats_descriptive, only: mean
        \\  implicit none
        \\  private
        \\  public :: mean
        \\end module stats
        \\
        },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use stats, only: mean
        \\  implicit none
        \\  print *, mean([1.0, 2.0])
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try w.expectNoDiagnosticLike("p.f90", "is not declared");
}

test "stdlib: CLASS(*) and assumed-rank dummy arguments take any type; a % f() binds its object" {
    const w = try h.Workspace.init(&.{.{ .name = "poly.f90", .text =
        \\module poly
        \\  implicit none
        \\  type :: map_t
        \\    integer :: n = 0
        \\  contains
        \\    procedure, pass(map) :: entries
        \\  end type map_t
        \\contains
        \\  subroutine show(a1, a2)
        \\    class(*), intent(in) :: a1
        \\    class(*), intent(in), optional, dimension(..) :: a2
        \\  end subroutine show
        \\  integer function entries(map)
        \\    class(map_t), intent(in) :: map
        \\    entries = map%n
        \\  end function entries
        \\  subroutine use_it(map)
        \\    class(map_t), intent(in) :: map
        \\    call show('text', 'more')
        \\    call show(1, [1, 2])
        \\    print *, map % entries()
        \\  end subroutine use_it
        \\end module poly
        \\
    }}, .{});
    defer w.deinit();
    try expectClean(w, "poly.f90");
}

test "stdlib: a separate module function with its type first (`real(dp) module function`)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text =
        \\module m
        \\  implicit none
        \\  interface
        \\    real module function lifetime(n) result(t)
        \\      integer, intent(in) :: n
        \\    end function lifetime
        \\    module subroutine wait_for(n)
        \\      integer, intent(in) :: n
        \\    end subroutine wait_for
        \\  end interface
        \\end module m
        \\
        },
        .{ .name = "s.f90", .text =
        \\submodule (m) s
        \\  implicit none
        \\contains
        \\  real module function lifetime(n) result(t)
        \\    integer, intent(in) :: n
        \\    integer :: count_max
        \\    count_max = n
        \\    t = real(count_max)
        \\  end function lifetime
        \\  module subroutine wait_for(n)
        \\    integer, intent(in) :: n
        \\    integer :: count_max
        \\    count_max = n
        \\    print *, count_max
        \\  end subroutine wait_for
        \\end submodule s
        \\
        },
    }, .{});
    defer w.deinit();
    try expectClean(w, "s.f90");
}

test "stdlib: a kind from the ancestor of a submodule that is not in the workspace" {
    const w = try h.Workspace.init(&.{
        .{ .name = "kinds.f90", .text =
        \\module other_kinds
        \\  implicit none
        \\  integer, parameter :: int_index = 8
        \\end module other_kinds
        \\
        },
        .{ .name = "s.f90", .text =
        \\submodule (generated_sorting) radix
        \\  implicit none
        \\contains
        \\  pure subroutine helper(n)
        \\    integer(kind=int_index), intent(in) :: n
        \\  end subroutine helper
        \\end submodule radix
        \\
        },
    }, .{});
    defer w.deinit();
    try w.expectNoDiagnosticLike("s.f90", "not found in scope");
}

test "control: what the fixes leave reported" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f", .text =
        \\      SUBROUTINE S( N, X )
        \\      IMPLICIT NONE
        \\      INTEGER N
        \\      DOUBLE PRECISION X
        \\      IF( N.GT.0 )
        \\     $   X = UNDEF1
        \\      PRINT *, 'text', UNDEF2
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    var found: std.ArrayList([]const u8) = .empty;
    defer found.deinit(std.testing.allocator);
    for (try w.diagnostics("s.f")) |d| {
        if (std.mem.eql(u8, d.code, "undeclared-name")) try found.append(std.testing.allocator, d.message);
    }
    try h.expect(found.items.len == 2, "undeclared: {any}", .{found.items});
}

test "control: a kind from a module that is not used, all modules known" {
    const w = try h.Workspace.init(&.{
        .{ .name = "kinds.f90", .text =
        \\module other_kinds
        \\  implicit none
        \\  integer, parameter :: int_index = 8
        \\end module other_kinds
        \\
        },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use iso_fortran_env, only: int64
        \\  implicit none
        \\  integer(kind=int_index) :: n
        \\  n = 1_int64
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    var n: usize = 0;
    for (try w.diagnostics("p.f90")) |d| {
        if (std.mem.find(u8, d.message, "not found in scope") != null) n += 1;
    }
    try h.expect(n == 1, "{d} not found in scope", .{n});
}

// The Fortran stdlib with its fypp sources generated
// (`config/fypp_deployment.py --deploy_stdlib_fpm`)

test "stdlib: a .F90 file whose lines are indented 5 columns is free form" {
    const w = try h.Workspace.init(&.{
        .{ .name = "kinds.f90", .text =
        \\module kinds
        \\  implicit none
        \\  integer, parameter :: sp = selected_real_kind(6)
        \\end module kinds
        \\
        },
        // no line indented 1 to 4 columns, nor one that ends with `&`:
        // read as fixed form, `use` was a continuation of `module`
        .{ .name = "consts.F90", .text =
        \\module consts
        \\     use kinds, only: sp
        \\     implicit none
        \\     public
        \\end module consts
        \\
        },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use consts, only: sp
        \\  implicit none
        \\  real(sp) :: a
        \\  a = 1.0_sp
        \\  print *, a
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try expectClean(w, "p.f90");
}

test "stdlib: enumerators are names of the scope around the ENUM, PUBLIC by name" {
    const w = try h.Workspace.init(&.{
        .{ .name = "solvers.f90", .text =
        \\module solvers
        \\  implicit none
        \\  private
        \\  enum, bind(c)
        \\    enumerator :: pc_none = 0
        \\    enumerator :: pc_jacobi
        \\  end enum
        \\  enum, bind(c)
        \\    enumerator comma, colon
        \\  end enum
        \\  public :: pc_none, pc_jacobi, kind_of
        \\contains
        \\  integer function kind_of(k)
        \\    integer, intent(in) :: k
        \\    kind_of = merge(comma, colon, k == pc_none)
        \\  end function kind_of
        \\end module solvers
        \\
        },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use solvers, only: pc_jacobi, kind_of
        \\  implicit none
        \\  print *, kind_of(pc_jacobi)
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try expectClean(w, "solvers.f90");
    try expectClean(w, "p.f90");
    const hover = (try w.hover("p.f90", w.pos("p.f90", "pc_jacobi)", 0, 1))) orelse return h.unmet("no hover on pc_jacobi", .{});
    try h.expect(std.mem.find(u8, hover, "PARAMETER") != null, "{s}", .{hover});
}

test "stdlib: BOZ literals, a logical literal's kind, SELECT RANK, an OPEN statement beside a function open" {
    const w = try h.Workspace.init(&.{
        .{ .name = "io.f90", .text =
        \\module io
        \\  use iso_fortran_env, only: int8, int32
        \\  implicit none
        \\contains
        \\  integer function open(filename)
        \\    character(*), intent(in) :: filename
        \\    open(newunit=open, file=filename, status='old', action='read')
        \\  end function open
        \\  subroutine show(a)
        \\    class(*), intent(in) :: a(..)
        \\    integer(int32) :: h
        \\    logical(int8) :: flag
        \\    h = int(z'7F', int32) + int(Z'1F', int32) + int(b"101", int32)
        \\    flag = .false._int8
        \\    select rank (v => a)
        \\    rank (0)
        \\      call put(v)
        \\    rank (1)
        \\      print *, size(v)
        \\    rank default
        \\      print *, rank(v)
        \\    end select
        \\    print *, h, flag
        \\  end subroutine show
        \\  subroutine put(x)
        \\    class(*), intent(in) :: x
        \\  end subroutine put
        \\end module io
        \\
        },
    }, .{});
    defer w.deinit();
    try expectClean(w, "io.f90");
}
