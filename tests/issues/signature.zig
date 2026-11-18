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
