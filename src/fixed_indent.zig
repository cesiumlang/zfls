//! zfls's own formatter (#986), fixed form: the code of a statement's
//! lines (columns 7 on) at its depth, the label and continuation columns
//! as they are. A line is changed only when both it and the result fit in
//! the line length (72, or `fixed_line_length`), so nothing moves past the
//! columns the compiler reads, and sequence numbers stay; a line that ends
//! in a continued character literal, and the line that goes on with it,
//! stay as they are (their blanks up to the last column are the literal's).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    /// a comment, a blank line, a preprocessor's or debug line, a TAB-format
    /// line: left as it is
    other,
    statement,
    continuation,
};

pub fn kindOf(line: []const u8) Kind {
    if (std.mem.trim(u8, line, " \r").len == 0) return .other;
    switch (line[0]) {
        'c', 'C', '*', '!', '#', 'd', 'D' => return .other,
        else => {},
    }
    const head = line[0..@min(line.len, 6)];
    if (std.mem.findScalar(u8, head, '\t') != null) return .other;
    // a comment that starts in the label columns
    const lead = std.mem.findNone(u8, head, " ") orelse head.len;
    if (lead < head.len and lead < 5 and head[lead] == '!') return .other;
    for (head[0..@min(head.len, 5)]) |c| if (c != ' ' and !std.ascii.isDigit(c)) return .other;
    if (line.len > 5 and line[5] != ' ' and line[5] != '0') return .continuation;
    return .statement;
}

/// The code of a line: columns 7 to `limit`
pub fn codeOf(line: []const u8, limit: usize) []const u8 {
    if (line.len <= 6) return "";
    return line[6..@min(line.len, limit)];
}

/// The quote a line's code ends in, from the one it starts in (0: none)
pub fn endQuote(code: []const u8, start_quote: u8) u8 {
    var quote = start_quote;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (quote != 0) {
            if (c == quote) {
                if (i + 1 < code.len and code[i + 1] == quote) {
                    i += 1;
                    continue;
                }
                quote = 0;
            }
            continue;
        }
        if (c == '\'' or c == '"') quote = c else if (c == '!') return 0;
    }
    return quote;
}

/// `line` with its code `blanks` after column 6, or null to leave it as it
/// is: it or the result does not fit in `limit` columns, or it has no code
pub fn reindent(a: Allocator, line: []const u8, blanks: usize, limit: usize) !?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, line, " \r");
    if (trimmed.len > limit or trimmed.len <= 6) return null;
    const text = std.mem.trimStart(u8, trimmed[6..], " ");
    if (text.len == 0) return null;
    const n = 6 + blanks + text.len;
    if (n > limit) return null;
    const out = try a.alloc(u8, n);
    @memcpy(out[0..6], trimmed[0..6]);
    @memset(out[6 .. 6 + blanks], ' ');
    @memcpy(out[6 + blanks ..], text);
    return out;
}

const testing = std.testing;

test "fixed-form lines: statements, continuations and the rest (#986)" {
    try testing.expectEqual(Kind.statement, kindOf("      x = 1"));
    try testing.expectEqual(Kind.statement, kindOf("   10 CONTINUE"));
    try testing.expectEqual(Kind.continuation, kindOf("     &  y)"));
    try testing.expectEqual(Kind.statement, kindOf("     0x = 1"));
    try testing.expectEqual(Kind.other, kindOf("C     a comment"));
    try testing.expectEqual(Kind.other, kindOf("   ! a comment"));
    try testing.expectEqual(Kind.other, kindOf("\tx = 1"));
    try testing.expectEqual(Kind.other, kindOf("#ifdef X"));
    try testing.expectEqual(Kind.other, kindOf(""));
}

test "fixed-form code moved within the line length (#986)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("   10    CONTINUE", (try reindent(a, "   10 CONTINUE", 3, 72)).?);
    try testing.expectEqualStrings("     &      Y", (try reindent(a, "     &  Y", 6, 72)).?);
    // past column 72, or with sequence numbers: as it is
    const pad: [61]u8 = @splat(' ');
    const name: [60]u8 = @splat('A');
    try testing.expectEqual(null, try reindent(a, "      X = 1" ++ pad ++ "SEQ00010", 3, 72));
    try testing.expectEqual(null, try reindent(a, "      X = " ++ name, 3, 72));
    try testing.expectEqual('\'', endQuote("PRINT *, 'A LONG", 0));
    try testing.expectEqual(0, endQuote("TEXT'", '\''));
}
