//! The number of subscripts of an array reference (#850): `a(1, 2)` for a
//! rank-1 array. gfortran, Flang and ifx all report it. Only variables
//! whose rank the declaration gives are checked, with the subscripts of
//! the first parentheses after the name.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const dimensions = @import("../objects/dimensions.zig");
const objects = @import("../objects.zig");

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;
const Obj = objects.Obj;

/// The number of subscripts between the parentheses at `open` and `close`
fn count(text: []const u8, open: usize, close: usize) usize {
    var rest = text[open + 1 .. close];
    if (std.mem.trim(u8, rest, " ").len == 0) return 0;
    var n: usize = 1;
    while (typing.topLevel(rest, ',')) |i| : (rest = rest[i + 1 ..]) n += 1;
    return n;
}

/// Reports reference `w` of variable `v`, the parentheses at `open` and
/// `close` of the joined statement `text` (at offset `s`), that has other
/// subscripts than the rank of `v`
pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, w: helpers.Word, open: usize, close: usize, v: *Obj) !void {
    // an associate name's rank is its selector's, and a rank block's is not
    // always known
    if (dimensions.isAssociateName(v) or !dimensions.known(v)) return;
    const rank = argcheck.rankOf(dimensions.of(v)) orelse return;
    const n = count(text, open, close);
    if (n == 0 or n == rank) return;
    try c.report(j, s + w.start, s + w.end, .subscript_count, "Reference to rank-{d} object {s} has {d} subscripts", .{ rank, v.name, n });
}
