//! The variables of the gdb backend of `zfls dap`, as Fortran: gdb's
//! variables and values reshaped (fortran.zig reads them): array elements
//! by their subscripts and large arrays in sections, an expression for
//! each variable (Add to Watch, Copy as Expression, setting values),
//! previews of arrays and derived types, "not allocated" and "not
//! associated", pointers as their targets, a polymorphic object (CLASS)
//! with the components of its dynamic type, gfortran's hidden lengths of
//! CHARACTER arguments left out, and the module variables that a frame's
//! line sees (zfls's index of the sources).
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const fortran = @import("fortran.zig");
const ArrayContext = fortran.ArrayContext;
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const gdb = @import("gdb.zig");

/// A frame of a stack trace: its file and line
pub const FrameInfo = struct { file: ?[]const u8, line: i64 };

/// A module variable as a line sees it (`zfls/moduleVariables`)
pub const ModuleVariable = struct {
    /// The module that declares it
    module: []const u8,
    /// Its name there
    name: []const u8,
    /// Its name at the line (a USE may rename it)
    local: []const u8,
    /// Its type (`REAL(8)`, `TYPE(grid)`, ...)
    type: []const u8,
};

/// What the backend knows of a node's place, for its children
pub const Context = struct {
    /// The node's expression: its components' are `expr%name`
    evaluate_name: ?[]const u8 = null,
    /// The node's place in an array, for an array or a column of one
    array: ?ArrayContext = null,
    /// Its elements, for an array
    count: ?u64 = null,
    /// The node is gdb's scope of registers: `$rax`
    registers: bool = false,
    /// For a polymorphic object shown as its dynamic type: the components
    /// of its declared type, which the object's expression names
    /// (`t%_data%x`) while the others need gdb's pointer to it
    declared: ?Declared = null,
};

pub const Declared = struct { expr: []const u8, names: []const []const u8 };

/// A child's name as shown, to gdb's name and the expression
pub const Named = struct { shown: []const u8, gdb_name: []const u8, evaluate_name: ?[]const u8 };

/// What a variable reference of the backend stands for
pub const Node = struct {
    kind: union(enum) {
        /// gdb's reference
        gdb: i64,
        /// A section of an array, by its expression
        section: []const u8,
        /// A section of more than 100 elements, in sections: its count
        chunks: u64,
        modules: []const ModuleVariable,
        module: []const ModuleVariable,
    },
    frame: ?i64 = null,
    ctx: Context = .{},
    /// The children as last listed
    names: []const Named = &.{},
};

/// A variable of the protocol, gdb's or as shown
pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    type: ?[]const u8 = null,
    ref: i64 = 0,
    evaluate_name: ?[]const u8 = null,
    indexed: ?i64 = null,
    hint: ?Value = null,
    memory_reference: ?[]const u8 = null,

    pub fn fromGdb(v: Value) Variable {
        return .{
            .name = json.str(json.get(v, "name")) orelse "",
            .value = json.str(json.get(v, "value")) orelse "",
            .type = json.str(json.get(v, "type")),
            .ref = json.int(json.get(v, "variablesReference")) orelse 0,
            .evaluate_name = json.str(json.get(v, "evaluateName")),
            .indexed = json.int(json.get(v, "indexedVariables")),
            .hint = json.get(v, "presentationHint"),
            .memory_reference = json.str(json.get(v, "memoryReference")),
        };
    }

    pub fn toJson(v: Variable, a: Allocator) !Value {
        var o: json.ObjectMap = .empty;
        try o.put(a, "name", .{ .string = v.name });
        try o.put(a, "value", .{ .string = v.value });
        if (v.type) |t| try o.put(a, "type", .{ .string = t });
        try o.put(a, "variablesReference", .{ .integer = v.ref });
        if (v.evaluate_name) |e| try o.put(a, "evaluateName", .{ .string = e });
        if (v.hint) |h| if (h != .null) try o.put(a, "presentationHint", h);
        if (v.memory_reference) |m| try o.put(a, "memoryReference", .{ .string = m });
        return .{ .object = o };
    }
};

// Nodes

fn arena(s: *Session) Allocator {
    if (s.g.nodes_arena == null) s.g.nodes_arena = .init(s.gpa);
    return s.g.nodes_arena.?.allocator();
}

/// A node, its slices copied to the nodes' memory: its reference
pub fn add(s: *Session, n: Node) !i64 {
    const na = arena(s);
    var out = n;
    out.kind = switch (n.kind) {
        .gdb, .chunks => n.kind,
        .section => |e| .{ .section = try na.dupe(u8, e) },
        .modules => |vs| .{ .modules = try dupeVars(na, vs) },
        .module => |vs| .{ .module = try dupeVars(na, vs) },
    };
    out.ctx = .{
        .evaluate_name = if (n.ctx.evaluate_name) |e| try na.dupe(u8, e) else null,
        .array = if (n.ctx.array) |c| try c.dupe(na) else null,
        .count = n.ctx.count,
        .registers = n.ctx.registers,
        .declared = if (n.ctx.declared) |d| .{ .expr = try na.dupe(u8, d.expr), .names = try dupeStrings(na, d.names) } else null,
    };
    out.names = &.{};
    try s.g.nodes.append(s.gpa, out);
    return s.g.node_base + @as(i64, @intCast(s.g.nodes.items.len));
}

fn dupeVars(na: Allocator, vs: []const ModuleVariable) ![]const ModuleVariable {
    const out = try na.alloc(ModuleVariable, vs.len);
    for (vs, out) |v, *o| o.* = .{ .module = try na.dupe(u8, v.module), .name = try na.dupe(u8, v.name), .local = try na.dupe(u8, v.local), .type = try na.dupe(u8, v.type) };
    return out;
}

fn dupeStrings(na: Allocator, xs: []const []const u8) ![]const []const u8 {
    const out = try na.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = try na.dupe(u8, x);
    return out;
}

pub fn get(s: *Session, ref: i64) ?Node {
    const i = ref - s.g.node_base - 1;
    if (i < 0 or i >= s.g.nodes.items.len) return null;
    return s.g.nodes.items[@intCast(i)];
}

fn setNames(s: *Session, ref: i64, vs: []const Variable, gdb_names: []const []const u8) !void {
    const i = ref - s.g.node_base - 1;
    if (i < 0 or i >= s.g.nodes.items.len) return;
    const na = arena(s);
    const names = try na.alloc(Named, vs.len);
    for (vs, gdb_names, names) |v, g, *n| n.* = .{
        .shown = try na.dupe(u8, v.name),
        .gdb_name = try na.dupe(u8, g),
        .evaluate_name = if (v.evaluate_name) |e| try na.dupe(u8, e) else null,
    };
    s.g.nodes.items[@intCast(i)].names = names;
}

/// The program went on: its variables, and the frames, are gone. Their
/// memory lasts until the next request, as one may be using it.
pub fn clear(s: *Session) void {
    if (s.g.nodes_arena) |n| {
        s.g.retired.append(s.gpa, n) catch {
            var x = n;
            x.deinit();
        };
        s.g.nodes_arena = null;
    }
    s.g.node_base += @intCast(s.g.nodes.items.len);
    s.g.nodes.clearRetainingCapacity();
    s.g.frames.clearRetainingCapacity();
}

/// Frees the nodes cleared, between requests
pub fn freeRetired(s: *Session) void {
    for (s.g.retired.items) |*r| r.deinit();
    s.g.retired.clearRetainingCapacity();
}

/// Keeps a frame's file and line, for its module variables
pub fn keepFrame(s: *Session, id: i64, file: ?[]const u8, line: i64) !void {
    try s.g.frames.put(s.gpa, id, .{ .file = if (file) |f| try arena(s).dupe(u8, f) else null, .line = line });
}

// gdb

/// The arguments of an `evaluate`, of a frame when there is one
pub fn evalArgs(a: Allocator, expression: []const u8, frame: ?i64, context: []const u8) !Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "expression", .{ .string = expression });
    if (frame) |f| try o.put(a, "frameId", .{ .integer = f });
    try o.put(a, "context", .{ .string = context });
    return .{ .object = o };
}

fn gdbChildren(s: *Session, a: Allocator, ref: i64) ![]Variable {
    const r = try gdb.request(s, a, "variables", .{ .variablesReference = ref });
    if (!gdb.isSuccess(r)) {
        s.g.failure = json.str(json.get(r, "message")) orelse "variables";
        return error.GdbFailed;
    }
    const items = json.items(json.path(r, &.{ "body", "variables" }));
    const out = try a.alloc(Variable, items.len);
    for (items, out) |v, *o| o.* = .fromGdb(v);
    return out;
}

fn hiddenFilter(a: Allocator, kids: []const Variable) ![]Variable {
    const named = try a.alloc(fortran.Named, kids.len);
    for (kids, named) |k, *n| n.* = .{ .name = k.name, .type = k.type };
    var out: std.ArrayList(Variable) = .empty;
    for (kids) |k| if (!fortran.isHiddenLength(k.name, named)) try out.append(a, k);
    return out.items;
}

// Children

/// The children of node `ref`, as shown
pub fn children(s: *Session, a: Allocator, ref: i64, node: Node) anyerror![]Variable {
    switch (node.kind) {
        .modules => |vars| {
            var out: std.ArrayList(Variable) = .empty;
            var done: std.ArrayList([]const u8) = .empty;
            for (vars) |v| {
                const listed = for (done.items) |m| {
                    if (std.ascii.eqlIgnoreCase(m, v.module)) break true;
                } else false;
                if (listed) continue;
                try done.append(a, v.module);
                var group: std.ArrayList(ModuleVariable) = .empty;
                for (vars) |w| if (std.ascii.eqlIgnoreCase(w.module, v.module)) try group.append(a, w);
                try out.append(a, .{
                    .name = v.module,
                    .value = "",
                    .ref = try add(s, .{ .kind = .{ .module = group.items }, .frame = node.frame }),
                    .hint = try json.from(a, .{ .kind = "class" }),
                });
            }
            return out.items;
        },
        .module => |vars| {
            const out = try a.alloc(Variable, vars.len);
            const names = try a.alloc([]const u8, vars.len);
            for (vars, out, names) |v, *o, *n| {
                o.* = try moduleVariable(s, a, v, node.frame);
                n.* = o.name;
            }
            try setNames(s, ref, out, names);
            return out;
        },
        .chunks => |count| {
            const cs = try fortran.chunks(a, count);
            const out = try a.alloc(Variable, cs.len);
            for (cs, out) |c, *o| o.* = try chunk(s, a, node.ctx.array.?, c, node.frame);
            return out;
        },
        .section => |expr| {
            const r = try gdb.request(s, a, "evaluate", try evalArgs(a, expr, node.frame, "watch"));
            const gref = json.int(json.path(r, &.{ "body", "variablesReference" })) orelse 0;
            if (!gdb.isSuccess(r) or gref == 0) return &.{};
            return convertAndRecord(s, a, ref, try gdbChildren(s, a, gref), node);
        },
        .gdb => |gref| {
            // a large array in sections, when it has an expression
            if (node.ctx.array) |array| if (array.expr != null and (node.ctx.count orelse 0) > fortran.chunk_size) {
                const cs = try fortran.chunks(a, node.ctx.count.?);
                const out = try a.alloc(Variable, cs.len);
                for (cs, out) |c, *o| o.* = try chunk(s, a, array, c, node.frame);
                return out;
            };
            return convertAndRecord(s, a, ref, try gdbChildren(s, a, gref), node);
        },
    }
}

fn convertAndRecord(s: *Session, a: Allocator, ref: i64, kids: []const Variable, node: Node) ![]Variable {
    const shown = try hiddenFilter(a, kids);
    const out = try a.alloc(Variable, shown.len);
    const names = try a.alloc([]const u8, shown.len);
    for (shown, out, names) |k, *o, *n| {
        o.* = try convert(s, a, k, node.ctx, node.frame);
        n.* = k.name;
    }
    try setNames(s, ref, out, names);
    return out;
}

/// gdb's child of a node as shown: its Fortran name and expression
fn convert(s: *Session, a: Allocator, k: Variable, parent: Context, frame: ?i64) !Variable {
    if (parent.array) |array| {
        const e = try fortran.element(a, array, k.name);
        return present(s, a, k, e.name, e.evaluate_name, frame, e.sub, null);
    }
    const evaluate_name: []const u8 = blk: {
        if (parent.registers) break :blk try a.print("${s}", .{k.name});
        if (parent.declared) |d| for (d.names) |n| {
            if (std.ascii.eqlIgnoreCase(n, k.name)) break :blk try a.print("{s}%{s}", .{ d.expr, k.name });
        };
        if (parent.evaluate_name) |e| break :blk try a.print("{s}%{s}", .{ e, k.name });
        break :blk k.name;
    };
    return present(s, a, k, k.name, evaluate_name, frame, null, null);
}

/// A section of an array, shown as a node of its elements
fn chunk(s: *Session, a: Allocator, array: ArrayContext, c: fortran.Chunk, frame: ?i64) !Variable {
    const section = try fortran.chunkSection(a, array, c);
    const ctx: Context = .{ .evaluate_name = section.evaluate_name, .array = try fortran.chunkContext(a, array, c), .count = c.count };
    const ref = if (c.count > fortran.chunk_size)
        try add(s, .{ .kind = .{ .chunks = c.count }, .frame = frame, .ctx = ctx })
    else
        try add(s, .{ .kind = .{ .section = section.evaluate_name.? }, .frame = frame, .ctx = ctx });
    return .{ .name = section.name, .value = "", .ref = ref, .evaluate_name = section.evaluate_name };
}

fn moduleVariable(s: *Session, a: Allocator, v: ModuleVariable, frame: ?i64) !Variable {
    const label = if (std.ascii.eqlIgnoreCase(v.local, v.name)) v.local else try a.print("{s} => {s}", .{ v.local, v.name });
    const expr = try a.print("{s}::{s}", .{ try std.ascii.allocLowerString(a, v.module), try std.ascii.allocLowerString(a, v.name) });
    const r = try gdb.request(s, a, "evaluate", try evalArgs(a, expr, frame, "watch"));
    const result = json.str(json.path(r, &.{ "body", "result" }));
    if (!gdb.isSuccess(r) or result == null) return .{ .name = label, .value = s.text.not_available, .type = v.type };
    return present(s, a, .{
        .name = label,
        .value = result.?,
        .type = json.str(json.path(r, &.{ "body", "type" })),
        .ref = json.int(json.path(r, &.{ "body", "variablesReference" })) orelse 0,
    }, label, expr, frame, null, null);
}

// Values

/// A variable of gdb as shown: its value, and a node for its children
pub fn present(s: *Session, a: Allocator, gv: Variable, name: []const u8, evaluate_name: ?[]const u8, frame: ?i64, sub: ?ArrayContext, declared: ?Declared) anyerror!Variable {
    var v = gv;
    v.type = fortran.fortranType(v.type);
    var out: Variable = .{ .name = name, .value = v.value, .type = v.type, .evaluate_name = evaluate_name, .hint = v.hint, .memory_reference = v.memory_reference };

    if (fortran.isClassWrapper(v.type) and v.ref != 0) return presentClass(s, a, v, out, frame);
    // a pointer, as its target
    if (fortran.pointerTarget(v.type) != null) {
        if (fortran.isNullPointer(v.value)) {
            out.value = s.text.not_associated;
            return out;
        }
        if (v.ref != 0) {
            const kids = try gdbChildren(s, a, v.ref);
            if (kids.len == 1 and std.mem.eql(u8, kids[0].name, "value")) return present(s, a, kids[0], name, evaluate_name, frame, sub, declared);
        }
        out.ref = try nodeOf(s, v, frame, .{ .evaluate_name = evaluate_name }, declared);
        return out;
    }
    const at = try fortran.arrayType(a, v.type);
    // a string whose type reads as an array of characters (a dummy's of
    // assumed length, in gdb 15): gdb's value is the string
    if (at != null and sub == null and v.value.len > 0 and v.value[0] == '\'') return out;
    if (at != null or sub != null) {
        if (at) |t| if (sub == null and fortran.isUnallocated(t)) {
            out.value = if (t.allocatable) s.text.not_allocated else s.text.not_associated;
            return out;
        };
        const ctx: ArrayContext = sub orelse .{ .expr = evaluate_name, .dims = at.?.dims };
        const count: u64 = if (v.indexed) |n| @intCast(@max(n, 0)) else fortran.extent(fortran.indexedDim(ctx)) orelse 0;
        out.value = try arrayValue(s, a, v, ctx, count, frame);
        out.ref = try nodeOf(s, v, frame, .{ .evaluate_name = evaluate_name, .array = ctx, .count = count }, declared);
        return out;
    }
    if (fortran.derivedTypeName(v.type)) |type_name| if (v.ref != 0) {
        const shown = try hiddenFilter(a, try gdbChildren(s, a, v.ref));
        const comps = try a.alloc(fortran.Component, shown.len);
        for (shown, comps) |k, *c| c.* = .{ .name = k.name, .value = try short(a, k) };
        out.value = try fortran.structPreview(a, type_name, comps);
        out.ref = try nodeOf(s, v, frame, .{ .evaluate_name = evaluate_name }, declared);
        return out;
    };
    out.value = try fortran.fortranNumber(a, v.value, v.type);
    out.ref = try nodeOf(s, v, frame, .{ .evaluate_name = evaluate_name }, declared);
    return out;
}

fn nodeOf(s: *Session, v: Variable, frame: ?i64, ctx: Context, declared: ?Declared) !i64 {
    if (v.ref == 0) return 0;
    var c = ctx;
    if (declared) |d| c.declared = d;
    return add(s, .{ .kind = .{ .gdb = v.ref }, .frame = frame, .ctx = c });
}

/// The preview of an array: its first elements, or its shape
fn arrayValue(s: *Session, a: Allocator, v: Variable, ctx: ArrayContext, count: u64, frame: ?i64) ![]const u8 {
    const rank = fortran.rankOf(ctx);
    if (rank > 1) return fortran.shapePreview(a, ctx.dims[0..rank]);
    if (count == 0) return "[]";
    var kids: []Variable = &.{};
    if (count <= fortran.chunk_size and v.ref != 0) {
        kids = try gdbChildren(s, a, v.ref);
    } else if (ctx.expr != null) {
        const first = try fortran.chunkSection(a, ctx, .{ .start = 0, .count = @min(count, 6) });
        const r = try gdb.request(s, a, "evaluate", try evalArgs(a, first.evaluate_name.?, frame, "watch"));
        const ref = json.int(json.path(r, &.{ "body", "variablesReference" })) orelse 0;
        if (gdb.isSuccess(r) and ref != 0) kids = try gdbChildren(s, a, ref);
    }
    if (kids.len == 0) return a.print("[{d}]", .{count});
    const shown = try a.alloc([]const u8, kids.len);
    for (kids, shown) |k, *o| o.* = try short(a, k);
    return fortran.arrayPreview(a, shown, count);
}

/// A polymorphic object: its dynamic type's components, through a pointer
/// of gdb's to it, as gdb shows only the declared type's
fn presentClass(s: *Session, a: Allocator, v: Variable, out_in: Variable, frame: ?i64) !Variable {
    var out = out_in;
    const kids = try gdbChildren(s, a, v.ref);
    const data = find(kids, "_data") orelse {
        out.ref = try add(s, .{ .kind = .{ .gdb = v.ref }, .frame = frame, .ctx = .{ .evaluate_name = out.evaluate_name } });
        return out;
    };
    const vptr = find(kids, "_vptr");
    const declared_name = fortran.derivedTypeName(fortran.pointerTarget(data.type));
    const type_name = if (declared_name) |d| try a.print("class({s})", .{d}) else out.type;
    if (fortran.isNullPointer(data.value)) {
        out.type = type_name;
        out.value = s.text.not_allocated;
        return out;
    }
    const data_expr: ?[]const u8 = if (out.evaluate_name) |e| try a.print("{s}%_data", .{e}) else null;
    const dynamic = if (vptr) |p| try fortran.dynamicType(a, p.value) else null;
    const address = fortran.addressOf(data.value);
    if (dynamic != null and address != null and (declared_name == null or !std.ascii.eqlIgnoreCase(dynamic.?.name, declared_name.?))) {
        s.g.convenience += 1;
        const variable = try a.print("zfls_{d}", .{s.g.convenience});
        const set = try gdb.request(s, a, "evaluate", try evalArgs(a, try fortran.castCommand(a, variable, address.?, dynamic.?), frame, "repl"));
        if (gdb.isSuccess(set)) {
            const pointer = try a.print("${s}", .{variable});
            const r = try gdb.request(s, a, "evaluate", try evalArgs(a, pointer, frame, "watch"));
            const ref = json.int(json.path(r, &.{ "body", "variablesReference" })) orelse 0;
            if (gdb.isSuccess(r) and ref != 0) {
                const declared: ?Declared = if (data_expr) |e| .{ .expr = e, .names = try componentNames(s, a, data) } else null;
                var shown = try present(s, a, .{
                    .name = out.name,
                    .value = json.str(json.path(r, &.{ "body", "result" })) orelse "",
                    .type = json.str(json.path(r, &.{ "body", "type" })),
                    .ref = ref,
                }, out.name, pointer, frame, null, declared);
                shown.type = type_name;
                shown.evaluate_name = out.evaluate_name;
                return shown;
            }
        }
    }
    var shown = try present(s, a, data, out.name, data_expr, frame, null, null);
    shown.type = type_name;
    shown.evaluate_name = out.evaluate_name;
    return shown;
}

fn find(vs: []const Variable, name: []const u8) ?Variable {
    for (vs) |v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

/// The components of the declared type of a polymorphic object's `_data`
fn componentNames(s: *Session, a: Allocator, data: Variable) ![]const []const u8 {
    if (data.ref == 0) return &.{};
    const values = try gdbChildren(s, a, data.ref);
    if (values.len == 0 or values[0].ref == 0) return &.{};
    const comps = try gdbChildren(s, a, values[0].ref);
    const out = try a.alloc([]const u8, comps.len);
    for (comps, out) |c, *o| o.* = try std.ascii.allocLowerString(a, c.name);
    return out;
}

/// A value in a preview: a number as Fortran writes it, `[…]` for an
/// array, `point(…)` for a derived type
fn short(a: Allocator, v: Variable) ![]const u8 {
    if (v.value.len > 0) return fortran.fortranNumber(a, v.value, v.type);
    if (try fortran.arrayType(a, v.type) != null) return "[…]";
    if (fortran.derivedTypeName(v.type)) |t| return a.print("{s}(…)", .{t});
    return "…";
}

// Tests, with a gdb faked: its answers by request

const FakeGdb = struct {
    /// `variables`' answers by reference, `evaluate`'s by expression (JSON)
    variables: []const struct { i64, []const u8 } = &.{},
    evaluate: []const struct { []const u8, []const u8 } = &.{},
    asked: std.ArrayList(u8) = .empty,

    fn answer(ctx: *anyopaque, a: Allocator, command: []const u8, args: Value) anyerror!Value {
        const f: *FakeGdb = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, command, "variables")) {
            const ref = json.int(json.get(args, "variablesReference")).?;
            try f.asked.print(a, "variables {d}; ", .{ref});
            for (f.variables) |v| if (v[0] == ref) return json.parse(a, try a.print("{{\"success\":true,\"body\":{{\"variables\":{s}}}}}", .{v[1]}));
        } else if (std.mem.eql(u8, command, "evaluate")) {
            const expr = json.str(json.get(args, "expression")).?;
            try f.asked.print(a, "evaluate {s}; ", .{expr});
            for (f.evaluate) |e| if (std.mem.eql(u8, e[0], expr)) return json.parse(a, try a.print("{{\"success\":true,\"body\":{s}}}", .{e[1]}));
        }
        return json.parse(a, "{\"success\":false,\"message\":\"no\"}");
    }
};

fn testSession(env: *std.process.Environ.Map, fake: *FakeGdb) Session {
    var s: Session = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = env,
        .log = .init(std.testing.io),
        .nodes_arena = .init(std.testing.allocator),
    };
    s.g.fake = .{ .ctx = fake, .answer = FakeGdb.answer };
    return s;
}

fn testDeinit(s: *Session) void {
    s.nodes_arena.deinit();
    gdb.deinit(s);
}

test "a large array: a preview of its first elements, and sections" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var fake: FakeGdb = .{
        .evaluate = &.{.{ "big(0:5)", "{\"result\":\"(0,1,2,3,4,5)\",\"type\":\"real(kind=4) (6)\",\"variablesReference\":9}" }},
        .variables = &.{.{ 9, "[{\"name\":\"1\",\"value\":\"0\",\"type\":\"real(kind=4)\",\"variablesReference\":0},{\"name\":\"2\",\"value\":\"1.5\",\"type\":\"real(kind=4)\",\"variablesReference\":0}]" }},
    };
    var s = testSession(&env, &fake);
    defer testDeinit(&s);
    const v = try present(&s, a, .{ .name = "big", .value = "(0, 1, ...)", .type = "real(kind=4) (0:249)", .ref = 5 }, "big", "big", 1, null, null);
    try std.testing.expectEqualStrings("[0.0, 1.5, …]", v.value);
    try std.testing.expectEqualStrings("real(kind=4) (0:249)", v.type.?);
    // in sections of 100, by their bounds, without asking gdb
    const node = get(&s, v.ref).?;
    const sections = try children(&s, a, v.ref, node);
    try std.testing.expectEqual(@as(usize, 3), sections.len);
    try std.testing.expectEqualStrings("(200:249)", sections[2].name);
    try std.testing.expectEqualStrings("big(200:249)", sections[2].evaluate_name.?);
    try std.testing.expectEqualStrings("evaluate big(0:5); variables 9; ", fake.asked.items);
}

test "a string typed as an array of characters: the string" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var fake: FakeGdb = .{};
    var s = testSession(&env, &fake);
    defer testDeinit(&s);
    const v = try present(&s, a, .{ .name = "s", .value = "'abcdef'", .type = "character (6)", .ref = 0 }, "s", "s", 1, null, null);
    try std.testing.expectEqualStrings("'abcdef'", v.value);
    try std.testing.expectEqual(@as(i64, 0), v.ref);
    try std.testing.expectEqualStrings("", fake.asked.items);
}

test "a pointer as its target; a null one, an unallocated array" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var fake: FakeGdb = .{
        .variables = &.{.{ 3, "[{\"name\":\"value\",\"value\":\"5\",\"type\":\"integer(kind=4)\",\"variablesReference\":0}]" }},
    };
    var s = testSession(&env, &fake);
    defer testDeinit(&s);
    const ip = try present(&s, a, .{ .name = "ip", .value = "0x7ff6 <goal>", .type = "PTR TO -> ( integer(kind=4) )", .ref = 3 }, "ip", "ip", null, null, null);
    try std.testing.expectEqualStrings("5", ip.value);
    try std.testing.expectEqualStrings("integer(kind=4)", ip.type.?);
    try std.testing.expectEqual(@as(i64, 0), ip.ref);
    const none = try present(&s, a, .{ .name = "p", .value = "0x0", .type = "PTR TO -> ( Type point )", .ref = 4 }, "p", "p", null, null, null);
    try std.testing.expectEqualStrings("not associated", none.value);
    const unallocated = try present(&s, a, .{ .name = "w", .value = "<not allocated>", .type = "real(kind=8), allocatable (:)", .ref = 0 }, "w", "w", null, null, null);
    try std.testing.expectEqualStrings("not allocated", unallocated.value);
}

test "a derived type's preview and components, hidden lengths left out" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var fake: FakeGdb = .{
        .variables = &.{
            .{ 7, "[{\"name\":\"x\",\"value\":\"9\",\"type\":\"real(kind=4)\",\"variablesReference\":0},{\"name\":\"id\",\"value\":\"7\",\"type\":\"integer(kind=4)\",\"variablesReference\":0}]" },
            .{ 1, "[{\"name\":\"s\",\"value\":\"'ab'\",\"type\":\"character*2\",\"variablesReference\":0},{\"name\":\"p\",\"value\":\"\",\"type\":\"Type point\",\"variablesReference\":7},{\"name\":\"_s\",\"value\":\"2\",\"type\":\"integer(kind=8)\",\"variablesReference\":0}]" },
        },
    };
    var s = testSession(&env, &fake);
    defer testDeinit(&s);
    const scope = try add(&s, .{ .kind = .{ .gdb = 1 }, .frame = 1 });
    const args = try children(&s, a, scope, get(&s, scope).?);
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("point(x=9.0, id=7)", args[1].value);
    const comps = try children(&s, a, args[1].ref, get(&s, args[1].ref).?);
    try std.testing.expectEqualStrings("p%x", comps[0].evaluate_name.?);
    try std.testing.expectEqualStrings("9.0", comps[0].value);
    // what setVariable finds
    try std.testing.expectEqualStrings("p%id", get(&s, args[1].ref).?.names[1].evaluate_name.?);
    // the program went on: the references are gone, and not reused
    clear(&s);
    try std.testing.expect(get(&s, scope) == null);
    try std.testing.expect(try add(&s, .{ .kind = .{ .gdb = 2 } }) > args[1].ref);
    freeRetired(&s);
}
