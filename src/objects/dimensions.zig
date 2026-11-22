//! The DIMENSION of a variable as hover shows it and argument checking
//! takes it: of the associate name of a TYPE IS, CLASS IS or RANK block,
//! or of an array section, the one its rank or its selector gives it
//! (#701, #706, #707).

const std = @import("std");
const objects = @import("../objects.zig");
const Obj = objects.Obj;

const colons = ":,:,:,:,:,:,:,:,:,:,:,:,:,:,:";

/// The DIMENSION of an array of rank `rank` (at most 15) that has no
/// explicit shape, `:,:`; `*` when assumed size; null for a scalar
pub fn ofRank(rank: usize, assumed_size: bool) ?[]const u8 {
    if (rank == 0) return null;
    if (assumed_size) return "*";
    return colons[0 .. 2 * @min(rank, 15) - 1];
}

/// The DIMENSION of variable `v`: of an associate name of a section or
/// of a block of SELECT TYPE or RANK, the one its rank gives it; of a TYPE
/// IS or CLASS IS name otherwise its selector's; else its own
pub fn of(v: *const Obj) ?[]const u8 {
    const d = v.varDataOptConst() orelse return v.keyword_info.dimension;
    if (d.slice_rank >= 0) return ofRank(@intCast(d.slice_rank), d.assumed_size);
    if (d.selector_obj) |s| return s.keyword_info.dimension;
    return v.keyword_info.dimension;
}

test ofRank {
    try std.testing.expectEqual(null, ofRank(0, false));
    try std.testing.expectEqualStrings(":", ofRank(1, false).?);
    try std.testing.expectEqualStrings(":,:,:", ofRank(3, false).?);
    try std.testing.expectEqualStrings("*", ofRank(1, true).?);
}
