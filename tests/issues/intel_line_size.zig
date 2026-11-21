//! ifx's `!DEC$ FIXEDFORMLINESIZE:n`: the line length of the fixed-form
//! lines after it (#511; the ifx audit, #489).

const std = @import("std");
const h = @import("harness.zig");

// ifx: `error #6404 ... [UNDECL]` only; a name past column 72 is cut
// before the first directive by fixed_line_length (ifx's default: 72)
const text = "      PROGRAM FL\n" ++
    "      IMPLICIT NONE\n" ++
    "      INTEGER I\n" ++
    "      I = 1                                                             + IGNORED1\n" ++
    "CDEC$ FIXEDFORMLINESIZE:132\n" ++
    "      I = 1                                                            + UNDECL\n" ++
    "!DEC$ FIXEDFORMLINESIZE:72\n" ++
    "      I = 2                                                             + IGNORED2\n" ++
    "      PRINT *, I\n" ++
    "      END\n";

test "FIXEDFORMLINESIZE sets the line length of the lines after it" {
    const w = try h.Workspace.init(&.{.{ .name = "fls.f", .text = text }}, .{ .settings = .{ .fixed_line_length = 72 } });
    defer w.deinit();
    const ds = try w.diagnostics("fls.f");
    try h.expect(ds.len == 1, "{d} diagnostics, the first: {s}", .{ ds.len, if (ds.len > 0) ds[0].message else "" });
    try std.testing.expectEqual(@as(i64, 5), ds[0].line);
    try std.testing.expectEqualStrings("Name \"UNDECL\" is not declared (IMPLICIT NONE)", ds[0].message);
}

test "FIXEDFORMLINESIZE in a file that switches forms" {
    const switched = text ++ "!DEC$ FREEFORM\n";
    const w = try h.Workspace.init(&.{.{ .name = "fls.f", .text = switched }}, .{ .settings = .{ .fixed_line_length = 72 } });
    defer w.deinit();
    const ds = try w.diagnostics("fls.f");
    try h.expect(ds.len == 1, "{d} diagnostics, the first: {s}", .{ ds.len, if (ds.len > 0) ds[0].message else "" });
    try std.testing.expectEqual(@as(i64, 5), ds[0].line);
}
