//! Values of the gdb backend of `zfls dap` that gdb does not show as
//! Fortran, read otherwise: a CHARACTER of kind 4, whose type gdb gives as
//! an array (`character(kind=4) (5)`, its length first also for an array
//! of them: `character(kind=4) (3,3,2)`) and whose text it cuts short at a
//! character beyond ASCII, read from memory; a module's deferred-length
//! CHARACTER, whose length gfortran keeps apart; a module's COMMON
//! variable, which gfortran's DWARF leaves out.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const fortran = @import("fortran.zig");
const session = @import("session.zig");
const Session = session.Session;
const gdb = @import("gdb.zig");
const gdb_variables = @import("gdb_variables.zig");
const Variable = gdb_variables.Variable;
const declarations = @import("declarations.zig");

/// The longest string read from memory
const max_len = 4096;

/// A scalar CHARACTER of kind 4 (gdb's array type `t` of one dimension,
/// its length) as Fortran writes it (`4_'hëllo'`), read from the memory
/// of `expr`; null for any other type, or when it cannot be read
pub fn wideCharacter(s: *Session, a: Allocator, t: fortran.ArrayType, expr: ?[]const u8, frame: ?i64) !?[]const u8 {
    if (characterKind(t.element) != 4 or t.dims.len != 1) return null;
    const len = fortran.extent(t.dims[0]) orelse return null;
    if (len > max_len) return null;
    const bytes = try readMemory(s, a, expr orelse return null, len * 4, frame) orelse return null;
    return try wideText(a, bytes);
}

/// The most elements of an array of CHARACTER of kind 4 read at once
const max_elements = 4096;

/// An array of CHARACTER of kind 4 (gdb's type `t`: the length, then the
/// array's dimensions), read from the memory of `expr` at once: its
/// elements in order (`(1,1)`, `(2,1)`, ...), each `4_'...'` with gdb's
/// expression of it (`w(:,2,1)`); null for another type, or when it cannot
/// be read
pub fn wideArray(s: *Session, a: Allocator, t: fortran.ArrayType, expr: ?[]const u8, frame: ?i64) !?[]Variable {
    if (characterKind(t.element) != 4 or t.dims.len < 2) return null;
    const len = fortran.extent(t.dims[0]) orelse return null;
    const dims = t.dims[1..];
    var count: u64 = 1;
    for (dims) |d| count = std.math.mul(u64, count, fortran.extent(d) orelse return null) catch return null;
    if (len > max_len or count > max_elements or len * count > max_len * 16) return null;
    const e = expr orelse return null;
    const bytes = try readMemory(s, a, e, len * count * 4, frame) orelse return null;
    const out = try a.alloc(Variable, @intCast(count));
    const index = try a.alloc(i64, dims.len);
    for (index, dims) |*x, d| x.* = d.lo.?;
    const element_type = try a.print("character(kind=4,len={d})", .{len});
    for (out, 0..) |*o, k| {
        var subs: std.ArrayList(u8) = .empty;
        for (index, 0..) |x, j| try subs.print(a, "{s}{d}", .{ if (j == 0) "" else ",", x });
        const at: usize = @intCast(k * len * 4);
        o.* = .{
            .name = try a.print("({s})", .{subs.items}),
            .value = try wideText(a, bytes[at..][0..@intCast(len * 4)]),
            .type = element_type,
            .evaluate_name = try a.print("{s}(:,{s})", .{ e, subs.items }),
        };
        // the next subscripts, the first fastest
        for (index, dims) |*x, d| {
            if (x.* < d.hi.?) {
                x.* += 1;
                break;
            }
            x.* = d.lo.?;
        }
    }
    return out;
}

/// The Fortran type of an array of CHARACTER of kind 4 from gdb's (`t`):
/// `character(kind=4,len=3) (3,0:1)`
pub fn wideArrayType(a: Allocator, t: fortran.ArrayType) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "character(kind=4,len={d}) (", .{fortran.extent(t.dims[0]) orelse 0});
    for (t.dims[1..], 0..) |d, i| {
        if (i > 0) try out.append(a, ',');
        if (d.lo == 1) try out.print(a, "{d}", .{d.hi.?}) else try out.print(a, "{d}:{d}", .{ d.lo.?, d.hi.? });
    }
    try out.append(a, ')');
    return out.items;
}

/// `count` bytes at the address of `expr`, or null when they cannot be read
fn readMemory(s: *Session, a: Allocator, expr: []const u8, count: u64, frame: ?i64) !?[]u8 {
    const r = try gdb.request(s, a, "evaluate", try gdb_variables.evalArgs(a, try a.print("&{s}", .{expr}), frame, "watch"));
    if (!gdb.isSuccess(r)) return null;
    const result = json.str(json.path(r, &.{ "body", "result" })) orelse return null;
    const address = fortran.addressOf(result[std.mem.find(u8, result, "0x") orelse return null ..]) orelse return null;
    const m = try gdb.request(s, a, "readMemory", .{ .memoryReference = address, .count = count });
    if (!gdb.isSuccess(m)) return null;
    const data = json.str(json.path(m, &.{ "body", "data" })) orelse return null;
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, decoder.calcSizeForSlice(data) catch return null);
    decoder.decode(bytes, data) catch return null;
    if (bytes.len != count) return null;
    return bytes;
}

/// A module's deferred-length CHARACTER of gfortran's, gdb's variable
/// `gv`: gfortran's DWARF has a pointer to one character (`PTR TO -> (
/// character(kind=1) )`), and the length in the static
/// `_F.<module>_MOD_<name>`. Its text (`*module::name@len`), or "not
/// allocated"; null for another variable, or when it cannot be read
pub fn moduleString(s: *Session, a: Allocator, module: []const u8, name: []const u8, gv: Variable, frame: ?i64) !?Variable {
    const target = fortran.pointerTarget(gv.type) orelse return null;
    if (!std.mem.eql(u8, target, "character(kind=1)")) return null;
    var out = gv;
    out.ref = 0;
    if (fortran.isNullPointer(gv.value)) {
        out.value = s.text.not_allocated;
        return out;
    }
    const m = try std.ascii.allocLowerString(a, module);
    const n = try std.ascii.allocLowerString(a, name);
    const py = try a.print("python print('zfls-len %d' % int(gdb.lookup_global_symbol('_F.{s}_MOD_{s}').value()))", .{ m, n });
    const r = try gdb.request(s, a, "evaluate", try gdb_variables.evalArgs(a, py, frame, "repl"));
    const len = lengthResult(json.str(json.path(r, &.{ "body", "result" })) orelse return null) orelse return null;
    out.type = try a.print("character*{d}", .{len});
    if (len == 0) {
        out.value = "''";
        return out;
    }
    const t = try gdb.request(s, a, "evaluate", try gdb_variables.evalArgs(a, try a.print("*{s}::{s}@{d}", .{ m, n, len }), frame, "watch"));
    if (!gdb.isSuccess(t)) return null;
    out.value = json.str(json.path(t, &.{ "body", "result" })) orelse return null;
    return out;
}

/// The length that `moduleString`'s Python printed: `zfls-len 11`
pub fn lengthResult(output: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, l, "zfls-len ")) return std.fmt.parseInt(u64, l["zfls-len ".len..], 10) catch null;
    }
    return null;
}

/// A module's variable in its COMMON block (`common /blk/ cx, cy` in the
/// module), of which gdb knows only the block's symbol (`blk_`): a
/// convenience variable of its declared type at the block plus its offset
/// (zfls's declarations), gdb's variable of it named `name`; null when it
/// is in no block, or its type or shape is not one written here
pub fn commonMember(s: *Session, a: Allocator, module: []const u8, name: []const u8, frame: ?i64) !?Variable {
    const mod = declarations.moduleNamed(s, module) orelse return null;
    const place = declarations.commonPlace(a, mod, name) orelse return null;
    if (place.block.len == 0) return null;
    const t = gdbType(a, module, declarations.moduleDecl(s, a, module, name) orelse return null) orelse return null;
    s.g.convenience += 1;
    const variable = try a.print("zfls_{d}", .{s.g.convenience});
    const py = try a.print("python v=gdb.Value(int(gdb.parse_and_eval('&{s}_'))+{d}).cast(({s}).pointer()).dereference();gdb.set_convenience_variable('{s}',v);print('zfls-common')", .{ try std.ascii.allocLowerString(a, place.block), place.offset, t, variable });
    const r = try gdb.request(s, a, "evaluate", try gdb_variables.evalArgs(a, py, frame, "repl"));
    if (std.mem.find(u8, json.str(json.path(r, &.{ "body", "result" })) orelse "", "zfls-common") == null) return null;
    const expr = try a.print("${s}", .{variable});
    const v = try gdb.request(s, a, "evaluate", try gdb_variables.evalArgs(a, expr, frame, "watch"));
    if (!gdb.isSuccess(v)) return null;
    return .{
        .name = name,
        .value = json.str(json.path(v, &.{ "body", "result" })) orelse return null,
        .type = json.str(json.path(v, &.{ "body", "type" })),
        .ref = json.int(json.path(v, &.{ "body", "variablesReference" })) orelse 0,
        .evaluate_name = expr,
    };
}

/// gdb's Python of the type of a declaration of `module`
/// (`gdb.lookup_type('real(kind=4)')`, `.array(1,3)` for each dimension,
/// the first innermost, as Fortran lays them out): integers, reals,
/// complexes, logicals, CHARACTER of a constant length, and a derived type
/// of the module's that gdb knows (`blocks::point`, when the program has
/// it elsewhere than in the block); null for another type, or a shape that
/// is not constant
fn gdbType(a: Allocator, module: []const u8, d: declarations.Decl) ?[]const u8 {
    var t = switch (d.t.kind) {
        .integer => a.print("gdb.lookup_type('integer(kind={d})')", .{d.t.size}),
        .real => a.print("gdb.lookup_type('real(kind={d})')", .{d.t.size}),
        .complex => a.print("gdb.lookup_type('complex(kind={d})')", .{d.t.size / 2}),
        .logical => a.print("gdb.lookup_type('logical(kind={d})')", .{d.t.size}),
        .character => if (d.t.size == 0) return null else a.print("gdb.lookup_type('character(kind=1)').array(1,{d})", .{d.t.size}),
        .derived => if (d.t.polymorphic or d.t.name.len == 0) return null else a.print("gdb.lookup_type('{s}::{s}')", .{ lower(a, module) orelse return null, lower(a, d.t.name) orelse return null }),
        else => return null,
    } catch return null;
    for (d.dims) |dim| {
        const lo = dim.lo orelse return null;
        const hi = dim.hi orelse return null;
        t = a.print("{s}.array({d},{d})", .{ t, lo, hi }) catch return null;
    }
    return t;
}

fn lower(a: Allocator, x: []const u8) ?[]const u8 {
    return std.ascii.allocLowerString(a, x) catch null;
}

/// The kind of gdb's CHARACTER type (`character(kind=4)`): 4; 1 for
/// `character*5`; 0 for another type
pub fn characterKind(t: []const u8) u32 {
    const prefix = "character(kind=";
    if (!std.mem.startsWith(u8, t, prefix)) return if (std.mem.startsWith(u8, t, "character")) 1 else 0;
    const end = std.mem.findScalarPos(u8, t, prefix.len, ')') orelse return 0;
    return std.fmt.parseInt(u32, t[prefix.len..end], 10) catch 0;
}

/// Characters of 4 bytes (UTF-32, little-endian) as a Fortran literal of
/// kind 4 in UTF-8: `4_'hëllo'`, a `'` doubled, an invalid one as U+FFFD
pub fn wideText(a: Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "4_'");
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const c = std.mem.readInt(u32, bytes[i..][0..4], .little);
        const cp: u21 = if (c <= 0x10FFFF and !(c >= 0xD800 and c <= 0xDFFF)) @intCast(c) else 0xFFFD;
        if (cp == '\'') try out.append(a, '\'');
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }
    try out.append(a, '\'');
    return out.items;
}

test "a CHARACTER of kind 4 from its bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: [20]u8 = undefined;
    for ([_]u32{ 'h', 0xEB, 'l', 'l', 'o' }, 0..) |c, k| std.mem.writeInt(u32, b[k * 4 ..][0..4], c, .little);
    try std.testing.expectEqualStrings("4_'hëllo'", try wideText(a, &b));
    std.mem.writeInt(u32, b[0..4], '\'', .little);
    std.mem.writeInt(u32, b[4..8], 0xD800, .little);
    try std.testing.expectEqualStrings("4_'''\u{FFFD}'", try wideText(a, b[0..8]));
    try std.testing.expectEqual(@as(u32, 4), characterKind("character(kind=4)"));
    try std.testing.expectEqual(@as(u32, 1), characterKind("character*5"));
    try std.testing.expectEqual(@as(u32, 0), characterKind("real(kind=4)"));
}

test "the length of a module's deferred-length CHARACTER, as gdb's Python prints it" {
    try std.testing.expectEqual(@as(?u64, 11), lengthResult("zfls-len 11\n"));
    try std.testing.expectEqual(@as(?u64, 0), lengthResult("zfls-len 0\r\n"));
    try std.testing.expect(lengthResult("Traceback (most recent call last):\nAttributeError: 'NoneType' object has no attribute 'value'\n") == null);
}

test "the Fortran type of an array of CHARACTER of kind 4" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = (try fortran.arrayType(a, "character(kind=4) (3,3,0:1)")).?;
    try std.testing.expectEqualStrings("character(kind=4,len=3) (3,0:1)", try wideArrayType(a, t));
}
