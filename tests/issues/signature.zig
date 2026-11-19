//! Signature help: which call the cursor is in, and which of its
//! parameters.

const std = @import("std");
const h = @import("harness.zig");

const constructors = [_]h.File{.{ .name = "m.f90", .text =
    \\module m
    \\implicit none
    \\contains
    \\subroutine s(a, b)
    \\  integer, intent(in) :: a(:), b
    \\  print *, a, b
    \\end subroutine s
    \\integer function f(x, y)
    \\  integer, intent(in) :: x, y
    \\  f = x + y
    \\end function f
    \\subroutine t()
    \\  integer :: i, arr(3)
    \\  call s([integer:: 1, 2, 3], 4)
    \\  call s([5, 6, 7], 8)
    \\  call s((/ 9, 10 /), 11)
    \\  call s([f(1, 2), 3], 4)
    \\  call s([(i, i = 1, 3)], 4)
    \\  arr = [1, 2, 3]
    \\  i = arr([1, 2])
    \\end subroutine t
    \\end module m
    \\
}};

/// Signature help at `needle` advanced by `plus`: its label (up to the
/// `(`) and active parameter, or null
fn sigAt(w: *h.Workspace, needle: []const u8, plus: usize) !?struct { name: []const u8, active: i64 } {
    const sig = (try w.signature("m.f90", w.pos("m.f90", needle, 0, plus))) orelse return null;
    const paren = std.mem.findScalar(u8, sig.label, '(') orelse sig.label.len;
    return .{ .name = sig.label[0..paren], .active = sig.active };
}

fn expectSig(w: *h.Workspace, needle: []const u8, plus: usize, name: []const u8, active: i64) !void {
    const got = (try sigAt(w, needle, plus)) orelse return h.unmet("{s} +{d}: no signature help", .{ needle, plus });
    try h.expect(std.ascii.eqlIgnoreCase(got.name, name) and got.active == active, "{s} +{d}: {s}, parameter {d}; expected {s}, {d}", .{ needle, plus, got.name, got.active, name, active });
}

fn expectInConstructors(w: *h.Workspace) !void {
    // the table of the issue
    try expectSig(w, "2, 3], 4", 0, "s", 0);
    try expectSig(w, "[5, 6", 1, "s", 0);
    try expectSig(w, "6, 7]", 0, "s", 0);
    try expectSig(w, "10 /)", 0, "s", 0);
    try expectSig(w, "4)\n  call s([5", 0, "s", 1);
    try expectSig(w, "11)", 0, "s", 1);
    // a call inside the constructor is a call of its own
    try expectSig(w, "f(1, 2), 3]", 5, "f", 1);
    try expectSig(w, "3], 4)\n  call s([(", 0, "s", 0);
    // an implied DO
    try expectSig(w, "i = 1, 3)", 4, "s", 0);
    // not a call: an array subscripted with a constructor
    try h.expect(try sigAt(w, "arr([1, 2])", 7) == null, "arr([1, 2: signature help", .{});
    try h.expect(try sigAt(w, "arr = [1, 2", 9) == null, "arr = [1, 2: signature help", .{});
}

test "#253 signature help inside an array constructor argument" {
    const w = try h.Workspace.init(&constructors, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    try h.checkIn(.hansec, 60, .fixed, expectInConstructors(w));
}

const structures = [_]h.File{
    .{ .name = "m.f90", .text =
    \\module m
    \\   implicit none
    \\   type :: pt
    \\      integer :: x, y
    \\   end type
    \\   type :: vec
    \\      real :: u, v = 0.0
    \\   end type
    \\   type, extends(vec) :: vec3
    \\      real :: w
    \\   end type
    \\   type :: hidden
    \\      integer, private :: secret
    \\      integer :: shown
    \\   end type
    \\   interface pt
    \\      module procedure make_pt
    \\   end interface
    \\contains
    \\   function make_pt(a) result(r)
    \\      integer, intent(in) :: a
    \\      type(pt) :: r
    \\      r%x = a
    \\      r%y = a
    \\   end function
    \\   subroutine inside()
    \\      type(hidden) :: hh
    \\      hh = hidden(1, 2)
    \\   end subroutine
    \\end module
    \\program p
    \\   use m
    \\   implicit none
    \\   type(pt) :: q
    \\   type(vec) :: w
    \\   type(vec3) :: w3
    \\   type(hidden) :: hh
    \\   q = make_pt(1)
    \\   q = pt(1)
    \\   w = vec(1.0, 2.0)
    \\   q = pt(x=1, y=2)
    \\   w3 = vec3(1.0, 2.0, 3.0)
    \\   hh = hidden(1, 2)
    \\   w3 = vec3(u
    \\end program
    \\
    },
};

/// All the signatures at `needle` + `plus` of m.f90, and the active one
fn allSigs(w: *h.Workspace, needle: []const u8, plus: usize) !?struct { labels: []const []const u8, active: i64, param: i64 } {
    const aa = w.arena.allocator();
    const p = w.pos("m.f90", needle, 0, plus);
    const v = try w.server.dispatchPublic(aa, "textDocument/signatureHelp", try h.json.from(aa, .{
        .textDocument = .{ .uri = try w.uri("m.f90") },
        .position = .{ .line = p.line, .character = p.col },
    }));
    if (v == .null) return null;
    var labels: std.ArrayList([]const u8) = .empty;
    for (h.json.items(h.json.get(v, "signatures"))) |s| try labels.append(aa, h.json.str(h.json.get(s, "label")) orelse "");
    return .{
        .labels = labels.items,
        .active = h.json.int(h.json.get(v, "activeSignature")) orelse 0,
        .param = h.json.int(h.json.get(v, "activeParameter")) orelse -1,
    };
}

fn hasLabel(labels: []const []const u8, label: []const u8) bool {
    for (labels) |l| if (std.ascii.eqlIgnoreCase(l, label)) return true;
    return false;
}

fn expectConstructorSignatures(w: *h.Workspace) !void {
    // a procedure: as before
    var s = (try allSigs(w, "make_pt(1)\n", 8)) orelse return h.unmet("make_pt(1): null", .{});
    try h.expect(s.labels.len == 1 and hasLabel(s.labels, "make_pt(a)"), "make_pt(1): {any}", .{s.labels});
    // the generic interface of the type's name and the structure constructor
    s = (try allSigs(w, "= pt(1)", 5)) orelse return h.unmet("pt(1): null", .{});
    try h.expect(s.labels.len == 2 and hasLabel(s.labels, "make_pt(a)") and hasLabel(s.labels, "pt(x, y)"), "pt(1): {any}", .{s.labels});
    // a structure constructor alone; a component with a default value is optional
    s = (try allSigs(w, "vec(1.0, 2.0)", 4)) orelse return h.unmet("vec(: null", .{});
    try h.expect(s.labels.len == 1 and hasLabel(s.labels, "vec(u, v=v)"), "vec(: {any}", .{s.labels});
    // a keyword: the constructor, at that component
    s = (try allSigs(w, "y=2)", 2)) orelse return h.unmet("pt(x=1, y=: null", .{});
    const active = s.labels[@intCast(s.active)];
    try h.expect(std.ascii.eqlIgnoreCase(active, "pt(x, y)") and s.param == 1, "pt(x=1, y=: {s} parameter {d}", .{ active, s.param });
    // an extended type: the parent's components first
    s = (try allSigs(w, "vec3(1.0", 5)) orelse return h.unmet("vec3(: null", .{});
    try h.expect(s.labels.len == 1 and hasLabel(s.labels, "vec3(u, v=v, w)"), "vec3(: {any}", .{s.labels});
    // a private component: none outside the module, one inside
    if (try allSigs(w, "hidden(1, 2)\n   w3", 7)) |x| return h.unmet("hidden( outside: {any}", .{x.labels});
    s = (try allSigs(w, "hidden(1, 2)\n   end subroutine", 7)) orelse return h.unmet("hidden( inside: null", .{});
    try h.expect(hasLabel(s.labels, "hidden(secret, shown)"), "hidden( inside: {any}", .{s.labels});
    // keyword arguments: the parent's components too
    const items = try w.completion("m.f90", w.pos("m.f90", "vec3(u", 0, 6));
    try h.expect(hasLabel(items, "u="), "vec3(u: {any}", .{items});
    // a type and an interface of one name are not declared twice
    for (try w.diagnostics("m.f90")) |d| try h.expect(std.mem.find(u8, d.message, "twice") == null, "{s}", .{d.message});
}

test "#266 signature help for structure constructors and a generic interface named like its type" {
    const w = try h.Workspace.init(&structures, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    try h.checkIn(.hansec, 148, .fixed, expectConstructorSignatures(w));
}
