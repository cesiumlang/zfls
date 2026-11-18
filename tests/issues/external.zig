//! Procedures a caller declares itself (#232): `external solve`,
//! `real, external :: twice`, or only the type of a function it calls
//! (`real twice`), stand for the workspace's procedure of that name.

const std = @import("std");
const h = @import("harness.zig");

const callers = [_]h.File{.{ .name = "a.f90", .text =
    \\subroutine solve(n, x, info)
    \\  integer :: n, info
    \\  real :: x(n)
    \\  info = 0
    \\end subroutine
    \\real function twice(v)
    \\  real :: v
    \\  twice = 2 * v
    \\end function
    \\subroutine with_external()
    \\  external solve
    \\  real, external :: twice
    \\  real :: x(2), y
    \\  integer :: info
    \\  call solve(2, x, info)
    \\  y = twice(x(2))
    \\  call solve(2)
    \\end subroutine
    \\subroutine typed_only()
    \\  real twice
    \\  real :: y
    \\  y = twice(1.0)
    \\end subroutine
    \\subroutine no_declaration()
    \\  real :: x(2)
    \\  integer :: info
    \\  call solve(2, x, info)
    \\  call solve(2)
    \\end subroutine
    \\subroutine apply(f, g)
    \\  external f
    \\  real g
    \\  real :: y
    \\  call f(1)
    \\  y = g(2.0)
    \\end subroutine
    \\subroutine f(a, b)
    \\  integer :: a, b
    \\end subroutine
    \\real function g(a, b)
    \\  real :: a, b
    \\  g = a + b
    \\end function
    \\
}};

fn sorted(comptime T: type, items: []const T) ![]const [2]i64 {
    var out: std.ArrayList([2]i64) = .empty;
    for (items) |it| try out.append(std.testing.allocator, .{ it.line, if (@hasField(T, "col")) it.col else it.start });
    const s = try out.toOwnedSlice(std.testing.allocator);
    std.mem.sort([2]i64, s, {}, struct {
        fn lt(_: void, x: [2]i64, y: [2]i64) bool {
            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
        }
    }.lt);
    return s;
}

fn expectSorted(want: []const [2]i64, got: []const [2]i64) !void {
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices([2]i64, want, got);
}

test "signature help and inlay hints through a caller's EXTERNAL or typed declaration (#232)" {
    const w = try h.Workspace.init(&callers, .{});
    defer w.deinit();
    for ([_]h.Pos{ .{ .line = 14, .col = 16 }, .{ .line = 26, .col = 16 } }) |p| {
        const s = (try w.signature("a.f90", p)) orelse return error.NoSignature;
        try std.testing.expectEqualStrings("solve(n, x, info)", s.label);
    }
    for ([_]h.Pos{ .{ .line = 15, .col = 12 }, .{ .line = 21, .col = 12 } }) |p| {
        const s = (try w.signature("a.f90", p)) orelse return error.NoSignature;
        try std.testing.expectEqualStrings("twice(v)", s.label);
    }
    var lines: [60]usize = @splat(0);
    for (try w.inlayHints("a.f90")) |hint| lines[@intCast(hint.line)] += 1;
    // `n:` before the literal 2, `v:` before `x(2)` and `1.0`; none for
    // the dummy procedures
    for (lines, 0..) |n, l| {
        const want: usize = for ([_]usize{ 14, 15, 16, 21, 26, 27 }) |x| {
            if (x == l) break 1;
        } else 0;
        try std.testing.expectEqual(want, n);
    }
}

test "argument checks through a caller's EXTERNAL declaration (#232)" {
    const w = try h.Workspace.init(&callers, .{});
    defer w.deinit();
    var missing: [40]usize = @splat(0);
    for (try w.diagnostics("a.f90")) |d| {
        if (std.mem.startsWith(u8, d.message, "Missing argument") and std.mem.endsWith(u8, d.message, "of solve")) missing[@intCast(d.line)] += 1;
    }
    try std.testing.expectEqual(2, missing[16]);
    try std.testing.expectEqual(2, missing[27]);
}

test "references and rename of a procedure take its callers' declarations (#232)" {
    const w = try h.Workspace.init(&callers, .{});
    defer w.deinit();
    const solve = [_][2]i64{ .{ 0, 11 }, .{ 10, 11 }, .{ 14, 7 }, .{ 16, 7 }, .{ 26, 7 }, .{ 27, 7 } };
    for ([_]h.Pos{ .{ .line = 0, .col = 11 }, .{ .line = 14, .col = 7 }, .{ .line = 10, .col = 11 } }) |p| {
        try expectSorted(&solve, try sorted(h.Location, try w.references("a.f90", p)));
        try expectSorted(&solve, try sorted(h.Edit, try w.rename("a.f90", p, "solve2")));
    }
    // the typed declaration of a called function too
    // (the function's result variable, line 7, is #228's)
    const twice = [_][2]i64{ .{ 5, 14 }, .{ 11, 20 }, .{ 15, 6 }, .{ 19, 7 }, .{ 21, 6 } };
    for ([_]h.Pos{ .{ .line = 5, .col = 14 }, .{ .line = 21, .col = 6 } }) |p| {
        var got: std.ArrayList(h.Location) = .empty;
        for (try w.references("a.f90", p)) |l| if (l.line != 7) try got.append(std.testing.allocator, l);
        defer got.deinit(std.testing.allocator);
        try expectSorted(&twice, try sorted(h.Location, got.items));
    }
}

test "a dummy procedure is not the workspace's procedure of its name (#232)" {
    const w = try h.Workspace.init(&callers, .{});
    defer w.deinit();
    try std.testing.expect(try w.signature("a.f90", w.pos("a.f90", "call f(1)", 0, 7)) == null);
    try std.testing.expect(try w.signature("a.f90", w.pos("a.f90", "g(2.0)", 0, 2)) == null);
    for (try w.diagnostics("a.f90")) |d| try std.testing.expect(std.mem.find(u8, d.message, "of f") == null and std.mem.find(u8, d.message, "of g") == null);
    // go to definition stays on the local declaration, implementation goes
    // to the procedure
    const call = w.pos("a.f90", "call solve(2, x", 0, 5);
    const def = (try w.definition("a.f90", call)) orelse return error.NoDefinition;
    try std.testing.expectEqual(10, def.line);
    const impl = (try w.implementation("a.f90", call)) orelse return error.NoImplementation;
    try std.testing.expectEqual(0, impl.line);
}

test "no procedure for a caller's declaration when two files define one of that name (#232)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "a.f90", .text = "subroutine dup(n)\n  integer :: n\nend subroutine\n" },
        .{ .name = "b.f90", .text = "subroutine dup(n, m)\n  integer :: n, m\nend subroutine\n" },
        .{ .name = "c.f90", .text = "subroutine caller()\n  external dup\n  call dup(1)\nend subroutine\n" },
    }, .{});
    defer w.deinit();
    try std.testing.expect(try w.signature("c.f90", .{ .line = 2, .col = 11 }) == null);
    try std.testing.expectEqual(0, (try w.inlayHints("c.f90")).len);
}
