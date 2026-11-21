//! The compiler check (`compiler_diagnostics`) with Intel's command line,
//! through a stand-in ifx that logs its arguments: the files of suffixes
//! its driver does not know (#497), the driver's messages without a
//! number (#494), fpp's, which name the file by its name only (#495), and
//! conda-forge's ifx's modules (#498).

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

/// A stand-in ifx that says what Intel's fpp says of `#error` on line 3:
/// the file by its name only, though given its path
const fpp: h.File = if (is_windows)
    .{ .name = "ifx.cmd", .text = "@echo off\r\necho u.f95(3): #error:  named by its name 1>&2\r\n" }
else
    .{ .name = "ifx.sh", .text = "#!/bin/sh\necho 'u.f95(3): #error:  named by its name' >&2\n" };

test "ifx: fpp's message, which names the file by its name only, is at its line (#495)" {
    const w = try h.Workspace.init(&.{ user, fpp }, .{ .init_options = "{\"compiler_diagnostics\": \"ifx\", \"compiler_path\": \"" ++ fpp.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fpp.name, .executable_file, .{});
    try w.open("u.f95", "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"named by its name\"", 60)) orelse return error.NoCompilerDiagnostics;
    // the diagnostic's range, before its message
    const at = std.mem.find(u8, sent, "\"message\":\"named by its name\"").?;
    const mark = "\"range\":{\"start\":{\"line\":";
    const r = std.mem.findLast(u8, sent[0..at], mark) orelse return h.unmet("no range in {s}", .{sent});
    try h.expect(std.mem.startsWith(u8, sent[r + mark.len ..], "2,"), "fpp's message is not on line 3: {s}", .{sent[r..at]});
}

/// A stand-in for conda-forge's ifx (`<prefix>\Library\bin\ifx.exe`), its
/// modules in `<prefix>\opt\compiler\include\intel64`, which it logs its
/// arguments beside
const conda_ifx: h.File = if (is_windows)
    .{ .name = "Library/bin/ifx.cmd", .text = "@echo off\r\necho %* >> \"%~dp0ifx.log\"\r\necho ifx: command line error: logged 1>&2\r\n" }
else
    .{ .name = "Library/bin/ifx.sh", .text = "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/ifx.log\"\necho 'ifx: command line error: logged' >&2\n" };

test "conda-forge's ifx: its modules, where its driver does not look, are passed with /I (#498)" {
    const modules = h.File{ .name = "opt/compiler/include/intel64/iso_fortran_env.modintr", .text = "" };
    const w = try h.Workspace.init(&.{ user, module, conda_ifx, modules }, .{ .init_options = "{\"compiler_diagnostics\": \"ifx\", \"compiler_path\": \"" ++ conda_ifx.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, conda_ifx.name, .executable_file, .{});
    try w.open("u.f95", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"ifx: logged\"", 60)) orelse return error.NoCompilerDiagnostics;
    const calls = try w.tmp.dir.readFileAlloc(io, "Library/bin/ifx.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(calls);
    const dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ "opt", "compiler", "include", "intel64" });
    defer std.testing.allocator.free(dir);
    const opt = if (is_windows) " /I" else " -I";
    var it = std.mem.tokenizeAny(u8, calls, "\r\n");
    var n: usize = 0;
    while (it.next()) |call| {
        // the probe of its predefined symbols (compiler_macros.zig, #509)
        if (std.mem.find(u8, call, "zfls_predefined.F90") != null) continue;
        n += 1;
        const at = std.mem.find(u8, call, dir) orelse return h.unmet("no {s} in {s}", .{ dir, call });
        const start = std.mem.findLast(u8, call[0..at], opt) orelse return h.unmet("{s} without {s}: {s}", .{ dir, opt, call });
        try h.expect(std.mem.findScalar(u8, call[start + 1 .. at], ' ') == null, "{s} is not an include directory: {s}", .{ dir, call });
    }
    try h.expect(n == 2, "{d} calls (the module, then the file)", .{n});
}
