//! The DIMENSION of a variable as hover shows it and argument checking
//! takes it: of the associate name of a TYPE IS, CLASS IS or RANK block,
//! or of an array section, the one its rank or its selector gives it;
//! of another associate name, that of what it is linked to (#701, #706,
//! #707, #714); and what a dummy argument's DIMENSION takes (#719).

const std = @import("std");
const objects = @import("../objects.zig");
const C = @import("../constants.zig");
const typing = @import("../argcheck/typing.zig");
const Obj = objects.Obj;
const KW = C.KW;

const colons = ":,:,:,:,:,:,:,:,:,:,:,:,:,:,:";

/// The DIMENSION of an array of rank `rank` (at most 15) that has no
/// explicit shape, `:,:`; `*` when assumed size; null for a scalar
pub fn ofRank(rank: usize, assumed_size: bool) ?[]const u8 {
    if (rank == 0) return null;
    if (assumed_size) return "*";
    return colons[0 .. 2 * @min(rank, 15) - 1];
}

/// The variable that gives `v` its rank: `v` when it has a rank of its
/// own (a section's, a RANK block's) or none to take; else, of a TYPE IS
/// or CLASS IS name its selector's, of another associate name what it is
/// linked to
fn rankSource(v: *const Obj) *const Obj {
    var o = v;
    // (a chain of links is free of loops; selectors are bound outside)
    for (0..64) |_| {
        const d = o.varDataOptConst() orelse return o;
        if (d.slice_rank >= 0) return o;
        const next = d.selector_obj orelse d.link_obj orelse return o;
        if (next.kind != .variable) return o;
        o = next;
    }
    return o;
}

/// The DIMENSION of variable `v`: of an associate name of a section or
/// of a block of SELECT TYPE or RANK, the one its rank gives it; of a TYPE
/// IS or CLASS IS name otherwise its selector's, of another associate name
/// that of what it is linked to; else its own
pub fn of(v: *const Obj) ?[]const u8 {
    const o = rankSource(v);
    const d = o.varDataOptConst() orelse return o.keyword_info.dimension;
    if (d.slice_rank >= 0) return ofRank(@intCast(d.slice_rank), d.assumed_size);
    return o.keyword_info.dimension;
}

/// Whether variable `v` is an array, with a DIMENSION or the attribute
pub fn isArray(v: *const Obj) bool {
    const o = rankSource(v);
    return of(v) != null or (o.hasKeyword(KW.dimension) and o.varDataConst().slice_rank < 0);
}

/// Whether variable `v` is the associate name of an ASSOCIATE, SELECT
/// TYPE or SELECT RANK construct
pub fn isAssociateName(v: *const Obj) bool {
    if (v.kind != .variable) return false;
    const p = v.parent orelse return false;
    return p.kind == .associate or p.getType(false) == C.TypeId.select;
}

/// Whether the rank of variable `v` can be told: not that of the name of
/// a RANK block whose rank is no constant (`rank (n)`), nor of an
/// associate name bound to an expression of a rank not known (`y =>
/// f(x)`, #719)
pub fn known(v: *const Obj) bool {
    // a RANK clause not evaluated (#729)
    if (v.varDataConst().rank_clause != null and std.mem.eql(u8, v.keyword_info.dimension orelse "", "..")) return false;
    if (!isAssociateName(v) or v.varDataConst().slice_rank >= 0) return true;
    if (v.isRankName() and (v.parent orelse return true).selectDataConst().case_rank != null) return false;
    return rankSource(v) != v;
}

/// What a dummy argument's DIMENSION takes (#719)
pub const Shape = enum {
    /// assumed or deferred shape (`:`, `0:`): arrays of its rank alone
    assumed,
    /// explicit shape or assumed size (`3`, `1:n`, `2,*`): an element
    /// sequence, an array of any rank or an element
    sequence,
    /// assumed rank (`..`): anything
    any,
    unknown,
};

/// What DIMENSION `dims` takes as an actual argument
pub fn shapeOf(dims: ?[]const u8) Shape {
    const d = std.mem.trim(u8, dims orelse return .unknown, " ");
    if (d.len == 0) return .unknown;
    if (std.mem.eql(u8, d, "..")) return .any;
    var deferred: usize = 0;
    var n: usize = 0;
    var rest = d;
    while (true) {
        const end = typing.topLevel(rest, ',') orelse rest.len;
        const dim = std.mem.trim(u8, rest[0..end], " ");
        if (dim.len == 0) return .unknown;
        n += 1;
        if (typing.topLevel(dim, ':')) |colon| {
            if (std.mem.trim(u8, dim[colon + 1 ..], " ").len == 0) deferred += 1;
        }
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
    }
    if (deferred == n) return .assumed;
    return if (deferred == 0) .sequence else .unknown;
}

test shapeOf {
    try std.testing.expectEqual(Shape.assumed, shapeOf(":"));
    try std.testing.expectEqual(Shape.assumed, shapeOf("0:, :"));
    try std.testing.expectEqual(Shape.sequence, shapeOf("3"));
    try std.testing.expectEqual(Shape.sequence, shapeOf("1:n, size(x(1:2))"));
    try std.testing.expectEqual(Shape.sequence, shapeOf("2, *"));
    try std.testing.expectEqual(Shape.sequence, shapeOf("0:*"));
    try std.testing.expectEqual(Shape.any, shapeOf(".."));
    try std.testing.expectEqual(Shape.unknown, shapeOf(null));
    try std.testing.expectEqual(Shape.unknown, shapeOf(":, 3"));
}

test ofRank {
    try std.testing.expectEqual(null, ofRank(0, false));
    try std.testing.expectEqualStrings(":", ofRank(1, false).?);
    try std.testing.expectEqualStrings(":,:,:", ofRank(3, false).?);
    try std.testing.expectEqualStrings("*", ofRank(1, true).?);
}
