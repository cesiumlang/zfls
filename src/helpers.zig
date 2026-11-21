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
    var logicals = R().LOGICAL.iterator(line);
    while (logicals.next()) |m| {
        if (m.start(0) <= char_pos and char_pos <= m.end(0)) return m.str();
    }
    // the string literals, found from left to right (#231)
    var from: usize = 0;
    while (std.mem.findAnyPos(u8, line, from, "'\"")) |open| {
        const close = stringEnd(line, open) orelse break;
        if (open <= char_pos and char_pos <= close + 1) return line[open .. close + 1];
        from = close + 1;
    }
    const regexs = [_]*const @import("regex.zig").Regex{ &R().WORD, &R().NUMBER };
    for (regexs) |r| {
        var it = r.iterator(line);
        while (it.next()) |m| {
            if (m.start(0) <= char_pos and char_pos <= m.end(0)) return m.str();
        }
    }
    return "";
}

// Line scanners (helpers/scanners.zig)
const scanners = @import("helpers/scanners.zig");
pub const leadingSpaces = scanners.leadingSpaces;
pub const isFixedComment = scanners.isFixedComment;
pub const isFreeComment = scanners.isFreeComment;
pub const isComment = scanners.isComment;
pub const markComments = scanners.markComments;
pub const docMark = scanners.docMark;
pub const isOpenMp = scanners.isOpenMp;
pub const isFixedCont = scanners.isFixedCont;
pub const tabFormatTab = scanners.tabFormatTab;
pub const tabContStart = scanners.tabContStart;
pub const fixedContStart = scanners.fixedContStart;
pub const fixedContMark = scanners.fixedContMark;
pub const fixedStmtStart = scanners.fixedStmtStart;
pub const freeContEnd = scanners.freeContEnd;
pub const isPpDirective = scanners.isPpDirective;
pub const Word = scanners.Word;
pub const WordIterator = scanners.WordIterator;
pub const words = scanners.words;
pub const detectFixedFormat = scanners.detectFixedFormat;
pub const LabelResult = scanners.LabelResult;
pub const stripLineLabel = scanners.stripLineLabel;

/// The index of the quote that closes the string literal opened by the
/// quote at `s[open]`: the next quote of the same kind that is not doubled
/// (`'it''s'`); a quote of the other kind is text. Null when the line ends
/// inside the literal.
pub fn stringEnd(s: []const u8, open: usize) ?usize {
    const q = s[open];
    var i = open + 1;
    while (std.mem.findScalarPos(u8, s, i, q)) |close| {
        if (close + 1 < s.len and s[close + 1] == q) {
            i = close + 2;
            continue;
        }
        return close;
    }
    return null;
}

/// Whether the apostrophe at `s[i]` is DEC's record mark of `READ (u'r)`,
/// `FIND (u'r)` (ifx), no literal: right after a digit or a letter, with
/// no other apostrophe after it on the line, as ifx's scanner has it
pub fn isRecordMark(s: []const u8, i: usize) bool {
    return s[i] == '\'' and i > 0 and std.ascii.isAlphanumeric(s[i - 1]) and std.mem.findScalarPos(u8, s, i + 1, '\'') == null;
}

/// Strips string literals from code line, found from left to right: the
/// first quote opens a literal and only the same kind closes it.
/// `maintain_len` blanks their contents instead of removing them. A literal
/// the line ends in is left as it is.
pub fn stripStrings(a: Allocator, in_line: []const u8, maintain_len: bool) ![]const u8 {
    if (std.mem.findAny(u8, in_line, "'\"") == null) return in_line;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, in_line.len);
    var last: usize = 0;
    while (std.mem.findAnyPos(u8, in_line, last, "'\"")) |open| {
        const close = stringEnd(in_line, open) orelse break;
        if (maintain_len) {
            out.appendSliceAssumeCapacity(in_line[last .. open + 1]);
            out.appendNTimesAssumeCapacity(' ', close - open - 1);
            out.appendAssumeCapacity(in_line[close]);
        } else {
            out.appendSliceAssumeCapacity(in_line[last..open]);
        }
        last = close + 1;
    }
    out.appendSliceAssumeCapacity(in_line[last..]);
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

/// `text` with each run of white space outside strings made one blank (a
/// value written over continuation lines), and its strings as they are
pub fn collapseBlanks(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var quote: u8 = 0;
    var blank = false;
    for (str.strip(text)) |c| {
        if (quote == 0 and std.ascii.isWhitespace(c)) {
            blank = true;
            continue;
        }
        if (blank) try out.append(a, ' ');
        blank = false;
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        }
        try out.append(a, c);
    }
    return out.items;
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

/// Separate definition lists, skipping parenthesis and bracket groups, and
/// the old-style initial values between slashes (`k /3/, v(3) /1, 2, 3/`,
/// an extension of gfortran, ifx and LLVM Flang)
pub fn separateDefList(a: Allocator, test_str: []const u8) !?[][]const u8 {
    const stripped = try stripStrings(a, test_str, false);
    var paren_count: isize = 0;
    var def_list: std.ArrayList([]const u8) = .empty;
    var curr: std.ArrayList(u8) = .empty;
    // in `/.../` after an entity, which has no `=` initialization
    var in_slashes = false;
    var has_eq = false;
    for (stripped) |c| {
        switch (c) {
            '(', '[' => paren_count += 1,
            ')', ']' => paren_count -= 1,
            '=' => if (paren_count == 0) {
                has_eq = true;
            },
            '/' => if (paren_count == 0 and !has_eq) {
                in_slashes = !in_slashes;
            },
            ',' => if (paren_count == 0 and !in_slashes) {
                const s = str.strip(curr.items);
                has_eq = false;
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

/// The name of an entity of a declaration's list, with its bounds, length
/// and codimensions (`v(3)[*]*8`): what is before its initialization, an
/// `= value` or an old-style `/value/` outside parentheses and brackets
/// (`x(1:int(n, kind=8))` has none)
pub fn entityBeforeInit(item: []const u8) []const u8 {
    var depth: usize = 0;
    for (item, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        '=', '/' => if (depth == 0) return item[0..i],
        else => {},
    };
    return item;
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
    if (qs and (std.mem.findAny(u8, line_prefix, "'\"") != null)) {
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
    const i_1 = std.mem.findScalar(u8, s, '(') orelse return null;
    const i_2 = std.mem.findScalarLast(u8, s, ')') orelse return null;
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
    if (std.mem.findScalar(u8, text, '.') == null) return text;
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
        const eq = std.mem.findScalar(u8, arg, '=');
        if (eq) |e| {
            // opt_split[1] is the text between the first and second '='
            const rest = arg[e + 1 ..];
            const val = str.beforeFirst(rest, "=");
            try holders.append(a, try a.print("{s}=${{{d}:{s}}}", .{ arg[0..e], i + 1, val }));
        } else {
            try holders.append(a, try a.print("${{{d}:{s}}}", .{ i + 1, arg }));
        }
    }
    const arg_str = try a.print("({s})", .{try std.mem.join(a, ", ", arg_list)});
    const arg_snip = try a.print("({s})", .{try std.mem.join(a, ", ", holders.items)});
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
        if (id == .codimension) if (std.mem.findScalar(u8, kw, '[')) |o| if (std.mem.findScalarLast(u8, kw, ']')) |c| {
            if (c > o) info.codimension = kw[o + 1 .. c];
        };
        if (std.mem.eql(u8, prefix, "intent") or std.mem.eql(u8, prefix, "dimension") or std.mem.eql(u8, prefix, "pass")) {
            // blanks may surround a name: `pass ( self )` names `self`, and
            // `intent ( in )` is IN (the bounds keep theirs, as fortls)
            if (getParenSubstring(kw)) |sub_raw| {
                const sub = str.strip(sub_raw);
                if (std.mem.eql(u8, prefix, "intent")) info.intent = sub;
                if (std.mem.eql(u8, prefix, "dimension")) info.dimension = sub_raw;
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
            try out.append(a, try a.print("{s}{s}{s}{s}", .{ up, fmt_open, addl, fmt_close }));
        } else {
            try out.append(a, up);
        }
    }
    return out.items;
}

const testing = std.testing;

test "DEC's record mark is no literal" {
    try testing.expect(isRecordMark("read (3'5) a", 7));
    try testing.expect(isRecordMark("find (iu'irec)", 8));
    try testing.expect(!isRecordMark("print *, 'abc'", 9));
    try testing.expect(!isRecordMark("x = z'7f'", 5));
    // ifx reads a literal to the next apostrophe, even in a comment
    try testing.expect(!isRecordMark("read (3'5) a ! it's", 7));
}

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
    const l3 = (try separateDefList(a, "k /3/, v(3) /1, 2, 3/, w = a / b, z")).?;
    try testing.expectEqual(@as(usize, 4), l3.len);
    try testing.expectEqualStrings("v(3) /1, 2, 3/", l3[1]);
    try testing.expectEqualStrings("w = a / b", l3[2]);
    try testing.expectEqualStrings("v(3) ", entityBeforeInit("v(3) /1, 2, 3/"));
    try testing.expectEqualStrings("x(1:int(n, kind=8))", entityBeforeInit("x(1:int(n, kind=8))"));
    try testing.expectEqualStrings("y ", entityBeforeInit("y = 2"));

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
    // the first quote opens a literal, only the same kind closes it (#231)
    try testing.expectEqualStrings("x = \"    \", t = ' '", try stripStrings(a, "x = \"it's\", t = 'x'", true));
    try testing.expectEqualStrings("f(\"    \", \"     \", 1)", try stripStrings(a, "f(\"it's\", \"Bob's\", 1)", true));
    try testing.expectEqualStrings("f(, , 1)", try stripStrings(a, "f(\"it's\", \"Bob's\", 1)", false));
    try testing.expectEqualStrings("print *, '        ', \"    \", x", try stripStrings(a, "print *, 'say \"hi\"', \"it's\", x", true));
    // a doubled quote stays inside
    try testing.expectEqualStrings("f('     ', \"    \", '', 1)", try stripStrings(a, "f('it''s', \"a\"\"b\", '', 1)", true));
    try testing.expectEqualStrings("f(, 1)", try stripStrings(a, "f('it''s', 1)", false));
    // a literal the line ends in is left as it is
    try testing.expectEqualStrings("a = , b = \"it's", try stripStrings(a, "a = 'x', b = \"it's", false));
    try testing.expectEqual(@as(?usize, 6), stringEnd("'it''s'", 0));
    try testing.expectEqual(@as(?usize, null), stringEnd("'it''s", 0));
    try testing.expect((try getLinePrefix(a, &.{""}, "#pragma once", 0, true)) == null);
}
