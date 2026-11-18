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

const two_forms = [_]h.File{.{ .name = "p.f90", .text =
    \\program p
    \\  implicit none
    \\  character(:), allocatable :: t(:)
    \\  integer :: n
    \\  n = this_im
    \\  call tokeni
    \\  n = this_image(
    \\  call tokenize(
    \\end program
    \\
}};

/// The completion item `label` at `needle` + `plus` of p.f90
fn itemAt(w: *h.Workspace, needle: []const u8, plus: usize, label: []const u8) !h.Workspace.Item {
    for (try w.completionItems("p.f90", w.pos("p.f90", needle, 0, plus))) |i| {
        if (std.ascii.eqlIgnoreCase(i.label, label)) return i;
    }
    return h.unmet("{s}: no {s}", .{ needle, label });
}

fn expectOneForm(w: *h.Workspace) !void {
    const this_image = try itemAt(w, "this_im\n", 7, "THIS_IMAGE");
    try h.expect(std.mem.eql(u8, this_image.insert, "THIS_IMAGE(${1:COARRAY}, DIM=${2:dim})"), "THIS_IMAGE inserts {s}", .{this_image.insert});
    try h.expect(std.mem.findScalar(u8, this_image.detail, '|') == null, "THIS_IMAGE: {s}", .{this_image.detail});
    const tokenize = try itemAt(w, "tokeni\n", 6, "TOKENIZE");
    try h.expect(std.mem.eql(u8, tokenize.insert, "TOKENIZE(${1:STRING}, ${2:SET}, ${3:TOKENS}, SEPARATORS=${4:separators})"), "TOKENIZE inserts {s}", .{tokenize.insert});
    try h.expect(std.mem.findScalar(u8, tokenize.detail, '|') == null, "TOKENIZE: {s}", .{tokenize.detail});
}

fn expectBothForms(w: *h.Workspace) !void {
    for ([_][]const u8{ "this_image(", "tokenize(" }) |call| {
        const sig = (try w.signature("p.f90", w.pos("p.f90", call, 0, call.len))) orelse return h.unmet("{s}: no signature help", .{call});
        try h.expect(sig.count == 2 and std.mem.findScalar(u8, sig.label, '|') == null, "{s}: {d} signatures, {s}", .{ call, sig.count, sig.label });
    }
}

test "#245 an intrinsic with two forms completes to the first, and signature help shows both" {
    {
        const w = try h.Workspace.init(&two_forms, .{});
        defer w.deinit();
        try expectOneForm(w);
    }
    const w = try h.Workspace.init(&two_forms, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    try expectBothForms(w);
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
    const text = w.text("use.f90");
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: i64 = 0;
    const content = while (it.next()) |l| : (n += 1) {
        if (n == line) break l;
    } else "";
    const v = try w.server.dispatchPublic(w.arena.allocator(), "textDocument/completion", try h.json.from(w.arena.allocator(), .{
        .textDocument = .{ .uri = try w.uri("use.f90") },
        .position = .{ .line = line, .character = content.len },
    }));
    if (v == .null) return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (h.json.items(v)) |item| try out.append(w.arena.allocator(), h.json.str(h.json.get(item, "label")) orelse "");
    return out.items;
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
