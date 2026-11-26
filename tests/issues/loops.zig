//! EXIT and CYCLE with no construct name outside a DO construct (#850):
//! gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 all report them, in a block
//! or an IF construct as well.

const std = @import("std");
const h = @import("harness.zig");

/// The "line: code" of the EXIT and CYCLE diagnostics of a file
fn found(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| {
        if (std.mem.eql(u8, d.code, "exit-outside-loop") or std.mem.eql(u8, d.code, "cycle-outside-loop")) {
            try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.code }));
        }
    }
    return out.items;
}

fn expectFound(text: []const u8, name: []const u8, want: []const []const u8) !void {
    const w = try h.Workspace.init(&.{.{ .name = name, .text = text }}, .{});
    defer w.deinit();
    const got = try found(w, name);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "EXIT and CYCLE outside a loop, in a block or an IF construct" {
    try expectFound(
        \\program p
        \\  implicit none
        \\  integer :: i
        \\  i = 1
        \\  if (i > 0) exit
        \\  cycle
        \\  do i = 1, 3
        \\    if (i == 2) cycle
        \\  end do
        \\  block
        \\    exit
        \\  end block
        \\  if (i > 0) then
        \\    cycle
        \\  end if
        \\end program
        \\
    , "a.f90", &.{ "5: exit-outside-loop", "6: cycle-outside-loop", "11: exit-outside-loop", "14: cycle-outside-loop" });
}

test "EXIT and CYCLE in fixed form, after labeled loops" {
    try expectFound(
        \\      program p
        \\      integer i, j
        \\      do 10 i = 1, 3
        \\         do 10 j = 1, 3
        \\            if (j .eq. 2) cycle
        \\   10 continue
        \\      do 20 i = 1, 3
        \\         if (i .eq. 2) exit
        \\   20 end do
        \\      if (i .eq. 3) cycle
        \\      end
        \\
    , "a.f", &.{"10: cycle-outside-loop"});
}

test "EXIT and CYCLE inside loops, named ones and variables named like them are not reported" {
    try expectFound(
        \\program p
        \\  implicit none
        \\  integer :: i, j, exit
        \\  outer: do i = 1, 3
        \\    do while (j < 3)
        \\      select case (i)
        \\      case (1)
        \\        cycle
        \\      case default
        \\        exit
        \\      end select
        \\      if (j == 1) exit outer
        \\    end do
        \\    do concurrent (j = 1:2)
        \\    end do
        \\    cycle outer
        \\  end do outer
        \\  blk: block
        \\    exit blk
        \\  end block blk
        \\  exit = 1
        \\end program
        \\
    , "a.f90", &.{});
}

test "a file whose DO constructs cannot be counted is not checked" {
    // an END DO with no DO, `;`, an INCLUDE
    try expectFound("subroutine s\n  end do\n  exit\nend subroutine\n", "a.f90", &.{});
    try expectFound("subroutine s\n  integer :: i\n  do i = 1, 2; exit; end do\n  exit\nend subroutine\n", "a.f90", &.{});
    try expectFound("subroutine s\n  include 'x.inc'\n  exit\nend subroutine\n", "a.f90", &.{});
}
