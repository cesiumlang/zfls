//! Upstream issues about rename.

const std = @import("std");
const h = @import("harness.zig");

/// Whether the rename edits include one at `line` (0-based), starting at `col`
fn hasEdit(edits: []const h.Edit, line: i64, col: i64) bool {
    for (edits) |e| if (e.line == line and e.start == col) return true;
    return false;
}

test "#322 renaming a function also renames its result variable" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\contains
        \\    real pure function myfun(x)
        \\        real, intent(in), value :: x
        \\        myfun = sin(x * ((4.0 * atan(1.0)) / 180.0))
        \\    end function
        \\end module m
        \\
        \\program p
        \\    use m
        \\    print *, myfun(1.0)
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    const edits = try w.rename("t.f90", w.pos("t.f90", "myfun(x)", 0, 0), "renamed");
    const result_line = w.pos("t.f90", "myfun = sin", 0, 0);
    try h.check(322, .fixed, h.expect(
        hasEdit(edits, result_line.line, result_line.col),
        "no edit for the result variable at line {d} ({d} edits)",
        .{ result_line.line + 1, edits.len },
    ));
}

test "#322 a function with a RESULT clause keeps its result variable (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\contains
        \\    function myfun(x) result(res)
        \\        real, intent(in) :: x
        \\        real :: res
        \\        res = x
        \\    end function
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    const edits = try w.rename("t.f90", w.pos("t.f90", "myfun(x)", 0, 0), "renamed");
    // the header and the END FUNCTION name are not there: only the header
    try h.expect(edits.len == 1, "expected 1 edit, got {d}", .{edits.len});
}

test "#52 renaming the original name of a renamed import (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module rename_mod2
        \\integer :: originalname
        \\end module rename_mod2
        \\
        \\subroutine test_rename_sub()
        \\use rename_mod2, only : localname => originalname
        \\implicit none
        \\
        \\localname = 4
        \\end subroutine test_rename_sub
        \\
        ,
    }}, .{});
    defer w.deinit();
    const edits = try w.rename("t.f90", w.pos("t.f90", "integer :: originalname", 0, 11), "other");
    const decl = w.pos("t.f90", "integer :: originalname", 0, 11);
    const use_stmt = w.pos("t.f90", "=> originalname", 0, 3);
    const alias_use = w.pos("t.f90", "localname = 4", 0, 0);
    try h.expect(hasEdit(edits, decl.line, decl.col), "the declaration is not renamed", .{});
    try h.expect(hasEdit(edits, use_stmt.line, use_stmt.col), "the original name in the USE statement is not renamed", .{});
    try h.expect(!hasEdit(edits, alias_use.line, alias_use.col), "the local name is renamed too", .{});
}

test "#86 renaming a dummy argument of a function with a continued header" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\contains
        \\  function mySub(some) result(res) &
        \\      bind(c, NAME="someName")
        \\    implicit none
        \\
        \\    integer(4), intent(in) :: some
        \\    integer(4) :: res
        \\
        \\    write(*, *) some
        \\
        \\  end function mySub
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    const edits = try w.rename("t.f90", w.pos("t.f90", "some)", 0, 0), "other");
    // the argument list, the declaration and the use
    try h.check(86, .fixed, h.expect(edits.len == 3, "expected 3 edits, got {d}", .{edits.len}));
}

test "#52 renaming an imported name that was renamed on import" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module rename_mod1
        \\real(8) :: var1
        \\end module rename_mod1
        \\
        \\module rename_mod2
        \\use rename_mod1, only: renamed_var1 => var1
        \\integer :: originalname
        \\end module rename_mod2
        \\
        \\subroutine test_rename_sub()
        \\use rename_mod2, only : localname => originalname, renamed_var2 => renamed_var1
        \\implicit none
        \\
        \\localname = 4
        \\renamed_var2 = 4
        \\end subroutine test_rename_sub
        \\
        ,
    }}, .{});
    defer w.deinit();
    const edits = try w.rename("t.f90", w.pos("t.f90", "localname = 4", 0, 0), "other");
    const use_stmt = w.pos("t.f90", "localname =>", 0, 0);
    const use_line = w.pos("t.f90", "localname = 4", 0, 0);
    const declaration = w.pos("t.f90", "integer :: originalname", 0, 0);
    try h.check(52, .fixed, blk: {
        if (!hasEdit(edits, use_stmt.line, use_stmt.col)) break :blk h.unmet("the local name in the USE statement is not renamed", .{});
        if (!hasEdit(edits, use_line.line, use_line.col)) break :blk h.unmet("the use of the local name is not renamed", .{});
        for (edits) |e| if (e.line == declaration.line) break :blk h.unmet("the original name's declaration is renamed", .{});
        break :blk {};
    });
}

const trig = [_]h.File{.{ .name = "r.f90", .text =
    \\module trig
    \\  implicit none
    \\contains
    \\  function sind(x)
    \\    real, intent(in) :: x
    \\    real :: sind
    \\    sind = sin(x * 0.0174533)
    \\  end function
    \\  subroutine use_it()
    \\    print *, sind(90.0)
    \\  end subroutine
    \\  recursive function fact(n)
    \\    integer, intent(in) :: n
    \\    integer :: fact
    \\    fact = 1
    \\    if (n > 1) fact = n * fact(n - 1)
    \\    call show(fact)
    \\  end function
    \\  subroutine show(i)
    \\    integer, intent(in) :: i
    \\  end subroutine
    \\  function f(x) result(r)
    \\    real, intent(in) :: x
    \\    real :: r
    \\    r = x
    \\  end function
    \\  subroutine call_f()
    \\    print *, f(1.0), fact(3)
    \\  end subroutine
    \\end module
    \\
}};

/// The (line, column) of each place, sorted
fn sortedPlaces(comptime T: type, items: []const T) ![]const [2]i64 {
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

test "a function's implicit result variable and the function are one name in references and rename (#228)" {
    const w = try h.Workspace.init(&trig, .{});
    defer w.deinit();
    const four = [_][2]i64{ .{ 3, 11 }, .{ 5, 12 }, .{ 6, 4 }, .{ 9, 13 } };
    for ([_][2]i64{ .{ 3, 11 }, .{ 5, 12 }, .{ 6, 4 }, .{ 9, 13 } }) |at| {
        const p: h.Pos = .{ .line = at[0], .col = at[1] };
        try expectSorted(&four, try sortedPlaces(h.Location, try w.references("r.f90", p)));
        try expectSorted(&four, try sortedPlaces(h.Edit, try w.rename("r.f90", p, "sin_deg")));
    }
}

test "a recursive function names itself in its body; RESULT keeps the two apart (#228)" {
    const w = try h.Workspace.init(&trig, .{});
    defer w.deinit();
    // `fact` without RESULT: the statement, the declaration, the body (also
    // as an actual argument and in its recursive call) and the call
    const fact = try sortedPlaces(h.Location, try w.references("r.f90", w.pos("r.f90", "fact = 1", 0, 0)));
    defer std.testing.allocator.free(fact);
    try std.testing.expectEqual(7, fact.len);
    // `r`: only `r`; `f`: the statement and the call
    try expectSorted(&.{ .{ 21, 23 }, .{ 23, 12 }, .{ 24, 4 } }, try sortedPlaces(h.Location, try w.references("r.f90", w.pos("r.f90", "r = x", 0, 0))));
    try expectSorted(&.{ .{ 21, 11 }, .{ 27, 13 } }, try sortedPlaces(h.Location, try w.references("r.f90", w.pos("r.f90", "f(x)", 0, 0))));
}

const renamed_through = [_]h.File{
    .{ .name = "a.f90", .text =
    \\module a
    \\  implicit none
    \\  interface
    \\    subroutine e1(x)
    \\      integer, intent(in) :: x
    \\    end subroutine
    \\  end interface
    \\contains
    \\  subroutine p1(x)
    \\    integer, intent(in) :: x
    \\  end subroutine p1
    \\end module a
    \\
    },
    .{ .name = "b.f90", .text =
    \\module b
    \\  use a, only: q1 => p1, r1 => e1
    \\  implicit none
    \\contains
    \\  subroutine inside()
    \\    call q1(1)
    \\  end subroutine
    \\end module b
    \\
    },
    .{ .name = "c.f90", .text =
    \\program c
    \\  use b
    \\  implicit none
    \\  call q1(2)
    \\  call r1(3)
    \\end program c
    \\
    },
    .{ .name = "d.f90", .text =
    \\module d
    \\  use b
    \\end module d
    \\program e
    \\  use d
    \\  call q1(4)
    \\end program e
    \\
    },
};

/// The number of `edits` in file `name`
fn editsIn(edits: []const h.Edit, name: []const u8) usize {
    var n: usize = 0;
    for (edits) |e| if (std.mem.endsWith(u8, e.uri, name)) {
        n += 1;
    };
    return n;
}

test "rename of a USE-renamed name from a further user changes the local name, not the original (#480)" {
    const w = try h.Workspace.init(&renamed_through, .{});
    defer w.deinit();
    // from a user of the module that renames, of a user of that one, and
    // inside the module: the local name in the rename and its uses
    for ([_]struct { []const u8, []const u8 }{
        .{ "c.f90", "q1(2)" },
        .{ "d.f90", "q1(4)" },
        .{ "b.f90", "q1(1)" },
    }) |at| {
        const edits = try w.rename(at[0], w.pos(at[0], at[1], 0, 0), "local");
        const in = [_]usize{ editsIn(edits, "a.f90"), editsIn(edits, "b.f90"), editsIn(edits, "c.f90"), editsIn(edits, "d.f90") };
        try h.expect(edits.len == 4 and in[0] == 0 and in[1] == 2 and in[2] == 1 and in[3] == 1, "rename of q1 from {s}: {d} edits, {any} by file, not 0, 2, 1, 1", .{ at[1], edits.len, in });
        for (edits) |e| try h.expect(!std.mem.endsWith(u8, e.uri, "b.f90") or e.line != 1 or e.start == 15, "b.f90's USE statement edited at {d}", .{e.start});
    }
    // an interface body renamed so (#474: a name of the module)
    const r = try w.rename("c.f90", w.pos("c.f90", "r1(3)", 0, 0), "local");
    try h.expect(r.len == 2 and editsIn(r, "b.f90") == 1 and editsIn(r, "c.f90") == 1, "rename of r1: {d} edits", .{r.len});
    // from the original name: the original only
    const p = try w.rename("a.f90", w.pos("a.f90", "subroutine p1", 0, 11), "orig");
    try h.expect(p.len == 3 and editsIn(p, "a.f90") == 2 and editsIn(p, "b.f90") == 1, "rename of p1: {d} edits, {d} in a.f90, {d} in b.f90", .{ p.len, editsIn(p, "a.f90"), editsIn(p, "b.f90") });
    for ([_][]const u8{ "a.f90", "b.f90", "c.f90", "d.f90" }) |name| try w.expectNoDiagnostics(name);
}

test "a rename to a name already taken is refused (#953)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = "module m\n  implicit none\ncontains\n  subroutine f()\n  end subroutine\n  subroutine base_run()\n  end subroutine\nend module m\n" },
        .{ .name = "p.f90", .text = "program p\n  use m\n  implicit none\n  integer :: total\n  call f()\nend program p\n" },
    }, .{});
    defer w.deinit();
    try w.open("m.f90", "fortran");
    try std.testing.expectEqual(@as(usize, 0), (try w.rename("m.f90", w.pos("m.f90", "f()", 0, 0), "base_run")).len);
    // a name of a scope that uses it
    try std.testing.expectEqual(@as(usize, 0), (try w.rename("m.f90", w.pos("m.f90", "f()", 0, 0), "total")).len);
    // a free name, or a change of case
    try std.testing.expect((try w.rename("m.f90", w.pos("m.f90", "f()", 0, 0), "solve")).len > 0);
    try std.testing.expect((try w.rename("m.f90", w.pos("m.f90", "f()", 0, 0), "F")).len > 0);
}

test "renaming an override from its call renames the bindings it overrides (#953)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module shapes
        \\  implicit none
        \\  type :: base
        \\  contains
        \\    procedure :: run => base_run
        \\  end type
        \\  type, extends(base) :: child
        \\  contains
        \\    procedure :: run => child_run
        \\  end type
        \\contains
        \\  subroutine base_run(self)
        \\    class(base), intent(in) :: self
        \\  end subroutine
        \\  subroutine child_run(self)
        \\    class(child), intent(in) :: self
        \\  end subroutine
        \\  subroutine use_it(c)
        \\    type(child), intent(in) :: c
        \\    call c%run()
        \\  end subroutine
        \\end module shapes
        \\
    }}, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    const edits = try w.rename("t.f90", w.pos("t.f90", "run()", 0, 0), "go");
    try std.testing.expect(hasEdit(edits, 4, 17));
    try std.testing.expect(hasEdit(edits, 8, 17));
    try std.testing.expect(hasEdit(edits, 19, 11));
}
