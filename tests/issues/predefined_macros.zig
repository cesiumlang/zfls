//! What the compilers' preprocessors define themselves: Intel fpp's
//! Fortran operators in `#if`, and `__LINE__`, `__FILE__`, `__DATE__`,
//! `__TIME__` of fpp and gfortran's cpp (#507), and the symbols the
//! compiler check's compiler predefines, asked of a stand-in compiler
//! (ifx #509, gfortran #541; the audits, #488, #489).

const std = @import("std");
const sysinfo = @import("builtin");
const h = @import("harness.zig");

const is_windows = sysinfo.target.os.tag == .windows;
const io = std.testing.io;

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

/// A stand-in ifx that predefines `__INTEL_LLVM_COMPILER` and `_WIN32`
/// (the probe's names 1 and 6) when it preprocesses (`/fpp /E`)
const ifx: h.File = if (is_windows)
    .{ .name = "ifx.cmd", .text = "@echo off\r\necho %* | findstr /c:\"/fpp /E\" >nul && (echo zfls_def 1 20260200& echo zfls_def 6 1& exit /b 0)\r\nexit /b 0\r\n" }
else
    .{ .name = "ifx.sh", .text = "#!/bin/sh\ncase \" $* \" in *\" -fpp -E \"*) printf 'zfls_def 1 20260200\\nzfls_def 6 1\\n'; exit 0;; esac\nexit 0\n" };

test "ifx: its predefined symbols in #ifdef, #if and !DEC$ IF (#509)" {
    const pp = h.File{ .name = "p.F90", .text =
        \\program p
        \\  implicit none
        \\#ifdef __INTEL_LLVM_COMPILER
        \\  integer :: intel_only
        \\#else
        \\  integer :: not_intel
        \\#endif
        \\!DEC$ IF DEFINED(_WIN32)
        \\  integer :: win32
        \\!DEC$ ENDIF
        \\!DEC$ IF (__INTEL_LLVM_COMPILER >= 20250000)
        \\  integer :: newer
        \\!DEC$ ENDIF
        \\  intel_only = 1
        \\  win32 = 1
        \\  newer = 1
        \\end program p
        \\
    };
    const opts = "{\"compiler_diagnostics\": \"ifx\", \"compiler_path\": \"" ++ ifx.name ++ "\"}";
    const w = try h.Workspace.init(&.{ pp, ifx }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) {
        // executable only now: the settings again, which ask it
        try w.tmp.dir.setFilePermissions(io, ifx.name, .executable_file, .{});
        try w.changeConfiguration("{\"compiler_diagnostics\": \"ifx\", \"compiler_path\": \"" ++ ifx.name ++ "\", \"pp_defs\": {\"ZFLS_X\": \"\"}}");
    }
    try w.open("p.F90", "fortran");
    for ([_][]const u8{ "intel_only = 1", "win32 = 1", "newer = 1" }) |at| {
        const got = (try w.hover("p.F90", w.pos("p.F90", at, 0, 0))) orelse return h.unmet("no hover at {s}", .{at});
        try h.expect(std.mem.find(u8, got, "INTEGER") != null, "hover at {s}: {s}", .{ at, got });
    }
    try h.expect((try w.hover("p.F90", w.pos("p.F90", "not_intel", 0, 0))) == null, "not_intel is in an active branch", .{});
}

/// A stand-in gfortran that predefines `__GFORTRAN__` and `__GNUC__` (`-dM`)
const gfortran: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho %* | findstr /c:\" -dM \" >nul && (echo #define __GFORTRAN__ 1& echo #define __GNUC__ 16& exit /b 0)\r\necho gfortran: error: logged 1>&2\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\ncase \" $* \" in *\" -dM \"*) printf '#define __GFORTRAN__ 1\\n#define __GNUC__ 16\\n'; exit 0;; esac\necho 'gfortran: error: logged' >&2\n" };

test "gfortran: its predefined macros in #ifdef and #if (#541)" {
    const pp = h.File{ .name = "p.F90", .text = "program p\n  implicit none\n#ifdef __GFORTRAN__\n  integer :: gf_only\n#else\n  integer :: not_gfortran\n#endif\n#if __GNUC__ >= 9\n  gf_only = 1\n#endif\nend program p\n" };
    const opts = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\"}";
    const w = try h.Workspace.init(&.{ pp, gfortran }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) {
        // executable only now: the settings again, which ask it
        try w.tmp.dir.setFilePermissions(io, gfortran.name, .executable_file, .{});
        try w.changeConfiguration("{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\", \"pp_defs\": {\"ZFLS_X\": \"\"}}");
    }
    try w.open("p.F90", "fortran");
    const got = (try w.hover("p.F90", w.pos("p.F90", "gf_only", 1, 0))) orelse return h.unmet("no hover on gf_only in #if __GNUC__ >= 9", .{});
    try h.expect(std.mem.find(u8, got, "INTEGER") != null, "hover on gf_only: {s}", .{got});
    try h.expect((try w.hover("p.F90", w.pos("p.F90", "not_gfortran", 0, 0))) == null, "not_gfortran is in an active branch", .{});
}

/// A stand-in gfortran 9 (`-dM`), for the fixed form
const gfortran9: h.File = if (is_windows)
    .{ .name = "gfortran9.cmd", .text = "@echo off\r\necho %* | findstr /c:\" -dM \" >nul && (echo #define __GFORTRAN__ 1& echo #define __GNUC__ 9& exit /b 0)\r\nexit /b 0\r\n" }
else
    .{ .name = "gfortran9.sh", .text = "#!/bin/sh\ncase \" $* \" in *\" -dM \"*) printf '#define __GFORTRAN__ 1\\n#define __GNUC__ 9\\n'; exit 0;; esac\nexit 0\n" };

/// Whether `name` is declared in an active branch of `file`
fn active(w: *h.Workspace, file: []const u8, name: []const u8) !bool {
    const got = (try w.hover(file, w.pos(file, name, 0, 0))) orelse return false;
    return std.mem.find(u8, got, "INTEGER") != null;
}

test "gfortran: the fixed form's compiler's macros for fixed-form files (#657)" {
    const free = h.File{ .name = "p.F90", .text = "program p\n#if __GNUC__ >= 16\n  integer :: new_free\n#else\n  integer :: old_free\n#endif\nend program p\n" };
    const fixed = h.File{ .name = "q.F", .text = "      PROGRAM Q\n#if __GNUC__ < 10\n      INTEGER OLDFIX\n#else\n      INTEGER NEWFIX\n#endif\n      END\n" };
    const opts = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\", \"compiler_path_fixed\": \"" ++ gfortran9.name ++ "\"}";
    const w = try h.Workspace.init(&.{ free, fixed, gfortran, gfortran9 }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) {
        try w.tmp.dir.setFilePermissions(io, gfortran.name, .executable_file, .{});
        try w.tmp.dir.setFilePermissions(io, gfortran9.name, .executable_file, .{});
        try w.changeConfiguration("{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\", \"compiler_path_fixed\": \"" ++ gfortran9.name ++ "\", \"pp_defs\": {\"ZFLS_X\": \"\"}}");
    }
    try w.open("p.F90", "fortran");
    try w.open("q.F", "fortran");
    try h.expect(try active(w, "p.F90", "new_free"), "new_free is in an inactive branch", .{});
    try h.expect(!try active(w, "p.F90", "old_free"), "old_free is in an active branch", .{});
    try h.expect(try active(w, "q.F", "OLDFIX"), "OLDFIX is in an inactive branch", .{});
    try h.expect(!try active(w, "q.F", "NEWFIX"), "NEWFIX is in an active branch", .{});
}

/// A stand-in gfortran that predefines `__OPTIMIZE__` with `-O2` (as
/// gfortran 16.1 does)
const gfortran_opt: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho %* | findstr /c:\" -dM \" >nul || exit /b 0\r\necho #define __GFORTRAN__ 1\r\necho %* | findstr /c:\" -O2 \" >nul && echo #define __OPTIMIZE__ 1\r\nexit /b 0\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\ncase \" $* \" in *\" -dM \"*) ;; *) exit 0;; esac\necho '#define __GFORTRAN__ 1'\ncase \" $* \" in *\" -O2 \"*) echo '#define __OPTIMIZE__ 1';; esac\nexit 0\n" };

test "gfortran: the macros of each file's command's options (#657)" {
    const src = "program {s}\n#ifdef __OPTIMIZE__\n  integer :: optimized\n#else\n  integer :: plain\n#endif\nend program {s}\n";
    const db = h.File{ .name = "compile_commands.json", .text = "[{\"directory\": \".\", \"file\": \"a.F90\", \"command\": \"gfortran -O2 -c a.F90\"},\n {\"directory\": \".\", \"file\": \"b.F90\", \"command\": \"gfortran -c b.F90\"}]\n" };
    const opts = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran_opt.name ++ "\"}";
    const w = try h.Workspace.init(&.{
        db,
        gfortran_opt,
        .{ .name = "a.F90", .text = std.fmt.comptimePrint(src, .{ "a", "a" }) },
        .{ .name = "b.F90", .text = std.fmt.comptimePrint(src, .{ "b", "b" }) },
    }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) {
        try w.tmp.dir.setFilePermissions(io, gfortran_opt.name, .executable_file, .{});
        try w.changeConfiguration("{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran_opt.name ++ "\", \"pp_defs\": {\"ZFLS_X\": \"\"}}");
    }
    try w.open("a.F90", "fortran");
    try w.open("b.F90", "fortran");
    try h.expect(try active(w, "a.F90", "optimized"), "a.F90 (-O2): optimized is in an inactive branch", .{});
    try h.expect(!try active(w, "b.F90", "optimized"), "b.F90: optimized is in an active branch", .{});
    try h.expect(try active(w, "b.F90", "plain"), "b.F90: plain is in an inactive branch", .{});
}

/// A stand-in gfortran (`-dM`) that makes `probes/<option>` beside itself
/// for its `-mk...` option, and `probes/dup<option>` when it was asked with
/// it before (on Windows it runs in zfls's directory)
const gfortran_once: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho %* | findstr /c:\" -dM \" >nul || exit /b 0\r\nfor %%a in (%*) do echo %%a| findstr /b /c:\"-mk\" >nul && (mkdir \"%~dp0probes\\%%a\" 2>nul || mkdir \"%~dp0probes\\dup%%a\" 2>nul)\r\necho #define __GFORTRAN__ 1\r\nexit /b 0\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\ncase \" $* \" in *\" -dM \"*) ;; *) exit 0;; esac\nfor x in \"$@\"; do case $x in -mk*) mkdir probes/$x 2>/dev/null || mkdir probes/dup$x 2>/dev/null;; esac; done\nsleep 0.1\necho '#define __GFORTRAN__ 1'\n" };

test "gfortran: the indexing threads ask each command's options once (#703)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 32 files, of 8 option sets
    const sets = 8;
    var files: std.ArrayList(h.File) = .empty;
    var db: std.ArrayList(u8) = .empty;
    try db.append(a, '[');
    for (0..32) |i| {
        const name = try a.print("m{d}.F90", .{i});
        try files.append(a, .{ .name = name, .text = try a.print("module m{d}\nend module m{d}\n", .{ i, i }) });
        try db.print(a, "{s}{{\"directory\": \".\", \"file\": \"{s}\", \"command\": \"gfortran -mk{d} -c {s}\"}}\n", .{ if (i > 0) "," else "", name, i % sets, name });
    }
    try db.appendSlice(a, "]\n");
    try files.appendSlice(a, &.{ gfortran_once, .{ .name = "compile_commands.json", .text = db.items }, .{ .name = "probes/keep", .text = "" } });
    const opts = "\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran_once.name ++ "\", \"nthreads\": 8";
    const w = try h.Workspace.init(files.items, .{ .init_options = "{" ++ opts ++ "}" });
    defer w.deinit();
    if (!is_windows) {
        // executable only now: the settings again, which index again
        try w.tmp.dir.setFilePermissions(io, gfortran_once.name, .executable_file, .{});
        try w.changeConfiguration("{" ++ opts ++ ", \"pp_defs\": {\"ZFLS_X\": \"\"}}");
    }
    for (0..sets) |k| {
        try h.expect(h.zfls.paths.isDir(io, try w.path(try a.print("probes/-mk{d}", .{k}))), "-mk{d}: not asked", .{k});
        try h.expect(!h.zfls.paths.isDir(io, try w.path(try a.print("probes/dup-mk{d}", .{k}))), "-mk{d}: asked more than once", .{k});
    }
}
