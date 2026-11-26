//! Line scanners: hand-written forms of simple patterns that run on every
//! line. Each names the pattern it replaces; tests compare them against it.
//! Part of the helpers (helpers.zig), which export them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const patterns = @import("../patterns.zig");
const helpers = @import("../helpers.zig");
const regex = @import("../regex.zig");
const testing = std.testing;

fn R() *const patterns.Patterns {
    return patterns.get();
}
/// Number of spaces (not tabs) at the start of `line`
pub fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Whether `line[i]` exists and is `c`
inline fn at(line: []const u8, i: usize, c: u8) bool {
    return i < line.len and line[i] == c;
}

/// Whether `line[i]` exists and is one of `set`
inline fn atAny(line: []const u8, i: usize, comptime set: []const u8) bool {
    return i < line.len and std.mem.findScalar(u8, set, line[i]) != null;
}

/// Index just after the start of a fixed-form comment: C, D, * or ! in
/// column 1, or 1-4 or 6+ spaces and `!`
fn fixedCommentEnd(line: []const u8) ?usize {
    if (atAny(line, 0, "!cCdD*")) return 1;
    const n = leadingSpaces(line);
    if (n == 0 or n == 5 or !at(line, n, '!')) return null;
    return n + 1;
}

/// A fixed-form comment line (FIXED_COMMENT)
pub fn isFixedComment(line: []const u8) bool {
    return fixedCommentEnd(line) != null;
}

/// A free-form comment line: spaces and `!` (FREE_COMMENT)
pub fn isFreeComment(line: []const u8) bool {
    return at(line, leadingSpaces(line), '!');
}

/// A comment line of either form
pub fn isComment(fixed: bool, line: []const u8) bool {
    return if (fixed) isFixedComment(line) else isFreeComment(line);
}

/// Makes the first of `markers` (`comment_markers`, such as `;*`) that
/// starts a comment in `line` one zfls reads: its first byte becomes `!`.
/// A marker starts a comment outside strings and before any `!`; a
/// preprocessor directive has none. The line keeps its length.
pub fn markComments(line: []u8, markers: []const []const u8) void {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "#")) return;
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            // a doubled quote closes and opens again
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '!') return;
        for (markers) |m| if (m.len > 0 and std.mem.startsWith(u8, line[i..], m)) {
            line[i] = '!';
            return;
        };
    }
}

test "comment markers become comments outside strings" {
    const markers = [_][]const u8{";*"};
    var buf: [64]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "  if (x) go to 110    ;* it's a comment", "  if (x) go to 110    !* it's a comment" },
        .{ ";* a whole line", "!* a whole line" },
        .{ "  s = 'a;*b' ;* c", "  s = 'a;*b' !* c" },
        .{ "  s = \"it''s;*\" ; t = 1", "  s = \"it''s;*\" ; t = 1" },
        .{ "  x = 1 ! a comment ;* already", "  x = 1 ! a comment ;* already" },
        .{ "#define X ;*", "#define X ;*" },
        .{ "  a = 1; b = 2", "  a = 1; b = 2" },
    };
    for (cases) |c| {
        const line = buf[0..c[0].len];
        @memcpy(line, c[0]);
        markComments(line, &markers);
        try std.testing.expectEqualStrings(c[1], line);
    }
}

/// Index of the mark (`<`, `>` or `!`) of a documentation comment such as
/// `!>` (FIXED_DOC, FREE_DOC)
pub fn docMark(fixed: bool, line: []const u8) ?usize {
    const i = if (fixed) fixedCommentEnd(line) orelse return null else blk: {
        const n = leadingSpaces(line);
        if (!at(line, n, '!')) return null;
        break :blk n + 1;
    };
    return if (atAny(line, i, "<>!")) i else null;
}

/// An OpenMP or OpenACC directive: `!$OMP` (FREE_OPENMP) or `!$ACC`, or in
/// fixed form `!$OMP`, `C$OMP` or `*$OMP` (FIXED_OPENMP), or the same of
/// `ACC`, in column 1 (#725)
pub fn isDirective(fixed: bool, line: []const u8) bool {
    var i: usize = 0;
    if (fixed) {
        if (!atAny(line, 0, "!cC*")) return false;
        i = 1;
    } else {
        i = leadingSpaces(line);
        if (!at(line, i, '!')) return false;
        i += 1;
    }
    if (!at(line, i, '$') or line.len < i + 4) return false;
    const word = line[i + 1 .. i + 4];
    return std.ascii.eqlIgnoreCase(word, "omp") or std.ascii.eqlIgnoreCase(word, "acc");
}

/// A fixed-form continuation line: five spaces and a character that is not
/// whitespace in column 6 (FIXED_CONT)
pub fn isFixedCont(line: []const u8) bool {
    return line.len >= 6 and std.mem.eql(u8, line[0..5], "     ") and
        std.mem.findScalar(u8, str.whitespace, line[5]) == null;
}

/// The TAB that makes `line` a TAB-format line (DEC's tab source form, which
/// ifx, ifort, gfortran and Flang read as fixed form): one in columns 1 to 6
/// after blanks or a label only. It stands for the columns up to 6: the
/// statement follows it, and a nonzero digit right after it marks a
/// continuation line. zfls reads it as a blank, but on a continuation line.
pub fn tabFormatTab(line: []const u8) ?usize {
    for (line[0..@min(line.len, 6)], 0..) |c, i| switch (c) {
        '\t' => return i,
        ' ', '0'...'9' => {},
        else => return null,
    };
    return null;
}

/// Where the statement goes on in a TAB-format continuation line: after
/// blanks, a TAB and a nonzero digit
pub fn tabContStart(line: []const u8) ?usize {
    const i = tabFormatTab(line) orelse return null;
    if (std.mem.findNone(u8, line[0..i], " ") != null) return null;
    return if (i + 1 < line.len and line[i + 1] >= '1' and line[i + 1] <= '9') i + 2 else null;
}

/// Where the statement goes on in a fixed-form continuation line: column 7
/// (`isFixedCont`), or after the digit of a TAB-format one; null for
/// another line
pub fn fixedContStart(line: []const u8) ?usize {
    return if (isFixedCont(line)) 6 else tabContStart(line);
}

/// As `fixedContStart`, for a mark in column 6 other than `0` only, which
/// standard Fortran reads as a blank there
pub fn fixedContMark(line: []const u8) ?usize {
    if (line.len > 5 and line[5] == '0' and tabContStart(line) == null) return null;
    return fixedContStart(line);
}

/// Where the statement of a fixed-form line that is not a comment starts:
/// at column 7, or where it goes on on a continuation line. A letter in the
/// label field (columns 1 to 5) is the statement of a TAB-format line,
/// whose TAB zfls reads as a blank: it starts after the label there.
pub fn fixedStmtStart(line: []const u8) usize {
    if (fixedContStart(line)) |s| return s;
    const n = @min(line.len, 6);
    const i = std.mem.findNone(u8, line[0..n], " 0123456789") orelse return n;
    return if (i < 5 or std.mem.findNone(u8, line[0..5], " ") != null) i else n;
}

/// Index just after the `&` of a free-form line that starts with spaces and
/// `&` (FREE_CONT)
pub fn freeContEnd(line: []const u8) ?usize {
    const n = leadingSpaces(line);
    return if (at(line, n, '&')) n + 1 else null;
}

/// A preprocessor directive: spaces, `#` or `#:`, spaces and a word (PP_ANY)
pub fn isPpDirective(line: []const u8) bool {
    var i = leadingSpaces(line);
    if (!at(line, i, '#')) return false;
    i += 1;
    if (at(line, i, ':')) i += 1;
    while (at(line, i, ' ')) i += 1;
    return i < line.len and regex.isWordChar(line[i]);
}

/// A Fortran name in a line: `$`s, a letter or `_`, then word characters
/// or `$`
pub const Word = struct {
    start: usize,
    end: usize,
    str: []const u8,
};

/// The Fortran names in a line, left to right (`WORD.iterator`)
pub const WordIterator = struct {
    line: []const u8,
    pos: usize = 0,

    pub fn next(self: *WordIterator) ?Word {
        const l = self.line;
        var i = self.pos;
        // `$`s first, then a letter or `_` (ifx's and Flang's `$$lib$random`)
        const start = while (i < l.len) : (i += 1) {
            if (std.ascii.isAlphabetic(l[i]) or l[i] == '_') break i;
            if (l[i] != '$') continue;
            var j = i;
            while (j < l.len and l[j] == '$') j += 1;
            if (j < l.len and (std.ascii.isAlphabetic(l[j]) or l[j] == '_')) break i;
            i = j - 1;
        } else {
            self.pos = l.len;
            return null;
        };
        i += 1;
        while (i < l.len and (regex.isWordChar(l[i]) or l[i] == '$')) i += 1;
        self.pos = i;
        return .{ .start = start, .end = i, .str = l[start..i] };
    }
};

/// Iterate the Fortran names in `line`
pub fn words(line: []const u8) WordIterator {
    return .{ .line = line };
}

/// Detect fixed/free format by looking for characters in label columns
/// and variable declarations before column 6. The TAB of a TAB-format line
/// (`tabFormatTab`) is no space: such a line is fixed form.
pub fn detectFixedFormat(file_lines: []const []const u8) bool {
    var pp_continue = false;
    for (file_lines) |line| {
        if (std.mem.startsWith(u8, line, "#") or pp_continue) {
            pp_continue = std.mem.endsWith(u8, str.rstrip(line), "\\");
            continue;
        }
        // 1-4 spaces and a letter (FREE_FORMAT_TEST)
        const n = leadingSpaces(line);
        if (n >= 1 and n <= 4 and n < line.len and std.ascii.isAlphabetic(line[n])) return false;
        // a declaration before column 6: VAR's keyword starts after the spaces
        if (n < 6 and R().VAR.match(line) != null) return false;
        if (!isFixedComment(line)) {
            const line_end = str.strip(helpers.beforeComment(line));
            if (line_end.len > 0 and std.mem.endsWith(u8, line_end, "&")) return false;
        }
    }
    return true;
}

pub const LabelResult = struct { line: []const u8, label: ?[]const u8 };

/// Strip leading numeric line label: spaces, digits, then a space
/// (LINE_LABEL); the label is blanked
pub fn stripLineLabel(a: Allocator, line: []const u8) !LabelResult {
    const start = leadingSpaces(line);
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == start or !at(line, end, ' ')) return .{ .line = line, .label = null };
    const out = try a.dupe(u8, line);
    @memset(out[start..end], ' ');
    return .{ .line = out, .label = line[start..end] };
}

/// Random lines made of the pieces the line scanners look at
fn randomLine(rng: std.Random, buf: []u8) []const u8 {
    const pieces = [_][]const u8{
        " ",   "  ",  "     ", "      ",  "!",    "&",         "#",                ":", "c",   "C",        "d",
        "D",   "*",   "$",     "omp",     "OMP",  "Omp",       "om",               "<", ">",   "1",        "23",
        "acc", "ACC", "'",     "\"",      "\t",   "\x0b",      "a",                "Z", "x_1", "\xc3\xa9", "$x",
        "5",   "_",   "real",  "INTEGER", "type", "Character", "double precision", "(", ")",   ",",        "=",
        "0",
    };
    var len: usize = 0;
    const n = rng.uintAtMost(usize, 9);
    for (0..n) |_| {
        const p = pieces[rng.uintLessThan(usize, pieces.len)];
        if (len + p.len > buf.len) break;
        @memcpy(buf[len .. len + p.len], p);
        len += p.len;
    }
    return buf[0..len];
}

test "the line scanners agree with the patterns they replace" {
    patterns.init();
    const ta = testing.allocator;
    const Regex = regex.Regex;
    var fixed_comment = try Regex.compile(ta, "([!cd*]|[ ]{1,4}!|[ ]{6,}!)", regex.I);
    defer fixed_comment.deinit();
    var free_comment = try Regex.compile(ta, "([ ]*!)", .{});
    defer free_comment.deinit();
    var fixed_doc = try Regex.compile(ta, "(?:[!cd\\*]|[ ]{1,4}!|[ ]{6,}!)([<>!])", regex.I);
    defer fixed_doc.deinit();
    var free_doc = try Regex.compile(ta, "[ ]*!([<>!])", .{});
    defer free_doc.deinit();
    var fixed_openmp = try Regex.compile(ta, "[!c\\*]\\$(?:OMP|ACC)", regex.I);
    defer fixed_openmp.deinit();
    var free_openmp = try Regex.compile(ta, "[ ]*!\\$(?:OMP|ACC)", regex.I);
    defer free_openmp.deinit();
    var fixed_cont = try Regex.compile(ta, "( {5}[\\S])", .{});
    defer fixed_cont.deinit();
    var free_cont = try Regex.compile(ta, "([ ]*&)", .{});
    defer free_cont.deinit();
    var pp_any = try Regex.compile(ta, "^[ ]*#:?[ ]*(\\w+)", .{});
    defer pp_any.deinit();
    var free_format_test = try Regex.compile(ta, "[ ]{1,4}[a-z]", regex.I);
    defer free_format_test.deinit();
    var line_label = try Regex.compile(ta, "[ ]*([0-9]+)[ ]+", regex.I);
    defer line_label.deinit();

    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x5ca9);
    const rng = prng.random();
    var buf: [64]u8 = undefined;
    for (0..20000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const line = randomLine(rng, &buf);

        try testing.expectEqual(fixed_comment.match(line) != null, isFixedComment(line));
        try testing.expectEqual(free_comment.match(line) != null, isFreeComment(line));
        const fd: ?usize = if (fixed_doc.match(line)) |m| m.start(1) else null;
        try testing.expectEqual(fd, docMark(true, line));
        const frd: ?usize = if (free_doc.match(line)) |m| m.start(1) else null;
        try testing.expectEqual(frd, docMark(false, line));
        try testing.expectEqual(fixed_openmp.match(line) != null, isDirective(true, line));
        try testing.expectEqual(free_openmp.match(line) != null, isDirective(false, line));
        try testing.expectEqual(fixed_cont.match(line) != null, isFixedCont(line));
        const fc: ?usize = if (free_cont.match(line)) |m| m.end(0) else null;
        try testing.expectEqual(fc, freeContEnd(line));
        try testing.expectEqual(pp_any.match(line) != null, isPpDirective(line));

        // detectFixedFormat on one line, as it was with the patterns
        const want_fixed = blk: {
            if (std.mem.startsWith(u8, line, "#")) break :blk true;
            if (free_format_test.match(line) != null) break :blk false;
            if (R().VAR.match(line)) |m| if (m.start(1) < 6) break :blk false;
            if (fixed_comment.match(line) == null) {
                const line_end = str.strip(helpers.beforeComment(line));
                if (line_end.len > 0 and std.mem.endsWith(u8, line_end, "&")) break :blk false;
            }
            break :blk true;
        };
        try testing.expectEqual(want_fixed, detectFixedFormat(&.{line}));

        const lr = try stripLineLabel(a, line);
        if (line_label.match(line)) |m| {
            try testing.expectEqualStrings(m.group(1).?, lr.label.?);
            const want = try a.dupe(u8, line);
            @memset(want[m.start(1)..m.end(1)], ' ');
            try testing.expectEqualStrings(want, lr.line);
        } else {
            try testing.expect(lr.label == null);
            try testing.expectEqualStrings(line, lr.line);
        }

        var want_words = R().WORD.iterator(line);
        var got_words = words(line);
        while (want_words.next()) |m| {
            const w = got_words.next().?;
            try testing.expectEqual(m.start(0), w.start);
            try testing.expectEqual(m.end(0), w.end);
            try testing.expectEqualStrings(m.str(), w.str);
        }
        try testing.expect(got_words.next() == null);
    }
}

test "TAB-format lines (DEC's tab source form)" {
    patterns.init();
    try testing.expectEqual(@as(?usize, 0), tabFormatTab("\tI = 1"));
    try testing.expectEqual(@as(?usize, 2), tabFormatTab("10\tJ = I"));
    try testing.expectEqual(@as(?usize, 5), tabFormatTab("     \tX"));
    try testing.expect(tabFormatTab("      X = 1\t! a TAB in the statement") == null);
    try testing.expect(tabFormatTab("C\tcomment") == null);
    // a continuation: a TAB and a nonzero digit, without a label
    try testing.expectEqual(@as(?usize, 2), tabContStart("\t1 2"));
    try testing.expectEqual(@as(?usize, 4), tabContStart("  \t9X"));
    try testing.expect(tabContStart("\t0X") == null);
    try testing.expect(tabContStart("10\t1X") == null);
    try testing.expectEqual(@as(?usize, 6), fixedContStart("     &X"));
    try testing.expectEqual(@as(?usize, 2), fixedContStart("\t1 2"));
    try testing.expect(fixedContMark("     0X") == null);
    try testing.expectEqual(@as(?usize, 6), fixedContMark("     1X"));
    // where the statement starts in the lines zfls reads (the TAB a blank)
    try testing.expectEqual(@as(usize, 6), fixedStmtStart("      X = 1"));
    try testing.expectEqual(@as(usize, 6), fixedStmtStart("   10 CONTINUE"));
    try testing.expectEqual(@as(usize, 1), fixedStmtStart(" I = 1"));
    try testing.expectEqual(@as(usize, 3), fixedStmtStart("10 J = I"));
    try testing.expectEqual(@as(usize, 5), fixedStmtStart("1234 X = 1"));
    try testing.expectEqual(@as(usize, 2), fixedStmtStart("\t1 2"));
    try testing.expectEqual(@as(usize, 3), fixedStmtStart("123"));
    // a file with TAB-format lines is fixed form; the TAB was a space
    // before column 6 (FREE_FORMAT_TEST)
    try testing.expect(detectFixedFormat(&.{ "      PROGRAM DL", "\tI = 1", "C     comment here", "\tEND" }));
    try testing.expect(detectFixedFormat(&.{"\tINTEGER I"}));
    try testing.expect(!detectFixedFormat(&.{ "\tI = 1", " x = 1" }));
    try testing.expect(!detectFixedFormat(&.{"\tcall f(a, &"}));
}
