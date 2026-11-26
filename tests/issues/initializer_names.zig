//! An implied-do variable in the initializer of a declaration (#850): under
//! IMPLICIT NONE gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 all report
//! `i` of `[(real(i, wp), i = 1, n)]` as having no type, as they do in an
//! executable statement.

const std = @import("std");
const h = @import("harness.zig");

fn undeclared(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, "undeclared-name")) {
        try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    };
    return out.items;
}

test "an undeclared implied-do variable in a declaration's initializer" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\program p
        \\  implicit none
        \\  integer, parameter :: n = 3
        \\  real, parameter :: wp = 1.0
        \\  real :: a(n) = [(real(i, wp), i = 1, n)]
        \\  integer :: b(3) = [(k, k = 1, 3)]
        \\  integer :: j
        \\  integer :: c(3) = [(j, j = 1, 3)]
        \\  integer :: d(3) = [(m, integer :: m = 1, 3)]
        \\  real :: e(n) = [(real(n), l = 1, n)]
        \\  character(len=3) :: s = 'abc'
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    const got = try undeclared(w, "a.f90");
    // i (twice: 5 and in `i = 1`), the first k, l
    for (got) |g| if (std.mem.find(u8, g, "\"i\"") == null and std.mem.find(u8, g, "\"k\"") == null and std.mem.find(u8, g, "\"l\"") == null) {
        std.debug.print("unexpected: {s}\n", .{g});
        return error.TestUnexpectedResult;
    };
    var lines: [3]bool = .{ false, false, false };
    for (got) |g| {
        if (std.mem.startsWith(u8, g, "5: ")) lines[0] = true;
        if (std.mem.startsWith(u8, g, "6: ")) lines[1] = true;
        if (std.mem.startsWith(u8, g, "8: ") or std.mem.startsWith(u8, g, "9: ")) {
            std.debug.print("unexpected: {s}\n", .{g});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(lines[0] and lines[1]);
}

test "a renamed name of a USE statement is no initializer" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = "module mm\n  integer :: yy\nend module\n" },
        .{ .name = "a.f90", .text = "program p\n  use, intrinsic :: iso_fortran_env, only: wp => real64\n  use mm, only: xx => yy\n  implicit none\n  integer :: k = 1\n  xx = 2\nend program\n" },
    }, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try undeclared(w, "a.f90")).len);
}
