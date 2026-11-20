//! Generic interfaces across scopes: a generic is the union of its own
//! interface blocks and those of its name that it has by USE or from its
//! host (#478).

const std = @import("std");
const h = @import("harness.zig");

const base = h.File{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  interface f
    \\    subroutine f1(x)
    \\      integer, intent(in) :: x
    \\    end subroutine
    \\  end interface
    \\  interface f
    \\    subroutine f5(r)
    \\      real, intent(in) :: r
    \\    end subroutine
    \\  end interface
    \\end module
    \\
};

const extended = h.File{ .name = "m2.f90", .text =
    \\module m2
    \\  use m
    \\  implicit none
    \\  interface f
    \\    module procedure f3
    \\  end interface
    \\contains
    \\  subroutine f3(c)
    \\    character(*), intent(in) :: c
    \\  end subroutine
    \\  subroutine inner()
    \\    interface f
    \\      subroutine f4(z)
    \\        logical, intent(in) :: z
    \\      end subroutine
    \\    end interface
    \\    call f(.true.)
    \\    call f('x')
    \\    call f(3)
    \\  end subroutine
    \\end module
    \\
};

const user = h.File{ .name = "u.f90", .text =
    \\program p
    \\  use m2
    \\  implicit none
    \\  call f(1)
    \\  call f('a')
    \\  call f(2.5)
    \\end program
    \\
};

/// That go to definition at `plus` characters into the first `needle` of
/// `name` goes to line `want` (1-based) of `in`
fn expectDef(w: *h.Workspace, name: []const u8, needle: []const u8, plus: usize, in: []const u8, want: i64) !void {
    const d = (try w.definition(name, w.pos(name, needle, 0, plus))) orelse return h.unmet("no definition of {s}", .{needle});
    try h.expect(std.mem.endsWith(u8, d.uri, in) and d.line + 1 == want, "{s} goes to {s}:{d}, not {s}:{d}", .{ needle, d.uri, d.line + 1, in, want });
}

/// That hover at `plus` characters into the first `needle` of `name` shows
/// each of `want` and none of `not`
fn expectHover(w: *h.Workspace, name: []const u8, needle: []const u8, plus: usize, want: []const []const u8, not: []const []const u8) !void {
    const got = (try w.hover(name, w.pos(name, needle, 0, plus))) orelse return h.unmet("no hover on {s}", .{needle});
    for (want) |s| try h.expect(std.mem.find(u8, got, s) != null, "hover on {s} without {s}: {s}", .{ needle, s, got });
    for (not) |s| try h.expect(std.mem.find(u8, got, s) == null, "hover on {s} with {s}: {s}", .{ needle, s, got });
}

/// The number of the locations in `locs` in file `name`
fn countIn(locs: []const h.Location, name: []const u8) usize {
    var n: usize = 0;
    for (locs) |l| if (std.mem.endsWith(u8, l.uri, name)) {
        n += 1;
    };
    return n;
}

test "a generic extended in a module that uses another one with the generic, or in a contained procedure, has the specifics of both (#478)" {
    const w = try h.Workspace.init(&.{ base, extended, user }, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    // a call: the specific of its arguments, of either interface block
    try expectHover(w, "u.f90", "f(1)", 0, &.{"SUBROUTINE f1(x)"}, &.{"f3"});
    try expectHover(w, "u.f90", "f('a')", 0, &.{"SUBROUTINE f3(c)"}, &.{"f1"});
    try expectDef(w, "u.f90", "f(1)", 0, "m.f90", 4);
    try expectDef(w, "u.f90", "f('a')", 0, "m2.f90", 8);
    // and of the other interface block of the name in the used module
    try expectHover(w, "u.f90", "f(2.5)", 0, &.{"SUBROUTINE f5(r)"}, &.{ "f1", "f3" });
    try expectDef(w, "u.f90", "f(2.5)", 0, "m.f90", 9);
    // the generic of m2: both specifics, own first
    try expectHover(w, "m2.f90", "interface f", 10, &.{ "SUBROUTINE f3(c)", "SUBROUTINE f1(x)", "SUBROUTINE f5(r)" }, &.{"f4"});
    const sig = (try w.signature("u.f90", w.pos("u.f90", "f(1)", 0, 3))) orelse return h.unmet("no signature help on f(1)", .{});
    try h.expect(sig.count == 3 and std.mem.startsWith(u8, sig.label, "f1("), "signature help on f(1): {d}, {s}", .{ sig.count, sig.label });
    // that of the module it uses: its two blocks'
    try expectHover(w, "m.f90", "interface f", 10, &.{ "SUBROUTINE f1(x)", "SUBROUTINE f5(r)" }, &.{ "f3", "f4" });
    // a generic of a contained procedure extends the host's
    try expectHover(w, "m2.f90", "f(.true.)", 0, &.{"SUBROUTINE f4(z)"}, &.{ "f1", "f3" });
    try expectDef(w, "m2.f90", "f('x')", 0, "m2.f90", 8);
    try expectDef(w, "m2.f90", "f(3)", 0, "m.f90", 4);
    // references: the generic names of both modules and the calls, from
    // any of them
    for ([_]struct { []const u8, []const u8, usize, usize }{
        .{ "u.f90", "f(1)", 0, 0 },
        .{ "m2.f90", "interface f", 0, 10 },
        .{ "m2.f90", "interface f", 1, 10 },
        .{ "m.f90", "interface f", 0, 10 },
        .{ "m.f90", "interface f", 1, 10 },
    }) |at| {
        const refs = try w.references(at[0], w.pos(at[0], at[1], at[2], at[3]));
        try h.expect(countIn(refs, "m.f90") == 2 and countIn(refs, "u.f90") == 3 and countIn(refs, "m2.f90") == 5, "references of f from {s}: {d} in m.f90, {d} in m2.f90, {d} in u.f90", .{ at[1], countIn(refs, "m.f90"), countIn(refs, "m2.f90"), countIn(refs, "u.f90") });
    }
    for ([_][]const u8{ "m.f90", "m2.f90", "u.f90" }) |name| try w.expectNoDiagnostics(name);
}
