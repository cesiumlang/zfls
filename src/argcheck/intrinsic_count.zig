//! The number of arguments of a call of an intrinsic function (#850):
//! `sin(1.0, 2.0)`, `mod(5)`. gfortran, Flang and ifx all report them. Only
//! a few intrinsics with fixed counts are told (the elemental functions of
//! one argument, MOD, MODULO, SIGN, ATAN2 and DIM of two, MAX and MIN of at
//! least two), and only a name that nothing in the workspace defines.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;

const Arity = struct { name: []const u8, min: usize, max: usize };

const arities = [_]Arity{
    .{ .name = "sin", .min = 1, .max = 1 },
    .{ .name = "cos", .min = 1, .max = 1 },
    .{ .name = "tan", .min = 1, .max = 1 },
    .{ .name = "asin", .min = 1, .max = 1 },
    .{ .name = "acos", .min = 1, .max = 1 },
    .{ .name = "sinh", .min = 1, .max = 1 },
    .{ .name = "cosh", .min = 1, .max = 1 },
    .{ .name = "tanh", .min = 1, .max = 1 },
    .{ .name = "asinh", .min = 1, .max = 1 },
    .{ .name = "acosh", .min = 1, .max = 1 },
    .{ .name = "atanh", .min = 1, .max = 1 },
    .{ .name = "sqrt", .min = 1, .max = 1 },
    .{ .name = "exp", .min = 1, .max = 1 },
    .{ .name = "log", .min = 1, .max = 1 },
    .{ .name = "log10", .min = 1, .max = 1 },
    .{ .name = "abs", .min = 1, .max = 1 },
    .{ .name = "mod", .min = 2, .max = 2 },
    .{ .name = "modulo", .min = 2, .max = 2 },
    .{ .name = "sign", .min = 2, .max = 2 },
    .{ .name = "atan2", .min = 2, .max = 2 },
    .{ .name = "dim", .min = 2, .max = 2 },
    .{ .name = "max", .min = 2, .max = std.math.maxInt(usize) },
    .{ .name = "min", .min = 2, .max = std.math.maxInt(usize) },
};

/// Reports the call `w(...)` (the parentheses at `open` and `close` of the
/// joined statement `text`, at offset `s`) of an intrinsic with the wrong
/// number of arguments; the caller found no entity of that name
pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, w: helpers.Word, open: usize, close: usize) !void {
    const arity = for (arities) |a| {
        if (std.ascii.eqlIgnoreCase(a.name, w.str)) break a;
    } else return;
    var n: usize = 0;
    var rest = text[open + 1 .. close];
    if (std.mem.trim(u8, rest, " ").len > 0) {
        n = 1;
        while (typing.topLevel(rest, ',')) |i| : (rest = rest[i + 1 ..]) n += 1;
    }
    if (n >= arity.min and n <= arity.max) return;
    const what: []const u8 = if (n < arity.min) "too few" else "too many";
    try c.report(j, s + w.start, s + w.end, .intrinsic_arguments, "{s} arguments in the call of intrinsic {s}", .{ what, w.str });
}
