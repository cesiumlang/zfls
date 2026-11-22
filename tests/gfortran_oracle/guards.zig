//! The associate names of SELECT TYPE's type guards for the gfortran oracle
//! (gfortran_oracle.zig, #701). gfortran's symbol of an associate name has
//! the selector's declared type, a CLASS, whose rank the oracle does not
//! compare; in each TYPE IS and CLASS IS block the name is a temporary of
//! the guard's type and the selector's rank: `__tmp_type_child_t_it`,
//! `__tmp_class_child_t_it`, `__tmp_REAL_8_x`, `__tmp_CHARACTER_0_1_x`
//! (gfortran 16; before, without the name: `__tmp_type_child_t`). In each
//! RANK block of SELECT RANK it is a temporary of the block's rank and the
//! selector's type and attributes, without the name: `__tmp_REAL_4_rank_2`,
//! `__tmp_REAL_4_rank_m1` (RANK (*)), #706.
//! Each of zfls's declarations of a name must agree with gfortran's symbol
//! of it or with one of its temporaries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const oz = @import("../oracle_zfls.zig");

/// A temporary of a type guard: in namespace `ns`, of name `name`, of
/// associate name `assoc` ("" when the dump did not tell)
pub const Temp = struct { ns: []const u8, name: []const u8, v: types.Var, assoc: []const u8 = "" };

pub fn isTemp(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__tmp_");
}

/// Whether `t` is a temporary of name `assoc` in namespace `ns`: by the
/// associate name listed after it, or by its own name, gfortran 16's
fn isOf(t: Temp, ns: []const u8, assoc: []const u8) bool {
    if (!std.mem.eql(u8, t.ns, ns)) return false;
    if (t.assoc.len > 0) return std.mem.eql(u8, t.assoc, assoc);
    // a temporary of `it` ends in `_it` (and so might one of `my_it`)
    return std.mem.endsWith(u8, t.name, assoc) and t.name.len > assoc.len and t.name[t.name.len - assoc.len - 1] == '_';
}

/// The temporaries of the namespace whose symbols the dump lists, until
/// the associate name they are of: the listing is in alphabetical order,
/// the temporaries first, and ends at a line no deeper than its symbols
pub const Unnamed = struct {
    indent: usize = 0,
    temps: std.ArrayList(usize) = .empty,

    /// Symbol `name` at `indent`, with its detail lines `block`: temporary
    /// `temp`, associate name `assoc`, or another one (both null)
    pub fn symbol(u: *Unnamed, a: Allocator, all: *std.ArrayList(Temp), indent: usize, block: []const []const u8, temp: ?Temp, assoc: ?[]const u8) !void {
        if (indent != u.indent) u.temps.clearRetainingCapacity();
        u.indent = indent;
        if (temp) |t| {
            try u.temps.append(a, all.items.len);
            try all.append(a, t);
        } else if (assoc) |n| {
            for (u.temps.items) |k| all.items[k].assoc = n;
            u.temps.clearRetainingCapacity();
        }
        for (block) |b| {
            const deeper = std.mem.findNone(u8, b, " \t\r") orelse continue;
            if (deeper <= indent) {
                // `SELECT RANK s:p(FULL)`: of `select rank (p)`, unnamed
                if (selectRankName(b[deeper..])) |n| for (u.temps.items) |k| {
                    all.items[k].assoc = n;
                };
                u.temps.clearRetainingCapacity();
                break;
            }
        }
    }
};

/// The selector of `SELECT RANK block@1:r(FULL)`, `r`, or null
fn selectRankName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "SELECT RANK ")) return null;
    const open = std.mem.findScalar(u8, line, '(') orelse return null;
    const colon = std.mem.findScalarLast(u8, line[0..open], ':') orelse return null;
    return line[colon + 1 .. open];
}

/// How zfls's declaration `decl` differs from temporary `v`: in type or
/// rank. gfortran makes its temporaries POINTER and TARGET whatever the
/// selector, so those are not compared.
fn tempMismatch(a: Allocator, v: types.Var, decl: []const u8) !?[]const u8 {
    const attrs = try std.ascii.allocUpperString(a, decl[0 .. std.mem.find(u8, decl, " :: ") orelse decl.len]);
    // of CLASS IS: a CLASS, whose rank a temporary's Array spec has
    if (std.mem.startsWith(u8, v.type, "(CLASS")) {
        if (!std.mem.startsWith(u8, attrs, "CLASS(")) return try a.print("type {s}, gfortran {s}", .{ oz.typeSpec(decl), v.type });
        if (oz.rank(attrs) != v.rank) return try a.print("rank {d}, gfortran {d}", .{ oz.rank(attrs), v.rank });
        return null;
    }
    var t = v;
    t.pointer = std.mem.find(u8, attrs, "POINTER") != null;
    t.target = std.mem.find(u8, attrs, "TARGET") != null;
    return types.mismatch(a, t, decl);
}

/// The differences between zfls's declarations `decls` of names (by path,
/// as `gfortran_oracle.zig` makes them) that gfortran has temporaries of,
/// and gfortran's symbols `vars` and temporaries `temps`
pub fn check(a: Allocator, diffs: *std.ArrayList([]const u8), vars: *const std.StringHashMapUnmanaged(types.Var), temps: []const Temp, decls: *const std.StringHashMapUnmanaged(std.ArrayList([]const u8))) !void {
    var it = decls.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const sep = std.mem.findLast(u8, key, "::") orelse continue;
        var mine: std.ArrayList(types.Var) = .empty;
        for (temps) |t| if (isOf(t, key[0..sep], key[sep + 2 ..])) try mine.append(a, t.v);
        if (mine.items.len == 0) continue;
        for (e.value_ptr.items) |decl| {
            var why: []const u8 = "";
            var ok = false;
            // gfortran's own symbol: the selector's CLASS, of CLASS DEFAULT
            // (or a dummy argument), whose rank its Array spec has
            if (vars.get(key)) |v| {
                const class = std.mem.startsWith(u8, v.type, "(CLASS");
                const w = if (class) try tempMismatch(a, v, decl) else try types.mismatch(a, v, decl);
                if (w) |reason| why = reason else ok = true;
            }
            for (mine.items) |t| {
                if (ok) break;
                if (try tempMismatch(a, t, decl)) |w| why = w else ok = true;
            }
            if (!ok) try diffs.append(a, try a.print("differs: {s}: {s}: {s}", .{ key, decl, why }));
        }
    }
}

/// The paths of the names that gfortran has temporaries of
pub fn names(a: Allocator, temps: []const Temp, decls: *const std.StringHashMapUnmanaged(std.ArrayList([]const u8))) !std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    var it = decls.keyIterator();
    while (it.next()) |k| {
        const sep = std.mem.findLast(u8, k.*, "::") orelse continue;
        for (temps) |t| if (isOf(t, k.*[0..sep], k.*[sep + 2 ..])) {
            try out.put(a, k.*, {});
            break;
        };
    }
    return out;
}

test check {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars: std.StringHashMapUnmanaged(types.Var) = .empty;
    try vars.put(a, "m::s::it", .{ .type = "(CLASS __class_m_Base_t_1_0p)", .rank = 1 });
    const temps = [_]Temp{
        .{ .ns = "m::s", .name = "__tmp_type_base_t_it", .v = .{ .type = "(DERIVED base_t)", .rank = 1, .pointer = true, .target = true } },
        .{ .ns = "m::s", .name = "__tmp_REAL_8_it", .v = .{ .type = "(REAL 8)", .rank = 1, .pointer = true, .target = true } },
        .{ .ns = "m::s", .name = "__tmp_class_child_t_it", .v = .{ .type = "(CLASS __class_m_Child_t_1_0p)", .rank = 1, .target = true } },
    };
    var decls: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(a, &.{ "TYPE(base_t), DIMENSION(:) :: it", "REAL(8), DIMENSION(:) :: it", "CLASS(child_t), DIMENSION(:) :: it", "CLASS(base_t), DIMENSION(:) :: it" });
    try decls.put(a, "m::s::it", list);
    var diffs: std.ArrayList([]const u8) = .empty;
    try check(a, &diffs, &vars, &temps, &decls);
    try std.testing.expectEqual(0, diffs.items.len);
    // a TYPE IS name without the selector's rank
    try decls.getPtr("m::s::it").?.append(a, "TYPE(base_t) :: it");
    try check(a, &diffs, &vars, &temps, &decls);
    try std.testing.expectEqual(1, diffs.items.len);
}

test "the temporaries of an unnamed SELECT RANK take its selector's name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: std.ArrayList(Temp) = .empty;
    var u: Unnamed = .{};
    // gfortran 16.1, `select rank (p)`
    try u.symbol(a, &all, 6, &.{ "        type spec : (REAL 4)", "        Array spec:(1 [0] AS_DEFERRED () () )" }, .{ .ns = "m::s", .name = "__tmp_REAL_4_rank_1", .v = .{ .rank = 1 } }, null);
    try u.symbol(a, &all, 6, &.{ "        type spec : (UNKNOWN 0)", "        attributes: (LABEL )", "      ", "      SELECT RANK s:p(FULL)" }, null, null);
    try std.testing.expectEqualStrings("p", all.items[0].assoc);
    try std.testing.expectEqualStrings("r", selectRankName("SELECT RANK block@1:r(FULL)").?);
}
