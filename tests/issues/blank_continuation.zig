//! A blank line between the continuation lines of a statement or a
//! declaration does not end it (#843), as a comment line does not (#259).

const h = @import("harness.zig");

const free0 =
    \\program p
    \\  implicit none
    \\  integer :: xx(2,2)
    \\  xx = reshape([1, 2, &
    \\
    \\    3, 4], shape(xx), order=[2,1])
    \\end program
    \\
;

const free1 =
    \\program p
    \\  implicit none
    \\  integer :: xx(2) = [1, &
    \\
    \\    2], yy
    \\  yy = 1
    \\  print *, xx, yy
    \\end program
    \\
;

const free2 =
    \\program p
    \\  implicit none
    \\  integer,save :: xx(2,2)= reshape([&
    \\  1, 2, &
    \\  3, 4 &
    \\
    \\  ],shape(xx),order=[2,1])
    \\  print *, xx
    \\end program
    \\
;

const free3 =
    \\program p
    \\  implicit none
    \\  integer :: xx(2,2)
    \\  xx = reshape([1, 2, &
    \\    ! a comment
    \\
    \\    3, 4], shape(xx), &
    \\
    \\    order=[2,1])
    \\end program
    \\
;

const fixed0 =
    \\      program p
    \\      implicit none
    \\      integer xx(2,2)
    \\      xx = reshape((/1, 2,
    \\
    \\     &  3, 4/), shape(xx), order=(/2,1/))
    \\      end program
    \\
;

const fixed1 =
    \\      program p
    \\      implicit none
    \\      integer :: aa(2) = (/1,
    \\
    \\     &  2/), bb
    \\      bb = aa(1)
    \\      end program
    \\
;

test "free form: a blank line between continuation lines does not cut the statement (#843)" {
    inline for ([_][]const u8{ free0, free1, free2, free3 }) |text| {
        const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
        defer w.deinit();
        try w.expectNoDiagnostics("t.f90");
    }
}

test "fixed form: a blank line between continuation lines does not cut the statement (#843)" {
    inline for ([_][]const u8{ fixed0, fixed1 }) |text| {
        const w = try h.Workspace.init(&.{.{ .name = "t.f", .text = text }}, .{});
        defer w.deinit();
        try w.expectNoDiagnostics("t.f");
    }
}
