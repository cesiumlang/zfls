//! LFortran's values on Windows's Debugger Engine (#366), in the programs
//! of its CodeView build (run/lfortran_types.zig gives their types):
//! CHARACTER as its `lfortran_string` (the data's address and the length),
//! or a dummy's data with its hidden length (`__libasr_len_s`); arrays
//! through its descriptor (`lfortran_array`: the data, an offset in
//! elements, the rank, then each dimension's lower bound, length and
//! stride in elements), or a dummy of assumed shape as its data with the
//! hidden extents (`__1a`, `__2b`). Part of `Session` (session.zig): each
//! function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const values = @import("values.zig");
const dbgeng = @import("dbgeng.zig");
const session = @import("session.zig");
const Session = session.Session;
const Frame = session.Frame;
const Val = session.Val;
const Decl = @import("declarations.zig").Decl;
const lfortran = @import("lfortran.zig");

/// The bytes of LFortran's descriptor before its dimensions
const header = 32;

/// A CHARACTER scalar of LFortran's: `val` with its data and length; false
/// when it is not one of LFortran's ways
pub fn string(s: *Session, a: Allocator, val: *Val, v: dbgeng.Variable, type_index: u32, frame: Frame) !bool {
    if (isNamed(s, a, v.mod_base, type_index, "lfortran_string")) {
        var w: [2]u64 = undefined;
        if (s.engine.read(val.address, std.mem.sliceAsBytes(&w)) != 16) return error.Unreadable;
        if (w[0] == 0) {
            val.empty = true;
            return true;
        }
        val.address = w[0];
        val.t.size = @intCast(@min(w[1], 1 << 20));
        return true;
    }
    // a CHARACTER(*) dummy: its data, and its length beside it
    if (v.parameter and val.t.size == 0) {
        const n = try hidden(s, a, frame, try a.print("__libasr_len_{s}", .{v.name}), 8) orelse return false;
        val.t.size = @intCast(@min(n, 1 << 20));
        return true;
    }
    return false;
}

/// An array of LFortran's: `val` with its data and extents; false when it
/// is not one of LFortran's ways. `elem` an element's bytes.
pub fn array(s: *Session, a: Allocator, val: *Val, d: Decl, v: dbgeng.Variable, type_index: u32, elem_declared: u64, frame: Frame, dynamic: *?[]const u8) !bool {
    var elem = elem_declared;
    const rank = d.dims.len;
    var desc_at = val.address;
    var t = type_index;
    // a pointer to the descriptor (an ALLOCATABLE's, a component's)
    if (s.engine.typeInfo(u32, v.mod_base, t, .symtag) == @backingInt(dbgeng.SymTag.pointer)) {
        var p: [8]u8 = undefined;
        if (s.engine.read(desc_at, &p) != 8) return error.Unreadable;
        desc_at = std.mem.readInt(u64, &p, .little);
        t = s.engine.typeInfo(u32, v.mod_base, t, .type) orelse t;
        if (desc_at == 0) {
            val.empty = true;
            val.rank = rank;
            return true;
        }
    }
    const described = isNamed(s, a, v.mod_base, t, "lfortran_array") or d.allocatable or d.pointer;
    if (!described) {
        if (!v.parameter) return false;
        // a dummy of assumed shape: its data, the extents beside it; else
        // (a CLASS array's) its descriptor
        if (try hiddenExtents(s, a, val, d, v.name, elem, frame)) return true;
    }
    var words: [header / 8 + 3 * 7]u64 = undefined;
    const want = header + 24 * rank;
    if (rank == 0 or rank > 7 or s.engine.read(desc_at, std.mem.sliceAsBytes(&words)[0..want]) != want) return error.Unreadable;
    const got_rank = (words[2] >> 32) & 0xff;
    if (got_rank != rank) return error.Unreadable;
    if (words[0] == 0) {
        val.empty = true;
        val.rank = rank;
        return true;
    }
    const offset: i64 = @bitCast(words[3]);
    var data: u64 = words[0];
    // a CLASS array's data: one box, of the elements' data and their
    // dynamic type, after `offset` boxes
    if (d.t.kind == .derived and d.t.polymorphic) {
        const b = (try classBox(s, a, @bitCast(@as(i64, @bitCast(data)) + offset * 16))) orelse return error.Unreadable;
        data = b.data;
        if (b.name) |n| if (try s.engine.typeNamed(a, v.mod_base, n)) |t_dyn| {
            dynamic.* = n;
            elem = s.engine.typeInfo(u64, v.mod_base, t_dyn, .length) orelse elem;
        };
        val.address = data;
    } else val.address = @bitCast(@as(i64, @bitCast(data)) + offset * @as(i64, @intCast(elem)));
    const extents = try a.alloc(values.Extent, rank);
    for (extents, 0..) |*e, k| {
        const dim = words[header / 8 + 3 * k ..][0..3];
        const length = dim[1];
        if (length > 1 << 40) return error.Unreadable;
        e.* = .{
            // an assumed-shape dummy's bounds are its declaration's
            .lo = if (!d.allocatable and !d.pointer) d.dims[k].lo orelse 1 else @bitCast(dim[0]),
            .count = length,
            .stride = @as(i64, @bitCast(dim[2])) * @as(i64, @intCast(elem)),
        };
    }
    return finish(val, extents);
}

/// A dummy of assumed shape whose extents LFortran passes beside its data
/// (`__1b`, `__2b` of `b`): `val` with them; false without them
fn hiddenExtents(s: *Session, a: Allocator, val: *Val, d: Decl, name: []const u8, elem: u64, frame: Frame) !bool {
    const extents = try a.alloc(values.Extent, d.dims.len);
    var stride: i64 = @intCast(elem);
    for (extents, 0..) |*e, k| {
        const n = try hidden(s, a, frame, try a.print("__{d}{s}", .{ k + 1, name }), 4) orelse return false;
        e.* = .{ .lo = d.dims[k].lo orelse 1, .count = n, .stride = stride };
        stride *= @intCast(n);
    }
    return finish(val, extents);
}

/// A CLASS object of LFortran's, its box: the address of its data, and its
/// dynamic type's name. The box is the address in its vtable after the
/// type's description (`@_VTable_tagged`, whose second word is
/// `@_Type_Info_tagged`, whose first points to `tagged`), then the data's.
pub fn classBox(s: *Session, a: Allocator, box: u64) !?struct { data: u64, name: ?[]const u8 } {
    var w: [2]u64 = undefined;
    if (s.engine.read(box, std.mem.sliceAsBytes(&w)) != 16 or w[1] == 0) return null;
    return .{ .data = w[1], .name = try className(s, a, w[0]) };
}

fn className(s: *Session, a: Allocator, vtable_at: u64) !?[]const u8 {
    if (vtable_at < 8) return null;
    var p: [8]u8 = undefined;
    if (s.engine.read(vtable_at - 8, &p) != 8) return null;
    const info = std.mem.readInt(u64, &p, .little);
    if (s.engine.read(info, &p) != 8) return null;
    var text: [128]u8 = undefined;
    const got = s.engine.read(std.mem.readInt(u64, &p, .little), &text);
    const end = std.mem.findScalar(u8, text[0..got], 0) orelse return null;
    for (text[0..end]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return if (end > 0) try a.dupe(u8, text[0..end]) else null;
}

fn finish(val: *Val, extents: []values.Extent) bool {
    val.extents = extents;
    val.rank = extents.len;
    val.count = extents[extents.len - 1].count;
    return true;
}

/// The value of a hidden argument of the frame (`__1a`, which holds the
/// address of an `i32` extent; `__libasr_len_s`, an `i64` itself), of
/// `bytes` bytes, or null when the frame has none of that name
fn hidden(s: *Session, a: Allocator, frame: Frame, name: []const u8, bytes: usize) !?u64 {
    for (try s.engine.variables(a, frame.thread, frame.index)) |v| {
        if (!std.mem.eql(u8, v.name, name)) continue;
        var b: [8]u8 = @splat(0);
        if (s.engine.read(v.address, &b) != 8) return null;
        var at = v.address;
        // a pointer to it
        if (s.engine.typeInfo(u32, v.mod_base, v.type_index, .symtag) == @backingInt(dbgeng.SymTag.pointer)) {
            at = std.mem.readInt(u64, &b, .little);
            b = @splat(0);
            if (s.engine.read(at, b[0..bytes]) != bytes) return null;
        }
        const n = std.mem.readInt(u64, &b, .little);
        return if (bytes == 4) @as(u32, @truncate(n)) else n;
    }
    return null;
}

fn isNamed(s: *Session, a: Allocator, mod_base: u64, type_index: u32, name: []const u8) bool {
    const n = s.engine.typeName(a, mod_base, type_index) orelse return false;
    return std.mem.eql(u8, n, name);
}

/// Whether the program is LFortran's: it has LFortran's runtime's function
/// that every program of LFortran's calls (asked once)
pub fn isProgram(s: *Session, a: Allocator) bool {
    if (s.lfortran == null) s.lfortran = (s.engine.global(a, lfortran.program_symbol) catch null) != null;
    return s.lfortran.?;
}
