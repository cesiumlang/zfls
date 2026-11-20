//! Upstream issues about included files: `#include` and INCLUDE into a
//! module or a submodule, the USE statements and IMPLICIT NONE of an
//! included file, and an include that is not found.

const std = @import("std");
const h = @import("harness.zig");

test "#495 hover and definition inside a file that is #included into a module" {
    const w = try h.Workspace.init(&.{
        .{ .name = "hello.F90", .text =
        \\module hello
        \\    implicit none
        \\    integer :: global_variable
        \\contains
        \\#include "file.f90"
        \\end module hello
        \\
        },
        .{ .name = "file.f90", .text =
        \\subroutine uses_global()
        \\    global_variable = 1
        \\end subroutine uses_global
        \\
        },
    }, .{});
    defer w.deinit();
    const def = try w.definition("file.f90", w.pos("file.f90", "global_variable", 0, 2));
    try h.check(495, .fixed, blk: {
        const l = def orelse break :blk h.unmet("global_variable is not found from the included file", .{});
        break :blk h.expect(std.mem.endsWith(u8, l.uri, "hello.F90"), "definition is in {s}", .{l.uri});
    });
}

const include_uses = [_]h.File{
    .{ .name = "tmod.f90", .text =
    \\module tmod
    \\  implicit none
    \\  type :: tt
    \\    integer :: comp
    \\  end type
    \\  integer :: modvar
    \\contains
    \\  subroutine tsub(n)
    \\    integer, intent(in) :: n
    \\  end subroutine tsub
    \\end module tmod
    \\
    },
    .{ .name = "uses.inc", .text =
    \\      use tmod
    \\      implicit none
    \\
    },
    .{ .name = "main.f90", .text =
    \\subroutine s1()
    \\  include 'uses.inc'
    \\  type(tt) :: v
    \\  v%comp = modvar
    \\  call tsub(1)
    \\  undeclared = 1
    \\end subroutine s1
    \\
    },
    .{ .name = "main2.F90", .text =
    \\subroutine s2()
    \\#include "uses.inc"
    \\  type(tt) :: v
    \\  v%comp = modvar
    \\  call tsub(1)
    \\  undeclared = 1
    \\end subroutine s2
    \\
    },
};

/// The USE and IMPLICIT NONE of uses.inc apply in `name`, which includes it
fn expectIncludedUses(w: *h.Workspace, name: []const u8) !void {
    var undeclared = false;
    for (try w.diagnostics(name)) |d| {
        if (std.mem.eql(u8, d.code, "object-not-found") or std.mem.eql(u8, d.code, "module-not-found") or std.mem.eql(u8, d.code, "use-after-implicit"))
            return h.unmet("{s}:{d}: {s}", .{ name, d.line + 1, d.message });
        if (std.mem.find(u8, d.message, "\"undeclared\" is not declared") != null) undeclared = true;
    }
    try h.expect(undeclared, "{s}: undeclared is not reported", .{name});
    try w.expectHoverContains(name, w.pos(name, "v%comp", 0, 2), "INTEGER :: comp");
    const at = w.pos(name, "modvar", 0, 0);
    try w.expectHoverContains(name, at, "INTEGER :: modvar");
    if (std.mem.find(u8, (try w.hover(name, at)).?, "Implicitly") != null) return h.unmet("{s}: modvar is implicitly typed", .{name});
    try w.expectHoverContains(name, w.pos(name, "tsub", 0, 0), "tsub");
    const def = (try w.definition(name, at)) orelse return h.unmet("{s}: no definition of modvar", .{name});
    try h.expect(std.mem.endsWith(u8, def.uri, "tmod.f90"), "{s}: modvar is defined in {s}", .{ name, def.uri });
    // completion offers it without adding a USE statement
    for (try w.completionItems(name, w.pos(name, "modvar", 0, 4))) |item| {
        if (std.mem.eql(u8, item.label, "modvar") and item.added != null) return h.unmet("{s}: completion adds {s}", .{ name, item.added.? });
    }
}

test "USE and IMPLICIT NONE in a file included with INCLUDE or #include apply in the including scope (#249)" {
    const w = try h.Workspace.init(&include_uses, .{});
    defer w.deinit();
    try expectIncludedUses(w, "main.f90");
    try expectIncludedUses(w, "main2.F90");
    // its IMPLICIT NONE is not without a scope: it applies in the includer's
    try w.expectNoDiagnostics("uses.inc");
    // without the USE in the included file, the type is not found again
    try w.changeOnDisk("uses.inc", "      integer :: other\n");
    var not_found = false;
    for (try w.diagnostics("main.f90")) |d| {
        if (std.mem.eql(u8, d.code, "object-not-found")) not_found = true;
    }
    try h.expect(not_found, "tt is still found after the USE was removed from uses.inc", .{});
}

test "USE statements in the active branch of an #included header and in a header it #includes apply (#249)" {
    const files = include_uses ++ [_]h.File{
        .{ .name = "kmod.f90", .text =
        \\module kmod
        \\  implicit none
        \\  integer :: kvar
        \\end module kmod
        \\
        },
        .{ .name = "outer.INC", .text =
        \\#ifdef NOT_DEFINED
        \\      use nonexistent
        \\#else
        \\      use tmod
        \\#endif
        \\#include "inner.inc"
        \\      implicit none
        \\
        },
        .{ .name = "inner.inc", .text =
        \\      use kmod
        \\
        },
        .{ .name = "main3.F90", .text =
        \\subroutine s3()
        \\#include "outer.INC"
        \\  type(tt) :: v
        \\  v%comp = modvar + kvar
        \\  call tsub(1)
        \\  undeclared = 1
        \\end subroutine s3
        \\
        },
    };
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try expectIncludedUses(w, "main3.F90");
    try w.expectNoDiagnostics("outer.INC");
    try w.expectHoverContains("main3.F90", w.pos("main3.F90", "kvar", 0, 0), "INTEGER :: kvar");
}

const petsc_file = [_]h.File{.{ .name = "a.F90", .text =
    \\module multigrid
    \\#include <petsc/finclude/petscksp.h>
    \\  use petscksp
    \\  implicit none
    \\contains
    \\  subroutine destroy(prec)
    \\    PC, intent(inout) :: prec
    \\    PetscErrorCode ierr
    \\    call PCDestroy(prec, ierr)
    \\  end subroutine destroy
    \\end module multigrid
    \\
}};

/// The diagnostics of `name` are those of `want` (0-based line and code,
/// sorted), in any order
fn expectCodes(w: *h.Workspace, name: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var got: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| try got.append(arena.allocator(), try arena.allocator().print("{d}:{s}", .{ d.line, d.code }));
    std.mem.sort([]const u8, got.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    errdefer for (got.items) |g| std.debug.print("{s}: {s}\n", .{ name, g });
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "an #include whose file is not found gets a diagnostic, and what depends on it no errors (#282)" {
    const w = try h.Workspace.init(&petsc_file, .{});
    defer w.deinit();
    try expectCodes(w, "a.F90", &.{ "1:include-not-found", "2:module-not-found" });
    var found = false;
    for (try w.diagnostics("a.F90")) |d| {
        if (!std.mem.eql(u8, d.code, "include-not-found")) continue;
        found = true;
        try std.testing.expectEqualStrings("Include file \"petsc/finclude/petscksp.h\" not found (include_dirs)", d.message);
        try std.testing.expectEqual(@as(i64, 3), d.severity);
    }
    try std.testing.expect(found);
}

test "diagnostic_severity turns include-not-found off (#282)" {
    const w = try h.Workspace.init(&petsc_file, .{ .diagnostic_severity = &.{.{ .code = "include-not-found", .level = "off" }} });
    defer w.deinit();
    try expectCodes(w, "a.F90", &.{"2:module-not-found"});
}

test "a missing #include in one procedure, or in a branch #if leaves out, leaves the other checks on (#282)" {
    const w = try h.Workspace.init(&.{.{ .name = "b.F90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  subroutine one(x)
        \\#include "nothere.h"
        \\    HT :: x
        \\  end subroutine one
        \\  subroutine two(y)
        \\#if 0
        \\#include "nothere_either.h"
        \\#endif
        \\  end subroutine two
        \\end module m
        \\
    }}, .{});
    defer w.deinit();
    try expectCodes(w, "b.F90", &.{ "4:include-not-found", "7:argument-not-declared" });
}

test "#include <file> is found in include_dirs (#282)" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text = "{\"include_dirs\": [\"inc\"]}\n" },
        .{ .name = "inc/h.h", .text = "#define HT integer\n" },
        .{ .name = "s.F90", .text =
        \\subroutine s(a)
        \\#include <h.h>
        \\  implicit none
        \\  HT :: a
        \\  a = 1
        \\end subroutine
        \\
        },
    }, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("s.F90");
    try w.expectHoverContains("s.F90", w.pos("s.F90", "a = 1", 0, 0), "INTEGER :: a");
}

test "a procedure #included into a submodule is found before another file's of the same name" {
    // two libraries each #include their own errors.F90 into their
    // submodules; each submodule calls the one it includes, not the one
    // whose path sorts first
    const t = struct {
        fn errors(comptime args: []const u8) []const u8 {
            return "subroutine assert_error(" ++ args ++ ")\n  logical, intent(in) :: a\nend subroutine assert_error\n";
        }
        fn module(comptime lib: []const u8) []const u8 {
            return "module " ++ lib ++ "_m\n  implicit none\n  interface\n    module subroutine " ++ lib ++ "_s()\n    end subroutine " ++ lib ++ "_s\n  end interface\nend module " ++ lib ++ "_m\n";
        }
        fn submodule(comptime lib: []const u8, comptime call_args: []const u8) []const u8 {
            return "submodule(" ++ lib ++ "_m) s\n  implicit none\ncontains\n  module procedure " ++ lib ++ "_s\n    call assert_error(" ++ call_args ++ ")\n  end procedure " ++ lib ++ "_s\n\n#include \"../../include/errors.F90\"\n\nend submodule s\n";
        }
    };
    const w = try h.Workspace.init(&.{
        .{ .name = "base/src/submodules/include/errors.F90", .text = t.errors("a, lineno") },
        .{ .name = "base/src/modules/m.F90", .text = t.module("base") },
        .{ .name = "base/src/submodules/m/src/m@s.F90", .text = t.submodule("base", ".true., 1") },
        .{ .name = "classes/src/submodules/include/errors.F90", .text = t.errors("a") },
        .{ .name = "classes/src/modules/m.F90", .text = t.module("classes") },
        .{ .name = "classes/src/submodules/m/src/m@s.F90", .text = t.submodule("classes", ".true.") },
    }, .{});
    defer w.deinit();
    inline for (.{ "base", "classes" }, .{ "lineno", "assert_error(a)" }) |lib, signature| {
        const file = lib ++ "/src/submodules/m/src/m@s.F90";
        const call = w.pos(file, "assert_error", 0, 2);
        const def = (try w.definition(file, call)) orelse return h.unmet("no definition of assert_error in {s}", .{file});
        try h.expect(std.mem.endsWith(u8, def.uri, lib ++ "/src/submodules/include/errors.F90"), "assert_error in {s} is {s}", .{ file, def.uri });
        try w.expectHoverContains(file, call, signature);
        // the included procedures are checked and outlined in their own file,
        // at their own lines, not as the submodule's: no "definition before
        // CONTAINS", and no symbol at their lines in the submodule
        try w.expectNoDiagnostics(file);
        for (try w.documentSymbols(file)) |name|
            try h.expect(!std.mem.eql(u8, name, "assert_error"), "{s} outlines the included assert_error", .{file});
    }
    // still so once the included file has been edited and linked again
    try w.replaceText("classes/src/submodules/include/errors.F90", t.errors("a, msg"));
    const file = "classes/src/submodules/m/src/m@s.F90";
    try w.expectHoverContains(file, w.pos(file, "assert_error", 0, 2), "assert_error(a, msg)");
}
