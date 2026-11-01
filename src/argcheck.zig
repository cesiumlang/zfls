//! Argument checking: the calls of workspace procedures whose arguments do
//! not fit the procedure (too many, a keyword it does not have, one given
//! twice, a required one missing, a type, rank or kind that differs), and
//! assignments to INTENT(IN) dummy arguments. Each statement is read whole, its continuation lines joined.
//! Generic interfaces, intrinsics, procedure pointers and procedures with
//! alternate returns are not checked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const objects = @import("objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;
const selection = @import("selection.zig");
const KW = @import("constants.zig").KW;

pub const Kind = enum { arguments, kinds, intent_in };

pub const Problem = struct { line: usize, start: usize, end: usize, message: []const u8, kind: Kind };

/// A statement with its continuation lines joined, and where each of its
/// bytes is in the file
const Joined = struct {
    text: []const u8,
    lines: []const usize,
    cols: []const usize,
};

fn join(a: Allocator, file: *const FortranFile, first: usize, last: usize) !Joined {
    var text: std.ArrayList(u8) = .empty;
    var lines: std.ArrayList(usize) = .empty;
    var cols: std.ArrayList(usize) = .empty;
    var ln = first;
    while (ln <= last) : (ln += 1) {
        const raw = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        var code = try helpers.stripStrings(a, raw, true);
        if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
        var s: usize = 0;
        var e = code.len;
        if (file.fixed) {
            // the label and continuation columns
            s = @min(6, code.len);
        } else {
            const t = std.mem.trimEnd(u8, code, " \t\r");
            e = t.len;
            if (e > 0 and t[e - 1] == '&') e -= 1;
            while (s < e and (code[s] == ' ' or code[s] == '\t')) s += 1;
            if (ln != first and s < e and code[s] == '&') s += 1;
        }
        var i = s;
        while (i < e) : (i += 1) {
            try text.append(a, code[i]);
            try lines.append(a, ln);
            try cols.append(a, i);
        }
        try text.append(a, ' ');
        try lines.append(a, ln);
        try cols.append(a, e);
    }
    return .{ .text = text.items, .lines = lines.items, .cols = cols.items };
}

/// The statement keywords whose statements declare or define: their
/// parentheses are no calls
const spec_words = [_][]const u8{
    "integer",     "real",        "double",     "complex",     "character", "logical",      "type",
    "class",       "procedure",   "dimension",  "allocatable", "parameter", "data",         "common",
    "namelist",    "external",    "intrinsic",  "intent",      "optional",  "pointer",      "target",
    "save",        "public",      "private",    "protected",   "use",       "import",       "implicit",
    "function",    "subroutine",  "module",     "submodule",   "program",   "interface",    "end",
    "pure",        "impure",      "elemental",  "recursive",   "entry",     "format",       "generic",
    "final",       "contains",    "bind",       "value",       "volatile",  "asynchronous", "contiguous",
    "equivalence", "enum",        "enumerator", "attributes",  "structure", "record",       "include",
    "abstract",    "codimension", "block",      "blockdata",   "select",    "case",         "rank",
};

fn isSpec(word: []const u8) bool {
    for (spec_words) |k| if (std.ascii.eqlIgnoreCase(word, k)) return true;
    return std.ascii.startsWithIgnoreCase(word, "end");
}

const Checker = struct {
    a: Allocator,
    env: objects.Env,
    ast: *Ast,
    cache: std.StringHashMapUnmanaged(?*Obj) = .empty,
    out: std.ArrayList(Problem) = .empty,

    fn lookup(c: *Checker, scope: ?*Obj, name: []const u8, line_no: usize) !?*Obj {
        const lower = try std.ascii.allocLowerString(c.a, name);
        const key = try std.fmt.allocPrint(c.a, "{x}:{s}", .{ @intFromPtr(scope), lower });
        const gop = try c.cache.getOrPut(c.a, key);
        if (gop.found_existing) return gop.value_ptr.*;
        var found = try objects.findInScope(c.env, scope, lower, .{ .var_line_number = line_no });
        if (found == null) found = c.env.global(c.ast, lower);
        gop.value_ptr.* = found;
        return found;
    }

    fn report(c: *Checker, j: Joined, start: usize, end: usize, kind: Kind, comptime fmt: []const u8, args: anytype) !void {
        const line = j.lines[start];
        const e = if (end > start and j.lines[end - 1] == line) j.cols[end - 1] + 1 else j.cols[start] + 1;
        try c.out.append(c.a, .{ .line = line, .start = j.cols[start], .end = e, .message = try std.fmt.allocPrint(c.a, fmt, args), .kind = kind });
    }

    fn statement(c: *Checker, j: Joined, s: usize, e: usize) !void {
        const text = j.text[s..e];
        var it = helpers.words(text);
        const first = it.next() orelse return;
        const line_no = j.lines[s + first.start] + 1;
        const scope = c.ast.getInnerScope(line_no);
        if (isSpec(first.str)) return;
        try c.intentIn(j, s, text, first, scope, line_no);
        // the calls
        it = helpers.words(text);
        var prev_word: ?[]const u8 = null;
        while (it.next()) |w| {
            defer prev_word = w.str;
            var k = w.end;
            while (k < text.len and text[k] == ' ') k += 1;
            if (std.mem.startsWith(u8, text[k..], "<<<")) {
                const close = std.mem.indexOfPos(u8, text, k, ">>>") orelse continue;
                k = close + 3;
                while (k < text.len and text[k] == ' ') k += 1;
            }
            if (k >= text.len or text[k] != '(') continue;
            const close = matching(text, k) orelse continue;
            // `x(1)%f(2)`, `.and.`, a literal's kind: not calls of a name
            if (w.start > 0 and (text[w.start - 1] == '.' or std.ascii.isDigit(text[w.start - 1]))) continue;
            const is_member = w.start > 0 and text[w.start - 1] == '%';
            const callee_obj = if (is_member)
                try c.member(scope, text[0..w.end], w.str)
            else
                try c.lookup(scope, w.str, line_no);
            const obj = callee_obj orelse continue;
            var drop: ?usize = null;
            const proc = switch (obj.kind) {
                .subroutine, .function => obj,
                .method => blk: {
                    drop = obj.varDataConst().drop_arg;
                    break :blk obj.linkObj() orelse continue;
                },
                else => continue,
            };
            if (proc.kind != .subroutine and proc.kind != .function) continue;
            if (proc.file_ast.file == null or headerHasDirective(proc)) continue;
            // a function's name in its own body is its result
            if (proc == scope and proc.kind == .function and !proc.hasKeyword(KW.recursive)) continue;
            // a variable named like an external procedure, `x(i)` in a
            // DIMENSION: only after CALL or as a function
            if (proc.kind == .subroutine and !is_member and !(prev_word != null and std.ascii.eqlIgnoreCase(prev_word.?, "call"))) continue;
            try c.callArgs(j, s, text, w, k, close, proc, drop, scope, line_no);
        }
    }

    fn member(c: *Checker, scope: ?*Obj, prefix: []const u8, name: []const u8) !?*Obj {
        const line_prefix = (try helpers.getLinePrefix(c.a, &.{}, prefix, prefix.len, false)) orelse return null;
        const var_stack = try helpers.getVarStack(c.a, line_prefix);
        if (var_stack.len < 2) return null;
        const type_scope = (try objects.climbTypeTree(c.env, var_stack, scope)) orelse return null;
        const lower = try std.ascii.allocLowerString(c.a, name);
        return objects.findInScope(c.env, type_scope, lower, .{});
    }

    fn callArgs(c: *Checker, j: Joined, s: usize, text: []const u8, w: helpers.Word, open: usize, close: usize, proc: *Obj, drop: ?usize, scope: ?*Obj, line_no: usize) !void {
        const pd = proc.procDataConst();
        const names = try objects_split(c.a, proc.argList());
        // the dummy arguments the call can give, in order
        var dummies: std.ArrayList(struct { name: []const u8, optional: bool, obj: ?*Obj }) = .empty;
        for (names, 0..) |n, i| {
            if (i == drop) continue;
            const name = std.mem.trim(u8, n, " ");
            // alternate returns
            if (name.len == 0 or name[0] == '*') return;
            const arg = if (i < pd.arg_objs.items.len) pd.arg_objs.items[i] else null;
            try dummies.append(c.a, .{ .name = name, .optional = if (arg) |o| o.isOptional() else false, .obj = arg });
        }
        const elemental = proc.hasKeyword(KW.elemental);
        // the arguments
        var given = try c.a.alloc(bool, dummies.items.len);
        @memset(given, false);
        var positional: usize = 0;
        var keyword_seen = false;
        var depth: usize = 0;
        var start = open + 1;
        var i = open + 1;
        const inner = std.mem.trim(u8, text[open + 1 .. close], " ");
        if (inner.len > 0) while (i <= close) : (i += 1) {
            const ch = text[i];
            if (ch == '(' or ch == '[') depth += 1;
            if ((ch == ')' or ch == ']') and i != close) depth -|= 1;
            if (i != close and !(ch == ',' and depth == 0)) continue;
            const arg = std.mem.trim(u8, text[start..i], " ");
            const arg_start = start;
            start = i + 1;
            if (keywordOf(arg)) |kw| {
                keyword_seen = true;
                const idx = for (dummies.items, 0..) |d, n| {
                    if (std.ascii.eqlIgnoreCase(d.name, kw)) break n;
                } else {
                    try c.report(j, s + w.start, s + w.end, .arguments, "{s} has no argument {s}", .{ proc.name, kw });
                    continue;
                };
                if (given[idx]) try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s} is given twice", .{ dummies.items[idx].name, proc.name });
                given[idx] = true;
                const eq = std.mem.indexOfScalar(u8, arg, '=').?;
                if (dummies.items[idx].obj) |d| try c.argType(j, s, w, proc, d, std.mem.trim(u8, arg[eq + 1 ..], " "), elemental, scope, line_no);
            } else {
                // a positional argument after a keyword one is invalid: the
                // compiler says so; nothing to add
                if (keyword_seen) return;
                if (positional >= dummies.items.len) {
                    _ = arg_start;
                    try c.report(j, s + w.start, s + w.end, .arguments, "Too many arguments for {s}: {d} expected", .{ proc.name, dummies.items.len });
                    return;
                }
                given[positional] = true;
                if (dummies.items[positional].obj) |d| try c.argType(j, s, w, proc, d, arg, elemental, scope, line_no);
                positional += 1;
            }
        };
        for (dummies.items, given) |d, g| {
            if (g or d.optional) continue;
            try c.report(j, s + w.start, s + w.end, .arguments, "Missing argument {s} of {s}", .{ d.name, proc.name });
        }
    }

    /// The type and rank of an argument that is a variable or a literal,
    /// against its dummy argument: the kind of type (integer, real,
    /// complex, logical, character, derived), and a whole array for a
    /// scalar or a literal for an array (not for an elemental procedure)
    fn argType(c: *Checker, j: Joined, s: usize, w: helpers.Word, proc: *Obj, dummy: *Obj, actual: []const u8, elemental: bool, scope: ?*Obj, line_no: usize) !void {
        if (dummy.kind != .variable or actual.len == 0) return;
        const want = category(dummy.descOf());
        var have: Category = .unknown;
        var have_array = false;
        var is_literal = false;
        if (literalCategory(actual)) |lc| {
            have = lc;
            is_literal = true;
        } else if (isName(actual)) {
            const v = (try c.lookup(scope, actual, line_no)) orelse return;
            if (v.kind != .variable or v.linkObj() != null) return;
            have = category(v.descOf());
            have_array = v.hasKeyword(KW.dimension) or v.keyword_info.dimension != null;
        } else return;
        if (want != .unknown and have != .unknown and want != have) {
            try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s}: {s} expected, {s} given", .{ dummy.name, proc.name, @tagName(want), @tagName(have) });
            return;
        }
        // the kinds, when both are known
        if (want == have and want != .unknown and want != .character and want != .derived) {
            const want_kind = try c.kindOfVar(dummy);
            const have_kind = if (is_literal)
                try c.literalKind(actual, scope, line_no)
            else
                try c.kindOfVar((try c.lookup(scope, actual, line_no)).?);
            if (want_kind != null and have_kind != null and want_kind.? != have_kind.?) {
                const t = typeName(want);
                try c.report(j, s + w.start, s + w.end, .kinds, "Argument {s} of {s}: {s}({d}) expected, {s}({d}) given", .{ dummy.name, proc.name, t, want_kind.?, t, have_kind.? });
                return;
            }
        }
        if (elemental) return;
        const dims = dummy.keyword_info.dimension;
        const dummy_array = dummy.hasKeyword(KW.dimension) or dims != null;
        // assumed rank takes any
        if (dims) |d| if (std.mem.eql(u8, std.mem.trim(u8, d, " "), "..")) return;
        if (have_array and !dummy_array) {
            try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s}: a scalar expected, an array given", .{ dummy.name, proc.name });
        } else if (is_literal and dummy_array and have != .character) {
            try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s}: an array expected, a scalar given", .{ dummy.name, proc.name });
        }
    }

    /// The kind of a variable's type, as gfortran numbers kinds (4 for a
    /// default REAL, 8 for DOUBLE PRECISION), or null when it cannot be told
    fn kindOfVar(c: *Checker, v: *Obj) !?i64 {
        if (v.kind != .variable) return null;
        const desc = std.mem.trim(u8, v.descOf(), " ");
        if (std.ascii.startsWithIgnoreCase(desc, "double")) return 8;
        const spec = std.mem.trim(u8, v.varDataConst().vkind orelse "", " ");
        if (spec.len == 0) return 4;
        if (spec[0] == '*') {
            const n = std.fmt.parseInt(i64, std.mem.trim(u8, spec[1..], " "), 10) catch return null;
            // COMPLEX*16 is two REAL(8)
            return if (category(desc) == .complex) @divTrunc(n, 2) else n;
        }
        if (spec[0] != '(' or spec[spec.len - 1] != ')') return null;
        var inner = std.mem.trim(u8, spec[1 .. spec.len - 1], " ");
        if (std.mem.indexOfScalar(u8, inner, '=')) |eq| {
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, inner[0..eq], " "), "kind")) return null;
            inner = std.mem.trim(u8, inner[eq + 1 ..], " ");
        }
        return c.kindValue(inner, v.parent, v.sline, 0);
    }

    /// The kind of a literal argument (`1.0` 4, `1d0` 8, `1.0_dp` that of
    /// `dp`)
    fn literalKind(c: *Checker, lit: []const u8, scope: ?*Obj, line_no: usize) !?i64 {
        if (lit[0] == '.') if (std.ascii.startsWithIgnoreCase(lit, ".true.") or std.ascii.startsWithIgnoreCase(lit, ".false.")) return 4;
        if (std.mem.lastIndexOfScalar(u8, lit, '_')) |u| return c.kindValue(lit[u + 1 ..], scope, line_no, 0);
        for (lit) |ch| switch (ch) {
            'd', 'D' => return 8,
            'q', 'Q' => return 16,
            else => {},
        };
        return 4;
    }

    /// The value of a kind expression: a number, a named constant (of
    /// ISO_FORTRAN_ENV, ISO_C_BINDING, or a PARAMETER), `kind(...)`,
    /// `selected_real_kind(p, r)`, `selected_int_kind(r)`
    fn kindValue(c: *Checker, expr_in: []const u8, scope: ?*Obj, line_no: usize, depth: usize) Allocator.Error!?i64 {
        if (depth > 8) return null;
        const expr = std.mem.trim(u8, expr_in, " ");
        if (expr.len == 0) return null;
        if (std.fmt.parseInt(i64, expr, 10)) |n| return n else |_| {}
        if (isName(expr)) {
            const v = (try c.lookup(scope, expr, line_no)) orelse return null;
            if (v.kind != .variable) return null;
            if (v.parent) |m| if (std.ascii.eqlIgnoreCase(m.name, "iso_fortran_env") or std.ascii.eqlIgnoreCase(m.name, "iso_c_binding")) {
                for (intrinsic_kinds) |k| if (std.ascii.eqlIgnoreCase(k[0], v.name)) return k[1];
                return null;
            };
            if (!v.varDataConst().is_const) return null;
            return c.kindValue(v.varDataConst().param_val orelse return null, v.parent, v.sline, depth + 1);
        }
        // a call of an inquiry function
        const open = std.mem.indexOfScalar(u8, expr, '(') orelse return null;
        if (expr[expr.len - 1] != ')' or matching(expr, open) != expr.len - 1) return null;
        const fun = std.mem.trim(u8, expr[0..open], " ");
        const args = expr[open + 1 .. expr.len - 1];
        if (std.ascii.eqlIgnoreCase(fun, "kind")) {
            const arg = std.mem.trim(u8, args, " ");
            if (literalCategory(arg)) |cat| return if (cat == .character) null else c.literalKind(arg, scope, line_no);
            if (!isName(arg)) return null;
            return c.kindOfVar((try c.lookup(scope, arg, line_no)) orelse return null);
        }
        const real = std.ascii.eqlIgnoreCase(fun, "selected_real_kind");
        if (!real and !std.ascii.eqlIgnoreCase(fun, "selected_int_kind")) return null;
        // the precision and range, by position or keyword
        var p: ?i64 = null;
        var r: ?i64 = null;
        var it = std.mem.splitScalar(u8, args, ',');
        var pos: usize = 0;
        while (it.next()) |part| : (pos += 1) {
            var arg = std.mem.trim(u8, part, " ");
            var which: u8 = if (pos == 0) 'p' else 'r';
            if (keywordOf(arg)) |kw| {
                which = std.ascii.toLower(kw[0]);
                arg = std.mem.trim(u8, arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..], " ");
            }
            const n = (try c.kindValue(arg, scope, line_no, depth + 1)) orelse return null;
            if (which == 'p') p = n else if (which == 'r') r = n else return null;
        }
        if (!real) return selectedIntKind(p orelse return null);
        return selectedRealKind(p, r);
    }

    /// `x = ...` (also `x(i) = `, `x%c = `) for an INTENT(IN) dummy argument
    /// of the procedure around
    fn intentIn(c: *Checker, j: Joined, s: usize, text: []const u8, first: helpers.Word, scope: ?*Obj, line_no: usize) !void {
        var k = first.end;
        while (true) {
            while (k < text.len and text[k] == ' ') k += 1;
            if (k < text.len and text[k] == '(') {
                k = (matching(text, k) orelse return) + 1;
                continue;
            }
            if (k < text.len and text[k] == '%') {
                k += 1;
                while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_' or text[k] == ' ')) k += 1;
                continue;
            }
            break;
        }
        if (k >= text.len or text[k] != '=') return;
        if (k + 1 < text.len and (text[k + 1] == '=' or text[k + 1] == '>')) return;
        const v = (try c.lookup(scope, first.str, line_no)) orelse return;
        if (v.kind != .variable) return;
        const intent = v.keyword_info.intent orelse return;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, intent, " "), "in")) return;
        // INTENT(IN) of a pointer fixes its association, not its target
        if (v.hasKeyword(KW.pointer)) return;
        // a dummy argument of the procedure around
        const p = v.parent orelse return;
        const pd = p.procDataOptConst() orelse return;
        for (pd.arg_objs.items) |arg| if (arg == v) {
            try c.report(j, s + first.start, s + first.end, .intent_in, "Assignment to INTENT(IN) argument {s}", .{v.name});
            return;
        };
    }
};

/// Whether the argument list of `proc`'s first statement has preprocessor
/// lines (`#include "dummy_arguments.inc"`), so that the arguments read are
/// not all of them
fn headerHasDirective(proc: *const Obj) bool {
    const f = proc.file_ast.file orelse return false;
    if (proc.sline == 0) return false;
    var depth: usize = 0;
    var opened = false;
    var ln = proc.sline - 1;
    const end = @min(ln + 200, f.nLines());
    while (ln < end) : (ln += 1) {
        const text = f.getLine(ln, false) orelse return false;
        const t = std.mem.trimStart(u8, text, " \t");
        if (t.len > 0 and t[0] == '#') return true;
        const code = if (std.mem.indexOfScalar(u8, text, '!')) |i| text[0..i] else text;
        for (code) |ch| switch (ch) {
            '(' => {
                depth += 1;
                opened = true;
            },
            ')' => {
                depth -|= 1;
                if (opened and depth == 0) return false;
            },
            else => {},
        };
        // no argument list
        if (!opened and !std.mem.endsWith(u8, std.mem.trimEnd(u8, code, " \t\r"), "&")) return false;
    }
    return false;
}

const Category = enum { unknown, integer, real, complex, logical, character, derived };

/// The kind of type a declared type is (`REAL(8)`, `DOUBLE PRECISION`,
/// `TYPE(pt)`); unknown for `TYPE(*)`, `CLASS(*)`, procedures and others
fn category(desc_in: []const u8) Category {
    const desc = std.mem.trim(u8, desc_in, " ");
    if (std.ascii.startsWithIgnoreCase(desc, "integer")) return .integer;
    if (std.ascii.startsWithIgnoreCase(desc, "real") or std.ascii.startsWithIgnoreCase(desc, "double precision")) return .real;
    if (std.ascii.startsWithIgnoreCase(desc, "complex") or std.ascii.startsWithIgnoreCase(desc, "double complex")) return .complex;
    if (std.ascii.startsWithIgnoreCase(desc, "logical")) return .logical;
    if (std.ascii.startsWithIgnoreCase(desc, "character")) return .character;
    if (std.ascii.startsWithIgnoreCase(desc, "type") or std.ascii.startsWithIgnoreCase(desc, "class")) {
        if (std.mem.indexOf(u8, desc, "*") != null) return .unknown;
        return .derived;
    }
    return .unknown;
}

/// The kind of type of a literal argument, or null for one that is no
/// literal (`1`, `1.0d0`, `2e3_dp`, `.true.`, `'text'`)
fn literalCategory(arg: []const u8) ?Category {
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
    if (std.mem.indexOfScalar(u8, t, '_')) |u| t = t[0..u];
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
const intrinsic_kinds = [_]struct { []const u8, i64 }{
    .{ "int8", 1 },      .{ "int16", 2 },           .{ "int32", 4 },            .{ "int64", 8 },
    .{ "real32", 4 },    .{ "real64", 8 },          .{ "real128", 16 },         .{ "c_signed_char", 1 },
    .{ "c_short", 2 },   .{ "c_int", 4 },           .{ "c_long_long", 8 },      .{ "c_int8_t", 1 },
    .{ "c_int16_t", 2 }, .{ "c_int32_t", 4 },       .{ "c_int64_t", 8 },        .{ "c_float", 4 },
    .{ "c_double", 8 },  .{ "c_float_complex", 4 }, .{ "c_double_complex", 8 }, .{ "c_bool", 1 },
};

/// gfortran's SELECTED_INT_KIND
fn selectedIntKind(r: i64) ?i64 {
    for ([_][2]i64{ .{ 2, 1 }, .{ 4, 2 }, .{ 9, 4 }, .{ 18, 8 }, .{ 38, 16 } }) |k| if (r <= k[0]) return k[1];
    return null;
}

/// gfortran's SELECTED_REAL_KIND on x86-64: the smallest kind with the
/// precision and range (REAL(10) is x87 extended precision)
fn selectedRealKind(p: ?i64, r: ?i64) ?i64 {
    if (p == null and r == null) return null;
    for ([_][3]i64{ .{ 6, 37, 4 }, .{ 15, 307, 8 }, .{ 18, 4931, 10 }, .{ 33, 4931, 16 } }) |k| {
        if ((p orelse 0) <= k[0] and (r orelse 0) <= k[1]) return k[2];
    }
    return null;
}

fn typeName(cat: Category) []const u8 {
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

fn isName(s: []const u8) bool {
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

fn objects_split(a: Allocator, s: []const u8) ![]const []const u8 {
    if (std.mem.trim(u8, s, " ").len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |p| try out.append(a, p);
    return out.items;
}

fn keywordOf(arg: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    if (eq + 1 < arg.len and (arg[eq + 1] == '=' or arg[eq + 1] == '>')) return null;
    if (eq > 0 and (arg[eq - 1] == '/' or arg[eq - 1] == '<' or arg[eq - 1] == '>')) return null;
    const name = std.mem.trim(u8, arg[0..eq], " ");
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return null;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return null;
    return name;
}

fn matching(text: []const u8, open: usize) ?usize {
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

pub fn check(a: Allocator, env: objects.Env, file: *const FortranFile, ast: *Ast) ![]const Problem {
    var c: Checker = .{ .a = a, .env = env, .ast = ast };
    const n = file.nLines();
    // the lines a preprocessor conditional leaves out
    const inactive = try a.alloc(bool, n);
    @memset(inactive, false);
    for (file.pp_skips) |sk| {
        var ln = sk.start;
        while (ln + 1 < sk.end and ln < n) : (ln += 1) inactive[ln] = true;
    }
    var ln: usize = 0;
    while (ln < n) {
        const st = selection.statementLines(file, ln);
        defer ln = st.last + 1;
        const raw = file.getLine(ln, false) orelse continue;
        if (inactive[ln] or helpers.isComment(file.fixed, raw)) continue;
        const t = std.mem.trimStart(u8, raw, " \t");
        if (t.len == 0 or t[0] == '#') continue;
        const j = try join(a, file, st.first, st.last);
        // statements separated by `;`
        var s: usize = 0;
        var depth: usize = 0;
        for (j.text, 0..) |ch, i| {
            if (ch == '(') depth += 1;
            if (ch == ')') depth -|= 1;
            if (ch == ';' and depth == 0) {
                try c.statement(j, s, i);
                s = i + 1;
            }
        }
        if (s < j.text.len) try c.statement(j, s, j.text.len);
    }
    return c.out.items;
}
