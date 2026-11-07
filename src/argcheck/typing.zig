//! Part of the argument checks (argcheck.zig): the types of arguments
//! and expressions as the checks tell them apart, literals, the kinds
//! of ISO_FORTRAN_ENV and SELECTED_*_KIND, and splitting an argument
//! list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("../objects.zig").Obj;

pub const Category = enum { unknown, integer, real, complex, logical, character, derived };

/// The type of an argument
pub const Typed = struct {
    cat: Category,
    array: bool = false,
    literal: bool = false,
    /// a variable or a part of one (an element may start an array)
    designator: bool = false,
    /// the variable or component it ends in
    obj: ?*Obj = null,
};

pub fn numeric(cat: Category) bool {
    return cat == .integer or cat == .real or cat == .complex;
}

/// The type of an expression of operands of types `x` and `y`
pub fn promote(x: Category, y: Category) Category {
    if (x == y) return x;
    if (numeric(x) and numeric(y)) return if (x == .complex or y == .complex) .complex else .real;
    return .unknown;
}

pub fn oneOf(word: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.eqlIgnoreCase(word, w)) return true;
    return false;
}

/// The first `ch` of `s` outside parentheses and brackets
pub fn topLevel(s: []const u8, ch: u8) ?usize {
    var depth: usize = 0;
    for (s, 0..) |x, i| switch (x) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        else => if (x == ch and depth == 0) return i,
    };
    return null;
}

/// The end of the operand that starts at `i` of `e`: a literal, a string,
/// a name with its subscripts and components, or a parenthesized
/// expression or array constructor
pub fn operandEnd(e: []const u8, start: usize) ?usize {
    var i = start;
    const c0 = e[i];
    if (c0 == '\'' or c0 == '"') {
        const close = std.mem.findScalarPos(u8, e, i + 1, c0) orelse return null;
        return close + 1;
    }
    if (c0 == '(') return (matching(e, i) orelse return null) + 1;
    if (c0 == '[') {
        var depth: usize = 0;
        while (i < e.len) : (i += 1) switch (e[i]) {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        };
        return null;
    }
    if (c0 == '.') {
        // a logical literal
        for ([_][]const u8{ ".true.", ".false." }) |lit| if (std.ascii.startsWithIgnoreCase(e[i..], lit)) {
            i += lit.len;
            if (i < e.len and e[i] == '_') {
                i += 1;
                while (i < e.len and (std.ascii.isAlphanumeric(e[i]) or e[i] == '_')) i += 1;
            }
            return i;
        };
        if (!(i + 1 < e.len and std.ascii.isDigit(e[i + 1]))) return null;
    }
    if (std.ascii.isDigit(c0) or c0 == '.') {
        while (i < e.len and std.ascii.isDigit(e[i])) i += 1;
        if (i < e.len and e[i] == '.') {
            // not the dot of an operator (`1.eq.2`)
            var k = i + 1;
            while (k < e.len and std.ascii.isAlphabetic(e[k])) k += 1;
            if (!(k > i + 1 and k < e.len and e[k] == '.')) {
                i += 1;
                while (i < e.len and std.ascii.isDigit(e[i])) i += 1;
            }
        }
        if (i + 1 < e.len and std.mem.findScalar(u8, "eEdDqQ", e[i]) != null) {
            var k = i + 1;
            if (e[k] == '+' or e[k] == '-') k += 1;
            if (k < e.len and std.ascii.isDigit(e[k])) {
                i = k;
                while (i < e.len and std.ascii.isDigit(e[i])) i += 1;
            }
        }
        if (i < e.len and e[i] == '_') {
            i += 1;
            while (i < e.len and (std.ascii.isAlphanumeric(e[i]) or e[i] == '_')) i += 1;
        }
        return i;
    }
    if (!std.ascii.isAlphabetic(c0)) return null;
    while (true) {
        while (i < e.len and (std.ascii.isAlphanumeric(e[i]) or e[i] == '_')) i += 1;
        var k = i;
        while (k < e.len and e[k] == ' ') k += 1;
        while (k < e.len and e[k] == '(') {
            k = (matching(e, k) orelse return null) + 1;
            i = k;
            while (k < e.len and e[k] == ' ') k += 1;
        }
        if (k < e.len and e[k] == '%') {
            i = k + 1;
            while (i < e.len and e[i] == ' ') i += 1;
            continue;
        }
        return i;
    }
}

/// The kind of type of variable `v`: unknown for `TYPE(*)` and `CLASS(*)`,
/// whose `*` the parser keeps apart from the type (`CLASS` and `(*)`)
pub fn varCategory(v: *const Obj) Category {
    const cat = category(v.descOf());
    if (cat == .derived and v.data == .variable) if (v.data.variable.vkind) |k| if (std.mem.findScalar(u8, k, '*') != null) return .unknown;
    return cat;
}

/// The kind of type a declared type is (`REAL(8)`, `DOUBLE PRECISION`,
/// `TYPE(pt)`); unknown for `TYPE(*)`, `CLASS(*)`, procedures and others
pub fn category(desc_in: []const u8) Category {
    const desc = std.mem.trim(u8, desc_in, " ");
    if (std.ascii.startsWithIgnoreCase(desc, "integer")) return .integer;
    if (std.ascii.startsWithIgnoreCase(desc, "real") or std.ascii.startsWithIgnoreCase(desc, "double precision")) return .real;
    if (std.ascii.startsWithIgnoreCase(desc, "complex") or std.ascii.startsWithIgnoreCase(desc, "double complex")) return .complex;
    if (std.ascii.startsWithIgnoreCase(desc, "logical")) return .logical;
    if (std.ascii.startsWithIgnoreCase(desc, "character")) return .character;
    if (std.ascii.startsWithIgnoreCase(desc, "type") or std.ascii.startsWithIgnoreCase(desc, "class")) {
        if (std.mem.find(u8, desc, "*") != null) return .unknown;
        return .derived;
    }
    return .unknown;
}

/// The kind of type of a literal argument, or null for one that is no
/// literal (`1`, `1.0d0`, `2e3_dp`, `.true.`, `'text'`)
pub fn literalCategory(arg: []const u8) ?Category {
    if (arg.len == 0) return null;
    if (arg[0] == '\'' or arg[0] == '"') {
        // one string, its closing quote last (`'a' == b` is an expression)
        var i: usize = 1;
        while (i < arg.len) : (i += 1) {
            if (arg[i] != arg[0]) continue;
            if (i + 1 < arg.len and arg[i + 1] == arg[0]) {
                i += 1;
                continue;
            }
            return if (i == arg.len - 1) .character else null;
        }
        return null;
    }
    if (std.ascii.eqlIgnoreCase(arg, ".true.") or std.ascii.eqlIgnoreCase(arg, ".false.")) return .logical;
    var t = arg;
    if (t[0] == '-' or t[0] == '+') t = t[1..];
    // a kind suffix
    if (std.mem.findScalar(u8, t, '_')) |u| t = t[0..u];
    if (t.len == 0 or !(std.ascii.isDigit(t[0]) or t[0] == '.')) return null;
    var real = false;
    for (t, 0..) |ch, i| {
        if (std.ascii.isDigit(ch)) continue;
        if (ch == '.') {
            real = true;
            continue;
        }
        // an exponent, with its sign
        if ((ch == 'e' or ch == 'E' or ch == 'd' or ch == 'D') and i > 0) {
            real = true;
            const rest = t[i + 1 ..];
            const digits = if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) rest[1..] else rest;
            if (digits.len == 0) return null;
            for (digits) |dch| if (!std.ascii.isDigit(dch)) return null;
            break;
        }
        return null;
    }
    return if (real) .real else .integer;
}

/// The kinds of the named constants of ISO_FORTRAN_ENV and ISO_C_BINDING
/// that are the same on every platform gfortran targets
pub const intrinsic_kinds = [_]struct { []const u8, i64 }{
    .{ "int8", 1 },      .{ "int16", 2 },           .{ "int32", 4 },            .{ "int64", 8 },
    .{ "real32", 4 },    .{ "real64", 8 },          .{ "real128", 16 },         .{ "c_signed_char", 1 },
    .{ "c_short", 2 },   .{ "c_int", 4 },           .{ "c_long_long", 8 },      .{ "c_int8_t", 1 },
    .{ "c_int16_t", 2 }, .{ "c_int32_t", 4 },       .{ "c_int64_t", 8 },        .{ "c_float", 4 },
    .{ "c_double", 8 },  .{ "c_float_complex", 4 }, .{ "c_double_complex", 8 }, .{ "c_bool", 1 },
};

/// gfortran's SELECTED_INT_KIND
pub fn selectedIntKind(r: i64) ?i64 {
    for ([_][2]i64{ .{ 2, 1 }, .{ 4, 2 }, .{ 9, 4 }, .{ 18, 8 }, .{ 38, 16 } }) |k| if (r <= k[0]) return k[1];
    return null;
}

/// gfortran's SELECTED_REAL_KIND on x86-64: the smallest kind with the
/// precision and range (REAL(10) is x87 extended precision)
pub fn selectedRealKind(p: ?i64, r: ?i64) ?i64 {
    if (p == null and r == null) return null;
    for ([_][3]i64{ .{ 6, 37, 4 }, .{ 15, 307, 8 }, .{ 18, 4931, 10 }, .{ 33, 4931, 16 } }) |k| {
        if ((p orelse 0) <= k[0] and (r orelse 0) <= k[1]) return k[2];
    }
    return null;
}

pub fn typeName(cat: Category) []const u8 {
    return switch (cat) {
        .integer => "INTEGER",
        .real => "REAL",
        .complex => "COMPLEX",
        .logical => "LOGICAL",
        else => "",
    };
}

test "selected kinds" {
    try std.testing.expectEqual(@as(?i64, 8), selectedRealKind(15, 307));
    try std.testing.expectEqual(@as(?i64, 4), selectedRealKind(6, null));
    try std.testing.expectEqual(@as(?i64, 8), selectedRealKind(null, 100));
    try std.testing.expectEqual(@as(?i64, 16), selectedRealKind(30, null));
    try std.testing.expectEqual(@as(?i64, 8), selectedIntKind(18));
    try std.testing.expectEqual(@as(?i64, 4), selectedIntKind(9));
}

pub fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

test "literal categories" {
    try std.testing.expectEqual(Category.integer, literalCategory("3").?);
    try std.testing.expectEqual(Category.integer, literalCategory("-3_int64").?);
    try std.testing.expectEqual(Category.real, literalCategory("1.0d0").?);
    try std.testing.expectEqual(Category.real, literalCategory("2e-3").?);
    try std.testing.expectEqual(Category.real, literalCategory(".5_dp").?);
    try std.testing.expectEqual(Category.logical, literalCategory(".TRUE.").?);
    try std.testing.expectEqual(Category.character, literalCategory("'x'").?);
    try std.testing.expectEqual(Category.character, literalCategory("'it''s'").?);
    try std.testing.expect(literalCategory("'a' == b") == null);
    try std.testing.expect(literalCategory("n") == null);
    try std.testing.expect(literalCategory("1 + n") == null);
    try std.testing.expect(literalCategory("3d") == null);
}

pub fn splitArgs(a: Allocator, s: []const u8) ![]const []const u8 {
    if (std.mem.trim(u8, s, " ").len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |p| try out.append(a, p);
    return out.items;
}

pub fn keywordOf(arg: []const u8) ?[]const u8 {
    const eq = std.mem.findScalar(u8, arg, '=') orelse return null;
    if (eq + 1 < arg.len and (arg[eq + 1] == '=' or arg[eq + 1] == '>')) return null;
    if (eq > 0 and (arg[eq - 1] == '/' or arg[eq - 1] == '<' or arg[eq - 1] == '>')) return null;
    const name = std.mem.trim(u8, arg[0..eq], " ");
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return null;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return null;
    return name;
}

pub fn matching(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (text[open..], open..) |ch, i| switch (ch) {
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}
