//! The keyword of a keyword argument, `x` of `call f(x=1.0)`, is the dummy
//! argument of the procedure called (#952): for definition, hover,
//! references and rename.

const std = @import("std");
const h = @import("harness.zig");

const source = h.File{ .name = "k.f90", .text =
    \\module m
    \\  implicit none
    \\  type :: pt
    \\    real :: xc, yc
    \\  end type
    \\  interface g
    \\    module procedure gi, gr
    \\  end interface
    \\contains
    \\  subroutine f(x, n)
    \\    real, intent(in) :: x
    \\    integer, intent(in), optional :: n
    \\  end subroutine
    \\  subroutine gi(k)
    \\    integer, intent(in) :: k
    \\  end subroutine
    \\  subroutine gr(r)
    \\    real, intent(in) :: r
    \\  end subroutine
    \\end module m
    \\
    \\program p
    \\  use m
    \\  implicit none
    \\  real :: x
    \\  type(pt) :: q
    \\  x = 2.0
    \\  call f(x=x, n=3)
    \\  call f(1.0, &
    \\         n=4)
    \\  call g(r=1.0)
    \\  q = pt(xc=1.0, yc=x)
    \\  if (x == 1.0) x = 3.0
    \\end program p
    \\
};

fn start() !*h.Workspace {
    const w = try h.Workspace.init(&.{source}, .{});
    errdefer w.deinit();
    try w.open("k.f90", "fortran");
    return w;
}

test "definition on a keyword goes to the dummy argument, not a name of the caller (#952)" {
    const w = try start();
    defer w.deinit();
    const call = w.pos("k.f90", "f(x=x", 0, 2);
    const d = (try w.definition("k.f90", call)) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 10), d.line);
    // the value is the program's own x
    const v = (try w.definition("k.f90", w.pos("k.f90", "f(x=x", 0, 4))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 24), v.line);
    // on a continuation line, of a generic's specific, of a constructor's component
    const n = (try w.definition("k.f90", w.pos("k.f90", "n=4", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 11), n.line);
    const r = (try w.definition("k.f90", w.pos("k.f90", "r=1.0", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 17), r.line);
    const xc = (try w.definition("k.f90", w.pos("k.f90", "xc=1.0", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 3), xc.line);
    // an assignment is no keyword
    const a = (try w.definition("k.f90", w.pos("k.f90", "x = 3.0", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 24), a.line);
}

test "hover on a keyword shows the dummy argument (#952)" {
    const w = try start();
    defer w.deinit();
    try w.expectHoverContains("k.f90", w.pos("k.f90", "n=3", 0, 0), "OPTIONAL");
}

test "renaming a dummy argument renames the keywords of the calls, not the caller's names (#952)" {
    const w = try start();
    defer w.deinit();
    const edits = try w.rename("k.f90", w.pos("k.f90", "f(x, n)", 0, 2), "xin");
    var keyword = false;
    for (edits) |e| {
        // in the program (lines 21 on), only the keyword of line 27
        if (e.line >= 21) {
            try std.testing.expectEqual(@as(i64, 27), e.line);
            try std.testing.expectEqual(@as(i64, 9), e.start);
            keyword = true;
        }
    }
    try std.testing.expect(keyword);
    // and references on the keyword list the dummy's places
    var dummy = false;
    for (try w.references("k.f90", w.pos("k.f90", "f(x=x", 0, 2))) |l| dummy = dummy or l.line == 9 or l.line == 10;
    try std.testing.expect(dummy);
}
