//! The workspace's module dependency graph: the modules each module and
//! submodule uses (in any of its scopes) and, for a submodule, the module or
//! submodule it extends. Its strongly connected components give the cycles
//! (circular USE, which compilers reject) and a compile order, dependencies
//! first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("objects.zig");
const Obj = objects.Obj;

pub const Graph = struct {
    units: []const *Obj,
    /// the units each unit depends on (indexes)
    deps: []const []const usize,
    /// the strongly connected component of each unit
    comp: []const usize,
    /// the components, dependencies first; each lists its units
    components: []const []const usize,

    /// Whether unit `i` is in a cycle
    pub fn inCycle(g: *const Graph, i: usize) bool {
        const c = g.components[g.comp[i]];
        if (c.len > 1) return true;
        for (g.deps[i]) |d| if (d == i) return true;
        return false;
    }

    pub fn indexOf(g: *const Graph, o: *const Obj) ?usize {
        for (g.units, 0..) |u, i| if (u == o) return i;
        return null;
    }
};

/// A module a USE statement names (lowercase), with the statement's 1-based
/// line
pub const Use = struct { name: []const u8, line: usize };

/// The modules a USE in `scope` or the scopes inside it names
pub fn usedModules(a: Allocator, scope: *const Obj, out: *std.ArrayList(Use)) !void {
    if (scope.data != .scope) return;
    for (scope.scopeDataConst().use.items) |u| {
        if (u.is_import) continue;
        try out.append(a, .{ .name = u.mod_name, .line = u.line_number });
    }
    for (scope.childList()) |c| try usedModules(a, c, out);
}

/// The graph of `units` (modules and submodules)
pub fn build(a: Allocator, units: []const *Obj) !Graph {
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    for (units, 0..) |u, i| if (u.kind == .module) try by_name.put(a, try std.ascii.allocLowerString(a, u.name), i);
    const deps = try a.alloc([]const usize, units.len);
    for (units, deps) |u, *d| {
        var list: std.ArrayList(usize) = .empty;
        var uses: std.ArrayList(Use) = .empty;
        try usedModules(a, u, &uses);
        for (uses.items) |m| if (by_name.get(m.name)) |j| {
            if (std.mem.indexOfScalar(usize, list.items, j) == null) try list.append(a, j);
        };
        if (u.kind == .submodule) if (u.submodDataConst().ancestor_obj) |anc| {
            for (units, 0..) |v, j| if (v == anc and std.mem.indexOfScalar(usize, list.items, j) == null) try list.append(a, j);
        };
        d.* = list.items;
    }
    // Tarjan's strongly connected components: each is complete after those
    // it depends on, so they come out dependencies first
    const n = units.len;
    const index = try a.alloc(?usize, n);
    @memset(index, null);
    const low = try a.alloc(usize, n);
    const on_stack = try a.alloc(bool, n);
    @memset(on_stack, false);
    const comp = try a.alloc(usize, n);
    var stack: std.ArrayList(usize) = .empty;
    var components: std.ArrayList([]const usize) = .empty;
    var next: usize = 0;
    const T = struct {
        fn visit(al: Allocator, v: usize, dg: []const []const usize, idx: []?usize, lw: []usize, os: []bool, cp: []usize, st: *std.ArrayList(usize), cs: *std.ArrayList([]const usize), nx: *usize) !void {
            idx[v] = nx.*;
            lw[v] = nx.*;
            nx.* += 1;
            try st.append(al, v);
            os[v] = true;
            for (dg[v]) |w| {
                if (idx[w] == null) {
                    try visit(al, w, dg, idx, lw, os, cp, st, cs, nx);
                    lw[v] = @min(lw[v], lw[w]);
                } else if (os[w]) {
                    lw[v] = @min(lw[v], idx[w].?);
                }
            }
            if (lw[v] == idx[v].?) {
                var members: std.ArrayList(usize) = .empty;
                while (st.pop()) |w| {
                    os[w] = false;
                    cp[w] = cs.items.len;
                    try members.append(al, w);
                    if (w == v) break;
                }
                try cs.append(al, members.items);
            }
        }
    };
    for (0..n) |v| if (index[v] == null) try T.visit(a, v, deps, index, low, on_stack, comp, &stack, &components, &next);
    return .{ .units = units, .deps = deps, .comp = comp, .components = components.items };
}
