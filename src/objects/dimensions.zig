//! The DIMENSION of a variable as hover shows it and argument checking
//! takes it: of the associate name of a TYPE IS, CLASS IS or RANK block,
//! or of an array section, the one its rank or its selector gives it;
//! of another associate name, that of what it is linked to (#701, #706,
//! #707, #714).

const std = @import("std");
const objects = @import("../objects.zig");
const C = @import("../constants.zig");
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

/// Whether the rank of variable `v` can be told: not that of the name of
/// a RANK block whose rank is no literal (`rank (n)`)
pub fn known(v: *const Obj) bool {
    if (!v.isRankName() or v.varDataConst().slice_rank >= 0) return true;
    return (v.parent orelse return true).selectDataConst().case_rank == null;
}

test ofRank {
    try std.testing.expectEqual(null, ofRank(0, false));
    try std.testing.expectEqualStrings(":", ofRank(1, false).?);
    try std.testing.expectEqualStrings(":,:,:", ofRank(3, false).?);
    try std.testing.expectEqualStrings("*", ofRank(1, true).?);
}
