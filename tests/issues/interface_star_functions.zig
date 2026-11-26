//! A function with a `type*N` prefix inside an interface block is indexed as
//! one with `type(kind)` is (#880): `use ifport, only: sport_connect` of ifx's
//! own module finds it. (That name was not found in a workspace of ifx's
//! modules because `!DEC$ IF DEFINED(_WIN32)` surrounds it, not for the prefix.)

const std = @import("std");
const h = @import("harness.zig");

const module =
    \\module m
    \\  implicit none
    \\  interface
    \\    integer*4 function f1(x)
    \\      integer, intent(in) :: x
    \\    end function
    \\    real*8 function f2(x)
    \\      integer, intent(in) :: x
    \\    end function
    \\    character*(*) function f3(x)
    \\      integer, intent(in) :: x
    \\    end function
    \\    pure integer*4 function f4(x)
    \\      integer, intent(in) :: x
    \\    end function
    \\    integer*4 recursive function f5(x) result(r)
    \\      integer, intent(in) :: x
    \\    end function
    \\    INTEGER*4 FUNCTION F6 ( X )
    \\      integer, intent(in) :: x
    \\    END FUNCTION F6
    \\    integer(4) function f7(x)
    \\      integer, intent(in) :: x
    \\    end function
    \\  end interface
    \\end module
    \\
;

const user =
    \\subroutine s
    \\  use m, only: f1, f2, f3, f4, f5, f6, f7
    \\  implicit none
    \\  integer :: i
    \\  i = f1(1) + f2(1) + f4(1) + f5(1) + f6(1) + f7(1)
    \\end subroutine
    \\
;

test "interface functions with a type*N prefix are found through USE, ONLY" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "u.f90", .text = user },
    }, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("u.f90");
    const names = [_][]const u8{ "f1", "f2", "f3", "f4", "f5", "f6", "f7" };
    // the 0-based lines of their declarations in `module`
    const lines = [_]i64{ 3, 6, 9, 12, 15, 18, 21 };
    inline for (names, lines) |name, line| {
        const def = (try w.definition("u.f90", w.pos("u.f90", name, 0, 0))) orelse return h.unmet("no definition of " ++ name, .{});
        try std.testing.expect(std.mem.endsWith(u8, def.uri, "m.f90"));
        if (def.line != line) {
            std.debug.print("{s}: defined at line {d}, expected {d}\n", .{ name, def.line, line });
            return error.TestUnexpectedResult;
        }
    }
}

test "hover on a call of an interface function with a type*N prefix" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "u.f90", .text = user },
    }, .{});
    defer w.deinit();
    try w.expectHoverContains("u.f90", w.pos("u.f90", "f1(1)", 0, 0), "f1");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "f2(1)", 0, 0), "f2");
}
