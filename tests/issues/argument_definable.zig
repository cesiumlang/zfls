//! An actual argument for an INTENT(OUT) or INTENT(INOUT) dummy argument
//! must be a variable (#848); gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0
//! all report the cases below.

const std = @import("std");
const h = @import("harness.zig");

const module =
    \\module mm
    \\  implicit none
    \\  type :: box
    \\    integer :: n
    \\  end type box
    \\contains
    \\  subroutine ou(x)
    \\    integer, intent(out) :: x
    \\    x = 1
    \\  end subroutine ou
    \\  subroutine io(x)
    \\    integer, intent(inout) :: x
    \\    x = x + 1
    \\  end subroutine io
    \\  subroutine inn(x)
    \\    integer, intent(in) :: x
    \\    print *, x
    \\  end subroutine inn
    \\  subroutine ptr(p)
    \\    integer, pointer, intent(out) :: p
    \\    p => null()
    \\  end subroutine ptr
    \\end module mm
    \\
;

fn collect(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, "argument-not-definable")) {
        try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    };
    return out.items;
}

test "INTENT(OUT) and INTENT(INOUT) dummies: constants, expressions, named constants, INTENT(IN) arguments" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use mm
        \\  implicit none
        \\  integer, parameter :: k = 2
        \\  integer :: i, j(3)
        \\  call ou(1)
        \\  call ou(k)
        \\  call ou(i+1)
        \\  call io(2)
        \\  call io((i))
        \\  call ou(x=3)
        \\contains
        \\  subroutine relay(d)
        \\    integer, intent(in) :: d
        \\    call ou(d)
        \\  end subroutine relay
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    const got = try collect(w, "p.f90");
    const want = [_][]const u8{
        "6: Argument x of ou is INTENT(OUT): a variable is expected, a constant given",
        "7: Argument x of ou is INTENT(OUT): a variable is expected, a named constant given",
        "8: Argument x of ou is INTENT(OUT): a variable is expected, an expression given",
        "9: Argument x of io is INTENT(INOUT): a variable is expected, a constant given",
        "10: Argument x of io is INTENT(INOUT): a variable is expected, an expression given",
        "11: Argument x of ou is INTENT(OUT): a variable is expected, a constant given",
        "15: Argument x of ou is INTENT(OUT): a variable is expected, an INTENT(IN) argument given",
    };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "INTENT(OUT) dummies: silent for variables, elements, sections, components, pointers, INTENT(IN) dummies and implicit interfaces" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text =
        \\subroutine external_out(x)
        \\  integer, intent(out) :: x
        \\  x = 1
        \\end subroutine external_out
        \\program p
        \\  use mm
        \\  implicit none
        \\  integer :: i, j(3)
        \\  integer, pointer :: q
        \\  type(box) :: b
        \\  call ou(i)
        \\  call ou(j(2))
        \\  call io(j(i))
        \\  call ou(b%n)
        \\  call ptr(q)
        \\  call inn(1)
        \\  call inn(i + 1)
        \\  call external_out(i)
        \\  call relay_in(i)
        \\contains
        \\  subroutine relay_in(d)
        \\    integer, intent(in) :: d
        \\    call inn(d)
        \\  end subroutine relay_in
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try collect(w, "p.f90")).len);
}

test "INTENT(OUT) actuals: the code can be turned off" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text =
        \\program p
        \\  use mm
        \\  implicit none
        \\  call ou(1) ! zfls: disable=argument-not-definable
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try collect(w, "p.f90")).len);
}
