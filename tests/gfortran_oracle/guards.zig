//! The associate names of SELECT TYPE's type guards for the gfortran oracle
//! (gfortran_oracle.zig, #701). gfortran's symbol of an associate name has
//! the selector's declared type, a CLASS, whose rank the oracle does not
//! compare; in each TYPE IS and CLASS IS block the name is a temporary of
//! the guard's type and the selector's rank: `__tmp_type_child_t_it`,
//! `__tmp_class_child_t_it`, `__tmp_REAL_8_x`, `__tmp_CHARACTER_0_1_x`.
//! Each of zfls's declarations of a name must agree with gfortran's symbol
//! of it or with one of its temporaries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const oz = @import("../oracle_zfls.zig");

/// A temporary of a type guard: in namespace `ns`, of name `name`
pub const Temp = struct { ns: []const u8, name: []const u8, v: types.Var };

pub fn isTemp(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__tmp_");
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
        const suffix = try a.print("_{s}", .{key[sep + 2 ..]});
        var mine: std.ArrayList(types.Var) = .empty;
        // a temporary of `it` ends in `_it` (and so might one of `my_it`)
        for (temps) |t| if (std.mem.eql(u8, t.ns, key[0..sep]) and std.mem.endsWith(u8, t.name, suffix)) try mine.append(a, t.v);
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
        const suffix = try a.print("_{s}", .{k.*[sep + 2 ..]});
        for (temps) |t| if (std.mem.eql(u8, t.ns, k.*[0..sep]) and std.mem.endsWith(u8, t.name, suffix)) {
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
