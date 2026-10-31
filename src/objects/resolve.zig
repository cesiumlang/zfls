//! Name resolution (port of fortls `utilities.py`): the USE tree of a scope,
//! finding a name in a scope or the workspace, and climbing a chain of
//! components.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const C = @import("../constants.zig");

const objects = @import("../objects.zig");
const Obj = objects.Obj;
const ImportType = objects.ImportType;
const UseStmt = objects.UseStmt;
const StrSet = objects.StrSet;
const StrMap = objects.StrMap;
const Env = objects.Env;

/// Build the USE tree of a scope. `use_dict` maps module name -> merged USE.
pub fn getUseTree(
    env: Env,
    scope: *Obj,
    use_dict: *std.array_hash_map.String(*UseStmt),
    only_list: ?*const StrSet,
    rename_map: ?*const StrMap,
    curr_path: []const []const u8,
) Allocator.Error!void {
    // what code being edited declares as a type may be no scope
    if (scope.data != .scope) return;
    const a = env.tmp;
    const empty_set: StrSet = .{};
    const empty_map: StrMap = .{};
    const only = only_list orelse &empty_set;
    const renames = rename_map orelse &empty_map;

    for (curr_path) |p| if (std.mem.eql(u8, p, scope.fqsn)) return;
    var new_path: std.ArrayList([]const u8) = .empty;
    try new_path.appendSlice(a, curr_path);
    try new_path.append(a, scope.fqsn);

    for (scope.scopeData().use.items) |use_stmnt| {
        if (!use_stmnt.is_import and !env.tree.contains(use_stmnt.mod_name)) continue;
        if (use_stmnt.is_import and use_stmnt.import_type == .none) continue;
        var merged_use_list: StrSet = undefined;
        var merged_rename: StrMap = undefined;
        if (only.len() == 0) {
            merged_use_list = try use_stmnt.only_list.clone(a);
            merged_rename = try use_stmnt.rename_map.clone(a);
        } else if (use_stmnt.only_list.len() == 0) {
            merged_use_list = try only.clone(a);
            merged_rename = try renames.clone(a);
        } else {
            // intersect_only
            merged_use_list = .{};
            merged_rename = try renames.clone(a);
            for (only.items.items) |val1| {
                const mapped1 = merged_rename.get(val1) orelse val1;
                if (use_stmnt.only_list.contains(mapped1)) {
                    try merged_use_list.items.append(a, val1);
                    if (use_stmnt.rename_map.get(mapped1)) |nr| try merged_rename.put(a, val1, nr);
                } else {
                    merged_rename.remove(val1);
                }
            }
            if (merged_use_list.len() == 0) continue;
        }
        if (use_dict.get(use_stmnt.mod_name)) |use_dict_mod| {
            const old_len = use_dict_mod.only_list.len();
            if (old_len > 0 and merged_use_list.len() > 0) {
                var only_len = old_len;
                for (merged_use_list.items.items) |only_name| {
                    try use_dict_mod.only_list.add(a, only_name);
                    if (use_dict_mod.only_list.len() == only_len) continue;
                    only_len = use_dict_mod.only_list.len();
                    if (merged_rename.get(only_name) == null) continue;
                    use_dict_mod.rename_map = merged_rename;
                }
            } else {
                const fresh = try a.create(UseStmt);
                fresh.* = .{ .mod_name = use_stmnt.mod_name };
                try use_dict.put(a, use_stmnt.mod_name, fresh);
            }
            // look the entry up again: a full import replaced a restricted one
            // above, and what it imports in turn must be searched (upstream #568)
            if (old_len == use_dict.get(use_stmnt.mod_name).?.only_list.len()) continue;
        } else {
            const nu = try a.create(UseStmt);
            nu.* = .{
                .mod_name = use_stmnt.mod_name,
                .only_list = merged_use_list,
                .rename_map = merged_rename,
                .is_import = use_stmnt.is_import,
                .import_type = use_stmnt.import_type,
            };
            if (use_stmnt.is_import) {
                if (scope.parent) |p| nu.scope = p.parent;
            }
            try use_dict.put(a, use_stmnt.mod_name, nu);
        }
        if (use_stmnt.is_import) continue;
        const next = env.global(scope.file_ast, use_stmnt.mod_name).?;
        try getUseTree(env, next, use_dict, &merged_use_list, &merged_rename, new_path.items);
    }
}

pub const FindOpts = struct {
    interface: bool = false,
    local_only: bool = false,
    var_line_number: ?usize = null,
};

pub fn checkScope(env: Env, local_scope: *Obj, name_lower: []const u8, filter_public: bool, var_line_number: ?usize) Allocator.Error!?*Obj {
    const children = try local_scope.getChildren(env.tmp, false);
    for (children) |child| {
        if (std.mem.startsWith(u8, child.name, "#GEN_INT")) {
            if (try checkScope(env, child, name_lower, filter_public, null)) |v| return v;
        }
        const is_private = child.vis == .private or (local_scope.def_vis == .private and child.vis != .public);
        if (filter_public and is_private) continue;
        if (std.ascii.eqlIgnoreCase(child.name, name_lower)) {
            if (local_scope.kind == .function and std.ascii.eqlIgnoreCase(local_scope.name, child.name)) {
                if (var_line_number) |vl| if (vl == local_scope.sline or vl == local_scope.eline) return null;
            }
            return child;
        }
    }
    return null;
}

pub fn checkImportScope(scope: *const Obj, name_lower: []const u8) ?ImportType {
    for (scope.scopeDataConst().use.items) |u| {
        if (!u.is_import) continue;
        switch (u.import_type) {
            .only => if (u.only_list.contains(name_lower)) return .only,
            .all => return .all,
            .none => return .none,
            .default => {},
        }
    }
    return null;
}

/// Find a named object visible from `scope_opt`
pub fn findInScope(env: Env, scope_opt: ?*Obj, var_name: []const u8, opts: FindOpts) Allocator.Error!?*Obj {
    const scope = scope_opt orelse return null;
    const a = env.tmp;
    const name_lower = try std.ascii.allocLowerString(a, var_name);
    const tmp_var = try checkScope(env, scope, name_lower, false, opts.var_line_number);
    if (opts.local_only or tmp_var != null) return tmp_var;
    // Check INCLUDE statements
    if (scope.file_ast.include_statements.items.len > 0) {
        const strip1 = try std.mem.replaceOwned(u8, a, var_name, "\"", "");
        const strip_str = try std.mem.replaceOwned(u8, a, strip1, "'", "");
        for (scope.file_ast.include_statements.items) |inc| {
            if (std.mem.eql(u8, strip_str, inc.path)) {
                const f = inc.file orelse return null;
                const inc_ast = f.ast orelse return null;
                if (inc.inc_obj == null) {
                    const saved = inc_ast.enc_scope_name;
                    inc_ast.enc_scope_name = null;
                    defer inc_ast.enc_scope_name = saved;
                    inc.inc_obj = try Obj.newScope(inc_ast, .include, inc.line_number, inc.path, &.{});
                }
                return inc.inc_obj;
            }
        }
    }
    // Setup USE search
    var use_dict = std.array_hash_map.String(*UseStmt).empty;
    try getUseTree(env, scope, &use_dict, null, null, &.{});
    var it = use_dict.iterator();
    while (it.next()) |entry| {
        const use_mod = entry.key_ptr.*;
        const use_info = entry.value_ptr.*;
        if (use_info.is_import) continue;
        const use_scope = env.global(scope.file_ast, use_mod) orelse continue;
        if (std.mem.eql(u8, use_mod, name_lower)) return use_scope;
        if (use_info.only_list.len() > 0 and !use_info.only_list.contains(name_lower)) continue;
        const renamed = use_info.rename_map.get(name_lower);
        // a renamed entity is not accessible under its original name
        if (renamed == null and use_info.rename_map.hasValue(name_lower)) continue;
        const mod_name = renamed orelse name_lower;
        if (try checkScope(env, use_scope, mod_name, true, null)) |v| return v;
    }
    // Only search local and imported names for interfaces
    var import_type: ImportType = .default;
    if (opts.interface) {
        import_type = checkImportScope(scope, name_lower) orelse return null;
    }
    if (scope.parent != null and import_type != .none) {
        if (try findInScope(env, scope.parent, var_name, .{})) |v| return v;
    }
    for (try scope.getAncestors(a)) |anc| {
        if (try findInScope(env, anc, var_name, .{})) |v| return v;
    }
    // A file included into a scope sees that scope
    if (scope.parent == null) if (scope.file_ast.included_in) |host| {
        if (host.file_ast != scope.file_ast) return findInScope(env, host, var_name, .{});
    };
    return null;
}

pub fn findInWorkspace(env: Env, query: []const u8, filter_public: bool, exact_match: bool) ![]*Obj {
    const a = env.tmp;
    var matching: std.ArrayList(*Obj) = .empty;
    var it = env.tree.iterator();
    while (it.next()) |entry| {
        const top_obj = entry.value_ptr.obj;
        if (entry.value_ptr.path == null) continue;
        if ((std.ascii.findIgnoreCase(top_obj.name, query) != null)) try matching.append(a, top_obj);
        if (top_obj.getType(false) == C.TypeId.module) {
            for (try top_obj.getChildren(a, filter_public)) |child| {
                if ((std.ascii.findIgnoreCase(child.name, query) != null)) try matching.append(a, child);
            }
        }
    }
    if (exact_match) {
        var filtered: std.ArrayList(*Obj) = .empty;
        for (matching.items) |sym| if (sym.name.len == query.len) try filtered.append(a, sym);
        return filtered.items;
    }
    return matching.items;
}

/// Walk up user-defined type sequence to determine final field type
pub fn climbTypeTree(env: Env, var_stack: []const []const u8, curr_scope: ?*Obj) !?*Obj {
    var i_var: usize = 0;
    const first = try std.ascii.allocLowerString(env.tmp, str.strip(var_stack[i_var]));
    var var_obj = (try findInScope(env, curr_scope, first, .{})) orelse return null;
    var n: usize = 0;
    while (n < 30) : (n += 1) {
        const type_obj = (try var_obj.getTypeObj(env)) orelse return null;
        // a variable named like the type, while code is being edited
        if (type_obj.data != .scope) return null;
        i_var += 1;
        if (i_var == var_stack.len - 1) return type_obj;
        const name = try std.ascii.allocLowerString(env.tmp, str.strip(var_stack[i_var]));
        var_obj = (try findInScope(env, type_obj, name, .{ .local_only = true })) orelse return null;
    }
    // Python raises KeyError here
    return null;
}
