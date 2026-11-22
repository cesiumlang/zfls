//! The associate names of SELECT TYPE's type guards and SELECT RANK's
//! cases for the gfortran oracle (gfortran_oracle.zig, #701, #706, #715).
//! gfortran lists the temporaries of a SELECT's blocks together, in the
//! namespace of the SELECT (its group here): in each TYPE IS and CLASS IS
//! block the name is a temporary of the guard's type and the selector's
//! rank: `__tmp_type_child_t_it`, `__tmp_class_child_t_it`,
//! `__tmp_REAL_8_x`, `__tmp_CHARACTER_0_1_x` (gfortran 16; before, without
//! the name: `__tmp_type_child_t`). In each RANK block it is a temporary of
//! the block's rank and the selector's type and attributes, without the
//! name: `__tmp_REAL_4_rank_2`, `__tmp_REAL_4_rank_m1` (RANK (*)). In
//! CLASS DEFAULT and RANK DEFAULT it is gfortran's symbol of the name.
//! Each block's name in zfls is compared with its own block's temporary,
//! found by the block's guard in the source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const oz = @import("../oracle_zfls.zig");

/// A temporary of a block of the SELECT of group `group`
pub const Temp = struct { group: usize, name: []const u8, v: types.Var };

/// The temporaries of one SELECT: in namespace `ns`, of associate name
/// `assoc` ("" when the dump did not tell), whose symbol is `v` (none
/// when the SELECT names none)
pub const Group = struct { ns: []const u8, assoc: []const u8 = "", v: ?types.Var = null };

pub const Temps = struct {
    temps: std.ArrayList(Temp) = .empty,
    groups: std.ArrayList(Group) = .empty,
};

pub fn isTemp(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__tmp_");
}

/// Reads the listings of SELECTs' namespaces: alphabetical, the
/// temporaries first, ending at a line no deeper than their symbols
pub const Reader = struct {
    indent: usize = 0,
    /// the group of the listing being read
    open: ?usize = null,

    /// Symbol `name` of namespace `ns` at `indent`, with its detail lines
    /// `block`: a temporary, an associate name (`assoc`) or another one
    pub fn symbol(r: *Reader, a: Allocator, out: *Temps, ns: []const u8, indent: usize, name: []const u8, block: []const []const u8, temp: bool, assoc: bool) !void {
        if (indent != r.indent) r.open = null;
        r.indent = indent;
        if (temp) {
            if (r.open == null) {
                r.open = out.groups.items.len;
                try out.groups.append(a, .{ .ns = ns });
            }
            try out.temps.append(a, .{ .group = r.open.?, .name = name, .v = types.varOf(block) });
        } else if (assoc) if (r.open) |g| if (out.groups.items[g].assoc.len == 0) {
            out.groups.items[g].assoc = name;
            out.groups.items[g].v = types.varOf(block);
        };
        for (block) |b| {
            const deeper = std.mem.findNone(u8, b, " \t\r") orelse continue;
            if (deeper > indent) continue;
            // `SELECT RANK s:p(FULL)`, `SELECT CASE _loc[((s:items % _vptr))]`:
            // the selector of a SELECT without an associate name
            if (r.open) |g| if (out.groups.items[g].assoc.len == 0) if (selectorName(b[deeper..])) |n| {
                out.groups.items[g].assoc = n;
            };
            r.open = null;
            break;
        }
    }
};

/// The selector of `SELECT RANK block@1:r(FULL)` or of `SELECT CASE
/// _loc[((guards:items % _vptr))]` (gfortran 13 and 14: `SELECT TYPE
/// _loc[...]`), or null
fn selectorName(line: []const u8) ?[]const u8 {
    var text = line;
    if (std.mem.startsWith(u8, line, "SELECT RANK ")) {
        text = line[0 .. std.mem.findScalar(u8, line, '(') orelse return null];
    } else if (std.mem.startsWith(u8, line, "SELECT CASE ") or std.mem.startsWith(u8, line, "SELECT TYPE ")) {
        text = std.mem.trimEnd(u8, line[0 .. std.mem.find(u8, line, "% _vptr") orelse return null], " ");
    } else return null;
    const colon = std.mem.findScalarLast(u8, text, ':') orelse return null;
    return text[colon + 1 ..];
}

/// zfls's associate name of a block of SELECT TYPE or RANK: of path `key`
/// (as `gfortran_oracle.zig` makes them), of the block on line `line`
/// (1-based) of the SELECT `select` on line `select_line`
pub const Block = struct { key: []const u8, select: []const u8, select_line: usize, line: usize, decl: []const u8 };

/// What a block's guard says of its temporary's name
const Guard = union(enum) {
    /// `rank (2)`: `2`; `rank (*)`: `m1`
    rank: []const u8,
    /// CLASS DEFAULT, RANK DEFAULT: gfortran's symbol of the name
    default,
    /// the start of the temporary's name: `__tmp_type_child_t`,
    /// `__tmp_REAL_8`; `any_kind` when the guard gives no kind literal
    prefix: struct { text: []const u8, any_kind: bool = false },
    /// not read: any temporary of the SELECT
    unknown,
};

/// The guard of a block's first line; the names of temporaries in lower
/// case, as the oracle reads them
fn guardOf(a: Allocator, line: []const u8) !Guard {
    const low = try std.ascii.allocLowerString(a, std.mem.trim(u8, line[0 .. std.mem.findScalar(u8, line, '!') orelse line.len], " \t\r"));
    var words = std.mem.tokenizeAny(u8, low, " \t");
    const first = words.next() orelse return .unknown;
    const rest = std.mem.trim(u8, words.rest(), " \t");
    if (std.mem.eql(u8, first, "rank") or std.mem.startsWith(u8, first, "rank(")) {
        const after = std.mem.trimStart(u8, low["rank".len..], " \t");
        if (std.mem.startsWith(u8, after, "default")) return .default;
        if (after.len == 0 or after[0] != '(') return .unknown;
        const close = std.mem.findScalar(u8, after, ')') orelse return .unknown;
        const r = std.mem.trim(u8, after[1..close], " \t");
        if (std.mem.eql(u8, r, "*")) return .{ .rank = "m1" };
        _ = std.fmt.parseInt(u8, r, 10) catch return .unknown;
        return .{ .rank = r };
    }
    if (std.mem.eql(u8, first, "class") and std.mem.startsWith(u8, rest, "default")) return .default;
    const class = std.mem.eql(u8, first, "class");
    if (!class and !std.mem.eql(u8, first, "type")) return .unknown;
    // `is (t)`, `is(t)`
    const is = std.mem.trimStart(u8, low[first.len..], " \t");
    if (!std.mem.startsWith(u8, is, "is")) return .unknown;
    const open = std.mem.findScalar(u8, is, '(') orelse return .unknown;
    const close = std.mem.findScalarLast(u8, is, ')') orelse return .unknown;
    if (close <= open) return .unknown;
    const spec = std.mem.trim(u8, is[open + 1 .. close], " \t");
    const name_end = std.mem.findAny(u8, spec, " \t(*") orelse spec.len;
    const name = spec[0..name_end];
    if (class) return .{ .prefix = .{ .text = try a.print("__tmp_class_{s}", .{name}) } };
    if (std.mem.eql(u8, spec, "double precision")) return .{ .prefix = .{ .text = "__tmp_real_8" } };
    if (std.mem.eql(u8, spec, "double complex")) return .{ .prefix = .{ .text = "__tmp_complex_8" } };
    for ([_][]const u8{ "integer", "real", "complex", "logical", "character", "unsigned" }) |t| {
        if (!std.mem.eql(u8, name, t)) continue;
        // `real(8)`, `real(kind=8)`, `real*8`: of kind 8
        var kind = std.mem.trim(u8, spec[name_end..], " \t()*");
        if (std.mem.startsWith(u8, kind, "kind")) kind = std.mem.trimStart(u8, kind["kind".len..], " \t=");
        const literal = kind.len > 0 and std.mem.findNone(u8, kind, "0123456789") == null;
        if (literal and !std.mem.eql(u8, t, "character")) return .{ .prefix = .{ .text = try a.print("__tmp_{s}_{s}", .{ t, kind }) } };
        return .{ .prefix = .{ .text = try a.print("__tmp_{s}_", .{t}), .any_kind = true } };
    }
    return .{ .prefix = .{ .text = try a.print("__tmp_type_{s}", .{name}) } };
}

/// Whether temporary `t` is of guard `g`, in a SELECT of associate name
/// `assoc`
fn isOfGuard(t: Temp, g: Guard, assoc: []const u8) bool {
    return switch (g) {
        .rank => |r| std.mem.endsWith(u8, t.name, r) and std.mem.endsWith(u8, t.name[0 .. t.name.len - r.len], "_rank_"),
        .default => false,
        .prefix => |p| if (p.any_kind) std.mem.startsWith(u8, t.name, p.text) else (std.mem.eql(u8, t.name, p.text) or
            (std.mem.startsWith(u8, t.name, p.text) and std.mem.eql(u8, t.name[p.text.len..], assocSuffix(t.name, assoc)))),
        .unknown => true,
    };
}

/// `_it` when `name` ends with it (gfortran 16's names), else ""
fn assocSuffix(name: []const u8, assoc: []const u8) []const u8 {
    if (name.len <= assoc.len or !std.mem.endsWith(u8, name, assoc) or name[name.len - assoc.len - 1] != '_') return "";
    return name[name.len - assoc.len - 1 ..];
}

/// Whether group `g` is of a SELECT of name `name` in namespace `ns`: by
/// its associate name, or by its temporaries' names (gfortran 16's)
fn isOfName(t: *const Temps, g: usize, ns: []const u8, name: []const u8) bool {
    const group = t.groups.items[g];
    if (!std.mem.eql(u8, group.ns, ns)) return false;
    if (group.assoc.len > 0) return std.mem.eql(u8, group.assoc, name);
    for (t.temps.items) |x| if (x.group == g and assocSuffix(x.name, name).len > 0) return true;
    return false;
}

/// How zfls's declaration `decl` differs from type guard's temporary
/// `v`: in type or rank. gfortran makes these temporaries POINTER and
/// TARGET whatever the selector, so those are not compared.
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

/// The differences between zfls's associate names of blocks `blocks`, in
/// the order of the source, and gfortran's temporaries `t` and symbols
/// `vars`; `lines` the source's lines
pub fn check(a: Allocator, diffs: *std.ArrayList([]const u8), vars: *const std.StringHashMapUnmanaged(types.Var), t: *const Temps, blocks: []const Block, lines: []const []const u8) !void {
    // each SELECT's group: the n-th SELECT of a name in a namespace is the
    // n-th group of that name there
    var groups: std.StringHashMapUnmanaged(?usize) = .empty;
    var taken: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (blocks) |b| {
        const gop = try groups.getOrPut(a, b.select);
        if (gop.found_existing) continue;
        const sep = std.mem.findLast(u8, b.key, "::") orelse b.key.len;
        gop.value_ptr.* = for (t.groups.items, 0..) |_, g| {
            if (!taken.contains(g) and isOfName(t, g, b.key[0..sep], b.key[@min(sep + 2, b.key.len)..])) {
                try taken.put(a, g, {});
                break g;
            }
        } else null;
    }
    for (blocks) |b| {
        const g = groups.get(b.select).? orelse {
            try diffs.append(a, try a.print("differs: {s} (line {d}): {s}: no temporaries in gfortran", .{ b.key, b.line, b.decl }));
            continue;
        };
        const group = t.groups.items[g];
        const guard = if (b.line >= 1 and b.line <= lines.len) try guardOf(a, lines[b.line - 1]) else .unknown;
        var why: []const u8 = "";
        var ok = false;
        var seen = false;
        if (guard == .default) {
            // the selector's CLASS (or a dummy argument's), whose rank its
            // Array spec has
            if (group.v orelse vars.get(b.key)) |v| {
                seen = true;
                const class = std.mem.startsWith(u8, v.type, "(CLASS");
                if (try (if (class) tempMismatch(a, v, b.decl) else types.mismatch(a, v, b.decl))) |w| why = w else ok = true;
            }
        } else for (t.temps.items) |x| {
            if (ok) break;
            if (x.group != g or !isOfGuard(x, guard, group.assoc)) continue;
            seen = true;
            // a RANK block's temporary has the selector's attributes
            const w = if (guard == .rank) try types.mismatch(a, x.v, b.decl) else try tempMismatch(a, x.v, b.decl);
            if (w) |reason| why = reason else ok = true;
        }
        if (!seen) why = "no temporary of its guard in gfortran";
        if (!ok) try diffs.append(a, try a.print("differs: {s} (line {d}): {s}: {s}", .{ b.key, b.line, b.decl, why }));
    }
}

test guardOf {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0", (try guardOf(a, "    rank (0)")).rank);
    try std.testing.expectEqualStrings("m1", (try guardOf(a, "RANK(*)")).rank);
    try std.testing.expect(try guardOf(a, "  rank default") == .default);
    try std.testing.expect(try guardOf(a, "  CLASS DEFAULT ! comment") == .default);
    try std.testing.expectEqualStrings("__tmp_type_child_t", (try guardOf(a, "type is (Child_T)")).prefix.text);
    try std.testing.expectEqualStrings("__tmp_class_child_t", (try guardOf(a, "class is(child_t)")).prefix.text);
    try std.testing.expectEqualStrings("__tmp_real_8", (try guardOf(a, "type is (real(kind=8))")).prefix.text);
    try std.testing.expect((try guardOf(a, "type is (real(dp))")).prefix.any_kind);
    try std.testing.expectEqualStrings("__tmp_character_", (try guardOf(a, "type is (character(len=*))")).prefix.text);
    try std.testing.expect(try guardOf(a, "rank (n)") == .unknown);
}

test check {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars: std.StringHashMapUnmanaged(types.Var) = .empty;
    var t: Temps = .{};
    // gfortran 16.1, tests/fortran/select_rank.f90
    try t.groups.append(a, .{ .ns = "m::s", .assoc = "r", .v = .{ .type = "(REAL 4)", .assumed_rank = true } });
    try t.temps.appendSlice(a, &.{
        .{ .group = 0, .name = "__tmp_real_4_rank_0", .v = .{ .type = "(REAL 4)" } },
        .{ .group = 0, .name = "__tmp_real_4_rank_2", .v = .{ .type = "(REAL 4)", .rank = 2 } },
    });
    const lines = [_][]const u8{ "select rank (r => a)", "rank (0)", "rank (2)", "rank default" };
    var blocks = [_]Block{
        .{ .key = "m::s::r", .select = "m::s::#select1", .select_line = 1, .line = 2, .decl = "REAL :: r" },
        .{ .key = "m::s::r", .select = "m::s::#select1", .select_line = 1, .line = 3, .decl = "REAL, DIMENSION(:,:) :: r" },
        .{ .key = "m::s::r", .select = "m::s::#select1", .select_line = 1, .line = 4, .decl = "REAL, DIMENSION(..) :: r" },
    };
    var diffs: std.ArrayList([]const u8) = .empty;
    try check(a, &diffs, &vars, &t, &blocks, &lines);
    try std.testing.expectEqual(0, diffs.items.len);
    // RANK (0)'s name with another block's rank (before #711)
    blocks[0].decl = "REAL, DIMENSION(..) :: r";
    try check(a, &diffs, &vars, &t, &blocks, &lines);
    try std.testing.expectEqual(1, diffs.items.len);
}

test "the temporaries of a SELECT without an associate name take its selector's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Temps = .{};
    var r: Reader = .{};
    // gfortran 16.1, `select rank (p)`
    try r.symbol(a, &t, "m::s", 6, "__tmp_real_4_rank_1", &.{ "        type spec : (REAL 4)", "        Array spec:(1 [0] AS_DEFERRED () () )" }, true, false);
    try r.symbol(a, &t, "m::s", 6, "block@2", &.{ "        type spec : (UNKNOWN 0)", "        attributes: (LABEL )", "      ", "      SELECT RANK s:p(FULL)" }, false, false);
    try std.testing.expectEqualStrings("p", t.groups.items[0].assoc);
    try std.testing.expectEqualStrings("items", selectorName("SELECT CASE _loc[((guards:items % _vptr))]").?);
    // gfortran 13
    try std.testing.expectEqualStrings("it", selectorName("SELECT TYPE _loc[((block@1:it % _vptr))]").?);
    try std.testing.expectEqualStrings("r", selectorName("SELECT RANK block@1:r(FULL)").?);
}
