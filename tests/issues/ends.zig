//! END statements that do not fit the open scope, and scopes left open at
//! the end of a file (#285).

const std = @import("std");
const h = @import("harness.zig");

/// The diagnostics of a file with code `code`, as 0-based lines
fn linesWith(w: *h.Workspace, name: []const u8, code: []const u8) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, code)) try out.append(w.arena.allocator(), d.line);
    return out.items;
}

fn messageOf(w: *h.Workspace, name: []const u8, code: []const u8) ![]const u8 {
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, code)) return d.message;
    return "";
}

test "an END that does not fit the open construct: one error there, and the procedures after it stay apart (#285)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine s(a)
        \\  implicit none
        \\  integer :: a
        \\  if (a > 0) then
        \\    a = 1
        \\  end do
        \\end subroutine s
        \\subroutine t(a)
        \\  implicit none
        \\  integer :: a
        \\  a = 2
        \\end subroutine t
        \\
    }}, .{});
    defer w.deinit();
    const diags = try w.diagnostics("t.f90");
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("mismatched-end", diags[0].code);
    try std.testing.expectEqual(@as(i64, 5), diags[0].line);
    try std.testing.expectEqualStrings("END DO does not match the IF construct opened at line 4", diags[0].message);
}

test "an END of a scope further out closes the constructs inside it (#285)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine s(a)
        \\  integer :: a
        \\  do while (a > 0)
        \\    if (a > 1) then
        \\      a = a - 1
        \\end subroutine s
        \\subroutine t(a)
        \\  integer :: a
        \\  a = 2
        \\end subroutine t
        \\
    }}, .{});
    defer w.deinit();
    try std.testing.expectEqualSlices(i64, &.{5}, try linesWith(w, "t.f90", "mismatched-end"));
    try std.testing.expectEqualStrings("END SUBROUTINE does not match the IF construct opened at line 4", try messageOf(w, "t.f90", "mismatched-end"));
    try std.testing.expectEqualSlices(i64, &.{2}, try linesWith(w, "t.f90", "unclosed-scope"));
    try std.testing.expectEqual(@as(usize, 2), (try w.diagnostics("t.f90")).len);
}

test "scopes left open at the end of a file (#285)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module un
        \\  implicit none
        \\  integer :: top
        \\contains
        \\  subroutine open_sub(a)
        \\    integer :: a
        \\    if (a > 0) then
        \\      a = top
        \\
    }}, .{});
    defer w.deinit();
    try std.testing.expectEqualSlices(i64, &.{ 0, 4, 6 }, try linesWith(w, "t.f90", "unclosed-scope"));
    try std.testing.expectEqual(@as(usize, 3), (try w.diagnostics("t.f90")).len);
    var found = false;
    for (try w.diagnostics("t.f90")) |d| if (std.mem.eql(u8, d.message, "SUBROUTINE \"open_sub\" is not closed")) {
        found = true;
    };
    try std.testing.expect(found);
    // closing them takes the errors away
    try w.replaceText("t.f90",
        \\module un
        \\  implicit none
        \\  integer :: top
        \\contains
        \\  subroutine open_sub(a)
        \\    integer :: a
        \\    if (a > 0) then
        \\      a = top
        \\    end if
        \\  end subroutine
        \\end module
        \\
    );
    try w.expectNoDiagnostics("t.f90");
}

test "no END errors for the forms and constructs that close scopes (#285)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  subroutine s(a, x)
        \\    integer :: a, i, j
        \\    real :: x(3)
        \\    outer: do i = 1, 3
        \\      inner: do j = 1, 3
        \\        if (j > i) cycle outer
        \\      enddo inner
        \\    end do outer
        \\    if (a > 0) then
        \\      a = 1
        \\    elseif (a < 0) then
        \\      a = 2
        \\    endif
        \\    n1: if (a > 0) then
        \\    end if n1
        \\    sel: select case (a)
        \\    case (1) sel
        \\      a = 2
        \\    endselect sel
        \\    n6: where (x > 0)
        \\      x = 1
        \\    elsewhere n6
        \\      x = 2
        \\    end where n6
        \\    where (x > 0)
        \\      x = 1
        \\    endwhere
        \\    b: block
        \\      integer :: k
        \\      k = 1
        \\    end block b
        \\    as: associate (y => a)
        \\      y = 1
        \\    end associate as
        \\    do 10 i = 1, 3
        \\      do 10 j = 1, 3
        \\        a = a + 1
        \\10  continue
        \\  end subroutine s
        \\  function f(a) result(r)
        \\    integer, intent(in) :: a
        \\    integer :: r
        \\    r = a
        \\  endfunction
        \\end module m
        \\block data init
        \\  common /c/ q
        \\  integer :: q
        \\  data q /1/
        \\end block data init
        \\
        },
        .{ .name = "old.f", .text =
        \\      SUBROUTINE OLD(N)
        \\      INTEGER N, I
        \\      DO 10 I = 1, N
        \\        IF (I .GT. 5) THEN
        \\          N = N - 1
        \\        ENDIF
        \\   10 CONTINUE
        \\      END
        \\
        },
    }, .{});
    defer w.deinit();
    for ([_][]const u8{ "t.f90", "old.f" }) |name| {
        try std.testing.expectEqual(@as(usize, 0), (try linesWith(w, name, "mismatched-end")).len);
        try std.testing.expectEqual(@as(usize, 0), (try linesWith(w, name, "unclosed-scope")).len);
    }
}

test "no END errors for a header split by #ifdef, nor for an include file holding part of a procedure (#285)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "t.F90", .text =
        \\#ifdef WIDE
        \\subroutine s(a, b)
        \\  integer :: a, b
        \\#else
        \\subroutine s(a)
        \\  integer :: a
        \\#endif
        \\  a = 1
        \\  include "body.inc"
        \\end subroutine s
        \\
        },
        .{ .name = "plain.f90", .text =
        \\#ifdef WIDE
        \\subroutine s(a, b)
        \\#else
        \\subroutine s(a)
        \\#endif
        \\  integer :: a
        \\  a = 1
        \\end subroutine s
        \\
        },
        .{ .name = "body.inc", .text =
        \\  if (a > 0) then
        \\    a = 2
        \\  end if
        \\
        },
        .{ .name = "head.inc", .text =
        \\subroutine u(a)
        \\  integer :: a
        \\
        },
        .{ .name = "u.f90", .text =
        \\include "head.inc"
        \\  a = 1
        \\end subroutine u
        \\
        },
    }, .{});
    defer w.deinit();
    for ([_][]const u8{ "t.F90", "plain.f90", "head.inc", "u.f90" }) |name| {
        try std.testing.expectEqual(@as(usize, 0), (try linesWith(w, name, "mismatched-end")).len);
        try std.testing.expectEqual(@as(usize, 0), (try linesWith(w, name, "unclosed-scope")).len);
    }
}
