//! The module sources that Intel's compilers ship (#513): `use ifport`
//! reads `ifport.f90` of `<bin>/../opt/compiler/include` (oneAPI's and
//! conda-forge's Linux layout; conda-forge's Windows one is a level up),
//! of a stand-in compiler with stand-in sources, not Intel's; and the
//! `finclude` sources of gfortran's (#544)

const std = @import("std");
const sysinfo = @import("builtin");
const h = @import("harness.zig");

const is_windows = sysinfo.target.os.tag == .windows;
const io = std.testing.io;

const ifx: h.File = if (is_windows)
    .{ .name = "intel/bin/ifx.cmd", .text = "@echo off\r\nexit /b 0\r\n" }
else
    .{ .name = "intel/bin/ifx", .text = "#!/bin/sh\nexit 0\n" };

const ifcore = h.File{ .name = "intel/opt/compiler/include/ifcore.f90", .text =
    \\      MODULE IFCORE
    \\      INTERFACE
    \\        SUBROUTINE TRACEBACKQQ(STRING)
    \\          CHARACTER*(*) STRING
    \\        END SUBROUTINE
    \\      END INTERFACE
    \\      END MODULE IFCORE
    \\
};

/// Two modules in one file, as Intel's ifport.f90 has them
const ifport = h.File{ .name = "intel/opt/compiler/include/ifport.f90", .text =
    \\      MODULE IFPORT_TYPES
    \\      INTEGER, PARAMETER :: JHANDLE_SIZE = 8
    \\      END MODULE IFPORT_TYPES
    \\      MODULE IFPORT
    \\      use IFPORT_TYPES
    \\      INTERFACE
    \\        INTEGER(4) FUNCTION GETPID()
    \\          !DEC$ ATTRIBUTES DEFAULT :: GETPID
    \\        END FUNCTION
    \\      END INTERFACE
    \\      END MODULE IFPORT
    \\
};

/// The stand-ins are no sources of the workspace
const rc = h.File{ .name = ".fortlsrc", .text = "{\"excl_paths\": [\"intel/**\", \"gnu/**\"]}\n" };

const main = h.File{ .name = "main.f90", .text =
    \\program main
    \\  use ifport
    \\  use ifcore, only: tracebackqq
    \\  implicit none
    \\  print *, getpid(), jhandle_size
    \\  call tracebackqq("here")
    \\end program main
    \\
};

test "use ifport: the module from the sources the compiler check's ifx ships (#513)" {
    const opts = "{\"compiler_diagnostics\": \"ifx\", \"compiler_path\": \"" ++ ifx.name ++ "\"}";
    const w = try h.Workspace.init(&.{ rc, ifx, ifcore, ifport, main }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) {
        try w.tmp.dir.setFilePermissions(io, ifx.name, .executable_file, .{});
        try w.changeConfiguration(opts);
    }
    try w.open("main.f90", "fortran");
    for (try w.diagnostics("main.f90")) |d| try h.expect(d.severity > 2, "{d}: {s}", .{ d.line, d.message });
    try w.expectHoverContains("main.f90", w.pos("main.f90", "getpid()", 0, 1), "INTEGER(4) :: GETPID");
    try w.expectHoverContains("main.f90", w.pos("main.f90", "jhandle_size", 0, 1), "JHANDLE_SIZE = 8");
    try w.expectHoverContains("main.f90", w.pos("main.f90", "tracebackqq(\"", 0, 1), "SUBROUTINE TRACEBACKQQ");
}

test "use ifport without an Intel compiler: not found, as before (#513)" {
    const w = try h.Workspace.init(&.{ rc, ifx, ifcore, ifport, main }, .{});
    defer w.deinit();
    try w.open("main.f90", "fortran");
    var not_found: usize = 0;
    for (try w.diagnostics("main.f90")) |d| if (std.mem.eql(u8, d.code, "module-not-found")) {
        not_found += 1;
    };
    try h.expect(not_found == 2, "{d} module-not-found", .{not_found});
}

/// A stand-in gfortran whose `-print-file-name=finclude` is `gnu/finclude`
const gfortran: h.File = if (is_windows)
    .{ .name = "gnu/bin/gfortran.cmd", .text = "@echo off\r\necho %* | findstr /c:\"-print-file-name=finclude\" >nul && (echo %~dp0..\\finclude& exit /b 0)\r\nexit /b 0\r\n" }
else
    .{ .name = "gnu/bin/gfortran", .text = "#!/bin/sh\ncase \" $* \" in *\" -print-file-name=finclude \"*) echo \"$(cd \"$(dirname \"$0\")/..\" && pwd)/finclude\"; exit 0;; esac\nexit 0\n" };

/// As gfortran's omp_lib.f90 has it, with a routine zfls's table has not
const omp_lib = h.File{ .name = "gnu/finclude/omp_lib.f90", .text =
    \\      module omp_lib_kinds
    \\        integer, parameter :: omp_integer_kind = 4
    \\      end module omp_lib_kinds
    \\      module omp_lib
    \\        use omp_lib_kinds
    \\        interface
    \\          subroutine omp_display_env (verbose)
    \\            logical,intent(in) :: verbose
    \\          end subroutine omp_display_env
    \\        end interface
    \\      end module omp_lib
    \\
};

test "use omp_lib: the module from the finclude sources of the compiler check's gfortran (#544)" {
    const src = h.File{ .name = "o.f90", .text =
        \\program o
        \\  use omp_lib
        \\  implicit none
        \\  call omp_display_env(.true.)
        \\end program o
        \\
    };
    const opts = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\"}";
    const w = try h.Workspace.init(&.{ rc, gfortran, omp_lib, src }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) {
        try w.tmp.dir.setFilePermissions(io, gfortran.name, .executable_file, .{});
        try w.changeConfiguration(opts);
    }
    try w.open("o.f90", "fortran");
    for (try w.diagnostics("o.f90")) |d| try h.expect(d.severity > 2, "{d}: {s}", .{ d.line, d.message });
    try w.expectHoverContains("o.f90", w.pos("o.f90", "omp_display_env(", 0, 1), "SUBROUTINE omp_display_env(verbose)");
}
