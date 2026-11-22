//! The blocks of SELECT TYPE and SELECT RANK: each guard's block is a
//! sibling of the one before (#708); the associate name of a RANK block
//! has its rank (#706); argument checking takes a guard name's (#707).

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");

const gpa = std.testing.allocator;

const guards =
    \\subroutine g(items, n)
    \\  class(*), intent(in) :: items(:)
    \\  integer :: n
    \\  select type (it => items)
    \\  type is (integer)
    \\    select case (n)
    \\    case (1)
    \\      print *, it(1)
    \\    end select
    \\    print *, it(2)
    \\  type is (real)
    \\    print *, it(3)
    \\  class default
    \\    print *, size(it)
    \\  end select
    \\end subroutine
    \\
;

test "each guard's block is in its SELECT TYPE, not in the guard before (#708)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = guards }}, .{});
    defer w.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try zfls.debug.runTo(gpa, std.testing.io, .{ .debug_parser = true, .debug_filepath = try w.path("t.f90"), .debug_rootpath = w.root }, .{ .a = gpa, .out = &out });
    const decls = out.items[std.mem.find(u8, out.items, "Declarations").?..];
    for ([_][]const u8{
        "g::#select1::#select2::it: INTEGER, DIMENSION(:) :: it\n",
        "g::#select1::#select4::it: REAL, DIMENSION(:) :: it\n",
        "g::#select1::#select5::it: CLASS(*), DIMENSION(:) :: it\n",
    }) |want| if (std.mem.find(u8, decls, want) == null) {
        std.debug.print("\n'{s}' not in:\n{s}\n", .{ want, decls });
        return error.TestExpectedEqual;
    };
    // the SELECT CASE in a guard makes no associate name
    try std.testing.expectEqual(3, std.mem.count(u8, decls, "::it:"));
}

test "a SELECT CASE in a guard's block leaves the guard open (#708)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = guards }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "it(1)", 0, 0), "INTEGER, DIMENSION(:) :: it");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "it(2)", 0, 0), "INTEGER, DIMENSION(:) :: it");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "it(3)", 0, 0), "REAL, DIMENSION(:) :: it");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "size(it)", 0, 5), "CLASS(*), DIMENSION(:) :: it");
}

test "SELECT RANK: each block's name has the block's rank and the selector's attributes (#706)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\subroutine s(a, p, al)
        \\  real, intent(in) :: a(..)
        \\  real, pointer :: p(..)
        \\  real, allocatable :: al(..)
        \\  select rank (r => a)
        \\  rank (0)
        \\    print *, r
        \\  rank (2)
        \\    print *, r(1, 1)
        \\  rank (*)
        \\    print *, r(1)
        \\  rank default
        \\    print *, rank(r)
        \\  end select
        \\  select rank (p)
        \\  rank (1)
        \\    print *, p(1)
        \\  end select
        \\  select rank (q => al)
        \\  rank (3) ! a comment (x)
        \\    print *, q(1, 1, 1)
        \\  end select
        \\end subroutine
        \\
    }}, .{});
    defer w.deinit();
    const want = [_]struct { []const u8, []const u8 }{
        .{ "r\n", "REAL :: r" },
        .{ "r(1, 1)", "REAL, DIMENSION(:,:) :: r" },
        .{ "r(1)", "REAL, DIMENSION(*) :: r" },
        .{ "r)", "REAL, DIMENSION(..) :: r" },
        .{ "p(1)", "REAL, POINTER, DIMENSION(:) :: p" },
        .{ "q(1, 1, 1)", "REAL, ALLOCATABLE, DIMENSION(:,:,:) :: q" },
    };
    for (want) |c| try w.expectHoverContains("t.f90", w.pos("t.f90", c[0], 0, 0), c[1]);
}

test "argument checking takes a TYPE IS name's rank and type (#707)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  subroutine takes_s(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine t(items)
        \\    class(*), intent(in) :: items(:)
        \\    select type (it => items)
        \\    type is (real)
        \\      call takes_s(it)
        \\      call takes_v(it)
        \\      call takes_s(it(1))
        \\    type is (integer)
        \\      call takes_s(it(1))
        \\    end select
        \\    select type (el => items(2))
        \\    type is (real)
        \\      call takes_s(el)
        \\    end select
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 report lines 14 and 18
    // alone: "Rank mismatch in argument 'x' at (1) (scalar and rank-1)",
    // "Type mismatch in argument 'x' at (1); passed INTEGER(4) to REAL(4)"
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(gpa);
    for (try w.diagnostics("t.f90")) |d| try got.append(gpa, try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    const want = [_][]const u8{
        "14: Argument x of takes_s: a scalar expected, an array given",
        "18: Argument x of takes_s: real expected, integer given",
    };
    if (got.items.len != want.len) {
        std.debug.print("got: {any}\n", .{got.items});
        return error.TestExpectedEqual;
    }
    for (want, got.items) |x, y| try std.testing.expectEqualStrings(x, y);
}
