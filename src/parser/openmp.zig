//! OpenMP conditional compilation lines: a line that starts with the
//! sentinel `!$` and a blank (in fixed form `!$`, `c$`, `C$` or `*$` in
//! columns 1 and 2) is a statement when the file is compiled with OpenMP.
//! zfls reads it as code, with the sentinel taken as two blanks, so that
//! its columns stay those of the editor. The directives (`!$omp`, `!$acc`)
//! stay comments.

const std = @import("std");

/// The index of the sentinel of an OpenMP conditional compilation line, or
/// null for any other line. Free form: blanks, `!$`, then a blank, a tab,
/// `&` (a continuation) or the end of the line. Fixed form: the sentinel in
/// columns 1 and 2, then blanks or digits (a label) up to column 5.
pub fn sentinel(fixed: bool, line: []const u8) ?usize {
    if (fixed) {
        if (line.len < 2 or line[1] != '$') return null;
        switch (line[0]) {
            '!', 'c', 'C', '*' => {},
            else => return null,
        }
        // a tab ends the label field (tab format)
        for (line[2..@min(line.len, 5)]) |c| switch (c) {
            ' ', '0'...'9' => {},
            '\t' => break,
            else => return null,
        };
        return 0;
    }
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i + 1 >= line.len or line[i] != '!' or line[i + 1] != '$') return null;
    if (i + 2 == line.len) return i;
    return switch (line[i + 2]) {
        ' ', '\t', '&' => i,
        else => null,
    };
}

/// Whether `line` is an OpenMP conditional compilation line
pub fn isConditional(fixed: bool, line: []const u8) bool {
    return sentinel(fixed, line) != null;
}

/// Blanks the sentinel of `line` when it is a conditional compilation line;
/// the line keeps its length. Returns whether it was one.
pub fn blankSentinel(fixed: bool, line: []u8) bool {
    const i = sentinel(fixed, line) orelse return false;
    line[i] = ' ';
    line[i + 1] = ' ';
    return true;
}

test "free-form conditional compilation lines" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 3), sentinel(false, "   !$ use omp_lib"));
    try t.expectEqual(@as(?usize, 0), sentinel(false, "!$ nthreads = omp_get_max_threads()"));
    try t.expectEqual(@as(?usize, 3), sentinel(false, "   !$& b)"));
    try t.expectEqual(@as(?usize, 3), sentinel(false, "   !$   & b)"));
    try t.expectEqual(@as(?usize, 1), sentinel(false, "\t!$\tx = 1"));
    try t.expectEqual(@as(?usize, 0), sentinel(false, "!$"));
    // directives and comments
    try t.expectEqual(@as(?usize, null), sentinel(false, "   !$omp parallel do"));
    try t.expectEqual(@as(?usize, null), sentinel(false, "   !$OMP END PARALLEL"));
    try t.expectEqual(@as(?usize, null), sentinel(false, "   !$acc kernels"));
    try t.expectEqual(@as(?usize, null), sentinel(false, "   !$this is text"));
    try t.expectEqual(@as(?usize, null), sentinel(false, "   ! $ x = 1"));
    try t.expectEqual(@as(?usize, null), sentinel(false, "   x = 1 !$ y = 2"));
    try t.expectEqual(@as(?usize, null), sentinel(false, "   c$ x = 1"));
    try t.expectEqual(@as(?usize, null), sentinel(false, ""));
}

test "fixed-form conditional compilation lines" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 0), sentinel(true, "c$    n = 8"));
    try t.expectEqual(@as(?usize, 0), sentinel(true, "C$    n = 8"));
    try t.expectEqual(@as(?usize, 0), sentinel(true, "*$    n = 16"));
    try t.expectEqual(@as(?usize, 0), sentinel(true, "!$    n = 16"));
    try t.expectEqual(@as(?usize, 0), sentinel(true, "c$ 10 continue"));
    try t.expectEqual(@as(?usize, 0), sentinel(true, "c$   &  n"));
    try t.expectEqual(@as(?usize, 0), sentinel(true, "c$"));
    try t.expectEqual(@as(?usize, 0), sentinel(true, "c$\tn = 8"));
    // directives, comments, and the sentinel elsewhere than in column 1
    try t.expectEqual(@as(?usize, null), sentinel(true, "c$omp parallel"));
    try t.expectEqual(@as(?usize, null), sentinel(true, "C$OMP END PARALLEL"));
    try t.expectEqual(@as(?usize, null), sentinel(true, "*$omp barrier"));
    try t.expectEqual(@as(?usize, null), sentinel(true, "!$acc kernels"));
    try t.expectEqual(@as(?usize, null), sentinel(true, "c$ a comment"));
    try t.expectEqual(@as(?usize, null), sentinel(true, "   !$ n = 1"));
    try t.expectEqual(@as(?usize, null), sentinel(true, "c a comment"));
    try t.expectEqual(@as(?usize, null), sentinel(true, "d$    n = 1"));
}

test "the sentinel becomes two blanks" {
    var buf = "   !$ call omp_set_num_threads(n)".*;
    try std.testing.expect(blankSentinel(false, &buf));
    try std.testing.expectEqualStrings("      call omp_set_num_threads(n)", &buf);
    var omp = "!$omp parallel".*;
    try std.testing.expect(!blankSentinel(false, &omp));
    try std.testing.expectEqualStrings("!$omp parallel", &omp);
}

test "a file reads its conditional lines as code; changes apply to the editor's text" {
    const parser = @import("../parser.zig");
    @import("../patterns.zig").init();
    const gpa = std.testing.allocator;
    const f = try parser.FortranFile.create(gpa, "/w/a.f90", null);
    defer f.destroy();
    _ = try f.setText("program p\n  !$ x = 1\n  !$omp barrier\nend program p\n");
    try std.testing.expectEqualStrings("     x = 1", f.getLine(1, false).?);
    try std.testing.expectEqualStrings("  !$omp barrier", f.getLine(2, false).?);
    try std.testing.expectEqualStrings("  !$ x = 1", f.editLines()[1]);
    // deleting the blank after the sentinel makes the line a comment
    _ = try f.applyChange(.{ .text = "", .range = .{ .sl = 1, .sc = 4, .el = 1, .ec = 5 } });
    try std.testing.expectEqualStrings("  !$x = 1", f.getLine(1, false).?);
    try std.testing.expectEqual(@as(usize, 0), f.raw_lines.items.len);
    // and typing it again, code
    _ = try f.applyChange(.{ .text = " ", .range = .{ .sl = 1, .sc = 4, .el = 1, .ec = 4 } });
    try std.testing.expectEqualStrings("     x = 1", f.getLine(1, false).?);
    try std.testing.expectEqualStrings("  !$ x = 1", f.editLines()[1]);
    // off: as written
    f.openmp_conditional = false;
    _ = try f.setText("program p\n  !$ y = 1\nend program p\n");
    try std.testing.expectEqualStrings("  !$ y = 1", f.getLine(1, false).?);
}

test "fixed form: the form is detected from the text as written" {
    const parser = @import("../parser.zig");
    @import("../patterns.zig").init();
    const gpa = std.testing.allocator;
    const f = try parser.FortranFile.create(gpa, "/w/a.f", null);
    defer f.destroy();
    _ = try f.setText("      program p\nc$    n = 8\n*$omp barrier\n      end\n");
    try std.testing.expect(f.fixed);
    try std.testing.expectEqualStrings("      n = 8", f.getLine(1, false).?);
    try std.testing.expectEqualStrings("*$omp barrier", f.getLine(2, false).?);
}
