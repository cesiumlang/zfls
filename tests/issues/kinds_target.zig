//! The kinds of the compiler's target (#548): REAL(10), x87 extended
//! precision, is gfortran's and LLVM Flang's on x86 only; gfortran on
//! aarch64 (Linux, Apple Silicon) has none, nor have Intel's compilers, so
//! `selected_real_kind(18)` is 16 there.

const std = @import("std");
const sysinfo = @import("builtin");
const h = @import("harness.zig");
const zfls = @import("zfls");

const is_windows = sysinfo.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in gfortran whose `-dM` has `__GFC_REAL_10__` or not
fn standIn(comptime real10: bool) h.File {
    const extra = if (real10) "& echo #define __GFC_REAL_10__ 1" else "";
    const extra_sh = if (real10) "\\n#define __GFC_REAL_10__ 1" else "";
    return if (is_windows)
        .{ .name = "gfortran.cmd", .text = "@echo off\r\necho %* | findstr /c:\" -dM \" >nul && (echo #define __GFORTRAN__ 1" ++ extra ++ "& exit /b 0)\r\nexit /b 0\r\n" }
    else
        .{ .name = "gfortran.sh", .text = "#!/bin/sh\ncase \" $* \" in *\" -dM \"*) printf '#define __GFORTRAN__ 1" ++ extra_sh ++ "\\n'; exit 0;; esac\nexit 0\n" };
}

const source = h.File{ .name = "k.f90", .text =
    \\module k
    \\  implicit none
    \\  integer, parameter :: k18 = selected_real_kind(18)
    \\contains
    \\  subroutine take16(x)
    \\    real(16), intent(in) :: x
    \\    print *, x
    \\  end subroutine take16
    \\  subroutine use_it()
    \\    real(k18) :: y
    \\    y = 1
    \\    call take16(y)
    \\  end subroutine use_it
    \\end module k
    \\
};

fn kindErrors(comptime real10: bool) !usize {
    const gf = comptime standIn(real10);
    const opts = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gf.name ++ "\"}";
    const w = try h.Workspace.init(&.{ source, gf }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) {
        try w.tmp.dir.setFilePermissions(io, gf.name, .executable_file, .{});
        try w.changeConfiguration("{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gf.name ++ "\", \"pp_defs\": {\"ZFLS_X\": \"\"}}");
    }
    var n: usize = 0;
    for (try w.diagnostics("k.f90")) |d| if (std.mem.find(u8, d.message, "REAL(16) expected") != null) {
        n += 1;
    };
    return n;
}

test "selected_real_kind(18) is 10 with a gfortran that has REAL(10), 16 with one that has not (#548)" {
    // x86-64: `Type mismatch in argument 'x' ... passed REAL(10) to REAL(16)`
    try h.expect(try kindErrors(true) == 1, "no REAL(10) mismatch with __GFC_REAL_10__", .{});
    // aarch64: none
    try h.expect(try kindErrors(false) == 0, "a REAL(10) mismatch without __GFC_REAL_10__", .{});
}

test "a gfortran has REAL(10) where it targets x86, as zfls's default has it there (CI: every platform's)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try std.testing.environ.createMap(a);
    const exe = env.get("GFORTRAN") orelse "gfortran";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const defs = zfls.compilers_predefined.ask(a, a, .gfortran, exe, .{ .io = io, .env = &env, .work_dir = dir, .cwd = null, .openmp = false }) orelse return error.SkipZigTest;
    var real10 = false;
    for (defs) |d| if (std.mem.eql(u8, d.name, "__GFC_REAL_10__")) {
        real10 = true;
    };
    // its target, which an emulated one does not share with zfls (MSYS2's
    // x86-64 gfortran on Windows on Arm)
    const r = std.process.run(a, io, .{ .argv = &.{ exe, "-dumpmachine" }, .environ_map = &env, .create_no_window = true }) catch return error.SkipZigTest;
    const machine = std.mem.trim(u8, r.stdout, " \r\n");
    const x86 = std.mem.startsWith(u8, machine, "x86_64") or std.mem.startsWith(u8, machine, "i686") or std.mem.startsWith(u8, machine, "i386");
    try h.expect(real10 == x86, "gfortran {s} ({s}) has REAL(10): {}", .{ exe, machine, real10 });
    const ours = @tagName(sysinfo.target.cpu.arch);
    if (!std.mem.startsWith(u8, machine, ours)) return;
    try h.expect(real10 == zfls.argcheck_typing.native_real10, "gfortran {s} has REAL(10): {}, zfls's default: {}", .{ exe, real10, zfls.argcheck_typing.native_real10 });
}
