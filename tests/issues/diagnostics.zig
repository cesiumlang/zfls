//! Upstream issues about diagnostics.

const std = @import("std");
const h = @import("harness.zig");

test "#406 an external function declared in two subroutines is not a duplicate" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\subroutine foo
        \\  integer bar
        \\  external bar
        \\end subroutine foo
        \\
        \\subroutine foo2
        \\  integer bar
        \\  external bar
        \\end subroutine foo2
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(406, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "#406 a real duplicate is still reported, an EXTERNAL before the type is not one (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\subroutine one
        \\  external bar
        \\  integer bar
        \\end subroutine one
        \\
        \\subroutine two
        \\  integer :: x
        \\  integer :: x
        \\end subroutine two
        \\
        ,
    }}, .{});
    defer w.deinit();
    const ds = try w.diagnostics("t.f90");
    try h.expect(ds.len == 1, "expected the one duplicate, got {d} diagnostics", .{ds.len});
    try h.expect(ds[0].line == 7 and std.mem.indexOf(u8, ds[0].message, "declared twice") != null, "unexpected: line {d}: {s}", .{ ds[0].line + 1, ds[0].message });
}

test "#172 more coarray declarations (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\subroutine co(a, b, c)
        \\  real, intent(in) :: a(5)[*]
        \\  integer, intent(out) :: b[*]
        \\  integer, intent(inout) :: c[2, *]
        \\end subroutine co
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
}

test "#568 a plain USE after a USE ONLY that goes through a re-exporting module" {
    const w = try h.Workspace.init(&.{
        .{ .name = "inner.f90", .text =
        \\module inner
        \\  implicit none
        \\  type :: a_t
        \\    integer :: n = 0
        \\  end type a_t
        \\  type :: b_t
        \\    integer :: n = 0
        \\  end type b_t
        \\end module inner
        \\
        },
        .{ .name = "umbrella.f90", .text =
        \\module umbrella
        \\  use inner
        \\  implicit none
        \\end module umbrella
        \\
        },
        .{ .name = "limited.f90", .text =
        \\module limited
        \\  use umbrella, only: a_t
        \\  implicit none
        \\  private
        \\end module limited
        \\
        },
        .{ .name = "user_fails.f90", .text =
        \\module user_fails
        \\  use limited
        \\  use umbrella
        \\  implicit none
        \\contains
        \\  subroutine s()
        \\    type(b_t) :: b
        \\  end subroutine s
        \\end module user_fails
        \\
        },
        .{ .name = "user_works.f90", .text =
        \\module user_works
        \\  use umbrella
        \\  use limited
        \\  implicit none
        \\contains
        \\  subroutine s()
        \\    type(b_t) :: b
        \\  end subroutine s
        \\end module user_works
        \\
        },
    }, .{});
    defer w.deinit();
    // the control: the same with the two USE lines swapped
    try w.expectNoDiagnostics("user_works.f90");
    try h.check(568, .fixed, w.expectNoDiagnostics("user_fails.f90"));
}

test "#568 USE ONLY still limits what is visible (control)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "inner.f90", .text =
        \\module inner
        \\  type :: a_t
        \\    integer :: n = 0
        \\  end type a_t
        \\  type :: b_t
        \\    integer :: n = 0
        \\  end type b_t
        \\end module inner
        \\
        },
        .{ .name = "umbrella.f90", .text =
        \\module umbrella
        \\  use inner
        \\end module umbrella
        \\
        },
        .{ .name = "user.f90", .text =
        \\module user
        \\  use umbrella, only: a_t
        \\contains
        \\  subroutine s()
        \\    type(a_t) :: a
        \\    type(b_t) :: b
        \\  end subroutine s
        \\end module user
        \\
        },
    }, .{});
    defer w.deinit();
    const ds = try w.diagnostics("user.f90");
    try h.expect(ds.len == 1 and ds[0].line == 5, "expected only b_t (line 6) to be unknown, got {d} diagnostics", .{ds.len});
}

test "#519 IMPORT in an abstract interface, in each of its forms" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module kinds
        \\  integer, parameter :: wp = kind(1.0d0)
        \\end module kinds
        \\
        \\module m
        \\  use kinds, only: wp
        \\  implicit none
        \\  type :: mytype
        \\    integer :: i
        \\  end type mytype
        \\  type :: other
        \\    integer :: j
        \\  end type other
        \\  abstract interface
        \\    subroutine cb1(x, t)
        \\      import :: wp, mytype
        \\      real(wp), intent(in) :: x
        \\      type(mytype), intent(in) :: t
        \\    end subroutine cb1
        \\    subroutine cb2(x, t)
        \\      import wp, mytype
        \\      real(wp), intent(in) :: x
        \\      type(mytype), intent(in) :: t
        \\    end subroutine cb2
        \\    subroutine cb3(x, t)
        \\      import
        \\      real(wp), intent(in) :: x
        \\      type(mytype), intent(in) :: t
        \\    end subroutine cb3
        \\    subroutine cb4(t, o)
        \\      import :: mytype, other
        \\      type(mytype), intent(in) :: t
        \\      type(other), intent(in) :: o
        \\    end subroutine cb4
        \\  end interface
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(519, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "#489 a comment after code in fixed form is not held to max_line_length" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f",
        .text =
        \\      program test
        \\
        \\      implicit none
        \\c This is a comment line, it can go past the 72nd column as;dlfkjams;l ekrjm cw;elj
        \\      integer :: i, j, k
        \\      integer :: some_variable ! This is a comment, if it goes past the 72nd column
        \\      integer :: another_variable ! then it will trigger a warning with fortls using max_line_length=72.
        \\
        \\      i = 1
        \\      j = i + 1
        \\      k = i + j
        \\      some_variable = 10
        \\      another_variable = 20
        \\
        \\      end program test
        \\
        ,
    }}, .{ .settings = .{ .max_line_length = 72, .max_comment_line_length = -1 } });
    defer w.deinit();
    try h.check(489, .fixed, w.expectNoDiagnostics("t.f"));
}

test "#489 code and a trailing comment are held to their own limits (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program p
        \\  integer :: short ! a long trailing comment, past thirty
        \\  integer :: a_very_long_declaration ! c
        \\  integer :: ok ! fine
        \\  ! a whole-line comment that is also long enough to be flagged
        \\end program p
        \\
        ,
    }}, .{ .settings = .{ .max_line_length = 30, .max_comment_line_length = 40 } });
    defer w.deinit();
    const ds = try w.diagnostics("t.f90");
    var code_lines: usize = 0;
    var comment_lines: usize = 0;
    for (ds) |d| {
        if (std.mem.startsWith(u8, d.message, "Line length")) {
            try h.expect(d.line == 2, "code limit reported at line {d}", .{d.line + 1});
            code_lines += 1;
        } else if (std.mem.startsWith(u8, d.message, "Comment line length")) {
            try h.expect(d.line == 1 or d.line == 4, "comment limit reported at line {d}", .{d.line + 1});
            comment_lines += 1;
        }
    }
    // the code of line 3 is too long; the comments of lines 2 and 5 are
    try h.expect(code_lines == 1 and comment_lines == 2, "{d} code and {d} comment diagnostics", .{ code_lines, comment_lines });
}

test "#264 IMPLICIT NONE inside a fixed-form BLOCK DATA" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f",
        .text =
        \\      BLOCKDATA
        \\      IMPLICIT NONE
        \\      COMMON /GRAPHQWDATA/ CCLIENT
        \\      CHARACTER*8 CCLIENT
        \\      DATA CCLIENT /'SCANMF'C/
        \\      ENDBLOCKDATA
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(264, .fixed, w.expectNoDiagnostics("t.f"));
}

test "#470 definitions after a BLOCK DATA unit (from the description; the report shows screenshots)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\block data bd
        \\  common /c/ x
        \\  real :: x
        \\  data x /1.0/
        \\end block data bd
        \\
        \\subroutine s()
        \\end subroutine s
        \\
        \\module m
        \\contains
        \\  subroutine t()
        \\  end subroutine t
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(470, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "#172 a coarray dummy argument is found in the argument list" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program main
        \\  implicit none
        \\contains
        \\  subroutine co_routine(coarray)
        \\    real, allocatable, intent(inout) :: coarray[:]
        \\  end subroutine co_routine
        \\end program main
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(172, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "#72 a single TYPE IS with an associated selector" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\  implicit none
        \\  type :: parent
        \\    integer :: a
        \\  end type parent
        \\  type, extends(parent) :: child1
        \\    integer :: b
        \\  end type child1
        \\contains
        \\  subroutine test_select_sub(self)
        \\    class(parent), intent(inout) :: self
        \\    select type (this => self)
        \\    type is (child1)
        \\      this%a = 1
        \\    end select
        \\  end subroutine test_select_sub
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(72, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "#485 local names are not reported as masking private names of a used module" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module Utils
        \\  implicit none
        \\  private
        \\
        \\  integer x
        \\
        \\  type :: TFileStream
        \\  contains
        \\    procedure :: Error
        \\  end type
        \\
        \\  public TFileStream
        \\contains
        \\
        \\  subroutine Error(this)
        \\    class(TFileStream) :: this
        \\  end subroutine
        \\end module
        \\
        \\program name
        \\  use Utils
        \\
        \\contains
        \\
        \\  subroutine test
        \\    integer error
        \\    integer x
        \\  end subroutine
        \\
        \\end program name
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(485, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "hansec #200 a dummy procedure's interface body does not mask the host's variables" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\subroutine foo(f)
        \\  interface
        \\    function f(x)
        \\      real, intent(in) :: x
        \\      real :: f
        \\    end function
        \\  end interface
        \\  real :: x
        \\end subroutine
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 200, .fixed, w.expectNoDiagnosticLike("t.f90", "masks"));
}

test "a separate module procedure interface still sees its module (control for hansec #200)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\  real :: x
        \\  interface
        \\    module subroutine s()
        \\      real :: x
        \\    end subroutine
        \\  end interface
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    const diags = try w.diagnostics("t.f90");
    var masks = false;
    for (diags) |d| if (std.mem.indexOf(u8, d.message, "masks") != null) {
        masks = true;
    };
    try h.expect(masks, "no masking warning in a module procedure interface", .{});
}

test "hansec #229 DO and ASSOCIATE opened and closed on single lines with ;" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program p
        \\  implicit none
        \\  integer :: i
        \\  real :: arr(3)
        \\  do i=1,size(arr); associate(point => arr(i))
        \\    point = 1.0
        \\  end associate; end do
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 229, .fixed, w.expectNoDiagnostics("t.f90"));
}

const masking =
    \\module m
    \\  integer :: n
    \\contains
    \\  subroutine s()
    \\    integer :: n
    \\    integer :: k
    \\    integer :: k
    \\  end subroutine s
    \\end module m
    \\
;

fn hasCode(diags: []const h.Diagnostic, code: []const u8) bool {
    for (diags) |d| if (std.mem.eql(u8, d.code, code)) return true;
    return false;
}

fn severityOf(diags: []const h.Diagnostic, code: []const u8) i64 {
    for (diags) |d| if (std.mem.eql(u8, d.code, code)) return d.severity;
    return 0;
}

fn expectSeverities(w: *h.Workspace) !void {
    const diags = try w.diagnostics("m.f90");
    try h.expect(!hasCode(diags, "masks-parent"), "masks-parent is reported though it is off", .{});
    try h.expect(severityOf(diags, "declared-twice") == 2, "declared-twice has severity {d}, not 2 (warning)", .{severityOf(diags, "declared-twice")});
}

test "#438 diagnostics have codes, which diagnostic_severity can turn off or change" {
    {
        // the codes, by default
        const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text = masking }}, .{});
        defer w.deinit();
        const diags = try w.diagnostics("m.f90");
        try std.testing.expect(hasCode(diags, "masks-parent"));
        try std.testing.expectEqual(@as(i64, 1), severityOf(diags, "declared-twice"));
    }
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text = masking }}, .{ .diagnostic_severity = &.{
        .{ .code = "masks-parent", .level = "off" },
        .{ .code = "declared-twice", .level = "warning" },
    } });
    defer w.deinit();
    try h.check(438, .fixed, expectSeverities(w));
}

fn expectSuppressed(w: *h.Workspace) !void {
    const diags = try w.diagnostics("m.f90");
    try h.expect(!hasCode(diags, "masks-parent"), "the comment does not hide masks-parent", .{});
    try h.expect(hasCode(diags, "declared-twice"), "the comment hides more than masks-parent", .{});
}

test "Modern Fortran #981 a comment hides a masks-parent warning" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text =
        \\module m
        \\  integer :: n
        \\contains
        \\  subroutine s()
        \\    integer :: n ! zfls: disable=masks-parent
        \\    integer :: k
        \\    integer :: k
        \\  end subroutine s
        \\end module m
        \\
    }}, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 981, .fixed, expectSuppressed(w));
}

test "disable-next-line and disable-file comments" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text =
        \\! zfls: disable-file=declared-twice
        \\module m
        \\  integer :: n
        \\contains
        \\  subroutine s()
        \\    ! zfls: disable-next-line
        \\    integer :: n
        \\    integer :: k
        \\    integer :: k
        \\  end subroutine s
        \\end module m
        \\
    }}, .{});
    defer w.deinit();
    const diags = try w.diagnostics("m.f90");
    try std.testing.expect(!hasCode(diags, "masks-parent"));
    try std.testing.expect(!hasCode(diags, "declared-twice"));
}

fn expectNoMissingModule(w: *h.Workspace) !void {
    const diags = try w.diagnostics("p.f90");
    for (diags) |d| try h.expect(!std.mem.eql(u8, d.code, "module-not-found") or std.mem.indexOf(u8, d.message, "mine") != null, "{s}", .{d.message});
    try h.expect(hasCode(diags, "module-not-found"), "a module of the project that is missing is not reported", .{});
}

test "Modern Fortran #1306 external_modules names the modules of libraries such as MPI" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text =
        \\program p
        \\  use mpi
        \\  use petsc_sys
        \\  use mine
        \\  implicit none
        \\end program p
        \\
    }}, .{ .external_modules = &.{ "MPI", "petsc*" } });
    defer w.deinit();
    try h.checkIn(.modern_fortran, 1306, .fixed, expectNoMissingModule(w));
}
