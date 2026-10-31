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
