//! The number of arguments and the keywords of a call of an intrinsic
//! function (#850, #877): `sin(1.0, 2.0)`, `mod(5)`, `abs(b=1)`. gfortran,
//! Flang and ifx all report them. The counts are those of the synopses of
//! the M_intrinsics pages (build/intrinsic_arity.zig, the widest over the
//! forms of a generic; pages that disagree with the compilers are left
//! out), MAX and MIN apart (two or more); only a name that nothing in the
//! workspace defines. The tests of the counts are in
//! `_test/intrinsic_arity.zig`.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const intrinsic_docs = @import("intrinsic_docs");

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;

const Arity = intrinsic_docs.Arity;

/// The pages of MAX and MIN list three arguments as required
const variadic = [_]Arity{
    .{ .name = "max", .min = 2, .max = null, .keywords = &.{} },
    .{ .name = "min", .min = 2, .max = null, .keywords = &.{} },
};

/// The counts of intrinsic `name`, null when unknown
pub fn arityOf(name: []const u8) ?Arity {
    for (variadic) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return v;
    for (intrinsic_docs.arities) |ar| if (std.ascii.eqlIgnoreCase(ar.name, name)) return ar;
    return null;
}

/// Reports the call `w(...)` (the parentheses at `open` and `close` of the
/// joined statement `text`, at offset `s`) of an intrinsic with the wrong
/// number of arguments; the caller found no entity of that name
pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, w: helpers.Word, open: usize, close: usize) !void {
    const arity = arityOf(w.str) orelse return;
    var n: usize = 0;
    var rest = text[open + 1 .. close];
    var at = open + 1;
    if (std.mem.trim(u8, rest, " ").len > 0) {
        n = 1;
        while (true) {
            const comma = typing.topLevel(rest, ',');
            const arg = rest[0 .. comma orelse rest.len];
            if (arity.keywords.len > 0) if (typing.keywordOf(arg)) |kw| if (!known(arity, kw)) {
                const start = at + (std.mem.find(u8, arg, kw) orelse 0);
                try c.report(j, s + start, s + start + kw.len, .intrinsic_arguments, "intrinsic {s} has no argument named {s}", .{ w.str, kw });
            };
            const i = comma orelse break;
            at += i + 1;
            rest = rest[i + 1 ..];
            n += 1;
        }
    }
    if (n >= arity.min and (arity.max == null or n <= arity.max.?)) return;
    const what: []const u8 = if (n < arity.min) "too few" else "too many";
    try c.report(j, s + w.start, s + w.end, .intrinsic_arguments, "{s} arguments in the call of intrinsic {s}", .{ what, w.str });
}

fn known(arity: Arity, kw: []const u8) bool {
    for (arity.keywords) |k| if (std.ascii.eqlIgnoreCase(k, kw)) return true;
    return false;
}

test {
    _ = @import("_test/intrinsic_arity.zig");
}
