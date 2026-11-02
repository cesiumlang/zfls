//! The literal constant at a column of a line, and its type, for hover
//! (fortls #125): `42` is INTEGER, `7_8` INTEGER(8), `3.0_dp` REAL(dp),
//! `1d0` DOUBLE PRECISION, `'abc'` CHARACTER(LEN=3), `.true._1` LOGICAL(1),
//! `z'ff'` a BOZ constant (with its value).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Literal = struct {
    /// the type, as declared (`REAL(dp)`), or `BOZ`
    type: []const u8,
    /// the value of a BOZ constant
    value: ?u128 = null,
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The start of the word that ends at `end`
fn wordStart(line: []const u8, end: usize) usize {
    var s = end;
    while (s > 0 and isWord(line[s - 1])) s -= 1;
    return s;
}

/// The literal at byte `col` of `line` (one line of code: a `!` outside
/// strings starts a comment)
pub fn at(a: Allocator, line: []const u8, col: usize) !?Literal {
    // the strings, and the code with them blanked
    const code = try a.dupe(u8, line);
    var i: usize = 0;
    var comment = line.len;
    while (i < line.len) : (i += 1) {
        const q = line[i];
        if (q == '!') {
            comment = i;
            break;
        }
        if (q != '\'' and q != '"') continue;
        const open = i;
        var n: usize = 0;
        i += 1;
        while (i < line.len) : (i += 1) {
            if (line[i] != q) {
                // a character, not a byte of one
                if (line[i] & 0xC0 != 0x80) n += 1;
                continue;
            }
            if (i + 1 < line.len and line[i + 1] == q) {
                n += 1;
                i += 1;
                continue;
            }
            break;
        }
        const close = @min(i, line.len - 1);
        @memset(code[open .. close + 1], ' ');
        // a BOZ constant (`z'ff'`), or a kind before the string (`dp_'x'`)
        var start = open;
        var kind: ?[]const u8 = null;
        var boz: ?u8 = null;
        if (open > 0 and (open < 2 or !isWord(line[open - 2])) and std.mem.indexOfScalar(u8, "bBoOzZ", line[open - 1]) != null) {
            start = open - 1;
            boz = std.ascii.toLower(line[open - 1]);
        } else if (open > 1 and line[open - 1] == '_' and isWord(line[open - 2])) {
            start = wordStart(line, open - 1);
            kind = line[start .. open - 1];
        }
        if (col < start or col > close) continue;
        if (boz) |b| {
            const base: u8 = switch (b) {
                'b' => 2,
                'o' => 8,
                else => 16,
            };
            return .{ .type = "BOZ", .value = std.fmt.parseInt(u128, line[open + 1 .. close], base) catch null };
        }
        return .{ .type = if (kind) |k|
            try std.fmt.allocPrint(a, "CHARACTER(LEN={d}, KIND={s})", .{ n, k })
        else
            try std.fmt.allocPrint(a, "CHARACTER(LEN={d})", .{n}) };
    }
    if (col >= comment) return null;
    const c = code[0..comment];
    // a logical (`.true.`, `.false._1`)
    for ([_][]const u8{ ".true.", ".false." }) |word| {
        var from: usize = 0;
        while (std.ascii.findIgnoreCasePos(c, from, word)) |s| : (from = s + 1) {
            var e = s + word.len;
            var kind: ?[]const u8 = null;
            if (e + 1 < c.len and c[e] == '_' and isWord(c[e + 1])) {
                const ks = e + 1;
                e = ks;
                while (e < c.len and isWord(c[e])) e += 1;
                kind = c[ks..e];
            }
            if (col < s or col >= e) continue;
            return .{ .type = if (kind) |k| try std.fmt.allocPrint(a, "LOGICAL({s})", .{k}) else "LOGICAL" };
        }
    }
    // a number
    i = 0;
    while (i < c.len) {
        const starts = std.ascii.isDigit(c[i]) or (c[i] == '.' and i + 1 < c.len and std.ascii.isDigit(c[i + 1]));
        if (!starts or (i > 0 and isWord(c[i - 1]))) {
            i += 1;
            continue;
        }
        const s = i;
        var real = false;
        var exponent: u8 = 0;
        while (i < c.len and std.ascii.isDigit(c[i])) i += 1;
        // a decimal point, unless it starts an operator (`1.eq.2`)
        if (i < c.len and c[i] == '.') {
            var j = i + 1;
            while (j < c.len and std.ascii.isAlphabetic(c[j])) j += 1;
            const operator = j > i + 1 and j < c.len and c[j] == '.';
            if (!operator) {
                real = true;
                i += 1;
                while (i < c.len and std.ascii.isDigit(c[i])) i += 1;
            }
        }
        // an exponent
        if (i + 1 < c.len and std.mem.indexOfScalar(u8, "eEdDqQ", c[i]) != null) {
            var j = i + 1;
            if (c[j] == '+' or c[j] == '-') j += 1;
            if (j < c.len and std.ascii.isDigit(c[j])) {
                exponent = std.ascii.toLower(c[i]);
                i = j;
                while (i < c.len and std.ascii.isDigit(c[i])) i += 1;
            }
        }
        var kind: ?[]const u8 = null;
        if (i + 1 < c.len and c[i] == '_' and isWord(c[i + 1])) {
            const ks = i + 1;
            i = ks;
            while (i < c.len and isWord(c[i])) i += 1;
            kind = c[ks..i];
        }
        // part of a name or of a format (`f10.3`, `5x`)
        if (i < c.len and isWord(c[i])) {
            while (i < c.len and isWord(c[i])) i += 1;
            continue;
        }
        if (col < s or col >= i) continue;
        if (exponent == 'd') return .{ .type = "DOUBLE PRECISION" };
        if (exponent == 'q') return .{ .type = "REAL(16)" };
        const t = if (real or exponent != 0) "REAL" else "INTEGER";
        return .{ .type = if (kind) |k| try std.fmt.allocPrint(a, "{s}({s})", .{ t, k }) else t };
    }
    return null;
}

fn expectType(line: []const u8, on: []const u8, expected: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const col = std.mem.indexOf(u8, line, on).?;
    const lit = try at(arena.allocator(), line, col);
    if (expected) |e| {
        try std.testing.expect(lit != null);
        try std.testing.expectEqualStrings(e, lit.?.type);
    } else try std.testing.expect(lit == null);
}

test "literal types" {
    const line = "x = 3.0_dp + 1d0 + 1.5e-3 + 42 + 7_8 + .5 + 2.0q0 + 1.e5";
    try expectType(line, "3.0_dp", "REAL(dp)");
    try expectType(line, "1d0", "DOUBLE PRECISION");
    try expectType(line, "1.5e-3", "REAL");
    try expectType(line, "42", "INTEGER");
    try expectType(line, "7_8", "INTEGER(8)");
    try expectType(line, ".5", "REAL");
    try expectType(line, "2.0q0", "REAL(16)");
    try expectType(line, "1.e5", "REAL");
    try expectType("s = 'abc' // \"it''s\" // 'don''t' // dp_'x'", "'abc'", "CHARACTER(LEN=3)");
    try expectType("s = 'abc' // \"it''s\" // 'don''t' // dp_'x'", "\"it", "CHARACTER(LEN=5)");
    try expectType("s = 'abc' // \"it''s\" // 'don''t' // dp_'x'", "'don", "CHARACTER(LEN=5)");
    try expectType("s = 'abc' // \"it''s\" // 'don''t' // dp_'x'", "dp_", "CHARACTER(LEN=1, KIND=dp)");
    try expectType("t = .TRUE. .or. .false._1", "TRUE", "LOGICAL");
    try expectType("t = .TRUE. .or. .false._1", "false", "LOGICAL(1)");
    try expectType("if (1.eq.2) i = 0", "1.eq", "INTEGER");
    try expectType("if (1.eq.2) i = 0", "2)", "INTEGER");
}

test "no literals" {
    try expectType("x1 = y", "1", null);
    try expectType("format (i5, f10.3, 5x)", "10", null);
    try expectType("format (i5, f10.3, 5x)", "5x", null);
    try expectType("x = 1 ! 42", "42", null);
    try expectType("s = 'a 42'", "42", "CHARACTER(LEN=4)");
    try expectType("t = .true.", "=", null);
}

test "BOZ constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = "i = z'ff' + b\"101\" + o'17'";
    for ([_]struct { []const u8, u128 }{ .{ "z'", 255 }, .{ "101", 5 }, .{ "o'", 15 } }) |case| {
        const lit = (try at(arena.allocator(), line, std.mem.indexOf(u8, line, case[0]).?)).?;
        try std.testing.expectEqualStrings("BOZ", lit.type);
        try std.testing.expectEqual(case[1], lit.value.?);
    }
}
