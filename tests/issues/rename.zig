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
