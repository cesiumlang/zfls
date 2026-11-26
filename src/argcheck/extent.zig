//! Part of the argument checks (argcheck.zig): the number of elements of a
//! rank-1 array that an actual argument gives, against the explicit-shape
//! dummy argument it goes to (#848). Only bounds written as integer
//! literals are told.

const std = @import("std");
const objects = @import("../objects.zig");
const typing = @import("typing.zig");
const dimensions = @import("../objects/dimensions.zig");

const Obj = objects.Obj;

fn literal(text: []const u8) ?i64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

/// The bounds of a rank-1 DIMENSION of integer literals (`3`, `0:9`)
const Bounds = struct { lo: i64, hi: i64 };

fn boundsOf(dims: ?[]const u8) ?Bounds {
    const d = std.mem.trim(u8, dims orelse return null, " ");
    if (typing.topLevel(d, ',') != null) return null;
    if (typing.topLevel(d, ':')) |colon| {
        return .{ .lo = literal(d[0..colon]) orelse return null, .hi = literal(d[colon + 1 ..]) orelse return null };
    }
    return .{ .lo = 1, .hi = literal(d) orelse return null };
}

/// The number of elements of the explicit-shape rank-1 dummy argument
pub fn wanted(dummy: *const Obj) ?i64 {
    const dims = dummy.keyword_info.dimension;
    if (dimensions.shapeOf(dims) != .sequence) return null;
    const b = boundsOf(dims) orelse return null;
    return @max(b.hi - b.lo + 1, 0);
}

/// What `actual` gives of array variable `v`
pub const Given = struct {
    /// the elements of an array, a whole one or a section
    array: ?i64 = null,
    /// the elements from an element on to the end of the array
    from_element: ?i64 = null,
};

/// The elements `actual` gives: `v` whole, `v(lo:hi)` (no stride), or from
/// the element `v(i)` on; of literals only
pub fn given(actual: []const u8, v: *const Obj) Given {
    const own = boundsOf(dimensions.of(v)) orelse return .{};
    const e = std.mem.trim(u8, actual, " ");
    const open = std.mem.findScalar(u8, e, '(') orelse {
        if (!isName(e)) return .{};
        return .{ .array = @max(own.hi - own.lo + 1, 0) };
    };
    if (!isName(std.mem.trim(u8, e[0..open], " ")) or e[e.len - 1] != ')' or typing.matching(e, open) != e.len - 1) return .{};
    const sub = e[open + 1 .. e.len - 1];
    if (typing.topLevel(sub, ',') != null) return .{};
    if (typing.topLevel(sub, ':')) |colon| {
        if (std.mem.find(u8, sub[colon + 1 ..], ":") != null) return .{};
        const lo = literal(sub[0..colon]) orelse return .{};
        const hi = literal(sub[colon + 1 ..]) orelse return .{};
        if (lo < own.lo or hi > own.hi) return .{};
        return .{ .array = @max(hi - lo + 1, 0) };
    }
    const i = literal(sub) orelse return .{};
    if (i < own.lo or i > own.hi) return .{};
    return .{ .from_element = own.hi - i + 1 };
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

test "extents of literal bounds" {
    try std.testing.expectEqual(Bounds{ .lo = 1, .hi = 3 }, boundsOf("3").?);
    try std.testing.expectEqual(Bounds{ .lo = 0, .hi = 2 }, boundsOf("0:2").?);
    try std.testing.expect(boundsOf("n") == null);
    try std.testing.expect(boundsOf("2,3") == null);
}
