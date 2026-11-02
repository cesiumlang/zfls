//! `zfls/moduleVariables`: the module variables that a line of a file sees,
//! for a debugger's view of them (the C debuggers list only a procedure's
//! own variables, FortranBreaker #10): those of the module or submodule
//! around the line (and a submodule's ancestors), then those that its USE
//! statements, and its hosts', make visible, under the names they have
//! there. Named constants are left out: a debugger has none of them.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const UseStmt = objects.UseStmt;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;

/// A module variable as a line sees it
const Item = struct {
    /// The module that declares it
    module: []const u8,
    /// Its name there
    name: []const u8,
    /// Its name at the line (a USE may rename it)
    local: []const u8,
    /// Its type (`REAL(8)`, `TYPE(grid)`, ...)
    type: []const u8,
};

const Found = struct {
    items: std.ArrayList(Item) = .empty,
    /// The local names listed (lowercase): an inner one hides an outer
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(f: *Found, a: Allocator, module: *const Obj, v: *const Obj, local: []const u8) !void {
        const key = try std.ascii.allocLowerString(a, local);
        const gop = try f.seen.getOrPut(a, key);
        if (gop.found_existing) return;
        try f.items.append(a, .{ .module = module.name, .name = v.name, .local = local, .type = v.varDataConst().desc });
    }
};

/// A module's variables (not its named constants)
fn isModuleVariable(o: *const Obj) bool {
    return o.kind == .variable and !o.varDataConst().is_const;
}

pub fn serveModuleVariables(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const env = self.env(a);
    var found: Found = .{};
    var uses: std.array_hash_map.String(*UseStmt) = .empty;
    // the scopes around the line, the innermost first
    var scope = ast.getInnerScope(params.position.line + 1);
    while (scope) |s| : (scope = s.parent) {
        try objects.getUseTree(env, s, &uses, null, null, &.{});
        if (s.kind != .module and s.kind != .submodule) continue;
        // a module's own variables, private ones too; a submodule's, and
        // its ancestors'
        var unit: ?*Obj = s;
        while (unit) |u| {
            for (u.childList()) |c| if (isModuleVariable(c)) try found.add(a, u, c, c.name);
            if (u != s) try objects.getUseTree(env, u, &uses, null, null, &.{});
            unit = if (u.kind == .submodule) u.submodDataConst().ancestor_obj else null;
        }
    }
    for (uses.values()) |u| {
        if (u.is_import) continue;
        const mod = env.global(ast, u.mod_name) orelse continue;
        if (mod.kind != .module) continue;
        const public = try mod.getChildren(a, true);
        if (u.only_list.len() == 0) {
            for (public) |c| {
                if (!isModuleVariable(c)) continue;
                // `use m, local => name` renames it
                const lower = try std.ascii.allocLowerString(a, c.name);
                var local: []const u8 = c.name;
                for (u.rename_map.keys.items, u.rename_map.values.items) |k, v| {
                    if (std.mem.eql(u8, v, lower)) local = k;
                }
                try found.add(a, mod, c, local);
            }
            continue;
        }
        for (u.only_list.items.items) |local| {
            const name = u.rename_map.get(local) orelse local;
            for (public) |c| {
                if (isModuleVariable(c) and std.ascii.eqlIgnoreCase(c.name, name)) try found.add(a, mod, c, local);
            }
        }
    }
    return json.from(a, found.items.items);
}
