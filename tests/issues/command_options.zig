//! A file read as its command in compile_commands.json says (#542): its
//! source form, fixed-form line length (gfortran's 72 by default), debug
//! lines and `-fimplicit-none`. No compiler runs.

const std = @import("std");
const h = @import("harness.zig");

const database = h.File{ .name = "compile_commands.json", .text =
    \\[{"directory": ".", "file": "fixedf90.f90", "command": "gfortran -ffixed-form -c fixedf90.f90"},
    \\ {"directory": ".", "file": "long.f", "command": "gfortran -c long.f"},
    \\ {"directory": ".", "file": "dl.f", "command": "gfortran -fd-lines-as-code -c dl.f"},
    \\ {"directory": ".", "file": "impl.f90", "command": "gfortran -fimplicit-none -c impl.f90"}]
    \\
};
const fixedf90 = h.File{ .name = "fixedf90.f90", .text = "C     fixed form with an .f90 suffix\n      PROGRAM FX\n      IMPLICIT NONE\n      INTEGER I\n      I = 1\n      END\n" };
const long = h.File{ .name = "long.f", .text = "      PROGRAM LONG\n      IMPLICIT NONE\n      INTEGER I\n      I = 1                                                             + IGNORED_TAIL\n      END\n" };
const dl = h.File{ .name = "dl.f", .text = "      PROGRAM DL\n      IMPLICIT NONE\n      INTEGER I\n      I = 1\nD     PRINT *, DEBUG_ONLY\n      END\n" };
const impl = h.File{ .name = "impl.f90", .text = "program impl\n  x = 1.0\n  print *, x\nend program impl\n" };

fn mentions(ds: []const h.Diagnostic, text: []const u8) bool {
    for (ds) |d| if (std.ascii.findIgnoreCase(d.message, text) != null) return true;
    return false;
}

test "the form, line length, debug lines and implicit none of the file's command (#542)" {
    const w = try h.Workspace.init(&.{ database, fixedf90, long, dl, impl }, .{});
    defer w.deinit();
    // -ffixed-form: fixed form, whatever the suffix
    try h.expect(try w.isFixed("fixedf90.f90"), "fixedf90.f90 is not read as fixed form", .{});
    // gfortran's 72 columns: what is after them is no code
    try h.expect(!mentions(try w.diagnostics("long.f"), "IGNORED_TAIL"), "long.f is read past column 72", .{});
    // -fd-lines-as-code: the D line is code, whose name is not declared
    try h.expect(mentions(try w.diagnostics("dl.f"), "DEBUG_ONLY"), "the D line of dl.f is not read as code", .{});
    // -fimplicit-none: x is not declared
    try h.expect(mentions(try w.diagnostics("impl.f90"), "\"x\""), "impl.f90 is not read with implicit none", .{});
}
