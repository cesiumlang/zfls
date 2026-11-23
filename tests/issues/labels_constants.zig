//! Statement labels and named constants (#850): gfortran 16.1, Flang 23.1.5
//! and ifx 2026.2.0 all report an assignment to a named constant, a label
//! defined twice in a scoping unit and a label that is named and not
//! defined there.

const std = @import("std");
const h = @import("harness.zig");

fn codes(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| {
        if (std.mem.eql(u8, d.code, "constant-assigned") or std.mem.eql(u8, d.code, "label-defined-twice") or std.mem.eql(u8, d.code, "label-not-found")) {
            try out.append(w.a(), try w.a().print("{d}: {s}: {s}", .{ d.line + 1, d.code, d.message }));
        }
    }
    return out.items;
}

test "an assignment to a named constant, a label defined twice, a label not defined" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\program p
        \\  implicit none
        \\  integer, parameter :: n = 3
        \\  integer :: i
        \\  n = 4
        \\  i = 1
        \\  goto 99
        \\10 continue
        \\10 continue
        \\  read (*, 77, err=55) i
        \\  print *, i
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    const want = [_][]const u8{
        "5: constant-assigned: Assignment to named constant n",
        "9: label-defined-twice: Label 10 is defined twice in this scope (first on line 8)",
        "7: label-not-found: Label 99 is not defined in this scope",
        "10: label-not-found: Label 55 is not defined in this scope",
        "10: label-not-found: Label 77 is not defined in this scope",
    };
    const got = try codes(w, "a.f90");
    try std.testing.expectEqual(want.len, got.len);
    for (want) |x| {
        var found = false;
        for (got) |y| if (std.mem.eql(u8, x, y)) {
            found = true;
        };
        if (!found) {
            std.debug.print("missing: {s}\n got: {any}\n", .{ x, got });
            return error.TestExpectedEqual;
        }
    }
}

test "labels and named constants: silent for valid code" {
    const w = try h.Workspace.init(&.{
        .{ .name = "b.f90", .text =
        \\program q
        \\  implicit none
        \\  integer :: i
        \\  integer, parameter :: m = 2
        \\  do 20 i = 1, 3
        \\    if (i == 2) go to 40
        \\20 continue
        \\40 continue
        \\30 format (i3)
        \\  write (*, 30) i
        \\  call s(err=0)
        \\contains
        \\  subroutine s(err)
        \\    integer :: err
        \\    err = 1
        \\10  continue
        \\  end subroutine s
        \\end program q
        \\
        },
        .{ .name = "d.f90", .text =
        \\program d
        \\  implicit none
        \\  real, parameter :: &
        \\
        \\    xv(*) = [1.0, 2.0]
        \\  print *, xv
        \\end program d
        \\
        },
        .{ .name = "c.f", .text =
        \\      program r
        \\      do 10 i = 1, 3
        \\   10 continue
        \\      read (5, 100, end=200) x
        \\  100 format (f8.2)
        \\  200 continue
        \\      end
        \\
        },
    }, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try codes(w, "b.f90")).len);
    try std.testing.expectEqual(@as(usize, 0), (try codes(w, "c.f")).len);
    // a blank line inside a continued declaration (#259)
    try std.testing.expectEqual(@as(usize, 0), (try codes(w, "d.f90")).len);
}
