//! The evaluator of `#if` expressions (preprocessor.zig): Python's
//! expression semantics, which fortls relied on (`eval`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Minimal evaluator for Python expressions consisting of literals,
/// arithmetic, comparisons and boolean operators.
pub const PyEval = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,

    pub const Err = error{ Syntax, Type, ZeroDivision, Name, OutOfMemory };

    pub const Value = union(enum) {
        int: i128,
        float: f64,
        boolean: bool,
        string: []const u8,
        none,

        pub fn truthy(v: Value) bool {
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

    pub fn evaluate(e: *PyEval) Err!Value {
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

    /// Python's `x % y`, with the sign of `y` (`@mod` takes no negative
    /// `y`); `y` is not zero
    fn pyMod(comptime T: type, x: T, y: T) T {
        if (T == i128 and y == -1) return 0;
        const m = @rem(x, y);
        return if (m != 0 and (m < 0) != (y < 0)) m + y else m;
    }

    fn arith(op: u8, l: Value, r: Value) Err!Value {
        if (op == '+' and l == .string and r == .string) return error.Type;
        if (!l.isNumeric() or !r.isNumeric()) return error.Type;
        const both_int = l.asInt() != null and r.asInt() != null;
        // an integer out of i128's range is not evaluated (Python's has no
        // bound), rather than overflowing
        switch (op) {
            '+' => return if (both_int) .{ .int = std.math.add(i128, l.asInt().?, r.asInt().?) catch return error.Type } else .{ .float = l.asFloat() + r.asFloat() },
            '-' => return if (both_int) .{ .int = std.math.sub(i128, l.asInt().?, r.asInt().?) catch return error.Type } else .{ .float = l.asFloat() - r.asFloat() },
            '*' => return if (both_int) .{ .int = std.math.mul(i128, l.asInt().?, r.asInt().?) catch return error.Type } else .{ .float = l.asFloat() * r.asFloat() },
            '/' => {
                if (r.asFloat() == 0) return error.ZeroDivision;
                return .{ .float = l.asFloat() / r.asFloat() };
            },
            'f' => { // floor division
                if (r.asFloat() == 0) return error.ZeroDivision;
                if (both_int) return .{ .int = std.math.divFloor(i128, l.asInt().?, r.asInt().?) catch return error.Type };
                return .{ .float = @floor(l.asFloat() / r.asFloat()) };
            },
            '%' => {
                if (r.asFloat() == 0) return error.ZeroDivision;
                if (both_int) return .{ .int = pyMod(i128, l.asInt().?, r.asInt().?) };
                return .{ .float = pyMod(f64, l.asFloat(), r.asFloat()) };
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
                if (c == '-') return if (v.asInt()) |i| .{ .int = std.math.negate(i) catch return error.Type } else .{ .float = -v.asFloat() };
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
                const n = exp.asInt().?;
                // 0, 1 and -1 never overflow: their powers without a loop of
                // up to 2^127 steps
                switch (b) {
                    0 => return .{ .int = if (n == 0) 1 else 0 },
                    1 => return .{ .int = 1 },
                    -1 => return .{ .int = if (@rem(n, 2) == 0) 1 else -1 },
                    else => {},
                }
                var result: i128 = 1;
                var k: i128 = 0;
                while (k < n) : (k += 1) {
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
            const close = std.mem.findScalarPos(u8, e.src, e.pos + 1, c) orelse return error.Syntax;
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

fn evalInt(src: []const u8) PyEval.Err!i128 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ev: PyEval = .{ .a = arena.allocator(), .src = src };
    return switch (try ev.evaluate()) {
        .int => |i| i,
        else => error.Type,
    };
}

test "integers out of range are errors, not overflows; Python's % and //" {
    try std.testing.expectError(error.Type, evalInt("2**126 + 2**126"));
    try std.testing.expectError(error.Type, evalInt("-(2**126) - 2**126 - 2**126"));
    try std.testing.expectError(error.Type, evalInt("2**100 * 2**100"));
    try std.testing.expectError(error.Type, evalInt("(-(2**126) - 2**126) // -1"));
    try std.testing.expectEqual(@as(i128, -1), try evalInt("7 % -4"));
    try std.testing.expectEqual(@as(i128, 1), try evalInt("-7 % 4"));
    try std.testing.expectEqual(@as(i128, 0), try evalInt("5 % -1"));
    try std.testing.expectEqual(@as(i128, -2), try evalInt("-7 // 4"));
}

test "powers of 0, 1 and -1 with huge exponents end at once" {
    try std.testing.expectEqual(@as(i128, 1), try evalInt("1 ** 170141183460469231731687303715884105727"));
    try std.testing.expectEqual(@as(i128, -1), try evalInt("(-1) ** 170141183460469231731687303715884105727"));
    try std.testing.expectEqual(@as(i128, 0), try evalInt("0 ** 170141183460469231731687303715884105727"));
    try std.testing.expectEqual(@as(i128, 1), try evalInt("0 ** 0"));
    try std.testing.expectError(error.Type, evalInt("2 ** 170141183460469231731687303715884105727"));
}
