//! Requests zfls answers for the editor while a program is debugged:
//! inline values.

const std = @import("std");
const h = @import("harness.zig");

const program = [_]h.File{.{ .name = "step.f90", .text =
    \\module counters
    \\  implicit none
    \\  integer :: total = 0
    \\  integer, private :: hidden = 0
    \\  integer, parameter :: limit = 10
    \\  type :: pt
    \\    integer :: x
    \\  end type pt
    \\end module counters
    \\
    \\module other
    \\  implicit none
    \\  integer :: shared_x = 0
    \\  integer :: renamed_y = 0
    \\end module other
    \\
    \\subroutine step(n, v)
    \\  use counters
    \\  use other, only: shared_x, ry => renamed_y
    \\  implicit none
    \\  integer, intent(in) :: n
    \\  real, intent(inout) :: v(n)
    \\  integer :: i
    \\  type(pt) :: p
    \\  character(len=8) :: msg
    \\  do i = 1, n
    \\    v(i) = v(i) + total + limit + shared_x + ry ! i
    \\    p%x = i
    \\  end do
    \\  msg = 'total i'
    \\  call helper()
    \\contains
    \\  subroutine helper()
    \\  end subroutine helper
    \\end subroutine step
    \\
}};

test "inline values while debugging (#195)" {
    const w = try h.Workspace.init(&program, .{});
    defer w.deinit();
    // stopped at `msg = 'total i'`: the variables step sees, from its first
    // line to the stop, a renamed one under its local name (`ry`), as
    // `zfls dap` lists them. Not the named constant `limit`, the private
    // `hidden`, the component `x`, the type `pt`, or what is in strings and
    // comments.
    const V = h.Workspace.InlineValue;
    const want = [_]V{
        .{ .line = 16, .col = 16, .name = "n" },
        .{ .line = 16, .col = 19, .name = "v" },
        .{ .line = 18, .col = 19, .name = "shared_x" },
        .{ .line = 18, .col = 29, .name = "ry" },
        .{ .line = 20, .col = 25, .name = "n" },
        .{ .line = 21, .col = 25, .name = "v" },
        .{ .line = 21, .col = 27, .name = "n" },
        .{ .line = 22, .col = 13, .name = "i" },
        .{ .line = 23, .col = 14, .name = "p" },
        .{ .line = 24, .col = 22, .name = "msg" },
        .{ .line = 25, .col = 5, .name = "i" },
        .{ .line = 25, .col = 12, .name = "n" },
        .{ .line = 26, .col = 4, .name = "v" },
        .{ .line = 26, .col = 6, .name = "i" },
        .{ .line = 26, .col = 11, .name = "v" },
        .{ .line = 26, .col = 13, .name = "i" },
        .{ .line = 26, .col = 18, .name = "total" },
        .{ .line = 26, .col = 34, .name = "shared_x" },
        .{ .line = 26, .col = 45, .name = "ry" },
        .{ .line = 27, .col = 4, .name = "p" },
        .{ .line = 27, .col = 10, .name = "i" },
        .{ .line = 29, .col = 2, .name = "msg" },
    };
    const got = try w.inlineValues("step.f90", 29);
    try h.expect(got.len == want.len, "{d} inline values, not {d}: {any}", .{ got.len, want.len, got });
    for (got, want) |g, x| try h.expect(g.line == x.line and g.col == x.col and std.mem.eql(u8, g.name, x.name), "{d}:{d} {s}, not {d}:{d} {s}", .{ g.line, g.col, g.name, x.line, x.col, x.name });
    // stopped outside any procedure: none
    const none = try w.inlineValues("step.f90", 2);
    try h.expect(none.len == 0, "{d} inline values outside a procedure: {any}", .{ none.len, none });
}
