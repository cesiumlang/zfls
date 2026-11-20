//! Values in a program's memory for `zfls dap`: a variable's, as its
//! declaration says (scalars, derived types, arrays through Intel's or
//! LLVM Flang's descriptors or of explicit shape), a derived type's components, a
//! module's variables, and the expressions of `evaluate`.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const objects = @import("../objects.zig");
const Obj = objects.Obj;
const values = @import("values.zig");
const dbgeng = @import("dbgeng.zig");

const session = @import("session.zig");
const Session = session.Session;
const Frame = session.Frame;
const Val = session.Val;
const declarations = @import("declarations.zig");
const Decl = declarations.Decl;
const declOf = declarations.declOf;
const frameVariables = declarations.frameVariables;
const typeDefinition = declarations.typeDefinition;

/// The value of a variable of the program, as Fortran declares it
pub fn valueOf(s: *Session, a: Allocator, v: dbgeng.Variable, decl: ?Decl, frame: Frame, expr: []const u8) !Val {
    var address = v.address;
    var type_index = v.type_index;
    // arguments: Intel passes their addresses
    const tag = s.engine.typeInfo(u32, v.mod_base, type_index, .symtag) orelse 0;
    if (v.parameter and tag == @backingInt(dbgeng.SymTag.pointer)) {
        var p: [8]u8 = undefined;
        if (s.engine.read(address, &p) == 8) address = std.mem.readInt(u64, &p, .little);
        type_index = s.engine.typeInfo(u32, v.mod_base, type_index, .type) orelse type_index;
    }
    // a scalar of a derived type: to the structure (a CLASS dummy is a
    // pointer to a pointer to it; LLVM Flang's is its descriptor, whose
    // first word is the pointer)
    const box = v.address;
    if (decl != null and decl.?.t.kind == .derived and decl.?.dims.len == 0) {
        for (0..2) |_| {
            if (s.engine.typeInfo(u32, v.mod_base, type_index, .symtag) != @backingInt(dbgeng.SymTag.pointer)) break;
            var p: [8]u8 = undefined;
            if (s.engine.read(address, &p) != 8) break;
            address = std.mem.readInt(u64, &p, .little);
            type_index = s.engine.typeInfo(u32, v.mod_base, type_index, .type) orelse break;
        }
    }
    const d = decl orelse return .{ .address = address, .t = rawType(s, v.mod_base, type_index), .expr = expr, .type_index = type_index, .mod_base = v.mod_base };
    var val: Val = .{ .address = address, .t = d.t, .expr = expr, .type_index = type_index, .mod_base = v.mod_base, .decl = d.obj };
    if (d.t.kind == .derived) val.type_index = try structure(s, a, v.mod_base, elementType(s, v.mod_base, type_index), d.t.name);
    if (d.t.kind == .derived and d.t.polymorphic and d.dims.len == 0) {
        var words: [4]u64 = undefined;
        if (s.engine.read(box, std.mem.sliceAsBytes(&words)) == @sizeOf(@TypeOf(words))) if (values.Descriptor.parse(&words)) |desc| {
            if (desc.rank == 0) try toDynamic(s, a, &val, desc.type_info, d);
        };
    }
    if (d.dims.len == 0) {
        // a deferred-length CHARACTER of Intel's (`character(len=:),
        // allocatable`): a descriptor of rank 0, CodeView's `LF_OEM`, of its
        // address and length; LLVM Flang's is a pointer, followed below
        if (d.t.kind == .character and d.t.size == 0 and (d.pointer or d.allocatable) and s.engine.typeInfo(u32, v.mod_base, type_index, .symtag) != @backingInt(dbgeng.SymTag.pointer)) {
            var words: [values.Descriptor.header_words]u64 = undefined;
            if (s.engine.read(address, std.mem.sliceAsBytes(&words)) != @sizeOf(@TypeOf(words))) return error.Unreadable;
            const desc = values.Descriptor.parse(&words) orelse return error.Unreadable;
            if (desc.rank != 0) return error.Unreadable;
            if (desc.empty()) {
                val.empty = true;
                return val;
            }
            val.address = desc.base;
            val.t.size = @intCast(@min(desc.elem_len, 1 << 20));
            return val;
        }
        // a POINTER or ALLOCATABLE scalar of LLVM Flang's: a pointer to it
        // (a derived type's is followed above)
        if ((d.pointer or d.allocatable) and d.t.kind != .derived and s.engine.typeInfo(u32, v.mod_base, type_index, .symtag) == @backingInt(dbgeng.SymTag.pointer)) {
            var p: [8]u8 = undefined;
            if (s.engine.read(address, &p) != 8) return error.Unreadable;
            val.address = std.mem.readInt(u64, &p, .little);
            val.type_index = s.engine.typeInfo(u32, v.mod_base, type_index, .type) orelse type_index;
        }
        if ((d.pointer or d.allocatable) and val.address == 0) {
            val.empty = true;
            return val;
        }
        if (d.t.kind == .character and d.t.size == 0) val.t.size = s.engine.typeInfo(u32, v.mod_base, val.type_index, .length) orelse 0;
        return val;
    }
    // arrays: Intel's or LLVM Flang's descriptor for those of deferred or
    // assumed shape
    if (d.allocatable or d.pointer or (!values.constantShape(d.dims) and dimsDeferred(d.dims))) {
        var words: [6 + 3 * 7]u64 = undefined;
        const got = s.engine.read(address, std.mem.sliceAsBytes(words[0..]));
        const desc = values.Descriptor.parse(words[0 .. got / 8]) orelse return error.Unreadable;
        if (desc.empty()) {
            val.empty = true;
            val.rank = d.dims.len;
            return val;
        }
        val.address = desc.base;
        if (val.t.kind == .character) val.t.size = @intCast(desc.elem_len);
        if (d.t.kind == .derived and d.t.polymorphic) try toDynamic(s, a, &val, desc.type_info, d);
        const extents = try a.dupe(values.Extent, desc.dims[0..desc.rank]);
        // an assumed-shape array's lower bounds are its declaration's (1
        // unless `a(0:)`), not those of the actual argument, which LLVM
        // Flang's descriptor keeps
        if (!d.allocatable and !d.pointer) for (extents, 0..) |*e, i| {
            if (i < d.dims.len) e.lo = d.dims[i].lo orelse 1;
        };
        val.extents = extents;
        val.rank = desc.rank;
        val.count = val.extents[val.rank - 1].count;
        return val;
    }
    // explicit shape: contiguous, its bounds numbers or the frame's integers
    const elem: u64 = if (val.t.kind == .derived) (s.engine.typeInfo(u64, v.mod_base, val.type_index, .length) orelse 0) else val.t.size;
    const dims = try a.dupe(values.Dim, d.dims);
    for (dims, d.dims) |*x, orig| {
        if (orig.hi == null) x.hi = try boundOf(s, a, frame, orig, true);
        if (orig.lo == null) x.lo = try boundOf(s, a, frame, orig, false);
    }
    if (!values.constantShape(dims)) return error.Unreadable;
    const ext = try a.alloc(values.Extent, dims.len);
    val.extents = values.contiguous(dims, elem, ext);
    val.rank = dims.len;
    val.count = val.extents[val.rank - 1].count;
    return val;
}

/// A CLASS object of LLVM Flang's as its dynamic type, whose description
/// its descriptor's addendum points at (`_QMgridEXdtXtagged`): dbghelp's
/// structure of that name, and zfls's definition, for its components
fn toDynamic(s: *Session, a: Allocator, val: *Val, type_info: u64, d: Decl) !void {
    if (type_info == 0) return;
    const symbol = s.engine.symbolAt(a, type_info) orelse return;
    const name = values.Descriptor.flangTypeName(symbol) orelse return;
    if (std.ascii.eqlIgnoreCase(name, val.t.name)) return;
    val.type_index = (try s.engine.typeNamed(a, val.mod_base, name)) orelse return;
    val.t.name = name;
    if (d.obj) |o| if (o.parent) |scope| {
        val.dynamic = typeDefinition(s, scope, name);
    };
}

fn dimsDeferred(dims: []const values.Dim) bool {
    for (dims) |d| if (d.lo == null and d.hi == null) return true;
    return false;
}

/// A bound that is a variable of the frame (`a(n)`): its value
fn boundOf(s: *Session, a: Allocator, frame: Frame, d: values.Dim, hi: bool) !?i64 {
    _ = d;
    _ = hi;
    _ = s;
    _ = a;
    _ = frame;
    return null;
}

/// dbghelp's structure with members of a derived type `name`, from the
/// type dbghelp gives a variable: itself, the definition of a forward
/// reference (Intel's descriptors' elements), or else the structure of
/// that name
fn structure(s: *Session, a: Allocator, mod_base: u64, type_index: u32, name: []const u8) !u32 {
    const t = try s.engine.definition(a, mod_base, type_index);
    if ((s.engine.typeInfo(u32, mod_base, t, .childrencount) orelse 0) > 0 or name.len == 0) return t;
    return (try s.engine.typeNamed(a, mod_base, name)) orelse t;
}

/// The type of an element (an array's) or the pointee
fn elementType(s: *Session, mod_base: u64, type_index: u32) u32 {
    var t = type_index;
    for (0..4) |_| {
        const tag = s.engine.typeInfo(u32, mod_base, t, .symtag) orelse return t;
        if (tag != @backingInt(dbgeng.SymTag.array) and tag != @backingInt(dbgeng.SymTag.pointer) and tag != @backingInt(dbgeng.SymTag.typedef)) return t;
        t = s.engine.typeInfo(u32, mod_base, t, .type) orelse return t;
    }
    return t;
}

/// The Fortran type of dbghelp's (without a declaration)
pub fn rawType(s: *Session, mod_base: u64, type_index: u32) values.Type {
    const tag = s.engine.typeInfo(u32, mod_base, type_index, .symtag) orelse return .{ .kind = .unknown };
    const len: u32 = @intCast(s.engine.typeInfo(u64, mod_base, type_index, .length) orelse 0);
    if (tag == @backingInt(dbgeng.SymTag.udt)) return .{ .kind = .derived, .size = len };
    if (tag != @backingInt(dbgeng.SymTag.base)) return .{ .kind = .unknown, .size = len };
    return switch (s.engine.typeInfo(u32, mod_base, type_index, .basetype) orelse 0) {
        8 => .{ .kind = .real, .size = len },
        10 => .{ .kind = .logical, .size = len },
        2 => .{ .kind = .character, .size = len },
        else => .{ .kind = .integer, .size = len },
    };
}

/// A derived type's components: dbghelp's members (their places), the
/// type's declaration (their Fortran types)
pub fn components(s: *Session, a: Allocator, v: Val) ![]Val {
    const members = try s.engine.members(a, v.mod_base, v.type_index);
    const def: ?*const Obj = v.dynamic orelse blk: {
        const d = v.decl orelse break :blk null;
        if (d.kind == .variable) if (d.varDataConst().type_obj) |t| break :blk t;
        break :blk if (d.parent) |scope| typeDefinition(s, scope, v.t.name) else null;
    };
    var out: std.ArrayList(Val) = .empty;
    for (members) |m| {
        const expr = try a.print("{s}%{s}", .{ v.expr, try std.ascii.allocLowerString(a, m.name) });
        const comp_decl: ?Decl = if (def) |t| blk: {
            for (t.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, m.name)) break :blk declOf(a, c);
            break :blk null;
        } else null;
        const mv: dbgeng.Variable = .{ .name = m.name, .address = v.address + m.offset, .size = 0, .type_index = m.type_index, .mod_base = v.mod_base, .parameter = false };
        const cv = valueOf(s, a, mv, comp_decl, .{ .thread = 0, .index = 0 }, expr) catch continue;
        var c = cv;
        if (comp_decl == null) {
            c.t = rawType(s, v.mod_base, m.type_index);
            // the parent of an extended type (`extends(point)`): a component
            // of its name, which the type does not declare; its type's
            // definition is found by that name from the extended type's
            if (c.t.kind == .derived and def != null) {
                c.t.name = try std.ascii.allocLowerString(a, m.name);
                c.decl = def;
            }
        }
        if (c.t.kind == .derived and c.t.name.len == 0) c.t.name = s.engine.typeName(a, v.mod_base, m.type_index) orelse "";
        try out.append(a, c);
    }
    return out.items;
}

/// A module variable's place: by the names Intel and LLVM Flang give it.
/// LLVM Flang's (`_QMgridEncells`) is a public symbol, without a type: the
/// variable's type is that of the variable of its own name (`ncells`) at
/// its address
pub fn moduleGlobal(s: *Session, a: Allocator, module: []const u8, name: []const u8) !?dbgeng.Variable {
    const intel = try a.print("{s}_mp_{s}", .{ try std.ascii.allocUpperString(a, module), try std.ascii.allocUpperString(a, name) });
    if (try s.engine.global(a, intel)) |v| return v;
    const lower = try std.ascii.allocLowerString(a, name);
    const flang = try a.print("_QM{s}E{s}", .{ try std.ascii.allocLowerString(a, module), lower });
    const v = (try s.engine.global(a, flang)) orelse return null;
    if (v.type_index == 0) if (try s.engine.dataAt(a, v.mod_base, lower, v.address)) |typed| return typed;
    return v;
}

/// An expression of a frame: a variable, its components and elements
/// (`p%x`, `a(2)`, `t%w(1)`), or a module's (`grid::cells`)
pub fn evaluate(s: *Session, a: Allocator, frame: Frame, expr: []const u8) !?Val {
    const text = std.mem.trim(u8, expr, " ");
    var parts = std.mem.splitScalar(u8, text, '%');
    const head = parts.first();
    const name_end = std.mem.findScalar(u8, head, '(') orelse head.len;
    const name = std.mem.trim(u8, head[0..name_end], " ");
    var v: Val = undefined;
    if (std.mem.find(u8, name, "::")) |sep| {
        const g = (try moduleGlobal(s, a, name[0..sep], name[sep + 2 ..])) orelse return null;
        v = try valueOf(s, a, g, null, frame, try std.ascii.allocLowerString(a, name));
    } else {
        const found = for (try frameVariables(s, a, frame)) |x| {
            if (std.ascii.eqlIgnoreCase(x.v.name, name)) break x;
        } else return null;
        v = try valueOf(s, a, found.v, found.decl, frame, try std.ascii.allocLowerString(a, name));
    }
    v = (try subscript(a, v, head[name_end..])) orelse return null;
    while (parts.next()) |p| {
        const pe = std.mem.findScalar(u8, p, '(') orelse p.len;
        const comp = std.mem.trim(u8, p[0..pe], " ");
        const comps = try components(s, a, v);
        v = for (comps) |c| {
            if (std.ascii.eqlIgnoreCase(c.expr[std.mem.findScalarLast(u8, c.expr, '%').? + 1 ..], comp)) break c;
        } else return null;
        v = (try subscript(a, v, p[pe..])) orelse return null;
    }
    v.expr = text;
    return v;
}

/// A substring of a CHARACTER scalar (`s(2:4)`, `s(3:)`, `s(:2)`), its
/// bounds integers within the string; null for anything else
fn substring(v: Val, range: []const u8) ?Val {
    if (v.t.kind != .character or v.empty) return null;
    const colon = std.mem.findScalar(u8, range, ':') orelse return null;
    const lo_text = std.mem.trim(u8, range[0..colon], " ");
    const hi_text = std.mem.trim(u8, range[colon + 1 ..], " ");
    const lo: i64 = if (lo_text.len == 0) 1 else std.fmt.parseInt(i64, lo_text, 10) catch return null;
    const hi: i64 = if (hi_text.len == 0) v.t.size else std.fmt.parseInt(i64, hi_text, 10) catch return null;
    if (lo < 1 or hi > v.t.size or hi < lo) return null;
    var out = v;
    out.address = v.address + @as(u64, @intCast(lo - 1));
    out.t.size = @intCast(hi - lo + 1);
    return out;
}

/// An element by its subscripts (`(2,-1)`), all of them integers
fn subscript(a: Allocator, v: Val, text: []const u8) !?Val {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return v;
    if (t[0] != '(' or t[t.len - 1] != ')') return null;
    if (v.rank == 0) return substring(v, t[1 .. t.len - 1]);
    var subs: std.ArrayList(i64) = .empty;
    var it = std.mem.splitScalar(u8, t[1 .. t.len - 1], ',');
    while (it.next()) |x| try subs.append(a, std.fmt.parseInt(i64, std.mem.trim(u8, x, " "), 10) catch return null);
    if (subs.items.len != v.rank) return null;
    var out = v;
    var offset: i64 = 0;
    for (subs.items, v.extents[0..v.rank]) |sub, e| {
        if (sub < e.lo or sub >= e.lo + @as(i64, @intCast(e.count))) return null;
        offset += (sub - e.lo) * e.stride;
    }
    out.address = @bitCast(@as(i64, @bitCast(v.address)) + offset);
    out.rank = 0;
    out.chosen = &.{};
    out.extents = &.{};
    return out;
}
