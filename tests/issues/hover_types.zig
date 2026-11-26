//! Hover on derived types and on variables of them: what the type holds,
//! its components and type-bound procedures (#268); those of a
//! parameterized type (#723).

const std = @import("std");
const h = @import("harness.zig");

const particle = [_]h.File{
    .{ .name = "m.f90", .text =
    \\module m
    \\   implicit none
    \\   type :: base
    \\      integer :: tag
    \\   end type
    \\   !> A point that moves
    \\   type, extends(base) :: particle
    \\      real :: x, y
    \\      integer :: id
    \\      real, private :: secret
    \\   contains
    \\      procedure :: move
    \\      procedure, private :: hide => move
    \\      generic :: go => move
    \\   end type
    \\contains
    \\   subroutine move(self, p)
    \\      class(particle), intent(inout) :: self
    \\      type(particle), intent(in) :: p
    \\      self%x = p%x
    \\   end subroutine
    \\end module
    \\
    },
    .{ .name = "p.f90", .text =
    \\program prog
    \\   use m
    \\   implicit none
    \\   type(particle) :: q
    \\   real :: r
    \\   r = q%x
    \\end program
    \\
    },
};

const block =
    \\```fortran90
    \\TYPE, EXTENDS(base) :: particle
    \\  REAL :: x, y
    \\  INTEGER :: id
    \\  REAL, PRIVATE :: secret
    \\CONTAINS
    \\  PROCEDURE :: move
    \\  PROCEDURE, PRIVATE :: hide => move
    \\  GENERIC :: go => move
    \\END TYPE
    \\```
;

fn hoverOf(w: *h.Workspace, name: []const u8, needle: []const u8, plus: usize) ![]const u8 {
    return (try w.hover(name, w.pos(name, needle, 0, plus))) orelse error.NoHover;
}

test "hover on a variable of a derived type lists the type's components after its declaration (#268)" {
    const w = try h.Workspace.init(&particle, .{});
    defer w.deinit();
    const got = try hoverOf(w, "m.f90", "p%x", 0);
    const want = "```fortran90\nTYPE(particle), INTENT(IN) :: p\n```\n" ++ block;
    try std.testing.expectEqualStrings(want, got);
}

test "hover on a type name shows the type as it is written, with its documentation (#268)" {
    const w = try h.Workspace.init(&particle, .{});
    defer w.deinit();
    const got = try hoverOf(w, "m.f90", "type(particle)", 6);
    try std.testing.expectEqualStrings(block ++ "\n-----\nA point that moves", got);
    // the parent's own components only: EXTENDS names it
    const base = try hoverOf(w, "m.f90", "extends(base)", 9);
    try std.testing.expectEqualStrings("```fortran90\nTYPE :: base\n  INTEGER :: tag\nEND TYPE\n```", base);
}

test "outside the type's module its private components and bindings are left out (#268)" {
    const w = try h.Workspace.init(&particle, .{});
    defer w.deinit();
    const got = try hoverOf(w, "p.f90", "q%x", 0);
    try std.testing.expect(std.mem.find(u8, got, "  REAL :: x, y\n  INTEGER :: id\nCONTAINS\n  PROCEDURE :: move\n  GENERIC :: go => move\nEND TYPE") != null);
    try std.testing.expect(std.mem.find(u8, got, "secret") == null);
    try std.testing.expect(std.mem.find(u8, got, "hide") == null);
}

test "hover on a component or a variable of intrinsic type is unchanged (#268)" {
    const w = try h.Workspace.init(&particle, .{});
    defer w.deinit();
    try std.testing.expectEqualStrings("```fortran90\nREAL :: x\n```", try hoverOf(w, "m.f90", "p%x", 2));
    try std.testing.expectEqualStrings("```fortran90\nREAL :: r\n```", try hoverOf(w, "p.f90", "r = q", 0));
}

test "hover_no_type_components keeps the hover of a type and its variables short (#268)" {
    const w = try h.Workspace.init(&particle, .{ .settings = .{ .hover_no_type_components = true } });
    defer w.deinit();
    try std.testing.expectEqualStrings("```fortran90\nTYPE(particle), INTENT(IN) :: p\n```", try hoverOf(w, "m.f90", "p%x", 0));
    try std.testing.expectEqualStrings("```fortran90\nTYPE, EXTENDS(base) :: particle\n```\n-----\nA point that moves", try hoverOf(w, "m.f90", "type(particle)", 6));
}

test "a type with many components ends its block with ... ; one not found hovers as before (#268)" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "module big\n  type :: t\n");
    for (0..30) |i| try src.print(std.testing.allocator, "    integer :: c{d}\n", .{i});
    try src.appendSlice(std.testing.allocator, "  end type\ncontains\n  subroutine s(v, u)\n    type(t) :: v\n    type(unknown_t) :: u\n  end subroutine\nend module\n");
    const files = [_]h.File{.{ .name = "big.f90", .text = src.items }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const got = try hoverOf(w, "big.f90", "v, u", 0);
    try std.testing.expect(std.mem.endsWith(u8, got, "  INTEGER :: c19\n  ...\n```"));
    try std.testing.expect(std.mem.find(u8, got, "c20") == null);
    try std.testing.expectEqualStrings("```fortran90\nTYPE(unknown_t) :: u\n```", try hoverOf(w, "big.f90", "v, u", 3));
}

test "hover on a DEC record component in the middle of a chain (sh.centre.x) (#539)" {
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text =
        \\module decm
        \\  implicit none
        \\  structure /point/
        \\    real x, y
        \\  end structure
        \\  structure /shape/
        \\    real radius
        \\    record /point/ centre
        \\  end structure
        \\end module decm
        \\program decp
        \\  use decm
        \\  implicit none
        \\  record /shape/ sh
        \\  sh.centre.x = 0.5
        \\  sh.radius = sh.centre.y
        \\end program decp
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("d.f90");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "centre.x", 0, 2), "TYPE(point) :: centre");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "centre.y", 0, 2), "TYPE(point) :: centre");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "centre.x", 0, 7), "REAL :: x");
    const def = (try w.definition("d.f90", w.pos("d.f90", "centre.x", 0, 2))) orelse return h.unmet("no definition of centre", .{});
    try h.expect(def.line == 7, "centre defined on line {d}", .{def.line});
}

test "variables of a parameterized derived type have its components (#723)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m_pdt
        \\  implicit none
        \\  type :: box(n)
        \\    integer, len :: n
        \\    real :: v(n)
        \\  end type
        \\  type :: matrix(k, rows, cols)
        \\    integer, kind :: k = kind(1.0)
        \\    integer, len :: rows, cols
        \\    real(k) :: m(rows, cols)
        \\  end type
        \\  type, extends(matrix) :: named_matrix
        \\    character(len=rows) :: label
        \\  end type
        \\contains
        \\  subroutine fill(q)
        \\    type(matrix(kind(1.0d0), *, *)), intent(inout) :: q
        \\    q%m = 0
        \\  end subroutine
        \\  subroutine s()
        \\    type(box(3)) :: b
        \\    type(box(n=3)) :: c
        \\    type(matrix(8, :, :)), allocatable :: d
        \\    type(named_matrix(4, 2, 2)) :: e
        \\    b%v = 1
        \\    c%v = 1
        \\    allocate(matrix(8, 4, 4) :: d)
        \\    d%m = 0
        \\    e%label = 'ab'
        \\    print *, b%n, e%m
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "b%v", 0, 2), "REAL, DIMENSION(n) :: v");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "c%v", 0, 2), "REAL, DIMENSION(n) :: v");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "q%m", 0, 2), "REAL(k), DIMENSION(rows, cols) :: m");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "d%m", 0, 2), "REAL(k), DIMENSION(rows, cols) :: m");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "e%label", 0, 2), "label");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "e%m", 0, 2), "REAL(k)");
    const def = (try w.definition("t.f90", w.pos("t.f90", "c%v", 0, 2))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 4), def.line);
    const items = try w.completion("t.f90", w.pos("t.f90", "b%v", 0, 2));
    var found = false;
    for (items) |i| found = found or std.mem.eql(u8, i, "v");
    try h.expect(found, "b%: {any}", .{items});
}
