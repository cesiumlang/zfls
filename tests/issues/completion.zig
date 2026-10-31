//! Upstream issues about completion.

const std = @import("std");
const h = @import("harness.zig");

const calls = [_]h.File{.{ .name = "t.f90", .text =
    \\module geometry
    \\  implicit none
    \\  type :: point
    \\    real :: x, y
    \\  contains
    \\    procedure :: shift
    \\  end type point
    \\  interface area
    \\    module procedure area_circle, area_rect
    \\  end interface area
    \\contains
    \\  subroutine move(p, dx, dy, scale)
    \\    type(point), intent(inout) :: p
    \\    real, intent(in) :: dx, dy
    \\    real, intent(in), optional :: scale
    \\  end subroutine move
    \\  subroutine shift(self, by)
    \\    class(point), intent(inout) :: self
    \\    real, intent(in) :: by
    \\  end subroutine shift
    \\  real function area_circle(radius)
    \\    real, intent(in) :: radius
    \\    area_circle = 3.14159 * radius**2
    \\  end function area_circle
    \\  real function area_rect(width, height)
    \\    real, intent(in) :: width, height
    \\    area_rect = width * height
    \\  end function area_rect
    \\end module geometry
    \\program main
    \\  use geometry
    \\  type(point) :: q
    \\  real :: dist
    \\  call move(q, d
    \\  call move(q, dx=1.0, d
    \\  call move(q, 1.0 + d
    \\  call q%shift(b
    \\  print *, area(r
    \\  print *, area(w
    \\  q = point(x
    \\  print *, size(q, d
    \\end program main
    \\
}};

fn has(items: []const []const u8, label: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i, label)) return true;
    return false;
}

fn expectKeywordArguments(w: *h.Workspace) !void {
    // the arguments of `move` starting with d, and the variables
    var items = try w.completion("t.f90", w.pos("t.f90", "call move(q, d", 0, 14));
    try h.expect(has(items, "dx=") and has(items, "dy="), "move(q, d: {any}", .{items});
    try h.expect(has(items, "dist"), "variables are still offered: {any}", .{items});
    try h.expect(std.mem.eql(u8, items[0], "dx="), "keywords come first: {any}", .{items});
    // a keyword given already is not offered again
    items = try w.completion("t.f90", w.pos("t.f90", "dx=1.0, d", 0, 9));
    try h.expect(has(items, "dy=") and !has(items, "dx="), "move(q, dx=1.0, d: {any}", .{items});
    // only where the argument is a bare name
    items = try w.completion("t.f90", w.pos("t.f90", "1.0 + d", 0, 7));
    try h.expect(!has(items, "dx="), "in an expression: {any}", .{items});
    // a type-bound procedure, without its passed object
    items = try w.completion("t.f90", w.pos("t.f90", "q%shift(b", 0, 9));
    try h.expect(has(items, "by="), "q%shift(b: {any}", .{items});
    // the procedures of a generic interface
    items = try w.completion("t.f90", w.pos("t.f90", "area(r", 0, 6));
    try h.expect(has(items, "radius="), "area(r: {any}", .{items});
    items = try w.completion("t.f90", w.pos("t.f90", "area(w", 0, 6));
    try h.expect(has(items, "width="), "area(w: {any}", .{items});
    // the components of a type, in its structure constructor
    items = try w.completion("t.f90", w.pos("t.f90", "point(x", 0, 7));
    try h.expect(has(items, "x="), "point(x: {any}", .{items});
    // an intrinsic procedure
    items = try w.completion("t.f90", w.pos("t.f90", "size(q, d", 0, 9));
    try h.expect(has(items, "dim=") or has(items, "DIM="), "size(q, d: {any}", .{items});
}

test "hansec #133 completion of keyword arguments inside a call" {
    const w = try h.Workspace.init(&calls, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 133, .fixed, expectKeywordArguments(w));
}

const modules = [_]h.File{
    .{ .name = "consts.f90", .text =
    \\module consts
    \\  implicit none
    \\  private
    \\  real, parameter, public :: gravity = 9.81
    \\  real, parameter :: hidden_value = 1.0
    \\  public :: grid_t, grid_size
    \\  type :: grid_t
    \\    integer :: n
    \\  end type grid_t
    \\contains
    \\  integer function grid_size(g)
    \\    type(grid_t), intent(in) :: g
    \\    grid_size = g%n
    \\  end function grid_size
    \\end module consts
    \\
    },
    .{ .name = "sim.f90", .text =
    \\module sim
    \\  use iso_fortran_env, only: real64
    \\  implicit none
    \\contains
    \\  subroutine step(dt)
    \\    real, intent(in) :: dt
    \\    real :: v
    \\    v = grav
    \\    v = hidd
    \\    v = gr
    \\  end subroutine step
    \\  subroutine draw()
    \\    type(grid_t) :: g
    \\  end subroutine draw
    \\end module sim
    \\
    },
};

fn find(items: []const h.Workspace.Item, label: []const u8) ?h.Workspace.Item {
    for (items) |i| if (std.mem.eql(u8, i.label, label)) return i;
    return null;
}

fn expectAutoUse(w: *h.Workspace) !void {
    // a public name of a module the procedure does not use, with its USE
    // statement after the procedure's first line
    const step_line = w.pos("sim.f90", "subroutine step", 0, 0).line;
    var items = try w.completionItems("sim.f90", w.pos("sim.f90", "v = grav", 0, 8));
    const g = find(items, "gravity") orelse return h.unmet("gravity not offered: {any}", .{items});
    try h.expect(g.added != null and std.mem.eql(u8, g.added.?, "    use consts, only: gravity\n") and g.added_line == step_line + 1, "gravity adds {?s} before line {d}", .{ g.added, g.added_line });
    try h.expect(std.mem.indexOf(u8, g.detail, "(use consts)") != null, "detail: {s}", .{g.detail});
    // not a private one
    items = try w.completionItems("sim.f90", w.pos("sim.f90", "v = hidd", 0, 8));
    try h.expect(find(items, "hidden_value") == null, "a private name is offered", .{});
    // procedures and types too, from intrinsic modules as well
    items = try w.completionItems("sim.f90", w.pos("sim.f90", "v = gr", 0, 6));
    try h.expect(find(items, "grid_size") != null, "grid_size not offered: {any}", .{items});
    // a quick fix for a type that is not found
    const decl = w.pos("sim.f90", "type(grid_t)", 0, 0).line;
    const actions = try w.codeActions("sim.f90", decl);
    for (actions) |act| {
        if (std.mem.eql(u8, act.title, "Add use consts, only: grid_t")) {
            try h.expect(std.mem.eql(u8, act.new_text, "    use consts, only: grid_t\n") and act.line == decl, "the quick fix inserts {s} before line {d}", .{ act.new_text, act.line });
            return;
        }
    }
    return h.unmet("no quick fix: {any}", .{actions});
}

test "hansec #62 names of modules not used yet: completion adds the USE statement; a quick fix for a type not found" {
    const w = try h.Workspace.init(&modules, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 62, .fixed, expectAutoUse(w));
}

test "autocomplete_no_auto_use offers only the names in scope" {
    const w = try h.Workspace.init(&modules, .{ .settings = .{ .autocomplete_no_auto_use = true } });
    defer w.deinit();
    const items = try w.completionItems("sim.f90", w.pos("sim.f90", "v = grav", 0, 8));
    try std.testing.expect(find(items, "gravity") == null);
}

test "an intrinsic module's names are offered with their USE statement, after the last USE" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text =
        \\program p
        \\  use iso_fortran_env, only: real64
        \\  implicit none
        \\  print *, output_u
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    const items = try w.completionItems("p.f90", w.pos("p.f90", "output_u", 0, 8));
    const o = find(items, "output_unit") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("  use iso_fortran_env, only: output_unit\n", o.added.?);
    try std.testing.expectEqual(@as(i64, 2), o.added_line);
}
