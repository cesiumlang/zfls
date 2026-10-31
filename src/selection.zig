//! Selection ranges (`textDocument/selectionRange`): from the name at a
//! position to the parentheses around it, its statement, the constructs and
//! program units around that, and the whole file. Also where a statement
//! begins and ends, continuation lines included.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("objects.zig");
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;

/// 0-based lines, byte columns
pub const Span = struct { sline: usize, scol: usize, eline: usize, ecol: usize };

/// The spans around byte column `col` of 0-based line `line`, innermost
/// first, each strictly containing the one before
pub fn around(a: Allocator, file: *const FortranFile, ast: *Ast, line: usize, col_in: usize) ![]const Span {
    var out: std.ArrayList(Span) = .empty;
    const text = file.getLine(line, false) orelse return out.items;
    const col = @min(col_in, text.len);
    // the name
    var s = col;
    while (s > 0 and isWord(text[s - 1])) s -= 1;
    var e = col;
    while (e < text.len and isWord(text[e])) e += 1;
    if (e > s) try push(a, &out, .{ .sline = line, .scol = s, .eline = line, .ecol = e });
    // the parentheses around it on its line, innermost first: their
    // contents, then with the parentheses
    const code = codeEnd(text);
    var open = col;
    var depth: usize = 0;
    while (open > 0) {
        open -= 1;
        switch (text[open]) {
            ')' => depth += 1,
            '(' => if (depth == 0) {
                const close = matching(text[0..code], open) orelse break;
                if (close >= col) {
                    try push(a, &out, .{ .sline = line, .scol = open + 1, .eline = line, .ecol = close });
                    try push(a, &out, .{ .sline = line, .scol = open, .eline = line, .ecol = close + 1 });
                }
            } else {
                depth -= 1;
            },
            else => {},
        }
    }
    // the statement
    const st = statementLines(file, line);
    const first = file.getLine(st.first, false) orelse text;
    const last = file.getLine(st.last, false) orelse text;
    try push(a, &out, .{ .sline = st.first, .scol = firstNonBlank(first), .eline = st.last, .ecol = trimmedEnd(last) });
    // the scopes around it, innermost first
    const scopes = try ast.getScopes(a, line + 1);
    var i = scopes.len;
    while (i > 0) {
        i -= 1;
        const sc = scopes[i];
        if (sc.sline == 0) continue;
        const sl = sc.sline - 1;
        const el = @max(sc.eline, sc.sline) - 1;
        const sl_text = file.getLine(sl, false) orelse continue;
        const el_text = file.getLine(el, false) orelse continue;
        try push(a, &out, .{ .sline = sl, .scol = firstNonBlank(sl_text), .eline = el, .ecol = trimmedEnd(el_text) });
    }
    // the file
    const n = file.nLines();
    const last_line: []const u8 = file.getLine(n -| 1, false) orelse "";
    if (n > 0) try push(a, &out, .{ .sline = 0, .scol = 0, .eline = n - 1, .ecol = last_line.len });
    return out.items;
}

/// Append `span` when it contains the last span and is larger
fn push(a: Allocator, out: *std.ArrayList(Span), span: Span) !void {
    if (out.items.len > 0) {
        const prev = out.items[out.items.len - 1];
        if (!contains(span, prev) or std.meta.eql(span, prev)) return;
    }
    try out.append(a, span);
}

fn before(l1: usize, c1: usize, l2: usize, c2: usize) bool {
    return l1 < l2 or (l1 == l2 and c1 <= c2);
}

fn contains(outer: Span, inner: Span) bool {
    return before(outer.sline, outer.scol, inner.sline, inner.scol) and before(inner.eline, inner.ecol, outer.eline, outer.ecol);
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn firstNonBlank(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return if (n == line.len) 0 else n;
}

/// The end of the code of a line: before a trailing comment, and blanks
fn trimmedEnd(line: []const u8) usize {
    return std.mem.trimEnd(u8, line[0..codeEnd(line)], " \t\r").len;
}

/// Where the code of a line ends: at a `!` comment outside strings
fn codeEnd(line: []const u8) usize {
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '!') return i;
    }
    return line.len;
}

/// The `)` that closes the `(` at `open`, outside strings
fn matching(code: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    for (code[open..], open..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The first and last 0-based lines of the statement on line `line`
pub fn statementLines(file: *const FortranFile, line: usize) struct { first: usize, last: usize } {
    var first = line;
    while (first > 0 and continues(file, first - 1)) first -= 1;
    var last = line;
    while (last + 1 < file.nLines() and continues(file, last)) last += 1;
    return .{ .first = first, .last = last };
}

/// Whether the statement on 0-based line `l` goes on to the next line
fn continues(file: *const FortranFile, l: usize) bool {
    if (file.fixed) {
        // a fixed-form continuation line has a character in column 6
        const next = file.getLine(l + 1, false) orelse return false;
        const comment = next.len > 0 and (next[0] == 'c' or next[0] == 'C' or next[0] == '*' or next[0] == '!');
        return !(comment or next.len < 6 or next[5] == ' ' or next[5] == '0');
    }
    const text = file.getLine(l, false) orelse return false;
    return std.mem.endsWith(u8, std.mem.trimEnd(u8, text[0..codeEnd(text)], " \t\r"), "&");
}

test "codeEnd and matching" {
    try std.testing.expectEqual(@as(usize, 9), codeEnd("x = 'a!b'! c"));
    try std.testing.expectEqual(@as(?usize, 8), matching("f(a, (b))", 1));
    try std.testing.expectEqual(@as(?usize, 7), matching("f(')', )", 1));
}
