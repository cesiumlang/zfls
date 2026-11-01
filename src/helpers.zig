//! Port of `fortls.helper_functions`

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("str.zig");
const patterns = @import("patterns.zig");
const constants = @import("constants.zig");
const regex = @import("regex.zig");

/// A single line range (start, end); start is -1 when not found
pub const Range = struct { start: isize, end: isize };

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// Get full word containing given cursor position
pub fn expandName(line: []const u8, char_pos: usize) []const u8 {
    const regexs = [_]*const @import("regex.zig").Regex{
        &R().LOGICAL, &R().SQ_STRING, &R().DQ_STRING, &R().WORD, &R().NUMBER,
    };
    for (regexs) |r| {
        var it = r.iterator(line);
        while (it.next()) |m| {
            if (m.start(0) <= char_pos and char_pos <= m.end(0)) return m.str();
        }
    }
    return "";
}

// --------------------------------------------------------------------------
// Line scanners: hand-written forms of simple patterns that run on every line.
// Each names the pattern it replaces; tests compare them against it.

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
    return i < line.len and std.mem.indexOfScalar(u8, set, line[i]) != null;
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

/// An OpenMP directive: `!$OMP` (FREE_OPENMP), or in fixed form `!$OMP`,
/// `C$OMP` or `*$OMP` in column 1 (FIXED_OPENMP)
pub fn isOpenMp(fixed: bool, line: []const u8) bool {
    var i: usize = 0;
    if (fixed) {
        if (!atAny(line, 0, "!cC*")) return false;
        i = 1;
    } else {
        i = leadingSpaces(line);
        if (!at(line, i, '!')) return false;
        i += 1;
    }
    return at(line, i, '$') and line.len >= i + 4 and std.ascii.eqlIgnoreCase(line[i + 1 .. i + 4], "omp");
}

/// A fixed-form continuation line: five spaces and a character that is not
/// whitespace in column 6 (FIXED_CONT)
pub fn isFixedCont(line: []const u8) bool {
    return line.len >= 6 and std.mem.eql(u8, line[0..5], "     ") and
        std.mem.indexOfScalar(u8, str.whitespace, line[5]) == null;
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

/// A Fortran name in a line: a letter or `_`, then word characters or `$`
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
        while (i < l.len and !(std.ascii.isAlphabetic(l[i]) or l[i] == '_')) i += 1;
        if (i >= l.len) {
            self.pos = l.len;
            return null;
        }
        const start = i;
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
/// and variable declarations before column 6.
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
            const line_end = str.strip(str.beforeFirst(line, "!"));
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

/// Strips string literals from code line: each '...', then each "..." in
/// what is left (SQ_STRING, DQ_STRING). `maintain_len` blanks their contents
/// instead of removing them.
pub fn stripStrings(a: Allocator, in_line: []const u8, maintain_len: bool) ![]const u8 {
    if (std.mem.indexOfAny(u8, in_line, "'\"") == null) return in_line;
    if (maintain_len) {
        const out = try a.dupe(u8, in_line);
        blankQuoted(out, '\'');
        blankQuoted(out, '"');
        return out;
    }
    return removeQuoted(a, try removeQuoted(a, in_line, '\''), '"');
}

/// Blank the inside of each `q...q` in `s`, pairing quotes left to right
fn blankQuoted(s: []u8, q: u8) void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, q)) |open| {
        const close = std.mem.indexOfScalarPos(u8, s, open + 1, q) orelse return;
        @memset(s[open + 1 .. close], ' ');
        i = close + 1;
    }
}

/// `s` without each `q...q`, pairing quotes left to right
fn removeQuoted(a: Allocator, s: []const u8, q: u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, last, q)) |open| {
        const close = std.mem.indexOfScalarPos(u8, s, open + 1, q) orelse break;
        try out.appendSlice(a, s[last..open]);
        last = close + 1;
    }
    try out.appendSlice(a, s[last..]);
    return out.items;
}

/// The value of a PARAMETER given as `= value` right after its name: up to
/// the next comma that is not inside parentheses, brackets or a string, so a
/// function call or an array constructor is whole (upstream #124). Null when
/// there is no `=` (or an `=>`).
pub fn parameterValue(after_name: []const u8) ?[]const u8 {
    const t = str.lstrip(after_name);
    if (t.len == 0 or t[0] != '=' or (t.len > 1 and t[1] == '>')) return null;
    const v = t[1..];
    var depth: isize = 0;
    var quote: u8 = 0;
    var end = v.len;
    for (v, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '!' => {
                end = i;
                break;
            },
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            ',' => if (depth == 0) {
                end = i;
                break;
            },
            else => {},
        }
    }
    return str.strip(v[0..end]);
}

/// Split an argument list at its own commas: not those inside parentheses,
/// brackets or string literals, as in `arr(2, 3), 'a,b'` (upstream #87). The
/// pieces are slices of `s`.
pub fn splitArgs(a: Allocator, s: []const u8) ![][]const u8 {
    const stripped = try stripStrings(a, s, true);
    var out: std.ArrayList([]const u8) = .empty;
    var depth: isize = 0;
    var start: usize = 0;
    for (stripped, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -= 1,
        ',' => if (depth == 0) {
            try out.append(a, s[start..i]);
            start = i + 1;
        },
        else => {},
    };
    try out.append(a, s[start..]);
    return out.items;
}

/// Separate definition lists, skipping parenthesis and bracket groups
pub fn separateDefList(a: Allocator, test_str: []const u8) !?[][]const u8 {
    const stripped = try stripStrings(a, test_str, false);
    var paren_count: isize = 0;
    var def_list: std.ArrayList([]const u8) = .empty;
    var curr: std.ArrayList(u8) = .empty;
    for (stripped) |c| {
        switch (c) {
            '(', '[' => paren_count += 1,
            ')', ']' => paren_count -= 1,
            ',' => if (paren_count == 0) {
                const s = str.strip(curr.items);
                if (s.len > 0) {
                    try def_list.append(a, try a.dupe(u8, s));
                    curr = .empty;
                } else if (def_list.items.len == 0) {
                    return null;
                }
                continue;
            },
            else => {},
        }
        try curr.append(a, c);
    }
    const s = str.strip(curr.items);
    if (s.len > 0) try def_list.append(a, s);
    return def_list.items;
}

/// Find Fortran word in line
pub fn findWordInLine(line: []const u8, word: []const u8) Range {
    var i: isize = -1;
    var it = words(line);
    while (it.next()) |m| {
        if (std.mem.eql(u8, m.str, word)) {
            i = @intCast(m.start);
            break;
        }
    }
    return .{ .start = i, .end = i + @as(isize, @intCast(word.len)) };
}

/// `findWordInLine` ignoring the case of the words in `line` and of `word`
pub fn findWordInLineIgnoreCase(line: []const u8, word: []const u8) Range {
    var i: isize = -1;
    var it = words(line);
    while (it.next()) |m| {
        if (std.ascii.eqlIgnoreCase(m.str, word)) {
            i = @intCast(m.start);
            break;
        }
    }
    return .{ .start = i, .end = i + @as(isize, @intCast(word.len)) };
}

/// Find matching closing parenthesis from an already open parenthesis scope
pub fn findParenMatch(s: []const u8) isize {
    var paren_count: isize = 1;
    // the quote of the string literal the character is in: a quote of the
    // other kind inside it is text (upstream #569)
    var quote: ?u8 = null;
    for (s, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '(') paren_count += 1 else if (c == ')') paren_count -= 1;
        if (paren_count == 0) return @intCast(i);
    }
    return -1;
}

/// Get code line prefix from current line and preceding continuation lines
pub fn getLinePrefix(a: Allocator, pre_lines: []const []const u8, curr_line_in: ?[]const u8, col_in: usize, qs: bool) !?[]const u8 {
    const curr = curr_line_in orelse return null;
    if (col_in > curr.len or std.mem.startsWith(u8, curr, "#")) return null;
    const prepend = try std.mem.concat(a, u8, pre_lines);
    const curr_line = try std.mem.concat(a, u8, &.{ prepend, curr });
    const col = col_in + prepend.len;
    const line_prefix = try std.ascii.allocLowerString(a, curr_line[0..col]);
    if (qs and (std.mem.indexOfAny(u8, line_prefix, "'\"") != null)) {
        var sq: usize = 0;
        var dq: usize = 0;
        for (line_prefix) |c| {
            if (c == '\'' and dq % 2 == 0) {
                sq += 1;
            } else if (c == '"' and sq % 2 == 0) {
                dq += 1;
            }
        }
        if (dq % 2 == 1 or sq % 2 == 1) return null;
    }
    return line_prefix;
}

/// Get the contents enclosed by the first pair of parenthesis
pub fn getParenSubstring(s: []const u8) ?[]const u8 {
    const i_1 = std.mem.indexOfScalar(u8, s, '(') orelse return null;
    const i_2 = std.mem.lastIndexOfScalar(u8, s, ')') orelse return null;
    if (i_1 < i_2) return s[i_1 + 1 .. i_2];
    return null;
}

pub const ParenLevel = struct { str: []const u8, sections: []Range };

/// Get sub-string corresponding to a single parenthesis level, via backward
/// search up through the line.
pub fn getParenLevel(a: Allocator, line: []const u8) !ParenLevel {
    if (line.len == 0) {
        const secs = try a.alloc(Range, 1);
        secs[0] = .{ .start = 0, .end = 0 };
        return .{ .str = "", .sections = secs };
    }
    var level: isize = 0;
    var in_string = false;
    var string_char: u8 = 0;
    var i_1: isize = @intCast(line.len);
    var sections: std.ArrayList(Range) = .empty;
    var i: isize = @as(isize, @intCast(line.len)) - 1;
    var last_i: isize = 0;
    while (i >= 0) : (i -= 1) {
        last_i = i;
        const c = line[@intCast(i)];
        if (in_string) {
            if (c == string_char) in_string = false;
            continue;
        }
        if (c == '(' or c == '[') {
            level -= 1;
            if (level == 0) {
                i_1 = i;
            } else if (level < 0) {
                try sections.append(a, .{ .start = i + 1, .end = i_1 });
                break;
            }
        } else if (c == ')' or c == ']') {
            level += 1;
            if (level == 1) try sections.append(a, .{ .start = i + 1, .end = i_1 });
        } else if (c == '\'' or c == '"') {
            in_string = true;
            string_char = c;
        }
    }
    if (level == 0) try sections.append(a, .{ .start = last_i, .end = i_1 });
    std.mem.reverse(Range, sections.items);
    var out: std.ArrayList(u8) = .empty;
    for (sections.items) |sec| try out.appendSlice(a, str.slice(line, sec.start, sec.end));
    return .{ .str = out.items, .sections = sections.items };
}

/// Get user-defined type field sequence terminating the given line
/// Intrinsic operators and logical literals written between dots
const dot_operators = [_][]const u8{ "eq", "ne", "lt", "le", "gt", "ge", "and", "or", "not", "eqv", "neqv", "true", "false", "xor" };

/// Whether the `.` at `i` of `text` separates a component (`rec.field`, the
/// DEC extension of hansec #45): it follows a name (not a number) or a `)`
/// and comes before a name that is not an intrinsic operator (`a.and.b`),
/// or ends the text (a line up to the position of a request)
pub fn isComponentDot(text: []const u8, i: usize) bool {
    if (i == 0 or i >= text.len or text[i] != '.') return false;
    if (i + 1 < text.len and !std.ascii.isAlphabetic(text[i + 1])) return false;
    const prev = text[i - 1];
    if (prev != ')') {
        if (!(std.ascii.isAlphanumeric(prev) or prev == '_')) return false;
        var s = i;
        while (s > 0 and (std.ascii.isAlphanumeric(text[s - 1]) or text[s - 1] == '_')) s -= 1;
        // a number: `1.e5`, `2.d0`
        if (!(std.ascii.isAlphabetic(text[s]) or text[s] == '_')) return false;
    }
    var e = i + 1;
    while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_')) e += 1;
    if (e < text.len and text[e] == '.') {
        for (dot_operators) |op| if (std.ascii.eqlIgnoreCase(text[i + 1 .. e], op)) return false;
    }
    return true;
}

/// `text` with the dots that separate components written `%`
pub fn dotComponents(a: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var out: ?[]u8 = null;
    // not in strings (`include "inc.f90"`)
    var quote: u8 = 0;
    for (text, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c != '.' or !isComponentDot(text, i)) continue;
        if (out == null) out = try a.dupe(u8, text);
        out.?[i] = '%';
    }
    return out orelse text;
}

test "component dots" {
    try std.testing.expect(isComponentDot("rec.field", 3));
    try std.testing.expect(isComponentDot("a(1).b", 4));
    try std.testing.expect(!isComponentDot("a.and.b", 1));
    try std.testing.expect(!isComponentDot("x .eq. y", 2));
    try std.testing.expect(!isComponentDot("1.e5", 1));
    try std.testing.expect(isComponentDot("x2.d0", 2));
    try std.testing.expect(isComponentDot("a.b.c", 1) and isComponentDot("a.b.c", 3));
    try std.testing.expect(isComponentDot("rec.", 3));
    try std.testing.expect(!isComponentDot("x = 1.", 5));
    const a = std.testing.allocator;
    const s = try dotComponents(a, "include 'a.f90' rec.f");
    defer if (s.ptr != "include 'a.f90' rec.f".ptr) a.free(s);
    try std.testing.expectEqualStrings("include 'a.f90' rec%f", s);
}

pub fn getVarStack(a: Allocator, line_in: []const u8) ![][]const u8 {
    const empty = try a.alloc([]const u8, 1);
    empty[0] = "";
    if (line_in.len == 0) return empty;
    const line = try dotComponents(a, line_in);
    const pl = try getParenLevel(a, line);
    if (pl.str.len == 0) return empty;
    var i_last: usize = 0;
    for (pl.sections, 0..) |sec, i| {
        if (!std.mem.startsWith(u8, str.strip(str.slice(line, sec.start, sec.end)), "%")) i_last = i;
    }
    var fv: std.ArrayList(u8) = .empty;
    for (pl.sections[i_last..]) |sec| try fv.appendSlice(a, str.slice(line, sec.start, sec.end));
    // "%".join(stripped parts)
    const parts = try str.split(a, fv.items, "%");
    for (parts) |*p| p.* = str.strip(p.*);
    const final_var = try std.mem.join(a, "%", parts);
    const op_split = try R().OBJBREAK.split(a, final_var);
    return str.split(a, op_split[op_split.len - 1], "%");
}

/// Generate placeholders for snippets: returns (arg_str, arg_snip)
pub fn getPlaceholders(a: Allocator, arg_list: []const []const u8) ![2][]const u8 {
    var holders: std.ArrayList([]const u8) = .empty;
    for (arg_list, 0..) |arg, i| {
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        if (eq) |e| {
            // opt_split[1] is the text between the first and second '='
            const rest = arg[e + 1 ..];
            const val = str.beforeFirst(rest, "=");
            try holders.append(a, try std.fmt.allocPrint(a, "{s}=${{{d}:{s}}}", .{ arg[0..e], i + 1, val }));
        } else {
            try holders.append(a, try std.fmt.allocPrint(a, "${{{d}:{s}}}", .{ i + 1, arg }));
        }
    }
    const arg_str = try std.fmt.allocPrint(a, "({s})", .{try std.mem.join(a, ", ", arg_list)});
    const arg_snip = try std.fmt.allocPrint(a, "({s})", .{try std.mem.join(a, ", ", holders.items)});
    return .{ arg_str, arg_snip };
}

/// Convert Fortran code to markdown
pub fn fortranMd(a: Allocator, code: ?[]const u8, docs: ?[]const u8) ![]const u8 {
    var msg: std.ArrayList(u8) = .empty;
    if (code) |c| if (c.len > 0) {
        try msg.appendSlice(a, "```{langid}\n");
        try msg.appendSlice(a, c);
        try msg.appendSlice(a, "\n```");
    };
    if (docs) |d| if (d.len > 0) {
        try msg.appendSlice(a, "\n-----\n");
        try msg.appendSlice(a, d);
    };
    return msg.items;
}

pub const KeywordInfo = struct {
    intent: ?[]const u8 = null,
    dimension: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    /// the cobounds of a coarray, `*` of `[*]`
    codimension: ?[]const u8 = null,

    pub fn get(self: KeywordInfo, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "intent")) return self.intent;
        if (std.mem.eql(u8, key, "dimension")) return self.dimension;
        if (std.mem.eql(u8, key, "pass")) return self.pass;
        if (std.mem.eql(u8, key, "codimension")) return self.codimension;
        return null;
    }

    /// None of them: what most objects have
    pub const empty: KeywordInfo = .{};

    /// A copy in `a`, or `empty` (shared) when there is nothing to copy
    pub fn dupe(self: KeywordInfo, a: Allocator) !*const KeywordInfo {
        if (self.intent == null and self.dimension == null and self.pass == null and self.codimension == null) return &empty;
        const out = try a.create(KeywordInfo);
        out.* = .{
            .intent = try str.dupeOpt(a, self.intent),
            .dimension = try str.dupeOpt(a, self.dimension),
            .pass = try str.dupeOpt(a, self.pass),
            .codimension = try str.dupeOpt(a, self.codimension),
        };
        return out;
    }
};

pub const MappedKeywords = struct { ids: []constants.Kw, info: KeywordInfo };

/// `sort` orders the keyword ids (`--sort_keywords`)
pub fn mapKeywords(a: Allocator, keywords: []const []const u8, sort: bool) !MappedKeywords {
    var ids: std.ArrayList(constants.Kw) = .empty;
    var info: KeywordInfo = .{};
    for (keywords) |kw| {
        const prefix_raw = str.strip(str.beforeFirst(str.beforeFirst(kw, "("), "["));
        const prefix = try std.ascii.allocLowerString(a, prefix_raw);
        const id = constants.Kw.fromName(prefix) orelse continue;
        try ids.append(a, id);
        if (id == .codimension) if (std.mem.indexOfScalar(u8, kw, '[')) |o| if (std.mem.lastIndexOfScalar(u8, kw, ']')) |c| {
            if (c > o) info.codimension = kw[o + 1 .. c];
        };
        if (std.mem.eql(u8, prefix, "intent") or std.mem.eql(u8, prefix, "dimension") or std.mem.eql(u8, prefix, "pass")) {
            if (getParenSubstring(kw)) |sub| {
                if (std.mem.eql(u8, prefix, "intent")) info.intent = sub;
                if (std.mem.eql(u8, prefix, "dimension")) info.dimension = sub;
                if (std.mem.eql(u8, prefix, "pass")) info.pass = sub;
            }
        }
    }
    if (sort) std.mem.sort(constants.Kw, ids.items, {}, constants.Kw.lessThan);
    return .{ .ids = ids.items, .info = info };
}

pub fn getKeywords(a: Allocator, ids: []const constants.Kw, info: KeywordInfo) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (ids) |id| {
        const rep = @tagName(id);
        const up = try std.ascii.allocUpperString(a, rep);
        if (info.get(rep)) |addl| {
            // cobounds go in brackets
            const fmt_open: []const u8 = if (id == .codimension) "[" else "(";
            const fmt_close: []const u8 = if (id == .codimension) "]" else ")";
            try out.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ up, fmt_open, addl, fmt_close }));
        } else {
            try out.append(a, up);
        }
    }
    return out.items;
}

const testing = std.testing;

test "helper functions" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(isize, 4), findParenMatch("a, b)"));
    try testing.expectEqual(@as(isize, 12), findParenMatch("a, (b, c), d)"));
    try testing.expectEqual(@as(isize, -1), findParenMatch("a, (b, (c, d)"));
    try testing.expectEqual(@as(isize, 29), findParenMatch("nt(sin(0.5))+8+len(\"ab((c\")-3) :: y"));
    try testing.expectEqual(@as(isize, 29), findParenMatch("nt(sin(0.5))+8+len('ab))c')-3) :: y"));
    try testing.expectEqual(@as(isize, 12), findParenMatch("len(\"don't\")) :: msg"));
    try testing.expectEqual(@as(isize, 14), findParenMatch("len('say \"hi')) :: msg"));

    const l1 = (try separateDefList(a, "var1, var2, var3")).?;
    try testing.expectEqual(@as(usize, 3), l1.len);
    const l2 = (try separateDefList(a, "var, init_var(3) = [1,2,3], array(3,3)")).?;
    try testing.expectEqualStrings("init_var(3) = [1,2,3]", l2[1]);
    try testing.expectEqualStrings("array(3,3)", l2[2]);

    const args = try splitArgs(a, "arr(2, 3), x=[1, 2], 'a,b', ");
    try testing.expectEqual(@as(usize, 4), args.len);
    try testing.expectEqualStrings("arr(2, 3)", args[0]);
    try testing.expectEqualStrings(" 'a,b'", args[2]);
    try testing.expectEqualStrings(" ", args[3]);

    try testing.expectEqualStrings("selected_real_kind(6, 30)", parameterValue(" = selected_real_kind(6, 30), b = 2").?);
    try testing.expectEqualStrings("[1, 2, 3]", parameterValue("=[1, 2, 3]").?);
    try testing.expectEqualStrings("'a,b'", parameterValue(" = 'a,b' , x").?);
    try testing.expect(parameterValue(" => null()") == null);

    try testing.expectEqualStrings("a, b, (c, d)", getParenSubstring("some line(a, b, (c, d))").?);
    try testing.expect(getParenSubstring("some line(a, b") == null);

    const pl = try getParenLevel(a, "CALL sub1(arg1(i),arg2");
    try testing.expectEqualStrings("arg1,arg2", pl.str);
    try testing.expectEqual(@as(usize, 2), pl.sections.len);
    try testing.expectEqual(@as(isize, 10), pl.sections[0].start);
    try testing.expectEqual(@as(isize, 14), pl.sections[0].end);
    const pl2 = try getParenLevel(a, "");
    try testing.expectEqualStrings("", pl2.str);

    const vs = try getVarStack(a, "myarray( i ) % foo   % bar");
    try testing.expectEqual(@as(usize, 3), vs.len);
    try testing.expectEqualStrings("myarray", vs[0]);
    try testing.expectEqualStrings("bar", vs[2]);
    const vs2 = try getVarStack(a, "CALL self%method(this%foo");
    try testing.expectEqual(@as(usize, 2), vs2.len);
    try testing.expectEqualStrings("this", vs2[0]);

    const ph = try getPlaceholders(a, &.{ "x", "y=2", "z" });
    try testing.expectEqualStrings("(x, y=2, z)", ph[0]);
    try testing.expectEqualStrings("(${1:x}, y=${2:2}, ${3:z})", ph[1]);

    try testing.expect(!detectFixedFormat(&.{" free format"}));
    try testing.expect(!detectFixedFormat(&.{" INTEGER, PARAMETER :: N = 10"}));
    try testing.expect(detectFixedFormat(&.{"C Fixed format"}));
    try testing.expect(!detectFixedFormat(&.{"trailing line & ! comment"}));
    try testing.expect(detectFixedFormat(&.{ "#if defined(A) && !defined(B)", "C Fixed format", "#endif" }));
    try testing.expect(detectFixedFormat(&.{ "#if defined(A) \\\\ ", " && !defined(B)", "C Fixed format", "#endif" }));
    try testing.expect(!detectFixedFormat(&.{ "#if defined(A) \\\\", "&& \\\\", "!defined(B)", " free format", "#endif" }));

    try testing.expectEqualStrings("print *, '   '", try stripStrings(a, "print *, 'abc'", true));
    try testing.expect((try getLinePrefix(a, &.{""}, "#pragma once", 0, true)) == null);
}

/// Random lines made of the pieces the line scanners look at
fn randomLine(rng: std.Random, buf: []u8) []const u8 {
    const pieces = [_][]const u8{
        " ",    "  ",      "     ", "      ",    "!",                "&",   "#",   ":",        "c",  "C", "d",
        "D",    "*",       "$",     "omp",       "OMP",              "Omp", "om",  "<",        ">",  "1", "23",
        "'",    "\"",      "\t",    "\x0b",      "a",                "Z",   "x_1", "\xc3\xa9", "$x", "5", "_",
        "real", "INTEGER", "type",  "Character", "double precision", "(",   ")",   ",",        "=",  "0",
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
    var fixed_openmp = try Regex.compile(ta, "[!c\\*]\\$OMP", regex.I);
    defer fixed_openmp.deinit();
    var free_openmp = try Regex.compile(ta, "[ ]*!\\$OMP", regex.I);
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
    var sq_string = try Regex.compile(ta, "\\'[^\\']*\\'", regex.I);
    defer sq_string.deinit();
    var dq_string = try Regex.compile(ta, "\\\"[^\\\"]*\\\"", regex.I);
    defer dq_string.deinit();

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
        try testing.expectEqual(fixed_openmp.match(line) != null, isOpenMp(true, line));
        try testing.expectEqual(free_openmp.match(line) != null, isOpenMp(false, line));
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
                const line_end = str.strip(str.beforeFirst(line, "!"));
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

        const removed = try dq_string.sub(a, "", try sq_string.sub(a, "", line));
        try testing.expectEqualStrings(removed, try stripStrings(a, line, false));
        const blank = struct {
            fn f(q: u8, ba: Allocator, out: *std.ArrayList(u8), m: regex.Match) Allocator.Error!void {
                try out.append(ba, q);
                try out.appendNTimes(ba, ' ', m.str().len - 2);
                try out.append(ba, q);
            }
        }.f;
        const blanked = try dq_string.subFn(a, try sq_string.subFn(a, line, @as(u8, '\''), blank), @as(u8, '"'), blank);
        try testing.expectEqualStrings(blanked, try stripStrings(a, line, true));

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
