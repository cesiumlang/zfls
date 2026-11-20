//! DEC's TAB-format fixed form (#491): a line whose TAB in columns 1 to 6
//! stands for the columns up to 6, a nonzero digit after it marking a
//! continuation line. ifx, ifort, gfortran and Flang read such a `.f` file
//! as fixed form, and so does zfls, also for the compiler check.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// The audit's `dl5.f` and a continuation, which ifx, gfortran 16.1 and
/// Flang 23.1.5 accept (`I = 3`)
const tabs = h.File{ .name = "tc.f", .text = "      PROGRAM TC\n      IMPLICIT NONE\n      INTEGER I, J\n\tI = 1 +\n\t1 2\n10\tJ = I\nC     comment here\nD     PRINT *, I\n\tPRINT *, I, J\n\tEND\n" };

test "#491 a file with TAB-format lines is fixed form: comments, labels, continuations" {
    const w = try h.Workspace.init(&.{tabs}, .{});
    defer w.deinit();
    try w.open("tc.f", "fortran");
    try h.expect(try w.isFixed("tc.f"), "tc.f is read in free form", .{});
    // the C and D lines are comments, the 2 of the continuation no label
    try w.expectNoDiagnostics("tc.f");
    try w.expectHoverContains("tc.f", .{ .line = 3, .col = 1 }, "INTEGER :: I");
    try w.expectHoverContains("tc.f", .{ .line = 5, .col = 3 }, "INTEGER :: J");
    var refs: usize = 0;
    for (try w.references("tc.f", .{ .line = 2, .col = 14 })) |r| refs += @intFromBool(r.line == 3 or r.line == 5 or r.line == 8);
    try h.expect(refs == 3, "{d} of the 3 references to I in TAB-format lines", .{refs});
    // the names of a TAB-format line are colored, those of its comment not
    var names: usize = 0;
    for (try w.semanticTokens("tc.f")) |t| {
        if (t.line == 3 and std.mem.eql(u8, t.text, "I")) names += 1;
        try h.expect(t.line != 6 or std.mem.eql(u8, t.type, "comment"), "a {s} token in the comment", .{t.type});
    }
    try h.expect(names == 1, "{d} tokens for I on line 4", .{names});
}

test "#491 an undeclared name in a TAB-format continuation line" {
    const w = try h.Workspace.init(&.{.{ .name = "tu.f", .text = "      PROGRAM TU\n      IMPLICIT NONE\n      INTEGER I\n\tI = 1 +\n\t1 JUNDEF\n\tEND\n" }}, .{});
    defer w.deinit();
    try w.open("tu.f", "fortran");
    var found = false;
    for (try w.diagnostics("tu.f")) |d| {
        try h.expect(std.mem.find(u8, d.message, "\"JUNDEF\"") != null, "diagnostic: {s}", .{d.message});
        found = d.line == 4 and d.col == 3;
    }
    try h.expect(found, "no diagnostic for JUNDEF at 5:4", .{});
}

/// A stand-in gfortran that appends its arguments to `gf.log` in its
/// working directory and gives a driver message, `gfortran: error: logged`
const fake: h.File = if (is_windows)
    .{ .name = "gf.cmd", .text = "@echo off\r\necho %* >> gf.log\r\necho gfortran: error: logged 1>&2\r\n" }
else
    .{ .name = "gf.sh", .text = "#!/bin/sh\necho \"$@\" >> gf.log\necho 'gfortran: error: logged' >&2\n" };

test "#491 the compiler checks a file with TAB-format lines as fixed form" {
    const w = try h.Workspace.init(&.{ tabs, fake }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fake.name, .executable_file, .{});
    try w.open("tc.f", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "\"message\":\"gfortran: logged\"", 60)) orelse return error.NoCompilerDiagnostics;
    const calls = try w.tmp.dir.readFileAlloc(io, "gf.log", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(calls);
    try h.expect(std.mem.find(u8, calls, "-ffixed-form") != null and std.mem.find(u8, calls, "-ffree-form") == null, "gfortran called with {s}", .{calls});
}
