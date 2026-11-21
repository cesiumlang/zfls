//! A workspace given by its 8.3 short path (`C:\Users\EMANSP~1\...`, as
//! `%TEMP%` gives it) on Windows: zfls indexes it by its long path, which
//! editors' file URIs and compilers' debug information name (zfls #614).

const std = @import("std");
const h = @import("harness.zig");

test "a workspace opened by its short path finds the declarations of its files (#614)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "long directory/shapes.f90", .text =
        \\module shapes
        \\  implicit none
        \\contains
        \\  subroutine draw(n)
        \\    integer, intent(in) :: n
        \\  end subroutine draw
        \\end module shapes
        \\
        },
        .{ .name = "long directory/main.f90", .text =
        \\program main
        \\  use shapes
        \\  call draw(3)
        \\end program main
        \\
        },
    }, .{ .short_root = true });
    defer w.deinit();
    try std.testing.expect(std.mem.findScalar(u8, w.root, '~') != null);
    const loc = (try w.definition("long directory/main.f90", .{ .line = 2, .col = 8 })) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, loc.uri, "shapes.f90"));
    try std.testing.expectEqual(@as(i64, 3), loc.line);
    try std.testing.expect((try w.hover("long directory/main.f90", .{ .line = 2, .col = 8 })) != null);
}
