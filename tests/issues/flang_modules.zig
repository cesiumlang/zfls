//! LLVM Flang's module files, which are Fortran source (#395): those of the
//! include directories, and of Flang's intrinsic modules when the compiler
//! check is Flang's, indexed for the modules that nothing else defines.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A module file as Flang writes it: a BOM, its checksum, the modules it
/// needs, then the module, every END bare
const ext_mod =
    "\xEF\xBB\xBF!mod$ v1 sum:4fadcad3a42bb497\n" ++
    "!need$ 36b82225e343593f n ext_kinds\n" ++
    \\module ext
    \\use ext_kinds,only:wp
    \\real(wp)::scale
    \\interface
    \\function twice(x)
    \\real(4),intent(in)::x
    \\real(4)::twice
    \\end
    \\end interface
    \\contains
    \\pure function area(r)
    \\real(4),intent(in)::r
    \\real(4)::area
    \\end
    \\end
    \\
    ;

const kinds_mod =
    "\xEF\xBB\xBF!mod$ v1 sum:36b82225e343593f\n" ++
    \\module ext_kinds
    \\integer(4),parameter::wp=8_4
    \\end
    \\
    ;

const main = h.File{ .name = "main.f90", .text =
    \\program p
    \\  use ext, only: twice, area, scale
    \\  use gzipped
    \\  use own
    \\  implicit none
    \\  print *, twice(1.0), area(2.0), scale, mine
    \\end program p
    \\
};

/// the workspace's own module, of which the include directory also has a
/// module file: the source's
const own = h.File{ .name = "own.f90", .text = "module own\n  integer :: mine = 1\nend module own\n" };

fn notFound(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.find(u8, d.message, "not found") != null) try out.append(w.a(), d.message);
    return out.items;
}

test "Flang's module files of the include directories: the modules nothing else defines (#395)" {
    const w = try h.Workspace.init(&.{
        main,
        own,
        .{ .name = "inc/ext.mod", .text = ext_mod },
        .{ .name = "inc/ext_kinds.mod", .text = kinds_mod },
        // gfortran's are compressed: not read
        .{ .name = "inc/gzipped.mod", .text = "\x1f\x8b\x08\x00\x00\x00\x00\x00" },
        .{ .name = "inc/own.mod", .text = "\xEF\xBB\xBF!mod$ v1 sum:0\nmodule own\ninteger(4)::theirs\nend\n" },
    }, .{ .init_options = "{\"include_dirs\": [\"inc\"]}" });
    defer w.deinit();
    const missing = try notFound(w, "main.f90");
    try h.expect(missing.len == 1 and std.mem.find(u8, missing[0], "\"gzipped\"") != null, "only gzipped not found: {d} ({s})", .{ missing.len, if (missing.len > 0) missing[0] else "" });
    // the module file's interface, its contained function, its variable of
    // a kind of the module it uses
    try w.expectHoverContains("main.f90", w.pos("main.f90", "twice(1.0)", 0, 1), "FUNCTION twice");
    try w.expectHoverContains("main.f90", w.pos("main.f90", "area(2.0)", 0, 1), "FUNCTION area");
    const def = (try w.definition("main.f90", w.pos("main.f90", "area(2.0)", 0, 1))) orelse return h.unmet("no definition of area", .{});
    try h.expect(std.mem.endsWith(u8, def.uri, "inc/ext.mod") and def.line == 12, "area in inc/ext.mod at line 13: {s}:{d}", .{ def.uri, def.line + 1 });
    // own: the workspace's source, not the module file
    const mine = (try w.definition("main.f90", w.pos("main.f90", "mine", 0, 1))) orelse return h.unmet("no definition of mine", .{});
    try h.expect(std.mem.endsWith(u8, mine.uri, "own.f90"), "mine in own.f90: {s}", .{mine.uri});
}

test "Flang's module files: none without include directories (#395)" {
    const w = try h.Workspace.init(&.{ main, own, .{ .name = "inc/ext.mod", .text = ext_mod } }, .{});
    defer w.deinit();
    const missing = try notFound(w, "main.f90");
    try h.expect(missing.len == 2, "ext and gzipped not found: {d}", .{missing.len});
}

/// A stand-in Flang at `flang/bin` of the triple whose directory has its
/// intrinsic modules
const flang: h.File = if (is_windows)
    .{ .name = "flang/bin/flang.cmd", .text = "@echo off\r\nif \"%1\"==\"--version\" (echo flang version 23.1.5& echo Target: x86_64-unknown-linux-gnu& echo InstalledDir: %~dp0& exit /b 0)\r\necho flang: error: logged 1>&2\r\n" }
else
    .{ .name = "flang/bin/flang.sh", .text = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'flang version 23.1.5'; echo 'Target: x86_64-unknown-linux-gnu'; echo \"InstalledDir: $(cd \"$(dirname \"$0\")\" && pwd)\"; exit 0; fi\necho 'flang: error: logged' >&2\n" };

const intrinsic_dir = "flang/lib/clang/23/finclude/flang/x86_64-unknown-linux-gnu/";

test "Flang's intrinsic modules that zfls's table lacks, with the compiler check of Flang (#395)" {
    const cuda = h.File{ .name = "k.cuf", .text =
        \\module k
        \\  use cudadevice
        \\  implicit none
        \\contains
        \\  attributes(global) subroutine kern(a)
        \\    real :: a(:)
        \\    a(threadidx%x) = 0
        \\    call syncthreads()
        \\  end subroutine kern
        \\end module k
        \\
    };
    const w = try h.Workspace.init(&.{
        cuda,
        flang,
        // the one the directory is found by, which zfls's own table has
        .{ .name = intrinsic_dir ++ "iso_fortran_env.mod", .text = "\xEF\xBB\xBF!mod$ v1 sum:0\nmodule iso_fortran_env\nend\n" },
        // syncthreads as Flang writes it, a generic of its own name (#469)
        .{ .name = intrinsic_dir ++ "cudadevice.mod", .text = "\xEF\xBB\xBF!mod$ v1 sum:1\n!need$ 2 n __cuda_device\nmodule cudadevice\nuse __cuda_device,only:threadidx\ninterface syncthreads\nprocedure::syncthreads\nend interface\ncontains\nattributes(device) subroutine syncthreads()\nend\nend\n" },
        .{ .name = intrinsic_dir ++ "__cuda_device.mod", .text = "\xEF\xBB\xBF!mod$ v1 sum:2\nmodule __cuda_device\nuse __fortran_builtins,only:__builtin_dim3\ntype(__builtin_dim3)::threadidx\nend\n" },
        .{ .name = intrinsic_dir ++ "__fortran_builtins.mod", .text = "\xEF\xBB\xBF!mod$ v1 sum:3\nmodule __fortran_builtins\ntype::__builtin_dim3\ninteger(4)::x=1_4\ninteger(4)::y=1_4\ninteger(4)::z=1_4\nend type\nend\n" },
    }, .{ .init_options = "{\"compiler_diagnostics\": \"flang\", \"compiler_path\": \"" ++ flang.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) {
        // another file at its path, which zfls asks again: the one of the
        // start did not run
        try w.tmp.dir.writeFile(io, .{ .sub_path = flang.name, .data = flang.text ++ "# runs\n" });
        try w.tmp.dir.setFilePermissions(io, flang.name, .executable_file, .{});
    }
    try w.replaceText("k.cuf", cuda.text ++ "\n");
    const missing = try notFound(w, "k.cuf");
    try h.expect(missing.len == 0, "no module not found: {d} ({s})", .{ missing.len, if (missing.len > 0) missing[0] else "" });
    try w.expectHoverContains("k.cuf", w.pos("k.cuf", "syncthreads", 0, 1), "SUBROUTINE syncthreads");
    try w.expectHoverContains("k.cuf", w.pos("k.cuf", "threadidx", 0, 1), "__builtin_dim3");
}

test "Flang's intrinsic modules: not without the compiler check of Flang (#395)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "u.f90", .text = "program p\n  use cudadevice\nend program p\n" },
        flang,
        .{ .name = intrinsic_dir ++ "iso_fortran_env.mod", .text = "" },
        .{ .name = intrinsic_dir ++ "cudadevice.mod", .text = "\xEF\xBB\xBF!mod$ v1 sum:1\nmodule cudadevice\nend\n" },
    }, .{});
    defer w.deinit();
    const missing = try notFound(w, "u.f90");
    try h.expect(missing.len == 1, "cudadevice not found: {d}", .{missing.len});
}
