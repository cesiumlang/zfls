//! Intel's compilers write their preprocessor's output (`file.i90`) into
//! their working directory even when they only check a file, so zfls runs
//! them in a directory of its cache, not beside the sources (#262).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;

const source = h.File{ .name = "a.F90", .text =
    \\#define N 3
    \\program p
    \\  implicit none
    \\  integer :: i(N)
    \\  i = 1
    \\  print *, i
    \\end program p
    \\
};

/// A stand-in for ifx that writes `a.i90` into its working directory, as
/// ifort is reported to, and prints one warning
const fake: h.File = if (is_windows)
    .{ .name = "fake.cmd", .text = "@echo off\r\necho stray> a.i90\r\necho a.F90(1): warning #1: ran\r\n" }
else
    .{ .name = "fake.sh", .text = "#!/bin/sh\necho stray > a.i90\necho 'a.F90(1): warning #1: ran'\n" };

test "ifx runs in zfls's work directory, so that its .i90 files are not left beside the sources (#262)" {
    const w = try h.Workspace.init(&.{ source, fake }, .{ .init_options = "{\"compiler_diagnostics\": \"ifx\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(std.testing.io, fake.name, .executable_file, .{});
    try w.open("a.F90", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"ifx\"", 60)) orelse return error.NoCompilerDiagnostics;
    // not beside the source
    try std.testing.expectError(error.FileNotFound, w.tmp.dir.statFile(std.testing.io, "a.i90", .{}));
    // but in zfls's directory (in the workspace here: the tests have no
    // cache directory)
    var run = try w.tmp.dir.openDir(std.testing.io, ".zfls/work/run", .{ .iterate = true });
    defer run.close(std.testing.io);
    var it = run.iterate();
    const one = (try it.next(std.testing.io)) orelse return error.NoRunDirectory;
    var buf: [256]u8 = undefined;
    _ = try run.statFile(std.testing.io, try std.mem.print(&buf, "{s}/a.i90", .{one.name}), .{});
}
