//! COMMON blocks in requests (#556): a block is named between slashes, in
//! a COMMON or SAVE statement (and OpenMP's THREADPRIVATE, BIND(C)), and
//! its name is no name of the scope (parser/groups.zig). The blocks of one
//! name are one entity of the program: each program unit that names it has
//! its object, and references go to all of them.

const std = @import("std");
const objects = @import("../objects.zig");
const Obj = objects.Obj;

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// The name of a COMMON block at byte `col` of statement line `line` (the
/// statement's first line `first`), or null when the word there is none:
/// one between slashes, in a statement that names blocks so
pub fn blockNameAt(first: []const u8, line: []const u8, col: usize) ?[]const u8 {
    var s = @min(col, line.len);
    while (s > 0 and isWordChar(line[s - 1])) s -= 1;
    var e = @min(col, line.len);
    while (e < line.len and isWordChar(line[e])) e += 1;
    if (e == s) return null;
    var b = s;
    while (b > 0 and line[b - 1] == ' ') b -= 1;
    var f = e;
    while (f < line.len and line[f] == ' ') f += 1;
    if (b == 0 or line[b - 1] != '/' or f >= line.len or line[f] != '/') return null;
    const stmt = std.mem.trimStart(u8, first, " \t");
    const names_blocks = std.ascii.startsWithIgnoreCase(stmt, "common") or std.ascii.startsWithIgnoreCase(stmt, "save") or
        std.ascii.findIgnoreCase(stmt, "threadprivate") != null or std.ascii.startsWithIgnoreCase(stmt, "bind");
    return if (names_blocks) line[s..e] else null;
}

/// The block's name without its slashes
pub fn bareName(o: *const Obj) []const u8 {
    return if (o.name.len >= 2) o.name[1 .. o.name.len - 1] else o.name;
}

pub fn isCommon(o: *const Obj) bool {
    return o.kind == .variable and o.varDataConst().group == .common;
}

/// The block named `name` that `scope` or a scope around it names
pub fn find(scope: ?*Obj, name: []const u8) ?*Obj {
    var cur = scope;
    var depth: usize = 0;
    while (cur) |s| : (cur = s.parent) {
        depth += 1;
        if (depth > 64) break;
        if (s.data != .scope) continue;
        for (s.scopeData().commons.items) |o| if (std.ascii.eqlIgnoreCase(bareName(o), name)) return o;
    }
    return null;
}

/// Whether `x` and `y` are blocks of one name, which are one entity
pub fn sameBlock(x: *const Obj, y: *const Obj) bool {
    return isCommon(x) and isCommon(y) and std.ascii.eqlIgnoreCase(x.name, y.name);
}

test blockNameAt {
    try std.testing.expectEqualStrings("blk", blockNameAt("  common /blk/ a", "  common /blk/ a", 11).?);
    try std.testing.expectEqualStrings("BLK", blockNameAt("      COMMON/BLK/A2", "      COMMON/BLK/A2", 13).?);
    try std.testing.expectEqualStrings("blk", blockNameAt("  save /blk/, x", "  save /blk/, x", 9).?);
    // a division
    try std.testing.expect(blockNameAt("  x = a/b/c", "  x = a/b/c", 8) == null);
    // a name of the list
    try std.testing.expect(blockNameAt("  common /blk/ a", "  common /blk/ a", 15) == null);
}
