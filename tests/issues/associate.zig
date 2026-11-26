//! ASSOCIATE constructs (#230): named ones, an associate name spelled like
//! the variable of its selector, and the types of names bound to literals
//! and expressions; argument checking takes an associate name's rank and
//! type (#714).

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

test "argument checking takes an associate name's rank and its selector's type (#714)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  type :: box
        \\    real :: arr(4)
        \\  end type
        \\contains
        \\  subroutine takes_s(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_c(c)
        \\    character(len=*), intent(in) :: c
        \\  end subroutine
        \\  subroutine t(a2, x, n, d, bx, idx, str, names)
        \\    real, intent(in) :: a2(10, 3), x
        \\    integer, intent(in) :: n, idx(2)
        \\    double precision, intent(in) :: d
        \\    type(box), intent(in) :: bx
        \\    character(len=8), intent(in) :: str, names(3)
        \\    associate (b => a2(:, 1), c => a2, s => x, i => n, dd => d, q => bx%arr, vv => a2(idx, 2), el => a2(1, 1))
        \\      call takes_s(b)
        \\      call takes_v(b)
        \\      call takes_s(b(1))
        \\      call takes_s(c)
        \\      call takes_s(c(1, 1))
        \\      call takes_s(s)
        \\      call takes_s(i)
        \\      call takes_s(dd)
        \\      call takes_s(q)
        \\      call takes_v(q)
        \\      call takes_s(vv)
        \\      call takes_v(vv)
        \\      call takes_s(el)
        \\      associate (e => b, f => c(2, :), g => el)
        \\        call takes_s(e)
        \\        call takes_v(e)
        \\        call takes_s(f)
        \\        call takes_v(f)
        \\        call takes_s(g)
        \\      end associate
        \\    end associate
        \\    associate (sub => str(2:4), nm => names, nm1 => names(2))
        \\      call takes_c(sub)
        \\      call takes_c(sub(1:1))
        \\      call takes_c(nm)
        \\      call takes_c(nm(1))
        \\      call takes_c(nm1)
        \\      call takes_c(nm1(1:2))
        \\    end associate
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 report these lines alone:
    // "Rank mismatch in argument 'x' at (1) (scalar and rank-1)", "Type
    // mismatch in argument 'x' at (1); passed INTEGER(4) to REAL(4)", ...
    try w.expectDiagnostics("t.f90", &.{
        "23: Argument x of takes_s: a scalar expected, an array given",
        "26: Argument x of takes_s: a scalar expected, an array given",
        "29: Argument x of takes_s: real expected, integer given",
        "30: Argument x of takes_s: REAL(4) expected, REAL(8) given",
        "31: Argument x of takes_s: a scalar expected, an array given",
        "33: Argument x of takes_s: a scalar expected, an array given",
        "37: Argument x of takes_s: a scalar expected, an array given",
        "39: Argument x of takes_s: a scalar expected, an array given",
        "47: Argument c of takes_c: a scalar expected, an array given",
    });
}

test "SELECT TYPE: TYPE IS and CLASS IS names have the selector's rank and the guard's type (#701)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  type :: base_t
        \\    integer :: id = 0
        \\  end type
        \\  type, extends(base_t) :: child_t
        \\    real :: value = 0.0
        \\  end type
        \\contains
        \\  subroutine s(items, ptrs, any)
        \\    class(base_t), intent(in) :: items(:)
        \\    class(base_t), pointer :: ptrs(:, :)
        \\    class(*), intent(in) :: any(:)
        \\    select type (it => items)
        \\    type is (base_t)
        \\      print *, size(it)
        \\    class is (child_t)
        \\      print *, size(it)
        \\    class default
        \\      print *, size(it)
        \\    end select
        \\    select type (el => items(1))
        \\    type is (child_t)
        \\      print *, el%value
        \\    end select
        \\    select type (pp => ptrs)
        \\    type is (child_t)
        \\      print *, pp(1, 1)%value
        \\    end select
        \\    select type (items)
        \\    type is (child_t)
        \\      print *, items(1)%value
        \\    class default
        \\      print *, size(items)
        \\    end select
        \\    select type (x => any)
        \\    type is (real(8))
        \\      call takes(x)
        \\    type is (character(len=*))
        \\      print *, x(2)
        \\    end select
        \\  end subroutine
        \\  subroutine takes(v)
        \\    real(8), intent(in) :: v(:)
        \\    print *, v
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    const want = [_]struct { []const u8, usize, []const u8 }{
        .{ "size(it)", 0, "TYPE(base_t), DIMENSION(:) :: it" },
        .{ "size(it)", 1, "CLASS(child_t), DIMENSION(:) :: it" },
        .{ "size(it)", 2, "CLASS(base_t), DIMENSION(:) :: it" },
        .{ "el%value", 0, "TYPE(child_t) :: el" },
        .{ "pp(1, 1)", 0, "TYPE(child_t), TARGET, DIMENSION(:, :) :: pp" },
        .{ "items(1)%value", 0, "TYPE(child_t), DIMENSION(:) :: items" },
        .{ "size(items)", 0, "CLASS(base_t), DIMENSION(:) :: items" },
        .{ "takes(x)", 0, "REAL(8), DIMENSION(:) :: x" },
        .{ "x(2)", 0, "CHARACTER(len=*), DIMENSION(:) :: x" },
    };
    for (want) |c| {
        const plus: usize = if (std.mem.startsWith(u8, c[0], "size(")) 5 else if (std.mem.startsWith(u8, c[0], "takes(")) 6 else 0;
        try w.expectHoverContains("t.f90", w.pos("t.f90", c[0], c[1], plus), c[2]);
    }
    // an intrinsic guard's name is of that type, not a derived one
    try w.expectNoDiagnostics("t.f90");
}

test "a type guard outside SELECT TYPE, with a declaration in it, as while editing (#701)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine s(a)
        \\  class(*) :: a
        \\  type is (real)
        \\    real :: v
        \\    print *, v
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "v\n", 1, 0), "REAL :: v");
}

test "an ASSOCIATE selector ending in a subscripted component has its type, a function call its result's (#721)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m_assoc
        \\  implicit none
        \\  type :: inner
        \\    real :: c(4) = 0
        \\  end type
        \\  type :: outer
        \\    type(inner) :: b(3)
        \\  end type
        \\contains
        \\  subroutine takes_real(v)
        \\    real, intent(in) :: v
        \\    print *, v
        \\  end subroutine
        \\  function mk() result(r)
        \\    type(inner) :: r
        \\    r%c = 1
        \\  end function
        \\  type(inner) function mk2()
        \\    mk2%c = 2
        \\  end function
        \\  subroutine s(a)
        \\    type(outer), intent(inout) :: a
        \\    associate (y => a%b(2)%c(1), z => mk(), f => a%b(:)%c(1), u => mk2())
        \\      call takes_real(y)
        \\      call takes_real(a%b(2)%c(1))
        \\      print *, z%c, f, u%c
        \\    end associate
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // as gfortran, Flang and ifx accept it
    try w.expectNoDiagnostics("t.f90");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "y)\n", 0, 0), "REAL :: y");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "f, u%c", 0, 0), "REAL, DIMENSION(:) :: f");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "z%c", 0, 0), "TYPE(inner) :: z");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "z%c", 0, 2), "REAL, DIMENSION(4) :: c");
    const def = (try w.definition("t.f90", w.pos("t.f90", "z%c", 0, 2))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 3), def.line);
    try w.expectHoverContains("t.f90", w.pos("t.f90", "u%c", 0, 0), "TYPE(inner) :: u");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "u%c", 0, 2), "REAL, DIMENSION(4) :: c");
}

test "an ASSOCIATE selector of a component's element of another type is checked by that type (#721)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m_assoc
        \\  implicit none
        \\  type :: inner
        \\    integer :: c(4) = 0
        \\  end type
        \\  type :: outer
        \\    type(inner) :: b(3)
        \\  end type
        \\contains
        \\  subroutine takes_real(v)
        \\    real, intent(in) :: v
        \\    print *, v
        \\  end subroutine
        \\  subroutine s(a)
        \\    type(outer), intent(inout) :: a
        \\    associate (y => a%b(2)%c(1))
        \\      call takes_real(y)
        \\    end associate
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // as gfortran, Flang and ifx report it
    try w.expectDiagnostics("t.f90", &.{"17: Argument v of takes_real: real expected, integer given"});
}
