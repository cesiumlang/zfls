//! A compiler's column of a message on a line with TABs (DEC's TAB format,
//! #491) as the line's byte, for the message's range (#584): gfortran
//! counts a line's first TAB as the columns up to 6 (up to 5 before a
//! continuation digit, which is column 6) and every other character as
//! one; Intel's compilers count each TAB as the columns to the next stop of
//! 8 (their caret line); LLVM Flang, LFortran and the others count a TAB
//! as one column, as the byte it is (ifx 2026.2, gfortran 16.1, Flang 23).

const std = @import("std");
const compilers = @import("../compilers.zig");
const helpers = @import("../helpers.zig");

/// The 1-based byte column of `line` for compiler `id`'s 1-based `column`
pub fn byteColumn(id: compilers.Id, line: []const u8, column: usize) usize {
    if (std.mem.findScalar(u8, line, '\t') == null) return column;
    return switch (id) {
        .gfortran => gfortran(line, column),
        .ifx, .ifort => stops(line, column),
        else => column,
    };
}

fn gfortran(line: []const u8, column: usize) usize {
    const i = helpers.tabFormatTab(line) orelse return column;
    // after the TAB, a continuation digit in column 6, or the statement in 7
    const width: usize = if (helpers.tabContStart(line) != null) 5 else 6;
    if (column <= i) return column;
    return if (column <= width) i + 1 else i + 1 + column - width;
}

fn stops(line: []const u8, column: usize) usize {
    var at: usize = 1;
    for (line, 1..) |c, byte| {
        const next = if (c == '\t') (at - 1) / 8 * 8 + 9 else at + 1;
        if (column < next) return byte;
        at = next;
    }
    return line.len + (column - at) + 1;
}

test "a compiler's column on a TAB-format line as the byte" {
    const t = std.testing;
    // `\t1 JUNDEF`: gfortran 16.1 `5:13` (the name's last letter), ifx's
    // caret `----------^` (column 11, its first), Flang 23 `5:4`
    const cont = "\t1 JUNDEF";
    try t.expectEqual(@as(usize, 9), byteColumn(.gfortran, cont, 13));
    try t.expectEqual(@as(usize, 4), byteColumn(.ifx, cont, 11));
    try t.expectEqual(@as(usize, 4), byteColumn(.flang, cont, 4));
    // `\tI = 1 +`: the statement in column 7 for gfortran, 9 for Intel's
    const stmt = "\tI = 1 +";
    try t.expectEqual(@as(usize, 2), byteColumn(.gfortran, stmt, 7));
    try t.expectEqual(@as(usize, 2), byteColumn(.ifort, stmt, 9));
    try t.expectEqual(@as(usize, 1), byteColumn(.gfortran, stmt, 3));
    // after a label: `10<TAB>X`, X in column 7
    try t.expectEqual(@as(usize, 4), byteColumn(.gfortran, "10\tX = 1", 7));
    // a line without TABs, and one whose TAB is not first
    try t.expectEqual(@as(usize, 13), byteColumn(.gfortran, "      I = JUNDEF", 13));
    try t.expectEqual(@as(usize, 12), byteColumn(.gfortran, "      X =\tY", 12));
    try t.expectEqual(@as(usize, 11), byteColumn(.ifx, "      X =\tY", 17));
}
