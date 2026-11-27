//! A code action that writes a procedure's documentation comment from its
//! arguments (#982), in Doxygen's tags where the file has them.

const std = @import("std");
const h = @import("harness.zig");

const opts: h.Options = .{ .init_options = "{\"enable_code_actions\": true}" };

fn stubOf(w: *h.Workspace, name: []const u8, line: i64) !?h.Workspace.Action {
    for (try w.codeActions(name, line)) |act| if (std.mem.startsWith(u8, act.title, "Add a documentation comment")) return act;
    return null;
}

test "a documentation comment for a procedure that has none (#982)" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  real function scaled(x, n) result(y)
        \\    real, intent(in) :: x
        \\    integer, intent(inout) :: n
        \\    y = x * n
        \\  end function
        \\  !> already documented
        \\  subroutine done()
        \\  end subroutine
        \\end module m
        \\
    }}, opts);
    defer w.deinit();
    try w.open("m.f90", "fortran");
    const act = (try stubOf(w, "m.f90", 3)) orelse return h.unmet("no action on the FUNCTION statement", .{});
    try h.expect(act.line == 3, "the comment goes at line {d}", .{act.line + 1});
    for ([_][]const u8{ "  !> scaled\n", "!> - x: REAL, INTENT(IN)\n", "!> - n: INTEGER, INTENT(INOUT)\n" }) |want| {
        try h.expect(std.mem.find(u8, act.new_text, want) != null, "no '{s}' in:\n{s}", .{ want, act.new_text });
    }
    try h.expect(try stubOf(w, "m.f90", 9) == null, "an action for a documented procedure", .{});
}

test "Doxygen's tags in a file that uses them (#982)" {
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text =
        \\module d
        \\  implicit none
        \\contains
        \\  !> @brief the first
        \\  subroutine first()
        \\  end subroutine
        \\  subroutine second(a, b)
        \\    integer, intent(in) :: a
        \\    integer, intent(out) :: b
        \\    b = a
        \\  end subroutine
        \\end module d
        \\
    }}, opts);
    defer w.deinit();
    try w.open("d.f90", "fortran");
    const act = (try stubOf(w, "d.f90", 6)) orelse return h.unmet("no action on the SUBROUTINE statement", .{});
    for ([_][]const u8{ "!> @brief second\n", "!> @param[in] a INTEGER, INTENT(IN)\n", "!> @param[out] b INTEGER, INTENT(OUT)\n" }) |want| {
        try h.expect(std.mem.find(u8, act.new_text, want) != null, "no '{s}' in:\n{s}", .{ want, act.new_text });
    }
}
