//! C-style preprocessor used for Fortran sources (port of `preprocess_file`)
//!
//! `#if` expressions are rewritten exactly like fortls does and then
//! evaluated with a small evaluator implementing the Python expression
//! semantics fortls relied on (`eval`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const patterns = @import("patterns.zig");
const regex = @import("regex.zig");
const paths = @import("paths.zig");
const helpers = @import("helpers.zig");
const parser = @import("parser.zig");

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// A macro definition: object-like (`args == null`) or function-like
pub const Def = struct {
    args: ?[]const u8 = null,
    value: []const u8,
};

/// Ordered macro table (insertion order matters for substitution)
pub const Defs = std.array_hash_map.String(Def);

/// A range of lines (1-based, inclusive) that a conditional excludes
pub const Skip = struct { start: usize, end: usize };

/// An `#include` directive of the file itself (not of an included file) that
/// names a file that exists
pub const Include = struct {
    /// 1-based line of the directive
    line: usize,
    /// Absolute path of the included file
    path: []const u8,
};

pub const Output = struct {
    lines: [][]const u8,
    /// 1-based line ranges excluded by conditionals
    skips: []Skip,
    /// 1-based line numbers of #define/#undef statements
    defines: []usize,
    includes: []Include,
    defs: Defs,
};

/// Copy a macro table into `a`
pub fn cloneDefs(a: Allocator, defs: *const Defs) !Defs {
    var out: Defs = .empty;
    var it = defs.iterator();
    while (it.next()) |e| {
        try out.put(a, try a.dupe(u8, e.key_ptr.*), .{
            .args = try str.dupeOpt(a, e.value_ptr.args),
            .value = try a.dupe(u8, e.value_ptr.value),
        });
    }
    return out;
}

// --------------------------------------------------------------------------
// #if evaluation

const ReplaceCtx = struct { defs: *const Defs };

fn replDefined(ctx: ReplaceCtx, a: Allocator, out: *std.ArrayList(u8), m: regex.Match) Allocator.Error!void {
    if (ctx.defs.contains(m.group(1).?)) {
        try out.appendSlice(a, "(@$@)");
    } else {
        try out.appendSlice(a, "(%$%)");
    }
}

const VarErr = error{TupleValue} || Allocator.Error;

fn replaceVars(a: Allocator, line: []const u8, defs: *const Defs) VarErr![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = helpers.words(line);
    var i_0: usize = 0;
    while (it.next()) |m| {
        try out.appendSlice(a, line[i_0..m.start]);
        if (defs.get(m.str)) |d| {
            // fortls fails on function-like macros here
            if (d.args != null) return error.TupleValue;
            try out.appendSlice(a, d.value);
        } else {
            try out.appendSlice(a, "False");
        }
        i_0 = m.end;
    }
    if (i_0 < line.len) try out.appendSlice(a, line[i_0..]);
    var res = try std.mem.replaceOwned(u8, a, out.items, "@$@", "True");
    res = try std.mem.replaceOwned(u8, a, res, "%$%", "False");
    return res;
}

fn replaceOps(a: Allocator, expr: []const u8) ![]const u8 {
    var e = try std.mem.replaceOwned(u8, a, expr, "&&", " and ");
    e = try std.mem.replaceOwned(u8, a, e, "||", " or ");
    e = try std.mem.replaceOwned(u8, a, e, "!=", " <> ");
    e = try std.mem.replaceOwned(u8, a, e, "!", " not ");
    e = try std.mem.replaceOwned(u8, a, e, " <> ", " != ");
    return e;
}

/// Evaluate a preprocessor `#if` condition
pub fn evalPpIf(a: Allocator, text: []const u8, defs: *const Defs) bool {
    const step1 = R().DEFINED.subFn(a, text, ReplaceCtx{ .defs = defs }, replDefined) catch return false;
    const step2 = replaceVars(a, step1, defs) catch return false;
    const expr = replaceOps(a, step2) catch return false;
    var ev: PyEval = .{ .a = a, .src = expr };
    const v = ev.evaluate() catch return false;
    return v.truthy();
}

/// Minimal evaluator for Python expressions consisting of literals,
/// arithmetic, comparisons and boolean operators.
const PyEval = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,

    const Err = error{ Syntax, Type, ZeroDivision, Name, OutOfMemory };

    const Value = union(enum) {
        int: i128,
        float: f64,
        boolean: bool,
        string: []const u8,
        none,

        fn truthy(v: Value) bool {
            return switch (v) {
                .int => |i| i != 0,
                .float => |f| f != 0,
                .boolean => |b| b,
                .string => |s| s.len > 0,
                .none => false,
            };
        }

        fn isNumeric(v: Value) bool {
            return v == .int or v == .float or v == .boolean;
        }

        fn asInt(v: Value) ?i128 {
            return switch (v) {
                .int => |i| i,
                .boolean => |b| @intFromBool(b),
                else => null,
            };
        }

        fn asFloat(v: Value) f64 {
            return switch (v) {
                .int => |i| @floatFromInt(i),
                .float => |f| f,
                .boolean => |b| if (b) 1.0 else 0.0,
                else => 0,
            };
        }
    };

    fn evaluate(e: *PyEval) Err!Value {
        const v = try e.parseOr();
        e.skipWs();
        if (e.pos != e.src.len) return error.Syntax;
        return v;
    }

    fn skipWs(e: *PyEval) void {
        while (e.pos < e.src.len and std.ascii.isWhitespace(e.src[e.pos])) e.pos += 1;
    }

    fn peekKeyword(e: *PyEval, kw: []const u8) bool {
        e.skipWs();
        const rest = e.src[e.pos..];
        if (!std.mem.startsWith(u8, rest, kw)) return false;
        if (rest.len > kw.len and (std.ascii.isAlphanumeric(rest[kw.len]) or rest[kw.len] == '_')) return false;
        return true;
    }

    fn peekOp(e: *PyEval, op: []const u8) bool {
        e.skipWs();
        return std.mem.startsWith(u8, e.src[e.pos..], op);
    }

    fn parseOr(e: *PyEval) Err!Value {
        var left = try e.parseAnd();
        while (e.peekKeyword("or")) {
            e.pos += 2;
            const right = try e.parseAnd();
            if (!left.truthy()) left = right;
        }
        return left;
    }

    fn parseAnd(e: *PyEval) Err!Value {
        var left = try e.parseNot();
        while (e.peekKeyword("and")) {
            e.pos += 3;
            const right = try e.parseNot();
            if (left.truthy()) left = right;
        }
        return left;
    }

    fn parseNot(e: *PyEval) Err!Value {
        if (e.peekKeyword("not")) {
            e.pos += 3;
            const v = try e.parseNot();
            return .{ .boolean = !v.truthy() };
        }
        return e.parseComparison();
    }

    const CmpOp = enum { eq, ne, le, ge, lt, gt };

    /// Comparison operators by their text; two-character ones come first
    const cmp_ops = [_]struct { []const u8, CmpOp }{
        .{ "==", .eq },
        .{ "!=", .ne },
        .{ "<=", .le },
        .{ ">=", .ge },
        .{ "<", .lt },
        .{ ">", .gt },
    };

    fn parseComparison(e: *PyEval) Err!Value {
        var left = try e.parseBitOr();
        var result: ?bool = null;
        while (true) {
            e.skipWs();
            var op: ?CmpOp = null;
            var op_len: usize = 0;
            for (cmp_ops) |entry| {
                const text, const kind = entry;
                if (std.mem.startsWith(u8, e.src[e.pos..], text)) {
                    // don't confuse '<<' / '>>' with comparisons
                    if ((kind == .lt or kind == .gt) and e.pos + 1 < e.src.len and e.src[e.pos + 1] == text[0]) break;
                    op = kind;
                    op_len = text.len;
                    break;
                }
            }
            const o = op orelse break;
            e.pos += op_len;
            const right = try e.parseBitOr();
            const r = try compare(o, left, right);
            result = (result orelse true) and r;
            left = right;
        }
        if (result) |r| return .{ .boolean = r };
        return left;
    }

    fn compare(op: CmpOp, l: Value, r: Value) Err!bool {
        if (op == .eq or op == .ne) {
            var eq: bool = undefined;
            if (l.isNumeric() and r.isNumeric()) {
                eq = l.asFloat() == r.asFloat();
                if (l.asInt() != null and r.asInt() != null) eq = l.asInt().? == r.asInt().?;
            } else if (l == .string and r == .string) {
                eq = std.mem.eql(u8, l.string, r.string);
            } else if (l == .none and r == .none) {
                eq = true;
            } else eq = false;
            return if (op == .eq) eq else !eq;
        }
        var ord: std.math.Order = undefined;
        if (l.isNumeric() and r.isNumeric()) {
            if (l.asInt() != null and r.asInt() != null) {
                ord = std.math.order(l.asInt().?, r.asInt().?);
            } else {
                ord = std.math.order(l.asFloat(), r.asFloat());
            }
        } else if (l == .string and r == .string) {
            ord = std.mem.order(u8, l.string, r.string);
        } else return error.Type;
        return switch (op) {
            .lt => ord == .lt,
            .gt => ord == .gt,
            .le => ord != .gt,
            else => ord != .lt,
        };
    }

    fn intBinop(l: Value, r: Value) Err![2]i128 {
        const li = l.asInt() orelse return error.Type;
        const ri = r.asInt() orelse return error.Type;
        return .{ li, ri };
    }

    fn parseBitOr(e: *PyEval) Err!Value {
        var left = try e.parseBitXor();
        while (e.peekOp("|")) {
            e.pos += 1;
            const v = try intBinop(left, try e.parseBitXor());
            left = .{ .int = v[0] | v[1] };
        }
        return left;
    }

    fn parseBitXor(e: *PyEval) Err!Value {
        var left = try e.parseBitAnd();
        while (e.peekOp("^")) {
            e.pos += 1;
            const v = try intBinop(left, try e.parseBitAnd());
            left = .{ .int = v[0] ^ v[1] };
        }
        return left;
    }

    fn parseBitAnd(e: *PyEval) Err!Value {
        var left = try e.parseShift();
        while (e.peekOp("&")) {
            e.pos += 1;
            const v = try intBinop(left, try e.parseShift());
            left = .{ .int = v[0] & v[1] };
        }
        return left;
    }

    fn parseShift(e: *PyEval) Err!Value {
        var left = try e.parseArith();
        while (true) {
            if (e.peekOp("<<")) {
                e.pos += 2;
                const v = try intBinop(left, try e.parseArith());
                if (v[1] < 0 or v[1] > 100) return error.Type;
                left = .{ .int = v[0] << @intCast(v[1]) };
            } else if (e.peekOp(">>")) {
                e.pos += 2;
                const v = try intBinop(left, try e.parseArith());
                if (v[1] < 0) return error.Type;
                left = .{ .int = v[0] >> @intCast(@min(v[1], 127)) };
            } else break;
        }
        return left;
    }

    fn arith(op: u8, l: Value, r: Value) Err!Value {
        if (op == '+' and l == .string and r == .string) return error.Type;
        if (!l.isNumeric() or !r.isNumeric()) return error.Type;
        const both_int = l.asInt() != null and r.asInt() != null;
        switch (op) {
            '+' => return if (both_int) .{ .int = l.asInt().? + r.asInt().? } else .{ .float = l.asFloat() + r.asFloat() },
            '-' => return if (both_int) .{ .int = l.asInt().? - r.asInt().? } else .{ .float = l.asFloat() - r.asFloat() },
            '*' => return if (both_int) .{ .int = l.asInt().? * r.asInt().? } else .{ .float = l.asFloat() * r.asFloat() },
            '/' => {
                if (r.asFloat() == 0) return error.ZeroDivision;
                return .{ .float = l.asFloat() / r.asFloat() };
            },
            'f' => { // floor division
                if (r.asFloat() == 0) return error.ZeroDivision;
                if (both_int) return .{ .int = @divFloor(l.asInt().?, r.asInt().?) };
                return .{ .float = @floor(l.asFloat() / r.asFloat()) };
            },
            '%' => {
                if (r.asFloat() == 0) return error.ZeroDivision;
                if (both_int) return .{ .int = @mod(l.asInt().?, r.asInt().?) };
                return .{ .float = @mod(l.asFloat(), r.asFloat()) };
            },
            else => return error.Syntax,
        }
    }

    fn parseArith(e: *PyEval) Err!Value {
        var left = try e.parseTerm();
        while (true) {
            e.skipWs();
            if (e.pos >= e.src.len) break;
            const c = e.src[e.pos];
            if (c != '+' and c != '-') break;
            e.pos += 1;
            left = try arith(c, left, try e.parseTerm());
        }
        return left;
    }

    fn parseTerm(e: *PyEval) Err!Value {
        var left = try e.parseUnary();
        while (true) {
            e.skipWs();
            if (e.pos >= e.src.len) break;
            const rest = e.src[e.pos..];
            if (std.mem.startsWith(u8, rest, "**")) break;
            if (std.mem.startsWith(u8, rest, "//")) {
                e.pos += 2;
                left = try arith('f', left, try e.parseUnary());
            } else if (rest[0] == '*' or rest[0] == '/' or rest[0] == '%') {
                e.pos += 1;
                left = try arith(rest[0], left, try e.parseUnary());
            } else break;
        }
        return left;
    }

    fn parseUnary(e: *PyEval) Err!Value {
        e.skipWs();
        if (e.pos < e.src.len) {
            const c = e.src[e.pos];
            if (c == '-' or c == '+' or c == '~') {
                e.pos += 1;
                const v = try e.parseUnary();
                if (!v.isNumeric()) return error.Type;
                if (c == '+') return if (v.asInt()) |i| .{ .int = i } else v;
                if (c == '-') return if (v.asInt()) |i| .{ .int = -i } else .{ .float = -v.asFloat() };
                const i = v.asInt() orelse return error.Type;
                return .{ .int = ~i };
            }
        }
        return e.parsePower();
    }

    fn parsePower(e: *PyEval) Err!Value {
        const base = try e.parseAtom();
        if (e.peekOp("**")) {
            e.pos += 2;
            const exp = try e.parseUnary();
            if (!base.isNumeric() or !exp.isNumeric()) return error.Type;
            if (base.asInt() != null and exp.asInt() != null and exp.asInt().? >= 0) {
                const b = base.asInt().?;
                var result: i128 = 1;
                var k: i128 = 0;
                while (k < exp.asInt().?) : (k += 1) {
                    result = std.math.mul(i128, result, b) catch return error.Type;
                }
                return .{ .int = result };
            }
            return .{ .float = std.math.pow(f64, base.asFloat(), exp.asFloat()) };
        }
        return base;
    }

    fn parseAtom(e: *PyEval) Err!Value {
        e.skipWs();
        if (e.pos >= e.src.len) return error.Syntax;
        const c = e.src[e.pos];
        if (c == '(') {
            e.pos += 1;
            e.skipWs();
            if (e.pos < e.src.len and e.src[e.pos] == ')') return error.Type; // empty tuple
            const v = try e.parseOr();
            e.skipWs();
            if (e.pos >= e.src.len or e.src[e.pos] != ')') return error.Syntax;
            e.pos += 1;
            return v;
        }
        if (c == '\'' or c == '"') {
            const close = std.mem.indexOfScalarPos(u8, e.src, e.pos + 1, c) orelse return error.Syntax;
            const s = e.src[e.pos + 1 .. close];
            e.pos = close + 1;
            return .{ .string = s };
        }
        if (std.ascii.isDigit(c) or (c == '.' and e.pos + 1 < e.src.len and std.ascii.isDigit(e.src[e.pos + 1]))) {
            return e.parseNumber();
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = e.pos;
            while (e.pos < e.src.len and (std.ascii.isAlphanumeric(e.src[e.pos]) or e.src[e.pos] == '_')) e.pos += 1;
            const word = e.src[start..e.pos];
            if (std.mem.eql(u8, word, "True")) return .{ .boolean = true };
            if (std.mem.eql(u8, word, "False")) return .{ .boolean = false };
            if (std.mem.eql(u8, word, "None")) return .none;
            return error.Name;
        }
        return error.Syntax;
    }

    fn parseNumber(e: *PyEval) Err!Value {
        const start = e.pos;
        const s = e.src;
        if (s[e.pos] == '0' and e.pos + 1 < s.len and std.ascii.isAlphabetic(s[e.pos + 1])) {
            const base: u8 = switch (std.ascii.toLower(s[e.pos + 1])) {
                'x' => 16,
                'o' => 8,
                'b' => 2,
                else => return error.Syntax,
            };
            e.pos += 2;
            const ds = e.pos;
            while (e.pos < s.len and (std.ascii.isAlphanumeric(s[e.pos]) or s[e.pos] == '_')) e.pos += 1;
            const v = std.fmt.parseInt(i128, s[ds..e.pos], base) catch return error.Syntax;
            return .{ .int = v };
        }
        var is_float = false;
        while (e.pos < s.len and (std.ascii.isDigit(s[e.pos]) or s[e.pos] == '_')) e.pos += 1;
        if (e.pos < s.len and s[e.pos] == '.') {
            is_float = true;
            e.pos += 1;
            while (e.pos < s.len and std.ascii.isDigit(s[e.pos])) e.pos += 1;
        }
        if (e.pos < s.len and (s[e.pos] == 'e' or s[e.pos] == 'E')) {
            const save = e.pos;
            e.pos += 1;
            if (e.pos < s.len and (s[e.pos] == '+' or s[e.pos] == '-')) e.pos += 1;
            if (e.pos < s.len and std.ascii.isDigit(s[e.pos])) {
                is_float = true;
                while (e.pos < s.len and std.ascii.isDigit(s[e.pos])) e.pos += 1;
            } else e.pos = save;
        }
        // an identifier glued to a number is a syntax error in Python
        if (e.pos < s.len and (std.ascii.isAlphabetic(s[e.pos]) or s[e.pos] == '_')) return error.Syntax;
        const text = try std.mem.replaceOwned(u8, e.a, s[start..e.pos], "_", "");
        if (is_float) return .{ .float = std.fmt.parseFloat(f64, text) catch return error.Syntax };
        // Python rejects leading zeros on non-zero decimal integers
        if (text.len > 1 and text[0] == '0') {
            for (text) |ch| if (ch != '0') return error.Syntax;
        }
        return .{ .int = std.fmt.parseInt(i128, text, 10) catch return error.Syntax };
    }
};

// --------------------------------------------------------------------------
// Preprocessing

const DefRegex = struct { re: regex.Regex, template: []const u8 };

fn expandFuncMacro(a: Allocator, def_name: []const u8, args: []const u8, value: []const u8) !DefRegex {
    const def_args = try str.split(a, args, ",");
    var pat: std.ArrayList(u8) = .empty;
    try pat.print(a, "\\b{s}\\s*\\(", .{def_name});
    for (def_args, 0..) |_, i| {
        if (i > 0) try pat.append(a, ',');
        try pat.appendSlice(a, "(.*)");
    }
    try pat.appendSlice(a, "\\)");
    var sub = value;
    for (def_args, 0..) |arg, i| {
        var arg_re = try regex.Regex.compile(a, try std.fmt.allocPrint(a, "\\b({s})\\b", .{str.strip(arg)}), .{});
        defer arg_re.deinit();
        sub = try arg_re.sub(a, try std.fmt.allocPrint(a, "\\\\{d}", .{i + 1}), sub);
    }
    return .{ .re = try regex.Regex.compile(a, pat.items, .{}), .template = sub };
}

fn appendMultilineMacro(a: Allocator, d: Def, line: []const u8) !Def {
    return .{ .args = d.args, .value = try std.mem.concat(a, u8, &.{ d.value, line }) };
}

/// An open conditional. `start` is the first line of its excluded part, null
/// while the branch is included; `end` the last one, null until known.
/// The conditional directives that `PP_REGEX` matches
const Directive = enum { if_, ifdef, ifndef, else_, elif, endif };

const directives = std.StaticStringMap(Directive).initComptime(.{
    .{ "if ", .if_ },
    .{ "ifdef", .ifdef },
    .{ "ifndef", .ifndef },
    .{ "else", .else_ },
    .{ "elif", .elif },
    .{ "endif", .endif },
});

const StackEntry = struct { start: ?usize = null, end: ?usize = null };

fn skipOf(e: StackEntry) Skip {
    return .{ .start = e.start.?, .end = e.end.? };
}

/// Preprocess `contents`; all results are allocated in `a`.
pub fn preprocessFile(
    a: Allocator,
    io: Io,
    contents: []const []const u8,
    file_path: ?[]const u8,
    pp_defs: ?*const Defs,
    include_dirs_in: []const []const u8,
    trace: ?parser.Trace,
) !Output {
    var include_dirs: std.ArrayList([]const u8) = .empty;
    if (file_path) |fp| {
        try include_dirs.append(a, try paths.abspath(a, paths.dirname(fp)));
    }
    for (include_dirs_in) |d| {
        var dup = false;
        for (include_dirs.items) |e| if (std.mem.eql(u8, e, d)) {
            dup = true;
        };
        if (!dup) try include_dirs.append(a, d);
    }
    return preprocessInner(a, io, contents, pp_defs, &include_dirs, 0, trace);
}

fn preprocessInner(
    a: Allocator,
    io: Io,
    contents: []const []const u8,
    pp_defs: ?*const Defs,
    include_dirs: *std.ArrayList([]const u8),
    depth: usize,
    trace: ?parser.Trace,
) !Output {
    var pp_skips: std.ArrayList(Skip) = .empty;
    var pp_defines: std.ArrayList(usize) = .empty;
    var pp_includes: std.ArrayList(Include) = .empty;
    var pp_stack: std.ArrayList(StackEntry) = .empty;
    var pp_stack_group: std.ArrayList(struct { usize, bool }) = .empty;
    var defs_tmp: Defs = if (pp_defs) |d| try cloneDefs(a, d) else .empty;
    var def_regexes = std.array_hash_map.String(?DefRegex).empty;
    defer {
        var it = def_regexes.iterator();
        while (it.next()) |e| if (e.value_ptr.*) |*dr| dr.re.deinit();
    }
    var output: std.ArrayList([]const u8) = .empty;
    var def_cont_name: ?[]const u8 = null;

    for (contents, 0..) |line_in, i| {
        var line = line_in;
        // Handle multiline macro continuation
        if (def_cont_name) |dcn| {
            try output.append(a, "");
            const stripped = str.strip(line);
            const is_multiline = stripped.len == 0 or stripped[stripped.len - 1] != '\\';
            const to_append = if (is_multiline) stripped else str.strip(line[0..line.len -| 1]);
            if (defs_tmp.get(dcn)) |d| try defs_tmp.put(a, dcn, try appendMultilineMacro(a, d, to_append));
            if (is_multiline) def_cont_name = null;
            continue;
        }
        // Handle conditional statements
        if (R().PP_REGEX.match(line)) |m| {
            try output.append(a, line);
            var kw_buf: [8]u8 = undefined;
            const kw = directives.get(std.ascii.lowerString(&kw_buf, m.group(1).?)).?;
            var if_start = false;
            var is_path = false;
            if (kw == .if_) {
                is_path = evalPpIf(a, line[m.end(1)..], &defs_tmp);
                if_start = true;
            } else if (kw == .ifdef) {
                if_start = true;
                is_path = defs_tmp.contains(str.strip(line[m.end(0)..]));
            } else if (kw == .ifndef) {
                if_start = true;
                is_path = !defs_tmp.contains(str.strip(line[m.end(0)..]));
            }
            if (if_start) {
                if (is_path) {
                    try pp_stack.append(a, .{});
                    parser.Trace.print(trace, "{s} !!! Conditional TRUE({d})", .{ str.strip(line), i + 1 });
                } else {
                    try pp_stack.append(a, .{ .start = i + 1 });
                    parser.Trace.print(trace, "{s} !!! Conditional FALSE({d})", .{ str.strip(line), i + 1 });
                }
                continue;
            }
            if (pp_stack.items.len == 0) continue;
            const depth_now = pp_stack.items.len;
            const top = &pp_stack.items[pp_stack.items.len - 1];
            var cond: enum { none, included, excluded_start, excluded } = .none;
            if (kw == .elif) {
                if (pp_stack_group.items.len == 0 or pp_stack_group.items[pp_stack_group.items.len - 1][0] != depth_now) {
                    try pp_stack_group.append(a, .{ depth_now, top.start == null });
                }
                const grp = &pp_stack_group.items[pp_stack_group.items.len - 1];
                if (grp[1]) {
                    // An earlier if or elif in this group has been true
                    if (top.start == null) top.start = i + 1;
                    cond = .excluded;
                } else if (evalPpIf(a, line[m.end(1)..], &defs_tmp)) {
                    top.end = i + 1;
                    try pp_skips.append(a, skipOf(pp_stack.pop().?));
                    grp[1] = true;
                    try pp_stack.append(a, .{});
                    cond = .included;
                } else cond = .excluded_start;
            } else if (kw == .else_) {
                if (top.start == null) {
                    top.start = i + 1;
                    cond = .excluded_start;
                } else if (pp_stack_group.items.len > 0 and
                    pp_stack_group.items[pp_stack_group.items.len - 1][0] == depth_now and
                    pp_stack_group.items[pp_stack_group.items.len - 1][1])
                {
                    // An earlier if or elif in this group has been true
                    cond = .excluded;
                } else {
                    top.end = i + 1;
                    try pp_skips.append(a, skipOf(pp_stack.pop().?));
                    try pp_stack.append(a, .{});
                    cond = .included;
                }
            } else if (kw == .endif) {
                if (pp_stack_group.items.len > 0 and pp_stack_group.items[pp_stack_group.items.len - 1][0] == depth_now) {
                    _ = pp_stack_group.pop();
                }
                if (top.start == null) {
                    _ = pp_stack.pop();
                    parser.Trace.print(trace, "{s} !!! Conditional TRUE/END({d})", .{ str.strip(line), i + 1 });
                    continue;
                }
                if (top.end == null) {
                    top.end = i + 1;
                    parser.Trace.print(trace, "{s} !!! Conditional FALSE/END({d})", .{ str.strip(line), i + 1 });
                }
                try pp_skips.append(a, skipOf(pp_stack.pop().?));
            }
            switch (cond) {
                .none => {},
                .included => parser.Trace.print(trace, "{s} !!! Conditional TRUE({d})", .{ str.strip(line), i + 1 }),
                .excluded_start => parser.Trace.print(trace, "{s} !!! Conditional FALSE({d})", .{ str.strip(line), i + 1 }),
                .excluded => parser.Trace.print(trace, "{s} !!! Conditional EXCLUDED({d})", .{ str.strip(line), i + 1 }),
            }
            continue;
        }
        var stack_is_true = true;
        for (pp_stack.items) |s| if (s.start != null) {
            stack_is_true = false;
        };
        // Handle variable/macro definitions
        if (R().PP_DEF.match(line)) |m| if (stack_is_true) {
            try output.append(a, line);
            try pp_defines.append(a, i + 1);
            const def_name = m.group(2).?;
            const directive = m.group(1).?;
            if (std.mem.eql(u8, directive, "define") and !defs_tmp.contains(def_name)) {
                var def_value: []const u8 = undefined;
                const rest = line[m.end(0)..];
                if (std.mem.indexOfScalar(u8, rest, ' ')) |eq_ind| {
                    const rs = str.rstrip(line);
                    if (rs.len > 0 and rs[rs.len - 1] == '\\') {
                        def_value = str.strip(line[m.end(0) + eq_ind .. @max(line.len -| 1, m.end(0) + eq_ind)]);
                        def_cont_name = try a.dupe(u8, def_name);
                    } else {
                        def_value = str.strip(line[m.end(0) + eq_ind ..]);
                    }
                } else {
                    def_value = "True";
                }
                var d: Def = .{ .value = try a.dupe(u8, def_value) };
                if (m.group(3) != null) d.args = try a.dupe(u8, m.group(4) orelse "");
                try defs_tmp.put(a, try a.dupe(u8, def_name), d);
            } else if (std.mem.eql(u8, directive, "undef") and defs_tmp.contains(def_name)) {
                _ = defs_tmp.orderedRemove(def_name);
            }
            parser.Trace.print(trace, "{s} !!! Define statement({d})", .{ str.strip(line), i + 1 });
            continue;
        };
        // Handle include files
        if (R().PP_INCLUDE.match(line)) |m| if (stack_is_true) {
            parser.Trace.print(trace, "{s} !!! Include statement({d})", .{ str.strip(line), i + 1 });
            const include_filename = try std.mem.replaceOwned(u8, a, m.group(1).?, "\"", "");
            var include_path: ?[]const u8 = null;
            for (include_dirs.items) |dir| {
                const candidate = try paths.join(a, &.{ dir, include_filename });
                if (paths.isFile(io, candidate)) {
                    include_path = try paths.abspath(a, candidate);
                    break;
                }
            }
            if (include_path) |ip| {
                if (depth == 0) try pp_includes.append(a, .{ .line = i + 1, .path = ip });
                // guard against include cycles
                if (depth >= 32) {} else if (Io.Dir.cwd().readFileAlloc(io, ip, a, .limited(1 << 28))) |data| {
                    const text = try std.mem.replaceOwned(u8, a, data, "\t", " ");
                    const inc_lines = try parser.splitLines(a, text);
                    const dir = try paths.abspath(a, paths.dirname(ip));
                    var dup = false;
                    for (include_dirs.items) |e| if (std.mem.eql(u8, e, dir)) {
                        dup = true;
                    };
                    if (!dup) try include_dirs.append(a, dir);
                    parser.Trace.print(trace, "\n!!! Parsing include file '{s}'", .{ip});
                    const res = try preprocessInner(a, io, inc_lines, &defs_tmp, include_dirs, depth + 1, trace);
                    defs_tmp = res.defs;
                    parser.Trace.print(trace, "!!! Completed parsing include file\n", .{});
                } else |_| {
                    parser.Trace.print(trace, "!!! Failed to parse include file: {s}", .{ip});
                }
            } else {
                parser.Trace.print(trace, "{s} !!! Could not locate include file ({d})", .{ str.strip(line), i + 1 });
            }
        };
        // Substitute (if any) read in preprocessor macros
        var it = defs_tmp.iterator();
        while (it.next()) |e| {
            const def_tmp = e.key_ptr.*;
            const value = e.value_ptr.*;
            if (std.mem.indexOf(u8, line, def_tmp) == null) continue;
            const gop = try def_regexes.getOrPut(a, def_tmp);
            if (!gop.found_existing) {
                gop.key_ptr.* = def_tmp;
                if (value.args) |args| {
                    gop.value_ptr.* = expandFuncMacro(a, def_tmp, args, value.value) catch |err| blk: {
                        parser.Trace.print(trace, "!!! bad macro {s}: {s}", .{ def_tmp, @errorName(err) });
                        break :blk null;
                    };
                } else {
                    const re = regex.Regex.compile(a, try std.fmt.allocPrint(a, "\\b{s}\\b", .{def_tmp}), .{}) catch null;
                    gop.value_ptr.* = if (re) |r| .{ .re = r, .template = "" } else null;
                }
            }
            const dr = gop.value_ptr.* orelse continue;
            const template = if (value.args != null) dr.template else value.value;
            const res = try dr.re.subn(a, template, line);
            if (res.count > 0) {
                const shown = if (value.args != null) dr.template else value.value;
                parser.Trace.print(trace, "{s} !!! Macro sub({d}) '{s}' -> '{s}'", .{ str.strip(line), i + 1, def_tmp, shown });
                line = res.out;
            }
        }
        try output.append(a, line);
    }
    return .{
        .lines = output.items,
        .skips = pp_skips.items,
        .defines = pp_defines.items,
        .includes = pp_includes.items,
        .defs = defs_tmp,
    };
}

const testing = std.testing;

test "pp if evaluation" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var defs: Defs = .empty;
    try defs.put(a, "A", .{ .value = "1" });
    try defs.put(a, "VER", .{ .value = "3" });
    try testing.expect(evalPpIf(a, " defined(A)", &defs));
    try testing.expect(!evalPpIf(a, " defined(B)", &defs));
    try testing.expect(evalPpIf(a, " !defined(B) && defined(A)", &defs));
    try testing.expect(evalPpIf(a, " VER >= 2", &defs));
    try testing.expect(!evalPpIf(a, " VER > 3 || 0", &defs));
    try testing.expect(evalPpIf(a, " 1", &defs));
    try testing.expect(!evalPpIf(a, " 0", &defs));
    try testing.expect(evalPpIf(a, " defined PETSC_ERR || defined A", &defs));
    try testing.expect(evalPpIf(a, " (VER - 1) * 2 == 4", &defs));
}

test "pp macro expansion" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{
        "#define N 10",
        "#define SQ(x) ((x)*(x))",
        "#if N > 5",
        "integer :: a(N)",
        "#else",
        "integer :: b",
        "#endif",
        "y = SQ(z)",
    };
    const out = try preprocessFile(a, undefined, &lines, null, null, &.{}, null);
    try testing.expectEqualStrings("integer :: a(10)", out.lines[3]);
    try testing.expectEqualStrings("y = ((z)*(z))", out.lines[7]);
    try testing.expectEqual(@as(usize, 1), out.skips.len);
    try testing.expectEqual(@as(usize, 5), out.skips[0].start);
    try testing.expectEqual(@as(usize, 7), out.skips[0].end);
}
