//! CASE values of a SELECT CASE construct that overlap an earlier one
//! (#850): `case (1)` twice, `case (1:5)` and `case (4, 9)`. gfortran,
//! Flang and ifx all report it. Only integer and one-character values
//! written as literals are told, in a CASE statement on one line; a
//! construct with any other value is left alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const selection = @import("selection.zig");
const typing = @import("argcheck/typing.zig");
const inactive_lines = @import("inactive.zig");
const FortranFile = @import("parser.zig").FortranFile;

pub const Problem = struct { line: usize, start: usize, end: usize, message: []const u8 };

const Interval = struct { lo: i64, hi: i64 };

const Select = struct {
    /// a SELECT TYPE or RANK, or a CASE statement that is not read
    unknown: bool = false,
    seen: std.ArrayList(Interval) = .empty,
    /// 0: no value yet, 1: integers, 2: characters
    kind: u8 = 0,
};

/// The code of the line the statement starts on, with the label field and
/// the comment cut, and its offset in the line
fn codeOf(file: *const FortranFile, raw: []const u8) ?struct { text: []const u8, offset: usize } {
    if (helpers.isComment(file.fixed, raw)) return null;
    var start: usize = 0;
    if (file.fixed) {
        start = @min(helpers.fixedStmtStart(raw), raw.len);
    } else {
        while (start < raw.len and (raw[start] == ' ' or raw[start] == '\t')) start += 1;
        // a numeric label
        var k = start;
        while (k < raw.len and std.ascii.isDigit(raw[k])) k += 1;
        if (k > start and k < raw.len and raw[k] == ' ') start = k + 1;
    }
    const end = selection.codeEnd(raw);
    if (start >= end) return null;
    const body = raw[start..end];
    const text = std.mem.trim(u8, body, " \t\r");
    if (text.len == 0) return null;
    return .{ .text = text, .offset = start + std.mem.findNone(u8, body, " \t\r").? };
}

fn startsWord(text: []const u8, word: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(text, word)) return false;
    return text.len == word.len or !(std.ascii.isAlphanumeric(text[word.len]) or text[word.len] == '_');
}

/// The statement after a construct name (`name: select case`)
fn afterName(text: []const u8) []const u8 {
    var i: usize = 0;
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return text;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    var j = i;
    while (j < text.len and text[j] == ' ') j += 1;
    if (j < text.len and text[j] == ':' and !(j + 1 < text.len and text[j + 1] == ':')) {
        j += 1;
        while (j < text.len and text[j] == ' ') j += 1;
        return text[j..];
    }
    return text;
}

fn value(text: []const u8, kind: *u8) ?i64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 3 and (t[0] == '\'' or t[0] == '"') and t[2] == t[0]) {
        if (kind.* == 1) return null;
        kind.* = 2;
        return t[1];
    }
    if (t.len == 0) return null;
    for (t, 0..) |ch, i| if (!(std.ascii.isDigit(ch) or (i == 0 and (ch == '-' or ch == '+')))) return null;
    if (kind.* == 2) return null;
    kind.* = 1;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

pub fn check(a: Allocator, file: *const FortranFile) ![]const Problem {
    const inactive = (try inactive_lines.of(a, file)).lines;
    var out: std.ArrayList(Problem) = .empty;
    var stack: std.ArrayList(Select) = .empty;
    const n = file.nLines();
    var ln: usize = 0;
    while (ln < n) {
        const st = selection.statementLines(file, ln);
        defer ln = st.last + 1;
        if (inactive[ln]) continue;
        const raw = file.getLine(ln, false) orelse continue;
        const c = codeOf(file, raw) orelse continue;
        const text = afterName(c.text);
        const continued = st.last > st.first;
        if (startsWord(text, "select") or startsWord(text, "selectcase")) {
            const rest = if (startsWord(text, "select")) std.mem.trimStart(u8, text[6..], " ") else text;
            const is_case = startsWord(rest, "case") or startsWord(text, "selectcase");
            try stack.append(a, .{ .unknown = !is_case or continued });
        } else if ((startsWord(text, "end") and startsWord(std.mem.trimStart(u8, text[3..], " "), "select")) or startsWord(text, "endselect")) {
            if (stack.items.len > 0) _ = stack.pop();
        } else if (startsWord(text, "case")) {
            if (stack.items.len == 0) continue;
            const top = &stack.items[stack.items.len - 1];
            if (top.unknown) continue;
            const rest = std.mem.trimStart(u8, text[4..], " ");
            if (rest.len == 0 or rest[0] != '(') continue;
            const close = typing.matching(rest, 0) orelse {
                top.unknown = true;
                continue;
            };
            if (continued) {
                top.unknown = true;
                continue;
            }
            const list = rest[1..close];
            const list_at = c.offset + (c.text.len - rest.len) + 1;
            var pos: usize = 0;
            while (pos <= list.len) {
                const comma = typing.topLevel(list[pos..], ',') orelse list.len - pos;
                const item = list[pos .. pos + comma];
                const iv = interval(item, &top.kind) orelse {
                    top.unknown = true;
                    break;
                };
                for (top.seen.items) |s| if (iv.lo <= s.hi and s.lo <= iv.hi) {
                    const trimmed = std.mem.trim(u8, item, " ");
                    const at = list_at + pos + (std.mem.find(u8, item, trimmed) orelse 0);
                    try out.append(a, .{ .line = ln, .start = at, .end = at + trimmed.len, .message = try a.print("CASE value {s} overlaps an earlier CASE value of the construct", .{trimmed}) });
                    break;
                };
                try top.seen.append(a, iv);
                pos += comma + 1;
            }
        }
    }
    return out.items;
}

/// The values of a case item, `3`, `1:5`, `:0`, `'a'`
fn interval(item: []const u8, kind: *u8) ?Interval {
    if (typing.topLevel(item, ':')) |colon| {
        const lo_text = std.mem.trim(u8, item[0..colon], " ");
        const hi_text = std.mem.trim(u8, item[colon + 1 ..], " ");
        const lo: i64 = if (lo_text.len == 0) std.math.minInt(i64) else value(lo_text, kind) orelse return null;
        const hi: i64 = if (hi_text.len == 0) std.math.maxInt(i64) else value(hi_text, kind) orelse return null;
        return .{ .lo = lo, .hi = hi };
    }
    const v = value(item, kind) orelse return null;
    return .{ .lo = v, .hi = v };
}
