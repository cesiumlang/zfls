//! The compiler check (`compiler_diagnostics`) with LLVM Flang's command
//! line, through a stand-in compiler that logs its arguments: the files of
//! suffixes Flang's driver does not know (#376).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in compiler that appends its arguments to `flang.log` in its
/// working directory and gives a driver message, `flang: error: logged`
const fake: h.File = if (is_windows)
    .{ .name = "flang.cmd", .text = "@echo off\r\necho %* >> flang.log\r\necho flang: error: logged 1>&2\r\n" }
else
    .{ .name = "flang.sh", .text = "#!/bin/sh\necho \"$@\" >> flang.log\necho 'flang: error: logged' >&2\n" };

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
