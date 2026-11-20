//! Part of the parser (parser.zig): the blanks of a file's text, and DEC's
//! TAB-format lines, which ifx, ifort, gfortran and Flang read in fixed
//! form. A TAB in columns 1 to 6 after blanks or a label stands for the
//! columns up to 6, and a nonzero digit right after it marks a
//! continuation line (`helpers.tabFormatTab`). Such a TAB stays in the
//! editor's text (`FortranFile.editLines`), where it tells the form; the
//! lines zfls reads have a blank for it, but on a continuation line of a
//! fixed-form file.

const std = @import("std");
const helpers = @import("../helpers.zig");

/// Makes the tabs and form feeds (the page breaks of old sources) of
/// `text` spaces, as compilers read them (fortls #443); every column stays
/// where it is. The TAB of a TAB-format line stays.
pub fn blankSpaces(text: []u8) void {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |l| {
        const line: []u8 = @constCast(l);
        const keep = helpers.tabFormatTab(line) orelse line.len;
        for (line, 0..) |*c, i| {
            if ((c.* == '\t' and i != keep) or c.* == '\x0c') c.* = ' ';
        }
    }
}

/// Whether any of `lines` is a TAB-format line, its TAB kept
pub fn any(lines: []const []const u8) bool {
    for (lines) |l| if (helpers.tabFormatTab(l)) |i| if (l[i] == '\t') return true;
    return false;
}

/// Makes the TAB of a TAB-format line a blank, but of a continuation line
/// of fixed form (whose digit after it is no label)
pub fn blankLine(fixed: bool, line: []u8) void {
    if (helpers.tabFormatTab(line)) |i| if (!fixed or helpers.tabContStart(line) == null) {
        line[i] = ' ';
    };
}

const FortranFile = @import("../parser.zig").FortranFile;

test "form feeds and tabs are read as spaces, as loaded and as edited" {
    const f = try FortranFile.create(std.testing.allocator, "/w/a.f90", null);
    defer f.destroy();
    _ = try f.setText("program p\n\x0c\tinteger :: a\nend program p\n");
    try std.testing.expectEqualStrings("  integer :: a", f.getLine(1, false).?);
    _ = try f.applyChange(.{ .text = "\x0c\tinteger :: b\n", .range = .{ .sl = 2, .sc = 0, .el = 2, .ec = 0 } });
    try std.testing.expectEqualStrings("  integer :: b", f.getLine(2, false).?);
    _ = try f.applyChange(.{ .text = "\x0c", .range = .{ .sl = 1, .sc = 0, .el = 1, .ec = 1 } });
    try std.testing.expectEqualStrings("  integer :: a", f.getLine(1, false).?);
    // a free-form file's TABs are blanks, also at the start of a line
    _ = try f.setText("program p\n\tinteger :: a\nend program p\n");
    try std.testing.expect(!f.fixed);
    try std.testing.expectEqualStrings(" integer :: a", f.getLine(1, false).?);
    try std.testing.expectEqualStrings("\tinteger :: a", f.editLines()[1]);
}

test "a file with TAB-format lines is fixed form, also after an edit" {
    const a = std.testing.allocator;
    const f = try FortranFile.create(a, "/w/tc.f", null);
    defer f.destroy();
    // ifx, gfortran and Flang: I = 3, J = 3
    _ = try f.setText("      PROGRAM TC\n      INTEGER I, J\n\tI = 1 +\n\t1 2\n10\tJ = I\nC     comment here\n\tEND\n");
    try std.testing.expect(f.fixed and f.declared_fixed);
    // the editor's text as it is, the lines zfls reads with blanks
    try std.testing.expectEqualStrings("\tI = 1 +", f.editLines()[2]);
    try std.testing.expectEqualStrings(" I = 1 +", f.getLine(2, false).?);
    try std.testing.expectEqualStrings("10 J = I", f.getLine(4, false).?);
    // the continuation line: TAB and digit
    try std.testing.expectEqualStrings("\t1 2", f.getLine(3, false).?);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const cl = try f.getCodeLine(arena.allocator(), 2, true, false, false, false);
    try std.testing.expectEqualStrings(" I = 1 +", cl.curr.?);
    try std.testing.expectEqual(@as(usize, 1), cl.post.len);
    try std.testing.expectEqualStrings("   2", cl.post[0]);
    const back = try f.getCodeLine(arena.allocator(), 3, false, true, false, false);
    try std.testing.expectEqualStrings(" I = 1 +", back.pre[0]);
    // an edit elsewhere keeps the TABs that tell the form
    _ = try f.applyChange(.{ .text = "K", .range = .{ .sl = 1, .sc = 17, .el = 1, .ec = 18 } });
    try std.testing.expect(f.fixed);
    try std.testing.expectEqualStrings("\tI = 1 +", f.editLines()[2]);
    // the editor says free form: the TABs are blanks, the continuation too
    _ = f.forceForm(.free);
    try std.testing.expect(!f.fixed);
    try std.testing.expectEqualStrings(" 1 2", f.getLine(3, false).?);
    _ = f.forceForm(null);
    try std.testing.expect(f.fixed);
    try std.testing.expectEqualStrings("\t1 2", f.getLine(3, false).?);
}

test "a TAB-format continuation line in the fixed-form part of a file that switches forms" {
    const f = try FortranFile.create(std.testing.allocator, "/w/a.f", null);
    defer f.destroy();
    _ = try f.setText("      X = 1 +\n\t1 2\n!dir$ free\ny = 3\n");
    try std.testing.expect(f.declared_fixed and f.form_switched and !f.fixed);
    try std.testing.expectEqualStrings("      X = 1 +&", f.getLine(0, false).?);
    try std.testing.expectEqualStrings(" & 2", f.getLine(1, false).?);
}
