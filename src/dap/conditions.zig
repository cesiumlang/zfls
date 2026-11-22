//! Fortran expressions of scalars for `zfls dap`'s breakpoint conditions
//! and hit conditions on Windows's Debugger Engine (#734): literals,
//! designators (which the caller reads from the program), the arithmetic,
//! relational and logical operators with Fortran's precedence, both
//! spellings of the relational ones (`==`, `.eq.`). No Windows here.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Scalar = union(enum) {
    integer: i64,
    real: f64,
    logical: bool,
    character: []const u8,
};

pub const Error = error{ OutOfMemory, Syntax, UnknownName, TypeMismatch, DivisionByZero };

/// Reads a designator (`k`, `p%x`, `a(2,1)`, `grid::n`) of the program:
/// null when there is none of that name
pub const Lookup = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, a: Allocator, designator: []const u8) anyerror!?Scalar,
};

/// The value of `text`
pub fn evaluate(a: Allocator, text: []const u8, lookup: Lookup) Error!Scalar {
    var p: Parser = .{ .a = a, .text = text, .lookup = lookup };
    const v = try p.equivalence();
    p.skip();
    if (p.i != text.len) return error.Syntax;
    return v;
}

/// Whether `text` is true: a LOGICAL's value, or a number not zero
pub fn isTrue(a: Allocator, text: []const u8, lookup: Lookup) Error!bool {
    return switch (try evaluate(a, text, lookup)) {
        .logical => |b| b,
        .integer => |n| n != 0,
        .real => |x| x != 0,
        .character => error.TypeMismatch,
    };
}

/// An integer's value of `text` (a hit condition: the hits ignored)
pub fn integer(a: Allocator, text: []const u8, lookup: Lookup) Error!i64 {
    return switch (try evaluate(a, text, lookup)) {
        .integer => |n| n,
        .real => |x| if (std.math.isFinite(x)) @intFromFloat(@trunc(x)) else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

const Parser = struct {
    a: Allocator,
    text: []const u8,
    i: usize = 0,
    lookup: Lookup,

    fn skip(p: *Parser) void {
        while (p.i < p.text.len and (p.text[p.i] == ' ' or p.text[p.i] == '\t')) p.i += 1;
    }

    /// Takes `op` (case not minded) if it comes next
    fn take(p: *Parser, op: []const u8) bool {
        p.skip();
        if (p.i + op.len > p.text.len or !std.ascii.eqlIgnoreCase(p.text[p.i..][0..op.len], op)) return false;
        p.i += op.len;
        return true;
    }

    /// The next of `ops`, taken
    fn takeOf(p: *Parser, ops: []const []const u8) ?usize {
        for (ops, 0..) |op, k| if (p.take(op)) return k;
        return null;
    }

    fn equivalence(p: *Parser) Error!Scalar {
        var l = try p.disjunction();
        while (p.takeOf(&.{ ".neqv.", ".eqv." })) |k| {
            const r = try p.disjunction();
            l = .{ .logical = (try logical(l) == try logical(r)) == (k == 1) };
        }
        return l;
    }

    fn disjunction(p: *Parser) Error!Scalar {
        var l = try p.conjunction();
        while (p.take(".or.")) {
            const r = try p.conjunction();
            l = .{ .logical = try logical(l) or try logical(r) };
        }
        return l;
    }

    fn conjunction(p: *Parser) Error!Scalar {
        var l = try p.negation();
        while (p.take(".and.")) {
            const r = try p.negation();
            l = .{ .logical = try logical(l) and try logical(r) };
        }
        return l;
    }

    fn negation(p: *Parser) Error!Scalar {
        if (p.take(".not.")) return .{ .logical = !try logical(try p.negation()) };
        return p.relation();
    }

    // the longer spellings first (`<=` before `<`, `/=` before a division)
    const relations = [_][]const u8{ "==", "/=", "<=", ">=", "<", ">", ".eq.", ".ne.", ".le.", ".ge.", ".lt.", ".gt." };
    const Rel = enum { eq, ne, le, ge, lt, gt };

    fn relation(p: *Parser) Error!Scalar {
        const l = try p.sum();
        const k = p.takeOf(&relations) orelse return l;
        const rel: Rel = @fromBackingInt(@intCast(k % 6));
        const r = try p.sum();
        const order: std.math.Order = switch (l) {
            .character => |ls| switch (r) {
                .character => |rs| compareText(ls, rs),
                else => return error.TypeMismatch,
            },
            else => blk: {
                if (r == .character or l == .logical or r == .logical) return error.TypeMismatch;
                if (l == .integer and r == .integer) break :blk std.math.order(l.integer, r.integer);
                break :blk std.math.order(try real(l), try real(r));
            },
        };
        return .{ .logical = switch (rel) {
            .eq => order == .eq,
            .ne => order != .eq,
            .le => order != .gt,
            .ge => order != .lt,
            .lt => order == .lt,
            .gt => order == .gt,
        } };
    }

    fn sum(p: *Parser) Error!Scalar {
        // a sign before the first term
        var l: Scalar = if (p.take("-")) try negate(try p.product()) else if (p.take("+")) try p.product() else try p.product();
        while (true) {
            p.skip();
            // not `//`, nor the relational `/=`
            const k = p.takeOf(&.{ "+", "-" }) orelse return l;
            l = try arithmetic(if (k == 0) .add else .sub, l, try p.product());
        }
    }

    fn product(p: *Parser) Error!Scalar {
        var l = try p.power();
        while (true) {
            p.skip();
            if (p.i < p.text.len and p.text[p.i] == '*' and !(p.i + 1 < p.text.len and p.text[p.i + 1] == '*')) {
                p.i += 1;
                l = try arithmetic(.mul, l, try p.power());
            } else if (p.i < p.text.len and p.text[p.i] == '/' and !(p.i + 1 < p.text.len and (p.text[p.i + 1] == '=' or p.text[p.i + 1] == '/'))) {
                p.i += 1;
                l = try arithmetic(.div, l, try p.power());
            } else return l;
        }
    }

    fn power(p: *Parser) Error!Scalar {
        const base = try p.primary();
        if (!p.take("**")) return base;
        // right to left; a sign allowed after `**`
        const e: Scalar = if (p.take("-")) try negate(try p.power()) else try p.power();
        return arithmetic(.pow, base, e);
    }

    fn primary(p: *Parser) Error!Scalar {
        p.skip();
        if (p.i >= p.text.len) return error.Syntax;
        const c = p.text[p.i];
        if (c == '(') {
            p.i += 1;
            const v = try p.equivalence();
            if (!p.take(")")) return error.Syntax;
            return v;
        }
        if (c == '\'' or c == '"') {
            const end = std.mem.findScalarPos(u8, p.text, p.i + 1, c) orelse return error.Syntax;
            const s = p.text[p.i + 1 .. end];
            p.i = end + 1;
            return .{ .character = s };
        }
        if (p.take(".true.")) return .{ .logical = true };
        if (p.take(".false.")) return .{ .logical = false };
        if (std.ascii.isDigit(c) or (c == '.' and p.i + 1 < p.text.len and std.ascii.isDigit(p.text[p.i + 1]))) return p.number();
        if (std.ascii.isAlphabetic(c)) return p.designator();
        return error.Syntax;
    }

    /// An integer or real literal, its kind (`_8`) ignored
    fn number(p: *Parser) Error!Scalar {
        const start = p.i;
        var is_real = false;
        while (p.i < p.text.len) : (p.i += 1) {
            const c = p.text[p.i];
            if (std.ascii.isDigit(c)) continue;
            // a decimal point, not an operator's (`1.eq.2`)
            if (c == '.' and !is_real and !isDotOperator(p.text[p.i..])) {
                is_real = true;
                continue;
            }
            if ((c == 'e' or c == 'E' or c == 'd' or c == 'D') and p.i + 1 < p.text.len and (std.ascii.isDigit(p.text[p.i + 1]) or p.text[p.i + 1] == '-' or p.text[p.i + 1] == '+')) {
                is_real = true;
                p.i += 1;
                continue;
            }
            break;
        }
        const digits = p.text[start..p.i];
        if (p.i < p.text.len and p.text[p.i] == '_') {
            p.i += 1;
            while (p.i < p.text.len and (std.ascii.isAlphanumeric(p.text[p.i]) or p.text[p.i] == '_')) p.i += 1;
        }
        if (!is_real) return .{ .integer = std.fmt.parseInt(i64, digits, 10) catch return error.Syntax };
        var buf: [64]u8 = undefined;
        if (digits.len > buf.len) return error.Syntax;
        const t = buf[0..digits.len];
        for (digits, t) |d, *o| o.* = if (d == 'd' or d == 'D') 'e' else d;
        return .{ .real = std.fmt.parseFloat(f64, t) catch return error.Syntax };
    }

    /// A name with its components, subscripts and module (`t%w(2)`,
    /// `grid::n`), read by the lookup
    fn designator(p: *Parser) Error!Scalar {
        const start = p.i;
        var depth: usize = 0;
        while (p.i < p.text.len) : (p.i += 1) {
            const c = p.text[p.i];
            if (depth > 0) {
                if (c == '(') depth += 1;
                if (c == ')') depth -= 1;
                continue;
            }
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '%') continue;
            if (c == ':' and p.i + 1 < p.text.len and p.text[p.i + 1] == ':') {
                p.i += 1;
                continue;
            }
            if (c == '(') {
                depth = 1;
                continue;
            }
            break;
        }
        if (depth > 0) return error.Syntax;
        const text = std.mem.trimEnd(u8, p.text[start..p.i], " ");
        return (p.lookup.read(p.lookup.ctx, p.a, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnknownName,
        }) orelse error.UnknownName;
    }
};

/// Whether `text` begins with a dotted operator or logical constant
fn isDotOperator(text: []const u8) bool {
    const ops = [_][]const u8{ ".eq.", ".ne.", ".lt.", ".le.", ".gt.", ".ge.", ".and.", ".or.", ".not.", ".eqv.", ".neqv.", ".true.", ".false." };
    for (ops) |op| if (text.len >= op.len and std.ascii.eqlIgnoreCase(text[0..op.len], op)) return true;
    return false;
}

fn logical(v: Scalar) Error!bool {
    return if (v == .logical) v.logical else error.TypeMismatch;
}

fn real(v: Scalar) Error!f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .real => |x| x,
        else => error.TypeMismatch,
    };
}

fn negate(v: Scalar) Error!Scalar {
    return switch (v) {
        .integer => |n| .{ .integer = -%n },
        .real => |x| .{ .real = -x },
        else => error.TypeMismatch,
    };
}

const Op = enum { add, sub, mul, div, pow };

fn arithmetic(op: Op, l: Scalar, r: Scalar) Error!Scalar {
    if (l == .integer and r == .integer) {
        const x = l.integer;
        const y = r.integer;
        return .{
            .integer = switch (op) {
                .add => x +% y,
                .sub => x -% y,
                .mul => x *% y,
                // Fortran's: toward zero
                .div => if (y == 0) return error.DivisionByZero else @divTrunc(x, y),
                .pow => if (y < 0) (if (x == 1) 1 else if (x == -1) (if (@mod(y, 2) == 0) 1 else -1) else if (x == 0) return error.DivisionByZero else 0) else std.math.powi(i64, x, y) catch 0,
            },
        };
    }
    const x = try real(l);
    const y = try real(r);
    return .{ .real = switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .pow => std.math.pow(f64, x, y),
    } };
}

/// Fortran's comparison of CHARACTER: the shorter padded with blanks
fn compareText(l: []const u8, r: []const u8) std.math.Order {
    const n = @max(l.len, r.len);
    for (0..n) |i| {
        const x: u8 = if (i < l.len) l[i] else ' ';
        const y: u8 = if (i < r.len) r[i] else ' ';
        if (x != y) return std.math.order(x, y);
    }
    return .eq;
}

const TestVars = struct {
    fn read(_: *anyopaque, _: Allocator, d: []const u8) anyerror!?Scalar {
        if (std.ascii.eqlIgnoreCase(d, "k")) return .{ .integer = 1 };
        if (std.mem.eql(u8, d, "p%x")) return .{ .real = 9.0 };
        if (std.mem.eql(u8, d, "a(2,1)")) return .{ .integer = -20 };
        if (std.mem.eql(u8, d, "done")) return .{ .logical = false };
        if (std.mem.eql(u8, d, "tag")) return .{ .character = "hello   " };
        if (std.mem.eql(u8, d, "grid::n")) return .{ .integer = 42 };
        return null;
    }
};

fn testTrue(text: []const u8) !bool {
    var ctx: u8 = 0;
    return isTrue(std.testing.allocator, text, .{ .ctx = &ctx, .read = TestVars.read });
}

test "conditions" {
    const t = std.testing;
    try t.expect(try testTrue("k == 1"));
    try t.expect(try testTrue("K .EQ. 1"));
    try t.expect(!try testTrue("k /= 1"));
    try t.expect(try testTrue("k.ne.0 .and. k < 2"));
    try t.expect(try testTrue("p%x > 8.5 .and. a(2,1) == -20"));
    try t.expect(try testTrue("a(2,1) + 2*10 == 0"));
    try t.expect(try testTrue(".not. done"));
    try t.expect(try testTrue("done .or. grid::n >= 42"));
    try t.expect(try testTrue("tag == 'hello'"));
    try t.expect(try testTrue("2**3**2 == 512"));
    try t.expect(try testTrue("-2**2 == -4"));
    try t.expect(try testTrue("7/2 == 3 .and. 7.0/2 == 3.5"));
    try t.expect(try testTrue("1.5d0 <= 1.5e0"));
    try t.expect(try testTrue("1.eq.1"));
    try t.expect(try testTrue("(k + 1) * 2 == 4"));
    try t.expect(try testTrue("done .eqv. .false."));
    try t.expect(try testTrue("k"));
    try t.expectError(error.UnknownName, testTrue("nope == 1"));
    try t.expectError(error.TypeMismatch, testTrue("done == 1"));
    try t.expectError(error.Syntax, testTrue("k == "));
    try t.expectError(error.Syntax, testTrue("k == 1)"));
    var ctx: u8 = 0;
    try t.expectEqual(@as(i64, 3), try integer(t.allocator, "k + 2", .{ .ctx = &ctx, .read = TestVars.read }));
}
