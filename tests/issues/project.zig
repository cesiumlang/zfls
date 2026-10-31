//! Upstream issues about reading a project's build files: the include
//! directories and preprocessor definitions of compile_commands.json and
//! fpm.toml.

const std = @import("std");
const h = @import("harness.zig");

fn expectCompileCommands(w: *h.Workspace) !void {
    // USE_KIND from the command line, WP from kinds.h in the -I directory
    try w.expectHoverContains("src/a.F90", w.pos("src/a.F90", "x = 1", 0, 0), "REAL(8)");
}

test "#512 compile_commands.json gives the include directories and definitions of the Fortran files" {
    const w = try h.Workspace.init(&.{
        .{ .name = "build/compile_commands.json", .text =
        \\[
        \\  {"directory": "..", "file": "src/a.F90",
        \\   "command": "gfortran -Iinc -DUSE_KIND -c src/a.F90 -o build/a.o"},
        \\  {"directory": "..", "file": "src/c.c",
        \\   "command": "cc -DUSE_KIND=0 -c src/c.c"}
        \\]
        \\
        },
        .{ .name = "inc/kinds.h", .text =
        \\#define WP 8
        \\
        },
        .{ .name = "src/a.F90", .text =
        \\program p
        \\#include "kinds.h"
        \\#ifdef USE_KIND
        \\  real(WP) :: x
        \\#endif
        \\  x = 1
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try h.check(512, .fixed, expectCompileCommands(w));
}

test "a compile_commands option of \"\" reads no compilation database" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text =
        \\{"compile_commands": ""}
        \\
        },
        .{ .name = "compile_commands.json", .text =
        \\[{"directory": ".", "file": "a.F90", "command": "gfortran -DUSE_KIND -c a.F90"}]
        \\
        },
        .{ .name = "a.F90", .text =
        \\program p
        \\#ifdef USE_KIND
        \\  real :: x
        \\#endif
        \\  x = 1
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    try std.testing.expect((try w.hover("a.F90", w.pos("a.F90", "x = 1", 0, 0))) == null);
}

fn expectFpm(w: *h.Workspace) !void {
    try w.expectHoverContains("src/m.F90", w.pos("src/m.F90", "k = N", 0, 0), "k = 4");
    try w.expectHoverContains("src/m.F90", w.pos("src/m.F90", "n2 = M", 0, 0), "n2 = 2");
}

test "Modern Fortran #471 fpm.toml gives the include directory and the preprocessor macros" {
    const w = try h.Workspace.init(&.{
        .{ .name = "fpm.toml", .text =
        \\name = "demo"
        \\
        \\[library]
        \\include-dir = "headers"  # not the default "include"
        \\
        \\[preprocess]
        \\[preprocess.cpp]
        \\macros = [
        \\  "HAVE_X",
        \\  "N=4",
        \\]
        \\
        },
        .{ .name = "headers/consts.h", .text =
        \\#define M 2
        \\
        },
        .{ .name = "src/m.F90", .text =
        \\module m
        \\  implicit none
        \\#include "consts.h"
        \\#ifdef HAVE_X
        \\  integer, parameter :: k = N
        \\#endif
        \\  integer, parameter :: n2 = M
        \\end module m
        \\
        },
    }, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 471, .fixed, expectFpm(w));
}
