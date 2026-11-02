//! The protocol's variables for `zfls dap`: a value's text, type and
//! children (`variables`): a frame's locals, its modules' variables, a
//! derived type's components, an array's elements and sections.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const C = @import("../constants.zig");
const paths = @import("../paths.zig");
const values = @import("values.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const Node = session.Node;
const Val = session.Val;
const addNode = session.addNode;
const persist = session.persist;
const declarations = @import("declarations.zig");
const Decl = declarations.Decl;
const declOf = declarations.declOf;
const declaredType = declarations.declaredType;
const frameVariables = declarations.frameVariables;
const scopeOf = declarations.scopeOf;
const memory = @import("memory.zig");
const valueOf = memory.valueOf;
const components = memory.components;
const moduleGlobal = memory.moduleGlobal;

/// Arrays of more elements are shown in sections
const chunk = 100;

/// A value as a variable of the protocol: its value text, its type, and a
/// reference to its children
pub fn show(s: *Session, a: Allocator, name: []const u8, v: Val) !Value {
    var text: []const u8 = undefined;
    var ref: i64 = 0;
    const type_name = try typeText(a, v);
    if (v.empty) {
        text = if (v.decl != null and hasKeyword(v.decl.?, .allocatable)) s.text.not_allocated else s.text.not_associated;
    } else if (v.rank > v.chosen.len) {
        ref = try addNode(s, .{ .value = try persist(s, v) });
        text = try arrayPreview(s, a, v);
    } else if (v.t.kind == .derived) {
        ref = try addNode(s, .{ .value = try persist(s, v) });
        text = try derivedPreview(s, a, v);
    } else {
        text = try scalarText(s, a, v);
    }
    return json.from(a, .{ .name = name, .value = text, .type = type_name, .variablesReference = ref, .evaluateName = v.expr });
}

fn hasKeyword(o: *const Obj, k: C.Kw) bool {
    for (o.keywords.items) |x| if (x == k) return true;
    return false;
}

fn typeText(a: Allocator, v: Val) ![]const u8 {
    if (v.decl) |o| {
        if (o.kind == .variable) return declaredType(a, o);
    }
    return switch (v.t.kind) {
        .integer => a.print("INTEGER({d})", .{v.t.size}),
        .real => a.print("REAL({d})", .{v.t.size}),
        .complex => a.print("COMPLEX({d})", .{v.t.size / 2}),
        .logical => a.print("LOGICAL({d})", .{v.t.size}),
        .character => a.print("CHARACTER(LEN={d})", .{v.t.size}),
        .derived => a.print("TYPE({s})", .{v.t.name}),
        .unknown => "",
    };
}

fn scalarText(s: *Session, a: Allocator, v: Val) ![]const u8 {
    const size: usize = if (v.t.size == 0) 8 else @min(v.t.size, 4096);
    const b = try a.alloc(u8, size);
    if (s.engine.read(v.address, b) != size) return "<unreadable>";
    if (v.t.kind == .unknown) return values.scalar(a, .{ .kind = .integer, .size = @intCast(size) }, b);
    return values.scalar(a, v.t, b);
}

/// The element `i` (0-based) of the node's last dimension
fn elementOf(v: Val, i: u64) Val {
    const e = v.extents[v.rank - v.chosen.len - 1];
    var out = v;
    out.address = @bitCast(@as(i64, @bitCast(v.address)) + @as(i64, @intCast(i)) * e.stride);
    return out;
}

fn arrayPreview(s: *Session, a: Allocator, v: Val) ![]const u8 {
    const left = v.rank - v.chosen.len;
    if (left > 1) return values.shape(a, v.extents[0..left]);
    const e = v.extents[0];
    var shown: std.ArrayList([]const u8) = .empty;
    var i: u64 = 0;
    while (i < @min(e.count, 6)) : (i += 1) {
        const el = elementOf(v, i);
        var scalar = el;
        scalar.rank = 0;
        scalar.chosen = &.{};
        scalar.extents = &.{};
        try shown.append(a, if (v.t.kind == .derived) try a.print("{s}(…)", .{v.t.name}) else try scalarText(s, a, scalar));
    }
    return values.preview(a, shown.items, e.count);
}

fn derivedPreview(s: *Session, a: Allocator, v: Val) ![]const u8 {
    const comps = try components(s, a, v);
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}(", .{v.t.name});
    for (comps[0..@min(comps.len, 4)], 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        const text = if (c.rank > 0 or c.t.kind == .derived or c.empty) "…" else try scalarText(s, a, c);
        try out.print(a, "{s}={s}", .{ c.expr[std.mem.findScalarLast(u8, c.expr, '%').? + 1 ..], text });
    }
    if (comps.len > 4) try out.appendSlice(a, ", …");
    try out.append(a, ')');
    return out.items;
}

pub fn children(s: *Session, a: Allocator, node: Node) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    switch (node) {
        .locals => |frame| {
            for (try frameVariables(s, a, frame)) |fv| {
                const name = try std.ascii.allocLowerString(a, fv.v.name);
                const val = valueOf(s, a, fv.v, fv.decl, frame, name) catch {
                    try out.append(a, try json.from(a, .{ .name = name, .value = s.text.not_available, .variablesReference = 0 }));
                    continue;
                };
                try out.append(a, try show(s, a, name, val));
            }
        },
        .modules => |frame| {
            const where = scopeOf(s, a, frame) orelse return out.items;
            const srv = s.server orelse return out.items;
            const uri = try paths.pathToUri(a, where.file);
            const items = srv.dispatchPublic(a, "zfls/moduleVariables", try json.from(a, .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = where.line - 1, .character = 0 },
            })) catch return out.items;
            var seen: std.ArrayList([]const u8) = .empty;
            for (json.items(items)) |it| {
                const module = json.str(json.get(it, "module")) orelse continue;
                const listed = for (seen.items) |m| {
                    if (std.ascii.eqlIgnoreCase(m, module)) break true;
                } else false;
                if (listed) continue;
                try seen.append(a, module);
                try out.append(a, try json.from(a, .{ .name = module, .value = "", .variablesReference = try addNode(s, .{ .module = .{ .frame = frame, .name = try s.nodes_arena.allocator().dupe(u8, module) } }) }));
            }
        },
        .module => |m| {
            const where = scopeOf(s, a, m.frame) orelse return out.items;
            const srv = s.server orelse return out.items;
            const uri = try paths.pathToUri(a, where.file);
            const items = srv.dispatchPublic(a, "zfls/moduleVariables", try json.from(a, .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = where.line - 1, .character = 0 },
            })) catch return out.items;
            const env = srv.env(a);
            const ff = (srv.fileFromUri(a, uri) catch null) orelse return out.items;
            const ast = ff.ast orelse return out.items;
            const mod = env.global(ast, m.name);
            for (json.items(items)) |it| {
                const module = json.str(json.get(it, "module")) orelse continue;
                if (!std.ascii.eqlIgnoreCase(module, m.name)) continue;
                const name = json.str(json.get(it, "name")) orelse continue;
                const local = json.str(json.get(it, "local")) orelse name;
                const label = if (std.ascii.eqlIgnoreCase(local, name)) try std.ascii.allocLowerString(a, local) else try a.print("{s} => {s}", .{ local, name });
                const v = (try moduleGlobal(s, a, module, name)) orelse {
                    try out.append(a, try json.from(a, .{ .name = label, .value = s.text.not_available, .variablesReference = 0 }));
                    continue;
                };
                const decl: ?Decl = if (mod) |mo| blk: {
                    for (mo.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, name)) break :blk declOf(a, c);
                    break :blk null;
                } else null;
                const expr = try a.print("{s}::{s}", .{ try std.ascii.allocLowerString(a, module), try std.ascii.allocLowerString(a, name) });
                const val = valueOf(s, a, v, decl, m.frame, expr) catch continue;
                try out.append(a, try show(s, a, label, val));
            }
        },
        .value => |v| {
            if (v.t.kind == .derived and v.rank == v.chosen.len) {
                for (try components(s, a, v)) |c| try out.append(a, try show(s, a, c.expr[std.mem.findScalarLast(u8, c.expr, '%').? + 1 ..], c));
                return out.items;
            }
            const left = v.rank - v.chosen.len;
            const e = v.extents[left - 1];
            const base = if (v.base.len > 0) v.base else v.expr;
            const total = if (v.count > 0) v.count else e.count;
            if (total > chunk) {
                // in sections of 100 (of 10000, ...)
                var per: u64 = chunk;
                while (total > per * chunk) per *= chunk;
                var start: u64 = 0;
                while (start < total) : (start += per) {
                    var sec = v;
                    sec.base = base;
                    sec.first = v.first + start;
                    sec.count = @min(per, total - start);
                    const lo = e.lo + @as(i64, @intCast(sec.first));
                    const label = try sectionLabel(a, left, v.chosen, lo, lo + @as(i64, @intCast(sec.count)) - 1);
                    try out.append(a, try json.from(a, .{ .name = label, .value = "", .variablesReference = try addNode(s, .{ .value = try persist(s, sec) }), .evaluateName = try a.print("{s}{s}", .{ base, label }) }));
                }
                return out.items;
            }
            var i: u64 = 0;
            while (i < total) : (i += 1) {
                const at = v.first + i;
                const sub = e.lo + @as(i64, @intCast(at));
                var el = elementOf(v, at);
                const chosen = try a.alloc(i64, v.chosen.len + 1);
                chosen[0] = sub;
                @memcpy(chosen[1..], v.chosen);
                el.chosen = try s.nodes_arena.allocator().dupe(i64, chosen);
                el.first = 0;
                el.count = 0;
                const label = try values.subscripts(a, v.rank, chosen);
                el.expr = try s.nodes_arena.allocator().dupe(u8, try a.print("{s}{s}", .{ base, label }));
                el.base = base;
                el.extents = try s.nodes_arena.allocator().dupe(values.Extent, v.extents);
                if (el.rank == el.chosen.len) {
                    var scalar = el;
                    if (el.t.kind != .derived) {
                        scalar.rank = 0;
                        scalar.chosen = &.{};
                        scalar.extents = &.{};
                    }
                    try out.append(a, try show(s, a, label, scalar));
                } else try out.append(a, try show(s, a, label, el));
            }
        },
    }
    return out.items;
}

fn sectionLabel(a: Allocator, rank: usize, chosen: []const i64, lo: i64, hi: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '(');
    for (0..rank - 1) |_| try out.appendSlice(a, ":,");
    try out.print(a, "{d}:{d}", .{ lo, hi });
    for (chosen) |c| try out.print(a, ",{d}", .{c});
    try out.append(a, ')');
    return out.items;
}
