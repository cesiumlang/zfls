//! Code actions that modernize legacy Fortran and organize USE statements
//! (#985).

const std = @import("std");
const h = @import("harness.zig");

const opts: h.Options = .{ .init_options = "{\"enable_code_actions\": true}" };

fn actionTitled(acts: []const h.Workspace.Action, title: []const u8) ?h.Workspace.Action {
    for (acts) |act| if (std.mem.eql(u8, act.title, title)) return act;
    return null;
}

test "a labeled DO and an arithmetic IF rewritten on their lines (#985)" {
    const w = try h.Workspace.init(&.{.{ .name = "old.f90", .text =
        \\program old
        \\  implicit none
        \\  integer :: i, s
        \\  s = 0
        \\  do 10 i = 1, 3
        \\    s = s + i
        \\10 continue
        \\  if (s - 6) 20, 30, 20
        \\20 stop 1
        \\30 print *, s
        \\end program old
        \\
    }}, opts);
    defer w.deinit();
    try w.open("old.f90", "fortran");
    const do_act = actionTitled(try w.codeActions("old.f90", 4), "Convert to DO ... END DO") orelse return h.unmet("no DO action", .{});
    try std.testing.expectEqualStrings("  do i = 1, 3\n    s = s + i\n  end do", do_act.new_text);
    const if_act = actionTitled(try w.codeActions("old.f90", 7), "Convert the arithmetic IF to an IF block") orelse return h.unmet("no IF action", .{});
    try h.expect(std.mem.startsWith(u8, if_act.new_text, "  if (s - 6 < 0) then\n     go to 20\n"), "the IF block: {s}", .{if_act.new_text});
}

const mods = [_]h.File{
    .{ .name = "geo.f90", .text = "module geo\n  implicit none\n  real :: radius, height\n  integer :: count\nend module geo\n" },
    .{ .name = "ops.f90", .text = "module ops\n  implicit none\n  interface operator(.plus.)\n    module procedure plus\n  end interface\ncontains\n  integer function plus(x, y)\n    integer, intent(in) :: x, y\n    plus = x + y\n  end function\nend module ops\n" },
    .{ .name = "p.f90", .text = "program p\n  use ops\n  use geo\n  use, intrinsic :: iso_fortran_env\n  implicit none\n  radius = 1.0\n  print *, radius, height, 1 .plus. 2\nend program p\n" },
};

test "organize USE sorts the statements, intrinsic modules first (#985)" {
    const w = try h.Workspace.init(&mods, opts);
    defer w.deinit();
    try w.open("p.f90", "fortran");
    const acts = try w.codeActionsOf("p.f90", 0, 0, &.{"source.organizeImports"});
    const act = actionTitled(acts, "Organize USE statements") orelse return h.unmet("no organize action", .{});
    try std.testing.expectEqualStrings("  use, intrinsic :: iso_fortran_env\n  use geo\n  use ops", act.new_text);
    // ONLY lists for the modules of the workspace that define no operator
    const only = actionTitled(acts, "Add ONLY lists to the USE statements") orelse return h.unmet("no ONLY action", .{});
    try std.testing.expectEqualStrings("  use, intrinsic :: iso_fortran_env\n  use geo, only: radius, height\n  use ops", only.new_text);
}
