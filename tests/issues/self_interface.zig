//! A procedure with an argument declared with its own interface, or two
//! procedures whose arguments use each other's, has a hover and inlay
//! hints (#894).

const std = @import("std");
const h = @import("harness.zig");

test "hover and inlay hints of an argument with its own interface (#894)" {
    const text = "module m\n  interface\n    subroutine s(x)\n      procedure(s) :: x\n    end subroutine\n  end interface\nend module\n";
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    _ = try w.hover("t.f90", w.pos("t.f90", "s) :: x", 0, 0));
    _ = try w.hover("t.f90", w.pos("t.f90", "x\n    end", 0, 0));
    _ = try w.inlayHints("t.f90");
}

test "hover and inlay hints of procedures that name each other (#894)" {
    const text = "module m\n  interface\n    subroutine s1(x)\n      procedure(s2) :: x\n    end subroutine\n    subroutine s2(y)\n      procedure(s1) :: y\n    end subroutine\n  end interface\n  procedure(s1), pointer :: pp\nend module\n";
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    _ = try w.hover("t.f90", w.pos("t.f90", "s1(x)", 0, 0));
    _ = try w.hover("t.f90", w.pos("t.f90", "pp", 0, 0));
    _ = try w.inlayHints("t.f90");
}
