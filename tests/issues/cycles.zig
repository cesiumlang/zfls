//! Code that refers to itself in a loop, as it may while being written:
//! a file that includes itself (#954), submodules that name each other as
//! parent (#955), a type that extends itself (#956). zfls answers without
//! running out of stack.

const std = @import("std");
const h = @import("harness.zig");

test "a file that includes itself, or two that include each other (#954)" {
    const files = [_]h.File{
        .{ .name = "s.f90", .text = "subroutine s\n  include 's.f90'\n  integer :: k\n  k = 1\nend subroutine s\n" },
        .{ .name = "a.inc", .text = "subroutine t\n  include 'b.inc'\nend subroutine t\n" },
        .{ .name = "b.inc", .text = "integer :: j\ninclude 'a.inc'\n" },
    };
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("s.f90", "fortran");
    try w.expectHoverContains("s.f90", w.pos("s.f90", "k = 1", 0, 0), "INTEGER :: k");
    try w.replaceText("s.f90", "subroutine s\n  include 's.f90'\n  integer :: k, m\n  k = 1\nend subroutine s\n");
    try w.expectHoverContains("s.f90", w.pos("s.f90", "k = 1", 0, 0), "INTEGER :: k");
    try w.open("a.inc", "fortran");
    _ = try w.hover("a.inc", w.pos("a.inc", "t", 0, 0));
}

test "submodules that name each other as parent (#955)" {
    const files = [_]h.File{
        .{ .name = "m.f90", .text = "module m\n  implicit none\n  integer :: base_val\nend module m\n" },
        .{ .name = "a.f90", .text = "submodule (m:b) a\ncontains\n  subroutine sa()\n    print *, undefined_a, base_val\n  end subroutine\nend submodule a\n" },
        .{ .name = "b.f90", .text = "submodule (m:a) b\ncontains\n  subroutine sb()\n    print *, undefined_b\n  end subroutine\nend submodule b\n" },
    };
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("a.f90", "fortran");
    _ = try w.diagnostics("a.f90");
    _ = try w.hover("a.f90", w.pos("a.f90", "undefined_a", 0, 0));
    _ = try w.hover("a.f90", w.pos("a.f90", "base_val", 0, 0));
    try w.open("b.f90", "fortran");
    _ = try w.hover("b.f90", w.pos("b.f90", "undefined_b", 0, 0));
}

test "a type that extends itself, or two that extend each other (#956)" {
    const files = [_]h.File{.{ .name = "t.f90", .text =
        \\module t
        \\  implicit none
        \\  type, extends(node) :: node
        \\    integer :: v
        \\  contains
        \\    procedure :: run
        \\  end type
        \\  type, extends(p2) :: p1
        \\    integer :: x1
        \\  end type
        \\  type, extends(p1) :: p2
        \\    integer :: x2
        \\  end type
        \\contains
        \\  subroutine run(self)
        \\    class(node), intent(in) :: self
        \\    type(p1) :: q
        \\    print *, self%v, q%x1, q%x2
        \\  end subroutine
        \\end module t
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    _ = try w.diagnostics("t.f90");
    _ = try w.references("t.f90", w.pos("t.f90", "run\n", 0, 0));
    _ = try w.references("t.f90", w.pos("t.f90", "x2\n", 0, 0));
    _ = try w.completion("t.f90", w.pos("t.f90", "q%x1", 0, 2));
}
