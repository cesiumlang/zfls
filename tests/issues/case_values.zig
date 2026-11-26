//! CASE values that overlap an earlier one of the construct (#850): gfortran
//! 16.1, Flang 23.1.5 and ifx 2026.2.0 all report them.

const std = @import("std");
const h = @import("harness.zig");

fn overlaps(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, "case-value-overlap")) {
        try out.append(w.a(), try w.a().print("{d}:{d}: {s}", .{ d.line + 1, d.col, d.message }));
    };
    return out.items;
}

test "CASE values that overlap an earlier one, nested constructs apart" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\program p
        \\  implicit none
        \\  integer :: i
        \\  character :: c
        \\  i = 1
        \\  c = 'a'
        \\  select case (i)
        \\  case (1:5)
        \\    i = 1
        \\  case (4, 9)
        \\    i = 2
        \\  case (:0)
        \\    i = 3
        \\  case (-3)
        \\    i = 4
        \\  case (7, 7)
        \\    i = 5
        \\  end select
        \\  outer: select case (c)
        \\  case ('a', 'b')
        \\    i = 1
        \\  case ('b':'d')
        \\    i = 2
        \\  case default
        \\    select case (i)
        \\    case (1)
        \\      i = 6
        \\    case (2)
        \\      i = 7
        \\    end select
        \\  end select outer
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    const want = [_][]const u8{
        "10:8: CASE value 4 overlaps an earlier CASE value of the construct",
        "14:8: CASE value -3 overlaps an earlier CASE value of the construct",
        "16:11: CASE value 7 overlaps an earlier CASE value of the construct",
        "22:8: CASE value 'b':'d' overlaps an earlier CASE value of the construct",
    };
    const got = try overlaps(w, "a.f90");
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "CASE values: silent for distinct values, other kinds of value, and SELECT TYPE" {
    const w = try h.Workspace.init(&.{.{ .name = "b.f90", .text =
        \\program q
        \\  implicit none
        \\  integer, parameter :: k = 1
        \\  integer :: i
        \\  class(*), allocatable :: x
        \\  i = 1
        \\  select case (i)
        \\  case (1, 3)
        \\    i = 1
        \\  case (2)
        \\    i = 2
        \\  case (4:6, 8)
        \\    i = 3
        \\  end select
        \\  select case (i)
        \\  case (k)
        \\    i = 4
        \\  case (1)
        \\    i = 5
        \\  case (k + 1, &
        \\        1)
        \\    i = 6
        \\  end select
        \\  select type (x)
        \\  type is (integer)
        \\    i = 7
        \\  class default
        \\    i = 8
        \\  end select
        \\end program q
        \\
    }}, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try overlaps(w, "b.f90")).len);
}
