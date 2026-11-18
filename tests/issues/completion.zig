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
    try h.expect(std.mem.find(u8, g.detail, "(use consts)") != null, "detail: {s}", .{g.detail});
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

const features = [_]h.File{.{ .name = "test.f90", .text =
    \\module mod
    \\implicit none
    \\private
    \\type :: feature_base
    \\end type feature_base
    \\type, extends(feature_base) :: feature_ext
    \\end type feature_ext
    \\type, extends(feature_ext) :: feature_all
    \\end type feature_all
    \\contains
    \\   subroutine xxx(x)
    \\      class(feature_all) :: x
    \\      x%feat
    \\   end subroutine xxx
    \\end module mod
    \\
}};

test "hansec #121 completion of a component offers the parent components of an extended type" {
    const w = try h.Workspace.init(&features, .{});
    defer w.deinit();
    const items = try w.completion("test.f90", w.pos("test.f90", "x%feat", 0, 6));
    const outcome: anyerror!void = if (has(items, "feature_base") and has(items, "feature_ext") and !has(items, "feature_all")) {} else h.unmet("x%feat: {any}", .{items});
    try h.checkIn(.hansec, 121, .fixed, outcome);
}

test "type hierarchy: the type a type extends, and the types that extend it" {
    const w = try h.Workspace.init(&features, .{});
    defer w.deinit();
    const item = (try w.prepareTypeHierarchy("test.f90", w.pos("test.f90", "feature_ext\n", 0, 1))) orelse return error.TestUnexpectedResult;
    const supers = try w.typeHierarchy(item, true);
    try std.testing.expect(supers.len == 1 and std.mem.eql(u8, supers[0], "feature_base"));
    const subs = try w.typeHierarchy(item, false);
    try std.testing.expect(subs.len == 1 and std.mem.eql(u8, subs[0], "feature_all"));
    // from a variable, its type
    const from_var = (try w.prepareTypeHierarchy("test.f90", w.pos("test.f90", "x%feat", 0, 0))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), (try w.typeHierarchy(from_var, false)).len);
    try std.testing.expectEqualStrings("feature_ext", (try w.typeHierarchy(from_var, true))[0]);
}

const empty_prefix = [_]h.File{
    .{ .name = "mymod.f90", .text =
    \\module mymod
    \\implicit none
    \\private
    \\integer, public :: alpha_one, alpha_two
    \\integer :: alpha_hidden
    \\type, public :: shape_t
    \\end type shape_t
    \\end module mymod
    \\
    },
    // the space at the end of a line is where the cursor is
    .{ .name = "use.f90", .text = "subroutine s()\n" ++
        "use mymod, only: \n" ++
        "implicit none\n" ++
        "end subroutine s\n" ++
        "subroutine t()\n" ++
        "use mymod, only: alpha_one, \n" ++
        "implicit none\n" ++
        "end subroutine t\n" ++
        "subroutine u()\n" ++
        "use mymod, only: al\n" ++
        "implicit none\n" ++
        "end subroutine u\n" ++
        "subroutine v()\n" ++
        "use \n" ++
        "implicit none\n" ++
        "type(\n" ++
        "end subroutine v\n" ++
        "subroutine w()\n" ++
        "use mymod, only: a => alpha_one, \n" ++
        "implicit none\n" ++
        "end subroutine w\n" ++
        "subroutine x(n)\n" ++
        "use mymod\n" ++
        "implicit none\n" ++
        "integer :: n\n" ++
        "type(\n" ++
        "\n" ++
        "n = \n" ++
        "call x( \n" ++
        "end subroutine x\n" },
};

/// The labels completion gives at the end of line `line` (0-based) of
/// use.f90, or null when it answers null
fn atEnd(w: *h.Workspace, line: i64) !?[]const []const u8 {
    return labelsAtEnd(w, "use.f90", line);
}

fn sameSet(got: []const []const u8, want: []const []const u8) bool {
    if (got.len != want.len) return false;
    for (want) |x| if (!has(got, x)) return false;
    return true;
}

fn expectEmptyPrefix(w: *h.Workspace) !void {
    // after `only:`, the module's public names
    var got = (try atEnd(w, 1)) orelse return h.unmet("only: null", .{});
    try h.expect(sameSet(got, &.{ "alpha_one", "alpha_two", "shape_t" }), "only: {any}", .{got});
    // after a comma, the names not listed yet
    got = (try atEnd(w, 5)) orelse return h.unmet("only: alpha_one, null", .{});
    try h.expect(sameSet(got, &.{ "alpha_two", "shape_t" }), "only: alpha_one, {any}", .{got});
    // as before with a prefix
    got = (try atEnd(w, 9)) orelse return h.unmet("only: al null", .{});
    try h.expect(sameSet(got, &.{ "alpha_one", "alpha_two" }), "only: al {any}", .{got});
    // the modules after `use`
    got = (try atEnd(w, 13)) orelse return h.unmet("use: null", .{});
    try h.expect(has(got, "mymod"), "use: {any}", .{got});
    // a renamed name is listed
    got = (try atEnd(w, 18)) orelse return h.unmet("only: a => alpha_one, null", .{});
    try h.expect(sameSet(got, &.{ "alpha_two", "shape_t" }), "only: a => alpha_one, {any}", .{got});
    // the types in scope after `type(`
    got = (try atEnd(w, 25)) orelse return h.unmet("type( null", .{});
    try h.expect(sameSet(got, &.{"shape_t"}), "type(: {any}", .{got});
    got = (try atEnd(w, 15)) orelse return h.unmet("type( in v: null", .{});
    try h.expect(got.len == 0, "type( in v: {any}", .{got});
    // elsewhere still null: the start of a statement, after `=`, in a call
    for ([_]i64{ 26, 27, 28 }) |line| {
        if (try atEnd(w, line)) |g| return h.unmet("line {d}: {any}", .{ line, g });
    }
}

test "#283 completion with nothing typed after only:, use and type(" {
    const w = try h.Workspace.init(&empty_prefix, .{});
    defer w.deinit();
    expectEmptyPrefix(w) catch |e| {
        std.debug.print("{s}\n", .{h.lastNote()});
        return e;
    };
}

// the space at the end of a line is where the cursor is
const undeclared_args = [_]h.File{.{ .name = "m.f90", .text = "module m\n" ++
    "  implicit none\n" ++
    "  integer :: mod_var\n" ++
    "  real :: mo\n" ++
    "contains\n" ++
    "  subroutine foo(nodes, cells)\n" ++
    "    implicit none\n" ++
    "    real(kind=8), allocatable :: no\n" ++
    "  end subroutine\n" ++
    "  subroutine bar(nodes, cells)\n" ++
    "    implicit none\n" ++
    "    integer :: \n" ++
    "  end subroutine\n" ++
    "  subroutine baz(nodes, cells)\n" ++
    "    implicit none\n" ++
    "    integer :: nodes\n" ++
    "    real :: \n" ++
    "  end subroutine\n" ++
    "  subroutine qux(nodes)\n" ++
    "    implicit none\n" ++
    "    integer :: nodes\n" ++
    "    real :: \n" ++
    "  end subroutine\n" ++
    "end module m\n" }};

/// The labels completion gives at the end of 0-based line `line`, or
/// null when it answers null
fn labelsAtEnd(w: *h.Workspace, name: []const u8, line: i64) !?[]const []const u8 {
    var it = std.mem.splitScalar(u8, w.text(name), '\n');
    var n: i64 = 0;
    const content = while (it.next()) |l| : (n += 1) {
        if (n == line) break l;
    } else "";
    const v = try w.server.dispatchPublic(w.arena.allocator(), "textDocument/completion", try h.json.from(w.arena.allocator(), .{
        .textDocument = .{ .uri = try w.uri(name) },
        .position = .{ .line = line, .character = content.len },
    }));
    if (v == .null) return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (h.json.items(v)) |item| try out.append(w.arena.allocator(), h.json.str(h.json.get(item, "label")) orelse "");
    return out.items;
}

fn expectUndeclaredArgs(w: *h.Workspace) !void {
    // the argument being declared, not the name being typed
    var got = (try labelsAtEnd(w, "m.f90", 7)) orelse return h.unmet(":: no: null", .{});
    try h.expect(got.len > 0 and std.mem.eql(u8, got[0], "nodes") and !has(got, "no"), ":: no: {any}", .{got});
    // with nothing typed, the arguments not declared
    got = (try labelsAtEnd(w, "m.f90", 11)) orelse return h.unmet("bar :: null", .{});
    try h.expect(got.len == 2 and has(got, "nodes") and has(got, "cells"), "bar :: {any}", .{got});
    got = (try labelsAtEnd(w, "m.f90", 16)) orelse return h.unmet("baz :: null", .{});
    try h.expect(got.len == 1 and has(got, "cells"), "baz :: {any}", .{got});
    // all declared: nothing, as before
    if (try labelsAtEnd(w, "m.f90", 21)) |g| return h.unmet("qux :: {any}", .{g});
    // not at module level
    got = (try labelsAtEnd(w, "m.f90", 3)) orelse &.{};
    try h.expect(!has(got, "nodes"), "real :: mo: {any}", .{got});
}

fn expectDeclareArgActions(w: *h.Workspace) !void {
    const header = w.pos("m.f90", "subroutine foo", 0, 0).line;
    var one: ?h.Workspace.Action = null;
    var all: ?h.Workspace.Action = null;
    for (try w.codeActions("m.f90", header)) |act| {
        if (std.mem.eql(u8, act.title, "Declare nodes as integer")) one = act;
        if (std.mem.startsWith(u8, act.title, "Declare the arguments")) all = act;
    }
    const act = one orelse return h.unmet("no quick fix declaring nodes", .{});
    try h.expect(std.mem.eql(u8, act.new_text, "    integer :: nodes\n") and act.line == header + 3, "declares with {s} before line {d}", .{ act.new_text, act.line });
    const both = all orelse return h.unmet("no quick fix declaring both", .{});
    try h.expect(std.mem.eql(u8, both.new_text, "    integer :: nodes\n    real :: cells\n"), "declares both with {s}", .{both.new_text});
    // applied, the diagnostic is gone
    const text = w.text("m.f90");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var buf: std.ArrayList(u8) = .empty;
    const aa = w.arena.allocator();
    var n: i64 = 0;
    while (lines.next()) |l| : (n += 1) {
        if (n == act.line) try buf.appendSlice(aa, act.new_text);
        try buf.appendSlice(aa, l);
        if (lines.peek() != null) try buf.append(aa, '\n');
    }
    try w.replaceText("m.f90", buf.items);
    for (try w.diagnostics("m.f90")) |d| {
        if (d.line == header and std.mem.find(u8, d.message, "\"nodes\"") != null) return h.unmet("still: {s}", .{d.message});
    }
}

test "#270 completion of the arguments not declared yet; a quick fix declaring them" {
    const w = try h.Workspace.init(&undeclared_args, .{});
    defer w.deinit();
    expectUndeclaredArgs(w) catch |e| {
        std.debug.print("{s}\n", .{h.lastNote()});
        return e;
    };
    expectDeclareArgActions(w) catch |e| {
        std.debug.print("{s}\n", .{h.lastNote()});
        return e;
    };
}
