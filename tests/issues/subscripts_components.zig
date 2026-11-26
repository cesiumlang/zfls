//! The number of subscripts of an array reference and the components of a
//! derived type (#850): gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 all
//! report `a(1, 2)` for a rank-1 array and `v%b` for a type with no
//! component b.

const std = @import("std");
const h = @import("harness.zig");

fn collect(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| {
        if (std.mem.eql(u8, d.code, "subscript-count") or std.mem.eql(u8, d.code, "unknown-component")) {
            try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
        }
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

const module =
    \\module m
    \\  implicit none
    \\  type :: base
    \\    integer :: a
    \\  contains
    \\    procedure :: show
    \\    generic :: g => show
    \\  end type
    \\  type, extends(base) :: child
    \\    real :: b
    \\    integer :: arr(3, 3)
    \\  end type
    \\  type :: pdt(k)
    \\    integer, kind :: k
    \\    real(k) :: x
    \\  end type
    \\contains
    \\  subroutine show(self)
    \\    class(base) :: self
    \\  end subroutine
    \\end module
    \\
;

test "wrong subscript counts and unknown components are reported" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use m
        \\  implicit none
        \\  type(child) :: c
        \\  real :: arr(3, 3), vec(3)
        \\  integer :: i
        \\  vec(1, 2) = 1
        \\  arr(1) = 1
        \\  i = vec(1, 2, 3)
        \\  c%zz = 1
        \\  i = c%nosuch
        \\  i = c%arr(1)
        \\end program
        \\
        },
    }, .{});
    defer w.deinit();
    try expectAll(try collect(w, "p.f90"), &.{
        "7: Reference to rank-1 object vec has 2 subscripts",
        "8: Reference to rank-2 object arr has 1 subscripts",
        "9: Reference to rank-1 object vec has 3 subscripts",
        "10: Component zz is not a member of type child",
        "11: Component nosuch is not a member of type child",
        "12: Reference to rank-2 object arr has 1 subscripts",
    });
}

test "valid references are not reported" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use m
        \\  implicit none
        \\  type(child) :: c, cs(2)
        \\  type(pdt(4)) :: q
        \\  complex :: z
        \\  real :: arr(3, 3), vec(3), mat(2, 2)
        \\  character(len=10) :: s
        \\  character(len=4) :: names(2)
        \\  integer :: i, j
        \\  real, allocatable :: al(:, :)
        \\  real, pointer :: pt(:)
        \\  i = c%a + c%base%a
        \\  call c%show()
        \\  call c%g()
        \\  vec(1) = z%re
        \\  arr(1, 2) = 1
        \\  vec = arr(1, :)
        \\  i = q%k
        \\  s(1:2) = 'ab'
        \\  names(1)(2:3) = 'ab'
        \\  cs(1)%arr(1, 2) = 1
        \\  allocate (al(2, 2), pt(3))
        \\  al(1, 1) = mat(1, 2)
        \\  associate (r => arr(:, 1))
        \\    vec(1) = r(2)
        \\  end associate
        \\  mat = reshape([(real(j), j = 1, 4)], [2, 2])
        \\  i = size(arr, 1)
        \\end program
        \\
        },
    }, .{});
    defer w.deinit();
    try expectAll(try collect(w, "p.f90"), &.{});
}

test "a type with conditional compilation inside is not checked for components" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text = "module m\n  type t\n    integer :: a\n!DEC$ IF DEFINED(_M_AMD64)\n    integer :: b\n!DEC$ ENDIF\n  end type\nend module\nprogram p\n  use m\n  type(t) :: v\n  v%b = 1\n  v%c = 1\nend program\n" }}, .{});
    defer w.deinit();
    try expectAll(try collect(w, "a.f90"), &.{});
}
