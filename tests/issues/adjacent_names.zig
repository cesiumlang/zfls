//! References and rename find a name that follows the same name after one
//! character (`i*i`, `a(i,i)`), not only after two (#844).

const std = @import("std");
const h = @import("harness.zig");

fn hasEdit(edits: []const h.Edit, line: i64, col: i64) bool {
    for (edits) |e| if (e.line == line and e.start == col) return true;
    return false;
}

fn hasRef(refs: []const h.Location, line: i64, col: i64) bool {
    for (refs) |r| if (r.line == line and r.col == col) return true;
    return false;
}

test "a name after the same name and one operator is found (#844)" {
    inline for (.{ "*", "+", "-", "/", ",", "**", " + " }) |op| {
        const text = "program p\n  implicit none\n  integer :: i, a(3,3), s\n  s = a(i,i) + i" ++ op ++ "i\nend program\n";
        const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
        defer w.deinit();
        const at = w.pos("t.f90", "i, a(3,3)", 0, 0);
        const refs = try w.references("t.f90", at);
        const edits = try w.rename("t.f90", at, "jj");
        // `a(i,i)` (columns 8 and 10) and `i<op>i` (14 and 15 + op length)
        const second: i64 = 15 + @as(i64, op.len);
        inline for (.{ 8, 10, 14, second }) |c| {
            try std.testing.expect(hasRef(refs, 3, c));
            try std.testing.expect(hasEdit(edits, 3, c));
        }
    }
}

test "the middle name of three in a row is found (#844)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = "program p\n  implicit none\n  integer :: ab, s\n  s = ab*ab*ab\nend program\n" }}, .{});
    defer w.deinit();
    const edits = try w.rename("t.f90", w.pos("t.f90", "ab, s", 0, 0), "cd");
    for ([_]i64{ 6, 9, 12 }) |c| try std.testing.expect(hasEdit(edits, 3, c));
}
