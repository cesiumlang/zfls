//! `hover_signature` (#281): hover on an actual argument shows the dummy
//! argument it is passed to.

const std = @import("std");
const h = @import("harness.zig");

const source = [_]h.File{.{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  type :: t
    \\  contains
    \\    procedure :: scale
    \\  end type
    \\  interface pick
    \\    module procedure pick_int, pick_real
    \\  end interface
    \\contains
    \\  !> Adds things
    \\  subroutine addit(first, second)
    \\    integer, intent(in) :: first  !< the first
    \\    integer, intent(out) :: second
    \\    second = first
    \\  end subroutine
    \\  subroutine scale(self, factor)
    \\    class(t), intent(inout) :: self
    \\    real, intent(in) :: factor !< how much
    \\  end subroutine
    \\  subroutine pick_int(i)
    \\    integer, intent(in) :: i
    \\  end subroutine
    \\  subroutine pick_real(r, extra)
    \\    real, intent(in) :: r
    \\    real, intent(in) :: extra
    \\  end subroutine
    \\  integer function g(y)
    \\    integer, intent(in) :: y !< g's own
    \\    g = y
    \\  end function
    \\  integer function f(z)
    \\    integer, intent(in) :: z
    \\    f = z
    \\  end function
    \\  subroutine u()
    \\    integer :: k, x, n
    \\    type(t) :: obj
    \\    real :: w
    \\    call addit(1, k)
    \\    call addit(second=k, first=1)
    \\    call obj%scale(w)
    \\    call pick(w, w)
    \\    n = f(g(x))
    \\    n = abs(x)
    \\  end subroutine
    \\end module m
    \\
}};

fn hoverOf(w: *h.Workspace, needle: []const u8, plus: usize) ![]const u8 {
    return (try w.hover("m.f90", w.pos("m.f90", needle, 0, plus))) orelse error.NoHover;
}

fn expectDummy(w: *h.Workspace, needle: []const u8, plus: usize, want: []const u8) !void {
    const got = try hoverOf(w, needle, plus);
    const at = std.mem.find(u8, got, "\n\n-----\nArgument of ") orelse {
        std.debug.print("no dummy in the hover at {s}+{d}: {s}\n", .{ needle, plus, got });
        return error.NoDummy;
    };
    try std.testing.expectEqualStrings(want, got[at + 8 ..]);
}

test "with hover_signature, hover on an actual argument adds the dummy it is passed to (#281)" {
    const w = try h.Workspace.init(&source, .{ .settings = .{ .hover_signature = true } });
    defer w.deinit();
    // a literal: its type, then the dummy
    const lit = try hoverOf(w, "addit(1, k)", 6);
    try std.testing.expect(std.mem.startsWith(u8, lit, "```fortran90\nINTEGER\n```\n-----\nLiteral constant\n\n-----\n"));
    try expectDummy(w, "addit(1, k)", 6, "Argument of `addit(first, second)`:\n```fortran90\nINTEGER, INTENT(IN) :: first\n```\n-----\nthe first");
    // a variable: its declaration, then the dummy
    const k = try hoverOf(w, "addit(1, k)", 9);
    try std.testing.expect(std.mem.startsWith(u8, k, "```fortran90\nINTEGER :: k\n```\n\n-----\n"));
    try expectDummy(w, "addit(1, k)", 9, "Argument of `addit(first, second)`:\n```fortran90\nINTEGER, INTENT(OUT) :: second\n```");
}

test "hover_signature follows keywords, type-bound and generic calls and the innermost call (#281)" {
    const w = try h.Workspace.init(&source, .{ .settings = .{ .hover_signature = true } });
    defer w.deinit();
    const second = "Argument of `addit(first, second)`:\n```fortran90\nINTEGER, INTENT(OUT) :: second\n```";
    try expectDummy(w, "second=k, first", 7, second);
    // the keyword itself
    try expectDummy(w, "second=k, first", 2, second);
    try expectDummy(w, "first=1)", 6, "Argument of `addit(first, second)`:\n```fortran90\nINTEGER, INTENT(IN) :: first\n```\n-----\nthe first");
    // past the passed-object argument
    try expectDummy(w, "scale(w)", 6, "Argument of `scale(factor)`:\n```fortran90\nREAL, INTENT(IN) :: factor\n```\n-----\nhow much");
    // the specific the two arguments fit
    try expectDummy(w, "pick(w, w)", 5, "Argument of `pick_real(r, extra)`:\n```fortran90\nREAL, INTENT(IN) :: r\n```");
    try expectDummy(w, "pick(w, w)", 8, "Argument of `pick_real(r, extra)`:\n```fortran90\nREAL, INTENT(IN) :: extra\n```");
    // x is passed to g, g(x) to f
    try expectDummy(w, "f(g(x))", 4, "Argument of `g(y)`:\n```fortran90\nINTEGER, INTENT(IN) :: y\n```\n-----\ng's own");
    try expectDummy(w, "f(g(x))", 2, "Argument of `f(z)`:\n```fortran90\nINTEGER, INTENT(IN) :: z\n```");
}

test "hover_signature adds nothing on the procedure's name, for an intrinsic, or when off (#281)" {
    {
        const w = try h.Workspace.init(&source, .{ .settings = .{ .hover_signature = true } });
        defer w.deinit();
        try std.testing.expect(std.mem.find(u8, try hoverOf(w, "addit(1, k)", 1), "Argument of") == null);
        try std.testing.expect(std.mem.find(u8, try hoverOf(w, "abs(x)", 4), "Argument of") == null);
    }
    const w = try h.Workspace.init(&source, .{});
    defer w.deinit();
    try std.testing.expectEqualStrings("```fortran90\nINTEGER :: k\n```", try hoverOf(w, "addit(1, k)", 9));
    try std.testing.expectEqualStrings("```fortran90\nINTEGER\n```\n-----\nLiteral constant", try hoverOf(w, "addit(1, k)", 6));
}
