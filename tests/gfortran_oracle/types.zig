//! What the gfortran oracle (gfortran_oracle.zig) compares beyond names
//! (#551): a variable's type and kind, rank, ALLOCATABLE, POINTER, TARGET
//! and INTENT as gfortran's dump has them, against what zfls's hover
//! declares (oracle_zfls.zig); and the components of DEC structures, whose
//! unions and maps the dump names `UU$0` and `MM$0`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oz = @import("../oracle_zfls.zig");

pub const Var = struct {
    /// `(REAL 8)`, `(CHARACTER 5 1)`, `(DERIVED point)`, `(CLASS ...)`
    type: []const u8 = "",
    rank: usize = 0,
    /// `Array spec:(-1 ... AS_ASSUMED_RANK)`, `x(..)`
    assumed_rank: bool = false,
    allocatable: bool = false,
    pointer: bool = false,
    target: bool = false,
    /// of `DUMMY(IN)`: `IN`, `OUT`, `INOUT`
    intent: ?[]const u8 = null,
};

/// The variable a symbol's detail lines describe
pub fn varOf(block: []const []const u8) Var {
    var v: Var = .{};
    for (block) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, t, "type spec : ")) {
            v.type = t["type spec : ".len..];
        } else if (std.mem.startsWith(u8, t, "Array spec:(")) {
            var words = std.mem.tokenizeScalar(u8, t["Array spec:(".len..], ' ');
            const r = words.next() orelse "0";
            v.assumed_rank = std.mem.eql(u8, r, "-1");
            v.rank = std.fmt.parseInt(usize, r, 10) catch 0;
        } else if (std.mem.startsWith(u8, t, "attributes: (")) {
            var words = std.mem.tokenizeAny(u8, t["attributes: (".len..], " \t)");
            while (words.next()) |w| {
                if (std.mem.eql(u8, w, "ALLOCATABLE")) v.allocatable = true;
                if (std.mem.eql(u8, w, "POINTER")) v.pointer = true;
                if (std.mem.eql(u8, w, "TARGET")) v.target = true;
                if (std.mem.startsWith(u8, w, "DUMMY(")) v.intent = w["DUMMY(".len..];
            }
        }
    }
    return v;
}

/// How zfls's declaration `decl` (the first line of its hover) differs
/// from gfortran's `v`, null when they agree
pub fn mismatch(a: Allocator, v: Var, decl: []const u8) !?[]const u8 {
    const spec = oz.typeSpec(decl);
    if (v.type.len > 0) if (try oz.typeOf(a, spec)) |t| {
        const ok = switch (t) {
            .character => std.mem.startsWith(u8, v.type, "(CHARACTER"),
            .derived => |d| std.mem.startsWith(u8, v.type, "(CLASS") or
                std.ascii.eqlIgnoreCase(v.type, try a.print("(DERIVED {s})", .{d.name})),
            .intrinsic => |i| std.mem.eql(u8, v.type, try a.print("({s} {d})", .{ i.name, i.kind })),
        };
        if (!ok) return try a.print("type {s}, gfortran {s}", .{ spec, v.type });
    };
    const attrs = try std.ascii.allocUpperString(a, decl[0 .. std.mem.find(u8, decl, " :: ") orelse decl.len]);
    // a CLASS variable's rank, ALLOCATABLE and POINTER are its class
    // container's `_data` component's in the dump
    if (std.mem.startsWith(u8, v.type, "(CLASS")) return null;
    const assumed = std.mem.find(u8, attrs, "DIMENSION(..)") != null;
    if (assumed != v.assumed_rank) return try a.print("assumed rank {}, gfortran {}", .{ assumed, v.assumed_rank });
    const r = oz.rank(attrs);
    if (!assumed and r != v.rank) return try a.print("rank {d}, gfortran {d}", .{ r, v.rank });
    for ([_]struct { []const u8, bool }{ .{ "ALLOCATABLE", v.allocatable }, .{ "POINTER", v.pointer }, .{ "TARGET", v.target } }) |p| {
        const z = std.mem.find(u8, attrs, p[0]) != null;
        if (z != p[1]) return try a.print("{s} {}, gfortran {}", .{ p[0], z, p[1] });
    }
    if (std.mem.find(u8, attrs, "INTENT(")) |i| {
        const close = std.mem.findScalarPos(u8, attrs, i, ')') orelse attrs.len;
        // `IN OUT` is `INOUT`
        const intent = try std.mem.replaceOwned(u8, a, attrs[i + "INTENT(".len .. close], " ", "");
        if (v.intent == null or !std.mem.eql(u8, intent, v.intent.?)) return try a.print("INTENT({s}), gfortran {?s}", .{ intent, v.intent });
    }
    return null;
}

/// A component of a DEC structure, union or map: `(x (REAL 4) ())`
pub const Component = struct { name: []const u8, type: []const u8 };

/// The components that a structure's, union's or map's detail lines list
pub fn components(a: Allocator, block: []const []const u8) ![]const Component {
    var out: std.ArrayList(Component) = .empty;
    for (block) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len < 3 or t[0] != '(' or t[1] == '(') continue;
        const sp = std.mem.findScalar(u8, t, ' ') orelse continue;
        const rest = t[sp + 1 ..];
        if (rest.len == 0 or rest[0] != '(') continue;
        const close = std.mem.findScalar(u8, rest, ')') orelse continue;
        try out.append(a, .{ .name = t[1..sp], .type = rest[0 .. close + 1] });
    }
    return out.items;
}

/// Whether `name` is one of the dump's own: `MM$0` (a map), `UU$0` (a union)
pub fn isArtificial(name: []const u8) bool {
    const d = std.mem.findScalar(u8, name, '$') orelse return false;
    if (d != 2 or d + 1 >= name.len) return false;
    for (name[d + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return std.ascii.isUpper(name[0]) and std.ascii.isUpper(name[1]);
}

/// The fields of DEC structure `name` (the dump's name), through its
/// unions and maps, from `records` (each one's components)
pub fn fields(a: Allocator, records: *const std.StringHashMapUnmanaged([]const Component), name: []const u8, out: *std.ArrayList([]const u8)) !void {
    for (records.get(name) orelse return) |c| {
        if (isArtificial(c.name)) {
            try fields(a, records, c.name, out);
        } else try out.append(a, c.name);
    }
}

test "a variable of gfortran's dump, against zfls's declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // gfortran 16.1
    const v = varOf(&.{ "    type spec : (REAL 4)", "    attributes: (VARIABLE IMPLICIT-SAVE ALLOCATABLE DIMENSION)", "    Array spec:(2 [0] AS_DEFERRED () () () () )" });
    try std.testing.expectEqualStrings("(REAL 4)", v.type);
    try std.testing.expectEqual(@as(usize, 2), v.rank);
    try std.testing.expect(v.allocatable and !v.pointer);
    try std.testing.expect(try mismatch(a, v, "REAL, ALLOCATABLE, DIMENSION(:,:) :: a") == null);
    try std.testing.expect(try mismatch(a, v, "REAL(8), ALLOCATABLE, DIMENSION(:,:) :: a") != null);
    try std.testing.expect(try mismatch(a, v, "REAL, ALLOCATABLE, DIMENSION(:) :: a") != null);
    const d = varOf(&.{ "      type spec : (DERIVED tt)", "      attributes: (VARIABLE  ARTIFICIAL DUMMY(IN))" });
    try std.testing.expectEqualStrings("IN", d.intent.?);
    try std.testing.expect(try mismatch(a, d, "TYPE(tt), INTENT(IN) :: src") == null);
    try std.testing.expect(try mismatch(a, d, "TYPE(tt), INTENT(OUT) :: src") != null);
    const ar = varOf(&.{ "      type spec : (REAL 4)", "      attributes: (VARIABLE  DIMENSION DUMMY(IN))", "      Array spec:(-1 [0] AS_ASSUMED_RANK )" });
    try std.testing.expect(try mismatch(a, ar, "REAL, DIMENSION(..), INTENT(IN) :: x") == null);
    try std.testing.expect(try mismatch(a, ar, "REAL, DIMENSION(:), INTENT(IN) :: x") != null);
}

test "the fields of a DEC structure, through its unions and maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var records: std.StringHashMapUnmanaged([]const Component) = .empty;
    try records.put(a, "Point", try components(a, &.{ "    (x (REAL 4) ()) ", "    (UU$0 (UNION UU$0) ())" }));
    try records.put(a, "UU$0", try components(a, &.{ "    (MM$0 (DERIVED MM$0) ()) ", "    (MM$1 (DERIVED MM$1) ())" }));
    try records.put(a, "MM$0", try components(a, &.{"    (i (INTEGER 4) ())"}));
    try records.put(a, "MM$1", try components(a, &.{"    (r (REAL 4) ())"}));
    var out: std.ArrayList([]const u8) = .empty;
    try fields(a, &records, "Point", &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("i", out.items[1]);
    try std.testing.expect(isArtificial("MM$0") and isArtificial("UU$12") and !isArtificial("a$b"));
}
