//! The global name tree (which file owns each module, program and global
//! procedure) and the linking of the workspace's files to each other.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Ast = objects.Ast;
const FortranFile = parser.FortranFile;

const srv = @import("../server.zig");
const Server = srv.Server;
const definition = @import("definition.zig");
const pull = @import("pull.zig");

// Several files can define the same global name. Unlike fortls, where
// the last file parsed takes the name and re-parsing either file drops
// it for both, the tree keeps one owner per name chosen the same way
// whatever the order of events, so a long session agrees with a fresh
// start: any file over an intrinsic module, then the lowest path.

/// Whether a definition from `path` takes a name held by `held`.
pub fn treeOwnerBeats(path: ?[]const u8, held: ?[]const u8) bool {
    const p = path orelse return false;
    const h = held orelse return true;
    return std.mem.order(u8, p, h) == .lt;
}

pub fn addToTree(self: *Server, f: *FortranFile) !void {
    const ast = f.ast orelse return;
    var it = ast.global_dict.iterator();
    while (it.next()) |e| {
        const gop = try self.obj_tree.getOrPut(self.gpa, e.key_ptr.*);
        // another file's of the same name: both kept (#187)
        if (gop.found_existing) if (gop.value_ptr.path) |held| if (!std.mem.eql(u8, held, f.path)) {
            try self.same_names.add(self.gpa, e.key_ptr.*, gop.value_ptr.*, .{ .obj = e.value_ptr.*, .path = f.path });
        };
        if (gop.found_existing and !treeOwnerBeats(f.path, gop.value_ptr.path)) continue;
        // the key is the owner's (it lives as long as the owner's AST)
        gop.key_ptr.* = e.key_ptr.*;
        gop.value_ptr.* = .{ .obj = e.value_ptr.*, .path = f.path };
    }
}

/// Drops the names `ast` owns, handing each to the next file (or
/// intrinsic module) that defines it.
pub fn removeFromTree(self: *Server, ast: *Ast) Allocator.Error!void {
    self.same_names.remove(self.gpa, ast);
    // the names nobody else defines, taken out together (one at a time is
    // quadratic in a file of thousands of procedures)
    var gone: std.ArrayList(usize) = .empty;
    defer gone.deinit(self.gpa);
    for (ast.global_dict.keys()) |key| {
        const held = self.obj_tree.getEntry(key) orelse continue;
        if (held.value_ptr.obj.file_ast != ast) continue;
        var best: ?struct { key: []const u8, entry: objects.TreeEntry } = null;
        for (self.workspace.values()) |f| {
            const other = f.ast orelse continue;
            if (other == ast) continue;
            const e = other.global_dict.getEntry(key) orelse continue;
            if (best == null or treeOwnerBeats(f.path, best.?.entry.path)) {
                best = .{ .key = e.key_ptr.*, .entry = .{ .obj = e.value_ptr.*, .path = f.path } };
            }
        }
        if (best == null) for (self.intr.mods) |m| {
            if (std.mem.eql(u8, m.fqsn, key)) best = .{ .key = m.fqsn, .entry = .{ .obj = m, .path = null } };
        };
        if (best) |b| {
            held.key_ptr.* = b.key;
            held.value_ptr.* = b.entry;
        } else if (self.obj_tree.getIndex(key)) |i| try gone.append(self.gpa, i);
    }
    std.mem.sort(usize, gone.items, {}, std.sort.asc(usize));
    try self.obj_tree.orderedRemoveAtMany(self.gpa, gone.items);
}

pub fn retireFileAst(self: *Server, f: *FortranFile) !void {
    if (f.ast) |old| {
        try self.retired.append(self.gpa, old);
        try removeFromTree(self, old);
    }
}

/// Re-resolve includes and links across the whole workspace, after
/// which no object references a retired AST, so those can be freed.
pub fn fullRelink(self: *Server, a: Allocator) !void {
    // Reset cross-file references so that nothing points into retired ASTs
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        ast.included_in = null;
        if (ast.inc_scope) |inc| {
            ast.none_scope = inc;
            for (inc.childList()) |c| c.parent = inc;
        }
        // the last linked first, so that each restores the IMPLICIT state
        // it found
        var k_inc = ast.include_statements.items.len;
        while (k_inc > 0) {
            k_inc -= 1;
            const inc = ast.include_statements.items[k_inc];
            inc.unlink();
            inc.inc_obj = null;
            inc.file = null;
        }
        for (ast.variable_list.items) |v| {
            v.varData().type_obj = null;
            v.varData().link_obj = null;
        }
        for (ast.scope_list.items) |s| {
            // a procedure of a file of whole procedures, linked by an
            // include into another file's scope, is the file's own again
            if (s.parent) |p| if (p.file_ast != ast) {
                s.setParent(null);
                try s.updateFqsn(null);
            };
            if (s.kind.isSubroutine()) s.procData().link_obj = null;
            if (s.procDataOpt()) |p| if (p.linked_from_interface) s.resetInterfaceCopy();
            if (s.kind == .interface) {
                s.ifaceData().mems.clearRetainingCapacity();
                s.ifaceData().extends.clearRetainingCapacity();
            }
            if (s.kind == .type) {
                s.typeData().inherit_var = null;
                s.scopeData().in_children.clearRetainingCapacity();
                s.typeData().inherit_version = -1;
            }
            if (s.kind == .submodule) s.submodData().ancestor_obj = null;
            // Children of scopes in other files added through INCLUDE
            var k: usize = 0;
            while (k < s.childList().len) {
                if (s.childList()[k].file_ast != ast) {
                    s.removeChild(k);
                } else k += 1;
            }
        }
        if (ast.none_scope) |ns| {
            var k: usize = 0;
            while (k < ns.childList().len) {
                if (ns.childList()[k].file_ast != ast) {
                    ns.removeChild(k);
                } else k += 1;
            }
        }
    }
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.include_statements.items) |inc| inc.scope_objs.clearRetainingCapacity();
    }
    for (self.workspace.values()) |f| {
        if (f.ast) |ast| try ast.resolveIncludes(&self.workspace, try definition.includeDirs(self, a), null, a);
    }
    self.link_version = @mod(self.link_version + 1, 1000);
    pull.changed(self);
    var tmp = std.heap.ArenaAllocator.init(self.gpa);
    defer tmp.deinit();
    for (self.workspace.values()) |f| {
        if (f.ast) |ast| {
            try ast.resolveLinks(self.env(tmp.allocator()), self.link_version);
            _ = tmp.reset(.retain_capacity);
        }
    }
    for (self.retired.items) |ast| ast.destroy();
    self.retired.clearRetainingCapacity();
}
