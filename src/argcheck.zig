//! Argument checking: the calls of workspace procedures whose arguments do
//! not fit the procedure (too many, a keyword it does not have, one given
//! twice, a required one missing, a type, rank or kind that differs), and
//! assignments to INTENT(IN) dummy arguments. Each statement is read whole,
//! its continuation lines joined. Generic interfaces, intrinsics, procedure
//! pointers and procedures with alternate returns are not checked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const objects = @import("objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;
const selection = @import("selection.zig");
const KW = @import("constants.zig").KW;
const typing = @import("argcheck/typing.zig");
const default_kinds = @import("default_kinds.zig");
const unit_kinds = @import("argcheck/unit_kinds.zig");
const ignore_tkr = @import("argcheck/ignore_tkr.zig");
const dimensions = @import("objects/dimensions.zig");
const Category = typing.Category;
const Typed = typing.Typed;
const numeric = typing.numeric;
const promote = typing.promote;
const oneOf = typing.oneOf;
const topLevel = typing.topLevel;
const operandEnd = typing.operandEnd;
const varCategory = typing.varCategory;
const category = typing.category;
const literalCategory = typing.literalCategory;
const intrinsic_kinds = typing.intrinsic_kinds;
const selectedIntKind = typing.selectedIntKind;
const selectedRealKind = typing.selectedRealKind;
const typeName = typing.typeName;
const isName = typing.isName;
const splitArgs = typing.splitArgs;
const keywordOf = typing.keywordOf;
const matching = typing.matching;

pub const Kind = enum { arguments, kinds, intent_in };

/// How an actual argument fits a dummy argument (`Checker.compare`)
pub const Match = union(enum) {
    /// its type, kind and rank are known and fit
    fits,
    /// nothing is known not to fit, but not all of it is known
    unknown,
    type: struct { want: Category, have: Category },
    kind: struct { cat: Category, want: i64, have: i64 },
    /// another derived type (for a generic reference)
    derived,
    /// an array for a scalar
    scalar_expected,
    /// a scalar for an array
    array_expected,
    /// arrays of different ranks
    rank: struct { want: usize, have: usize },
};

/// What a call's interface lets `Checker.compare` tell: an implicit one,
/// an explicit one (#719), a generic reference's specific
pub const Mode = enum { implicit, explicit, generic };

/// The rank of a DIMENSION (`:,:` 2, `*` 1), or null when it cannot be
/// told
pub fn rankOf(dims: ?[]const u8) ?usize {
    const d = std.mem.trim(u8, dims orelse return null, " ");
    // (assumed rank: any)
    if (d.len == 0 or std.mem.eql(u8, d, "..")) return null;
    var n: usize = 1;
    var rest = d;
    while (topLevel(rest, ',')) |i| : (rest = rest[i + 1 ..]) n += 1;
    return n;
}

/// What variable `v` takes its type from: what an associate name is
/// linked to, else `v`; null when that is no variable
fn typeSource(v: *Obj) ?*Obj {
    var o = v;
    // (a chain of links is free of loops)
    for (0..64) |_| {
        o = o.linkObj() orelse return o;
        if (o.kind != .variable) return null;
    }
    return null;
}

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
        if (std.mem.findScalar(u8, code, '!')) |i| code = code[0..i];
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
    "simple",      "typeof",      "classof",
};

/// The statements whose first word has parentheses after it that are no
/// call, though the workspace has a procedure of that name (stdlib_io's
/// function `open`): a statement cannot start with a function reference
const statement_words = [_][]const u8{
    "open",  "close", "read",     "write",      "inquire", "rewind", "backspace", "endfile",
    "flush", "wait",  "allocate", "deallocate", "nullify", "if",     "where",     "forall",
};

fn isSpec(word: []const u8) bool {
    for (spec_words) |k| if (std.ascii.eqlIgnoreCase(word, k)) return true;
    return std.ascii.startsWithIgnoreCase(word, "end");
}

pub const Checker = struct {
    a: Allocator,
    env: objects.Env,
    ast: *Ast,
    cache: std.StringHashMapUnmanaged(?*Obj) = .empty,
    /// the workspace's files, for `objects.declaredProcedure`
    files: []const *FortranFile,
    out: std.ArrayList(Problem) = .empty,
    /// the innermost scope of each line, found once
    inner: objects.InnerScopes,
    /// the `!dir$ ignore_tkr` and `NO_ARG_CHECK` directives of each
    /// procedure called, read once
    tkr: std.AutoHashMapUnmanaged(*const Obj, []const ignore_tkr.Entry) = .empty,
    /// the compiler has REAL(10) (`typing.native_real10`)
    real10: bool = typing.native_real10,
    /// the kinds of the types without one, of the file checked's options
    kinds: default_kinds.Kinds = .{},

    /// The kinds of the file that declares `v` (else of the file checked),
    /// with the `!DEC$ REAL:n` before its program unit
    fn kindsOf(c: *const Checker, v: *const Obj) default_kinds.Kinds {
        return unit_kinds.ofDeclaration(v) orelse c.kinds;
    }

    /// The kinds of a literal in `scope` of the file checked
    fn kindsIn(c: *const Checker, scope: ?*Obj) default_kinds.Kinds {
        var unit: *const Obj = scope orelse return c.kinds;
        while (unit.parent) |p| unit = p;
        const f = c.ast.file orelse return c.kinds;
        return unit_kinds.ofUnit(c.kinds, f.lines.items, c.ast, unit);
    }

    fn lookup(c: *Checker, scope: ?*Obj, name: []const u8, line_no: usize) !?*Obj {
        const lower = try std.ascii.allocLowerString(c.a, name);
        const key = try c.a.print("{x}:{s}", .{ @intFromPtr(scope), lower });
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
        try c.out.append(c.a, .{ .line = line, .start = j.cols[start], .end = e, .message = try c.a.print(fmt, args), .kind = kind });
    }

    fn statement(c: *Checker, j: Joined, s: usize, e: usize) !void {
        const text = j.text[s..e];
        var it = helpers.words(text);
        const first = it.next() orelse return;
        const line_no = j.lines[s + first.start] + 1;
        const scope = c.inner.at(line_no);
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
                const close = std.mem.findPos(u8, text, k, ">>>") orelse continue;
                k = close + 3;
                while (k < text.len and text[k] == ' ') k += 1;
            }
            if (k >= text.len or text[k] != '(') continue;
            if (w.start == first.start and oneOf(w.str, &statement_words)) continue;
            const close = matching(text, k) orelse continue;
            // `x(1)%f(2)`, `.and.`, a literal's kind: not calls of a name
            if (w.start > 0 and (text[w.start - 1] == '.' or std.ascii.isDigit(text[w.start - 1]))) continue;
            // `a%f(x)`, also written `a % f(x)`
            const is_member = std.mem.endsWith(u8, std.mem.trimEnd(u8, text[0..w.start], " "), "%");
            const callee_obj = if (is_member)
                try c.member(scope, text[0..w.end], w.str)
            else
                try c.lookup(scope, w.str, line_no);
            var obj = callee_obj orelse continue;
            // the caller's own declaration of a procedure it calls (#232)
            if (!is_member) if (try objects.declaredProcedure(c.env, c.ast, c.files, obj, true)) |p| {
                obj = p;
            };
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
        const names = try splitArgs(c.a, proc.argList());
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
        // a module procedure, an internal one, an interface body: not an
        // external procedure, whose interface is implicit
        const mode: Mode = if (proc.parent != null) .explicit else .implicit;
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
                const eq = std.mem.findScalar(u8, arg, '=').?;
                if (dummies.items[idx].obj) |d| try c.argType(j, s, w, proc, d, std.mem.trim(u8, arg[eq + 1 ..], " "), elemental, mode, scope, line_no);
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
                if (dummies.items[positional].obj) |d| try c.argType(j, s, w, proc, d, arg, elemental, mode, scope, line_no);
                positional += 1;
            }
        };
        for (dummies.items, given) |d, g| {
            if (g or d.optional) continue;
            try c.report(j, s + w.start, s + w.end, .arguments, "Missing argument {s} of {s}", .{ d.name, proc.name });
        }
    }

    /// The type and rank of an argument, against its dummy argument: the
    /// kind of type (integer, real, complex, logical, character, derived),
    /// its kind, and an array for a scalar or a scalar expression for an
    /// array (not for an elemental procedure), and with an explicit
    /// interface a rank that differs from an assumed-shape array's
    fn argType(c: *Checker, j: Joined, s: usize, w: helpers.Word, proc: *Obj, dummy: *Obj, actual: []const u8, elemental: bool, mode: Mode, scope: ?*Obj, line_no: usize) !void {
        // those that `!dir$ ignore_tkr` or `NO_ARG_CHECK` leaves out
        const ignored = try c.ignoredChecks(proc, dummy.name);
        switch (try c.compare(dummy, actual, elemental, mode, scope, line_no)) {
            .type => |t| if (!ignored.type) try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s}: {s} expected, {s} given", .{ dummy.name, proc.name, @tagName(t.want), @tagName(t.have) }),
            .kind => |k| if (!ignored.kind) {
                const t = typeName(k.cat);
                try c.report(j, s + w.start, s + w.end, .kinds, "Argument {s} of {s}: {s}({d}) expected, {s}({d}) given", .{ dummy.name, proc.name, t, k.want, t, k.have });
            },
            .scalar_expected => if (!ignored.rank) try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s}: a scalar expected, an array given", .{ dummy.name, proc.name }),
            .array_expected => if (!ignored.rank) try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s}: an array expected, a scalar given", .{ dummy.name, proc.name }),
            .rank => |r| if (!ignored.rank) try c.report(j, s + w.start, s + w.end, .arguments, "Argument {s} of {s}: rank {d} expected, rank {d} given", .{ dummy.name, proc.name, r.want, r.have }),
            .fits, .unknown, .derived => {},
        }
    }

    /// The checks of dummy argument `name` of `proc` that its `!dir$
    /// ignore_tkr` and `NO_ARG_CHECK` directives leave out
    fn ignoredChecks(c: *Checker, proc: *const Obj, name: []const u8) !ignore_tkr.Ignored {
        const gop = try c.tkr.getOrPut(c.a, proc);
        if (!gop.found_existing) gop.value_ptr.* = if (proc.file_ast.file) |f| try ignore_tkr.ofProcedure(c.a, f, proc.sline, proc.eline) else &.{};
        return ignore_tkr.of(gop.value_ptr.*, name);
    }

    /// How actual argument `actual` fits dummy argument `dummy`. For the
    /// diagnostics, an element (`x(1)`) or a character scalar fits an array
    /// (sequence association), and with an explicit interface only an
    /// assumed-shape array's rank is checked (#719). A `generic` reference
    /// asks instead for the same rank (an elemental procedure's scalar
    /// takes any), and the same derived type (or one that extends it, for
    /// a CLASS).
    pub fn compare(c: *Checker, dummy: *Obj, actual: []const u8, elemental: bool, mode: Mode, scope: ?*Obj, line_no: usize) !Match {
        const generic = mode == .generic;
        if (dummy.kind != .variable or actual.len == 0) return .unknown;
        const want = varCategory(dummy);
        const typed = (try c.exprType(actual, scope, line_no, 0)) orelse return .unknown;
        const have = typed.cat;
        var known = want != .unknown and have != .unknown;
        if (known and want != have) return .{ .type = .{ .want = want, .have = have } };
        // the kinds, when both are known
        if (known and want != .character and want != .derived) {
            const want_kind = try c.kindOfVar(dummy);
            const have_kind = if (typed.literal)
                try c.literalKind(actual, scope, line_no)
            else if (typed.obj) |v|
                try c.kindOfVar(v)
            else
                null;
            if (want_kind != null and have_kind != null) {
                if (want_kind.? != have_kind.?) return .{ .kind = .{ .cat = want, .want = want_kind.?, .have = have_kind.? } };
            } else known = false;
        }
        // a CHARACTER of another kind
        if (generic and known and want == .character) {
            for ([_]?*Obj{ dummy, typed.obj }) |o| if (o) |v_in| if (typeSource(v_in)) |v| if (v.varDataConst().vkind) |k| if (std.ascii.findIgnoreCase(k, "kind") != null) {
                known = false;
            };
        }
        if (generic and known and want == .derived) switch (try c.sameType(dummy, typed.obj)) {
            .no => return .derived,
            .unknown => known = false,
            .yes => {},
        };
        const dims = dummy.keyword_info.dimension;
        const dummy_array = dummy.hasKeyword(KW.dimension) or dims != null;
        if (elemental and (generic or !dummy_array)) return if (known) .fits else .unknown;
        if (elemental) return .unknown;
        // assumed rank takes any
        if (dims) |d| if (std.mem.eql(u8, std.mem.trim(u8, d, " "), "..")) return if (known) .fits else .unknown;
        if (!typed.rank_known) return .unknown;
        // an assumed-shape array takes an array of its rank alone (#719)
        const assumed_shape = mode == .explicit and dimensions.shapeOf(dims) == .assumed;
        if (typed.array and !dummy_array) return .scalar_expected;
        if (!typed.array and dummy_array) {
            if (generic or assumed_shape) return .array_expected;
            // an element (`x(1)`) or a character may start an element
            // sequence, as anything may for TYPE(*); with an implicit
            // interface also a scalar variable
            if (have == .character or want == .unknown or have == .unknown) return .unknown;
            if (!typed.designator) return .array_expected;
            if (mode == .explicit and dimensions.shapeOf(dims) == .sequence and !typed.subscripted) return .array_expected;
            return .unknown;
        }
        if (typed.array and dummy_array) {
            if (!generic and !assumed_shape) return .unknown;
            const want_rank = rankOf(dims) orelse return .unknown;
            // a section's or an expression's (#718)
            const have_rank = if (typed.rank > 0) typed.rank else return .unknown;
            if (want_rank != have_rank) return .{ .rank = .{ .want = want_rank, .have = have_rank } };
        }
        return if (known) .fits else .unknown;
    }

    /// Whether variable `v` has the derived type of dummy argument `dummy`
    /// (or, for a CLASS dummy argument, a type that extends it)
    fn sameType(c: *Checker, dummy: *Obj, v_opt: ?*Obj) !enum { yes, no, unknown } {
        const v = v_opt orelse return .unknown;
        const want = (try dummy.getTypeObj(c.env)) orelse return .unknown;
        var t = (try v.getTypeObj(c.env)) orelse return .unknown;
        if (want.kind != .type or t.kind != .type) return .unknown;
        if (t == want) return .yes;
        if (!std.ascii.startsWithIgnoreCase(std.mem.trim(u8, dummy.descOf(), " "), "class")) return .no;
        var n: usize = 0;
        while (n < 20) : (n += 1) {
            // a type that extends one not found
            if (t.data == .scope and t.data.scope.inherit != null and t.typeDataConst().inherit_var == null) return .unknown;
            t = t.typeDataConst().inherit_var orelse return .no;
            if (t == want) return .yes;
        }
        return .unknown;
    }

    /// The type of an argument: a literal, a variable or a part of one
    /// (`a(i)%b(:)`), or an expression of these with intrinsic operators;
    /// null when it cannot be told (a function, a user-defined operator, a
    /// derived type in an expression)
    fn exprType(c: *Checker, expr_in: []const u8, scope: ?*Obj, line_no: usize, depth: usize) Allocator.Error!?Typed {
        if (depth > 16) return null;
        const e = std.mem.trim(u8, expr_in, " ");
        if (e.len == 0) return null;
        if (literalCategory(e)) |lc| return .{ .cat = lc, .literal = true };
        if (std.ascii.isAlphabetic(e[0])) if (try c.designator(e, scope, line_no, depth)) |t| return t;
        // a conditional expression (F2023): the type of its values (#733)
        if (typing.conditionalValue(e)) |value| {
            const t = (try c.exprType(value, scope, line_no, depth + 1)) orelse return null;
            return .{ .cat = t.cat, .array = t.array, .rank = t.rank, .rank_known = t.rank_known, .obj = t.obj };
        }
        // a whole expression in parentheses, or a complex literal
        if (e[0] == '(' and matching(e, 0) == e.len - 1) {
            const inner = e[1 .. e.len - 1];
            if (topLevel(inner, ',')) |comma| {
                const re = (try c.exprType(inner[0..comma], scope, line_no, depth + 1)) orelse return null;
                const im = (try c.exprType(inner[comma + 1 ..], scope, line_no, depth + 1)) orelse return null;
                if (re.literal and im.literal and numeric(re.cat) and numeric(im.cat)) return .{ .cat = .complex };
                return null;
            }
            const t = (try c.exprType(inner, scope, line_no, depth + 1)) orelse return null;
            return .{ .cat = t.cat, .array = t.array, .rank = t.rank, .rank_known = t.rank_known };
        }
        // an array constructor: the type of its first element
        if ((e[0] == '[' and e[e.len - 1] == ']') or (e.len >= 4 and std.mem.startsWith(u8, e, "(/") and std.mem.endsWith(u8, e, "/)"))) {
            const inner = if (e[0] == '[') e[1 .. e.len - 1] else e[2 .. e.len - 2];
            // a type spec (`[real :: ...]`) or an implied DO
            if (std.mem.find(u8, inner, "::") != null or std.mem.findScalar(u8, inner, '=') != null) return null;
            const first = inner[0 .. topLevel(inner, ',') orelse inner.len];
            const t = (try c.exprType(first, scope, line_no, depth + 1)) orelse return null;
            return .{ .cat = t.cat, .array = true, .rank = 1 };
        }
        // operands and the operators between them
        var cat: Category = .unknown;
        var array = false;
        var rank: usize = 0;
        var rank_known = true;
        var relational = false;
        var logical_op = false;
        var concat = false;
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
        if (relational or logical_op) return .{ .cat = .logical, .array = array, .rank = rank, .rank_known = rank_known };
        if (concat) return if (cat == .character) .{ .cat = .character, .array = array, .rank = rank, .rank_known = rank_known } else null;
        if (!numeric(cat)) return null;
        return .{ .cat = cat, .array = array, .rank = rank, .rank_known = rank_known };
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
            const obj = if (v) |parent|
                (try c.component(parent, name)) orelse return null
            else
                (try c.lookup(scope, name, line_no)) orelse return null;
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
        return .{ .cat = varCategory(v_type), .array = array, .rank = rank, .designator = true, .subscripted = subscripted_last, .rank_known = rank_known, .obj = obj };
    }

    /// A component of a variable of derived type, in its type or a type
    /// that type extends
    fn component(c: *Checker, v: *Obj, name: []const u8) !?*Obj {
        var t = (try v.getTypeObj(c.env)) orelse return null;
        const lower = try std.ascii.allocLowerString(c.a, name);
        var n: usize = 0;
        while (n < 20) : (n += 1) {
            if (t.kind != .type) return null;
            if (try objects.findInScope(c.env, t, lower, .{ .local_only = true })) |comp| return comp;
            t = t.typeDataConst().inherit_var orelse return null;
        }
        return null;
    }

    /// The rank of the section that subscripts select: the number of `:`
    /// and of arrays (vector subscripts) among them, 0 for an element; null
    /// when a subscript's type cannot be told
    fn sectionRank(c: *Checker, subs: []const u8, scope: ?*Obj, line_no: usize, depth: usize) !?usize {
        var rank: usize = 0;
        var start: usize = 0;
        while (start <= subs.len) {
            const end = if (topLevel(subs[start..], ',')) |k| start + k else subs.len;
            const sub = std.mem.trim(u8, subs[start..end], " ");
            if (topLevel(sub, ':') != null) {
                rank += 1;
            } else if (sub.len > 0) {
                const t = (try c.exprType(sub, scope, line_no, depth + 1)) orelse return null;
                if (!t.rank_known) return null;
                if (t.array) rank += 1;
            }
            start = end + 1;
        }
        return rank;
    }

    /// The kind of a variable's type, as gfortran numbers kinds (4 for a
    /// default REAL, 8 for DOUBLE PRECISION), or null when it cannot be told
    fn kindOfVar(c: *Checker, v_in: *Obj) !?i64 {
        if (v_in.kind != .variable) return null;
        const v = typeSource(v_in) orelse return null;
        const desc = std.mem.trim(u8, v.descOf(), " ");
        const k = c.kindsOf(v);
        if (std.ascii.startsWithIgnoreCase(desc, "double")) return k.double;
        const cat = category(desc);
        const real = cat == .real or cat == .complex;
        const spec = std.mem.trim(u8, v.varDataConst().vkind orelse "", " ");
        if (spec.len == 0) return if (real) k.real else if (cat == .integer or cat == .logical) k.integer else 4;
        if (spec[0] == '*') {
            const n = std.fmt.parseInt(i64, std.mem.trim(u8, spec[1..], " "), 10) catch return null;
            // COMPLEX*16 is two REAL(8)
            return k.promoted(real, if (cat == .complex) @divTrunc(n, 2) else n);
        }
        if (spec[0] != '(' or spec[spec.len - 1] != ')') return null;
        var inner = std.mem.trim(u8, spec[1 .. spec.len - 1], " ");
        if (std.mem.findScalar(u8, inner, '=')) |eq| {
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, inner[0..eq], " "), "kind")) return null;
            inner = std.mem.trim(u8, inner[eq + 1 ..], " ");
        }
        const n = (try c.kindValue(inner, v.parent, v.sline, 0)) orelse return null;
        return k.promoted(real, n);
    }

    /// The kind of a literal argument (`1.0` 4, `1d0` 8, `1.0_dp` that of
    /// `dp`)
    fn literalKind(c: *Checker, lit: []const u8, scope: ?*Obj, line_no: usize) !?i64 {
        const k = c.kindsIn(scope);
        if (lit[0] == '.') if (std.ascii.startsWithIgnoreCase(lit, ".true.") or std.ascii.startsWithIgnoreCase(lit, ".false.")) return k.integer;
        const real = literalCategory(lit) == .real;
        if (std.mem.findScalarLast(u8, lit, '_')) |u| {
            const n = (try c.kindValue(lit[u + 1 ..], scope, line_no, 0)) orelse return null;
            return k.promoted(real, n);
        }
        for (lit) |ch| switch (ch) {
            'd', 'D' => return k.double,
            'q', 'Q' => return 16,
            else => {},
        };
        return if (real) k.real else k.integer;
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
        const open = std.mem.findScalar(u8, expr, '(') orelse return null;
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
                arg = std.mem.trim(u8, arg[std.mem.findScalar(u8, arg, '=').? + 1 ..], " ");
            }
            const n = (try c.kindValue(arg, scope, line_no, depth + 1)) orelse return null;
            if (which == 'p') p = n else if (which == 'r') r = n else return null;
        }
        if (!real) return selectedIntKind(p orelse return null);
        return selectedRealKind(p, r, c.real10);
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
        const code = if (std.mem.findScalar(u8, text, '!')) |i| text[0..i] else text;
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

/// A checker for the arguments of single calls (`Checker.compare`); with no
/// workspace files, which only serve the checks of a file's calls
pub fn checker(a: Allocator, env: objects.Env, ast: *Ast) Checker {
    return .{ .a = a, .env = env, .ast = ast, .files = &.{}, .inner = .{ .lines = &.{}, .none_scope = null } };
}

/// The type of expression `expr` in `scope` (1-based `line_no`), as the
/// checks tell types apart; null when it cannot be told (for the type of an
/// ASSOCIATE name bound to an expression)
pub fn expressionType(a: Allocator, env: objects.Env, ast: *Ast, scope: ?*Obj, expr: []const u8, line_no: usize) !?Typed {
    var c = checker(a, env, ast);
    return c.exprType(expr, scope, line_no, 0);
}

/// The value of integer constant expression `expr` in `scope` (1-based
/// `line_no`) as kinds are told: a number, a named constant, an inquiry of
/// a kind; null when it cannot be told
pub fn constantValue(a: Allocator, env: objects.Env, ast: *Ast, scope: ?*Obj, expr: []const u8, line_no: usize) !?i64 {
    var c = checker(a, env, ast);
    return c.kindValue(expr, scope, line_no, 0);
}

/// `files`: the workspace's; `real10`: the compiler has REAL(10)
pub fn check(a: Allocator, env: objects.Env, file: *const FortranFile, ast: *Ast, files: []const *FortranFile, real10: bool) ![]const Problem {
    const n = file.nLines();
    var c: Checker = .{ .a = a, .env = env, .ast = ast, .files = files, .inner = try ast.innerScopes(a, n), .real10 = real10, .kinds = file.default_kinds };
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
