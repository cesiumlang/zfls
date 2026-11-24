//! Operands of the wrong types in an expression (#876): `r + c` and
//! `c == 1` with a CHARACTER variable, `'a' // 1`. gfortran, Flang and ifx
//! report each; only a character literal in an arithmetic or relational
//! operation (`r + 'a'`) is ifx's to accept. Only operands whose types are
//! known are read: a name that is no declared variable, a function call, a
//! sign or a user-defined operator leaves the expression alone. Not checked
//! where the workspace has an `operator` interface for the kind of
//! operator.

const std = @import("std");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const objects = @import("../objects.zig");

const Checker = argcheck.Checker;
const Typed = typing.Typed;
const Category = typing.Category;
const Obj = objects.Obj;

/// The kinds of operators the workspace has `operator(...)` interfaces for
pub const Defined = struct { arithmetic: bool = false, concat: bool = false, relational: bool = false };

/// The operator interfaces of the workspace, told once
fn definedOperators(c: *Checker) Defined {
    if (c.defined_operators) |known| return known;
    var d: Defined = .{};
    for (c.files) |f| {
        for (0..f.nLines()) |ln| note(&d, f.getLine(ln, false) orelse continue);
    }
    c.defined_operators = d;
    return d;
}

/// Adds the operators of the `operator(...)` interfaces of `line` to `d`
pub fn note(d: *Defined, line: []const u8) void {
    var rest = line;
    while (std.ascii.findIgnoreCase(rest, "operator")) |i| {
        rest = rest[i + "operator".len ..];
        const open = std.mem.trimStart(u8, rest, " ");
        if (open.len == 0 or open[0] != '(') continue;
        const close = std.mem.findScalar(u8, open, ')') orelse continue;
        const sym = std.mem.trim(u8, open[1..close], " ");
        if (std.mem.eql(u8, sym, "//")) {
            d.concat = true;
        } else if (typing.oneOf(sym, &.{ "+", "-", "*", "/", "**" })) {
            d.arithmetic = true;
        } else if (typing.oneOf(sym, &.{ "==", "/=", "<", "<=", ">", ">=", ".eq.", ".ne.", ".lt.", ".le.", ".gt.", ".ge." })) {
            d.relational = true;
        }
    }
}

pub const Clash = struct { start: usize, end: usize, message: []const u8 };

const Op = enum { arithmetic, concat, relational, logical };

const Span = struct { start: usize, end: usize };

const Lexed = struct {
    operands: []const Span,
    /// between operand k and k + 1
    ops: []const Op,
};

/// The operands and operators of a flat expression; null when it has a
/// sign, `.not.` or anything else that is not an operand or a binary
/// operator
fn lex(a: std.mem.Allocator, e: []const u8) !?Lexed {
    var operands: std.ArrayList(Span) = .empty;
    var ops: std.ArrayList(Op) = .empty;
    var i: usize = 0;
    var want_operand = true;
    while (true) {
        while (i < e.len and e[i] == ' ') i += 1;
        if (i >= e.len) break;
        if (want_operand) {
            if (e[i] == '+' or e[i] == '-' or std.ascii.startsWithIgnoreCase(e[i..], ".not.")) return null;
            const end = typing.operandEnd(e, i) orelse return null;
            try operands.append(a, .{ .start = i, .end = end });
            i = end;
            want_operand = false;
            continue;
        }
        const rest = e[i..];
        var op: Op = .arithmetic;
        var len: usize = 1;
        if (rest[0] == '.') {
            const close = std.mem.findScalarPos(u8, e, i + 1, '.') orelse return null;
            const word = e[i + 1 .. close];
            if (typing.oneOf(word, &.{ "eq", "ne", "lt", "le", "gt", "ge" })) {
                op = .relational;
            } else if (typing.oneOf(word, &.{ "and", "or", "eqv", "neqv" })) {
                op = .logical;
            } else return null;
            len = close + 1 - i;
        } else if (std.mem.startsWith(u8, rest, "//")) {
            op = .concat;
            len = 2;
        } else if (std.mem.startsWith(u8, rest, "**")) {
            len = 2;
        } else if (std.mem.startsWith(u8, rest, "==") or std.mem.startsWith(u8, rest, "/=") or std.mem.startsWith(u8, rest, "<=") or std.mem.startsWith(u8, rest, ">=")) {
            op = .relational;
            len = 2;
        } else if (rest[0] == '<' or rest[0] == '>') {
            op = .relational;
        } else if (std.mem.findScalar(u8, "+-*/", rest[0]) == null) return null;
        try ops.append(a, op);
        i += len;
        want_operand = true;
    }
    if (want_operand or operands.items.len < 2) return null;
    return .{ .operands = operands.items, .ops = ops.items };
}

fn nonCharacter(cat: Category) bool {
    return typing.numeric(cat) or cat == .logical;
}

/// Whether a CHARACTER operand meets a numeric or logical one, which
/// gfortran and Flang reject, and ifx does for a character variable but
/// not a character literal
fn mixes(l: ?Typed, r: ?Typed, strict: bool) bool {
    const lt = l orelse return false;
    const rt = r orelse return false;
    const char_numeric = (lt.cat == .character and nonCharacter(rt.cat)) or (rt.cat == .character and nonCharacter(lt.cat));
    if (!char_numeric) return false;
    const literal = (lt.cat == .character and lt.literal) or (rt.cat == .character and rt.literal);
    return strict or !literal;
}

fn typeOf(t: ?Typed) []const u8 {
    const x = t orelse return "an unknown type";
    return if (x.cat == .character) "CHARACTER" else typing.typeName(x.cat);
}

/// The type of operands `lo` to `hi` of `lx`, joined by arithmetic and
/// concatenation operators
fn segmentType(c: *Checker, e: []const u8, lx: Lexed, lo: usize, hi: usize, scope: ?*Obj, line_no: usize) !?Typed {
    return c.exprType(e[lx.operands[lo].start..lx.operands[hi].end], scope, line_no, 1);
}

/// The first clash of the operands of expression `e` (offsets in `e`), or
/// null when there is none or `e` is not read
pub fn first(c: *Checker, e: []const u8, scope: ?*Obj, line_no: usize, strict: bool) !?Clash {
    const lx = (try lex(c.a, e)) orelse return null;
    const defined = definedOperators(c);
    var lo: usize = 0;
    for (0..lx.operands.len) |k| {
        const last = k + 1 == lx.operands.len;
        const op: ?Op = if (last) null else lx.ops[k];
        // inside a segment of arithmetic and concatenation operators
        if (op != null and (op.? == .arithmetic or op.? == .concat)) {
            if (op.? == .concat and defined.concat or op.? == .arithmetic and defined.arithmetic) continue;
            const l = lx.operands[k];
            const r = lx.operands[k + 1];
            const lt = try c.exprType(e[l.start..l.end], scope, line_no, 1);
            const rt = try c.exprType(e[r.start..r.end], scope, line_no, 1);
            if (op.? == .concat) {
                for ([_]?Typed{ lt, rt }) |t| if (t) |x| if (nonCharacter(x.cat)) {
                    return .{ .start = l.start, .end = r.end, .message = try c.a.print("The operands of // must be CHARACTER, not {s}", .{typeOf(x)}) };
                };
            } else if (mixes(lt, rt, strict)) {
                return .{ .start = l.start, .end = r.end, .message = try c.a.print("A CHARACTER operand and a {s} operand in an arithmetic operation", .{if (lt != null and lt.?.cat == .character) typeOf(rt) else typeOf(lt)}) };
            }
            continue;
        }
        // the end of a segment: a relation joins it to the next
        if (op != null and op.? == .relational and !defined.relational) {
            var hi = k + 1;
            while (hi + 1 < lx.operands.len and (lx.ops[hi] == .arithmetic or lx.ops[hi] == .concat)) hi += 1;
            const lt = try segmentType(c, e, lx, lo, k, scope, line_no);
            const rt = try segmentType(c, e, lx, k + 1, hi, scope, line_no);
            if (mixes(lt, rt, strict)) {
                return .{ .start = lx.operands[lo].start, .end = lx.operands[hi].end, .message = try c.a.print("A CHARACTER operand and a {s} operand in a comparison", .{if (lt != null and lt.?.cat == .character) typeOf(rt) else typeOf(lt)}) };
            }
        }
        lo = k + 1;
    }
    return null;
}

test "operators of an interface" {
    var d: Defined = .{};
    note(&d, "  interface operator(//)");
    try std.testing.expect(d.concat and !d.arithmetic and !d.relational);
    note(&d, "interface OPERATOR ( + )");
    note(&d, "generic :: operator(.eq.) => f");
    try std.testing.expect(d.arithmetic and d.relational);
}
