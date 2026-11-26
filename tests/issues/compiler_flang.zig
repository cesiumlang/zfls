//! The compiler check (`compiler_diagnostics`) with LLVM Flang's command
//! line, through a stand-in compiler that logs its arguments: the files of
//! suffixes Flang's driver does not know (#376), its version asked
//! again when the compiler changes (#427), and its intrinsic modules where
//! its driver does not look for them (#438).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in compiler that appends its arguments to `flang.log` beside
/// itself (not in its working directory, zfls's on Windows) and gives a
/// driver message, `flang: error: logged`
const fake: h.File = if (is_windows)
    .{ .name = "flang.cmd", .text = "@echo off\r\necho %* >> \"%~dp0flang.log\"\r\necho flang: error: logged 1>&2\r\n" }
else
    .{ .name = "flang.sh", .text = "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/flang.log\"\necho 'flang: error: logged' >&2\n" };

const module = h.File{ .name = "k.cuf", .text = "module k\n  integer :: n\nend module k\n" };
const user = h.File{ .name = "u.f90", .text = "program p\n  use k\n  n = 1\nend program p\n" };

test "Flang: the file and the modules it uses with -x f95 right before them, for any suffix (#376)" {
    const w = try h.Workspace.init(&.{ module, user, fake }, .{ .init_options = "{\"compiler_diagnostics\": \"flang\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fake.name, .executable_file, .{});
    try w.open("u.f90", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"flang: logged\"", 60)) orelse return error.NoCompilerDiagnostics;
    const calls = try w.tmp.dir.readFileAlloc(io, "flang.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(calls);
    var it = std.mem.tokenizeAny(u8, calls, "\r\n");
    var files: usize = 0;
    while (it.next()) |call| {
        const line = std.mem.trimEnd(u8, call, " ");
        // the module, compiled first, then the file
        const file = if (std.mem.endsWith(u8, line, "k.cuf")) "k.cuf" else if (std.mem.endsWith(u8, line, "u.f90")) "u.f90" else continue;
        files += 1;
        // nothing but the file's path after it
        const x = std.mem.findLast(u8, line, " -x f95 ");
        if (x == null or std.mem.find(u8, line[x.? + " -x f95 ".len ..], " -") != null) {
            std.debug.print("\nno -x f95 before {s}: {s}\n", .{ file, line });
            return error.NoLanguage;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), files);
}

/// A stand-in Flang of `version` that logs its arguments to `flang.log`
/// and gives a driver message naming its version, `flang: error: <version>`
fn versioned(comptime version: []const u8) h.File {
    return if (is_windows)
        .{ .name = "flang.cmd", .text = "@echo off\r\nif \"%1\"==\"--version\" (echo flang version " ++ version ++ "& exit /b 0)\r\necho %* >> \"%~dp0flang.log\"\r\necho flang: error: " ++ version ++ " 1>&2\r\n" }
    else
        .{ .name = "flang.sh", .text = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'flang version " ++ version ++ "'; exit 0; fi\necho \"$@\" >> \"$(dirname \"$0\")/flang.log\"\necho 'flang: error: " ++ version ++ "' >&2\n" };
}

test "Flang: a compiler upgraded at the same path is asked its version again (#427)" {
    const old = comptime versioned("21.1.8");
    const w = try h.Workspace.init(&.{ user, old }, .{ .init_options = "{\"compiler_diagnostics\": \"flang\", \"compiler_path\": \"" ++ old.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, old.name, .executable_file, .{});
    try w.open("u.f90", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "flang: 21.1.8", 60)) orelse return error.NoCompilerDiagnostics;
    // Flang 21: no warnings by default (#393)
    const before = try w.tmp.dir.readFileAlloc(io, "flang.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.find(u8, before, "-Wunused-variable") == null);

    // the same path, a new Flang: its warnings
    const new = comptime versioned("23.1.5 (upgraded)");
    try w.tmp.dir.writeFile(io, .{ .sub_path = new.name, .data = new.text });
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, new.name, .executable_file, .{});
    try w.tmp.dir.deleteFile(io, "flang.log");
    try w.save("u.f90");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "flang: 23.1.5 (upgraded)", 60)) orelse return error.NoCompilerDiagnostics;
    const after = try w.tmp.dir.readFileAlloc(io, "flang.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.find(u8, after, "-Wunused-variable") != null);
}

/// A stand-in Flang at `flang/bin` whose driver's triple
/// (`x86_64-conda-linux-gnu`, conda-forge's) has no intrinsic modules
const conda_flang: h.File = if (is_windows)
    .{ .name = "flang/bin/flang.cmd", .text = "@echo off\r\nif \"%1\"==\"--version\" (echo flang version 23.1.5& echo Target: x86_64-conda-linux-gnu& echo InstalledDir: %~dp0& exit /b 0)\r\necho %* >> \"%~dp0flang.log\"\r\necho flang: error: logged 1>&2\r\n" }
else
    .{ .name = "flang/bin/flang.sh", .text = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'flang version 23.1.5'; echo 'Target: x86_64-conda-linux-gnu'; echo \"InstalledDir: $(cd \"$(dirname \"$0\")\" && pwd)\"; exit 0; fi\necho \"$@\" >> \"$(dirname \"$0\")/flang.log\"\necho 'flang: error: logged' >&2\n" };

test "Flang: its intrinsic modules where its driver does not look for them (#438)" {
    const modules = h.File{ .name = "flang/lib/clang/23/finclude/flang/x86_64-unknown-linux-gnu/iso_fortran_env.mod", .text = "" };
    const w = try h.Workspace.init(&.{ user, conda_flang, modules }, .{ .init_options = "{\"compiler_diagnostics\": \"flang\", \"compiler_path\": \"" ++ conda_flang.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, conda_flang.name, .executable_file, .{});
    try w.open("u.f90", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"flang: logged\"", 60)) orelse return error.NoCompilerDiagnostics;
    const calls = try w.tmp.dir.readFileAlloc(io, "flang/bin/flang.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(calls);
    const at = std.mem.find(u8, calls, "-fintrinsic-modules-path ") orelse {
        std.debug.print("\nno -fintrinsic-modules-path: {s}\n", .{calls});
        return error.NoIntrinsicModules;
    };
    try std.testing.expect(std.mem.find(u8, calls[at..], "x86_64-unknown-linux-gnu") != null);
}
