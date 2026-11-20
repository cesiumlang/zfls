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

const self_named = h.File{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  interface sync
    \\    module procedure sync, sync_n
    \\  end interface
    \\  interface wait
    \\    procedure :: wait
    \\  end interface
    \\contains
    \\  subroutine sync()
    \\  end subroutine sync
    \\  subroutine sync_n(n)
    \\    integer, intent(in) :: n
    \\  end subroutine
    \\  subroutine wait()
    \\  end subroutine
    \\end module
    \\
};

const self_named_user = h.File{ .name = "u.f90", .text =
    \\program p
    \\  use m
    \\  implicit none
    \\  call sync()
    \\  call sync(1)
    \\  call wait()
    \\  call wa
    \\end program
    \\
};

/// That go to definition at `plus` characters into the `nth` `needle` of
/// file `name` goes to 1-based line `want` of m.f90
fn expectDefIn(w: *h.Workspace, name: []const u8, needle: []const u8, plus: usize, want: i64) !void {
    const d = (try w.definition(name, w.pos(name, needle, 0, plus))) orelse return h.unmet("no definition of {s}", .{needle});
    try h.expect(std.mem.endsWith(u8, d.uri, "m.f90") and d.line + 1 == want, "{s} goes to {s}:{d}, not m.f90:{d}", .{ needle, d.uri, d.line + 1, want });
}

test "a generic that has the name of one of its specifics: hover, definition, references, completion (#469)" {
    const w = try h.Workspace.init(&.{ self_named, self_named_user }, .{});
    defer w.deinit();
    // hover: the specifics, the generic's namesake among them
    try w.expectHoverContains("u.f90", w.pos("u.f90", "wait()", 0, 1), "SUBROUTINE wait()");
    try w.expectHoverContains("m.f90", w.pos("m.f90", "interface wait", 0, 10), "SUBROUTINE wait()");
    const both = (try w.hover("m.f90", w.pos("m.f90", "interface sync", 0, 10))) orelse return h.unmet("no hover on the generic sync", .{});
    try h.expect(std.mem.find(u8, both, "SUBROUTINE sync()") != null and std.mem.find(u8, both, "SUBROUTINE sync_n(n)") != null, "both specifics: {s}", .{both});
    // a call: the specific of its arguments
    const none = (try w.hover("u.f90", w.pos("u.f90", "sync()", 0, 1))) orelse return h.unmet("no hover on sync()", .{});
    try h.expect(std.mem.find(u8, none, "SUBROUTINE sync()") != null and std.mem.find(u8, none, "sync_n") == null, "sync() is sync: {s}", .{none});
    try w.expectHoverContains("u.f90", w.pos("u.f90", "sync(1)", 0, 1), "SUBROUTINE sync_n(n)");
    // definition: the generic on its own name, the specific on a call (as
    // for any generic, #273) and on the specific's own names
    try expectDefIn(w, "m.f90", "interface sync", 10, 3);
    try expectDefIn(w, "m.f90", "interface wait", 10, 6);
    try expectDefIn(w, "u.f90", "sync()", 1, 10);
    try expectDefIn(w, "u.f90", "sync(1)", 1, 12);
    try expectDefIn(w, "u.f90", "wait()", 1, 15);
    try expectDefIn(w, "m.f90", "procedure sync", 10, 10);
    try expectDefIn(w, "m.f90", "procedure :: wait", 13, 15);
    try expectDefIn(w, "m.f90", "subroutine sync()", 11, 10);
    try expectDefIn(w, "m.f90", "end subroutine sync", 15, 10);
    try w.expectHoverContains("m.f90", w.pos("m.f90", "subroutine sync()", 0, 11), "SUBROUTINE sync()");
    // references: the generic and the specific are one name of the module
    for ([_]struct { []const u8, []const u8, usize }{
        .{ "u.f90", "sync()", 1 },
        .{ "m.f90", "interface sync", 10 },
        .{ "m.f90", "subroutine sync()", 11 },
    }) |at| {
        const refs = try w.references(at[0], w.pos(at[0], at[1], 0, at[2]));
        try h.expect(refs.len == 6, "references of sync from {s}: {d}, not 6", .{ at[1], refs.len });
    }
    // completion: the specific once, by its generic
    var waits: usize = 0;
    for (try w.completion("u.f90", w.pos("u.f90", "call wa", 0, 7))) |label| {
        if (std.mem.eql(u8, label, "wait")) waits += 1;
    }
    try h.expect(waits == 1, "wait offered {d} times, not once", .{waits});
    try w.expectNoDiagnostics("m.f90");
}

const bodies = h.File{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  type :: v_t
    \\    real :: x
    \\  end type
    \\  interface f
    \\    subroutine f1(x)
    \\      integer, intent(in) :: x
    \\    end subroutine
    \\    subroutine f2(x)
    \\      real, intent(in) :: x
    \\    end subroutine
    \\  end interface
    \\  interface g
    \\    module procedure g1
    \\    function g2(x) result(r)
    \\      real, intent(in) :: x
    \\      real :: r
    \\    end function
    \\  end interface
    \\  interface h
    \\    subroutine h(n)
    \\      integer, intent(in) :: n
    \\    end subroutine
    \\  end interface
    \\  interface operator(.add.)
    \\    function add_v(a, b) result(c)
    \\      import :: v_t
    \\      type(v_t), intent(in) :: a, b
    \\      type(v_t) :: c
    \\    end function
    \\  end interface
    \\  interface assignment(=)
    \\    subroutine set_v(a, r)
    \\      import :: v_t
    \\      type(v_t), intent(out) :: a
    \\      real, intent(in) :: r
    \\    end subroutine
    \\  end interface
    \\  interface
    \\    subroutine ext(k)
    \\      integer, intent(in) :: k
    \\    end subroutine
    \\  end interface
    \\  abstract interface
    \\    subroutine cb(k)
    \\      integer, intent(in) :: k
    \\    end subroutine
    \\  end interface
    \\contains
    \\  function g1(x) result(r)
    \\    integer, intent(in) :: x
    \\    integer :: r
    \\    r = x
    \\  end function
    \\end module
    \\
};

const bodies_user = h.File{ .name = "u.f90", .text =
    \\program p
    \\  use m
    \\  implicit none
    \\  type(v_t) :: u, v
    \\  procedure(cb), pointer :: pc => null()
    \\  call f(1)
    \\  call f(1.0)
    \\  print *, g(1), g(1.0)
    \\  call h(2)
    \\  call ext(3)
    \\  u = 1.0
    \\  v = u .add. u
    \\  call f
    \\end program
    \\
};

/// That hover at `plus` characters into the first `needle` of `name` shows
/// `want` and not `not`
fn expectHoverOnly(w: *h.Workspace, name: []const u8, needle: []const u8, plus: usize, want: []const u8, not: []const u8) !void {
    const got = (try w.hover(name, w.pos(name, needle, 0, plus))) orelse return h.unmet("no hover on {s}", .{needle});
    try h.expect(std.mem.find(u8, got, want) != null and std.mem.find(u8, got, not) == null, "hover on {s}: {s}", .{ needle, got });
}

test "a generic whose specifics are interface bodies: hover, signature help, definition, references, completion (#472)" {
    const w = try h.Workspace.init(&.{ bodies, bodies_user }, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    // hover: the specifics, or the one of a call's arguments
    try w.expectHoverContains("m.f90", w.pos("m.f90", "interface f", 0, 10), "SUBROUTINE f1(x)");
    try w.expectHoverContains("m.f90", w.pos("m.f90", "interface f", 0, 10), "SUBROUTINE f2(x)");
    try expectHoverOnly(w, "u.f90", "f(1)", 0, "SUBROUTINE f1(x)", "f2");
    try expectHoverOnly(w, "u.f90", "f(1.0)", 0, "SUBROUTINE f2(x)", "f1");
    // a module procedure and an interface body of one generic
    try expectHoverOnly(w, "u.f90", "g(1)", 0, "FUNCTION g1(x)", "g2");
    try expectHoverOnly(w, "u.f90", "g(1.0)", 0, "FUNCTION g2(x)", "g1");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "h(2)", 0, 0), "SUBROUTINE h(n)");
    // signature help: each specific, the one of the arguments active
    for ([_]struct { []const u8, usize, []const u8 }{
        .{ "f(1)", 3, "f1(" },
        .{ "f(1.0)", 5, "f2(" },
        .{ "g(1.0)", 5, "g2(" },
    }) |c| {
        const sig = (try w.signature("u.f90", w.pos("u.f90", c[0], 0, c[1]))) orelse return h.unmet("no signature help on {s}", .{c[0]});
        try h.expect(sig.count == 2 and std.mem.startsWith(u8, sig.label, c[2]), "signature help on {s}: {d}, {s}", .{ c[0], sig.count, sig.label });
    }
    // definition: a call goes to the specific of its arguments (#273); an
    // interface body of the generic's name is the generic on the
    // INTERFACE statement (as #469 for a module procedure)
    try expectDefIn(w, "u.f90", "f(1)", 0, 7);
    try expectDefIn(w, "u.f90", "f(1.0)", 0, 10);
    try expectDefIn(w, "u.f90", "g(1)", 0, 51);
    try expectDefIn(w, "u.f90", "g(1.0)", 0, 16);
    try expectDefIn(w, "u.f90", "h(2)", 0, 22);
    try expectDefIn(w, "m.f90", "interface h", 10, 21);
    try expectDefIn(w, "m.f90", "subroutine h", 11, 22);
    // references: the generic's name
    const refs = try w.references("u.f90", w.pos("u.f90", "f(1)", 0, 0));
    try h.expect(refs.len == 4, "references of f: {d}, not 4", .{refs.len});
    for ([_]struct { []const u8, []const u8, usize }{ .{ "u.f90", "h(2)", 0 }, .{ "m.f90", "interface h", 10 } }) |at| {
        const hr = try w.references(at[0], w.pos(at[0], at[1], 0, at[2]));
        try h.expect(hr.len == 2, "references of the generic h from {s}: {d}, not 2", .{ at[1], hr.len });
    }
    // a defined operator and a defined assignment by interface bodies
    try w.expectHoverContains("u.f90", w.pos("u.f90", ".add.", 0, 1), "FUNCTION add_v(a, b)");
    try w.expectHoverContains("u.f90", w.pos("u.f90", "= 1.0", 0, 0), "SUBROUTINE set_v(a, r)");
    // completion: the generic, by its specifics' calls
    var fs: usize = 0;
    for (try w.completionItems("u.f90", w.pos("u.f90", "call f\n", 0, 6))) |it| {
        if (std.mem.eql(u8, it.label, "f") and std.mem.eql(u8, it.detail, "SUBROUTINE f(x)")) fs += 1;
    }
    try h.expect(fs == 1, "f offered {d} times, not once", .{fs});
    // an interface block without a generic specification and an abstract
    // one: as they were
    try w.expectHoverContains("u.f90", w.pos("u.f90", "ext(3)", 0, 0), "SUBROUTINE ext(k)");
    try expectDefIn(w, "u.f90", "ext(3)", 0, 41);
    try w.expectHoverContains("u.f90", w.pos("u.f90", "cb)", 0, 0), "SUBROUTINE cb(k)");
    try w.expectNoDiagnostics("m.f90");
    try w.expectNoDiagnostics("u.f90");
}

const named_bodies = h.File{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  private
    \\  public :: f, f1, ext
    \\  interface f
    \\    subroutine f1(x)
    \\      integer, intent(in) :: x
    \\    end subroutine f1
    \\    subroutine f2(x)
    \\      real, intent(in) :: x
    \\    end subroutine
    \\  end interface f
    \\  interface
    \\    subroutine ext(k)
    \\      integer, intent(in) :: k
    \\    end subroutine
    \\    subroutine hid(k)
    \\      integer, intent(in) :: k
    \\    end subroutine
    \\  end interface
    \\contains
    \\  subroutine inside()
    \\    call f1(1)
    \\    call f2(2.0)
    \\    call hid(3)
    \\  end subroutine
    \\end module
    \\
};

const named_bodies_user = h.File{ .name = "u.f90", .text =
    \\program p
    \\  use m
    \\  implicit none
    \\  call f1(4)
    \\  call ext(5)
    \\  call f2(6.0)
    \\  call hid(7)
    \\  call f
    \\  call e
    \\end program
    \\
};

/// The number of the locations in `locs` in file `name`
fn countIn(locs: []const h.Location, name: []const u8) usize {
    var n: usize = 0;
    for (locs) |l| if (std.mem.endsWith(u8, l.uri, name)) {
        n += 1;
    };
    return n;
}

test "the interface bodies of a named generic are names of the module, public or not as its other names (#474)" {
    const w = try h.Workspace.init(&.{ named_bodies, named_bodies_user }, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    // a specific called by its own name: hover, definition, signature help
    try expectHoverOnly(w, "u.f90", "f1(4)", 0, "SUBROUTINE f1(x)", "f2");
    try expectDefIn(w, "u.f90", "f1(4)", 0, 6);
    const sig = (try w.signature("u.f90", w.pos("u.f90", "f1(4)", 0, 3))) orelse return h.unmet("no signature help on f1(4)", .{});
    try h.expect(sig.count == 1 and std.mem.startsWith(u8, sig.label, "f1("), "signature help on f1(4): {d}, {s}", .{ sig.count, sig.label });
    // inside the module, private ones too
    try w.expectHoverContains("m.f90", w.pos("m.f90", "f1(1)", 0, 0), "SUBROUTINE f1(x)");
    try expectDefIn(w, "m.f90", "f2(2.0)", 0, 9);
    try expectDefIn(w, "m.f90", "hid(3)", 0, 17);
    // outside it, only the public ones: of a named generic and of an
    // unnamed interface block alike
    try w.expectHoverContains("u.f90", w.pos("u.f90", "ext(5)", 0, 0), "SUBROUTINE ext(k)");
    for ([_][]const u8{ "f2(6.0)", "hid(7)" }) |needle| {
        const got = try w.hover("u.f90", w.pos("u.f90", needle, 0, 0));
        try h.expect(got == null, "hover on the private {s}: {?s}", .{ needle, got });
    }
    // references and rename: the module's name, in every file that uses it
    for ([_]struct { []const u8, []const u8, usize, usize, usize }{
        .{ "u.f90", "f1(4)", 0, 4, 1 },
        .{ "m.f90", "subroutine f1", 11, 4, 1 },
        .{ "u.f90", "ext(5)", 0, 2, 1 },
        .{ "m.f90", "subroutine ext", 11, 2, 1 },
    }) |c| {
        const refs = try w.references(c[0], w.pos(c[0], c[1], 0, c[2]));
        try h.expect(countIn(refs, "m.f90") == c[3] and countIn(refs, "u.f90") == c[4], "references from {s}: {d} in m.f90, {d} in u.f90", .{ c[1], countIn(refs, "m.f90"), countIn(refs, "u.f90") });
    }
    const edits = try w.rename("u.f90", w.pos("u.f90", "f1(4)", 0, 0), "first");
    var in_user: usize = 0;
    for (edits) |e| if (std.mem.endsWith(u8, e.uri, "u.f90")) {
        in_user += 1;
    };
    try h.expect(edits.len == 5 and in_user == 1, "rename of f1: {d} edits, {d} in u.f90", .{ edits.len, in_user });
    // completion: the public ones
    var offered: [3]bool = @splat(false);
    for (try w.completion("u.f90", w.pos("u.f90", "call f\n", 0, 6))) |label| {
        for ([_][]const u8{ "f", "f1", "f2" }, &offered) |want, *o| if (std.mem.eql(u8, label, want)) {
            o.* = true;
        };
    }
    try h.expect(offered[0] and offered[1] and !offered[2], "call f offers f {}, f1 {}, f2 {}", .{ offered[0], offered[1], offered[2] });
    var ext_offered = false;
    for (try w.completion("u.f90", w.pos("u.f90", "call e\n", 0, 6))) |label| {
        if (std.mem.eql(u8, label, "ext")) ext_offered = true;
    }
    try h.expect(ext_offered, "call e does not offer the public ext", .{});
    try w.expectNoDiagnostics("m.f90");
    try w.expectNoDiagnostics("u.f90");
}
