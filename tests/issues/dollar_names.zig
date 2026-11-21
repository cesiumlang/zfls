//! Names with `$`, also first (`subroutine $$lib$random`), which ifx and
//! LLVM Flang accept, and gfortran after the first character with
//! `-fdollar-ok` (#508; the ifx audit, #489).

const std = @import("std");
const h = @import("harness.zig");

test "an interface body named $$lib$random ends where its END SUBROUTINE is" {
    // ifx: exit 0 (Intel's ifport.f90 and ifqwin.f90 have such names)
    const w = try h.Workspace.init(&.{.{ .name = "dl.f90", .text =
        \\module dm
        \\  interface random
        \\    subroutine $$lib$random(f)
        \\      real f
        \\    end subroutine
        \\  end interface
        \\contains
        \\  subroutine a$b()
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("dl.f90");
    const symbols = try w.documentSymbols("dl.f90");
    for ([_][]const u8{ "dm", "a$b" }) |name| {
        for (symbols) |s| {
            if (std.mem.eql(u8, s, name)) break;
        } else return h.unmet("no symbol {s} in {any}", .{ name, symbols });
    }
}

test "modules, programs, procedures, results and variables named with $ first" {
    // ifx and Flang: exit 0
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text =
        \\module $mod$x
        \\  implicit none
        \\  integer :: $count = 0
        \\contains
        \\  subroutine $sub(x)
        \\    real :: x
        \\    $count = $count + 1
        \\    x = real($count)
        \\  end subroutine $sub
        \\  function $fn() result($r)
        \\    integer :: $r
        \\    $r = 1
        \\  end function
        \\end module
        \\program $prog
        \\  use $mod$x
        \\  call $sub(y)
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("d.f90");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "$sub(y)", 0, 1), "SUBROUTINE $sub(x)");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "$count + 1", 0, 1), "INTEGER :: $count");
}
