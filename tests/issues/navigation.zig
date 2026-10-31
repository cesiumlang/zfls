//! Navigation requests zfls answers beyond fortls: prepareRename,
//! selection ranges and document links.

const std = @import("std");
const h = @import("harness.zig");

const files = [_]h.File{
    .{ .name = "consts.h", .text =
    \\#define N 4
    \\
    },
    .{ .name = "body.inc", .text =
    \\x = 1
    \\
    },
    .{ .name = "m.F90", .text =
    \\module m
    \\#include "consts.h"
    \\  implicit none
    \\contains
    \\  subroutine s(x, y)
    \\    real, intent(inout) :: x, y
    \\    integer :: i
    \\    do i = 1, N
    \\      y = max(x, y * 2.0) + &
    \\        1.0
    \\    end do
    \\    include 'body.inc'
    \\  end subroutine s
    \\end module m
    \\
    },
};

test "prepareRename: the name to rename, or nothing for an intrinsic or a keyword" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const p = (try w.prepareRename("m.F90", w.pos("m.F90", "y * 2.0", 0, 0))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("y", p.placeholder);
    try std.testing.expectEqual(w.pos("m.F90", "y * 2.0", 0, 0).line, p.line);
    try std.testing.expect((try w.prepareRename("m.F90", w.pos("m.F90", "max(", 0, 1))) == null);
    try std.testing.expect((try w.prepareRename("m.F90", w.pos("m.F90", "implicit", 0, 1))) == null);
}

test "selection ranges grow from the name to its parentheses, statement, constructs, procedure, module and file" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const at = w.pos("m.F90", "max(x", 0, 4);
    const sels = try w.selectionRanges("m.F90", at);
    // x, the arguments, the parenthesized arguments, the statement
    // (continued on the next line), DO, subroutine, module, file
    try std.testing.expect(sels.len >= 8);
    try std.testing.expectEqual(h.Workspace.Sel{ .sl = at.line, .sc = at.col, .el = at.line, .ec = at.col + 1 }, sels[0]);
    const stmt = sels[3];
    try std.testing.expectEqual(at.line, stmt.sl);
    try std.testing.expectEqual(at.line + 1, stmt.el);
    const do_line = w.pos("m.F90", "do i", 0, 0).line;
    try std.testing.expectEqual(do_line, sels[4].sl);
    const last = sels[sels.len - 1];
    try std.testing.expectEqual(@as(i64, 0), last.sl);
    for (sels[1..], sels[0 .. sels.len - 1]) |outer, inner| {
        try std.testing.expect(outer.sl < inner.sl or (outer.sl == inner.sl and outer.sc <= inner.sc));
        try std.testing.expect(outer.el > inner.el or (outer.el == inner.el and outer.ec >= inner.ec));
    }
}

test "document links on the files of #include and INCLUDE" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const links = try w.documentLinks("m.F90");
    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expect(std.mem.endsWith(u8, links[0].target, "/consts.h"));
    try std.testing.expectEqual(w.pos("m.F90", "consts.h", 0, 0).col, links[0].start);
    try std.testing.expect(std.mem.endsWith(u8, links[1].target, "/body.inc"));
}
