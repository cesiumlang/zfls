//! The number of elements an array actual argument gives an explicit-shape
//! dummy argument (#848). gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 all
//! reject a whole array or a section that is too short; gfortran and Flang
//! also count the elements left from an element on, ifx does not.

const std = @import("std");
const h = @import("harness.zig");

const module =
    \\module m3
    \\contains
    \\  subroutine ar(a)
    \\    integer :: a(3)
    \\  end subroutine ar
    \\  subroutine ar0(a)
    \\    integer :: a(0:2)
    \\  end subroutine ar0
    \\  subroutine ars(a)
    \\    integer :: a(*)
    \\  end subroutine ars
    \\end module m3
    \\
;

const program =
    \\program p
    \\  use m3
    \\  implicit none
    \\  integer :: w(2), j(5), m(2, 3)
    \\  call ar(w)
    \\  call ar(j(1:2))
    \\  call ar(j(2:4))
    \\  call ar(j(4))
    \\  call ar(j(5))
    \\  call ar(j(1:5:2))
    \\  call ar0(j(1:2))
    \\  call ar(m(1, :))
    \\  call ars(w)
    \\  call ar(j)
    \\end program p
    \\
;

fn collect(w: *h.Workspace, name: []const u8, code: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, code)) {
        try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    };
    return out.items;
}

fn expectAll(got: []const []const u8, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

fn workspace(dialect: []const u8) !*h.Workspace {
    const opts = try std.fmt.allocPrint(std.testing.allocator, "{{\"lint_dialect\": \"{s}\"}}", .{dialect});
    return h.Workspace.init(&.{
        .{ .name = "m.f90", .text = module },
        .{ .name = "p.f90", .text = program },
    }, .{ .init_options = opts });
}

test "a whole array or a section with too few elements, in every dialect" {
    for ([_][]const u8{ "neutral", "gfortran", "ifx", "flang" }) |d| {
        const w = try workspace(d);
        defer w.deinit();
        try expectAll(try collect(w, "p.f90", "argument-too-short"), &.{
            "5: Argument a of ar: 3 elements expected, 2 given",
            "6: Argument a of ar: 3 elements expected, 2 given",
            "11: Argument a of ar0: 3 elements expected, 2 given",
        });
    }
}

test "the elements left from an element on: gfortran's and Flang's dialects" {
    for ([_][]const u8{ "neutral", "gfortran", "ifx", "flang" }) |d| {
        const w = try workspace(d);
        defer w.deinit();
        const got = try collect(w, "p.f90", "argument-storage-short");
        if (std.mem.eql(u8, d, "gfortran") or std.mem.eql(u8, d, "flang")) {
            try expectAll(got, &.{
                "8: Argument a of ar: 3 elements expected, 2 left in the array from the element given",
                "9: Argument a of ar: 3 elements expected, 1 left in the array from the element given",
            });
        } else try std.testing.expectEqual(@as(usize, 0), got.len);
    }
}
