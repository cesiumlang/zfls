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
    var ds: std.ArrayList(h.Diagnostic) = .empty;
    defer ds.deinit(std.testing.allocator);
    // the variables are not used: those hints are not what this is about
    for (try w.diagnostics("user.f90")) |d| if (!std.mem.eql(u8, d.code, "unused-name")) try ds.append(std.testing.allocator, d);
    try h.expect(ds.items.len == 1 and ds.items[0].line == 5, "expected only b_t (line 6) to be unknown, got {d} diagnostics", .{ds.items.len});
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

const undeclared = [_]h.File{
    .{ .name = "consts.f90", .text =
    \\module consts
    \\  implicit none
    \\  integer, parameter :: dp = kind(1.d0)
    \\  type :: pt
    \\    real(dp) :: x
    \\  end type pt
    \\end module consts
    \\
    },
    .{ .name = "p.f90", .text =
    \\program p
    \\  use consts
    \\  implicit none
    \\  integer :: i, n
    \\  real(dp) :: total
    \\  type(pt) :: a
    \\  n = 3
    \\  total = 0.0_dp
    \\  outer: do i = 1, n
    \\    if (i > 2) exit outer
    \\    if (i == 1) print *, sqrt(real(i, kind=dp))
    \\    total = total + a%x + 1.d0
    \\    call external_sub(i)
    \\    kount = kount + 1
    \\  end do outer
    \\  do while (n > 0)
    \\    n = n - 1
    \\  end do
    \\  open(newunit=n, &
    \\       file='x.txt', status='old')
    \\  associate (y => total)
    \\    print *, y
    \\  end associate
    \\  print *, undefined_value
    \\end program p
    \\
    },
    .{ .name = "q.f90", .text =
    \\program q
    \\  use mpi
    \\  implicit none
    \\  call mpi_init(ierr)
    \\end program q
    \\
    },
    .{ .name = "r.f90", .text =
    \\program r
    \\  k = 1
    \\end program r
    \\
    },
};

fn expectUndeclared(w: *h.Workspace) !void {
    var found: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics("p.f90")) |d| {
        if (std.mem.eql(u8, d.code, "undeclared-name")) try found.append(std.testing.allocator, d.message);
    }
    defer found.deinit(std.testing.allocator);
    // kount and undefined_value only: not keywords, intrinsics, keyword
    // arguments (also on a continuation line), components, construct names,
    // a subroutine called, kinds or exponents of literals, associate names
    try h.expect(found.items.len == 3, "undeclared: {any}", .{found.items});
    try h.expect(std.mem.indexOf(u8, found.items[0], "\"kount\"") != null, "{s}", .{found.items[0]});
    try h.expect(std.mem.indexOf(u8, found.items[2], "\"undefined_value\"") != null, "{s}", .{found.items[2]});
    // not where a module is unknown, nor without IMPLICIT NONE
    for (try w.diagnostics("q.f90")) |d| try h.expect(!std.mem.eql(u8, d.code, "undeclared-name"), "q.f90: {s}", .{d.message});
    for (try w.diagnostics("r.f90")) |d| try h.expect(!std.mem.eql(u8, d.code, "undeclared-name"), "r.f90: {s}", .{d.message});
    // the quick fix declares it after the last declaration
    const line = w.pos("p.f90", "kount = kount", 0, 0).line;
    const decl = w.pos("p.f90", "type(pt) :: a", 0, 0).line;
    for (try w.codeActions("p.f90", line)) |act| {
        if (std.mem.eql(u8, act.title, "Declare kount as integer")) {
            try h.expect(std.mem.eql(u8, act.new_text, "  integer :: kount\n") and act.line == decl + 1, "declares with {s} before line {d}", .{ act.new_text, act.line });
            return;
        }
    }
    return h.unmet("no quick fix declaring kount", .{});
}

test "hansec #129 names that are not declared under IMPLICIT NONE" {
    const w = try h.Workspace.init(&undeclared, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 129, .fixed, expectUndeclared(w));
}

const unused_names = [_]h.File{
    .{ .name = "consts.f90", .text =
    \\module consts
    \\  implicit none
    \\  integer, parameter :: sp = kind(1.0), dp = kind(1.d0)
    \\  integer :: shared_count
    \\end module consts
    \\
    },
    .{ .name = "u.F90", .text =
    \\module work
    \\  implicit none
    \\  integer :: module_level
    \\contains
    \\  real function area(r) result(res)
    \\    use consts, only: sp, dp
    \\    real(dp), intent(in) :: r
    \\    real :: scratch
    \\    integer :: used_inside, only_in_ifdef
    \\    integer :: n = 2, m
    \\    m = n * 2
    \\    used_inside = 1
    \\#ifdef DEBUG
    \\    only_in_ifdef = 1
    \\#endif
    \\    res = r * r * helper()
    \\  contains
    \\    real function helper()
    \\      helper = real(used_inside)
    \\    end function helper
    \\  end function area
    \\end module work
    \\
    },
};

fn expectUnused(w: *h.Workspace) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    for (try w.diagnostics("u.F90")) |d| {
        if (!std.mem.eql(u8, d.code, "unused-name")) continue;
        try h.expect(d.severity == 4, "severity {d}", .{d.severity});
        try names.append(std.testing.allocator, d.message);
    }
    // sp (USE ONLY) and scratch only: not the argument, the result, a name
    // a contained procedure uses, one in an inactive #ifdef branch, n used
    // in m's declaration, or the module's names
    try h.expect(names.items.len == 2, "unused: {any}", .{names.items});
    try h.expect(std.mem.indexOf(u8, names.items[0], "\"scratch\"") != null or std.mem.indexOf(u8, names.items[1], "\"scratch\"") != null, "{any}", .{names.items});
    try h.expect(std.mem.indexOf(u8, names.items[0], "\"sp\"") != null or std.mem.indexOf(u8, names.items[1], "\"sp\"") != null, "{any}", .{names.items});
    // the quick fix removes a declaration of that name only
    const line = w.pos("u.F90", "real :: scratch", 0, 0).line;
    for (try w.codeActions("u.F90", line)) |act| {
        if (std.mem.eql(u8, act.title, "Remove unused scratch")) {
            try h.expect(act.line == line and act.new_text.len == 0, "removes line {d}", .{act.line});
            return;
        }
    }
    return h.unmet("no quick fix removing scratch", .{});
}

test "unused local variables and USE ONLY names are shown faded, with a quick fix" {
    const w = try h.Workspace.init(&unused_names, .{});
    defer w.deinit();
    try expectUnused(w);
}

fn indexIn(names: []const []const u8, name: []const u8) usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return std.math.maxInt(usize);
}

test "the module graph: compile order, and circular USE" {
    const w = try h.Workspace.init(&.{
        .{ .name = "kinds.f90", .text = "module kinds\n  integer, parameter :: dp = kind(1.d0)\nend module kinds\n" },
        .{ .name = "geom.f90", .text = "module geom\n  use kinds, only: dp\n  real(dp) :: origin\nend module geom\n" },
        .{ .name = "geom_impl.f90", .text = "submodule (geom) geom_impl\nend submodule geom_impl\n" },
        .{ .name = "app.f90", .text = "module app\ncontains\n  subroutine run()\n    use geom, only: origin\n    print *, origin\n  end subroutine run\nend module app\n" },
        .{ .name = "ping.f90", .text = "module ping\n  use pong\nend module ping\n" },
        .{ .name = "pong.f90", .text = "module pong\ncontains\n  subroutine back()\n    use ping\n  end subroutine back\nend module pong\n" },
    }, .{});
    defer w.deinit();
    const co = try w.compileOrder();
    // each module after those it uses (the USE inside a procedure counts),
    // a submodule after its module
    try std.testing.expect(indexIn(co.order, "kinds") < indexIn(co.order, "geom"));
    try std.testing.expect(indexIn(co.order, "geom") < indexIn(co.order, "geom_impl"));
    try std.testing.expect(indexIn(co.order, "geom") < indexIn(co.order, "app"));
    try std.testing.expectEqual(@as(usize, 1), co.cycles);
    // each USE of the cycle is an error
    for ([_][]const u8{ "ping.f90", "pong.f90" }) |f| {
        var found = false;
        for (try w.diagnostics(f)) |d| if (std.mem.eql(u8, d.code, "circular-use")) {
            found = true;
        };
        try std.testing.expect(found);
    }
    for (try w.diagnostics("geom.f90")) |d| try std.testing.expect(!std.mem.eql(u8, d.code, "circular-use"));
}

test "argument checks: count, keywords, missing arguments, INTENT(IN) assignments" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module ops
        \\  implicit none
        \\  type :: box
        \\    real :: v
        \\  contains
        \\    procedure :: scale
        \\  end type box
        \\contains
        \\  subroutine move(p, dx, dy)
        \\    real, intent(inout) :: p
        \\    real, intent(in) :: dx
        \\    real, intent(in), optional :: dy
        \\    dx = 1.0
        \\    p = p + dx
        \\  end subroutine move
        \\  subroutine scale(self, f)
        \\    class(box), intent(inout) :: self
        \\    real, intent(in) :: f
        \\    self%v = self%v * f
        \\  end subroutine scale
        \\  real function half(x)
        \\    real, intent(in) :: x
        \\    half = x / 2
        \\  end function half
        \\end module ops
        \\program main
        \\  use ops
        \\  implicit none
        \\  real :: q
        \\  type(box) :: b
        \\  call move(q, 1.0)
        \\  call move(q, 1.0, 2.0)
        \\  call move(q, 1.0, 2.0, 3.0)
        \\  call move(q, dz=1.0)
        \\  call move(q)
        \\  call move(q, 1.0, &
        \\            dy=2.0)
        \\  call b%scale(2.0)
        \\  call b%scale()
        \\  q = half(q) + half(x=q)
        \\  q = half(q, q)
        \\end program main
        \\
    }}, .{});
    defer w.deinit();
    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);
    for (try w.diagnostics("a.f90")) |d| {
        if (std.mem.eql(u8, d.code, "argument-mismatch") or std.mem.eql(u8, d.code, "intent-in-assigned")) try msgs.append(std.testing.allocator, d.message);
    }
    const want = [_][]const u8{
        "Assignment to INTENT(IN) argument dx",
        "Too many arguments for move: 3 expected",
        "move has no argument dz",
        "Missing argument dx of move",
        "Missing argument dx of move",
        "Missing argument f of scale",
        "Too many arguments for half: 1 expected",
    };
    if (msgs.items.len != want.len) {
        std.debug.print("got: {any}\n", .{msgs.items});
        return error.TestExpectedEqual;
    }
    for (want, msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

fn actionNamed(acts: []const h.Workspace.Action, title: []const u8) ?h.Workspace.Action {
    for (acts) |act| if (std.mem.eql(u8, act.title, title)) return act;
    return null;
}

test "quick fixes: IMPLICIT NONE, modern operators, kind parameters, keyword case" {
    const w = try h.Workspace.init(&.{.{ .name = "q.f90", .text =
        \\program q
        \\  real*8 :: x
        \\  real :: len
        \\  len = 3
        \\  if (x.eq.1.0d0 .and. len.ge.2) print *, 'x.eq.1'
        \\end program q
        \\
    }}, .{});
    defer w.deinit();
    // IMPLICIT NONE after the first line of the program
    const implicit = actionNamed(try w.codeActions("q.f90", 0), "Add IMPLICIT NONE to q") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("  implicit none\n", implicit.new_text);
    try std.testing.expectEqual(@as(i64, 1), implicit.line);
    const kinds = actionNamed(try w.codeActions("q.f90", 1), "Write the kinds given with * as kind parameters") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("  real(8) :: x", kinds.new_text);
    const ops = actionNamed(try w.codeActions("q.f90", 4), "Write .eq. ... .ge. as == ... >=") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("  if (x == 1.0d0 .and. len >= 2) print *, 'x.eq.1'", ops.new_text);
    // keyword case: a Source Action, not offered otherwise
    try std.testing.expect(actionNamed(try w.codeActions("q.f90", 4), "Keywords in upper case") == null);
    const src = try w.codeActionsOf("q.f90", 0, 0, &.{"source"});
    const upper = actionNamed(src, "Keywords in upper case") orelse return error.TestUnexpectedResult;
    // program, real, real, if, eq, and, ge, print, end, program; not the
    // variable len
    try std.testing.expectEqual(@as(usize, 10), upper.edits);
    try std.testing.expectEqualStrings("PROGRAM", upper.new_text);
}

test "argument checks: the type and rank of variables and literals" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module ops
        \\  implicit none
        \\  type :: pt
        \\    real :: x
        \\  end type pt
        \\contains
        \\  subroutine take(n, x, v, p, s)
        \\    integer, intent(in) :: n
        \\    real(8), intent(in) :: x
        \\    real, intent(in) :: v(:)
        \\    type(pt), intent(in) :: p
        \\    character(len=*), intent(in) :: s
        \\  end subroutine take
        \\  elemental real function sq(a)
        \\    real, intent(in) :: a
        \\    sq = a * a
        \\  end function sq
        \\  subroutine any_rank(a)
        \\    real, intent(in) :: a(..)
        \\  end subroutine any_rank
        \\end module ops
        \\program main
        \\  use ops
        \\  implicit none
        \\  integer :: i
        \\  real :: r, arr(3)
        \\  type(pt) :: q
        \\  call take(1, 2.0d0, arr, q, 'ok')
        \\  call take(1.5, 2, arr, q, 'ok')
        \\  call take(i, r, r, q, 'ok')
        \\  call take(i, r, arr, q, s=3)
        \\  call take(i, r, 1.0, 'x', 'ok')
        \\  arr = sq(arr)
        \\  call any_rank(arr)
        \\  call any_rank(r)
        \\end program main
        \\
    }}, .{});
    defer w.deinit();
    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);
    for (try w.diagnostics("t.f90")) |d| {
        if (std.mem.eql(u8, d.code, "argument-mismatch")) try msgs.append(std.testing.allocator, d.message);
    }
    const want = [_][]const u8{
        "Argument n of take: integer expected, real given",
        "Argument x of take: real expected, integer given",
        // not for a scalar variable: it may be an array element passed to an
        // explicit-shape or assumed-size array (sequence association)
        "Argument s of take: character expected, integer given",
        "Argument v of take: an array expected, a scalar given",
        "Argument p of take: derived expected, character given",
    };
    if (msgs.items.len != want.len) {
        std.debug.print("got: {any}\n", .{msgs.items});
        return error.TestExpectedEqual;
    }
    for (want, msgs.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "stub actions: an interface block for an external procedure, submodule stubs" {
    const w = try h.Workspace.init(&.{
        .{ .name = "ext.f90", .text =
        \\subroutine ext(a)
        \\  real, intent(in) :: a
        \\end subroutine ext
        \\
        },
        .{ .name = "main.f90", .text =
        \\program main
        \\  implicit none
        \\  real :: r
        \\  call ext(r)
        \\end program main
        \\
        },
        .{ .name = "m.f90", .text =
        \\module m
        \\  interface
        \\    module subroutine foo(x)
        \\      real, intent(in) :: x
        \\    end subroutine foo
        \\  end interface
        \\end module m
        \\
        },
        .{ .name = "n.f90", .text =
        \\module n
        \\  interface
        \\    module subroutine bar()
        \\    end subroutine bar
        \\  end interface
        \\end module n
        \\
        },
        .{ .name = "n_sub.f90", .text =
        \\submodule (n) n_sub
        \\contains
        \\end submodule n_sub
        \\
        },
    }, .{});
    defer w.deinit();
    const iface = actionNamed(try w.codeActions("main.f90", 3), "Add an interface block for ext") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, iface.new_text, "  interface\n    SUBROUTINE ext(a)\n      REAL, INTENT(IN) :: a\n    END SUBROUTINE ext\n  end interface\n"));
    try std.testing.expectEqual(@as(i64, 3), iface.line);
    const new_sub = actionNamed(try w.codeActions("m.f90", 2), "Implement foo in a new submodule") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, new_sub.new_text, "submodule (m) m_impl\ncontains\n  module procedure foo\n") != null);
    try std.testing.expect(actionNamed(try w.codeActions("n.f90", 2), "Implement bar in submodule n_sub") != null);
}
