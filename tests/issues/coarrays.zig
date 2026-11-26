//! The coarray constructs and statements of Fortran 2018 and 2023: CHANGE
//! TEAM, CRITICAL with a sync-stat list.

const std = @import("std");
const h = @import("harness.zig");

test "CHANGE TEAM opens a construct that END TEAM closes (#720)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "t.f90", .text =
        \\module m_team
        \\  use iso_fortran_env, only: team_type
        \\  implicit none
        \\contains
        \\  subroutine work(n)
        \\    integer, intent(in) :: n
        \\    type(team_type) :: t
        \\    integer :: k, st
        \\    real :: y[*]
        \\    character(len=40) :: msg
        \\    form team (n, t)
        \\    change team (t)
        \\      k = team_number()
        \\    end team
        \\    named: change team (t, x[*] => y, stat=st, errmsg=msg)
        \\      x = 1.0
        \\    end team (stat=st) named
        \\    CHANGE TEAM (t)
        \\      k = 2
        \\    END TEAM (STAT=st, ERRMSG=msg)
        \\    print *, k
        \\  end subroutine
        \\  subroutine after()
        \\    print *, 'after'
        \\  end subroutine
        \\end module
        \\
        },
        .{ .name = "e.f90", .text = "subroutine e(t)\n" ++
            "  use iso_fortran_env, only: team_type\n" ++
            "  type(team_type) :: t\n" ++
            "  change team (t)\n" ++
            "  end \n" },
    }, .{ .snippet_support = true });
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
    // the unit goes on after END TEAM
    const syms = try w.documentSymbols("t.f90");
    var found = false;
    for (syms) |s| found = found or std.mem.eql(u8, s, "after");
    try h.expect(found, "symbols: {any}", .{syms});
    try w.expectHoverContains("t.f90", w.pos("t.f90", "print *, k", 0, 9), "INTEGER :: k");
    // the associate name is the coarray it names
    try w.expectHoverContains("t.f90", w.pos("t.f90", "x = 1.0", 0, 0), "REAL, CODIMENSION[*] :: x");
    // the end statement offered in the construct
    const items = try w.completion("e.f90", w.pos("e.f90", "  end \n", 0, 6));
    found = false;
    for (items) |s| found = found or std.mem.eql(u8, s, "END TEAM");
    try h.expect(found, "completion: {any}", .{items});
}

test "END TEAM outside CHANGE TEAM does not end the procedure (#720)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine s()
        \\  implicit none
        \\  integer :: k
        \\  end team
        \\  k = 1
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try w.expectDiagnostics("t.f90", &.{"4: END TEAM does not match SUBROUTINE \"s\" opened at line 1"});
}

test "CRITICAL with STAT= or ERRMSG= is a construct (#722)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program crit
        \\  implicit none
        \\  integer :: x[*], st
        \\  character(len=80) :: msg
        \\  critical (stat=st)
        \\    x = 1
        \\  end critical
        \\  named: critical (stat=st, errmsg=msg) ! a comment
        \\    x = 2
        \\  end critical named
        \\  CRITICAL(ERRMSG=msg)
        \\    x = 3
        \\  END CRITICAL
        \\  print *, x, st
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "print *, x", 0, 9), "INTEGER, CODIMENSION[*] :: x");
}
