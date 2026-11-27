//! Part of the argument checks (argcheck.zig): the types of expressions,
//! for the checks and for hover (#987): a literal, a variable or a part of
//! one, a function's result, and expressions of these with intrinsic
//! operators.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const argcheck = @import("../argcheck.zig");
const Checker = argcheck.Checker;
const typing = @import("typing.zig");
const dimensions = @import("../objects/dimensions.zig");
const Category = typing.Category;
const Typed = typing.Typed;
const numeric = typing.numeric;
const promote = typing.promote;
const oneOf = typing.oneOf;
const topLevel = typing.topLevel;
const operandEnd = typing.operandEnd;
const varCategory = typing.varCategory;
const literalCategory = typing.literalCategory;
const matching = typing.matching;
const typeSource = argcheck.typeSource;
const rankOf = argcheck.rankOf;

/// The kind of a complex literal, `(1.0d0, 2)`: the larger of its parts',
/// an integer part's the default real's
fn complexKind(c: *Checker, scope: ?*Obj, re: Typed, im: Typed) ?i64 {
    const real = c.kindsIn(scope).real;
    const r = if (re.cat == .integer) real else re.kind orelse return null;
    const i = if (im.cat == .integer) real else im.kind orelse return null;
    return @max(r, i);
}

/// The type of an argument: a literal, a variable or a part of one
/// (`a(i)%b(:)`), or an expression of these with intrinsic operators;
/// null when it cannot be told (an intrinsic function, a user-defined
/// operator, a derived type in an expression)
pub fn of(c: *Checker, expr_in: []const u8, scope: ?*Obj, line_no: usize, depth: usize) Allocator.Error!?Typed {
    if (depth > 16) return null;
    const e = std.mem.trim(u8, expr_in, " ");
    if (e.len == 0) return null;
    if (literalCategory(e)) |lc| return .{ .cat = lc, .literal = true, .kind = if (numeric(lc) or lc == .logical) try c.literalKind(e, scope, line_no) else null };
    if (std.ascii.isAlphabetic(e[0])) if (try designator(c, e, scope, line_no, depth)) |t| return t;
    // a conditional expression (F2023): the type of its values (#733)
    if (typing.conditionalValue(e)) |value| {
        const t = (try c.exprType(value, scope, line_no, depth + 1)) orelse return null;
        return .{ .cat = t.cat, .array = t.array, .rank = t.rank, .rank_known = t.rank_known, .obj = t.obj, .kind = t.kind };
    }
    // a whole expression in parentheses, or a complex literal
    if (e[0] == '(' and matching(e, 0) == e.len - 1) {
        const inner = e[1 .. e.len - 1];
        if (topLevel(inner, ',')) |comma| {
            const re = (try c.exprType(inner[0..comma], scope, line_no, depth + 1)) orelse return null;
            const im = (try c.exprType(inner[comma + 1 ..], scope, line_no, depth + 1)) orelse return null;
            if (re.literal and im.literal and numeric(re.cat) and numeric(im.cat)) return .{ .cat = .complex, .kind = complexKind(c, scope, re, im) };
            return null;
        }
        const t = (try c.exprType(inner, scope, line_no, depth + 1)) orelse return null;
        return .{ .cat = t.cat, .array = t.array, .rank = t.rank, .rank_known = t.rank_known, .kind = t.kind };
    }
    // an array constructor: the type of its first element
    if ((e[0] == '[' and e[e.len - 1] == ']') or (e.len >= 4 and std.mem.startsWith(u8, e, "(/") and std.mem.endsWith(u8, e, "/)"))) {
        const inner = if (e[0] == '[') e[1 .. e.len - 1] else e[2 .. e.len - 2];
        // a type spec (`[real :: ...]`) or an implied DO
        if (std.mem.find(u8, inner, "::") != null or std.mem.findScalar(u8, inner, '=') != null) return null;
        const first = inner[0 .. topLevel(inner, ',') orelse inner.len];
        const t = (try c.exprType(first, scope, line_no, depth + 1)) orelse return null;
        return .{ .cat = t.cat, .array = true, .rank = 1, .kind = t.kind };
    }
    // operands and the operators between them
    var cat: Category = .unknown;
    var array = false;
    var rank: usize = 0;
    var rank_known = true;
    var relational = false;
    var logical_op = false;
    var concat = false;
    var kind: ?i64 = null;
    var operands: usize = 0;
    var i: usize = 0;
    var want_operand = true;
    while (true) {
        while (i < e.len and e[i] == ' ') i += 1;
        if (i >= e.len) break;
        if (want_operand) {
            if (e[i] == '+' or e[i] == '-') {
                i += 1;
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(e[i..], ".not.")) {
                logical_op = true;
                i += 5;
                continue;
            }
            const end = operandEnd(e, i) orelse return null;
            const t = (try c.exprType(e[i..end], scope, line_no, depth + 1)) orelse return null;
            operands += 1;
            array = array or t.array;
            rank = @max(rank, t.rank);
            rank_known = rank_known and t.rank_known;
            kind = if (operands == 1) t.kind else typing.combinedKind(cat, kind, t.cat, t.kind);
            cat = if (operands == 1) t.cat else promote(cat, t.cat);
            i = end;
            want_operand = false;
            continue;
        }
        // an operator
        const rest = e[i..];
        if (rest[0] == '.') {
            const close = std.mem.findScalarPos(u8, e, i + 1, '.') orelse return null;
            const word = e[i + 1 .. close];
            if (oneOf(word, &.{ "eq", "ne", "lt", "le", "gt", "ge" })) {
                relational = true;
            } else if (oneOf(word, &.{ "and", "or", "eqv", "neqv" })) {
                logical_op = true;
            } else return null;
            i = close + 1;
        } else if (std.mem.startsWith(u8, rest, "//")) {
            concat = true;
            i += 2;
        } else if (std.mem.startsWith(u8, rest, "**")) {
            i += 2;
        } else if (std.mem.startsWith(u8, rest, "==") or std.mem.startsWith(u8, rest, "/=") or std.mem.startsWith(u8, rest, "<=") or std.mem.startsWith(u8, rest, ">=")) {
            relational = true;
            i += 2;
        } else if (rest[0] == '<' or rest[0] == '>') {
            relational = true;
            i += 1;
        } else if (std.mem.findScalar(u8, "+-*/", rest[0]) != null) {
            i += 1;
        } else return null;
        want_operand = true;
    }
    if (want_operand or operands < 2) return null;
    if (cat == .unknown) return null;
    // a relation: of the default logical kind
    if (relational or logical_op) return .{ .cat = .logical, .array = array, .rank = rank, .rank_known = rank_known, .kind = if (relational) c.kindsIn(scope).integer else kind };
    if (concat) return if (cat == .character) .{ .cat = .character, .array = array, .rank = rank, .rank_known = rank_known } else null;
    if (!numeric(cat)) return null;
    return .{ .cat = cat, .array = array, .rank = rank, .rank_known = rank_known, .kind = kind };
}

/// The type of a variable or a part of one: `x`, `a(i)` (a scalar),
/// `a(:)` or `a(v)` with an array `v` (an array), `p%c`, `s(1:3)` (a
/// substring); null when it is no variable (a function, an intrinsic)
fn designator(c: *Checker, e: []const u8, scope: ?*Obj, line_no: usize, depth: usize) Allocator.Error!?Typed {
    var v: ?*Obj = null;
    var v_type: *Obj = undefined;
    var array = false;
    var subscripted_last = false;
    var rank_known = true;
    // the rank of the part that has one
    var rank: usize = 0;
    var i: usize = 0;
    while (true) {
        const ns = i;
        while (i < e.len and (std.ascii.isAlphanumeric(e[i]) or e[i] == '_')) i += 1;
        if (i == ns or !std.ascii.isAlphabetic(e[ns])) return null;
        const name = e[ns..i];
        var obj = if (v) |parent|
            (try c.component(parent, name)) orelse return null
        else
            (try c.lookup(scope, name, line_no)) orelse return null;
        while (i < e.len and e[i] == ' ') i += 1;
        // a call of a function: its result, the call's arguments skipped
        // (#987)
        if (v == null and obj.kind == .function and i < e.len and e[i] == '(') {
            obj = obj.procDataConst().result_obj orelse return null;
            i = (matching(e, i) orelse return null) + 1;
            while (i < e.len and e[i] == ' ') i += 1;
            const typ = typeSource(obj) orelse return null;
            const fn_array = dimensions.isArray(obj);
            if (fn_array) rank = rankOf(dimensions.of(obj)) orelse 0;
            if (!dimensions.known(obj)) rank_known = false;
            array = fn_array;
            v = obj;
            v_type = typ;
            if (i < e.len and e[i] == '%') {
                i += 1;
                while (i < e.len and e[i] == ' ') i += 1;
                continue;
            }
            break;
        }
        if (obj.kind != .variable) return null;
        // an associate name: the type of what it is linked to, the rank
        // its selector or section gives it (#707, #714)
        const typ = typeSource(obj) orelse return null;
        if (!dimensions.known(obj)) rank_known = false;
        const obj_dims = dimensions.of(obj);
        const is_array = dimensions.isArray(obj);
        while (i < e.len and e[i] == ' ') i += 1;
        var subscripted = false;
        // subscripts, then a substring
        var groups: usize = 0;
        while (i < e.len and e[i] == '(') : (groups += 1) {
            const close = matching(e, i) orelse return null;
            if (groups == 0 and is_array) {
                subscripted = true;
                const sec = (try c.sectionRank(e[i + 1 .. close], scope, line_no, depth)) orelse return null;
                if (sec > 0) array = true;
                rank = @max(rank, sec);
            } else if (varCategory(typ) != .character) return null;
            i = close + 1;
            while (i < e.len and e[i] == ' ') i += 1;
        }
        if (is_array and !subscripted) {
            array = true;
            rank = @max(rank, rankOf(obj_dims) orelse 0);
        }
        v = obj;
        v_type = typ;
        subscripted_last = groups > 0;
        if (i < e.len and e[i] == '%') {
            i += 1;
            while (i < e.len and e[i] == ' ') i += 1;
            continue;
        }
        break;
    }
    if (i != e.len) return null;
    const obj = v.?;
    const cat = varCategory(v_type);
    const kind = if (numeric(cat) or cat == .logical) try c.kindOfVar(obj) else null;
    return .{ .cat = cat, .array = array, .rank = rank, .designator = true, .subscripted = subscripted_last, .rank_known = rank_known, .obj = obj, .kind = kind };
}
