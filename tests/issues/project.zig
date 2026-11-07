//! Upstream issues about reading a project's build files: the include
//! directories and preprocessor definitions of compile_commands.json and
//! fpm.toml; and the tests of fpm and pFUnit projects (`zfls/fpmTests`,
//! `zfls/pfunitTests`).

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
    // x is not declared: only its implicit type
    try w.expectHoverContains("a.F90", w.pos("a.F90", "x = 1", 0, 0), "Implicitly typed");
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

/// The items of a test request, one a line: `name file:line:character`,
/// indented by their depth; `children` names the lists below each level
fn outline(a: std.mem.Allocator, w: *h.Workspace, items: h.json.Value, children: []const []const u8, depth: usize, out: *std.ArrayList(u8)) !void {
    for (h.json.items(items)) |item| {
        try out.appendNTimes(a, ' ', 2 * depth);
        try out.appendSlice(a, h.json.str(h.json.get(item, "name")).?);
        if (h.json.str(h.json.get(item, "uri"))) |uri| {
            const root = try w.uri("");
            const rel = std.mem.trimStart(u8, if (std.mem.startsWith(u8, uri, root)) uri[root.len..] else uri, "/");
            const line = h.json.int(h.json.path(item, &.{ "range", "start", "line" }));
            const char = h.json.int(h.json.path(item, &.{ "range", "start", "character" }));
            if (line) |l| try out.print(a, " {s}:{d}:{d}", .{ rel, l, char.? }) else if (rel.len > 0) try out.print(a, " {s}", .{rel});
        }
        if (h.json.get(item, "selectsTests")) |v| if (v == .bool and v.bool) try out.appendSlice(a, " (selects)");
        if (h.json.get(item, "parameterized")) |v| if (v == .bool and v.bool) try out.appendSlice(a, " (parameterized)");
        try out.append(a, '\n');
        if (children.len > 0) try outline(a, w, h.json.get(item, children[0]) orelse continue, children[1..], depth + 1, out);
    }
}

test "zfls/fpmTests: each project's test targets, with test-drive's suites and tests" {
    const w = try h.Workspace.init(&.{
        .{ .name = "fpm.toml", .text =
        \\name = "demo"
        \\
        \\[[test]]
        \\name = "unit"
        \\source-dir = "tests/unit"
        \\
        },
        .{ .name = "src/demo.f90", .text =
        \\module demo
        \\end module demo
        \\
        },
        .{ .name = "test/check.f90", .text =
        \\program check
        \\  use testdrive, only : new_testsuite, select_suite, run_selected
        \\  use test_math, only : collect_math
        \\  use test_strings, only : collect_strings
        \\  testsuites = [new_testsuite("math", collect_math), &
        \\    new_testsuite("strings", collect_strings)]
        \\  is = select_suite(testsuites, suite_name)
        \\  call run_selected(testsuites(is)%collect, test_name, error_unit, stat)
        \\end program check
        \\
        },
        .{ .name = "test/test_math.f90", .text =
        \\module test_math
        \\  use testdrive, only : new_unittest, unittest_type
        \\contains
        \\  subroutine collect_math(testsuite)
        \\    type(unittest_type), allocatable, intent(out) :: testsuite(:)
        \\    testsuite = [new_unittest("adds", test_adds), &
        \\      new_unittest("fails", test_fails, should_fail=.true.)]
        \\  end subroutine collect_math
        \\end module test_math
        \\
        },
        .{ .name = "test/sub/test_strings.f90", .text =
        \\module test_strings
        \\contains
        \\  subroutine collect_strings(testsuite)
        \\    testsuite = [new_unittest("upper", test_upper)]
        \\  end
        \\end module test_strings
        \\
        },
        .{ .name = "tests/unit/main.f90", .text =
        \\program unit_main
        \\end program unit_main
        \\
        },
        // a dependency fpm fetched: not a project of the workspace
        .{ .name = "build/dependencies/test-drive/fpm.toml", .text =
        \\name = "test-drive"
        \\
        },
    }, .{});
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try outline(a, w, try w.zflsRequest("zfls/fpmTests", .{}), &.{ "targets", "suites", "tests" }, 0, &out);
    try std.testing.expectEqualStrings(
        \\demo
        \\  check test/check.f90:0:8 (selects)
        \\    math test/check.f90:4:31
        \\      adds test/test_math.f90:5:31
        \\      fails test/test_math.f90:6:20
        \\    strings test/check.f90:5:19
        \\      upper test/sub/test_strings.f90:3:31
        \\  unit tests/unit/main.f90:0:8
        \\
    , out.items);
}

test "zfls/pfunitTests: the programs of add_pfunit_ctest with their suites and tests, and the .pf files of none" {
    const w = try h.Workspace.init(&.{
        .{ .name = "CMakeLists.txt", .text =
        \\project(vectors Fortran)
        \\find_package(PFUNIT REQUIRED)
        \\add_subdirectory(tests)
        \\
        },
        .{ .name = "tests/CMakeLists.txt", .text =
        \\set(pf_files test_vectors.pf)
        \\add_pfunit_ctest(vector_tests
        \\  TEST_SOURCES ${pf_files} missing.pf
        \\  LINK_LIBRARIES vectors)
        \\
        },
        .{ .name = "tests/test_vectors.pf", .text =
        \\module test_vectors
        \\   use funit
        \\contains
        \\   @test
        \\   subroutine test_norm()
        \\      @assertEqual(5.0, 5.0)
        \\   end subroutine test_norm
        \\
        \\   @test(testParameters={[1, 2]})
        \\   subroutine test_cases(this)
        \\   end subroutine test_cases
        \\end module test_vectors
        \\
        },
        .{ .name = "other/loose.pf", .text =
        \\@test
        \\subroutine test_alone()
        \\end subroutine test_alone
        \\
        },
        // a build's copy: not the workspace's
        .{ .name = "build/tests/test_vectors.pf", .text =
        \\@test
        \\subroutine t()
        \\end subroutine t
        \\
        },
    }, .{});
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const res = try w.zflsRequest("zfls/pfunitTests", .{});
    var out: std.ArrayList(u8) = .empty;
    try outline(a, w, h.json.get(res, "programs").?, &.{ "suites", "tests" }, 0, &out);
    try out.appendSlice(a, "--\n");
    try outline(a, w, h.json.get(res, "unlisted").?, &.{"tests"}, 0, &out);
    try std.testing.expectEqualStrings(
        \\vector_tests tests/CMakeLists.txt:1:17
        \\  test_vectors_suite tests/test_vectors.pf:0:7
        \\    test_norm tests/test_vectors.pf:3:3
        \\    test_cases tests/test_vectors.pf:8:3 (parameterized)
        \\--
        \\loose_suite other/loose.pf:0:0
        \\  test_alone other/loose.pf:0:0
        \\
    , out.items);
}
