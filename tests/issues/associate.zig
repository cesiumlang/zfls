//! ASSOCIATE constructs (#230): named ones, an associate name spelled like
//! the variable of its selector, and the types of names bound to literals
//! and expressions.

const std = @import("std");
const h = @import("harness.zig");

test "a named ASSOCIATE construct defines its names (#230)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program test
        \\  implicit none
        \\  integer :: a
        \\  a = 1
        \\  associate (c => a)
        \\    print *, c
        \\  end associate
        \\  testing: associate (d => a)
        \\    print *, d
        \\  end associate testing
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "print *, c", 0, 9), "INTEGER :: c");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "print *, d", 0, 9), "INTEGER :: d");
    const refs = try w.references("t.f90", w.pos("t.f90", "testing:", 0, 0));
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqual(@as(i64, 7), refs[0].line);
    try std.testing.expectEqual(@as(i64, 9), refs[1].line);
}

const same_names =
    \\program p
    \\  implicit none
    \\  type :: inner_t
    \\    integer :: a
    \\  end type
    \\  type :: outer_t
    \\    type(inner_t) :: c
    \\  end type
    \\  type(outer_t) :: t
    \\  integer :: y(10)
    \\  real :: w
    \\  associate (y => y(3), w => w)
    \\    print *, y, w
    \\  end associate
    \\  associate (t => t%c)
    \\    print *, t%a
    \\  end associate
    \\  print *, y, w
    \\end program
    \\
;

fn lines(locs: []const h.Location) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (locs) |l| try out.append(std.testing.allocator, l.line * 1000 + l.col);
    std.mem.sort(i64, out.items, {}, std.sort.asc(i64));
    return out.toOwnedSlice(std.testing.allocator);
}

fn expectRefs(w: *h.Workspace, p: h.Pos, want: []const i64) !void {
    const got = try lines(try w.references("t.f90", p));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(i64, want, got);
}

test "an associate name spelled like the variable of its selector (#230)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = same_names }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", .{ .line = 12, .col = 13 }, "INTEGER :: y");
    try w.expectHoverContains("t.f90", .{ .line = 12, .col = 16 }, "REAL :: w");
    try w.expectHoverContains("t.f90", .{ .line = 15, .col = 13 }, "TYPE(inner_t) :: t");
    try w.expectHoverContains("t.f90", .{ .line = 15, .col = 15 }, "INTEGER :: a");
    const items = try w.completion("t.f90", .{ .line = 15, .col = 15 });
    var has_a = false;
    for (items) |i| if (std.mem.eql(u8, i, "a")) {
        has_a = true;
    };
    try std.testing.expect(has_a);
    // the selector is the outer `w`
    try expectRefs(w, .{ .line = 12, .col = 16 }, &.{ 11024, 12016 });
    try expectRefs(w, .{ .line = 10, .col = 10 }, &.{ 10010, 11029, 17014 });
    const def = (try w.definition("t.f90", .{ .line = 14, .col = 18 })) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 8), def.line);
}

test "renaming an associate name or the variable of its selector keeps the code valid (#230)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = same_names }}, .{});
    defer w.deinit();
    const outer = try w.rename("t.f90", .{ .line = 10, .col = 10 }, "ww");
    var cols: std.ArrayList(i64) = .empty;
    defer cols.deinit(std.testing.allocator);
    for (outer) |e| try cols.append(std.testing.allocator, e.line * 1000 + e.start);
    std.mem.sort(i64, cols.items, {}, std.sort.asc(i64));
    try std.testing.expectEqualSlices(i64, &.{ 10010, 11029, 17014 }, cols.items);
    const inner = try w.rename("t.f90", .{ .line = 12, .col = 16 }, "ww");
    cols.clearRetainingCapacity();
    for (inner) |e| try cols.append(std.testing.allocator, e.line * 1000 + e.start);
    std.mem.sort(i64, cols.items, {}, std.sort.asc(i64));
    try std.testing.expectEqualSlices(i64, &.{ 11024, 12016 }, cols.items);
}

test "the types of associate names bound to literals, expressions and intrinsic calls (#230)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program p
        \\  implicit none
        \\  integer :: x(3)
        \\  associate (r => 1.0, s => "abc", n => 7_8, e => x(1) + 2, b => size(x))
        \\    print *, r, s, n, e, b
        \\  end associate
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    // r, s, n, e and b on the print line
    const want = [_][]const u8{ "REAL :: r", "CHARACTER(LEN=3) :: s", "INTEGER(8) :: n", "INTEGER :: e", "INTEGER :: b" };
    for (want, 0..) |hover, i| {
        try w.expectHoverContains("t.f90", .{ .line = 4, .col = @intCast(13 + 3 * i) }, hover);
    }
    try w.expectNoDiagnostics("t.f90");
}

test "an associate name has the rank of its selector and the attributes it gives (#691)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine s(d)
        \\  implicit none
        \\  real, intent(in) :: d(:)
        \\  real :: b(10, 3), c(4)
        \\  real, pointer :: pt(:)
        \\  integer :: idx(2)
        \\  character(len=8) :: str
        \\  associate (sec => b(:, 1), vec => b(idx, 2), el => b(1, 2), ex => c + 1.0, sub => str(2:4), ab => abs(b), ad => d, ap => pt)
        \\    print *, sec, vec, el, ex, sub, ab, ad, ap
        \\  end associate
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    const want = [_]struct { []const u8, []const u8 }{
        .{ "sec", "REAL, DIMENSION(:) :: sec" },
        .{ "vec", "REAL, DIMENSION(:) :: vec" },
        .{ "el", "REAL :: el" },
        .{ "ex", "REAL, DIMENSION(:) :: ex" },
        .{ "sub", "CHARACTER(len=8) :: sub" },
        .{ "ab", "REAL, DIMENSION(:,:) :: ab" },
        .{ "ad", "REAL, DIMENSION(:) :: ad" },
        .{ "ap", "REAL, TARGET, DIMENSION(:) :: ap" },
    };
    for (want) |c| try w.expectHoverContains("t.f90", w.pos("t.f90", "print *,", 0, @intCast(std.mem.find(u8, "print *, sec, vec, el, ex, sub, ab, ad, ap", c[0]).?)), c[1]);
}
