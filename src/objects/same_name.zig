//! Global names that more than one file defines (#187): a module `utils` in
//! `app1/` and another in `app2/`, of two programs that a project builds.
//! The object tree (`ObjTree`) keeps one owner for each name; `SameNames`
//! keeps every definition of the names defined more than once, and `pick`
//! chooses the one that a file sees:
//!
//! - with the build's module directories (compile_commands.json), the one
//!   whose module directory comes first in the file's search path;
//! - else the one in the file's directory, then in the nearest directory,
//!   then the one of the lowest path (the tree's owner).

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const project = @import("../project.zig");
const paths = @import("../paths.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const TreeEntry = objects.TreeEntry;

pub const SameNames = struct {
    /// The definitions of each name defined more than once (its key owned)
    map: std.array_hash_map.String(std.ArrayList(TreeEntry)) = .empty,

    pub fn deinit(self: *SameNames, gpa: Allocator) void {
        self.clear(gpa);
        self.map.deinit(gpa);
    }

    pub fn clear(self: *SameNames, gpa: Allocator) void {
        for (self.map.keys(), self.map.values()) |k, *v| {
            gpa.free(k);
            v.deinit(gpa);
        }
        self.map.clearRetainingCapacity();
    }

    /// `entry` defines `key` too, which `held` (the tree's owner, from
    /// another file) defines
    pub fn add(self: *SameNames, gpa: Allocator, key: []const u8, held: TreeEntry, entry: TreeEntry) Allocator.Error!void {
        if (self.map.getPtr(key)) |list| {
            for (list.items) |e| if (e.obj == entry.obj) return;
            return list.append(gpa, entry);
        }
        const owned = try gpa.dupe(u8, key);
        errdefer gpa.free(owned);
        var list: std.ArrayList(TreeEntry) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, &.{ held, entry });
        try self.map.put(gpa, owned, list);
    }

    /// Drops the definitions of `ast`, which leaves the workspace
    pub fn remove(self: *SameNames, gpa: Allocator, ast: *const Ast) void {
        for (ast.global_dict.keys()) |key| {
            const list = self.map.getPtr(key) orelse continue;
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].obj.file_ast == ast) {
                    _ = list.orderedRemove(i);
                } else i += 1;
            }
            if (list.items.len >= 2) continue;
            const kv = self.map.fetchOrderedRemove(key).?;
            gpa.free(kv.key);
            var l = kv.value;
            l.deinit(gpa);
        }
    }
};

/// The definition of `name` that file `ast` sees, of those in `same`; null
/// when the name is defined once (the tree's owner is it)
pub fn global(same: *const SameNames, module_dirs: ?*const project.ModuleDirsMap, tmp: Allocator, ast: *const Ast, name: []const u8) ?*Obj {
    const cands = same.map.get(name) orelse return null;
    const from = ast.path orelse return null;
    return pick(tmp, module_dirs, from, cands.items);
}

/// The definition of `cands` that the file at `from` sees
pub fn pick(tmp: Allocator, module_dirs: ?*const project.ModuleDirsMap, from: []const u8, cands: []const TreeEntry) ?*Obj {
    if (module_dirs) |dirs| if (dirs.get(project.pathKey(tmp, from) catch "")) |own| {
        for (own.search) |d| for (cands) |c| {
            const p = c.path orelse continue;
            const theirs = dirs.get(project.pathKey(tmp, p) catch continue) orelse continue;
            if (paths.eql(theirs.out, d)) return c.obj;
        };
    };
    const here = paths.dirname(from);
    var best: ?TreeEntry = null;
    var best_near: Nearness = .{};
    for (cands) |c| {
        const p = c.path orelse continue;
        const near = nearness(here, paths.dirname(p));
        if (best == null or near.better(best_near) or (near.same(best_near) and std.mem.order(u8, p, best.?.path.?) == .lt)) {
            best = c;
            best_near = near;
        }
    }
    return if (best) |b| b.obj else null;
}

/// How near a directory is to another: the leading components they share,
/// then the fewest further ones
const Nearness = struct {
    common: usize = 0,
    extra: usize = 0,

    fn better(x: Nearness, y: Nearness) bool {
        return x.common > y.common or (x.common == y.common and x.extra < y.extra);
    }

    fn same(x: Nearness, y: Nearness) bool {
        return x.common == y.common and x.extra == y.extra;
    }
};

fn nearness(from: []const u8, dir: []const u8) Nearness {
    var x = std.mem.tokenizeAny(u8, from, "/\\");
    var y = std.mem.tokenizeAny(u8, dir, "/\\");
    var n: Nearness = .{};
    while (true) {
        const a = x.next();
        const b = y.next() orelse break;
        if (a == null or !paths.eql(a.?, b)) {
            n.extra += 1;
            break;
        }
        n.common += 1;
    }
    while (y.next()) |_| n.extra += 1;
    return n;
}

test "the nearest directory, then the lowest path" {
    const sep = std.Io.Dir.path.sep_str;
    var objs: [3]Obj = undefined;
    const cands = [_]TreeEntry{
        .{ .obj = &objs[0], .path = sep ++ "p" ++ sep ++ "a" ++ sep ++ "utils.f90" },
        .{ .obj = &objs[1], .path = sep ++ "p" ++ sep ++ "b" ++ sep ++ "utils.f90" },
        .{ .obj = &objs[2], .path = sep ++ "p" ++ sep ++ "b" ++ sep ++ "sub" ++ sep ++ "utils.f90" },
    };
    const a = std.testing.allocator;
    try std.testing.expect(pick(a, null, sep ++ "p" ++ sep ++ "b" ++ sep ++ "main.f90", &cands) == &objs[1]);
    try std.testing.expect(pick(a, null, sep ++ "p" ++ sep ++ "a" ++ sep ++ "main.f90", &cands) == &objs[0]);
    try std.testing.expect(pick(a, null, sep ++ "p" ++ sep ++ "b" ++ sep ++ "sub" ++ sep ++ "x" ++ sep ++ "main.f90", &cands) == &objs[2]);
    try std.testing.expect(pick(a, null, sep ++ "p" ++ sep ++ "c" ++ sep ++ "main.f90", &cands) == &objs[0]);
    try std.testing.expect(pick(a, null, sep ++ "q" ++ sep ++ "main.f90", &cands) == &objs[0]);
}
