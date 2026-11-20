//! The compiler check (`compiler_diagnostics`) with Intel's command line,
//! through a stand-in ifx that logs its arguments: the files of suffixes
//! its driver does not know (#497), and the driver's messages without a
//! number (#494).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in ifx that appends its arguments to `ifx.log` in its working
/// directory (zfls's, for Intel's compilers) and gives a driver message
/// without a number, as ifx's `command line error` (#494)
const fake: h.File = if (is_windows)
    .{ .name = "ifx.cmd", .text = "@echo off\r\necho %* >> \"%~dp0ifx.log\"\r\necho ifx: command line error: logged 1>&2\r\n" }
else
    .{ .name = "ifx.sh", .text = "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/ifx.log\"\necho 'ifx: command line error: logged' >&2\n" };

const module = h.File{ .name = "k.f08", .text = "module k\n  integer :: n\nend module k\n" };
const user = h.File{ .name = "u.f95", .text = "program p\n  use k\n  n = 1\nend program p\n" };

test "ifx: the file and the modules it uses with /Tf (-Tf) right before them, for any suffix (#497)" {
    const w = try h.Workspace.init(&.{ module, user, fake }, .{ .init_options = "{\"compiler_diagnostics\": \"ifx\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fake.name, .executable_file, .{});
    try w.open("u.f95", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"ifx: logged\"", 60)) orelse return error.NoCompilerDiagnostics;
    const calls = try w.tmp.dir.readFileAlloc(io, "ifx.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(calls);
    const mark = if (is_windows) " /Tf " else " -Tf ";
    var it = std.mem.tokenizeAny(u8, calls, "\r\n");
    var files: usize = 0;
    while (it.next()) |call| {
        const line = std.mem.trimEnd(u8, call, " ");
        // the module, compiled first, then the file
        const file = if (std.mem.endsWith(u8, line, "k.f08")) "k.f08" else if (std.mem.endsWith(u8, line, "u.f95")) "u.f95" else continue;
        files += 1;
        // nothing but the file's path after it
        const x = std.mem.findLast(u8, line, mark);
        const rest = if (x) |i| line[i + mark.len ..] else "";
        if (x == null or std.mem.find(u8, rest, " /") != null or std.mem.find(u8, rest, " -") != null) {
            std.debug.print("\nno {s} before {s}: {s}\n", .{ mark, file, line });
            return error.NoLanguage;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), files);
}
