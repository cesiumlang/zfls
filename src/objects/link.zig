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
            const ln = v.link_name orelse return;
            if (self.parent) |p| {
                if (try findInScope(env, p, ln, .{})) |l| {
                    if (!self.linkLoops(l)) v.link_obj = l;
                }
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
                if (try findInScope(env, p, member, .{})) |m| try mems.append(self.al(), m);
            }
        },
        .subroutine => try self.resolveArgLink(),
        .function => {
            try self.resolveArgLink();
            const proc = self.procData();
            const rn = proc.result_name orelse self.name;
            for (self.childList()) |child| {
                if (std.ascii.eqlIgnoreCase(child.name, rn)) {
                    proc.result_obj = child;
                    proc.result_name = child.name;
                    proc.result_type = try child.getDesc(self.al());
                }
            }
        },
        .submodule => try self.resolveSubmoduleLink(env),
        .associate => {
            for (self.assocData().links.items) |*assoc| {
                assoc.var_.varData().link_obj = null;
                assoc.link_name = try R().PAREN_CONTENT.sub(self.al(), "", assoc.link_name);
                const var_stack = try helpers.getVarStack(env.tmp, assoc.link_name);
                var var_obj: ?*Obj = null;
                if (var_stack.len > 1) {
                    const type_scope = (try climbTypeTree(env, var_stack, self)) orelse continue;
                    var_obj = try findInScope(env, type_scope, var_stack[var_stack.len - 1], .{});
                } else {
                    var_obj = try findInScope(env, self, assoc.link_name, .{});
                }
                if (var_obj) |v| if (!assoc.var_.linkLoops(v)) {
                    assoc.var_.varData().link_obj = v;
                };
            }
        },
        else => {},
    }
}

pub fn resolveArgLink(self: *Obj) !void {
    const proc = self.procData();
    if (proc.args.len == 0 or self.scopeData().in_children.items.len > 0) return;
    const a = self.al();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const arg_list = try str.split(t, proc.args, ",");
    const arg_list_lower = try str.split(t, try std.ascii.allocLowerString(t, proc.args), ",");
    proc.arg_objs.clearRetainingCapacity();
    try proc.arg_objs.appendNTimes(a, null, arg_list.len);
    proc.missing_args.clearRetainingCapacity();
    for (self.childList()) |child| {
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
            if (child.isOptional()) arg_list[i] = try std.fmt.allocPrint(t, "{s}={s}", .{ arg_list[i], arg_list[i] });
        } else if (child.hasKeyword(KW.intent)) {
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
            const type_name = try std.ascii.allocLowerString(env.tmp, str.strip(tn));
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
