//! gfortran's module files (#544): a module that only its `.mod` of
//! gfortran's defines (a library installed without its sources) is read
//! from it: `gfortran_mod/lib.mod` is gfortran 16.1's of
//! `gfortran_mod/lib.f90`, in the workspace as `inc/lib.mod` alone.

const std = @import("std");
const h = @import("harness.zig");

const main = h.File{ .name = "main.f90", .text =
    \\program main
    \\  use lib
    \\  implicit none
    \\  real :: v(3)
    \\  v = 1
    \\  x = pi
    \\  call s(v)
    \\  print *, n, f(1.0), scale%a, gen(2.0)
    \\end program main
    \\
};

test "use lib: the module from gfortran's module file (#544)" {
    const w = try h.Workspace.init(&.{ main, .{ .name = "inc/lib.mod", .text = @embedFile("gfortran_mod/lib.mod") } }, .{ .init_options = "{\"include_dirs\": [\"inc\"]}" });
    defer w.deinit();
    try w.open("main.f90", "fortran");
    for (try w.diagnostics("main.f90")) |d| try h.expect(d.severity > 2, "{d}: {s}", .{ d.line, d.message });
    try w.expectHoverContains("main.f90", w.pos("main.f90", "x = pi", 0, 0), "REAL(8) :: x");
    try w.expectHoverContains("main.f90", w.pos("main.f90", "x = pi", 0, 4), "REAL(4), PARAMETER :: pi = 3.14159");
    try w.expectHoverContains("main.f90", w.pos("main.f90", "call s", 0, 5), "SUBROUTINE s(a");
    try w.expectHoverContains("main.f90", w.pos("main.f90", "n, f(", 0, 0), "INTEGER(4), PARAMETER :: n = 3");
    try w.expectHoverContains("main.f90", w.pos("main.f90", "scale%a", 0, 6), "REAL(4) :: a");
}

test "without the module file, lib is not found" {
    const w = try h.Workspace.init(&.{main}, .{});
    defer w.deinit();
    try w.open("main.f90", "fortran");
    var found = false;
    for (try w.diagnostics("main.f90")) |d| found = found or std.mem.eql(u8, d.code, "module-not-found");
    try h.expect(found, "no module-not-found", .{});
}
