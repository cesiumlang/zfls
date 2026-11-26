//! The columns of a fixed-form line past `fixed_line_length`, which the
//! compilers read as a comment (gfortran's `-ffixed-line-length-n`,
//! Flang's `-ffixed-line-length=n`, ifx's `-extend-source`): blanks in the
//! lines zfls reads, so that they declare nothing and name nothing (#553).
//! Every other column stays where it is. A comment line and a preprocessor
//! directive keep their columns: the preprocessor reads a whole line, and a
//! documentation comment is read for hover.

const std = @import("std");
const helpers = @import("../helpers.zig");

/// Whether fixed-form code line `line` reaches past `columns`
pub fn isLong(line: []const u8, columns: usize) bool {
    return line.len > columns and !helpers.isFixedComment(line) and !helpers.isPpDirective(line);
}

/// Makes the columns of fixed-form code line `line` past `columns` blanks
pub fn blank(line: []u8, columns: usize) void {
    if (isLong(line, columns)) @memset(line[columns..], ' ');
}

/// The bytes of `line` within `columns`: `columns`, but on a TAB-format
/// line whose TAB the compiler counts as the columns up to 6 (`wide`, as
/// gfortran and LLVM Flang do; up to 5 before a continuation digit, which
/// is column 6) as many fewer as the TAB stands for beyond one (#585)
pub fn tabLimit(line: []const u8, columns: usize, wide: bool) usize {
    if (!wide or columns < 6) return columns;
    const i = helpers.tabFormatTab(line) orelse return columns;
    const cont = helpers.tabContStart(line) != null;
    // bytes up to the TAB, the TAB (and the digit), then columns 7 and on
    return i + 1 + @intFromBool(cont) + (columns - 6);
}

/// `line` without the columns past `columns` when it is a code line
pub fn code(line: []const u8, columns: ?usize) []const u8 {
    const n = columns orelse return line;
    return if (isLong(line, n)) line[0..n] else line;
}

test "a TAB-format line's limit, as gfortran and Flang count its TAB" {
    // ll.f: `<TAB>IA = 1 ... + UNDECL`, UNDECL in columns 70 to 75 for
    // gfortran and Flang with -ffixed-line-length 72: they read `UND`
    const ll = "\tIA = 1                                                       + UNDECL";
    try std.testing.expectEqual(@as(usize, 72), tabLimit(ll, 72, false));
    try std.testing.expectEqual(@as(usize, 67), tabLimit(ll, 72, true));
    try std.testing.expectEqualStrings("UND", code(ll, tabLimit(ll, 72, true))[64..]);
    // a continuation digit is column 6; after a label the TAB still ends at 6
    try std.testing.expectEqual(@as(usize, 68), tabLimit("\t1 X", 72, true));
    try std.testing.expectEqual(@as(usize, 69), tabLimit("10\tX = 1", 72, true));
    // no TAB-format line, no change
    try std.testing.expectEqual(@as(usize, 72), tabLimit("      X = 1", 72, true));
}

test "the columns past fixed_line_length are blanks in code lines only" {
    var buf = "      INTEGER A, B        , PAST".*;
    blank(&buf, 24);
    try std.testing.expectEqualStrings("      INTEGER A, B              ", &buf);
    var comment = "C     A COMMENT LONGER THAN THE LIMIT".*;
    blank(&comment, 10);
    try std.testing.expectEqualStrings("C     A COMMENT LONGER THAN THE LIMIT", &comment);
    var directive = "#define LONG_MACRO_NAME 1".*;
    blank(&directive, 10);
    try std.testing.expectEqualStrings("#define LONG_MACRO_NAME 1", &directive);
    try std.testing.expect(isLong("      Y = 2      , Z", 12));
    try std.testing.expect(!isLong("C     A LONG COMMENT LINE", 12));
    try std.testing.expectEqualStrings("      X = 1", code("      X = 1    ! C", 11));
    try std.testing.expectEqualStrings("      X = 1    ! C", code("      X = 1    ! C", null));
}
