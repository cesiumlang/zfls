//! The code of one statement over its lines, for code actions that take a
//! statement apart or write it elsewhere: without comments, continuation
//! marks and line breaks, with where each character is in the lines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const FortranFile = @import("parser.zig").FortranFile;
const selection = @import("selection.zig");

pub const Pos = struct { line: usize, col: usize };

pub const Code = struct {
    /// the characters, with blanks for those inside strings
    text: []const u8,
    /// the characters as written
    raw: []const u8,
    /// where each character is: 0-based line among the statement's lines
    /// and byte column
    at: []const Pos,

    pub fn skipBlanks(code: Code, from: usize) usize {
        var p = from;
        while (p < code.text.len and isBlank(code.text[p])) p += 1;
        return p;
    }

    /// The word (letters, digits, `_`) starting at `p`; empty when none
    pub fn word(code: Code, p: usize) []const u8 {
        var e = p;
        while (e < code.text.len and (std.ascii.isAlphanumeric(code.text[e]) or code.text[e] == '_')) e += 1;
        return code.text[p..e];
    }

    /// The `)` that closes the `(` at `open`
    pub fn closing(code: Code, open: usize) ?usize {
        var depth: usize = 0;
        for (code.text[open..], open..) |c, i| switch (c) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        };
        return null;
    }

    /// The statement on one line: the characters as written but those in
    /// `skip` (spans of `at` positions, the end exclusive), with each run
    /// of blanks outside strings made one space, trimmed
    pub fn joined(code: Code, a: Allocator, skip: []const [2]Pos) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var quote: u8 = 0;
        for (code.raw, code.at) |c, p| {
            if (for (skip) |s| {
                if (!before(p, s[0]) and before(p, s[1])) break true;
            } else false) continue;
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '\'' or c == '"') {
                quote = c;
            } else if (isBlank(c)) {
                if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(a, ' ');
                continue;
            }
            try out.append(a, c);
        }
        return std.mem.trimEnd(u8, out.items, " ");
    }
};

fn before(x: Pos, y: Pos) bool {
    return x.line < y.line or x.line == y.line and x.col < y.col;
}

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// `lines`, the lines of one statement, as `Code`; null when a string goes
/// on to the next line or a `;` ends a statement
pub fn of(a: Allocator, lines: []const []const u8, fixed: bool) !?Code {
    var text: std.ArrayList(u8) = .empty;
    var raw: std.ArrayList(u8) = .empty;
    var at: std.ArrayList(Pos) = .empty;
    for (lines, 0..) |line, l| {
        var i: usize = 0;
        if (l > 0) {
            if (fixed) i = @min(helpers.fixedContStart(line) orelse 6, line.len) else if (helpers.freeContEnd(line)) |e| i = e;
        }
        const end = if (fixed) @min(line.len, 72) else line.len;
        const first = text.items.len;
        var quote: u8 = 0;
        while (i < end) : (i += 1) {
            const c = line[i];
            var t = c;
            if (quote != 0) {
                if (c == quote) quote = 0 else t = ' ';
            } else if (c == '!') {
                break;
            } else if (c == ';') {
                return null;
            } else if (c == '\'' or c == '"') {
                quote = c;
            }
            try text.append(a, t);
            try raw.append(a, c);
            try at.append(a, .{ .line = l, .col = i });
        }
        if (quote != 0) return null;
        if (!fixed and l + 1 < lines.len) {
            while (text.items.len > first and isBlank(text.items[text.items.len - 1])) text.items.len -= 1;
            if (text.items.len > first and text.items[text.items.len - 1] == '&') text.items.len -= 1;
            raw.items.len = text.items.len;
            at.items.len = text.items.len;
        }
        // keeps the words of two lines apart
        try text.append(a, ' ');
        try raw.append(a, ' ');
        try at.append(a, .{ .line = l, .col = end });
    }
    return .{ .text = text.items, .raw = raw.items, .at = at.items };
}

/// The lines of the statement on 0-based line `line` of `file`, and the
/// first of them
pub fn linesOf(a: Allocator, file: *const FortranFile, line: usize) !?struct { first: usize, lines: []const []const u8 } {
    const st = selection.statementLines(file, line);
    var lines: std.ArrayList([]const u8) = .empty;
    for (st.first..st.last + 1) |l| try lines.append(a, file.getLine(l, false) orelse return null);
    return .{ .first = st.first, .lines = lines.items };
}

test "a statement on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = (try of(a, &.{ "  real(dp), intent(in) :: x(:), &  ! values", "     & s  = 'a  b'" }, false)).?;
    try std.testing.expectEqualStrings("real(dp), intent(in) :: x(:), s = 'a  b'", try code.joined(a, &.{}));
    const fixed = (try of(a, &.{ "      integer function f(a,", "     &  b)" }, true)).?;
    try std.testing.expectEqualStrings("integer function f(a, b)", try fixed.joined(a, &.{}));
    try std.testing.expect(try of(a, &.{"  x = 'it''s'; y = 1"}, false) == null);
}
