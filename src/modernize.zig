//! Rewrites of legacy statements that code actions offer (#985), each only
//! where the meaning is certain to stay: a labeled DO loop as DO ... END
//! DO, and an arithmetic IF as an IF block. Lines of text in, the lines'
//! new text out.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A rewrite of lines `first` to `last` (0-based) into `lines`
pub const Rewrite = struct { first: usize, last: usize, lines: []const []const u8 };

/// The statement of a line: its label (empty: none), the text from the
/// statement on, and where that starts
const Statement = struct { label: []const u8, text: []const u8, start: usize };

fn statement(line: []const u8, fixed: bool) ?Statement {
    if (fixed) {
        if (line.len == 0 or line[0] == 'c' or line[0] == 'C' or line[0] == '*' or line[0] == '!') return null;
        // a continuation line is not one statement's start
        if (line.len > 5 and line[5] != ' ' and line[5] != '0') return null;
        const label = std.mem.trim(u8, line[0..@min(line.len, 5)], " ");
        for (label) |c| if (!std.ascii.isDigit(c)) return null;
        const body_start = @min(line.len, 6);
        const lead = std.mem.trimStart(u8, line[body_start..], " ");
        return .{ .label = label, .text = std.mem.trimEnd(u8, lead, " \r"), .start = line.len - lead.len };
    }
    const lead = std.mem.trimStart(u8, line, " \t");
    var e: usize = 0;
    while (e < lead.len and std.ascii.isDigit(lead[e])) e += 1;
    if (e > 0 and (e == lead.len or lead[e] == ' ' or lead[e] == '\t')) {
        const rest = std.mem.trimStart(u8, lead[e..], " \t");
        return .{ .label = lead[0..e], .text = std.mem.trimEnd(u8, rest, " \r"), .start = line.len - rest.len };
    }
    return .{ .label = "", .text = std.mem.trimEnd(u8, lead, " \r"), .start = line.len - lead.len };
}

/// The code of `text`, lowercase, without character literals and comment
fn code(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var quote: u8 = 0;
    for (text) |c| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '!') break;
        try out.append(a, std.ascii.toLower(c));
    }
    return out.items;
}

/// Whether `text` has `number` as a token of its own
fn hasNumber(text: []const u8, number: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, text, i, number)) |at| : (i = at + 1) {
        const before = at == 0 or !(std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_' or text[at - 1] == '.');
        const end = at + number.len;
        const after = end == text.len or !(std.ascii.isAlphanumeric(text[end]) or text[end] == '_' or text[end] == '.');
        if (before and after) return true;
    }
    return false;
}

/// Whether a statement's code may refer to a label: the statements that
/// take labels (GO TO, IF, I/O, ASSIGN, DO); a line of none cannot
fn mayRefer(c: []const u8) bool {
    for ([_][]const u8{ "goto", "go to", "if", "err", "end", "eor", "fmt", "assign", "read", "write", "print", "do", "open", "close", "inquire", "rewind", "backspace" }) |w| {
        if (std.mem.find(u8, c, w) != null) return true;
    }
    return false;
}

/// The labeled DO loop of line `at` as DO ... END DO, or null: the line is
/// none, its terminal statement is not found, or another statement may
/// refer to its label (a GO TO, an inner DO that shares it)
pub fn labeledDo(a: Allocator, lines: []const []const u8, at: usize, fixed: bool) !?Rewrite {
    const st = statement(lines[at], fixed) orelse return null;
    const c = try code(a, st.text);
    if (!std.mem.startsWith(u8, c, "do") or c.len < 3 or std.ascii.isAlphabetic(c[2]) or c[2] == '_') return null;
    var rest = std.mem.trimStart(u8, c[2..], " ");
    var e: usize = 0;
    while (e < rest.len and std.ascii.isDigit(rest[e])) e += 1;
    if (e == 0) return null;
    const label = rest[0..e];
    rest = std.mem.trimStart(u8, rest[e..], " ");
    if (rest.len > 0 and rest[0] == ',') rest = std.mem.trimStart(u8, rest[1..], " ");
    if (rest.len == 0) return null;
    // the terminal statement, and no other mention of the label
    var terminal: ?usize = null;
    for (lines, 0..) |line, i| {
        if (i == at) continue;
        const s = statement(line, fixed) orelse continue;
        if (std.mem.eql(u8, s.label, label)) {
            if (terminal != null or i < at) return null;
            terminal = i;
        }
        const sc = try code(a, s.text);
        if (mayRefer(sc) and hasNumber(sc, label)) return null;
    }
    const end = terminal orelse return null;
    if (fixed and end + 1 < lines.len and statement(lines[end + 1], true) == null and lines[end + 1].len > 5 and lines[end + 1][5] != ' ') return null;
    // the DO statement without its label, in the text as written
    const body = st.text[2..];
    const label_at = std.mem.find(u8, body, label).?;
    var after = std.mem.trimStart(u8, body[label_at + label.len ..], " ");
    if (after.len > 0 and after[0] == ',') after = std.mem.trimStart(u8, after[1..], " ");
    const indent = lines[at][0..st.start];
    const do_kw = st.text[0..2];
    const do_line = try std.mem.concat(a, u8, &.{ if (fixed) try blankLabel(a, indent) else indent, do_kw, " ", after });
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, do_line);
    for (lines[at + 1 .. end]) |l| try out.append(a, l);
    const ts = statement(lines[end], fixed).?;
    const end_do = try std.mem.concat(a, u8, &.{ if (fixed) try blankLabel(a, indent) else indent, if (std.ascii.isUpper(do_kw[0])) "END DO" else "end do" });
    const tc = try code(a, ts.text);
    if (!std.mem.eql(u8, std.mem.trim(u8, tc, " "), "continue")) {
        // the terminal statement stays in the loop, without its label
        const blank = try a.alloc(u8, ts.start);
        @memset(blank, ' ');
        if (!fixed) @memcpy(blank[0..@min(blank.len, indent.len)], indent[0..@min(blank.len, indent.len)]);
        try out.append(a, try std.mem.concat(a, u8, &.{ blank, ts.text }));
    }
    try out.append(a, end_do);
    return .{ .first = at, .last = end, .lines = out.items };
}

/// A fixed-form line's start before the statement, without its label
fn blankLabel(a: Allocator, start: []const u8) ![]const u8 {
    const out = try a.dupe(u8, start);
    for (out[0..@min(out.len, 5)]) |*c| c.* = ' ';
    return out;
}

/// The arithmetic IF of `line`, `if (x) 10, 20, 30`, as an IF block of GO
/// TOs, or null: the line is none, or its expression has parentheses (a
/// function that it would call twice could do something)
pub fn arithmeticIf(a: Allocator, line: []const u8, fixed: bool) !?[]const []const u8 {
    const st = statement(line, fixed) orelse return null;
    // a label is a GO TO's target, which the block would have to keep; a
    // character literal moves the code's places from the text's
    if (st.label.len > 0 or std.mem.findAny(u8, st.text, "'\"") != null) return null;
    const c = try code(a, st.text);
    if (!std.mem.startsWith(u8, c, "if")) return null;
    const open = std.mem.findScalar(u8, c, '(') orelse return null;
    if (std.mem.trim(u8, c[2..open], " ").len != 0) return null;
    const close = std.mem.findScalarPos(u8, c, open + 1, ')') orelse return null;
    const expr = std.mem.trim(u8, st.text[open + 1 .. close], " ");
    if (expr.len == 0 or std.mem.findAny(u8, expr, "()") != null) return null;
    var it = std.mem.splitScalar(u8, c[close + 1 ..], ',');
    var labels: [3][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 3) return null;
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) return null;
        for (t) |ch| if (!std.ascii.isDigit(ch)) return null;
        labels[n] = t;
    }
    if (n != 3) return null;
    const indent = line[0..st.start];
    const inner = try std.mem.concat(a, u8, &.{ indent, "   " });
    var out: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, labels[0], labels[1]) and std.mem.eql(u8, labels[1], labels[2])) {
        try out.append(a, try a.print("{s}go to {s}", .{ indent, labels[0] }));
        return out.items;
    }
    try out.append(a, try a.print("{s}if ({s} < 0) then", .{ indent, expr }));
    try out.append(a, try a.print("{s}go to {s}", .{ inner, labels[0] }));
    try out.append(a, try a.print("{s}else if ({s} == 0) then", .{ indent, expr }));
    try out.append(a, try a.print("{s}go to {s}", .{ inner, labels[1] }));
    try out.append(a, try a.print("{s}else", .{indent}));
    try out.append(a, try a.print("{s}go to {s}", .{ inner, labels[2] }));
    try out.append(a, try a.print("{s}end if", .{indent}));
    return out.items;
}

const testing = std.testing;

fn expectLines(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a labeled DO with a CONTINUE becomes DO ... END DO (#985)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const free = [_][]const u8{ "  do 10 i = 1, n", "    s = s + i", "10 continue", "  x = 10" };
    const r = (try labeledDo(a, &free, 0, false)).?;
    try testing.expectEqual(2, r.last);
    try expectLines(&.{ "  do i = 1, n", "    s = s + i", "  end do" }, r.lines);
    const fixed = [_][]const u8{ "      DO 20, I = 1, N", "        S = S + I", "   20 S = S * 2" };
    const f = (try labeledDo(a, &fixed, 0, true)).?;
    try expectLines(&.{ "      DO I = 1, N", "        S = S + I", "      S = S * 2", "      END DO" }, f.lines);
}

test "a labeled DO whose label another statement names stays (#985)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const goto = [_][]const u8{ "do 10 i = 1, n", "if (i > 3) go to 10", "10 continue" };
    try testing.expectEqual(null, try labeledDo(a, &goto, 0, false));
    const shared = [_][]const u8{ "do 10 i = 1, n", "do 10 j = 1, n", "10 continue" };
    try testing.expectEqual(null, try labeledDo(a, &shared, 0, false));
    const none = [_][]const u8{ "do i = 1, n", "end do" };
    try testing.expectEqual(null, try labeledDo(a, &none, 0, false));
}

test "an arithmetic IF becomes an IF block of GO TOs (#985)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectLines(&.{
        "  if (x - 1 < 0) then",
        "     go to 10",
        "  else if (x - 1 == 0) then",
        "     go to 20",
        "  else",
        "     go to 30",
        "  end if",
    }, (try arithmeticIf(a, "  if (x - 1) 10, 20, 30", false)).?);
    try expectLines(&.{"  go to 5"}, (try arithmeticIf(a, "  if (k) 5, 5, 5", false)).?);
    // a function's call could have an effect twice; a logical IF is none
    try testing.expectEqual(null, try arithmeticIf(a, "  if (f(x)) 10, 20, 30", false));
    try testing.expectEqual(null, try arithmeticIf(a, "  if (x > 0) go to 10", false));
}
