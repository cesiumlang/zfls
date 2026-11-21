//! The compiler check on TAB-format lines (DEC's, #491): a compiler's
//! column there, which counts the TAB as several, as the line's byte, so
//! that the message's range is the name (#584). Through a stand-in
//! gfortran that gives gfortran 16.1's message.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// gfortran 16.1 on `\t1 JUNDEF`, the continuation line 5 of tu.f: column
/// 13, the name's last letter, with the TAB as columns 1 to 5
const fake: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho tu.f:5:13: Error: Symbol 'jundef' at (1) has no IMPLICIT type 1>&2\r\nexit /b 1\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\necho \"tu.f:5:13: Error: Symbol 'jundef' at (1) has no IMPLICIT type\" >&2\nexit 1\n" };

test "gfortran: a message on a TAB-format line covers the name, not the line's end (#584)" {
    const tu = h.File{ .name = "tu.f", .text = "      PROGRAM TU\n      IMPLICIT NONE\n      INTEGER I\n\tI = 1 +\n\t1 JUNDEF\n\tPRINT *, I\n\tEND\n" };
    const w = try h.Workspace.init(&.{ tu, fake }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ fake.name ++ "\"}" });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, fake.name, .executable_file, .{});
    try w.open("tu.f", "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "has no IMPLICIT type", 60)) orelse return error.NoCompilerDiagnostics;
    const at = std.mem.find(u8, sent, "\"message\":\"Symbol 'jundef'").?;
    const mark = "\"range\":";
    const r = std.mem.findLast(u8, sent[0..at], mark) orelse return h.unmet("no range in {s}", .{sent});
    const want = "\"range\":{\"start\":{\"line\":4,\"character\":3},\"end\":{\"line\":4,\"character\":9}}";
    try h.expect(std.mem.startsWith(u8, sent[r..], want), "the range is not JUNDEF's: {s}", .{sent[r..at]});
}
