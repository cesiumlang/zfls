//! Refactorings: extracting statements into a procedure (#222).

const std = @import("std");
const h = @import("harness.zig");
const edits = @import("edits.zig");

const source =
    \\module stats
    \\  implicit none
    \\  integer, parameter :: dp = kind(1.d0)
    \\contains
    \\  subroutine summarize(x, n, total, mean, label)
    \\    integer, intent(in) :: n
    \\    real(dp), intent(in) :: x(n)
    \\    real(dp), intent(out) :: total, mean
    \\    character(len=*), intent(inout) :: label
    \\    integer :: i
    \\    real(dp) :: scale(0:3)
    \\    total = 0
    \\    do i = 1, n
    \\      total = total + x(i)
    \\    end do
    \\    mean = total / n
    \\    scale(0) = mean
    \\    label = 'done'
    \\  end subroutine summarize
    \\end module stats
    \\
    \\subroutine refusals(a, n)
    \\  implicit none
    \\  integer, intent(in) :: n
    \\  real, intent(inout) :: a(n)
    \\  integer :: i
    \\  do i = 1, n
    \\    if (a(i) < 0) exit
    \\    if (a(i) > 1) cycle
    \\    a(i) = 2 * a(i)
    \\  end do
    \\  if (n > 3) return
    \\  if (n > 2) go to 10
    \\  a(1) = 0
    \\10 continue
    \\  a(2) = 1
    \\end subroutine refusals
    \\
    \\program main
    \\  use stats, only: dp
    \\  implicit none
    \\  real(dp) :: v(3), t
    \\  v = 1
    \\  t = sum(v)
    \\  print *, t
    \\end program main
    \\
;

/// That extracting the lines from the one of `from` to the one of `to`
/// makes `source` into the text with each of `cut` replaced by what
/// follows it, which gfortran compiles
fn expectExtract(w: *h.Workspace, from: []const u8, to: []const u8, cut: []const [2][]const u8) !void {
    const a = std.testing.allocator;
    const first = w.pos("r.f90", from, 0, 0).line;
    const last = w.pos("r.f90", to, 0, 0).line;
    const got = (try edits.applyAction(w, "r.f90", first, last + 1, null, "Extract into subroutine extracted")) orelse
        return h.unmet("no extraction of {s} .. {s}", .{ from, to });
    var want: []const u8 = try a.dupe(u8, source);
    defer a.free(want);
    for (cut) |c| {
        const next = try std.mem.replaceOwned(u8, a, want, c[0], c[1]);
        a.free(want);
        want = next;
    }
    try h.expect(std.mem.eql(u8, got, want), "extracting {s} .. {s} gives\n{s}", .{ from, to, got });
    try edits.expectCompiles(w, &.{.{ .name = "r.f90", .text = got }});
}

/// That the lines from the one of `from` to the one of `to` are not
/// offered for extraction, and asked for as a refactoring, say why
fn expectRefused(w: *h.Workspace, from: []const u8, to: []const u8, why: []const u8) !void {
    const first = w.pos("r.f90", from, 0, 0).line;
    const last = w.pos("r.f90", to, 0, 0).line;
    if (try edits.applyAction(w, "r.f90", first, last + 1, null, "Extract into subroutine extracted")) |_|
        return h.unmet("extracts {s} .. {s}", .{ from, to });
    const reason = (try edits.disabledReason(w, "r.f90", first, last + 1, &.{"refactor"}, "Extract into subroutine")) orelse
        return h.unmet("no reason given for {s} .. {s}", .{ from, to });
    try h.expect(std.mem.find(u8, reason, why) != null, "{s} .. {s}: {s}", .{ from, to, reason });
}

fn expectExtractions(w: *h.Workspace) !void {
    // read (n, x), written then read (total, i)
    try expectExtract(w, "    total = 0", "    end do", &.{
        .{ "    total = 0\n    do i = 1, n\n      total = total + x(i)\n    end do\n", "    call extracted(total, i, n, x)\n" },
        .{
            "  end subroutine summarize\n",
            \\  contains
            \\    subroutine extracted(total, i, n, x)
            \\      real(dp), intent(inout) :: total
            \\      integer, intent(inout) :: i
            \\      integer, intent(in) :: n
            \\      real(dp), dimension(:), intent(in) :: x
            \\      total = 0
            \\      do i = 1, n
            \\        total = total + x(i)
            \\      end do
            \\    end subroutine extracted
            \\  end subroutine summarize
            \\
        },
    });
    // written only (mean)
    try expectExtract(w, "    mean = total", "    mean = total", &.{
        .{ "    mean = total / n\n", "    call extracted(mean, total, n)\n" },
        .{
            "  end subroutine summarize\n",
            \\  contains
            \\    subroutine extracted(mean, total, n)
            \\      real(dp), intent(out) :: mean
            \\      real(dp), intent(in) :: total
            \\      integer, intent(in) :: n
            \\      mean = total / n
            \\    end subroutine extracted
            \\  end subroutine summarize
            \\
        },
    });
    // assigned in part, keeping its lower bound (scale); a character of
    // assumed length
    try expectExtract(w, "    scale(0) = mean", "    label = 'done'", &.{
        .{ "    scale(0) = mean\n    label = 'done'\n", "    call extracted(scale, mean, label)\n" },
        .{
            "  end subroutine summarize\n",
            \\  contains
            \\    subroutine extracted(scale, mean, label)
            \\      real(dp), dimension(0:), intent(inout) :: scale
            \\      real(dp), intent(in) :: mean
            \\      character(len=*), intent(out) :: label
            \\      scale(0) = mean
            \\      label = 'done'
            \\    end subroutine extracted
            \\  end subroutine summarize
            \\
        },
    });
    // in a program, which gets a CONTAINS
    try expectExtract(w, "  t = sum(v)", "  print *, t", &.{
        .{ "  t = sum(v)\n  print *, t\n", "  call extracted(t, v)\n" },
        .{
            "end program main\n",
            \\contains
            \\  subroutine extracted(t, v)
            \\    real(dp), intent(inout) :: t
            \\    real(dp), dimension(:), intent(in) :: v
            \\    t = sum(v)
            \\    print *, t
            \\  end subroutine extracted
            \\end program main
            \\
        },
    });
    // an EXIT or CYCLE of the loop around them
    try expectRefused(w, "if (a(i) < 0) exit", "if (a(i) < 0) exit", "EXIT or CYCLE a loop around them");
    try expectRefused(w, "if (a(i) > 1) cycle", "a(i) = 2 * a(i)", "EXIT or CYCLE a loop around them");
    // a RETURN
    try expectRefused(w, "if (n > 3) return", "if (n > 3) return", "returns");
    // a GO TO out of them, a label jumped to from outside
    try expectRefused(w, "if (n > 2) go to 10", "a(1) = 0", "refer to label 10 outside them");
    try expectRefused(w, "10 continue", "a(2) = 1", "label 10 is jumped to from outside");
    // a part of a construct
    try expectRefused(w, "do i = 1, n\n    if (a(i) < 0)", "a(i) = 2 * a(i)", "whole constructs");
    // declarations: not offered
    const decl = w.pos("r.f90", "  integer :: i", 0, 0).line;
    for (try w.codeActionsOf("r.f90", decl, decl + 3, &.{"refactor"})) |act| {
        if (std.mem.startsWith(u8, act.title, "Extract")) return h.unmet("offers {s} on declarations", .{act.title});
    }
    // the whole loop is fine
    const first = w.pos("r.f90", "do i = 1, n\n    if (a(i) < 0)", 0, 0).line;
    for (try w.codeActionsOf("r.f90", first, first + 5, &.{"refactor"})) |act| {
        if (std.mem.eql(u8, act.title, "Extract into subroutine extracted")) return;
    }
    return h.unmet("the loop of refusals is not offered for extraction", .{});
}

test "#222 extract the selected statements into a procedure" {
    const w = try h.Workspace.init(&.{.{ .name = "r.f90", .text = source }}, .{ .disabled_actions = true });
    defer w.deinit();
    expectExtractions(w) catch |e| {
        std.debug.print("\n{s}\n", .{h.lastNote()});
        return e;
    };
}
