//! The names of ASSOCIATE constructs, and the coarrays a CHANGE TEAM
//! associates, for the gfortran oracle (gfortran_oracle.zig, #754).
//! gfortran lists each construct's names after its `ASSOCIATE  x = ...` or
//! `CHANGE TEAM t x = ...` line, constructs in the order of the source;
//! zfls's `Associate Constructs` section gives each construct's line.
//! Several constructs of a procedure can have a name of the same name: the
//! n-th construct with names of a procedure in zfls is compared with the
//! n-th in gfortran, each name with its own construct's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

/// gfortran's name `name` of the `n`-th (1-based) construct with names of
/// namespace `ns`
pub const Name = struct { ns: []const u8, n: usize, name: []const u8, v: types.Var };

/// Reads the ASSOCIATE and CHANGE TEAM constructs of gfortran's dump
pub const Reader = struct {
    /// the constructs with names of each namespace so far
    counts: std.StringHashMapUnmanaged(usize) = .empty,
    /// the construct whose names follow its line: its number once it has
    /// one
    open: ?struct { indent: usize, ns: []const u8, n: ?usize = null } = null,
    names: std.ArrayList(Name) = .empty,

    /// A line of namespace `ns` that is not a symbol's: an ASSOCIATE's or
    /// CHANGE TEAM's opens its construct, any other closes it
    pub fn line(r: *Reader, ns: []const u8, text: []const u8) void {
        r.open = null;
        const indent = std.mem.findNone(u8, text, " \t") orelse return;
        const t = text[indent..];
        if (std.mem.startsWith(u8, t, "ASSOCIATE ")) {
            // a block of SELECT TYPE (`ASSOCIATE   = ...`) has no name
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, t["ASSOCIATE".len..], " "), "=")) return;
        } else if (!std.mem.startsWith(u8, t, "CHANGE TEAM ")) return;
        r.open = .{ .indent = indent, .ns = ns };
    }

    /// Symbol `name` at `indent`, with its detail lines `block`, an
    /// associate name (`assoc`) or not: whether it is a name of the open
    /// construct
    pub fn symbol(r: *Reader, a: Allocator, indent: usize, name: []const u8, block: []const []const u8, assoc: bool) !bool {
        const o = if (r.open) |*o| o else return false;
        if (indent <= o.indent or !assoc) return false;
        const n = o.n orelse blk: {
            const gop = try r.counts.getOrPut(a, o.ns);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            o.n = gop.value_ptr.*;
            break :blk gop.value_ptr.*;
        };
        try r.names.append(a, .{ .ns = o.ns, .n = n, .name = name, .v = types.varOf(block) });
        return true;
    }
};

/// zfls's name of an ASSOCIATE construct: of path `key` (as
/// gfortran_oracle.zig makes them), `ns` without the name, of the
/// construct `construct` on line `line`
pub const Zname = struct { key: []const u8, ns: []const u8, construct: []const u8, line: usize, decl: []const u8 };

/// The number (1-based) of the construct of `z` among zfls's constructs
/// with names of its namespace, by their lines
fn ordinal(znames: []const Zname, z: Zname) usize {
    var n: usize = 1;
    for (znames, 0..) |o, i| {
        if (!std.mem.eql(u8, o.ns, z.ns) or std.mem.eql(u8, o.construct, z.construct)) continue;
        // each construct once
        const again = for (znames[0..i]) |q| {
            if (std.mem.eql(u8, q.construct, o.construct)) break true;
        } else false;
        if (!again and (o.line < z.line or (o.line == z.line and std.mem.order(u8, o.construct, z.construct) == .lt))) n += 1;
    }
    return n;
}

/// The differences between zfls's names of ASSOCIATE constructs `znames`
/// and gfortran's `names`, each with its own construct's
pub fn check(a: Allocator, diffs: *std.ArrayList([]const u8), names: []const Name, znames: []const Zname) !void {
    for (znames) |z| {
        const n = ordinal(znames, z);
        const short = z.key[if (std.mem.findLast(u8, z.key, "::")) |i| i + 2 else 0..];
        const g = for (names) |g| {
            if (g.n == n and std.mem.eql(u8, g.ns, z.ns) and std.ascii.eqlIgnoreCase(g.name, short)) break g;
        } else {
            try diffs.append(a, try a.print("missing in gfortran: {s} of the ASSOCIATE on line {d} (construct {d})", .{ z.key, z.line, n }));
            continue;
        };
        if (try types.mismatch(a, g.v, z.decl)) |why| try diffs.append(a, try a.print("differs: {s} (ASSOCIATE on line {d}): {s}", .{ z.key, z.line, why }));
    }
}
