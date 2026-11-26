//! A change to the settings that choose the compiler of the compiler check
//! or its options (`compiler_path`, `compiler_args`, the compile commands)
//! reads the compiler's modules and predefined symbols again and checks
//! the open documents again (#693), through stand-in gfortrans.

const std = @import("std");
const sysinfo = @import("builtin");
const h = @import("harness.zig");

const is_windows = sysinfo.target.os.tag == .windows;
const io = std.testing.io;

/// The stand-ins are no sources of the workspace
const rc = h.File{ .name = ".fortlsrc", .text = "{\"excl_paths\": [\"gnu/**\", \"one/**\", \"two/**\"]}\n" };

/// A stand-in gfortran whose `-print-file-name=finclude` is `gnu/finclude`
const gfortran: h.File = if (is_windows)
    .{ .name = "gnu/bin/gfortran.cmd", .text = "@echo off\r\necho %* | findstr /c:\"-print-file-name=finclude\" >nul && (echo %~dp0..\\finclude& exit /b 0)\r\nexit /b 0\r\n" }
else
    .{ .name = "gnu/bin/gfortran", .text = "#!/bin/sh\ncase \" $* \" in *\" -print-file-name=finclude \"*) echo \"$(cd \"$(dirname \"$0\")/..\" && pwd)/finclude\"; exit 0;; esac\nexit 0\n" };

/// A module of that gfortran's, with a routine no other omp_lib has
const omp_lib = h.File{ .name = "gnu/finclude/omp_lib.f90", .text =
    \\      module omp_lib
    \\        interface
    \\          subroutine omp_zfls_stand_in (verbose)
    \\            logical,intent(in) :: verbose
    \\          end subroutine omp_zfls_stand_in
    \\        end interface
    \\      end module omp_lib
    \\
};

test "setting compiler_path reads the modules of that gfortran (#693)" {
    const src = h.File{ .name = "o.f90", .text =
        \\program o
        \\  use omp_lib
        \\  implicit none
        \\  call omp_zfls_stand_in(.true.)
        \\end program o
        \\
    };
    const w = try h.Workspace.init(&.{ rc, gfortran, omp_lib, src }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"gnu/none/gfortran\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, gfortran.name, .executable_file, .{});
    try w.open("o.f90", "fortran");
    try w.changeConfiguration("{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\"}");
    try w.expectHoverContains("o.f90", w.pos("o.f90", "omp_zfls_stand_in(", 0, 1), "SUBROUTINE omp_zfls_stand_in(verbose)");
}

/// A stand-in gfortran that predefines ZFLS_OPT with -O2, as gfortran
/// predefines `__OPTIMIZE__`
const optimizing: h.File = if (is_windows)
    .{ .name = "gnu/bin/gfortran.cmd", .text = "@echo off\r\necho %* | findstr /c:\"-O2\" >nul && echo #define ZFLS_OPT 1\r\nexit /b 0\r\n" }
else
    .{ .name = "gnu/bin/gfortran", .text = "#!/bin/sh\ncase \" $* \" in *\" -O2 \"*) echo '#define ZFLS_OPT 1';; esac\nexit 0\n" };

test "setting compiler_args reads the symbols the compiler predefines with them (#693)" {
    const src = h.File{ .name = "p.F90", .text =
        \\program p
        \\#ifdef ZFLS_OPT
        \\  integer :: optimized
        \\#endif
        \\  optimized = 1
        \\end program p
        \\
    };
    const opts = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ optimizing.name ++ "\"";
    const w = try h.Workspace.init(&.{ rc, optimizing, src }, .{ .init_options = opts ++ "}" });
    defer w.deinit();
    if (!is_windows) {
        try w.tmp.dir.setFilePermissions(io, optimizing.name, .executable_file, .{});
        // executable only now: indexed again, which asks it
        try w.changeConfiguration(opts ++ ", \"pp_defs\": {\"ZFLS_X\": \"\"}}");
    }
    try w.open("p.F90", "fortran");
    try w.expectHoverContains("p.F90", w.pos("p.F90", "optimized = 1", 0, 1), "Implicitly typed");
    try w.changeConfiguration(opts ++ ", \"compiler_args\": [\"-O2\"]}");
    try w.expectHoverContains("p.F90", w.pos("p.F90", "optimized = 1", 0, 1), "INTEGER :: optimized");
}

/// Two stand-in gfortrans, each with its own error message
const first: h.File = if (is_windows)
    .{ .name = "one/gfortran.cmd", .text = "@echo off\r\necho gfortran: error: first 1>&2\r\nexit /b 1\r\n" }
else
    .{ .name = "one/gfortran", .text = "#!/bin/sh\necho 'gfortran: error: first' >&2\nexit 1\n" };
const second: h.File = if (is_windows)
    .{ .name = "two/gfortran.cmd", .text = "@echo off\r\necho gfortran: error: second 1>&2\r\nexit /b 1\r\n" }
else
    .{ .name = "two/gfortran", .text = "#!/bin/sh\necho 'gfortran: error: second' >&2\nexit 1\n" };

test "setting compiler_path checks the open documents with that compiler (#693)" {
    const src = h.File{ .name = "c.f90", .text = "program c\nend program c\n" };
    const w = try h.Workspace.init(&.{ rc, first, second, src }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ first.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) {
        try w.tmp.dir.setFilePermissions(io, first.name, .executable_file, .{});
        try w.tmp.dir.setFilePermissions(io, second.name, .executable_file, .{});
    }
    try w.open("c.f90", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"gfortran: first\"", 60)) orelse return error.NoCompilerDiagnostics;
    try w.changeConfiguration("{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ second.name ++ "\"}");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"gfortran: second\"", 60)) orelse return error.NotCheckedAgain;
}
