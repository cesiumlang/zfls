//! The compiler check (`compiler_diagnostics`) of fixed-form files with a
//! compiler, executable and arguments of their own (#280), and the end of
//! a compiler run when the server shuts down.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in compiler named `name` that appends its arguments to
/// `name.log` in its working directory and says `name` (a driver message:
/// `gfortran: name`)
fn fake(comptime name: []const u8) h.File {
    return if (is_windows)
        .{ .name = name ++ ".cmd", .text = "@echo off\r\necho %* >> " ++ name ++ ".log\r\necho gfortran: error: " ++ name ++ " 1>&2\r\n" }
    else
        .{ .name = name ++ ".sh", .text = "#!/bin/sh\necho \"$@\" >> " ++ name ++ ".log\necho 'gfortran: error: " ++ name ++ "' >&2\n" };
}

const module = h.File{ .name = "m.f90", .text = "module m\n  integer :: k\nend module m\n" };
const fixed_file = h.File{ .name = "b.f", .text =
    \\      program p
    \\      use m
    \\      k = 1
    \\      end
    \\
};
const free_file = h.File{ .name = "c.f90", .text = "program q\n  print *, 1\nend program q\n" };

fn start(files: []const h.File, comptime options: []const u8) !*h.Workspace {
    const w = try h.Workspace.init(files, .{ .init_options = options });
    errdefer w.deinit();
    if (!is_windows) for (files) |f| if (std.mem.endsWith(u8, f.name, ".sh")) {
        try w.tmp.dir.setFilePermissions(io, f.name, .executable_file, .{});
    };
    return w;
}

/// Opens `name` and waits for the stand-in's message `said`
fn expectChecked(w: *h.Workspace, name: []const u8, said: []const u8) !void {
    try w.open(name, "fortran");
    var buf: [64]u8 = undefined;
    const needle = try std.mem.print(&buf, "\"message\":\"gfortran: {s}\"", .{said});
    _ = (try w.waitForSent("textDocument/publishDiagnostics", needle, 60)) orelse {
        std.debug.print("\nno message {s} for {s}\n", .{ said, name });
        return error.NoCompilerDiagnostics;
    };
}

fn log(w: *h.Workspace, name: []const u8) ![]const u8 {
    return w.tmp.dir.readFileAlloc(io, name, std.testing.allocator, .limited(1 << 20));
}

test "fixed-form files are checked with compiler_diagnostics_fixed, and so are the modules they use (#280)" {
    const free = comptime fake("free");
    const fixed = comptime fake("fixed");
    const w = try start(&.{ module, fixed_file, free_file, free, fixed }, "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ free.name ++
        "\", \"compiler_diagnostics_fixed\": \"gfortran\", \"compiler_path_fixed\": \"" ++ fixed.name ++ "\", \"compiler_args_fixed\": [\"-DFIXEDARG\"]}");
    defer w.deinit();
    try expectChecked(w, "b.f", "fixed");
    const calls = try log(w, "fixed.log");
    defer std.testing.allocator.free(calls);
    // the free-form module, compiled with the fixed-form compiler first,
    // then the file, with the fixed form's arguments
    try std.testing.expect(std.mem.find(u8, calls, "m.f90") != null);
    try std.testing.expect(std.mem.find(u8, calls, "b.f") != null);
    try std.testing.expect(std.mem.find(u8, calls, "-DFIXEDARG") != null);
    try std.testing.expectError(error.FileNotFound, w.tmp.dir.statFile(io, "free.log", .{}));
    try expectChecked(w, "c.f90", "free");
    const free_calls = try log(w, "free.log");
    defer std.testing.allocator.free(free_calls);
    try std.testing.expect(std.mem.find(u8, free_calls, "-DFIXEDARG") == null);
}

test "without compiler_diagnostics_fixed, both forms use compiler_diagnostics (#280)" {
    const free = comptime fake("free");
    const w = try start(&.{ module, fixed_file, free }, "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ free.name ++ "\"}");
    defer w.deinit();
    try expectChecked(w, "b.f", "free");
}

test "a server shutdown stops the compiler running, and what it started (#280)" {
    // a compiler that starts a process which outlives it, then hangs
    const slow: h.File = if (is_windows)
        .{ .name = "slow.cmd", .text = "@echo off\r\nstart /b cmd /c \"ping -n 60 127.0.0.1 >nul\"\r\nping -n 60 127.0.0.1 >nul\r\n" }
    else
        .{ .name = "slow.sh", .text = "#!/bin/sh\nsleep 60 &\nsleep 60\n" };
    const w = try start(&.{ free_file, slow }, "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ slow.name ++ "\"}");
    try w.open("c.f90", "fortran");
    io.sleep(.fromMilliseconds(1500), .awake) catch {};
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    w.deinit();
    // not after the compiler's 60 seconds, nor its timeout
    try std.testing.expect(std.Io.Clock.awake.now(io).nanoseconds - before < 20 * std.time.ns_per_s);
}
