//! zfls's own formatter (#986), its spacing (`--spacing`): one blank after
//! a comma and none before it; one blank around `::`, the relational
//! operators (`==`, `/=`, `<`, `<=`, `>`, `>=`), and outside parentheses
//! around `=` and `=>` (an assignment, an initialization, a DO's control,
//! not a keyword argument nor `len=`). Only blanks change, between a
//! delimiter and what is next to it, so every token stays as it was;
//! character literals and comments are left as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A free-form line's text (no leading blanks) spaced, from the quote it
/// starts in (`quote`, 0: none: a line that goes on in a character literal)
pub fn space(a: Allocator, text: []const u8, start_quote: u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var quote = start_quote;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (quote != 0) {
            try out.append(a, c);
            if (c == quote) {
                if (i + 1 < text.len and text[i + 1] == quote) {
                    try out.append(a, quote);
                    i += 2;
                    continue;
                }
                quote = 0;
            }
            i += 1;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            // a comment: the rest as it is
            '!' => {
                try out.appendSlice(a, text[i..]);
                return out.items;
            },
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            else => {},
        }
        if (c == '\'' or c == '"' or c == '(' or c == '[' or c == ')' or c == ']') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (c == ',') {
            trimEnd(&out);
            try out.append(a, ',');
            i = skipBlanks(text, i + 1);
            if (i < text.len) try out.append(a, ' ');
            continue;
        }
        const op = operatorAt(text, i, depth);
        if (op == 0) {
            try out.append(a, c);
            i += 1;
            continue;
        }
        // `operator(==)`, `(/ ... /)`: an operator without operands
        const next = skipBlanks(text, i + op);
        const before = lastNonBlank(out.items);
        if (before == null or before.? == '(' or next >= text.len or text[next] == ')') {
            try out.appendSlice(a, text[i .. i + op]);
            i += op;
            continue;
        }
        trimEnd(&out);
        try out.append(a, ' ');
        try out.appendSlice(a, text[i .. i + op]);
        try out.append(a, ' ');
        i = next;
    }
    return out.items;
}

/// The length of the operator to space at `text[i]`, or 0
fn operatorAt(text: []const u8, i: usize, depth: usize) usize {
    const c = text[i];
    const n: u8 = if (i + 1 < text.len) text[i + 1] else 0;
    const p: u8 = if (i > 0) text[i - 1] else 0;
    return switch (c) {
        // not a stride with no upper bound, `a(1::2)`
        ':' => if (n == ':' and depth == 0) 2 else 0,
        '=' => if (n == '=') 2 else if (p == '=' or p == '/' or p == '<' or p == '>') 0 else if (depth > 0) 0 else if (n == '>') 2 else 1,
        // not `//`, `(/` nor `/)`
        '/' => if (n == '=' and p != '(') 2 else 0,
        '<', '>' => if (p == '=' and c == '>') 0 else if (n == '=') 2 else 1,
        else => 0,
    };
}

/// Where the `::` of a declaration's line is, outside parentheses and
/// character literals, or null
pub fn doubleColon(text: []const u8) ?usize {
    var quote: u8 = 0;
    var depth: usize = 0;
    for (text, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '!' => return null,
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ':' => if (depth == 0 and i + 1 < text.len and text[i + 1] == ':') return i,
            else => {},
        }
    }
    return null;
}

/// `lines` with the `::` of each run of declarations in one column, the
/// blanks before it padded (`eligible[i]`: line `i` may be one, a statement
/// on a line of its own)
pub fn alignColons(a: Allocator, lines: []const []const u8, eligible: []const bool) ![]const []const u8 {
    const out = try a.dupe([]const u8, lines);
    var i: usize = 0;
    while (i < lines.len) {
        if (!eligible[i] or doubleColon(lines[i]) == null) {
            i += 1;
            continue;
        }
        var end = i;
        var column: usize = 0;
        // a run at one indentation: not a type's statement and its components
        const lead = leadingBlanks(lines[i]);
        while (end < lines.len and eligible[end] and leadingBlanks(lines[end]) == lead) : (end += 1) {
            const at = doubleColon(lines[end]) orelse break;
            column = @max(column, std.mem.trimEnd(u8, lines[end][0..at], " \t").len + 1);
        }
        for (i..end) |k| {
            const at = doubleColon(lines[k]).?;
            const head = std.mem.trimEnd(u8, lines[k][0..at], " \t");
            const buf = try a.alloc(u8, column + lines[k].len - at);
            @memcpy(buf[0..head.len], head);
            @memset(buf[head.len..column], ' ');
            @memcpy(buf[column..], lines[k][at..]);
            out[k] = buf;
        }
        i = end;
    }
    return out;
}

fn leadingBlanks(line: []const u8) usize {
    return std.mem.findNone(u8, line, " \t") orelse line.len;
}

fn skipBlanks(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

fn trimEnd(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) out.items.len -= 1;
}

fn lastNonBlank(s: []const u8) ?u8 {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] != ' ' and s[i] != '\t') return s[i];
    }
    return null;
}

const testing = std.testing;

fn expectSpaced(want: []const u8, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(want, try space(arena.allocator(), text, 0));
}

test "blanks around assignments, relations and ::, after commas (#986)" {
    try expectSpaced("integer :: n = 1, k", "integer::n=1 ,k");
    try expectSpaced("if (a == b .and. c /= d) x = 1", "if (a==b .and. c/=d) x=1");
    try expectSpaced("call f(x, key=2, len=3)", "call f(x,key=2,len=3)");
    try expectSpaced("do i = 1, n", "do i=1,n");
    try expectSpaced("p => t", "p=>t");
    try expectSpaced("if (i <= 3 .or. i > 4) y = z >= w", "if (i<=3 .or. i>4) y=z>=w");
    try expectSpaced("write(*, *) 'a=b,c'  ! x=1,2", "write(*,*) 'a=b,c'  ! x=1,2");
}

test "the :: of a run of declarations in one column (#986)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = [_][]const u8{ "  integer :: n", "  real(8), allocatable :: x(:)", "  character(len=*) :: s ! a::b", "  n = 1", "  logical :: ok" };
    const got = try alignColons(arena.allocator(), &lines, &.{ true, true, true, true, true });
    try testing.expectEqualStrings("  integer              :: n", got[0]);
    try testing.expectEqualStrings("  real(8), allocatable :: x(:)", got[1]);
    try testing.expectEqualStrings("  character(len=*)     :: s ! a::b", got[2]);
    try testing.expectEqualStrings("  n = 1", got[3]);
    try testing.expectEqualStrings("  logical :: ok", got[4]);
    // a type's statement and its components: each at its own indentation
    const typed = [_][]const u8{ "  type :: point", "    real :: x", "    integer :: id" };
    const t = try alignColons(arena.allocator(), &typed, &.{ true, true, true });
    try testing.expectEqualStrings("  type :: point", t[0]);
    try testing.expectEqualStrings("    real    :: x", t[1]);
    try testing.expectEqualStrings("    integer :: id", t[2]);
}

test "operators without operands, array constructors and concatenation stay (#986)" {
    try expectSpaced("interface operator(==)", "interface operator(==)");
    try expectSpaced("v = (/1, 2/) // s", "v=(/1,2/) // s");
    try expectSpaced("x = a, &", "x=a,&");
    try expectSpaced("x = 'it''s', y", "x='it''s',y");
}
