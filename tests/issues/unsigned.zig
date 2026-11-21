//! UNSIGNED, gfortran's from GCC 15 (`-funsigned`) and LLVM Flang's, the
//! F202Y proposal: the type, its literals (`4000000000u`, `3u_uk`), its
//! intrinsics, in declarations, hover and argument checks (#540; the
//! gfortran audit, #488).

const std = @import("std");
const h = @import("harness.zig");

test "UNSIGNED declares, with its kinds and literals" {
    // gfortran -funsigned: exit 0
    const w = try h.Workspace.init(&.{.{ .name = "unsig.f90", .text =
        \\program unsig
        \\  implicit none
        \\  unsigned :: u
        \\  unsigned(kind=8) :: big
        \\  integer, parameter :: uk = selected_unsigned_kind(4)
        \\  unsigned(uk) :: w
        \\  u = 4000000000u
        \\  big = uint(7, 8)
        \\  w = 3u_uk
        \\  print *, u, big, w, huge(u), umaskl(3), umaskr(3)
        \\  call takeu(u)
        \\contains
        \\  subroutine takeu(x)
        \\    unsigned, intent(in) :: x
        \\    print *, x
        \\  end subroutine takeu
        \\end program unsig
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("unsig.f90");
    try w.expectHoverContains("unsig.f90", w.pos("unsig.f90", "u = 4", 0, 0), "UNSIGNED :: u");
    try w.expectHoverContains("unsig.f90", w.pos("unsig.f90", "big = uint", 0, 0), "UNSIGNED(kind=8) :: big");
    try w.expectHoverContains("unsig.f90", w.pos("unsig.f90", "4000000000u", 0, 1), "UNSIGNED");
    try w.expectHoverContains("unsig.f90", w.pos("unsig.f90", "3u_uk", 0, 0), "UNSIGNED(uk)");
}

test "an INTEGER for an UNSIGNED argument, and an UNSIGNED for an INTEGER one" {
    // gfortran -funsigned: `Type mismatch in argument 'x' at (1); passed
    // INTEGER(4) to UNSIGNED(4)` (line 8), and the other way (line 10)
    const w = try h.Workspace.init(&.{.{ .name = "u2.f90", .text =
        \\program u2
        \\  implicit none
        \\  integer :: i
        \\  unsigned :: u
        \\  i = 1
        \\  u = 1u
        \\  call takeu(u)
        \\  call takeu(i)
        \\  call takeu(2u)
        \\  call takei(u)
        \\contains
        \\  subroutine takeu(x)
        \\    unsigned, intent(in) :: x
        \\    print *, x
        \\  end subroutine takeu
        \\  subroutine takei(n)
        \\    integer, intent(in) :: n
        \\    print *, n
        \\  end subroutine takei
        \\end program u2
        \\
    }}, .{});
    defer w.deinit();
    var lines: std.ArrayList(i64) = .empty;
    for (try w.diagnostics("u2.f90")) |d| if (d.severity == 1) try lines.append(w.a(), d.line);
    try h.expect(lines.items.len == 2 and lines.items[0] == 7 and lines.items[1] == 9, "errors on lines {any}", .{lines.items});
}
