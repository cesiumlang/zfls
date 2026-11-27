//! The types of LFortran's variables in its IR (#366), for the CodeView
//! build: LFortran 0.69 types a variable as `float`, `integer` or a type of
//! size zero (an array, a derived type, a pointer), gives a procedure's
//! dummy arguments no entries and module variables none. Each variable's
//! storage is in the IR (its `alloca`, its global, the struct types), so
//! its type is written from there: structures named after their Fortran
//! types with the source's component names, arrays, pointers (to what the
//! procedure stores in them), LFortran's descriptors (`lfortran_array`,
//! `lfortran_dim`) and strings (`lfortran_string`). Dummy arguments are
//! the function's parameters, stored where the debugger finds them; module
//! variables (`@__module_grid_ncells`) and a program's saved variables
//! (`@main.v`) become globals of the debug information.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir_text = @import("ir_text.zig");
const dbgOf = ir_text.dbgOf;
const metadataId = ir_text.metadataId;
const field = ir_text.field;
const number = ir_text.number;
const splitLines = ir_text.splitLines;
const word = ir_text.word;
const objects = @import("../objects.zig");
const lines_patch = @import("lfortran_lines.zig");
const ir_types = @import("ir_types.zig");
const Ty = ir_types.Ty;
const Types = ir_types.Types;
const splitTop = ir_types.splitTop;
const writeType = ir_types.writeType;

/// A derived type of the source: its components' names, in order, and its
/// parent's name (`extends(point)`)
pub const TypeInfo = struct { name: []const u8, parent: ?[]const u8, components: []const []const u8 };

/// What the types need of the source
pub const Source = struct {
    types: []const TypeInfo,
    /// lowercase
    modules: []const []const u8,
    procs: []const lines_patch.Proc,
};

pub fn ofAst(a: Allocator, ast: *const objects.Ast, procs: []const lines_patch.Proc) !Source {
    var types: std.ArrayList(TypeInfo) = .empty;
    var modules: std.ArrayList([]const u8) = .empty;
    for (ast.scope_list.items) |sc| switch (sc.kind) {
        .type => {
            var comps: std.ArrayList([]const u8) = .empty;
            for (sc.childList()) |c| if (c.kind == .variable) try comps.append(a, try std.ascii.allocLowerString(a, c.name));
            const parent = sc.typeDataConst().inherit_tmp;
            try types.append(a, .{ .name = try std.ascii.allocLowerString(a, sc.name), .parent = if (parent) |p| try std.ascii.allocLowerString(a, p) else null, .components = comps.items });
        },
        .module => try modules.append(a, try std.ascii.allocLowerString(a, sc.name)),
        else => {},
    };
    return .{ .types = types.items, .modules = modules.items, .procs = procs };
}

/// The writer of the new metadata
const Meta = struct {
    a: Allocator,
    types: *Types,
    source: Source,
    out: std.ArrayList(u8) = .empty,
    next: u64,
    file: u64,
    /// IR type's text (or a key) → its DI type's id
    made: std.StringHashMapUnmanaged(u64) = .empty,

    fn id(m: *Meta) u64 {
        const n = m.next;
        m.next += 1;
        return n;
    }

    /// The DI type of an IR type, `pointee` the IR type a pointer holds
    fn of(m: *Meta, ty: Ty, pointee: ?Ty) Allocator.Error!u64 {
        const key = try m.keyOf(ty, pointee);
        if (m.made.get(key)) |n| return n;
        const n = switch (m.types.resolve(ty)) {
            .int => |bits| try m.basic(try m.a.print("integer({d})", .{@max(1, bits / 8)}), @max(8, bits), "DW_ATE_signed"),
            .float => try m.basic("real(4)", 32, "DW_ATE_float"),
            .double => try m.basic("real(8)", 64, "DW_ATE_float"),
            .ptr => blk: {
                const base: ?u64 = if (pointee) |p| try m.of(p, null) else null;
                const n = m.id();
                if (base) |b| try m.out.print(m.a, "!{d} = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !{d}, size: 64)\n", .{ n, b }) else try m.out.print(m.a, "!{d} = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: null, size: 64)\n", .{n});
                break :blk n;
            },
            .array => |arr| blk: {
                const e = try m.of(arr.elem.*, null);
                const n = m.id();
                const sub = m.id();
                try m.out.print(m.a, "!{d} = !DISubrange(count: {d})\n!{d} = !DICompositeType(tag: DW_TAG_array_type, baseType: !{d}, size: {d}, elements: !{{!{d}}})\n", .{ sub, arr.count, n, e, m.types.layout(ty).size * 8, sub });
                break :blk n;
            },
            .structure => |st| try m.structure(ty, st, structName(ty)),
            .named, .other => try m.basic("unknown", 8, "DW_ATE_unsigned"),
        };
        try m.made.put(m.a, key, n);
        return n;
    }

    /// A type's text, as the IR writes it, and a pointer's its pointee's
    fn keyOf(m: *Meta, ty: Ty, pointee: ?Ty) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try writeType(m.a, &out, ty);
        if (pointee) |p| {
            try out.appendSlice(m.a, "->");
            try writeType(m.a, &out, p);
        }
        return out.items;
    }

    fn basic(m: *Meta, name: []const u8, bits: u32, encoding: []const u8) !u64 {
        const n = m.id();
        try m.out.print(m.a, "!{d} = !DIBasicType(name: \"{s}\", size: {d}, encoding: {s})\n", .{ n, name, bits, encoding });
        return n;
    }

    /// A struct type: a derived type's (`%grid.point.3`, its source's
    /// component names), LFortran's descriptor, dimension and string, or
    /// fields by number
    fn structure(m: *Meta, ty: Ty, st: anytype, name_in: []const u8) Allocator.Error!u64 {
        const offs = try m.types.offsets(m.a, st);
        var names = try m.a.alloc([]const u8, st.fields.len);
        for (names, 0..) |*n, i| n.* = try m.a.print("f{d}", .{i});
        var name = name_in;
        if (std.mem.startsWith(u8, name, "%array")) {
            name = "lfortran_array";
            fieldNames(names, &.{ "data", "size", "type", "rank", "flag1", "flag2", "flag3", "offset", "dims" });
        } else if (std.mem.eql(u8, name, "%dimension_descriptor")) {
            name = "lfortran_dim";
            fieldNames(names, &.{ "lower_bound", "length", "stride" });
        } else if (std.mem.eql(u8, name, "%string_descriptor")) {
            name = "lfortran_string";
            fieldNames(names, &.{ "data", "len" });
        } else if (derivedName(name)) |dn| {
            name = dn;
            if (m.typeInfo(dn)) |info| {
                // its parent first (`%grid.point.3` in `%grid.tagged.4`)
                // (the parser's name of it, else its struct's type's)
                const parent = info.parent orelse if (st.fields.len > 0) derivedName(structName(st.fields[0])) else null;
                const skip: usize = if (parent != null and names.len == info.components.len + 1) 1 else 0;
                if (skip == 1) names[0] = parent.?;
                if (names.len == info.components.len + skip) for (info.components, 0..) |c, i| {
                    names[i + skip] = c;
                };
            }
        } else if (name.len == 0 or name[0] == '%') {
            name = if (name.len > 0) name[1..] else "struct";
        }
        // members before the structure that holds them
        const member_types = try m.a.alloc(u64, st.fields.len);
        for (st.fields, member_types) |f, *t| t.* = try m.of(f, null);
        const n = m.id();
        var elements: std.ArrayList(u8) = .empty;
        for (st.fields, member_types, offs, names, 0..) |f, t, o, mn, i| {
            const mid = m.id();
            try m.out.print(m.a, "!{d} = !DIDerivedType(tag: DW_TAG_member, name: \"{s}\", scope: !{d}, file: !{d}, baseType: !{d}, size: {d}, offset: {d})\n", .{ mid, mn, n, m.file, t, m.types.layout(f).size * 8, o * 8 });
            try elements.print(m.a, "{s}!{d}", .{ if (i > 0) ", " else "", mid });
        }
        try m.out.print(m.a, "!{d} = distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{s}\", file: !{d}, size: {d}, elements: !{{{s}}})\n", .{ n, name, m.file, m.types.layout(ty).size * 8, elements.items });
        return n;
    }

    fn typeInfo(m: *const Meta, name: []const u8) ?TypeInfo {
        for (m.source.types) |t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }
};

/// The first of `names` as `fixed`
fn fieldNames(names: [][]const u8, fixed: []const []const u8) void {
    for (names[0..@min(names.len, fixed.len)], fixed[0..@min(names.len, fixed.len)]) |*n, f| n.* = f;
}

/// The name of a named struct type (`%grid.point.3`), or ""
fn structName(ty: Ty) []const u8 {
    return switch (ty) {
        .named => |n| n,
        else => "",
    };
}

/// A derived type's name of LFortran's struct type: `%grid.point.3`,
/// `%main.t.1` give `point`, `t`
fn derivedName(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "%")) return null;
    var it = std.mem.splitScalar(u8, name[1..], '.');
    _ = it.next() orelse return null;
    const t = it.next() orelse return null;
    const n = it.next() orelse return null;
    if (it.next() != null or t.len == 0) return null;
    for (n) |c| if (!std.ascii.isDigit(c)) return null;
    return t;
}

/// `ir` with the types of its variables written from its storage; as it
/// was where it is not LFortran's as zfls knows it
pub fn patch(a: Allocator, ir: []const u8, source: Source) ![]const u8 {
    const lines = try splitLines(a, ir);
    var types: Types = .{ .a = a };
    var max_id: u64 = 0;
    var file: ?u64 = null;
    var cu: ?usize = null;
    // the IR's struct types, the metadata's ids, the file and the unit
    for (lines, 0..) |l, i| {
        if (l.len > 1 and l[0] == '%') if (std.mem.find(u8, l, " = type ")) |eq| {
            try types.defs.put(a, l[0..eq], try types.parse(l[eq + " = type ".len ..]));
        };
        const mid = metadataId(l) orelse continue;
        max_id = @max(max_id, mid);
        if (file == null and std.mem.find(u8, l, "= !DIFile(") != null) file = mid;
        if (cu == null and std.mem.find(u8, l, "= distinct !DICompileUnit(") != null) cu = i;
    }
    if (file == null or cu == null) return ir;
    var m: Meta = .{ .a = a, .types = &types, .source = source, .next = max_id + 1, .file = file.? };
    var out_lines = try a.dupe([]const u8, lines);
    // the variables' new types: their metadata line → the type's id
    var retyped: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    var globals: std.ArrayList(u64) = .empty;
    // after each line, the lines to insert
    var inserts: std.AutoHashMapUnmanaged(usize, []const u8) = .empty;
    var subprograms: std.AutoHashMapUnmanaged(u64, struct { name: []const u8, line: usize }) = .empty;
    for (lines) |l| if (metadataId(l)) |mid| if (std.mem.find(u8, l, "= distinct !DISubprogram(") != null) {
        try subprograms.put(a, mid, .{ .name = field(l, "name: \"", '"') orelse "", .line = number(field(l, "line: ", ',')) orelse 0 });
    };
    // module variables: `@__module_grid_ncells = global i32 42`
    for (lines, 0..) |l, i| {
        if (!std.mem.startsWith(u8, l, "@__module_")) continue;
        const eq = std.mem.find(u8, l, " = ") orelse continue;
        const symbol = l[1..eq];
        const rest = symbol["__module_".len..];
        const module = for (source.modules) |mod| {
            if (rest.len > mod.len + 1 and std.mem.startsWith(u8, rest, mod) and rest[mod.len] == '_') break mod;
        } else continue;
        const name = rest[module.len + 1 ..];
        const ty = globalType(l[eq + 3 ..]) orelse continue;
        const t = try m.of(try types.parse(ty), null);
        const g = try globalVariable(&m, name, symbol, false, t);
        try globals.append(a, g);
        out_lines[i] = try withDbg(a, l, g);
    }
    // each function: its variables' types, its dummy arguments
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        if (!std.mem.startsWith(u8, lines[i], "define ")) continue;
        const start = i;
        while (i < lines.len and !std.mem.eql(u8, lines[i], "}")) i += 1;
        const sp_id = dbgOf(lines[start]) orelse continue;
        const sp = subprograms.get(sp_id) orelse continue;
        const user = lines_patch.matching(source.procs, .{ .name = sp.name, .line = sp.line }) != null;
        // the allocas of the function, by name
        var allocas: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (start + 1..i) |j| {
            const t = std.mem.trimStart(u8, lines[j], " ");
            if (t.len == 0 or t[0] != '%') continue;
            const eq = std.mem.find(u8, t, " = alloca ") orelse continue;
            const ty_end = std.mem.findScalarPos(u8, t, eq + " = alloca ".len, ',') orelse t.len;
            try allocas.put(a, t[0..eq], t[eq + " = alloca ".len .. ty_end]);
        }
        for (start + 1..i) |j| {
            const t = std.mem.trimStart(u8, lines[j], " ");
            if (!std.mem.startsWith(u8, t, "#dbg_declare(ptr ")) continue;
            const rest = t["#dbg_declare(ptr ".len..];
            const comma = std.mem.findScalar(u8, rest, ',') orelse continue;
            const place = rest[0..comma];
            const var_id = number(field(rest, "!", ',')) orelse continue;
            if (place[0] == '@') {
                // a saved variable of the program (`@main.v`): a global
                const g_line = for (lines, 0..) |gl, k| {
                    if (std.mem.startsWith(u8, gl, place) and gl.len > place.len and gl[place.len] == ' ') break k;
                } else continue;
                const eq = std.mem.find(u8, lines[g_line], " = ") orelse continue;
                const ty = globalType(lines[g_line][eq + 3 ..]) orelse continue;
                const vname = variableName(lines, var_id) orelse continue;
                // of the file, local to it, as LLVM Flang's saved variables are
                const g = try globalVariable(&m, vname, place[1..], true, try m.of(try types.parse(ty), null));
                try globals.append(a, g);
                out_lines[g_line] = try withDbg(a, out_lines[g_line], g);
                continue;
            }
            const ty_text = allocas.get(place) orelse continue;
            const ty = try types.parse(ty_text);
            // scalars keep LFortran's types
            switch (types.resolve(ty)) {
                .int, .float, .double => continue,
                else => {},
            }
            const pointee: ?Ty = if (ty == .ptr) try storedType(a, &types, lines[start + 1 .. i], place, &allocas) else null;
            try retyped.put(a, var_id, try m.of(ty, pointee));
        }
        if (user) if (try arguments(&m, lines[start], sp_id, sp.line)) |text| {
            const entry = for (start + 1..i) |j| {
                if (std.mem.eql(u8, lines[j], ".entry:")) break j;
            } else start;
            try inserts.put(a, entry, text);
        };
    }
    // the variables' lines with their types, and the unit's globals
    for (lines, 0..) |l, k| {
        const mid = metadataId(l) orelse continue;
        if (retyped.get(mid)) |t| out_lines[k] = try retype(a, out_lines[k], t);
    }
    if (globals.items.len > 0) {
        const g = m.id();
        var list: std.ArrayList(u8) = .empty;
        for (globals.items, 0..) |x, k| try list.print(a, "{s}!{d}", .{ if (k > 0) ", " else "", x });
        try m.out.print(a, "!{d} = !{{{s}}}\n", .{ g, list.items });
        const cu_line = out_lines[cu.?];
        const close = std.mem.findScalarLast(u8, cu_line, ')') orelse return ir;
        out_lines[cu.?] = try a.print("{s}, globals: !{d}{s}", .{ cu_line[0..close], g, cu_line[close..] });
    }
    var out: std.ArrayList(u8) = .empty;
    for (out_lines, 0..) |l, k| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
        if (inserts.get(k)) |text| try out.appendSlice(a, text);
    }
    try out.appendSlice(a, m.out.items);
    return out.items;
}

/// A dummy argument for each named parameter of a function (its `define`
/// line), stored at the start of its entry block where the debugger finds
/// it: the lines to insert there, or null for none
fn arguments(m: *Meta, define: []const u8, sp_id: u64, line: usize) !?[]const u8 {
    const open = std.mem.findScalar(u8, define, '(') orelse return null;
    const close = std.mem.findScalarLast(u8, define[0 .. std.mem.findScalarLast(u8, define, '{') orelse define.len], ')') orelse return null;
    if (close <= open) return null;
    var text: std.ArrayList(u8) = .empty;
    const loc = m.id();
    try m.out.print(m.a, "!{d} = !DILocation(line: {d}, scope: !{d})\n", .{ loc, line, sp_id });
    var arg: usize = 0;
    for (try splitTop(m.a, define[open + 1 .. close])) |p_in| {
        arg += 1;
        const p = std.mem.trim(u8, p_in, " ");
        const sp_at = std.mem.findScalarLast(u8, p, ' ') orelse continue;
        const name = p[sp_at + 1 ..];
        if (name.len < 2 or name[0] != '%' or std.ascii.isDigit(name[1])) continue;
        const ty_text = std.mem.trim(u8, p[0..sp_at], " ");
        const ty = try m.types.parse(ty_text);
        const t = try m.of(ty, null);
        const v = m.id();
        try m.out.print(m.a, "!{d} = !DILocalVariable(name: \"{s}\", arg: {d}, scope: !{d}, file: !{d}, line: {d}, type: !{d})\n", .{ v, name[1..], arg, sp_id, m.file, line, t });
        try text.print(m.a, "  {s}.zfls = alloca {s}, align 8\n  store {s} {s}, ptr {s}.zfls, align 8\n    #dbg_declare(ptr {s}.zfls, !{d}, !DIExpression(), !{d})\n", .{ name, ty_text, ty_text, name, name, name, v, loc });
    }
    return if (text.items.len > 0) text.items else null;
}

/// The IR type a procedure stores in the pointer `place`: that of the
/// alloca it stores there (`store ptr %arr_desc, ptr %big`)
fn storedType(a: Allocator, types: *Types, body: []const []const u8, place: []const u8, allocas: *const std.StringHashMapUnmanaged([]const u8)) !?Ty {
    const want = try a.print(", ptr {s},", .{place});
    for (body) |l| {
        const t = std.mem.trimStart(u8, l, " ");
        if (!std.mem.startsWith(u8, t, "store ptr %")) continue;
        const at = std.mem.find(u8, t, want) orelse continue;
        const value = t["store ptr ".len..at];
        if (allocas.get(value)) |ty| return try types.parse(ty);
    }
    return null;
}

/// A global variable of the debug information, `local` a program's saved
/// variable: its expression's id
fn globalVariable(m: *Meta, name: []const u8, linkage: []const u8, local: bool, t: u64) !u64 {
    const v = m.id();
    const e = m.id();
    try m.out.print(m.a, "!{d} = distinct !DIGlobalVariable(name: \"{s}\", linkageName: \"{s}\", scope: !{d}, file: !{d}, type: !{d}, isLocal: {}, isDefinition: true)\n!{d} = !DIGlobalVariableExpression(var: !{d}, expr: !DIExpression())\n", .{ v, name, linkage, m.file, m.file, t, local, e, v });
    return e;
}

/// The type of a global's definition: `internal global [3 x float] ...`
fn globalType(def: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, def, "global ") orelse return null;
    const rest = def[at + "global ".len ..];
    // up to its initializer: the type's brackets balanced, then a blank
    var depth: usize = 0;
    for (rest, 0..) |c, i| switch (c) {
        '{', '[', '<' => depth += 1,
        '}', ']', '>' => depth -|= 1,
        ' ' => if (depth == 0) return rest[0..i],
        else => {},
    };
    return null;
}

/// The name of the DILocalVariable `id`
fn variableName(lines: []const []const u8, id: u64) ?[]const u8 {
    for (lines) |l| if (metadataId(l) == id) return field(l, "name: \"", '"');
    return null;
}

/// A global's definition with its debug information
fn withDbg(a: Allocator, l: []const u8, g: u64) ![]const u8 {
    return a.print("{s}, !dbg !{d}", .{ l, g });
}

/// A DILocalVariable's line with the type `t`
fn retype(a: Allocator, l: []const u8, t: u64) ![]const u8 {
    const at = (std.mem.find(u8, l, "type: !") orelse return l) + "type: !".len;
    var e = at;
    while (e < l.len and std.ascii.isDigit(l[e])) e += 1;
    return a.print("{s}{d}{s}", .{ l[0..at], t, l[e..] });
}

const testing = std.testing;

test "LFortran's variables typed from its IR: derived types, descriptors, dummies, module variables (#366)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "module grid\n  type :: point\n    real :: x, y\n    integer :: id\n  end type\n  type, extends(point) :: labeled\n    integer :: label\n  end type\n  integer :: ncells = 42\ncontains\n  subroutine work(p, n)\n    type(point) :: p\n    integer :: n\n  end subroutine\nend module\n";
    const parsed = try lines_patch.parse(a, testing.io, "/w/grid.f90", source);
    const src = try ofAst(a, parsed.ast, try lines_patch.ofParsed(a, parsed.file, parsed.ast));
    // as LFortran 0.69.0 writes them, shortened
    const ir =
        \\%grid.point.3 = type { float, float, i32 }
        \\%grid.labeled.5 = type { %grid.point.3, i32 }
        \\%array.1 = type { ptr, i64, i32, i8, i8, i8, i8, i64, [1 x %dimension_descriptor] }
        \\%dimension_descriptor = type { i64, i64, i64 }
        \\@__module_grid_ncells = global i32 42
        \\
        \\define void @__module_grid_work(ptr %p, ptr %n) !dbg !3 {
        \\.entry:
        \\  %lb = alloca %grid.labeled.5, align 8, !dbg !5
        \\    #dbg_declare(ptr %lb, !6, !DIExpression(), !5)
        \\  %d = alloca %array.1, align 8, !dbg !5
        \\  %big = alloca ptr, align 8
        \\  store ptr %d, ptr %big, align 8
        \\    #dbg_declare(ptr %big, !7, !DIExpression(), !5)
        \\  ret void, !dbg !5
        \\}
        \\
        \\!0 = distinct !DICompileUnit(language: DW_LANG_C, file: !1, emissionKind: FullDebug)
        \\!1 = !DIFile(filename: "grid.f90", directory: ".")
        \\!3 = distinct !DISubprogram(name: "work", scope: !1, file: !1, line: 11, unit: !0)
        \\!4 = !DIBasicType(name: "non-specified-debug-type-SIZE-set-to-ZERO", encoding: DW_ATE_unsigned)
        \\!5 = !DILocation(line: 11, scope: !3)
        \\!6 = !DILocalVariable(name: "lb", scope: !3, file: !1, line: 11, type: !4)
        \\!7 = !DILocalVariable(name: "big", scope: !3, file: !1, line: 11, type: !4)
        \\
    ;
    const out = try patch(a, ir, src);
    for ([_][]const u8{
        // the derived types, by their names, with the components' and the parent's
        "name: \"labeled\", file: !1, size: 128",
        "name: \"point\", scope: ",
        "name: \"label\", scope: ",
        "name: \"x\", scope: ",
        "name: \"id\", scope: ",
        // LFortran's descriptor, and a pointer to it
        "name: \"lfortran_array\", file: !1, size: 448",
        "name: \"stride\", scope: ",
        "DW_TAG_pointer_type, baseType: !",
        // the dummy arguments, stored where the debugger finds them
        "  %p.zfls = alloca ptr, align 8\n  store ptr %p, ptr %p.zfls, align 8\n",
        "!DILocalVariable(name: \"n\", arg: 2, scope: !3",
        // the module variable, of the unit
        "@__module_grid_ncells = global i32 42, !dbg !",
        "!DIGlobalVariable(name: \"ncells\", linkageName: \"__module_grid_ncells\"",
        "emissionKind: FullDebug, globals: !",
    }) |want| try h(out, want);
    // the variables' zero-size types are gone
    try testing.expect(std.mem.find(u8, out, "!6 = !DILocalVariable(name: \"lb\", scope: !3, file: !1, line: 11, type: !4)") == null);
}

fn h(out: []const u8, want: []const u8) !void {
    if (std.mem.find(u8, out, want) == null) {
        std.debug.print("not in the patched IR: {s}\n{s}\n", .{ want, out });
        return error.TestUnexpectedResult;
    }
}
