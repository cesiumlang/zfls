//! The statement a line is part of: its continuation lines before and after
//! it, and words found in them.
//! Part of `FortranFile` (parser.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const parser = @import("../parser.zig");
const FortranFile = parser.FortranFile;
const Range = helpers.Range;

pub const CodeLine = struct {
    pre: []const []const u8,
    curr: ?[]const u8,
    post: []const []const u8,
};

/// Index of the `&` of a free-form line that continues on the next line: the
/// first one, unless a comment starts before it
fn continuationAmpersand(line: []const u8) ?usize {
    const amper = std.mem.findScalar(u8, line, '&') orelse return null;
    const comment = std.mem.findScalar(u8, line, '!') orelse return amper;
    return if (amper < comment) amper else null;
}

/// A fixed-form continuation line with blanks for its marks, the statement
/// going on at `start` (`helpers.fixedContStart`)
fn contLine(a: Allocator, line: []const u8, start: usize) ![]const u8 {
    return std.mem.concat(a, u8, &.{ try str.spaces(a, start), str.from(line, start) });
}

/// A fixed-form line without its trailing `!` comment. A `!` inside a
/// string, also one left open to continue on the next line, is no comment.
fn fixedNoComment(a: Allocator, line: []const u8) ![]const u8 {
    _ = a;
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '!') {
            return str.rstrip(line[0..i]);
        }
    }
    return line;
}

/// Whether line `i` (0-based), `line`, holds no part of a statement: a
/// blank or comment line, a preprocessor directive, or a line of an
/// inactive conditional branch (hansec #203). Such lines may come
/// between the lines of a continued statement without ending it.
fn isNonCode(self: *const FortranFile, line: []const u8, i: usize) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0 or helpers.isComment(self.fixed, line) or
        helpers.isPpDirective(line) or ppSkipped(self, i);
}

/// The statement that line `line_no` (0-based) is part of: the line,
/// and the lines of the statement before it (`backward`) and after it
/// (`forward`). `pre` and `post` hold a line for each line of the
/// file, from the statement's first to its last: an empty one for a
/// line that is no code (`isNonCode`).
pub fn getCodeLine(self: *const FortranFile, a: Allocator, line_no: usize, forward: bool, backward: bool, pp_content: bool, strip_comment: bool) !CodeLine {
    var curr_line = self.getLine(line_no, pp_content) orelse return .{ .pre = &.{}, .curr = null, .post = &.{} };
    var pre_lines: std.ArrayList([]const u8) = .empty;
    // the lines that are no code since the last line of the statement
    var skipped: usize = 0;
    if (backward) {
        // a fixed-form line continues a statement by its column 6, a
        // free-form one when the code line before it ends with `&`
        const cont = if (self.fixed) helpers.fixedContStart(curr_line) else null;
        const continued = !self.fixed or cont != null;
        if (self.fixed) {
            if (cont) |c| curr_line = try contLine(a, curr_line, c);
        } else if (helpers.freeContEnd(curr_line)) |e| {
            curr_line = try std.mem.concat(a, u8, &.{ try str.spaces(a, e), curr_line[e..] });
        }
        var i = line_no;
        while (continued and i > 0) {
            i -= 1;
            const raw = self.getLine(i, pp_content) orelse "";
            if (isNonCode(self, raw, i)) {
                skipped += 1;
                continue;
            }
            var part: []const u8 = undefined;
            var first = false;
            if (self.fixed) {
                const c = helpers.fixedContStart(raw);
                first = c == null;
                part = try fixedNoComment(a, raw);
                if (c) |start| part = try contLine(a, part, start);
            } else {
                const no_comm = str.beforeFirst(try helpers.stripStrings(a, raw, true), "!");
                const cont_ind = std.mem.findScalarLast(u8, no_comm, '&') orelse break;
                part = no_comm[0..cont_ind];
                if (helpers.freeContEnd(no_comm)) |e| {
                    if (cont_ind == e - 1) break;
                    part = try std.mem.concat(a, u8, &.{ try str.spaces(a, e), part[e..] });
                }
            }
            try pre_lines.appendNTimes(a, "", skipped);
            skipped = 0;
            try pre_lines.append(a, part);
            if (first) break;
        }
    }
    var post_lines: std.ArrayList([]const u8) = .empty;
    if (forward) {
        // the statement's last line so far: null for `curr_line`, else
        // an index of `post_lines`
        var last: ?usize = null;
        var i = line_no + 1;
        skipped = 0;
        while (true) {
            const line = if (last) |l| post_lines.items[l] else curr_line;
            var cut = line;
            if (!self.fixed) {
                // a preprocessor directive's `&&` continues nothing
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#")) break;
                const amper = continuationAmpersand(try helpers.stripStrings(a, line, true)) orelse break;
                cut = str.upto(line, amper);
                if (last) |l| post_lines.items[l] = cut else curr_line = cut;
            }
            const next = while (self.getLine(i, pp_content)) |l| : (i += 1) {
                if (!isNonCode(self, l, i)) break l;
                skipped += 1;
            } else break;
            i += 1;
            var part = next;
            if (self.fixed) {
                const c = helpers.fixedContStart(next) orelse break;
                // a comment ends its line only: one before a continuation
                // must not cut off the rest of the statement (hansec #202)
                cut = try fixedNoComment(a, line);
                if (last) |l| post_lines.items[l] = cut else curr_line = cut;
                part = try contLine(a, next, c);
            } else if (helpers.freeContEnd(next)) |e| part = next[e..];
            try post_lines.appendNTimes(a, "", skipped);
            skipped = 0;
            try post_lines.append(a, part);
            last = post_lines.items.len - 1;
        }
    }
    if (strip_comment) curr_line = stripComment(self, curr_line);
    std.mem.reverse([]const u8, pre_lines.items);
    return .{ .pre = pre_lines.items, .curr = curr_line, .post = post_lines.items };
}

/// Whether line `line_no` (0-based) is excluded by a preprocessor
/// conditional
fn ppSkipped(self: *const FortranFile, line_no: usize) bool {
    for (self.pp_skips) |reg| if (reg.start <= line_no + 1 and line_no + 1 <= reg.end) return true;
    return false;
}

pub fn stripComment(self: *const FortranFile, line: []const u8) []const u8 {
    if (self.fixed) {
        if (helpers.isFixedComment(line) and !helpers.isDirective(true, line)) return "";
    } else {
        if (!helpers.isDirective(false, line)) return helpers.beforeComment(line);
    }
    return line;
}

/// Whether a statement continues into line `line_no` (0-based): the
/// code line before it ends with `&` (free form), or the next one is a
/// continuation line (fixed form). An INCLUDE or `#include` there is a
/// part of the statement's text (json-fortran's `subroutine s(me, &`
/// then an `#include` of the rest of the argument list), not a file of
/// declarations.
pub fn continuesInto(self: *const FortranFile, line_no: usize) bool {
    if (self.fixed) {
        var i = line_no + 1;
        while (self.getLine(i, false)) |l| : (i += 1) {
            if (std.mem.trim(u8, l, " \t\r").len == 0 or helpers.isFixedComment(l) or l[0] == '#') continue;
            return helpers.fixedContMark(l) != null;
        }
        return false;
    }
    var i = line_no;
    while (i > 0) {
        i -= 1;
        const l = self.getLine(i, false) orelse return false;
        const code = std.mem.trim(u8, stripComment(self, l), " \t\r");
        if (code.len == 0 or code[0] == '#') continue;
        return code[code.len - 1] == '&';
    }
    return false;
}

pub fn findWordInCodeLine(self: *const FortranFile, a: Allocator, line_no_in: usize, word: []const u8, forward: bool, backward: bool, pp_content: bool) !struct { line: usize, range: Range } {
    var line_no = line_no_in;
    const cl = try getCodeLine(self, a, line_no, forward, backward, pp_content, false);
    var word_range: Range = .{ .start = -1, .end = -1 };
    if (cl.curr) |c| word_range = helpers.findWordInLineIgnoreCase(c, word);
    if (backward and word_range.start < 0) {
        var i: usize = cl.pre.len;
        var k: usize = 0;
        while (i > 0) : (k += 1) {
            i -= 1;
            word_range = helpers.findWordInLineIgnoreCase(cl.pre[i], word);
            if (word_range.start >= 0) {
                line_no -|= k + 1;
                return .{ .line = line_no, .range = word_range };
            }
        }
    }
    if (forward and word_range.start < 0) {
        for (cl.post, 0..) |l, i| {
            word_range = helpers.findWordInLineIgnoreCase(l, word);
            if (word_range.start >= 0) {
                line_no += i + 1;
                return .{ .line = line_no, .range = word_range };
            }
        }
    }
    return .{ .line = line_no, .range = word_range };
}

test "getCodeLine: lines that are no code do not end a statement, and keep their place" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try FortranFile.create(std.testing.allocator, "/w/a.f90", null);
    defer f.destroy();
    _ = try f.setText("call foo(a, & ! one\n  ! two\n\n#if 1\n  b, &\n#endif\n  c)\nx = 1\n");
    const back = try f.getCodeLine(a, 6, false, true, false, false);
    try std.testing.expectEqual(@as(usize, 6), back.pre.len);
    try std.testing.expectEqualStrings("call foo(a, ", back.pre[0]);
    try std.testing.expectEqualStrings("  b, ", back.pre[4]);
    const fwd = try f.getCodeLine(a, 0, true, false, false, false);
    try std.testing.expectEqualStrings("call foo(a, ", fwd.curr.?);
    try std.testing.expectEqual(@as(usize, 6), fwd.post.len);
    try std.testing.expectEqualStrings("  c)", fwd.post[5]);
    // fixed form; line 0 is part of the statement too
    _ = try f.setText("      x = f(a,\nc two\n     & b)\nc three\n      y = 1\n");
    f.fixed = true;
    const fb = try f.getCodeLine(a, 2, false, true, false, false);
    try std.testing.expectEqual(@as(usize, 2), fb.pre.len);
    try std.testing.expectEqualStrings("      x = f(a,", fb.pre[0]);
    const ff = try f.getCodeLine(a, 0, true, false, false, false);
    try std.testing.expectEqual(@as(usize, 2), ff.post.len);
}
