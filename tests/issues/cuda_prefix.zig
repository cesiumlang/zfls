//! CUDA Fortran's `attributes(...)` among the other words of a
//! procedure's prefix (#388).

const std = @import("std");
const h = @import("harness.zig");

test "CUDA Fortran: a prefix before ATTRIBUTES (`pure attributes(device) function`)" {
    const w = try h.Workspace.init(&.{.{ .name = "prefix.cuf", .text =
        \\module k
        \\  use iso_c_binding, only: c_int
        \\  implicit none
        \\  interface
        \\    pure attributes(device) function f(x) bind(c) result(y)
        \\      import :: c_int
        \\      integer(c_int), intent(in) :: x
        \\      integer(c_int) :: y
        \\    end function
        \\    attributes(device) pure function g(x) result(y)
        \\      import :: c_int
        \\      integer(c_int), intent(in) :: x
        \\      integer(c_int) :: y
        \\    end function
        \\  end interface
        \\contains
        \\  pure attributes(device) subroutine twice(v)
        \\    real, intent(inout) :: v
        \\    v = 2 * v
        \\  end subroutine twice
        \\end module k
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("prefix.cuf");
    const symbols = try w.documentSymbols("prefix.cuf");
    for ([_][]const u8{ "f", "g", "twice" }) |name| {
        for (symbols) |s| {
            if (std.mem.eql(u8, s, name)) break;
        } else return error.TestUnexpectedResult;
    }
    try w.expectHoverContains("prefix.cuf", w.pos("prefix.cuf", "v = 2", 0, 0), "REAL");
}
