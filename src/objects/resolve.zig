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
const index = @import("index.zig");

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
    return checkScopeOf(env, local_scope, local_scope, name_lower, filter_public, var_line_number);
}

/// `checkScope` of `local_scope`, whose names are those of `owner`, public
/// or not as its: `owner` is the scope around an interface block, whose
/// interface bodies are names of it (#474)
fn checkScopeOf(env: Env, local_scope: *Obj, owner: *const Obj, name_lower: []const u8, filter_public: bool, var_line_number: ?usize) Allocator.Error!?*Obj {
    // the children `getChildren` lists, without copying them: a procedure's
    // and a type's own, then those inherited (`in_children`)
    const inherited: []const *Obj = switch (local_scope.kind) {
        .type, .subroutine, .function => local_scope.scopeDataConst().in_children.items,
        .variable, .method, .intrinsic => return null,
        else => &.{},
    };
    const own = local_scope.childList();
    if (try index.of(local_scope)) |idx| {
        // only the children where the name can be
        var it = idx.find(name_lower);
        while (it.next()) |i| switch (try checkChild(env, local_scope, owner, own[i], name_lower, filter_public, var_line_number)) {
            .next => {},
            .found => |v| return v,
        };
    } else for (own) |child| switch (try checkChild(env, local_scope, owner, child, name_lower, filter_public, var_line_number)) {
        .next => {},
        .found => |v| return v,
    };
    for (inherited) |child| switch (try checkChild(env, local_scope, owner, child, name_lower, filter_public, var_line_number)) {
        .next => {},
        .found => |v| return v,
    };
    return null;
}

/// What `checkScope` makes of one child: go on to the next, or answer
const Step = union(enum) { next, found: ?*Obj };

/// `owner`: whose names the children are, public or not as its (see
/// `checkScopeOf`)
fn checkChild(env: Env, local_scope: *Obj, owner: *const Obj, child: *Obj, name_lower: []const u8, filter_public: bool, var_line_number: ?usize) Allocator.Error!Step {
    // the interface bodies of an interface block are names of this scope,
    // public or not as its own (#474)
    if (child.bodiesAreNames(name_lower)) {
        if (try checkScopeOf(env, child, owner, name_lower, filter_public, null)) |v| return .{ .found = v };
    }
    // the enumerators of an ENUM are names of this scope, public or
    // not as its own
    if (child.kind == .enum_) for (child.childList()) |e| {
        const e_private = e.vis == .private or (owner.def_vis == .private and e.vis != .public);
        if (filter_public and e_private) continue;
        if (std.ascii.eqlIgnoreCase(e.name, name_lower)) return .{ .found = e };
    };
    const is_private = child.vis == .private or (owner.def_vis == .private and child.vis != .public);
    if (filter_public and is_private) return .next;
    if (std.ascii.eqlIgnoreCase(child.name, name_lower)) {
        if (local_scope.kind == .function and std.ascii.eqlIgnoreCase(local_scope.name, child.name)) {
            if (var_line_number) |vl| if (vl == local_scope.sline or vl == local_scope.eline) return .{ .found = null };
        }
        return .{ .found = child };
    }
    return .next;
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

/// Whether an IMPORT statement of `scope` (a BLOCK or a contained
/// procedure; interface bodies are `checkImportScope`'s) leaves the host's
/// name `name_lower` out: IMPORT, NONE, or IMPORT, ONLY without it (#804)
pub fn importHides(scope: *const Obj, name_lower: []const u8) bool {
    if (scope.data != .scope) return false;
    if (scope.parent) |p| if (p.kind == .interface) return false;
    var restricted = false;
    for (scope.scopeDataConst().use.items) |u| {
        if (!u.is_import) continue;
        switch (u.import_type) {
            .none => return true,
            .only => if (u.only_list.contains(name_lower)) return false else {
                restricted = true;
            },
            .all, .default => return false,
        }
    }
    return restricted;
}

/// Whether module `mod` gives its users `name` (lowercase), a name it has by
/// USE: not when a PRIVATE statement names it, nor, when PRIVATE is its
/// default, unless a PUBLIC statement does (#235)
pub fn exportsUsedName(mod: *const Obj, name: []const u8) bool {
    if (mod.data != .scope) return false;
    const sd = mod.scopeDataConst();
    for (sd.private_names.items) |n| if (std.mem.eql(u8, n, name)) return false;
    if (mod.def_vis != .private) return true;
    for (sd.public_names.items) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// What `name_lower` stands for in `scope` by its USE statements, through
/// the modules they use and those these use in turn, each statement's ONLY
/// list and renames applied. A used module passes on the names it has by
/// USE only as `exportsUsedName` says. `outside`: as `scope`'s users see
/// the name, `scope` being a module.
pub fn findThroughUse(env: Env, scope: *Obj, name_lower: []const u8, outside: bool) Allocator.Error!?*Obj {
    if (outside and !exportsUsedName(scope, name_lower)) return null;
    var walk: UseWalk = .{ .env = env, .name = name_lower };
    return walk.search(scope, name_lower);
}

/// Everything `name_lower` stands for in `scope` by its USE statements, as
/// `findThroughUse` finds the first: each object of the name in a module
/// that a USE statement brings it from, appended to `out` once. A module
/// that has the name itself is not searched further (#478: the generic
/// interfaces of one name that are one generic there).
pub fn findAllThroughUse(env: Env, scope: *Obj, name_lower: []const u8, out: *std.ArrayList(*Obj)) Allocator.Error!void {
    var walk: UseWalk = .{ .env = env, .name = name_lower, .all = out };
    _ = try walk.search(scope, name_lower);
}

/// Where `scope` gets `name_lower` by USE from a module that has it by a
/// rename (`use a, only: name => other` there): that module, the name
/// there and the line of its USE statement. Null when the name comes by
/// no such module, or is declared in the module it comes from (#480).
pub fn renamingModule(env: Env, scope: *Obj, name_lower: []const u8) Allocator.Error!?struct { mod: *Obj, name: []const u8, use_line: usize } {
    var seen: std.AutoHashMapUnmanaged(struct { *Obj, u64 }, void) = .empty;
    var cur_scope = scope;
    var cur_name = name_lower;
    // a name comes from one module: follow it, the first that has it
    outer: for (0..1000) |_| {
        if (cur_scope.data != .scope) return null;
        for (cur_scope.scopeDataConst().use.items) |u| {
            if (u.is_import or !env.tree.contains(u.mod_name)) continue;
            const mod = env.global(cur_scope.file_ast, u.mod_name) orelse continue;
            const there = u.nameThere(cur_name) orelse continue;
            if (try checkScope(env, mod, there, true, null)) |_| return null;
            if (!exportsUsedName(mod, there)) continue;
            for (mod.scopeDataConst().use.items) |mu| {
                if (!mu.is_import and mu.rename_map.get(there) != null) return .{ .mod = mod, .name = there, .use_line = mu.line_number };
            }
            const gop = try seen.getOrPut(env.tmp, .{ mod, std.hash.Wyhash.hash(0, there) });
            if (gop.found_existing) continue;
            // only if the name comes through `mod` at all
            if (try findThroughUse(env, mod, there, true) == null) continue;
            cur_scope = mod;
            cur_name = there;
            continue :outer;
        }
        return null;
    }
    return null;
}

/// Whether what `name_lower` stands for in `scope` by USE (as
/// `findThroughUse` finds it) comes through module `via`, where it is
/// named `via_name`: through the rename of a USE statement there, say.
/// Null when the name is not found.
pub fn comesThrough(env: Env, scope: *Obj, name_lower: []const u8, outside: bool, via: *Obj, via_name: []const u8) Allocator.Error!?bool {
    if (outside and !exportsUsedName(scope, name_lower)) return null;
    var walk: UseWalk = .{ .env = env, .name = name_lower, .via = .{ via, via_name } };
    walk.on_path = scope == via and std.mem.eql(u8, name_lower, via_name);
    _ = (try walk.search(scope, name_lower)) orelse return null;
    return walk.found_on_path;
}

const UseWalk = struct {
    env: Env,
    /// The name looked up, as `scope` has it: a used module of that name is
    /// the answer
    name: []const u8,
    /// The modules searched, each with a hash of the name searched there
    seen: std.AutoHashMapUnmanaged(struct { *Obj, u64 }, void) = .empty,
    /// For `comesThrough`: the module and its name to look for on the way,
    /// whether the walk is in it, and whether it was when the name was found
    via: ?struct { *Obj, []const u8 } = null,
    on_path: bool = false,
    found_on_path: bool = false,
    /// For `findAllThroughUse`: where every object found goes, the walk
    /// going on
    all: ?*std.ArrayList(*Obj) = null,

    /// Search the modules `scope` uses for `name`, its name in `scope`
    fn search(w: *UseWalk, scope: *Obj, name: []const u8) Allocator.Error!?*Obj {
        if (scope.data != .scope) return null;
        for (scope.scopeDataConst().use.items) |u| {
            if (u.is_import or !w.env.tree.contains(u.mod_name)) continue;
            const mod = w.env.global(scope.file_ast, u.mod_name) orelse continue;
            if (w.all == null and std.mem.eql(u8, u.mod_name, w.name)) return w.found(mod);
            const there = u.nameThere(name) orelse continue;
            if (try checkScope(w.env, mod, there, true, null)) |v| {
                const all = w.all orelse return w.found(v);
                if (std.mem.findScalar(*Obj, all.items, v) == null) try all.append(w.env.tmp, v);
                continue;
            }
            if (!exportsUsedName(mod, there)) continue;
            const gop = try w.seen.getOrPut(w.env.tmp, .{ mod, std.hash.Wyhash.hash(0, there) });
            if (gop.found_existing) continue;
            const was_on_path = w.on_path;
            defer w.on_path = was_on_path;
            if (w.via) |v| if (v[0] == mod and std.mem.eql(u8, v[1], there)) {
                w.on_path = true;
            };
            if (try w.search(mod, there)) |v| return v;
        }
        return null;
    }

    fn found(w: *UseWalk, obj: *Obj) *Obj {
        w.found_on_path = w.on_path;
        return obj;
    }
};

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
                    // the included file, from its first line (the line of
                    // the INCLUDE statement is one of the including file)
                    inc.inc_obj = try Obj.newScope(inc_ast, .include, 1, inc.path, &.{});
                }
                return inc.inc_obj;
            }
        }
    }
    if (try findThroughUse(env, scope, name_lower, false)) |v| return v;
    if (!opts.interface and importHides(scope, name_lower)) return null;
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
        if (importHides(anc, name_lower)) break;
    }
    // A file included into a scope sees that scope
    if (scope.parent == null) if (scope.file_ast.included_in) |host| {
        if (host.file_ast != scope.file_ast) return findInScope(env, host, var_name, .{});
    };
    return null;
}

/// The global subroutine or function that `v`, a caller's own declaration
/// of the name, stands for (#232): a variable with the EXTERNAL attribute
/// (`external solve`, `real, external :: twice`), or, when `called` (the
/// name is called somewhere), one declared with a type and no array shape,
/// `real twice`, which declares the type of a function. Not a dummy
/// argument of the caller (a dummy procedure) nor a function's result,
/// and only when one of `files` (the workspace's `FortranFile`s) alone
/// defines a global procedure of that name.
pub fn declaredProcedure(env: Env, ast: *const objects.Ast, files: anytype, v: *const Obj, called: bool) Allocator.Error!?*Obj {
    if (v.kind != .variable) return null;
    const vd = v.varDataConst();
    if (!vd.is_external and (!called or vd.is_const or v.hasKeyword(C.KW.dimension) or v.keyword_info.dimension != null)) return null;
    const parent = v.parent orelse return null;
    switch (parent.kind) {
        .type => return null,
        .subroutine, .function => {
            if (parent.kind == .function and std.ascii.eqlIgnoreCase(parent.name, v.name)) return null;
            for (parent.procDataConst().arg_objs.items) |arg| if (arg == v) return null;
        },
        else => {},
    }
    const key = try std.ascii.allocLowerString(env.tmp, v.name);
    const cand = env.global(ast, key) orelse return null;
    switch (cand.kind) {
        .function => {},
        .subroutine => if (!vd.is_external) return null,
        else => return null,
    }
    var defined: usize = 0;
    for (files) |f| {
        const fa = f.ast orelse continue;
        const o = fa.global_dict.get(key) orelse continue;
        if (o.kind == .subroutine or o.kind == .function) defined += 1;
    }
    return if (defined == 1) cand else null;
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

/// The symbols `workspace/symbol` offers: the global objects of every file
/// (modules, submodules, programs, top-level procedures), and below
/// modules, submodules and interfaces their declarations, procedures and
/// interface bodies, the type-bound procedures of their types, and the
/// internal procedures of every procedure. Local variables and type
/// components are left out. Each object is offered once:
/// a file's procedures that an include links into other scopes are its own,
/// and of two files that define the same global name, both are offered.
/// `files` is the workspace's map of paths to `FortranFile`s.
pub fn findSymbolsInWorkspace(a: Allocator, files: anytype) ![]*Obj {
    var out: std.ArrayList(*Obj) = .empty;
    var seen: std.AutoHashMapUnmanaged(*Obj, void) = .empty;
    for (files.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.global_dict.values()) |obj| try collectSymbols(a, obj, &out, &seen);
    }
    return out.items;
}

fn collectSymbols(a: Allocator, obj: *Obj, out: *std.ArrayList(*Obj), seen: *std.AutoHashMapUnmanaged(*Obj, void)) !void {
    if ((try seen.getOrPut(a, obj)).found_existing) return;
    if (obj.name.len > 0 and obj.name[0] != '#') try out.append(a, obj);
    // its COMMON blocks (#556)
    if (obj.data == .scope) for (obj.scopeData().commons.items) |c| try collectSymbols(a, c, out, seen);
    switch (obj.getType(false)) {
        .module, .submodule, .interface => {},
        // the internal procedures after CONTAINS and the NAMELIST groups,
        // but no local variables
        .subroutine, .function => {
            for (obj.childList()) |child| if (child.kind.isSubroutine() or child.isGroup()) try collectSymbols(a, child, out, seen);
            return;
        },
        .class => {
            for (obj.childList()) |child| {
                if (child.getType(true) != C.TypeId.method) continue;
                if ((try seen.getOrPut(a, child)).found_existing) continue;
                try out.append(a, child);
            }
            return;
        },
        else => return,
    }
    for (obj.childList()) |child| try collectSymbols(a, child, out, seen);
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

test "checkScope finds through a scope's index what walking its children finds (#209)" {
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    const FortranFile = @import("../parser.zig").FortranFile;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa,
        \\module big
        \\  private
        \\  public :: v1, v3, fres, Red, ext_f
        \\  integer :: dup
        \\  real, public :: DUP
        \\  enum, bind(c)
        \\    enumerator :: red = 1, green
        \\  end enum
        \\  interface
        \\    function ext_f(x)
        \\      real :: x, ext_f
        \\    end function
        \\    subroutine ext_s()
        \\    end subroutine
        \\  end interface
        \\  interface gen
        \\    subroutine gen()
        \\    end subroutine
        \\    subroutine gen_a()
        \\    end subroutine
        \\  end interface
        \\
    );
    for (0..40) |i| try src.print(gpa, "  integer :: v{d}\n", .{i});
    try src.appendSlice(gpa,
        \\contains
        \\  function fres(a)
        \\    integer :: a, fres
        \\
    );
    for (0..40) |i| try src.print(gpa, "    integer :: w{d}\n", .{i});
    try src.appendSlice(gpa,
        \\    fres = a
        \\  end function fres
        \\end module big
        \\
    );
    const f = try FortranFile.create(gpa, "/w/big.f90", null);
    defer f.destroy();
    _ = try f.setTextOwned(try src.toOwnedSlice(gpa));
    const ast = try f.parse(std.testing.io, null, &.{}, .{});
    defer ast.destroy();
    var tree: objects.ObjTree = .empty;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const env: Env = .{ .tree = &tree, .tmp = arena.allocator() };

    const mod = ast.global_dict.get("big").?;
    try std.testing.expect(try index.of(mod) != null);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (ast.scope_list.items) |s| {
        try names.append(gpa, s.name);
        for (s.childList()) |c| {
            try names.append(gpa, c.name);
            for (c.childList()) |e| try names.append(gpa, e.name);
        }
    }
    try names.appendSlice(gpa, &.{ "RED", "Ext_F", "V39", "nothing", "#gen_int" });
    for (ast.scope_list.items) |s| for (names.items) |n| {
        const lower = try std.ascii.allocLowerString(arena.allocator(), n);
        for ([_]bool{ false, true }) |public| for ([_]?usize{ null, s.sline, s.sline + 1, s.eline }) |line| {
            const want = try walkScope(env, s, lower, public, line);
            try std.testing.expectEqual(want, try checkScope(env, s, lower, public, line));
        };
    };
    // the function's own name on its first line is not its result
    const fres = (try checkScope(env, mod, "fres", false, null)).?;
    try std.testing.expect(try index.of(fres) != null);
    try std.testing.expect(try checkScope(env, fres, "fres", false, fres.sline) == null);
    try std.testing.expect(try checkScope(env, fres, "fres", false, fres.sline + 1) != null);
    // of two declarations, the public one when only public names count
    const first = (try checkScope(env, mod, "dup", false, null)).?;
    const public = (try checkScope(env, mod, "dup", true, null)).?;
    try std.testing.expectEqualStrings("dup", first.name);
    try std.testing.expectEqualStrings("DUP", public.name);
    // an interface body of a named generic (#474), but for the one that
    // has the generic's name
    try std.testing.expect((try checkScope(env, mod, "gen_a", false, null)).?.kind == .subroutine);
    try std.testing.expect((try checkScope(env, mod, "gen", false, null)).?.kind == .interface);
    // a child added or removed after a lookup
    try std.testing.expect(try checkScope(env, mod, "late", false, null) == null);
    try mod.addChild(try Obj.newScope(ast, .scope, 1, "late", &.{}));
    try std.testing.expect(try checkScope(env, mod, "late", false, null) != null);
    mod.removeChild(mod.childList().len - 1);
    try std.testing.expect(try checkScope(env, mod, "late", false, null) == null);
    // and one added to a generic interface
    for (mod.childList()) |c| if (std.mem.startsWith(u8, c.name, "#GEN_INT")) {
        try c.addChild(try Obj.newScope(ast, .subroutine, 1, "late_s", &.{}));
    };
    try std.testing.expect(try checkScope(env, mod, "late_s", false, null) != null);
}

/// What `checkScope` finds walking every child, without an index
fn walkScope(env: Env, local_scope: *Obj, name_lower: []const u8, filter_public: bool, var_line_number: ?usize) Allocator.Error!?*Obj {
    const inherited: []const *Obj = switch (local_scope.kind) {
        .type, .subroutine, .function => local_scope.scopeDataConst().in_children.items,
        .variable, .method, .intrinsic => return null,
        else => &.{},
    };
    for ([_][]const *Obj{ local_scope.childList(), inherited }) |list| for (list) |child| {
        switch (try checkChild(env, local_scope, local_scope, child, name_lower, filter_public, var_line_number)) {
            .next => {},
            .found => |v| return v,
        }
    };
    return null;
}
