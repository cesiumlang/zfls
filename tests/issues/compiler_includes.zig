//! The compiler check (`compiler_diagnostics`): a message in a file that
//! the file checked includes, at its INCLUDE or `#include` line (#496).
//! ifx, ifort and gfortran name only the included file; stand-ins print
//! their messages as ifx 2026.2.0 and gfortran 16.1 do.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

const inc = h.File{ .name = "inc/bad.inc", .text = "  integer :: ok_inc\n  undeclared_in_inc = 1\n" };
const outer = h.File{ .name = "inc/outer.inc", .text = "  include 'bad.inc'\n" };
const incl = h.File{ .name = "incl.f90", .text = "program incl\n  implicit none\n  include 'inc/bad.inc'\n  ok_inc = 2\nend program\n" };
const nest = h.File{ .name = "nest.f90", .text = "program nest\n  implicit none\n  include 'outer.inc'\n  ok_inc = 2\nend program\n" };

/// A stand-in compiler `name` that prints `message` (on stderr)
fn says(comptime name: []const u8, comptime message: []const u8) h.File {
    return if (is_windows)
        .{ .name = name ++ ".cmd", .text = "@echo off\r\necho " ++ message ++ " 1>&2\r\nexit /b 1\r\n" }
    else
        .{ .name = name ++ ".sh", .text = "#!/bin/sh\necho '" ++ message ++ "' >&2\nexit 1\n" };
}

/// Checks `file` with the stand-in `fake` of compiler `id` and expects the
/// message `text` on 0-based line `line`, related to the included file
fn expectAtInclude(files: []const h.File, comptime id: []const u8, comptime fake: h.File, file: []const u8, comptime text: []const u8, line: i64, comptime extra: []const u8) !void {
    const w = try h.Workspace.init(files, .{ .init_options = "{\"compiler_diagnostics\": \"" ++ id ++ "\", \"compiler_path\": \"" ++ fake.name ++ "\"" ++ extra ++ "}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fake.name, .executable_file, .{});
    try w.open(file, "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", text, 60)) orelse return error.NoCompilerDiagnostics;
    const at = std.mem.find(u8, sent, text).?;
    const mark = "\"range\":{\"start\":{\"line\":";
    const r = std.mem.findLast(u8, sent[0..at], mark) orelse return h.unmet("no range in {s}", .{sent});
    var buf: [16]u8 = undefined;
    const want = try std.mem.print(&buf, "{d},", .{line});
    try h.expect(std.mem.startsWith(u8, sent[r + mark.len ..], want), "the message is not on line {d}: {s}", .{ line + 1, sent[r..] });
    // with the place in the included file
    try h.expect(std.mem.find(u8, sent, "\"relatedInformation\"") != null and std.mem.find(u8, sent, "inc/bad.inc\"") != null, "no related information: {s}", .{sent});
}

test "#496 ifx: a message in an INCLUDE'd file, at the INCLUDE line" {
    const fake = comptime says("ifx", "inc/bad.inc(2): error #6404: This name does not have a type, and must have an explicit type.   [UNDECLARED_IN_INC]");
    try expectAtInclude(&.{ inc, incl, fake }, "ifx", fake, "incl.f90", "This name does not have a type", 2, "");
}

test "#496 gfortran: a message in an INCLUDE'd file, at the INCLUDE line" {
    const fake = comptime says("gfortran", "inc/bad.inc:2:3: Error: Symbol 'undeclared_in_inc' at (1) has no IMPLICIT type");
    try expectAtInclude(&.{ inc, incl, fake }, "gfortran", fake, "incl.f90", "has no IMPLICIT type", 2, "");
}

test "#496 gfortran: a message in a file included by an included file, at the outer INCLUDE line" {
    const fake = comptime says("gfortran", "bad.inc:2:3: Error: Symbol 'undeclared_in_inc' at (1) has no IMPLICIT type");
    try expectAtInclude(&.{ inc, outer, nest, fake }, "gfortran", fake, "nest.f90", "has no IMPLICIT type", 2, ", \"compiler_include_dirs\": [\"inc\"]");
}
