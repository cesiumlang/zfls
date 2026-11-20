//! Names that USE statements make visible: through modules that use others
//! in turn, and what those modules pass on.

const std = @import("std");
const h = @import("harness.zig");

const facade = [_]h.File{.{ .name = "a.f90", .text =
    \\module base
    \\  implicit none
    \\  integer :: shared_var, hidden_var
    \\contains
    \\  subroutine hidden_sub()
    \\  end subroutine
    \\end module
    \\module middle
    \\  use base
    \\  implicit none
    \\  private
    \\  public :: shared_var
    \\end module
    \\module hidden
    \\  use base
    \\  implicit none
    \\  private
    \\end module
    \\program main
    \\  use middle
    \\  implicit none
    \\  integer :: mine
    \\  shared_var = 1
    \\  hidden_var = 2
    \\  call hidden_sub()
    \\  mine = hid
    \\contains
    \\  subroutine inner()
    \\    integer :: hidden_var
    \\    hidden_var = 0
    \\  end subroutine
    \\end program
    \\subroutine other()
    \\  use hidden
    \\  implicit none
    \\  shared_var = 3
    \\end subroutine
    \\
}};

fn undeclared(w: *h.Workspace, file: []const u8, name: []const u8, line: i64) !bool {
    const want = try std.testing.allocator.print("Name \"{s}\" is not declared", .{name});
    defer std.testing.allocator.free(want);
    for (try w.diagnostics(file)) |d| {
        if (d.line == line and std.mem.startsWith(u8, d.message, want)) return true;
    }
    return false;
}

test "a module whose default is PRIVATE passes on only the used names it makes PUBLIC (#235)" {
    const w = try h.Workspace.init(&facade, .{});
    defer w.deinit();
    // through `middle`, `shared_var` and nothing else of `base`
    try w.expectHoverContains("a.f90", w.pos("a.f90", "shared_var = 1", 0, 0), "INTEGER :: shared_var");
    try std.testing.expect(try w.hover("a.f90", w.pos("a.f90", "hidden_var = 2", 0, 0)) == null);
    try std.testing.expect(try w.hover("a.f90", w.pos("a.f90", "hidden_sub()", 1, 0)) == null);
    try std.testing.expect(try undeclared(w, "a.f90", "hidden_var", 23));
    try std.testing.expect(!try undeclared(w, "a.f90", "shared_var", 22));
    // `hidden` passes on nothing
    try std.testing.expect(try w.hover("a.f90", w.pos("a.f90", "shared_var = 3", 0, 0)) == null);
    try std.testing.expect(try undeclared(w, "a.f90", "shared_var", 35));
    // a local declaration masks nothing of `base`
    for (try w.diagnostics("a.f90")) |d| try std.testing.expect(std.mem.find(u8, d.message, "masks") == null);
}

test "completion offers no used name that a PRIVATE module keeps (#235)" {
    const w = try h.Workspace.init(&facade, .{});
    defer w.deinit();
    for (try w.completionItems("a.f90", w.pos("a.f90", "= hid", 0, 5))) |item| {
        // offered with a USE of `base` added is another thing
        if (item.added != null) continue;
        try std.testing.expect(!std.mem.startsWith(u8, item.label, "hidden_"));
    }
}

test "a PRIVATE statement hides one used name; USE ONLY does not reach a hidden one (#235)" {
    const w = try h.Workspace.init(&.{.{ .name = "b.f90", .text =
        \\module base
        \\  implicit none
        \\  integer :: shared_var, hidden_var
        \\end module
        \\module middle
        \\  use base
        \\  implicit none
        \\  private :: hidden_var
        \\end module
        \\module closed
        \\  use base
        \\  implicit none
        \\  private
        \\end module
        \\program main
        \\  use middle
        \\  implicit none
        \\  shared_var = 1
        \\  hidden_var = 2
        \\end program
        \\subroutine s()
        \\  use closed, only: hidden_var
        \\  implicit none
        \\  hidden_var = 3
        \\end subroutine
        \\subroutine t()
        \\  use closed, only: hid
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("b.f90", w.pos("b.f90", "shared_var = 1", 0, 0), "INTEGER :: shared_var");
    try std.testing.expect(try w.hover("b.f90", w.pos("b.f90", "hidden_var = 2", 0, 0)) == null);
    try std.testing.expect(try w.hover("b.f90", w.pos("b.f90", "hidden_var = 3", 0, 0)) == null);
    for (try w.completion("b.f90", w.pos("b.f90", "only: hid", 0, 9))) |label| {
        try std.testing.expect(!std.mem.startsWith(u8, label, "hidden_"));
    }
}

const renamed = [_]h.File{
    .{ .name = "a.f90", .text =
    \\module base
    \\  implicit none
    \\  integer :: origin
    \\end module
    \\module user
    \\  use base, only: loc => origin
    \\  implicit none
    \\contains
    \\  subroutine s()
    \\    loc = 1
    \\    print *, loc
    \\  end subroutine
    \\end module
    \\module chain
    \\  use user, only: far => loc
    \\  implicit none
    \\contains
    \\  subroutine t()
    \\    far = 2
    \\  end subroutine
    \\end module
    \\module plain
    \\  use user
    \\contains
    \\  subroutine p()
    \\    loc = 3
    \\  end subroutine
    \\end module
    \\module other
    \\  use base, only: loc => origin
    \\contains
    \\  subroutine q()
    \\    loc = 4
    \\  end subroutine
    \\end module
    \\
    },
    .{ .name = "b.f90", .text =
    \\module mid_only
    \\  use base, only: m1 => origin
    \\end module
    \\module mid_all
    \\  use base, m2 => origin
    \\end module
    \\module t1
    \\  use mid_only, only: aa => m1
    \\contains
    \\  subroutine s()
    \\    aa = 1
    \\  end subroutine
    \\end module
    \\module t2
    \\  use mid_only, bb => m1
    \\contains
    \\  subroutine s()
    \\    bb = 1
    \\  end subroutine
    \\end module
    \\module t3
    \\  use mid_all, only: cc => m2
    \\contains
    \\  subroutine s()
    \\    cc = 1
    \\  end subroutine
    \\end module
    \\module t4
    \\  use mid_all, dd => m2
    \\contains
    \\  subroutine s()
    \\    dd = 1
    \\  end subroutine
    \\end module
    \\
    },
};

fn posLess(_: void, x: h.Pos, y: h.Pos) bool {
    return x.line < y.line or (x.line == y.line and x.col < y.col);
}

/// The places of `needles` (text, occurrence, column offset) in a.f90, sorted
fn placesOf(w: *h.Workspace, comptime needles: anytype) [needles.len]h.Pos {
    var out: [needles.len]h.Pos = undefined;
    inline for (needles, 0..) |n, i| out[i] = w.pos("a.f90", n[0], n[1], n[2]);
    std.mem.sort(h.Pos, &out, {}, posLess);
    return out;
}

/// The places in a.f90 of `locs`, sorted
fn sortedIn(w: *h.Workspace, locs: anytype) ![]const h.Pos {
    const uri = try w.uri("a.f90");
    var out: std.ArrayList(h.Pos) = .empty;
    for (locs) |l| {
        if (@hasField(@TypeOf(l), "uri") and !std.mem.eql(u8, l.uri, uri)) continue;
        try out.append(std.testing.allocator, if (@hasField(@TypeOf(l), "col")) .{ .line = l.line, .col = l.col } else .{ .line = l.line, .col = l.start });
    }
    const items = try out.toOwnedSlice(std.testing.allocator);
    std.mem.sort(h.Pos, items, {}, posLess);
    return items;
}

fn expectPlaces(want: []const h.Pos, got: []const h.Pos) !void {
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(h.Pos, want, got);
}

test "references on a USE-renamed name list its places under every name (#233)" {
    const w = try h.Workspace.init(&renamed, .{});
    defer w.deinit();
    const want = placesOf(w, .{
        .{ "integer :: origin", 0, 11 }, .{ "loc => origin", 0, 0 }, .{ "=> origin", 0, 3 },
        .{ "loc = 1", 0, 0 },            .{ "print *, loc", 0, 9 },  .{ "far => loc", 0, 0 },
        .{ "=> loc", 0, 3 },             .{ "far = 2", 0, 0 },       .{ "loc = 3", 0, 0 },
        .{ "loc => origin", 1, 0 },      .{ "=> origin", 1, 3 },     .{ "loc = 4", 0, 0 },
    });
    for ([_][]const u8{ "loc = 1", "integer :: origin", "far = 2" }) |at| {
        try expectPlaces(&want, try sortedIn(w, try w.references("a.f90", w.pos("a.f90", at, 0, if (at[0] == 'i') 11 else 0))));
    }
}

test "renaming a USE-renamed name follows it into the modules that use it (#233)" {
    const w = try h.Workspace.init(&renamed, .{});
    defer w.deinit();
    // not in `other`, which has a `loc` of its own
    try expectPlaces(&placesOf(w, .{
        .{ "loc => origin", 0, 0 }, .{ "loc = 1", 0, 0 }, .{ "print *, loc", 0, 9 }, .{ "=> loc", 0, 3 }, .{ "loc = 3", 0, 0 },
    }), try sortedIn(w, try w.rename("a.f90", w.pos("a.f90", "loc = 1", 0, 0), "zz")));
    // the original name keeps its places
    try expectPlaces(&placesOf(w, .{ .{ "integer :: origin", 0, 11 }, .{ "=> origin", 0, 3 }, .{ "=> origin", 1, 3 } }), try sortedIn(w, try w.rename("a.f90", w.pos("a.f90", "integer :: origin", 0, 11), "yy")));
}

test "a name renamed in two modules in a row resolves, with or without ONLY (#233)" {
    const w = try h.Workspace.init(&renamed, .{});
    defer w.deinit();
    for ([_][]const u8{ "aa = 1", "bb = 1", "cc = 1", "dd = 1" }) |at| {
        const p = w.pos("b.f90", at, 0, 0);
        try w.expectHoverContains("b.f90", p, "INTEGER :: origin");
        const d = (try w.definition("b.f90", p)) orelse return error.NoDefinition;
        try std.testing.expect(std.mem.endsWith(u8, d.uri, "a.f90") and d.line == 2);
    }
}

test "two modules that rename a name to the same local name (#233)" {
    const w = try h.Workspace.init(&.{.{ .name = "c.f90", .text =
        \\module a
        \\  integer :: x
        \\end module
        \\module b
        \\  use a, only: y => x
        \\end module
        \\module c
        \\  use a, y => x
        \\end module
        \\program p
        \\  use b
        \\  use c
        \\  implicit none
        \\  y = 1
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    const at = w.pos("c.f90", "y = 1", 0, 0);
    try w.expectHoverContains("c.f90", at, "INTEGER :: x");
    try std.testing.expect((try w.references("c.f90", at)).len >= 4);
    try std.testing.expect((try w.rename("c.f90", at, "z")).len >= 1);
}

test "ISO_FORTRAN_ENV and IEEE_ARITHMETIC names that gfortran has (#536)" {
    const w = try h.Workspace.init(&.{.{ .name = "i.f90", .text =
        \\program imods
        \\  use iso_fortran_env
        \\  use ieee_arithmetic
        \\  implicit none
        \\  type(event_type) :: ev[*]
        \\  type(team_type) :: tm
        \\  integer :: k(8)
        \\  type(ieee_round_type) :: rt
        \\  k = [real16, logical8, logical16, logical32, logical64, current_team, initial_team, parent_team]
        \\  rt = ieee_away
        \\  print *, k
        \\end program imods
        \\
    }}, .{});
    defer w.deinit();
    for (try w.diagnostics("i.f90")) |d| try h.expect(!std.mem.eql(u8, d.code, "undeclared-name"), "{s}", .{d.message});
    try w.expectHoverContains("i.f90", w.pos("i.f90", "event_type)", 0, 0), "event_type");
    try w.expectHoverContains("i.f90", w.pos("i.f90", "team_type)", 0, 0), "team_type");
    try w.expectHoverContains("i.f90", w.pos("i.f90", "real16", 0, 0), "INTEGER");
    try w.expectHoverContains("i.f90", w.pos("i.f90", "ieee_away", 0, 0), "TYPE(ieee_round_type)");
}
