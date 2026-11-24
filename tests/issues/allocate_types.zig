//! ALLOCATE of what cannot be, assignments of the wrong type and the number
//! of arguments of intrinsics (#850), verified on gfortran 16.1, Flang
//! 23.1.5 and ifx 2026.2.0: all three report each ALLOCATE problem and
//! intrinsic count and a numeric value for a character variable; a
//! character value for a numeric variable and `if (i)` are gfortran's and
//! Flang's errors, ifx accepts them. The same object twice in an ALLOCATE or
//! DEALLOCATE is gfortran's and ifx's error (#878), not Flang's.

const std = @import("std");
const h = @import("harness.zig");

const codes = [_][]const u8{ "allocate-object", "allocate-duplicate", "allocate-shape", "assignment-type", "condition-type", "intrinsic-arguments" };

fn collect(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| {
        for (codes) |c| if (std.mem.eql(u8, d.code, c)) {
            try out.append(w.a(), try w.a().print("{d}: {s}: {s}", .{ d.line + 1, d.code, d.message }));
        };
    }
    return out.items;
}

fn expectAll(got: []const []const u8, want: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("got: {any}\n", .{got});
        return error.TestExpectedEqual;
    }
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

fn workspace(comptime dialect: []const u8, text: []const u8) !*h.Workspace {
    const opts = "{\"lint_dialect\": \"" ++ dialect ++ "\"}";
    return h.Workspace.init(&.{.{ .name = "a.f90", .text = text }}, .{ .init_options = opts });
}

test "ALLOCATE and DEALLOCATE of what cannot be, in every dialect" {
    const text =
        \\program p
        \\  implicit none
        \\  integer, allocatable :: a(:)
        \\  integer, allocatable :: m(:, :)
        \\  integer :: i
        \\  integer, pointer :: q(:)
        \\  allocate (a)
        \\  allocate (i)
        \\  allocate (m(3))
        \\  allocate (q(3, 4))
        \\  deallocate (i)
        \\end program
        \\
    ;
    inline for ([_][]const u8{ "neutral", "gfortran", "ifx", "flang" }) |d| {
        const w = try workspace(d, text);
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &.{
            "7: allocate-shape: a is an array: ALLOCATE needs its shape, a SOURCE or a MOLD",
            "8: allocate-object: i has neither the ALLOCATABLE nor the POINTER attribute",
            "9: allocate-shape: m has rank 2 and 1 bounds are given",
            "10: allocate-shape: q has rank 1 and 2 bounds are given",
            "11: allocate-object: i has neither the ALLOCATABLE nor the POINTER attribute",
        });
    }
}

test "valid ALLOCATE statements are not reported" {
    const w = try workspace("neutral",
        \\module m
        \\  implicit none
        \\  type :: t
        \\    integer, allocatable :: c(:)
        \\    real, pointer :: p(:, :) => null()
        \\  end type
        \\contains
        \\  subroutine s(d, e)
        \\    real, allocatable, intent(out) :: d(:)
        \\    integer, intent(out), allocatable :: e(:, :)
        \\    allocate (d(3))
        \\    allocate (e(2, 2))
        \\  end subroutine
        \\  function f(n) result(r)
        \\    integer :: n
        \\    real, allocatable :: r(:)
        \\    allocate (r(n))
        \\  end function
        \\end module
        \\program p
        \\  use m
        \\  implicit none
        \\  real :: a(:), b(:, :), x
        \\  allocatable :: a, b
        \\  integer, pointer :: q(:)
        \\  real, allocatable :: y(:), z(:)
        \\  character(len=:), allocatable :: str
        \\  type(t) :: v
        \\  class(*), allocatable :: u
        \\  integer :: ier
        \\  pointer :: x
        \\  allocate (a(5), b(2, 3))
        \\  allocate (q(0:3), stat=ier)
        \\  allocate (y, source=a)
        \\  allocate (z, mold=a)
        \\  allocate (str, source='abc')
        \\  allocate (character(len=5) :: str)
        \\  allocate (v%c(3), v%p(2, 2))
        \\  allocate (real :: u)
        \\  allocate (x)
        \\  deallocate (a, b, q, y, z, str, x)
        \\end program
        \\
    );
    defer w.deinit();
    try expectAll(try collect(w, "a.f90"), &.{});
}

const types =
    \\program p
    \\  implicit none
    \\  integer :: i, a(3)
    \\  real :: r
    \\  character(len=3) :: s
    \\  i = 'abc'
    \\  s = 1
    \\  r = 1.5
    \\  s = 2.5
    \\  r = 'x'
    \\  if (i) then
    \\  end if
    \\  a(2) = 'q'
    \\end program
    \\
;

test "a numeric value for a character variable: every dialect" {
    inline for ([_][]const u8{ "neutral", "ifx" }) |d| {
        const w = try workspace(d, types);
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &.{
            "7: assignment-type: Cannot assign a value of type INTEGER to CHARACTER variable s",
            "9: assignment-type: Cannot assign a value of type REAL to CHARACTER variable s",
        });
    }
}

test "a character value for a numeric variable and if (i): gfortran's and Flang's" {
    inline for ([_][]const u8{ "gfortran", "flang" }) |d| {
        const w = try workspace(d, types);
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &.{
            "6: assignment-type: Cannot assign a value of type CHARACTER to INTEGER variable i",
            "7: assignment-type: Cannot assign a value of type INTEGER to CHARACTER variable s",
            "9: assignment-type: Cannot assign a value of type REAL to CHARACTER variable s",
            "10: assignment-type: Cannot assign a value of type CHARACTER to REAL variable r",
            "11: condition-type: The condition of IF must be logical, i is INTEGER",
            "13: assignment-type: Cannot assign a value of type CHARACTER to INTEGER variable a",
        });
    }
}

test "an assignment(=) interface makes assignments of other types valid" {
    const w = try workspace("gfortran",
        \\module ops
        \\  implicit none
        \\  interface assignment(=)
        \\    module procedure c2i
        \\  end interface
        \\contains
        \\  subroutine c2i(i, s)
        \\    integer, intent(out) :: i
        \\    character(len=*), intent(in) :: s
        \\    i = len(s)
        \\  end subroutine
        \\end module
        \\program p
        \\  use ops
        \\  implicit none
        \\  integer :: i, a(3)
        \\  real :: r
        \\  character(len=3) :: s
        \\  logical :: l
        \\  i = 3
        \\  s = 'ok'
        \\  r = 1.5
        \\  l = .true.
        \\  a = [1, 2, 3]
        \\  if (l) i = 2
        \\  if (i > 0) i = 2
        \\  s = 'a' // 'b'
        \\  i = 'abc'
        \\  a(2) = 'q'
        \\end program
        \\
    );
    defer w.deinit();
    try expectAll(try collect(w, "a.f90"), &.{});
}

test "the number of arguments of an intrinsic" {
    const w = try workspace("neutral",
        \\program p
        \\  implicit none
        \\  real :: x, y
        \\  x = sin(x, y)
        \\  x = cos()
        \\  x = mod(x)
        \\  x = atan2(x, y, y)
        \\  x = max(x)
        \\  x = sin(x) + cos(x=y) + abs(x) + mod(x, y) + atan2(y=1.0, x=x) + max(x, y, 3.0) + atan(x, y) + mod(a=x, p=y)
        \\end program
        \\
    );
    defer w.deinit();
    try expectAll(try collect(w, "a.f90"), &.{
        "4: intrinsic-arguments: too many arguments in the call of intrinsic sin",
        "5: intrinsic-arguments: too few arguments in the call of intrinsic cos",
        "6: intrinsic-arguments: too few arguments in the call of intrinsic mod",
        "7: intrinsic-arguments: too many arguments in the call of intrinsic atan2",
        "8: intrinsic-arguments: too few arguments in the call of intrinsic max",
    });
}

test "the same object twice in ALLOCATE or DEALLOCATE: gfortran and ifx report it" {
    const text =
        \\program p
        \\  implicit none
        \\  integer, allocatable :: a(:), b(:)
        \\  type :: t
        \\    integer, allocatable :: x(:), y(:)
        \\  end type
        \\  type(t) :: v
        \\  allocate (a(2), a(3))
        \\  allocate (a(2), b(3))
        \\  deallocate (a, b, A)
        \\  allocate (v%x(1), v%x(2))
        \\  allocate (a(2), b(3), stat=i, errmsg=m)
        \\end program
        \\
    ;
    inline for ([_][]const u8{ "neutral", "gfortran", "ifx", "flang" }) |d| {
        const w = try workspace(d, text);
        defer w.deinit();
        const got = try collect(w, "a.f90");
        if (comptime std.mem.eql(u8, d, "gfortran") or std.mem.eql(u8, d, "ifx")) {
            try expectAll(got, &.{
                "8: allocate-duplicate: a appears more than once in the ALLOCATE statement",
                "10: allocate-duplicate: A appears more than once in the DEALLOCATE statement",
            });
        } else try expectAll(got, &.{});
    }
}
