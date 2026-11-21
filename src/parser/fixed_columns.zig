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

/// `line` without the columns past `columns` when it is a code line
pub fn code(line: []const u8, columns: ?usize) []const u8 {
    const n = columns orelse return line;
    return if (isLong(line, n)) line[0..n] else line;
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
