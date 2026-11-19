//! Upstream issues about construct names and statement labels.

const std = @import("std");
const h = @import("harness.zig");

const loops =
    \\subroutine s(a, n)
    \\  integer :: n, i, j
    \\  real :: a(n, n)
    \\  outer: do i = 1, n
    \\    inner: do j = 1, n
    \\      if (a(i, j) < 0) cycle outer
    \\      if (a(i, j) > 9) exit inner
    \\      check: if (a(i, j) == 0) then
    \\        exit outer
    \\      end if check
    \\    end do inner
    \\  end do outer
    \\end subroutine s
    \\
;

fn expectConstructNames(w: *h.Workspace) !void {
    const use = w.pos("s.f90", "cycle outer", 0, 6);
    const def = (try w.definition("s.f90", use)) orelse return h.unmet("no definition of outer", .{});
    try h.expect(def.line == 3 and def.col == 2, "definition of outer at {d}:{d}", .{ def.line, def.col });
    const refs = try w.references("s.f90", use);
    try h.expect(refs.len == 4, "{d} references to outer, not 4", .{refs.len});
    const edits = try w.rename("s.f90", w.pos("s.f90", "end do inner", 0, 8), "rows");
    try h.expect(edits.len == 3, "{d} edits renaming inner, not 3", .{edits.len});
    for (edits) |e| try h.expect(std.mem.eql(u8, e.new_text, "rows"), "edit to {s}", .{e.new_text});
}

test "#424 go to definition, references and rename of construct names" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = loops }}, .{});
    defer w.deinit();
    try h.check(424, .fixed, expectConstructNames(w));
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn expectCompletion(w: *h.Workspace) !void {
    // EXIT: any construct open there; CYCLE: only DO constructs
    const exits = try w.completion("s.f90", w.pos("s.f90", "exit outer", 0, 5));
    for ([_][]const u8{ "check", "inner", "outer" }) |n| try h.expect(contains(exits, n), "exit does not offer {s}", .{n});
    const cycles = try w.completion("s.f90", w.pos("s.f90", "cycle outer", 0, 6));
    try h.expect(contains(cycles, "outer") and contains(cycles, "inner"), "cycle does not offer the loops", .{});
    try h.expect(!contains(cycles, "check"), "cycle offers an IF construct", .{});
}

test "hansec #157 construct names are completed after EXIT and CYCLE" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = loops }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 157, .fixed, expectCompletion(w));
}

test "statement labels: definition and references" {
    const w = try h.Workspace.init(&.{.{ .name = "old.f", .text =
        \\      SUBROUTINE OLD(N)
        \\      INTEGER N, I
        \\      DO 10 I = 1, N
        \\        IF (I .GT. 5) GO TO 20
        \\        WRITE (6, 100) I
        \\   10 CONTINUE
        \\   20 RETURN
        \\  100 FORMAT (I5)
        \\      END
        \\
    }}, .{});
    defer w.deinit();
    const def = (try w.definition("old.f", w.pos("old.f", "GO TO 20", 0, 6))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 6), def.line);
    const fmt = (try w.definition("old.f", w.pos("old.f", "(6, 100)", 0, 4))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 7), fmt.line);
    try std.testing.expectEqual(@as(usize, 2), (try w.references("old.f", w.pos("old.f", "DO 10", 0, 3))).len);
}

const branch_names =
    \\subroutine s(i, a)
    \\  implicit none
    \\  integer :: i
    \\  real :: a(3)
    \\  n1: if (i > 0) then
    \\    i = 1
    \\  else if (i < -1) then n1
    \\    i = 2
    \\  else n1
    \\    i = 3
    \\  end if n1
    \\  n2: select case (i)
    \\  case (1) n2
    \\    i = 4
    \\  case default n2
    \\    i = 5
    \\  end select n2
    \\  n6: where (a > 0)
    \\    a = 1
    \\  elsewhere (a < -1) n6
    \\    a = 2
    \\  elsewhere n6
    \\    a = 3
    \\  end where n6
    \\  n7: if (i > 0) then
    \\  else if (j < 0) then n7
    \\  end if n7
    \\end subroutine
    \\
;

test "construct names on ELSE, CASE and ELSEWHERE statements are no undeclared names (#241)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = branch_names }}, .{});
    defer w.deinit();
    const diags = try w.diagnostics("s.f90");
    // only the truly undeclared `j`
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(i64, 25), diags[0].line);
    try std.testing.expect(std.mem.find(u8, diags[0].message, "\"j\"") != null);
}

const selectcase_one_word =
    \\subroutine one(i)
    \\  integer :: i
    \\  selectcase (i)
    \\  case (1)
    \\    i = 2
    \\  case default
    \\    i = 3
    \\  endselect
    \\end subroutine
    \\subroutine named(i)
    \\  integer :: i
    \\  n1: selectcase (i)
    \\  case (1) n1
    \\    i = 2
    \\  endselect n1
    \\end subroutine
    \\
;

fn hasFold(folds: []const h.Fold, start: i64, end: i64) bool {
    for (folds) |f| if (f.start == start and f.end == end) return true;
    return false;
}

test "SELECT CASE written as one word: its branches fold and its name has references (#241)" {
    const w = try h.Workspace.init(&.{.{ .name = "s.f90", .text = selectcase_one_word }}, .{});
    defer w.deinit();
    const folds = try w.foldingRanges("s.f90");
    try std.testing.expect(hasFold(folds, 3, 4));
    try std.testing.expect(hasFold(folds, 5, 6));
    for ([_]h.Pos{ .{ .line = 11, .col = 2 }, .{ .line = 14, .col = 12 } }) |p| {
        const refs = try w.references("s.f90", p);
        try std.testing.expectEqual(@as(usize, 3), refs.len);
        const def = (try w.definition("s.f90", p)) orelse return error.NoDefinition;
        try std.testing.expectEqual(@as(i64, 11), def.line);
        try std.testing.expectEqual(@as(usize, 3), (try w.linkedEditing("s.f90", p)).len);
    }
}
