//! Resolving the links between objects after parsing: inherited types, the
//! types of variables, procedure arguments and pointers, submodule
//! implementations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const C = @import("../constants.zig");
const KW = C.KW;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const objects = @import("../objects.zig");
const Obj = objects.Obj;
const Env = objects.Env;
const findInScope = objects.findInScope;
const climbTypeTree = objects.climbTypeTree;
const selector = @import("selector.zig");
const dimensions = @import("dimensions.zig");
const argcheck = @import("../argcheck.zig");
const typing = @import("../argcheck/typing.zig");

pub fn resolveInherit(self: *Obj, env: Env, inherit_version: i64) Allocator.Error!void {
    switch (self.kind) {
        .type => {
            const sc = self.scopeData();
            const td = self.typeData();
            if (sc.inherit == null or td.inherit_version == inherit_version) return;
            td.inherit_version = inherit_version;
            td.inherit_var = try findInScope(env, self.parent, sc.inherit.?, .{});
            if (td.inherit_var) |iv| {
                // Resolve parent inheritance while avoiding circular recursion
                td.inherit_tmp = sc.inherit;
                sc.inherit = null;
                try iv.resolveInherit(env, inherit_version);
                sc.inherit = td.inherit_tmp;
                td.inherit_tmp = null;
                sc.in_children.clearRetainingCapacity();
                const parent_children = try iv.getChildren(env.tmp, false);
                for (parent_children) |child| {
                    var found = false;
                    for (sc.children.items) |own| {
                        if (std.ascii.eqlIgnoreCase(own.name, child.name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try sc.in_children.append(self.al(), child);
                }
            } else {
                sc.in_children.clearRetainingCapacity();
            }
        },
        .submodule => self.submodData().ancestor_obj = self.findSubmoduleParent(env),
        else => {},
    }
}

/// Whether linking `self` to `target` would make a loop of `link_obj`s
/// (e.g. bindings naming each other while code is being edited), which
/// everything that follows links would recurse around forever. Python
/// fortls hits a RecursionError there.
pub fn linkLoops(self: *const Obj, target: *const Obj) bool {
    var o: ?*const Obj = target;
    var hops: usize = 0;
    while (o) |cur| : (o = cur.linkObj()) {
        if (cur == self) return true;
        hops += 1;
        // a loop not through `self` (which no link made here allows)
        if (hops > 1000) return true;
    }
    return false;
}

pub fn resolveLink(self: *Obj, env: Env) Allocator.Error!void {
    switch (self.kind) {
        .variable => {
            const v = self.varData();
            v.link_obj = null;
            v.type_obj = null;
            v.selector_obj = null;
            v.assumed_size = false;
            const p = self.parent orelse return;
            if (v.type_of) |to| try resolveTypeOf(env, self, p, to);
            if (v.rank_clause) |r| try resolveRankClause(env, self, p, r);
            // the associate name of a block of SELECT TYPE or RANK: its
            // selector, with its rank (`it => items(i)`), found outside
            // the construct
            const construct: ?*Obj = if (p.isTypeRegion()) p.parent else null;
            if (v.link_name) |ln| {
                const found = if (construct) |c| try selectorVariable(env, c, ln) else try findInScope(env, p, ln, .{});
                if (found) |l| {
                    if (!self.linkLoops(l)) v.link_obj = l;
                }
                if (construct) |c| if (v.link_obj != null) {
                    v.slice_rank = try selector.associateRank(env, c, ln, self.sline, v.link_obj);
                    if (self.isRankName()) try caseRank(env, p, v, p.selectDataConst().case_rank);
                };
            } else if (self.isGuardName()) {
                // a TYPE IS or CLASS IS name: the selector's rank and
                // attributes, the guard's type (#701)
                // (in code being edited the block may be in no SELECT TYPE)
                const c = construct orelse return;
                if (!c.isTypeBinding()) return;
                const text = c.selectDataConst().bound_var orelse return;
                if (try selectorVariable(env, c, text)) |o| if (o.kind == .variable) {
                    v.selector_obj = o;
                };
                v.slice_rank = try selector.associateRank(env, c, text, self.sline, v.selector_obj);
            }
        },
        .method => {
            const v = self.varData();
            v.link_obj = null;
            v.type_obj = null;
            const ln = v.link_name orelse return;
            const p = self.parent orelse return;
            const link_obj = if (p.getType(false) == C.TypeId.class)
                try findInScope(env, p.parent, ln, .{})
            else
                try findInScope(env, p, ln, .{});
            if (link_obj) |l| {
                if (self.linkLoops(l)) return;
                v.link_obj = l;
                if (v.pass_name) |pn| {
                    const pnl = try std.ascii.allocLowerString(self.al(), pn);
                    v.pass_name = pnl;
                    if (l.kind.isSubroutine()) {
                        var it = std.mem.splitScalar(u8, l.procData().args_snip, ',');
                        var i: usize = 0;
                        while (it.next()) |arg| : (i += 1) {
                            if (std.ascii.eqlIgnoreCase(arg, pnl)) {
                                v.drop_arg = i;
                                break;
                            }
                        }
                    }
                }
            }
        },
        .interface => {
            const mems = &self.ifaceData().mems;
            mems.clearRetainingCapacity();
            const p = self.parent orelse return;
            for (self.scopeData().members.items) |member| {
                if (try specificOf(env, self, p, member)) |m| try mems.append(self.al(), m);
            }
            // and the interface bodies of a generic (#472); those of an
            // interface block that has no generic specification declare
            // external procedures, and those of an abstract one, abstract
            // interfaces: names of the scope around, no specifics
            if (self.ifaceData().generic) for (self.childList()) |child| {
                if (child.kind.isSubroutine()) try mems.append(self.al(), child);
            };
            try resolveExtended(env, self);
        },
        .subroutine => try self.resolveArgLink(env.tmp),
        .function => {
            try self.resolveArgLink(env.tmp);
            const proc = self.procData();
            const rn = proc.result_name orelse self.name;
            for ((proc.entry_of orelse self).childList()) |child| {
                if (std.ascii.eqlIgnoreCase(child.name, rn)) {
                    proc.result_obj = child;
                    proc.result_name = child.name;
                    proc.result_type = try child.getDesc(self.al());
                }
            }
        },
        .submodule => try self.resolveSubmoduleLink(env),
        .associate => {
            // the selectors are names of the scope around the construct
            // (`associate (x => x%field)`: the outer `x`)
            const outer = self.parent orelse self;
            for (self.assocData().links.items) |*assoc| {
                const v = assoc.var_.varData();
                v.link_obj = null;
                // of a conditional expression, its first value (#733)
                const sel = typing.conditionalValue(assoc.link_name) orelse assoc.link_name;
                if (try selectorVariable(env, outer, sel)) |found| {
                    // of a call of a function, its result (#721)
                    const result = if (found.kind == .function) functionResult(found) else found;
                    if (result) |o| if (!assoc.var_.linkLoops(o)) {
                        v.link_obj = o;
                        // (a call's arguments are no subscripts)
                        v.slice_rank = if (found == o) try selector.associateRank(env, outer, sel, self.sline, o) else -1;
                        continue;
                    };
                    if (found.kind == .function) if (found.procData().result_type) |rt| {
                        const open = std.mem.findScalar(u8, rt, '(');
                        v.desc = rt[0 .. open orelse rt.len];
                        v.vkind = if (open) |i| rt[i..] else null;
                        v.slice_rank = -1;
                        continue;
                    };
                }
                v.slice_rank = try selector.associateRank(env, outer, sel, self.sline, null);
                // a literal or an expression: its type
                const t = try selector.typeOf(env, outer, sel, self.sline);
                v.desc = if (t) |typ| try self.al().dupe(u8, typ.desc) else "UNKNOWN";
                v.vkind = if (t) |typ| if (typ.kind) |k| try self.al().dupe(u8, k) else null else null;
            }
        },
        else => {},
    }
}

/// The type of a variable declared `TYPEOF(ref)` or `CLASSOF(ref)` in
/// `scope` (#728): that of `ref`, a variable or a component; CLASS for
/// CLASSOF of a derived type. While `ref` is not found it stays `TYPEOF`.
fn resolveTypeOf(env: Env, self: *Obj, scope: *Obj, to: objects.TypeOf) Allocator.Error!void {
    const v = self.varData();
    v.desc = if (to.class) "CLASSOF" else "TYPEOF";
    v.vkind = to.ref;
    const inner = std.mem.trim(u8, to.ref, "() ");
    var src = (try selectorVariable(env, scope, inner)) orelse return;
    for (0..16) |_| src = if (src.kind == .variable) src.varDataConst().link_obj orelse break else break;
    if (src == self or src.kind != .variable) return;
    const d = src.varDataConst();
    // (another TYPEOF not resolved yet)
    if (std.mem.eql(u8, d.desc, "TYPEOF") or std.mem.eql(u8, d.desc, "CLASSOF")) return;
    const derived = std.ascii.eqlIgnoreCase(d.desc, "TYPE") or std.ascii.eqlIgnoreCase(d.desc, "CLASS");
    // TYPEOF of a polymorphic entity: its declared type
    v.desc = if (!derived) d.desc else if (to.class) "CLASS" else "TYPE";
    v.vkind = d.vkind;
    // the type the entity sees, which need not be visible here
    if (derived) v.type_obj = try src.getTypeObj(env);
}

/// The DIMENSION of a variable declared with RANK(`expr`) in `scope` (#729):
/// that of the constant rank, else assumed rank, which the argument checks
/// take as a rank not known
fn resolveRankClause(env: Env, self: *Obj, scope: *Obj, expr: []const u8) Allocator.Error!void {
    const n = (try argcheck.constantValue(env.tmp, env, self.file_ast, scope, expr, self.sline)) orelse -1;
    const dims: ?[]const u8 = if (n < 0 or n > 15) ".." else dimensions.ofRank(@intCast(n), false);
    const info = try self.al().create(helpers.KeywordInfo);
    info.* = self.keyword_info.*;
    info.dimension = dims;
    self.keyword_info = info;
    const at = std.mem.findScalar(C.Kw, self.keywords.items, KW.dimension);
    if (dims == null) {
        if (at) |i| _ = self.keywords.orderedRemove(i);
    } else if (at == null) try self.keywords.append(self.al(), KW.dimension);
}

/// The rank a case of SELECT RANK gives its associate name `v`: `0`, `2`,
/// assumed size for `*`, that of a constant expression in `block` (`rank
/// (zero)`, #717); that of the selector (assumed rank) for RANK DEFAULT or
/// a rank that cannot be told (#706)
fn caseRank(env: Env, block: *Obj, v: *objects.Variable, case_rank: ?[]const u8) Allocator.Error!void {
    const r = case_rank orelse return;
    if (std.mem.eql(u8, r, "*")) {
        v.slice_rank = 1;
        v.assumed_size = true;
        return;
    }
    const n = (try argcheck.constantValue(env.tmp, env, block.file_ast, block, r, block.sline)) orelse return;
    if (n >= 0 and n <= 15) v.slice_rank = @intCast(n);
}

/// The variable or component that selector `text` names in `scope`, its
/// subscripts aside (`x`, `t%c`, `b(:, 1)`), or null for an expression
fn selectorVariable(env: Env, scope: *Obj, text: []const u8) Allocator.Error!?*Obj {
    const name = try withoutParentheses(env.tmp, text);
    if (!selector.isDesignator(name)) return null;
    const var_stack = try helpers.getVarStack(env.tmp, name);
    if (var_stack.len == 1) return findInScope(env, scope, str.strip(name), .{});
    const type_scope = (try climbTypeTree(env, var_stack, scope)) orelse return null;
    return findInScope(env, type_scope, var_stack[var_stack.len - 1], .{});
}

/// `text` without what its parentheses hold, `a(i)%b(2)%c` as `a%b%c`
fn withoutParentheses(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (text) |c| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        else => if (depth == 0) try out.append(a, c),
    };
    return out.items;
}

/// The result variable of function `f`, or null when it has none (its
/// type in its prefix, `type(t) function f()`)
fn functionResult(f: *Obj) ?*Obj {
    const proc = f.procData();
    if (proc.result_obj) |r| return r;
    const rn = proc.result_name orelse f.name;
    for (f.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, rn)) return c;
    return null;
}

/// The specific procedure `name` of generic interface `generic`, whose
/// scope is `scope`: what the name stands for there, unless that is the
/// generic itself, a generic having the name of one of its specifics
/// (`interface sync` with `module procedure sync`, #469); then the other
/// object of that name in the scope, by USE or in the host.
fn specificOf(env: Env, generic: *Obj, scope: *Obj, name: []const u8) Allocator.Error!?*Obj {
    const found = try findInScope(env, scope, name, .{});
    if (found != generic) return found;
    for (scope.childList()) |child| {
        if (child != generic and std.ascii.eqlIgnoreCase(child.name, name)) return child;
    }
    if (try objects.findThroughUse(env, scope, try std.ascii.allocLowerString(env.tmp, name), false)) |v| return v;
    return findInScope(env, scope.parent, name, .{});
}

/// Whether `o` is a generic interface with a generic name (not an
/// OPERATOR or ASSIGNMENT block, whose blocks the operator requests
/// gather over the workspace)
fn isNamedGeneric(o: *const Obj) bool {
    return o.kind == .interface and o.ifaceDataConst().generic and o.name.len > 0 and o.name[0] != '#';
}

/// A generic is one with the other interface blocks of its name that it
/// sees (#478): those of its scope, those that USE brings in (of every
/// module that has the name), or else that its host has; and so those
/// blocks' own in turn. Their specifics are appended to `self`'s, which
/// lists them in `extends`.
fn resolveExtended(env: Env, self: *Obj) Allocator.Error!void {
    const iface = self.ifaceData();
    iface.extends.clearRetainingCapacity();
    if (!isNamedGeneric(self)) return;
    const scope = self.parent orelse return;
    if (scope.kind == .type) return;
    var seen: std.ArrayList(*Obj) = .empty;
    try seen.append(env.tmp, self);
    try addBlocks(env, self, scope, try std.ascii.allocLowerString(env.tmp, self.name), &seen);
    for (seen.items[1..]) |g| try iface.extends.append(self.al(), g);
}

/// For `resolveExtended`: the blocks of generic `name` in `scope` not yet
/// `seen`, and then those `scope` sees of the name
fn addBlocks(env: Env, self: *Obj, scope: *Obj, name: []const u8, seen: *std.ArrayList(*Obj)) Allocator.Error!void {
    for (scope.childList()) |g| {
        if (!isNamedGeneric(g) or !std.ascii.eqlIgnoreCase(g.name, name)) continue;
        if (std.mem.findScalar(*Obj, seen.items, g) != null) continue;
        try seen.append(env.tmp, g);
        const p = g.parent orelse continue;
        const mems = &self.ifaceData().mems;
        for (g.scopeData().members.items) |member| {
            const m = (try specificOf(env, g, p, member)) orelse continue;
            if (std.mem.findScalar(*Obj, mems.items, m) == null) try mems.append(self.al(), m);
        }
        for (g.childList()) |m| {
            if (m.kind.isSubroutine() and std.mem.findScalar(*Obj, mems.items, m) == null) try mems.append(self.al(), m);
        }
    }
    var used: std.ArrayList(*Obj) = .empty;
    try objects.findAllThroughUse(env, scope, name, &used);
    for (used.items) |g| {
        if (!isNamedGeneric(g) or std.mem.findScalar(*Obj, seen.items, g) != null) continue;
        const p = g.parent orelse continue;
        try addBlocks(env, self, p, try std.ascii.allocLowerString(env.tmp, g.name), seen);
    }
    if (used.items.len > 0) return;
    // the host's: not of an interface body, which has none
    const host = scope.parent orelse return;
    if (host.kind == .interface or scope.kind == .module or scope.kind == .submodule) return;
    // a name of the host that is no generic hides those it sees
    if (try findInScope(env, host, name, .{ .local_only = true })) |o| if (!isNamedGeneric(o)) return;
    try addBlocks(env, self, host, name, seen);
}

/// `t`: for the time of the call (a page allocator's arena for each of a
/// workspace's procedures made linking it several times slower, #219)
pub fn resolveArgLink(self: *Obj, t: Allocator) !void {
    const proc = self.procData();
    if (proc.args.len == 0 or self.scopeData().in_children.items.len > 0) return;
    const a = self.al();
    const arg_list = try str.split(t, proc.args, ",");
    const arg_list_lower = try str.split(t, try std.ascii.allocLowerString(t, proc.args), ",");
    proc.arg_objs.clearRetainingCapacity();
    try proc.arg_objs.appendNTimes(a, null, arg_list.len);
    proc.missing_args.clearRetainingCapacity();
    // an ENTRY's are the variables of the procedure it is an entry of
    const owner = proc.entry_of orelse self;
    for (owner.childList()) |child| {
        var ind: ?usize = null;
        for (arg_list_lower, 0..) |arg, i| {
            if (std.ascii.eqlIgnoreCase(arg, child.name)) {
                ind = i;
                break;
            } else if (std.ascii.startsWithIgnoreCase(child.name, "#gen_int")) {
                for (child.childList()) |sub_child| {
                    if (std.ascii.eqlIgnoreCase(arg, sub_child.name)) {
                        proc.arg_objs.items[i] = sub_child;
                        break;
                    }
                }
            }
        }
        if (ind) |i| {
            proc.arg_objs.items[i] = child;
            if (child.isOptional()) arg_list[i] = try t.print("{s}={s}", .{ arg_list[i], arg_list[i] });
        } else if (child.hasKeyword(KW.intent) and owner == self) {
            try proc.missing_args.append(a, child);
        }
    }
    const snip = try std.mem.join(t, ",", arg_list);
    if (!std.mem.eql(u8, snip, proc.args_snip)) proc.args_snip = try a.dupe(u8, snip);
}

/// `Subroutine.copy_interface`; returns lowercased child names
pub fn copyInterface(self: *Obj, src: *Obj) !void {
    // `src` is usually in another file's AST, which is freed when that
    // file is re-parsed: own copies of its strings
    const a = self.al();
    const proc = self.procData();
    const from = src.procData();
    const in_children = &self.scopeData().in_children;
    proc.linked_from_interface = true;
    proc.args = try a.dupe(u8, from.args);
    proc.args_snip = try a.dupe(u8, from.args_snip);
    // Python shares the list object; copy the contents
    proc.arg_objs.clearRetainingCapacity();
    try proc.arg_objs.appendSlice(a, from.arg_objs.items);
    in_children.clearRetainingCapacity();
    for (from.arg_objs.items) |child_opt| {
        const child = child_opt orelse continue;
        if (!self.hasChildNamed(child.name)) try in_children.append(a, child);
    }
    if (self.kind == .function) {
        proc.result_name = if (from.result_name) |n| try a.dupe(u8, n) else null;
        proc.result_type = if (from.result_type) |t| try a.dupe(u8, t) else null;
        proc.result_obj = from.result_obj;
        if (from.result_obj) |ro| {
            if (!self.hasChildNamed(ro.name)) try in_children.append(a, ro);
        }
    }
}

/// Drop data imported by `copyInterface` (it may reference other ASTs)
pub fn resetInterfaceCopy(self: *Obj) void {
    self.scopeData().in_children.clearRetainingCapacity();
    const proc = self.procData();
    proc.arg_objs.clearRetainingCapacity();
    if (proc.result_obj) |ro| if (ro.file_ast != self.file_ast) {
        proc.result_obj = null;
    };
    proc.linked_from_interface = false;
}

pub fn hasChildNamed(self: *const Obj, name: []const u8) bool {
    for (self.childList()) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return true;
    return false;
}

pub fn resolveSubmoduleLink(self: *Obj, env: Env) !void {
    // Collect the interface prototypes of the ancestor module and of the
    // parent submodules (looked up here, as their own links may not be
    // resolved yet)
    var interfaces: std.ArrayList(*Obj) = .empty;
    var visited: std.ArrayList(*const Obj) = .empty;
    var cur: *const Obj = self;
    outer: while (cur.kind == .submodule) {
        try visited.append(env.tmp, cur);
        const anc = cur.findSubmoduleParent(env) orelse break;
        for (visited.items) |v| if (v == anc) break :outer;
        for (anc.childList()) |child| {
            if (child.getType(false) != C.TypeId.interface) continue;
            for (child.childList()) |iface| {
                const it = iface.getType(false);
                if ((it == C.TypeId.subroutine or it == C.TypeId.function or it == C.TypeId.base) and iface.isModScope()) {
                    try interfaces.append(env.tmp, iface);
                }
            }
        }
        cur = anc;
    }
    for (interfaces.items) |iface| {
        for (self.childList()) |child| {
            if (!std.ascii.eqlIgnoreCase(child.name, iface.name)) continue;
            if (child.getType(false) == C.TypeId.base) {
                // Convert the plain scope into a subroutine/function in place
                if (iface.kind == .subroutine) {
                    child.becomeProcedure(.subroutine);
                } else if (iface.kind == .function) {
                    child.becomeProcedure(.function);
                    child.procData().result_name = child.name;
                    child.keyword_info = &helpers.KeywordInfo.empty;
                } else continue;
                const proc = child.procData();
                proc.args = "";
                proc.args_snip = "";
                proc.mod_scope = false;
            }
            if (child.getType(false) == iface.getType(false)) {
                iface.procData().link_obj = child;
                try iface.resolveLink(env);
                try child.copyInterface(iface);
                break;
            }
        }
    }
}

pub fn getTypeObj(self: *Obj, env: Env) !?*Obj {
    if (!self.kind.isVariable()) return null;
    if (self.linkObj()) |l| return l.getTypeObj(env);
    if (self.varData().type_obj == null) if (self.parent) |p| {
        const desc = try self.getDescNoLink(env.tmp);
        if (helpers.getParenSubstring(desc)) |tn| {
            var search_scope: ?*Obj = p;
            // without the type parameters of a parameterized type,
            // `box(n=3)` (#723)
            const type_name = try std.ascii.allocLowerString(env.tmp, str.strip(str.beforeFirst(tn, "(")));
            if (p.getType(false) == C.TypeId.class) {
                search_scope = p.parent;
                // a structure nested in a DEC structure is its child
                for (p.childList()) |c| if (c.kind == .type and c.nameLowerEql(type_name)) {
                    self.varData().type_obj = c;
                    return c;
                };
            }
            if (search_scope) |ss| {
                if (try findInScope(env, ss, type_name, .{})) |t| self.varData().type_obj = t;
            }
        }
    };
    return self.varData().type_obj;
}

pub fn getOverridden(self: *const Obj, a: Allocator, field_name: []const u8) ![]*Obj {
    var out: std.ArrayList(*Obj) = .empty;
    if (self.kind != .type) return out.items;
    for (self.childList()) |child| {
        if (std.ascii.eqlIgnoreCase(child.name, field_name)) {
            try out.append(a, child);
            break;
        }
    }
    if (self.typeDataConst().inherit_var) |iv| try out.appendSlice(a, try iv.getOverridden(a, field_name));
    return out.items;
}
