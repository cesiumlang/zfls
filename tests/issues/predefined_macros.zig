//! What the compilers' preprocessors define themselves: Intel fpp's
//! Fortran operators in `#if`, and `__LINE__`, `__FILE__`, `__DATE__`,
//! `__TIME__` of fpp and gfortran's cpp (#507; the audits, #488, #489).

const std = @import("std");
const h = @import("harness.zig");

test "Fortran operators in #if, __LINE__ and __FILE__ (Intel's fpp)" {
    // ifx /fpp: exit 0
    const w = try h.Workspace.init(&.{.{ .name = "fpp1.F90", .text =
        \\#define N 10
        \\program fpp1
        \\  implicit none
        \\  real :: arr(N)
        \\#if defined(N) .and. N > 5
        \\  integer :: fortran_ops
        \\#endif
        \\  fortran_ops = 2
        \\  arr = 0
        \\  print *, size(arr), __LINE__, __FILE__
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("fpp1.F90");
    try w.expectHoverContains("fpp1.F90", w.pos("fpp1.F90", "fortran_ops = 2", 0, 0), "INTEGER");
}

test "__DATE__ and __TIME__ (gfortran's cpp), and a #define of __LINE__ wins" {
    // gfortran -cpp: exit 0
    const w = try h.Workspace.init(&.{.{ .name = "pp.F90", .text =
        \\#define __LINE__ 7
        \\program pp
        \\  implicit none
        \\  integer :: lines(__LINE__)
        \\  print *, __DATE__, __TIME__, size(lines)
        \\end program pp
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("pp.F90");
    try w.expectHoverContains("pp.F90", w.pos("pp.F90", "lines)", 0, 0), "DIMENSION(7)");
}
