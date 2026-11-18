//! The compiler check (`compiler_diagnostics`) reads the compiler's messages
//! as English words, so the compiler runs in the C locale (#254); output it
//! does not understand is said rather than dropped.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;

const source = h.File{ .name = "a.f90", .text =
    \\program p
    \\  implicit none
    \\  integer :: i
    \\  i = j + 1
    \\end program p
    \\
};

/// A stand-in for gfortran that prints `line` to stderr and fails: a batch
/// file on Windows, a shell script elsewhere (`%LC_ALL%` / `$LC_ALL` in it
/// are its environment's)
fn fakeCompiler(posix_line: []const u8, windows_line: []const u8) h.File {
    return if (is_windows)
        .{ .name = "fake.cmd", .text = std.fmt.comptimePrint("@echo off\r\necho {s} 1>&2\r\nexit /b 1\r\n", .{windows_line}) }
    else
        .{ .name = "fake.sh", .text = std.fmt.comptimePrint("#!/bin/sh\necho \"{s}\" >&2\nexit 1\n", .{posix_line}) };
}

fn start(comptime fake: h.File) !*h.Workspace {
    const w = try h.Workspace.init(&.{ source, fake }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    errdefer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(std.testing.io, fake.name, .executable_file, .{});
    try w.open("a.f90", "fortran");
    return w;
}

test "the compiler runs in the C locale, so that its messages are in English (#254)" {
    const w = try start(comptime fakeCompiler("a.f90:4:7: Error: LC_ALL=$LC_ALL", "a.f90:4:7: Error: LC_ALL=%LC_ALL%"));
    defer w.deinit();
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"gfortran\"", 60)) orelse return error.NoCompilerDiagnostics;
    try std.testing.expect(std.mem.find(u8, sent, "\"message\":\"LC_ALL=C\"") != null);
}

test "a failure whose output zfls does not understand is said (#254)" {
    const w = try start(comptime fakeCompiler("a.f90:4:7: Fehler: Symbol j hat keinen IMPLICIT-Typ", "a.f90:4:7: Fehler: Symbol j hat keinen IMPLICIT-Typ"));
    defer w.deinit();
    const shown = (try w.waitForSent("window/showMessage", "did not understand", 60)) orelse return error.NothingSaid;
    try std.testing.expect(std.mem.find(u8, shown, "a.f90") != null);
}
