//! The ifx kit: what Intel's ifx needs from Visual Studio to link a `/MD`
//! program, made from Zig's own files, so that the VS Code extension can
//! build with ifx where Visual Studio is not installed (`ifx /MD
//! /fuse-ld=lld`, with `LIB` on `lib/ifx`). It installs to `lib/ifx`:
//! - `zfls_ifx_shim.obj`: the startup code (src/ifxkit/shim.zig)
//! - import libraries under the names Intel's objects and libraries ask
//!   for (`msvcrt`, `ucrt`, `vcruntime`, `kernel32`, ...), made with
//!   `zig dlltool` from the MinGW-w64 `.def` files that come with Zig
//!   (public domain)

const std = @import("std");

/// Import libraries: the name ifx's objects and libraries ask for, and
/// the MinGW-w64 definition file of its DLL (`lib/libc/mingw/...`).
/// `msvcrt` and `oldnames` are the UCRT too (with the aliases of the old
/// names); `uuid` has nothing to import (Intel's COM modules only).
const libs = [_]struct { []const u8, ?[]const u8 }{
    .{ "msvcrt", "lib-common/ucrtbase.def.in" },
    .{ "ucrt", "lib-common/ucrtbase.def.in" },
    .{ "oldnames", "lib-common/ucrtbase.def.in" },
    .{ "vcruntime", "lib-common/vcruntime140.def.in" },
    .{ "kernel32", "lib-common/kernel32.def.in" },
    .{ "user32", "lib-common/user32.def.in" },
    .{ "advapi32", "lib-common/advapi32.def.in" },
    .{ "bcrypt", "lib-common/bcrypt.def" },
    .{ "ole32", "lib-common/ole32.def.in" },
    .{ "oleaut32", "lib-common/oleaut32.def.in" },
    .{ "imagehlp", "lib-common/imagehlp.def" },
    .{ "ws2_32", "lib-common/ws2_32.def.in" },
    .{ "version", "lib-common/version.def" },
    .{ "uuid", null },
};

/// The step that installs the kit
pub fn add(b: *std.Build) *std.Build.Step {
    const step = b.step("ifx-kit", "Install what ifx needs to link without Visual Studio (lib/ifx)");
    const dir: std.Build.InstallDir = .{ .custom = "lib/ifx" };

    const shim = b.addObject(.{
        .name = "zfls_ifx_shim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ifxkit/shim.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc }),
            .optimize = .ReleaseSmall,
            .strip = true,
            .stack_protector = false,
            .stack_check = false,
            .red_zone = false,
        }),
    });
    shim.bundle_compiler_rt = false;
    step.dependOn(&b.addInstallFileWithDir(shim.getEmittedBin(), dir, "zfls_ifx_shim.obj").step);

    const mingw = std.Build.LazyPath.zig_lib.path(b, "libc/mingw");
    const empty = b.addWriteFiles().add("empty.def", "LIBRARY \"ucrtbase.dll\"\nEXPORTS\n");
    for (libs) |lib| {
        const name, const template = lib;
        // the definition file, for x86_64: the templates choose by macros
        const def = if (template) |t| def: {
            const pp = std.Build.Step.Run.create(b, b.fmt("preprocess {s}.def", .{name}));
            pp.addFileArg(std.Build.LazyPath.zig_exe);
            // `-w`: the files' `;` comments are not C (apostrophes)
            pp.addArgs(&.{ "cc", "-target", "x86_64-windows-gnu", "-E", "-P", "-w", "-x", "c" });
            pp.addPrefixedDirectoryArg("-I", mingw.path(b, "def-include"));
            pp.addFileArg(mingw.path(b, t));
            pp.addArg("-o");
            break :def pp.addOutputFileArg(b.fmt("{s}.def", .{name}));
        } else empty;
        const tool = std.Build.Step.Run.create(b, b.fmt("dlltool {s}.lib", .{name}));
        tool.addFileArg(std.Build.LazyPath.zig_exe);
        tool.addArgs(&.{ "dlltool", "-m", "i386:x86-64", "-d" });
        tool.addFileArg(def);
        tool.addArg("-l");
        const out = tool.addOutputFileArg(b.fmt("{s}.lib", .{name}));
        step.dependOn(&b.addInstallFileWithDir(out, dir, b.fmt("{s}.lib", .{name})).step);
    }
    return step;
}
