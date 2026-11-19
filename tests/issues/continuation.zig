//! Statements continued over several lines with comment lines, blank lines
//! or preprocessor directives between them (#259).

const std = @import("std");
const h = @import("harness.zig");
const PpDef = @import("zfls").settings.PpDef;

const foo =
    \\contains
    \\  subroutine foo(x, y, z)
    \\    integer :: x, y, z
    \\    print *, x, y, z
    \\  end subroutine foo
    \\end program hello
    \\
;

const free = [_]h.File{.{ .name = "t.f90", .text =
    \\program hello
    \\  implicit none
    \\  integer :: a, b, d
    \\  call foo(a, &
    \\    b, &
    \\    ! a comment between continuation lines
    \\    d)
    \\  call foo(a, &
    \\    b, &
    \\    d)
    \\  call foo(a, &
    \\
    \\    b, d)
    \\  call foo(a, &
    \\    ! one comment
    \\
    \\    ! and another
    \\    b, &
    \\    d)
    \\  call foo(a, &
    \\
    \\    b, y
    \\
++ foo }};

/// Signature help on the `nth` occurrence of `needle`, `plus` characters
/// into it: `foo(x, y, z)` with parameter `active`
fn expectSignature(w: *h.Workspace, name: []const u8, needle: []const u8, nth: usize, plus: usize, active: i64) !void {
    const s = (try w.signature(name, w.pos(name, needle, nth, plus))) orelse
        return h.unmet("no signature help on '{s}' ({d})", .{ needle, nth });
    try h.expect(std.mem.eql(u8, s.label, "foo(x, y, z)") and s.active == active, "'{s}' ({d}): {s}, parameter {d}", .{ needle, nth, s.label, s.active });
}

/// `result`, printing why it is unmet
fn noted(result: anyerror!void) !void {
    result catch |e| {
        std.debug.print("\n{s}\n", .{h.lastNote()});
        return e;
    };
}

fn expectFree(w: *h.Workspace) !void {
    // the same call with and without a comment line
    try expectSignature(w, "t.f90", "    d)", 0, 4, 2);
    try expectSignature(w, "t.f90", "    d)", 1, 4, 2);
    // a blank line
    try expectSignature(w, "t.f90", "    b, d)", 0, 4, 1);
    // comment, blank and comment lines
    try expectSignature(w, "t.f90", "    d)", 2, 4, 2);
    // completion sees the call too: its keyword arguments
    const items = try w.completion("t.f90", w.pos("t.f90", "    b, y", 0, 8));
    for (items) |i| if (std.mem.eql(u8, i, "y=")) return;
    return h.unmet("no completion y= after a blank line: {any}", .{items});
}

test "free form: comment and blank lines between continuation lines (#259)" {
    const w = try h.Workspace.init(&free, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 923, .fixed, expectFree(w));
}

const fixed = [_]h.File{.{ .name = "t.f", .text =
    \\      program hello
    \\      implicit none
    \\      integer a, b, d,
    \\c a comment between the lines of a declaration
    \\     & e
    \\      integer m
    \\c a comment after a statement
    \\      integer n
    \\      call foo(a,
    \\     & b,
    \\c I don't like this comment
    \\     & d)
    \\      call foo(a,
    \\     & b,
    \\     & d)
    \\      e = m + n
    \\      contains
    \\      subroutine foo(x,
    \\* the second argument
    \\
    \\     & y, z)
    \\      integer x, y, z
    \\      print *, x, y, z
    \\      end subroutine foo
    \\      end program hello
    \\
}};

test "fixed form: comment and blank lines between continuation lines (#259)" {
    const w = try h.Workspace.init(&fixed, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f");
    // backward: the call from its last line, with and without the comment
    try noted(expectSignature(w, "t.f", "     & d)", 0, 7, 2));
    try noted(expectSignature(w, "t.f", "     & d)", 1, 7, 2));
    // forward: the declaration and the subroutine statement read whole
    try w.expectHoverContains("t.f", w.pos("t.f", "e = m", 0, 0), "INTEGER");
    const def = (try w.definition("t.f", w.pos("t.f", "e = m", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 4), def.line);
    // a comment after a statement does not join it to the next one
    try w.expectHoverContains("t.f", w.pos("t.f", "m + n", 0, 0), "INTEGER");
    try w.expectHoverContains("t.f", w.pos("t.f", "m + n", 0, 4), "INTEGER");
}

test "preprocessor directives between continuation lines (#259)" {
    const files = [_]h.File{.{ .name = "t.F90", .text =
        \\program hello
        \\  implicit none
        \\  integer :: a, b, d
        \\  call foo(a, &
        \\#ifdef X
        \\    b, &
        \\#endif
        \\    d)
        \\
    ++ foo }};
    // the line of an inactive branch is not part of the call
    for ([_]struct { defs: []const PpDef, active: i64 }{
        .{ .defs = &.{.{ .name = "X", .value = "" }}, .active = 2 },
        .{ .defs = &.{}, .active = 1 },
    }) |c| {
        const w = try h.Workspace.init(&files, .{ .pp_defs = c.defs });
        defer w.deinit();
        try w.expectNoDiagnostics("t.F90");
        try noted(expectSignature(w, "t.F90", "    d)", 0, 4, c.active));
    }
}
