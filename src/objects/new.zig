//! Creating objects: scopes, procedures, types, interfaces, variables and the
//! other kinds of `Obj`.

const std = @import("std");
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const C = @import("../constants.zig");
const KW = C.KW;
const parser = @import("../parser.zig");

const KeywordInfo = helpers.KeywordInfo;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const objects = @import("../objects.zig");
const Obj = objects.Obj;
const Kind = objects.Kind;
const ScopeExt = objects.ScopeExt;
const Scope = objects.Scope;
const Variable = objects.Variable;
const Ast = objects.Ast;

/// The scope data a new object of `kind` starts with
pub fn scopeExtFor(kind: Kind) ScopeExt {
    return switch (kind) {
        .submodule => .{ .submodule = .{} },
        .subroutine, .function => .{ .procedure = .{} },
        .type => .{ .type = .{} },
        .interface => .{ .interface = .{} },
        .associate => .{ .associate = .{} },
        .select => .{ .select = .{} },
        else => .none,
    };
}

/// Turn a plain scope into a subroutine or function in place (a
/// MODULE PROCEDURE implementing a prototype), keeping its children
pub fn becomeProcedure(self: *Obj, kind: Kind) void {
    std.debug.assert(kind == .subroutine or kind == .function);
    self.kind = kind;
    if (self.data.scope.ext != .procedure) self.data.scope.ext = .{ .procedure = .{} };
}

/// Create a Scope-derived object (`Scope.__init__`)
pub fn newScope(file_ast: *Ast, kind: Kind, line_number: usize, name: []const u8, keywords: []const C.Kw) !*Obj {
    std.debug.assert(kind.isScope());
    const a = file_ast.allocator();
    const o = try a.create(Obj);
    const nm = try a.dupe(u8, name);
    o.* = .{
        .kind = kind,
        .name = nm,
        .file_ast = file_ast,
        .sline = line_number,
        .eline = line_number,
        .fqsn = try Obj.computeFqsn(a, file_ast, nm),
        .data = .{ .scope = try a.create(Scope) },
    };
    o.data.scope.* = .{ .ext = scopeExtFor(kind) };
    try o.keywords.appendSlice(a, keywords);
    switch (kind) {
        .type => {
            o.typeData().abstract = o.hasKeyword(KW.abstract);
            if (o.hasKeyword(KW.public)) o.vis = .public;
            if (o.hasKeyword(KW.private)) o.vis = .private;
        },
        else => {},
    }
    return o;
}

pub fn newInterface(file_ast: *Ast, line_number: usize, name: []const u8, abstract: bool) !*Obj {
    const o = try newScope(file_ast, .interface, line_number, name, &.{});
    o.ifaceData().abstract = abstract;
    o.ifaceData().external = std.mem.startsWith(u8, name, "#GEN_INT") and !abstract;
    return o;
}

pub fn newSubmodule(file_ast: *Ast, line_number: usize, name: []const u8, ancestor_name: []const u8, parent_smod_name: []const u8) !*Obj {
    const o = try newScope(file_ast, .submodule, line_number, name, &.{});
    o.submodData().ancestor_name = try o.al().dupe(u8, ancestor_name);
    o.submodData().parent_smod_name = try o.al().dupe(u8, parent_smod_name);
    return o;
}

pub fn newSubroutine(file_ast: *Ast, line_number: usize, name: []const u8, args: []const u8, mod_flag: bool, keywords: []const C.Kw) !*Obj {
    const o = try newScope(file_ast, .subroutine, line_number, name, keywords);
    const a = o.al();
    const p = o.procData();
    p.args = try std.mem.replaceOwned(u8, a, args, " ", "");
    p.args_snip = p.args;
    p.mod_scope = mod_flag;
    return o;
}

pub fn newFunction(file_ast: *Ast, line_number: usize, name: []const u8, opts: Obj.FunOpts) !*Obj {
    const o = try newScope(file_ast, .function, line_number, name, opts.keywords);
    const a = o.al();
    const p = o.procData();
    p.args = try std.ascii.allocLowerString(a, try std.mem.replaceOwned(u8, a, opts.args, " ", ""));
    p.args_snip = p.args;
    p.mod_scope = opts.mod_flag;
    p.result_name = try str.dupeOpt(a, opts.result_name);
    p.result_type = try str.dupeOpt(a, opts.result_type);
    o.keyword_info = try opts.keyword_info.dupe(a);
    if (p.result_name == null) p.result_name = o.name;
    return o;
}

pub fn newSelect(file_ast: *Ast, line_number: usize, name: []const u8, info: parser.SelectInfo) !*Obj {
    const o = try newScope(file_ast, .select, line_number, name, &.{});
    const a = o.al();
    const sel = o.selectData();
    sel.select_type = info.type;
    if (sel.select_type == 2) {
        const binding = info.binding orelse "";
        const parts = try str.split(a, binding, "=>");
        if (parts.len == 1) {
            sel.bound_var = try a.dupe(u8, str.strip(parts[0]));
        } else if (parts.len == 2) {
            sel.binding_name = try a.dupe(u8, str.strip(parts[0]));
            sel.bound_var = try a.dupe(u8, str.strip(parts[1]));
        }
    } else if (sel.select_type == 3) {
        sel.binding_type = try str.dupeOpt(a, info.binding);
    }
    // Close previous "TYPE IS" region if open
    if (file_ast.current_scope) |cs| {
        if (cs.getType(false) == C.TypeId.select and cs.isTypeRegion()) {
            try file_ast.endScope(line_number, true);
        }
    }
    return o;
}

/// `Variable.__init__`
pub fn newVariable(file_ast: *Ast, line_number: usize, name: []const u8, var_desc: []const u8, keywords: []const C.Kw, opts: Obj.VarOpts) !*Obj {
    const a = file_ast.allocator();
    const o = try a.create(Obj);
    const nm = try a.dupe(u8, name);
    o.* = .{
        .kind = .variable,
        .name = nm,
        .file_ast = file_ast,
        .sline = line_number,
        .eline = line_number,
        .keyword_info = try opts.keyword_info.dupe(a),
        .fqsn = try Obj.computeFqsn(a, file_ast, nm),
        .data = .{ .variable = .{
            .desc = try a.dupe(u8, var_desc),
            .vkind = try str.dupeOpt(a, opts.kind),
        } },
    };
    try o.keywords.appendSlice(a, keywords);
    const v = o.varData();
    v.callable = R().CLASS_VAR.match(try o.getDescNoLink(a)) != null;
    if (opts.link_obj) |l| v.link_name = try std.ascii.allocLowerString(a, l);
    if (o.hasKeyword(KW.public)) o.vis = .public;
    if (o.hasKeyword(KW.private)) o.vis = .private;
    if (o.hasKeyword(KW.parameter)) v.is_const = true;
    if (o.hasKeyword(KW.external) or std.ascii.eqlIgnoreCase(v.desc, "external")) v.is_external = true;
    return o;
}

/// `Method.__init__` (type-bound procedure / procedure pointer)
pub fn newMethod(file_ast: *Ast, line_number: usize, name: []const u8, var_desc: []const u8, keywords: []const C.Kw, keyword_info: KeywordInfo, proc_ptr: ?[]const u8, link_obj: ?[]const u8) !*Obj {
    const o = try newVariable(file_ast, line_number, name, var_desc, keywords, .{
        .keyword_info = keyword_info,
        .kind = proc_ptr,
        .link_obj = link_obj,
    });
    const a = o.al();
    o.kind = .method;
    const v = o.varData();
    v.drop_arg = null;
    v.pass_name = o.keyword_info.pass;
    if (link_obj == null) {
        const d = try std.ascii.allocLowerString(a, try o.getDescNoLink(a));
        if (helpers.getParenSubstring(d)) |sub| v.link_name = sub else v.link_name = null;
    }
    return o;
}

pub fn newIntrinsic(file_ast: *Ast, name: []const u8, itype: C.TypeId, doc_str: ?[]const u8, args: []const u8) !*Obj {
    const a = file_ast.allocator();
    const o = try a.create(Obj);
    o.* = .{
        .kind = .intrinsic,
        .name = try a.dupe(u8, name),
        .file_ast = file_ast,
        .doc_str = try str.dupeOpt(a, doc_str),
        .fqsn = "",
        .data = .{ .intrinsic = .{
            .itype = itype,
            .args = try std.mem.replaceOwned(u8, a, args, " ", ""),
        } },
    };
    return o;
}
