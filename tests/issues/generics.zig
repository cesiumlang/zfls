//! Calls of a generic interface resolved by the type, kind and rank of
//! their arguments (#273): go to definition and implementation, hover,
//! signature help, inlay hints and call hierarchy take the specific
//! procedure the call references, and today's choice (the first that takes
//! as many arguments) when the arguments do not tell.

const std = @import("std");
const h = @import("harness.zig");

const shapes =
    \\module shapes
    \\  implicit none
    \\  integer, parameter :: dp = kind(1.0d0)
    \\  interface area
    \\    module procedure area_r, area_i
    \\  end interface
    \\  interface twice
    \\    module procedure twice_4, twice_8
    \\  end interface
    \\  interface total
    \\    module procedure total_s, total_v
    \\  end interface
    \\  interface sq
    \\    module procedure sq_e, sq_v
    \\  end interface
    \\contains
    \\  real function area_r(r)
    \\    real, intent(in) :: r
    \\    area_r = r
    \\  end function
    \\  real function area_i(i)
    \\    integer, intent(in) :: i
    \\    area_i = i
    \\  end function
    \\  real function twice_4(x)
    \\    real(4), intent(in) :: x
    \\    twice_4 = 2 * x
    \\  end function
    \\  real(8) function twice_8(y)
    \\    real(8), intent(in) :: y
    \\    twice_8 = 2 * y
    \\  end function
    \\  real function total_s(s)
    \\    real, intent(in) :: s
    \\    total_s = s
    \\  end function
    \\  real function total_v(v)
    \\    real, intent(in) :: v(:)
    \\    total_v = sum(v)
    \\  end function
    \\  elemental real function sq_e(e)
    \\    real, intent(in) :: e
    \\    sq_e = e * e
    \\  end function
    \\  function sq_v(w)
    \\    real, intent(in) :: w(:)
    \\    real :: sq_v(size(w))
    \\    sq_v = w * w
    \\  end function
    \\end module
    \\program p
    \\  use shapes
    \\  implicit none
    \\  integer :: k
    \\  real :: a(3), b(2, 2), z
    \\  real(dp) :: d
    \\  real, external :: ext
    \\  k = 2
    \\  z = 1.0
    \\  d = 1.0d0
    \\  a = 1.0
    \\  b = 1.0
    \\  print *, area(1.0)
    \\  print *, area(k)
    \\  print *, area(ext(1))
    \\  print *, twice(1.0), twice(1.0d0), twice(d), twice(z)
    \\  print *, total(z), total(a), total(b(:, 1)), total(a(2))
    \\  print *, sq(z), sq(a), sq(b)
    \\end program
    \\
;

/// The line (1-based) that go to definition on the `nth` `needle` goes to
fn defLine(w: *h.Workspace, needle: []const u8, nth: usize) !i64 {
    const d = (try w.definition("m.f90", w.pos("m.f90", needle, nth, 0))) orelse return h.unmet("no definition of {s}", .{needle});
    return d.line + 1;
}

fn expectDef(w: *h.Workspace, needle: []const u8, nth: usize, want: i64) !void {
    const got = try defLine(w, needle, nth);
    try h.expect(got == want, "{s} (#{d}) goes to line {d}, not {d}", .{ needle, nth, got, want });
}

test "go to definition on a call of a generic goes to the specific of the arguments' type, kind and rank (#273)" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text = shapes }}, .{});
    defer w.deinit();
    // type
    try expectDef(w, "area(1.0)", 0, 17);
    try expectDef(w, "area(k)", 0, 21);
    // kind: a default real, a double precision literal, a REAL(dp) variable
    try expectDef(w, "twice(1.0)", 0, 25);
    try expectDef(w, "twice(1.0d0)", 0, 29);
    try expectDef(w, "twice(d)", 0, 29);
    try expectDef(w, "twice(z)", 0, 25);
    // rank: a scalar, a rank-1 array and section, an element; a rank-2
    // array fits neither, which leaves today's choice
    try expectDef(w, "total(z)", 0, 33);
    try expectDef(w, "total(a)", 0, 37);
    try expectDef(w, "total(b(:, 1))", 0, 37);
    try expectDef(w, "total(a(2))", 0, 33);
    // an elemental specific takes an array for its scalar; a nonelemental
    // one that fits the array is the one referenced
    try expectDef(w, "sq(z)", 0, 41);
    try expectDef(w, "sq(a)", 0, 45);
    try expectDef(w, "sq(b)", 0, 41);
    // an argument whose type is unknown: today's choice
    try expectDef(w, "area(ext(1))", 0, 17);
    // no new argument diagnostics
    try w.expectNoDiagnostics("m.f90");
}

test "hover, signature help and inlay hints on a call of a generic take the specific of the arguments (#273)" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text = shapes }}, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    // hover: the one specific, or all when the arguments do not tell
    const one = (try w.hover("m.f90", w.pos("m.f90", "area(k)", 0, 1))) orelse return error.NoHover;
    try std.testing.expect(std.mem.find(u8, one, "area_i") != null);
    try std.testing.expect(std.mem.find(u8, one, "area_r") == null);
    const both = (try w.hover("m.f90", w.pos("m.f90", "area(ext(1))", 0, 1))) orelse return error.NoHover;
    try std.testing.expect(std.mem.find(u8, both, "area_i") != null);
    try std.testing.expect(std.mem.find(u8, both, "area_r") != null);
    // signature help: the active signature
    const sig = (try w.signature("m.f90", w.pos("m.f90", "area(k)", 0, 6))) orelse return error.NoSignature;
    try std.testing.expectEqual(@as(usize, 2), sig.count);
    try std.testing.expect(std.mem.startsWith(u8, sig.label, "area_i"));
    const sig_r = (try w.signature("m.f90", w.pos("m.f90", "area(1.0)", 0, 8))) orelse return error.NoSignature;
    try std.testing.expect(std.mem.startsWith(u8, sig_r.label, "area_r"));
    const sig_v = (try w.signature("m.f90", w.pos("m.f90", "total(a)", 0, 7))) orelse return error.NoSignature;
    try std.testing.expect(std.mem.startsWith(u8, sig_v.label, "total_v"));
    // inlay hints: the names of the dummy arguments of the specific
    const area_k = w.pos("m.f90", "area(k)", 0, 5);
    const total_a = w.pos("m.f90", "total(a)", 0, 6);
    var found: usize = 0;
    for (try w.inlayHints("m.f90")) |hint| {
        if (hint.line == area_k.line and hint.col == area_k.col) {
            try std.testing.expectEqualStrings("i:", hint.label);
            found += 1;
        }
        if (hint.line == total_a.line and hint.col == total_a.col) {
            try std.testing.expectEqualStrings("v:", hint.label);
            found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

const bound =
    \\module shapes
    \\  implicit none
    \\  type :: a_t
    \\  end type
    \\  type :: b_t
    \\  end type
    \\  type, extends(a_t) :: c_t
    \\  end type
    \\  type :: shape_t
    \\  contains
    \\    procedure :: scale_r, scale_i
    \\    generic :: scale => scale_r, scale_i
    \\  end type
    \\  interface show
    \\    module procedure show_b, show_a
    \\  end interface
    \\contains
    \\  subroutine scale_r(self, r)
    \\    class(shape_t), intent(inout) :: self
    \\    real, intent(in) :: r
    \\  end subroutine
    \\  subroutine scale_i(self, i)
    \\    class(shape_t), intent(inout) :: self
    \\    integer, intent(in) :: i
    \\  end subroutine
    \\  subroutine show_a(x)
    \\    class(a_t), intent(in) :: x
    \\  end subroutine
    \\  subroutine show_b(y)
    \\    type(b_t), intent(in) :: y
    \\  end subroutine
    \\end module
    \\program p
    \\  use shapes
    \\  implicit none
    \\  type(shape_t) :: s
    \\  type(b_t) :: b
    \\  type(c_t) :: c
    \\  call s%scale(2)
    \\  call s%scale(2.0)
    \\  call show(b)
    \\  call show(c)
    \\end program
    \\
;

test "type-bound generics and derived-type arguments resolve the same way (#273)" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text = bound }}, .{});
    defer w.deinit();
    const scale_i = (try w.implementation("m.f90", w.pos("m.f90", "scale(2)", 0, 0))) orelse return error.NoImplementation;
    try std.testing.expectEqual(@as(i64, 21), scale_i.line);
    const scale_r = (try w.implementation("m.f90", w.pos("m.f90", "scale(2.0)", 0, 0))) orelse return error.NoImplementation;
    try std.testing.expectEqual(@as(i64, 17), scale_r.line);
    const show_b = (try w.definition("m.f90", w.pos("m.f90", "show(b)", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 28), show_b.line);
    // an extension of a_t, for a CLASS(a_t)
    const show_a = (try w.definition("m.f90", w.pos("m.f90", "show(c)", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 25), show_a.line);
    // call hierarchy: the outgoing calls of the program
    const item = (try w.prepareCallHierarchy("m.f90", w.pos("m.f90", "program p", 0, 8))) orelse return error.NoItem;
    var names: std.ArrayList([]const u8) = .empty;
    for (try w.calls(item, false)) |c| try names.append(std.testing.allocator, c.name);
    defer names.deinit(std.testing.allocator);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try std.testing.expectEqual(@as(usize, 4), names.items.len);
    for ([_][]const u8{ "scale_i", "scale_r", "show_a", "show_b" }, names.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
