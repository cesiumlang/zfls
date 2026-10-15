//! Port of `fortls.helper_functions`

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("str.zig");
const patterns = @import("patterns.zig");
const constants = @import("constants.zig");

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

/// Detect fixed/free format by looking for characters in label columns
/// and variable declarations before column 6.
pub fn detectFixedFormat(file_lines: []const []const u8) bool {
    var pp_continue = false;
    for (file_lines) |line| {
        if (std.mem.startsWith(u8, line, "#") or pp_continue) {
            pp_continue = std.mem.endsWith(u8, str.rstrip(line), "\\");
            continue;
        }
        if (R().FREE_FORMAT_TEST.match(line) != null) return false;
        if (R().VAR.match(line)) |m| {
            if (m.start(1) < 6) return false;
        }
        if (R().FIXED_COMMENT.match(line) == null) {
            const line_end = str.strip(str.beforeFirst(line, "!"));
            if (line_end.len > 0 and std.mem.endsWith(u8, line_end, "&")) return false;
        }
    }
    return true;
}

pub const LabelResult = struct { line: []const u8, label: ?[]const u8 };

/// Strip leading numeric line label
pub fn stripLineLabel(a: Allocator, line: []const u8) !LabelResult {
    const m = R().LINE_LABEL.match(line) orelse return .{ .line = line, .label = null };
    const label = m.group(1).?;
    const out = try a.alloc(u8, line.len);
    @memcpy(out, line);
    @memset(out[m.start(1)..m.end(1)], ' ');
    return .{ .line = out, .label = label };
}

const StripCtx = struct { quote: u8 };

fn replQuote(ctx: StripCtx, a: Allocator, out: *std.ArrayList(u8), m: @import("regex.zig").Match) Allocator.Error!void {
    const n = m.str().len;
    try out.append(a, ctx.quote);
    try out.appendNTimes(a, ' ', n - 2);
    try out.append(a, ctx.quote);
}

/// Strips string literals from code line
pub fn stripStrings(a: Allocator, in_line: []const u8, maintain_len: bool) ![]const u8 {
    if (std.mem.indexOfAny(u8, in_line, "'\"") == null) return in_line;
    if (maintain_len) {
        const tmp = try R().SQ_STRING.subFn(a, in_line, StripCtx{ .quote = '\'' }, replQuote);
        return R().DQ_STRING.subFn(a, tmp, StripCtx{ .quote = '"' }, replQuote);
    }
    const tmp = try R().SQ_STRING.sub(a, "", in_line);
    return R().DQ_STRING.sub(a, "", tmp);
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
    var it = R().WORD.iterator(line);
    while (it.next()) |m| {
        if (std.mem.eql(u8, m.str(), word)) {
            i = @intCast(m.start(0));
            break;
        }
    }
    return .{ .start = i, .end = i + @as(isize, @intCast(word.len)) };
}

/// Find matching closing parenthesis from an already open parenthesis scope
pub fn findParenMatch(s: []const u8) isize {
    var paren_count: isize = 1;
    var sq = false;
    var dq = false;
    for (s, 0..) |c, i| {
        if (c == '\'') sq = !sq;
        if (c == '"') dq = !dq;
        if (sq or dq) continue;
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
pub fn getVarStack(a: Allocator, line: []const u8) ![][]const u8 {
    const empty = try a.alloc([]const u8, 1);
    empty[0] = "";
    if (line.len == 0) return empty;
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

    pub fn get(self: KeywordInfo, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "intent")) return self.intent;
        if (std.mem.eql(u8, key, "dimension")) return self.dimension;
        if (std.mem.eql(u8, key, "pass")) return self.pass;
        return null;
    }

    pub fn dupe(self: KeywordInfo, a: Allocator) !KeywordInfo {
        return .{
            .intent = try str.dupeOpt(a, self.intent),
            .dimension = try str.dupeOpt(a, self.dimension),
            .pass = try str.dupeOpt(a, self.pass),
        };
    }
};

pub const MappedKeywords = struct { ids: []u8, info: KeywordInfo };

/// Global keyword ordering setting (`--sort_keywords`)
pub var sort_keywords: bool = true;

pub fn mapKeywords(a: Allocator, keywords: []const []const u8) !MappedKeywords {
    var ids: std.ArrayList(u8) = .empty;
    var info: KeywordInfo = .{};
    for (keywords) |kw| {
        const prefix_raw = str.strip(str.beforeFirst(kw, "("));
        const prefix = try std.ascii.allocLowerString(a, prefix_raw);
        const id = constants.keywordId(prefix) orelse continue;
        try ids.append(a, id);
        if (std.mem.eql(u8, prefix, "intent") or std.mem.eql(u8, prefix, "dimension") or std.mem.eql(u8, prefix, "pass")) {
            if (getParenSubstring(kw)) |sub| {
                if (std.mem.eql(u8, prefix, "intent")) info.intent = sub;
                if (std.mem.eql(u8, prefix, "dimension")) info.dimension = sub;
                if (std.mem.eql(u8, prefix, "pass")) info.pass = sub;
            }
        }
    }
    if (sort_keywords) std.mem.sort(u8, ids.items, {}, std.sort.asc(u8));
    return .{ .ids = ids.items, .info = info };
}

pub fn getKeywords(a: Allocator, ids: []const u8, info: KeywordInfo) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (ids) |id| {
        const rep = constants.keyword_list[id];
        const up = try std.ascii.allocUpperString(a, rep);
        if (info.get(rep)) |addl| {
            try out.append(a, try std.fmt.allocPrint(a, "{s}({s})", .{ up, addl }));
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

    const l1 = (try separateDefList(a, "var1, var2, var3")).?;
    try testing.expectEqual(@as(usize, 3), l1.len);
    const l2 = (try separateDefList(a, "var, init_var(3) = [1,2,3], array(3,3)")).?;
    try testing.expectEqualStrings("init_var(3) = [1,2,3]", l2[1]);
    try testing.expectEqualStrings("array(3,3)", l2[2]);

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
