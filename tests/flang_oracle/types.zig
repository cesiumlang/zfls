//! What the Flang oracle (flang_oracle.zig) compares beyond names (#715):
//! a variable's type and kind, rank, ALLOCATABLE, POINTER, TARGET and
//! INTENT, as the gfortran and ifx oracles do, from Flang's dump
//! (dump.zig) and from zfls's hover (oracle_zfls.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const dump = @import("dump.zig");
const oz = @import("../oracle_zfls.zig");

pub const Var = struct {
    /// `REAL(4)`, `CHARACTER(5_8,1)`, `TYPE(point)`, `CLASS(*)`; "" when
    /// the dump gives none
    type: []const u8 = "",
    /// null when the dump does not tell (the associate name of ASSOCIATE
    /// or SELECT TYPE)
    rank: ?usize = 0,
    assumed_rank: bool = false,
    allocatable: bool = false,
    pointer: bool = false,
    target: bool = false,
    /// `IN`, `OUT`, `INOUT`
    intent: ?[]const u8 = null,
};

/// A variable of Flang's or zfls's, by its path (entities.zig)
pub const Item = struct { path: []const u8, v: Var };

/// The words of `text` outside parentheses
fn words(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: ?usize = null;
    for (text, 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ' ' => if (depth == 0) {
                if (start) |s| try out.append(a, text[s..i]);
                start = null;
                continue;
            },
            else => {},
        }
        if (start == null) start = i;
    }
    if (start) |s| try out.append(a, text[s..]);
    return out.items;
}

/// The number of dimensions of a shape (`1_8:2_8,:`)
fn dimensions(shape: []const u8) usize {
    var n: usize = 1;
    var depth: usize = 0;
    for (shape) |c| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 0) {
            n += 1;
        },
        else => {},
    };
    return n;
}

/// The variable an ObjectEntity or AssocEntity symbol is
pub fn varOf(a: Allocator, sym: dump.Symbol) !Var {
    // ASSOCIATE and SELECT TYPE: the selector's rank, which the dump does
    // not give
    var v: Var = .{ .rank = if (std.mem.eql(u8, sym.details, "AssocEntity")) null else 0 };
    const ws = try words(a, sym.rest);
    for (ws, 0..) |w, i| {
        // the rest is the value or the selector
        if (std.mem.startsWith(u8, w, "init:") or std.mem.startsWith(u8, w, "expr:")) break;
        const next = if (i + 1 < ws.len) ws[i + 1] else "";
        if (std.mem.eql(u8, w, "type:")) {
            v.type = next;
        } else if (std.mem.eql(u8, w, "shape:")) {
            v.assumed_rank = std.mem.eql(u8, next, "..");
            v.rank = if (v.assumed_rank) 0 else dimensions(next);
        } else if (std.mem.startsWith(u8, w, "RANK(")) {
            // of a block of SELECT RANK; `RANK(*)`: assumed size
            const r = w["RANK(".len .. w.len - 1];
            v.rank = if (std.mem.eql(u8, r, "*")) 1 else std.fmt.parseInt(usize, r, 10) catch null;
        } else if (std.mem.eql(u8, w, "RANK") and std.mem.eql(u8, next, "DEFAULT")) {
            v.assumed_rank = true;
            v.rank = 0;
        }
    }
    v.allocatable = sym.hasAttr("ALLOCATABLE");
    v.pointer = sym.hasAttr("POINTER");
    v.target = sym.hasAttr("TARGET");
    for ([_][]const u8{ "IN", "OUT", "INOUT" }) |i| {
        if (sym.hasAttr(try a.print("INTENT({s})", .{i}))) v.intent = i;
    }
    return v;
}

/// A derived type's name without `__builtin_`: iso_c_binding's and the
/// other intrinsic modules' types are Flang's builtin ones (`c_ptr` is
/// `__builtin_c_ptr`)
fn typeName(name: []const u8) []const u8 {
    const builtin = "__builtin_";
    return if (std.ascii.startsWithIgnoreCase(name, builtin)) name[builtin.len..] else name;
}

/// How zfls's declaration `decl` (the first line of its hover) differs
/// from Flang's `v`, null when they agree
pub fn mismatch(a: Allocator, v: Var, decl: []const u8) !?[]const u8 {
    const spec = oz.typeSpec(decl);
    if (v.type.len > 0) if (try oz.typeOf(a, spec)) |t| {
        const ok = switch (t) {
            .character => std.mem.startsWith(u8, v.type, "CHARACTER("),
            .derived => |d| blk: {
                // a DEC structure's record: `RECORD/point/`
                if (!d.class and std.mem.startsWith(u8, v.type, "RECORD/"))
                    break :blk std.ascii.eqlIgnoreCase(std.mem.trim(u8, v.type["RECORD".len..], "/"), d.name);
                const keyword = if (d.class) "CLASS(" else "TYPE(";
                if (!std.mem.startsWith(u8, v.type, keyword)) break :blk false;
                const inner = v.type[keyword.len .. v.type.len - 1];
                // the parameters of a parameterized type are not compared
                break :blk std.ascii.eqlIgnoreCase(typeName(inner[0 .. std.mem.findScalar(u8, inner, '(') orelse inner.len]), typeName(d.name));
            },
            .intrinsic => |i| std.mem.eql(u8, v.type, try a.print("{s}({d})", .{ i.name, i.kind })),
        };
        if (!ok) return try a.print("type {s}, Flang {s}", .{ spec, v.type });
    };
    const attrs = try std.ascii.allocUpperString(a, decl[0 .. std.mem.find(u8, decl, " :: ") orelse decl.len]);
    const assumed = std.mem.find(u8, attrs, "DIMENSION(..)") != null;
    if (v.rank) |r| {
        if (assumed != v.assumed_rank) return try a.print("assumed rank {}, Flang {}", .{ assumed, v.assumed_rank });
        if (!assumed and oz.rank(attrs) != r) return try a.print("rank {d}, Flang {d}", .{ oz.rank(attrs), r });
    }
    for ([_]struct { []const u8, bool }{ .{ "ALLOCATABLE", v.allocatable }, .{ "POINTER", v.pointer }, .{ "TARGET", v.target } }) |p| {
        const z = std.mem.find(u8, attrs, p[0]) != null;
        if (z != p[1]) return try a.print("{s} {}, Flang {}", .{ p[0], z, p[1] });
    }
    const intent: ?[]const u8 = if (std.mem.find(u8, attrs, "INTENT(")) |i|
        try std.mem.replaceOwned(u8, a, attrs[i + "INTENT(".len .. std.mem.findScalarPos(u8, attrs, i, ')') orelse attrs.len], " ", "")
    else
        null;
    if (intent != null or v.intent != null) {
        if (intent == null or v.intent == null or !std.mem.eql(u8, intent.?, v.intent.?)) return try a.print("INTENT({?s}), Flang {?s}", .{ intent, v.intent });
    }
    return null;
}

test "a variable of Flang's dump, against zfls's declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Flang 23.1.5
    const r = try dump.parse(a,
        \\Global scope: size=0 alignment=1 sourceRange=0 bytes
        \\  Module scope: m size=0 alignment=1 sourceRange=504 bytes
        \\    a, INTENT(IN) size=48 offset=0: ObjectEntity dummy type: REAL(4) shape: ..
        \\    b size=48 offset=120: ObjectEntity type: REAL(4) shape: 1_8:__builtin_int(n,kind=8),1_8:2_8
        \\    p, POINTER: AssocEntity type: REAL(4) RANK(1) expr:p
        \\    it: AssocEntity type: TYPE(base_t) expr:items(1_8)
        \\    c: ObjectEntity type: TYPE(__builtin_c_ptr)
        \\    s, PARAMETER: ObjectEntity type: CHARACTER(5_8,1) init:"a b c"
        \\    al, ALLOCATABLE size=48 offset=0: ObjectEntity type: REAL(4) shape: :
        \\    pr size=8 offset=0: ObjectEntity type: RECORD/pair/
    );
    const syms = r.global.children.items[0].symbols.items;
    const av = try varOf(a, syms[0]);
    try std.testing.expect(av.assumed_rank and std.mem.eql(u8, av.intent.?, "IN"));
    try std.testing.expect(try mismatch(a, av, "REAL, DIMENSION(..), INTENT(IN) :: a") == null);
    try std.testing.expect(try mismatch(a, av, "REAL, DIMENSION(..) :: a") != null);
    const bv = try varOf(a, syms[1]);
    try std.testing.expectEqual(@as(?usize, 2), bv.rank);
    try std.testing.expect(try mismatch(a, bv, "REAL, DIMENSION(n,2) :: b") == null);
    try std.testing.expect(try mismatch(a, bv, "REAL(8), DIMENSION(n,2) :: b") != null);
    const pv = try varOf(a, syms[2]);
    try std.testing.expect(pv.pointer and pv.rank.? == 1);
    try std.testing.expect(try mismatch(a, pv, "REAL :: p") != null);
    const iv = try varOf(a, syms[3]);
    try std.testing.expectEqual(@as(?usize, null), iv.rank);
    try std.testing.expect(try mismatch(a, iv, "TYPE(base_t), DIMENSION(:) :: it") == null);
    try std.testing.expect(try mismatch(a, iv, "CLASS(base_t) :: it") != null);
    try std.testing.expect(try mismatch(a, try varOf(a, syms[4]), "TYPE(c_ptr) :: c") == null);
    try std.testing.expect(try mismatch(a, try varOf(a, syms[5]), "CHARACTER(len=5), PARAMETER :: s = 'a b c'") == null);
    try std.testing.expect(try mismatch(a, try varOf(a, syms[6]), "REAL, ALLOCATABLE, DIMENSION(:) :: al") == null);
    try std.testing.expect(try mismatch(a, try varOf(a, syms[6]), "REAL, ALLOCATABLE :: al") != null);
    try std.testing.expect(try mismatch(a, try varOf(a, syms[7]), "TYPE(pair) :: pr") == null);
}
