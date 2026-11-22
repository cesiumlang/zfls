//! Part of the argument checks (argcheck.zig): the value of an integer
//! constant expression with intrinsic operators, `n + 1`, `2*(k - 1)`,
//! `-k`, and of MERGE with a constant mask, for the evaluator of kinds and
//! ranks (`Checker.kindValue`, #763).

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const Obj = @import("../objects.zig").Obj;

/// The value of `expr` (trimmed), its operands as `c.kindValue` tells
/// them; null for another expression
pub fn value(c: anytype, expr: []const u8, scope: ?*Obj, line_no: usize, depth: usize) Allocator.Error!?i64 {
    // a whole expression in parentheses
    if (expr[0] == '(' and typing.matching(expr, 0) == expr.len - 1) return c.kindValue(expr[1 .. expr.len - 1], scope, line_no, depth + 1);
    // the operator applied last: the last `+` or `-` outside parentheses
    // that is no sign, else the last `*` or `/`
    for ([_][]const u8{ "+-", "*/" }) |ops| {
        var nest: usize = 0;
        var i = expr.len;
        while (i > 0) {
            i -= 1;
            switch (expr[i]) {
                ')' => nest += 1,
                '(' => nest -|= 1,
                else => {},
            }
            if (nest != 0 or std.mem.findScalar(u8, ops, expr[i]) == null) continue;
            const left = std.mem.trim(u8, expr[0..i], " ");
            // a sign: `-k`, `2*-k`
            if (left.len == 0 or std.mem.findScalar(u8, "+-*/(", left[left.len - 1]) != null) {
                if (left.len == 0 and ops[0] == '+') {
                    const v = (try c.kindValue(expr[i + 1 ..], scope, line_no, depth + 1)) orelse return null;
                    return if (expr[i] == '-') -v else v;
                }
                continue;
            }
            // (no power)
            if (expr[i] == '*' and ((i + 1 < expr.len and expr[i + 1] == '*') or expr[i - 1] == '*')) return null;
            const x = (try c.kindValue(left, scope, line_no, depth + 1)) orelse return null;
            const y = (try c.kindValue(expr[i + 1 ..], scope, line_no, depth + 1)) orelse return null;
            return switch (expr[i]) {
                '+' => std.math.add(i64, x, y) catch null,
                '-' => std.math.sub(i64, x, y) catch null,
                '*' => std.math.mul(i64, x, y) catch null,
                else => if (y == 0) null else @divTrunc(x, y),
            };
        }
    }
    return null;
}

/// The value of `merge(tsource, fsource, mask)` of a constant mask,
/// `.true.` or `.false.`, given its arguments `args`; null for another
pub fn merge(c: anytype, args: []const u8, scope: ?*Obj, line_no: usize, depth: usize) Allocator.Error!?i64 {
    const parts = try helpers.splitArgs(c.a, args);
    if (parts.len != 3) return null;
    const mask = std.mem.trim(u8, parts[2], " ");
    const pick: usize = if (std.ascii.eqlIgnoreCase(mask, ".true.")) 0 else if (std.ascii.eqlIgnoreCase(mask, ".false.")) 1 else return null;
    return c.kindValue(parts[pick], scope, line_no, depth + 1);
}

const Mock = struct {
    a: Allocator,
    pub fn kindValue(m: *Mock, expr_in: []const u8, scope: ?*Obj, line_no: usize, depth: usize) Allocator.Error!?i64 {
        const expr = std.mem.trim(u8, expr_in, " ");
        if (expr.len == 0) return null;
        if (std.fmt.parseInt(i64, expr, 10)) |n| return n else |_| {}
        if (std.mem.eql(u8, expr, "n")) return 3;
        if (std.mem.startsWith(u8, expr, "merge(") and expr[expr.len - 1] == ')') return merge(m, expr["merge(".len .. expr.len - 1], scope, line_no, depth);
        return value(m, expr, scope, line_no, depth);
    }
};

test value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: Mock = .{ .a = arena.allocator() };
    const cases = [_]struct { []const u8, ?i64 }{
        .{ "n+1", 4 },        .{ "2*(n - 1)", 4 },            .{ "-n", -3 },
        .{ "10 - 2 - 3", 5 }, .{ "2*-n", -6 },                .{ "7/2", 3 },
        .{ "n**2", null },    .{ "merge(1, 2, .true.)", 1 },  .{ "merge(1, n+1, .false.)", 4 },
        .{ "1.0e-5", null },  .{ "merge(1, 2, flag)", null }, .{ "x + 1", null },
    };
    for (cases) |cs| try std.testing.expectEqual(cs[1], try m.kindValue(cs[0], null, 0, 0));
}
