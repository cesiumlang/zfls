//! DEC's I/O statements, which ifx accepts: ENCODE, DECODE, ACCEPT, DEFINE
//! FILE, FIND and the record mark of `READ (u'r)` (#504; the ifx audit,
//! #489). gfortran (`-fdec`) has TYPE only, LLVM Flang none of them.

const std = @import("std");
const h = @import("harness.zig");

test "ENCODE, DECODE, ACCEPT, DEFINE FILE and FIND name no variables" {
    // ifx: exit 0
    const w = try h.Workspace.init(&.{.{ .name = "io.f", .text =
        \\      PROGRAM IO
        \\      IMPLICIT NONE
        \\      INTEGER I, J, N, IOS
        \\      REAL A(10), V
        \\      CHARACTER*40 LINE
        \\      I = 1
        \\      J = 2
        \\      ENCODE (40, 10, LINE) I, J
        \\   10 FORMAT (2I5)
        \\      DECODE (40, 10, LINE) N, J
        \\      TYPE *, 'type to terminal', N
        \\      ACCEPT *, V
        \\      DEFINE FILE 3 (100, 10, U, IOS)
        \\      READ (3'5) A(1)
        \\      FIND (3'7)
        \\      PRINT *, A(1), V
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("io.f");
}

test "the names after a record mark (READ (u'r)) are read, not a character literal" {
    // ifx: `error #6404 ... [UNDECL]` only
    const w = try h.Workspace.init(&.{.{ .name = "r.f90", .text =
        \\program rec
        \\  implicit none
        \\  integer :: irec
        \\  real :: a(10)
        \\  irec = 5
        \\  read (3'irec) a(1), undecl
        \\  write (3'irec + 1) a(2)
        \\  find (3'irec)
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    var undeclared: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics("r.f90")) |d| if (std.mem.eql(u8, d.code, "undeclared-name")) try undeclared.append(w.a(), d.message);
    try std.testing.expectEqual(1, undeclared.items.len);
    try std.testing.expect(std.mem.find(u8, undeclared.items[0], "\"undecl\"") != null);
    try w.expectHoverContains("r.f90", w.pos("r.f90", "a(2)", 0, 0), "REAL");
}
