//! Rewrites of a line that code actions offer: the relational operators
//! `.eq.` ... `.ge.` as `==` ... `>=`, the kind of a declaration written
//! with `*` (`real*8`) as a kind parameter (`real(8)`), and the case of a
//! keyword.

const std = @import("std");
const Allocator = std.mem.Allocator;

const operators = [_][2][]const u8{
    .{ "eq", "==" }, .{ "ne", "/=" }, .{ "lt", "<" }, .{ "le", "<=" }, .{ "gt", ">" }, .{ "ge", ">=" },
};

/// `line` with its relational operators `.eq.` ... written `==` ...
/// (outside strings and comments); null when it has none
pub fn modernOperators(a: Allocator, line: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '!') {
            try out.appendSlice(a, line[i..]);
            break;
        } else if (c == '.') {
            const rep = for (operators) |op| {
                const end = i + 1 + op[0].len;
                if (end < line.len and line[end] == '.' and std.ascii.eqlIgnoreCase(line[i + 1 .. end], op[0])) break op;
            } else null;
            if (rep) |op| {
                // one space on each side, as the operators are usually written
                if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(a, ' ');
                try out.appendSlice(a, op[1]);
                i += op[0].len + 2;
                if (i < line.len and line[i] != ' ') try out.append(a, ' ');
                changed = true;
                continue;
            }
        }
        try out.append(a, c);
        i += 1;
    }
    return if (changed) out.items else null;
}

/// `line` with the kind of a declaration written with `*` as a kind
/// parameter: `real*8` as `real(8)`, `complex*16` as `complex(8)`,
/// `character*10` as `character(len=10)`; at the start of the statement
/// or after IMPLICIT. Null when there is none.
pub fn kindParameters(a: Allocator, line: []const u8) !?[]const u8 {
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    var at = start;
    if (std.ascii.startsWithIgnoreCase(line[at..], "implicit")) {
        at += "implicit".len;
        while (at < line.len and line[at] == ' ') at += 1;
    }
    const types = [_][]const u8{ "real", "integer", "logical", "complex", "character" };
    const t = for (types) |ty| {
        if (std.ascii.startsWithIgnoreCase(line[at..], ty)) break ty;
    } else return null;
    var k = at + t.len;
    while (k < line.len and line[k] == ' ') k += 1;
    if (k >= line.len or line[k] != '*') return null;
    k += 1;
    while (k < line.len and line[k] == ' ') k += 1;
    // the length: digits, `(*)` or `(n)`
    var len_text: []const u8 = undefined;
    var end = k;
    if (k < line.len and line[k] == '(') {
        end = (std.mem.indexOfScalarPos(u8, line, k, ')') orelse return null) + 1;
        len_text = std.mem.trim(u8, line[k + 1 .. end - 1], " ");
    } else {
        while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
        if (end == k) return null;
        len_text = line[k..end];
    }
    const word = line[at .. at + t.len];
    const param = if (std.ascii.eqlIgnoreCase(t, "character"))
        try std.fmt.allocPrint(a, "(len={s})", .{len_text})
    else if (std.ascii.eqlIgnoreCase(t, "complex")) blk: {
        // complex*16 is two reals of kind 8
        const n = std.fmt.parseInt(u32, len_text, 10) catch return null;
        break :blk try std.fmt.allocPrint(a, "({d})", .{n / 2});
    } else try std.fmt.allocPrint(a, "({s})", .{len_text});
    // `real*8 x` needs a space before the name
    const sep: []const u8 = if (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) " " else "";
    return try std.mem.concat(a, u8, &.{ line[0..at], word, param, sep, line[end..] });
}

pub const Case = enum { upper, lower, title };

/// `word` in `case`
pub fn inCase(a: Allocator, word: []const u8, case: Case) ![]const u8 {
    const out = try a.dupe(u8, word);
    for (out, 0..) |*c, i| c.* = switch (case) {
        .upper => std.ascii.toUpper(c.*),
        .lower => std.ascii.toLower(c.*),
        .title => if (i == 0) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*),
    };
    return out;
}

test "modern operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("if (a == b .and. c /= d) x = 1 ! a.eq.b", (try modernOperators(a, "if (a.eq.b .and. c .NE. d) x = 1 ! a.eq.b")).?);
    try std.testing.expectEqualStrings("print *, '.eq.', x >= 2", (try modernOperators(a, "print *, '.eq.', x.ge.2")).?);
    try std.testing.expect((try modernOperators(a, "x = y .and. z")) == null);
}

test "kind parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("  real(8) :: x", (try kindParameters(a, "  real*8 :: x")).?);
    try std.testing.expectEqualStrings("  REAL(8) X, Y", (try kindParameters(a, "  REAL*8 X, Y")).?);
    try std.testing.expectEqualStrings("complex(8) z", (try kindParameters(a, "complex*16 z")).?);
    try std.testing.expectEqualStrings("character(len=10) :: s", (try kindParameters(a, "character*10 :: s")).?);
    try std.testing.expectEqualStrings("character(len=*) s", (try kindParameters(a, "character*(*) s")).?);
    try std.testing.expectEqualStrings("implicit real(8) (a-h)", (try kindParameters(a, "implicit real*8 (a-h)")).?);
    try std.testing.expect((try kindParameters(a, "x = a*8")) == null);
    try std.testing.expect((try kindParameters(a, "real(8) :: x")) == null);
}
