//! What the compilers' preprocessors define themselves: Intel fpp's
//! Fortran operators in `#if`, and `__LINE__`, `__FILE__`, `__DATE__`,
//! `__TIME__` of fpp and gfortran's cpp (#507), and the symbols the
//! compiler check's compiler predefines, asked of a stand-in compiler
//! (#509; the audits, #488, #489).

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
