//! Fortran object model and AST (port of `fortls.parsers.internal.*`
//! object classes: scope, module, subroutine, function, type, variable, ...).
//!
//! All Fortran objects share the single `Obj` struct; `kind` selects the
//! Python class whose behavior is mimicked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("str.zig");
const helpers = @import("helpers.zig");
const patterns = @import("patterns.zig");
const regex = @import("regex.zig");
const C = @import("constants.zig");
const KW = C.KW;
const parser = @import("parser.zig");
const FortranFile = parser.FortranFile;

const KeywordInfo = helpers.KeywordInfo;

fn R() *const patterns.Patterns {
    return patterns.get();
}

pub const Kind = enum {
    /// plain `Scope` (e.g. MODULE PROCEDURE implementation in a submodule)
    scope,
    include,
    module,
    program,
    submodule,
    subroutine,
    function,
    type,
    interface,
    block,
    do_,
    if_,
    where,
    enum_,
    associate,
    select,
    variable,
    method,
    intrinsic,

    pub fn isScope(k: Kind) bool {
        return switch (k) {
            .variable, .method, .intrinsic => false,
            else => true,
        };
    }

    pub fn isBlock(k: Kind) bool {
        return switch (k) {
            .block, .do_, .if_, .where, .enum_, .associate, .select => true,
            else => false,
        };
    }

    pub fn isSubroutine(k: Kind) bool {
        return k == .subroutine or k == .function;
    }

    pub fn isModule(k: Kind) bool {
        return k == .module or k == .program or k == .submodule;
    }

    pub fn isVariable(k: Kind) bool {
        return k == .variable or k == .method;
    }
};

/// Declared visibility of an object, `default` when no PUBLIC or PRIVATE applies
pub const Vis = enum { private, default, public };

pub const ImportType = enum(i8) { default = -1, none = 0, all = 1, only = 2 };

/// USE or IMPORT statement
pub const UseStmt = struct {
    mod_name: []const u8,
    only_list: StrSet = .{},
    rename_map: StrMap = .{},
    line_number: usize = 0,
    is_import: bool = false,
    import_type: ImportType = .default,
    /// Parent scope of IMPORT statement i.e. parent of the interface
    scope: ?*Obj = null,

    /// Construct (lowercasing names like the Python `Use` initializer)
    pub fn init(a: Allocator, mod_name: []const u8, only: []const []const u8, renames: []const [2][]const u8) !*UseStmt {
        const u = try a.create(UseStmt);
        u.* = .{ .mod_name = try std.ascii.allocLowerString(a, mod_name) };
        for (only) |o| try u.only_list.add(a, try std.ascii.allocLowerString(a, o));
        for (renames) |r| try u.rename_map.put(a, try std.ascii.allocLowerString(a, r[0]), try std.ascii.allocLowerString(a, r[1]));
        return u;
    }

    /// Rename ONLY:, statements
    pub fn rename(self: *const UseStmt, a: Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.only_list.items.items) |name| {
            try out.append(a, self.rename_map.get(name) orelse name);
        }
        return out.items;
    }
};

/// Ordered string set (stand-in for Python `set[str]`)
pub const StrSet = struct {
    items: std.ArrayList([]const u8) = .empty,

    pub fn contains(self: *const StrSet, s: []const u8) bool {
        for (self.items.items) |it| if (std.mem.eql(u8, it, s)) return true;
        return false;
    }

    pub fn add(self: *StrSet, a: Allocator, s: []const u8) !void {
        if (!self.contains(s)) try self.items.append(a, s);
    }

    pub fn len(self: *const StrSet) usize {
        return self.items.items.len;
    }

    pub fn clone(self: *const StrSet, a: Allocator) !StrSet {
        return .{ .items = try self.items.clone(a) };
    }
};

/// Ordered string map (stand-in for Python `dict[str, str]`)
pub const StrMap = struct {
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    pub fn hasValue(self: *const StrMap, v: []const u8) bool {
        for (self.values.items) |value| if (std.mem.eql(u8, value, v)) return true;
        return false;
    }

    pub fn get(self: *const StrMap, k: []const u8) ?[]const u8 {
        for (self.keys.items, 0..) |key, i| if (std.mem.eql(u8, key, k)) return self.values.items[i];
        return null;
    }

    pub fn put(self: *StrMap, a: Allocator, k: []const u8, v: []const u8) !void {
        for (self.keys.items, 0..) |key, i| if (std.mem.eql(u8, key, k)) {
            self.values.items[i] = v;
            return;
        };
        try self.keys.append(a, k);
        try self.values.append(a, v);
    }

    pub fn remove(self: *StrMap, k: []const u8) void {
        for (self.keys.items, 0..) |key, i| if (std.mem.eql(u8, key, k)) {
            _ = self.keys.orderedRemove(i);
            _ = self.values.orderedRemove(i);
            return;
        };
    }

    pub fn count(self: *const StrMap) usize {
        return self.keys.items.len;
    }

    pub fn clone(self: *const StrMap, a: Allocator) !StrMap {
        return .{ .keys = try self.keys.clone(a), .values = try self.values.clone(a) };
    }
};

pub const AssocLink = struct { var_: *Obj, bind_name: []const u8, link_name: []const u8 };

pub const ObjTree = std.array_hash_map.String(TreeEntry);
pub const TreeEntry = struct { obj: *Obj, path: ?[]const u8 };

/// Shared context for name resolution: object tree and a scratch allocator
pub const Env = struct {
    tree: *ObjTree,
    tmp: Allocator,

    /// The global (module, program, top-level procedure) `name` as seen from
    /// file `ast`: its own definition before another file's of that name.
    pub fn global(env: Env, ast: *const Ast, name: []const u8) ?*Obj {
        if (ast.global_dict.get(name)) |o| return o;
        return if (env.tree.get(name)) |e| e.obj else null;
    }
};

/// What a scope keeps beyond its children, by kind
pub const ScopeExt = union(enum) {
    /// plain scopes, modules, programs, blocks, INCLUDE objects
    none,
    submodule: Submodule,
    procedure: Procedure,
    type: TypeDef,
    interface: Interface,
    associate: Associate,
    select: Select,
};

/// A program unit or block: anything that has children (`Scope`)
pub const Scope = struct {
    children: std.ArrayList(*Obj) = .empty,
    members: std.ArrayList([]const u8) = .empty,
    use: std.ArrayList(*UseStmt) = .empty,
    inherit: ?[]const u8 = null,
    contains_start: ?usize = null,
    implicit_line: ?usize = null,
    /// Inherited children: of a type from its parent type, of a procedure
    /// from the submodule prototype it implements
    in_children: std.ArrayList(*Obj) = .empty,
    ext: ScopeExt = .none,
};

pub const Submodule = struct {
    /// the ancestor module
    ancestor_name: []const u8 = "",
    /// the parent submodule, if any: `SUBMODULE (ancestor:parent) name`
    parent_smod_name: []const u8 = "",
    /// the parent submodule, or else the ancestor module
    ancestor_obj: ?*Obj = null,
};

/// A subroutine or function
pub const Procedure = struct {
    args: []const u8 = "",
    args_snip: []const u8 = "",
    arg_objs: std.ArrayList(?*Obj) = .empty,
    missing_args: std.ArrayList(*Obj) = .empty,
    mod_scope: bool = false,
    /// The prototype in a submodule's ancestor that this procedure implements
    link_obj: ?*Obj = null,
    result_name: ?[]const u8 = null,
    result_type: ?[]const u8 = null,
    result_obj: ?*Obj = null,
    /// Set when `copyInterface` imported data from a submodule prototype
    linked_from_interface: bool = false,
};

/// A derived type
pub const TypeDef = struct {
    inherit_var: ?*Obj = null,
    inherit_tmp: ?[]const u8 = null,
    inherit_version: i64 = -1,
    abstract: bool = false,
};

pub const Interface = struct {
    mems: std.ArrayList(*Obj) = .empty,
    external: bool = false,
    abstract: bool = false,
};

pub const Associate = struct {
    links: std.ArrayList(AssocLink) = .empty,
};

pub const Select = struct {
    select_type: i32 = 0,
    binding_name: ?[]const u8 = null,
    bound_var: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,
};

/// A variable, or a method (type-bound procedure or procedure pointer)
pub const Variable = struct {
    desc: []const u8 = "",
    vkind: ?[]const u8 = null,
    type_obj: ?*Obj = null,
    is_const: bool = false,
    is_external: bool = false,
    param_val: ?[]const u8 = null,
    /// For an ASSOCIATE name bound to an array element or section, `b(:, 1)`:
    /// the number of dimensions that remain (the sections), else -1
    slice_rank: i32 = -1,
    link_name: ?[]const u8 = null,
    /// What the variable stands for: the procedure of a procedure pointer or
    /// type-bound procedure, the selector of an ASSOCIATE name
    link_obj: ?*Obj = null,
    callable: bool = false,
    drop_arg: ?usize = null,
    pass_name: ?[]const u8 = null,
};

/// A built-in procedure, keyword or statement
pub const Intrinsic = struct {
    itype: C.TypeId = .base,
    args: []const u8 = "",
};

/// The data of an object: what fortls's `Scope`, `Variable` and
/// `Intrinsic` classes hold. `Obj.kind` says which; the accessors
/// (`scope()`, `variable()`, `procedure()`, ...) check it in safe builds.
pub const Data = union(enum) {
    scope: Scope,
    variable: Variable,
    intrinsic: Intrinsic,
};

pub const Obj = struct {
    kind: Kind,
    name: []const u8,
    fqsn: []const u8 = "",
    sline: usize = 0,
    eline: usize = 0,
    vis: Vis = .default,
    def_vis: Vis = .default,
    doc_str: ?[]const u8 = null,
    parent: ?*Obj = null,
    implicit_vars: ?bool = null,
    file_ast: *Ast,
    keywords: std.ArrayList(C.Kw) = .empty,
    keyword_info: KeywordInfo = .{},
    data: Data,

    /// Allocator owning this object's persistent data
    pub fn al(self: *const Obj) Allocator {
        return self.file_ast.allocator();
    }

    pub fn nameLowerEql(self: *const Obj, other: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, other);
    }

    pub fn hasKeyword(self: *const Obj, id: C.Kw) bool {
        return std.mem.indexOfScalar(C.Kw, self.keywords.items, id) != null;
    }

    // ------------------------------------------------------------------
    // Data by kind

    pub fn scopeData(self: *Obj) *Scope {
        return &self.data.scope;
    }

    pub fn scopeDataConst(self: *const Obj) *const Scope {
        return &self.data.scope;
    }

    pub fn varData(self: *Obj) *Variable {
        return &self.data.variable;
    }

    pub fn varDataConst(self: *const Obj) *const Variable {
        return &self.data.variable;
    }

    pub fn intrinsicData(self: *const Obj) *const Intrinsic {
        return &self.data.intrinsic;
    }

    /// The procedure data of a subroutine or function
    pub fn procData(self: *Obj) *Procedure {
        return &self.data.scope.ext.procedure;
    }

    pub fn procDataConst(self: *const Obj) *const Procedure {
        return &self.data.scope.ext.procedure;
    }

    pub fn typeData(self: *Obj) *TypeDef {
        return &self.data.scope.ext.type;
    }

    pub fn typeDataConst(self: *const Obj) *const TypeDef {
        return &self.data.scope.ext.type;
    }

    pub fn ifaceData(self: *Obj) *Interface {
        return &self.data.scope.ext.interface;
    }

    pub fn ifaceDataConst(self: *const Obj) *const Interface {
        return &self.data.scope.ext.interface;
    }

    pub fn submodData(self: *Obj) *Submodule {
        return &self.data.scope.ext.submodule;
    }

    pub fn submodDataConst(self: *const Obj) *const Submodule {
        return &self.data.scope.ext.submodule;
    }

    pub fn assocData(self: *Obj) *Associate {
        return &self.data.scope.ext.associate;
    }

    pub fn assocDataConst(self: *const Obj) *const Associate {
        return &self.data.scope.ext.associate;
    }

    pub fn selectData(self: *Obj) *Select {
        return &self.data.scope.ext.select;
    }

    pub fn selectDataConst(self: *const Obj) *const Select {
        return &self.data.scope.ext.select;
    }

    /// The children of a scope; none for a variable or intrinsic
    pub fn childList(self: *const Obj) []*Obj {
        return switch (self.data) {
            .scope => |s| s.children.items,
            else => &.{},
        };
    }

    /// The members of an interface (its procedures); none for other objects
    pub fn memList(self: *const Obj) []*Obj {
        if (self.kind != .interface) return &.{};
        return self.data.scope.ext.interface.mems.items;
    }

    /// The procedure data, when the object is a subroutine or function
    pub fn procDataOpt(self: *Obj) ?*Procedure {
        return switch (self.data) {
            .scope => |*s| switch (s.ext) {
                .procedure => |*p| p,
                else => null,
            },
            else => null,
        };
    }

    pub fn procDataOptConst(self: *const Obj) ?*const Procedure {
        return switch (self.data) {
            .scope => |*s| switch (s.ext) {
                .procedure => |*p| p,
                else => null,
            },
            else => null,
        };
    }

    /// The variable data, when the object is a variable or method
    pub fn varDataOpt(self: *Obj) ?*Variable {
        return switch (self.data) {
            .variable => |*v| v,
            else => null,
        };
    }

    pub fn varDataOptConst(self: *const Obj) ?*const Variable {
        return switch (self.data) {
            .variable => |*v| v,
            else => null,
        };
    }

    /// `link_obj` of a procedure (its prototype) or a variable (what it
    /// stands for); null for other objects
    pub fn linkObj(self: *const Obj) ?*Obj {
        return switch (self.data) {
            .scope => |s| switch (s.ext) {
                .procedure => |p| p.link_obj,
                else => null,
            },
            .variable => |v| v.link_obj,
            .intrinsic => null,
        };
    }

    /// The argument list of a procedure or intrinsic, "" for others
    pub fn argList(self: *const Obj) []const u8 {
        return switch (self.data) {
            .scope => |s| switch (s.ext) {
                .procedure => |p| p.args,
                else => "",
            },
            .intrinsic => |i| i.args,
            .variable => "",
        };
    }

    /// The `desc` of a variable or method, "" for others
    pub fn descOf(self: *const Obj) []const u8 {
        return switch (self.data) {
            .variable => |v| v.desc,
            else => "",
        };
    }

    // ------------------------------------------------------------------
    // Construction

    fn computeFqsn(a: Allocator, file_ast: *Ast, name: []const u8) ![]const u8 {
        const lname = try std.ascii.allocLowerString(a, name);
        if (file_ast.enc_scope_name) |enc| {
            return std.mem.concat(a, u8, &.{ try std.ascii.allocLowerString(a, enc), "::", lname });
        }
        return lname;
    }

    /// The scope data a new object of `kind` starts with
    fn scopeExtFor(kind: Kind) ScopeExt {
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
            .fqsn = try computeFqsn(a, file_ast, nm),
            .data = .{ .scope = .{ .ext = scopeExtFor(kind) } },
        };
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

    pub const FunOpts = struct {
        args: []const u8 = "",
        mod_flag: bool = false,
        keywords: []const C.Kw = &.{},
        keyword_info: KeywordInfo = .{},
        result_type: ?[]const u8 = null,
        result_name: ?[]const u8 = null,
    };

    pub fn newFunction(file_ast: *Ast, line_number: usize, name: []const u8, opts: FunOpts) !*Obj {
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

    pub const VarOpts = struct {
        keyword_info: KeywordInfo = .{},
        kind: ?[]const u8 = null,
        link_obj: ?[]const u8 = null,
    };

    /// `Variable.__init__`
    pub fn newVariable(file_ast: *Ast, line_number: usize, name: []const u8, var_desc: []const u8, keywords: []const C.Kw, opts: VarOpts) !*Obj {
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
            .fqsn = try computeFqsn(a, file_ast, nm),
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

    // ------------------------------------------------------------------
    // Basic accessors

    pub fn getType(self: *const Obj, no_link: bool) C.TypeId {
        return switch (self.kind) {
            .scope, .include => C.TypeId.base,
            .module, .program => C.TypeId.module,
            .submodule => C.TypeId.submodule,
            .subroutine => C.TypeId.subroutine,
            .function => C.TypeId.function,
            .type => C.TypeId.class,
            .interface => C.TypeId.interface,
            .block => C.TypeId.block,
            .select => C.TypeId.select,
            .do_ => C.TypeId.do_,
            .where => C.TypeId.where,
            .if_ => C.TypeId.if_,
            .associate => C.TypeId.assoc,
            .enum_ => C.TypeId.enum_,
            .variable => if (self.linkObj()) |l| l.getType(false) else C.TypeId.variable,
            .method => if (!no_link and self.linkObj() != null) self.linkObj().?.getType(false) else C.TypeId.method,
            .intrinsic => self.intrinsicData().itype,
        };
    }

    /// Variable description without following links (`get_desc(True)`)
    pub fn getDescNoLink(self: *const Obj, a: Allocator) ![]const u8 {
        if (self.kind.isVariable()) {
            if (self.varDataConst().vkind) |k| if (k.len > 0) return std.mem.concat(a, u8, &.{ self.varDataConst().desc, k });
            return self.varDataConst().desc;
        }
        return self.getDesc(a);
    }

    pub fn getDesc(self: *const Obj, a: Allocator) Allocator.Error![]const u8 {
        return switch (self.kind) {
            .scope => "unknown",
            .include => "INCLUDE",
            .module => "MODULE",
            .program => "PROGRAM",
            .submodule => "SUBMODULE",
            .subroutine => "SUBROUTINE",
            .function => if (self.procDataConst().result_type) |rt| (if (rt.len > 0) try std.mem.concat(a, u8, &.{ rt, " FUNCTION" }) else "FUNCTION") else "FUNCTION",
            .type => "TYPE",
            .interface => "INTERFACE",
            .block => "BLOCK",
            .do_ => "DO",
            .if_ => "IF",
            .where => "WHERE",
            .enum_ => "ENUM",
            .associate => "ASSOCIATE",
            .select => "SELECT",
            .variable, .method => if (self.linkObj()) |l| l.getDesc(a) else self.getDescNoLink(a),
            .intrinsic => switch (self.intrinsicData().itype) {
                .subroutine => "SUBROUTINE",
                C.keyword_itype => "KEYWORD",
                C.statement_itype => "STATEMENT",
                else => "INTRINSIC",
            },
        };
    }

    pub fn getChildren(self: *const Obj, a: Allocator, public_only: bool) ![]*Obj {
        switch (self.kind) {
            .variable, .method, .intrinsic => return &.{},
            .type, .subroutine, .function => {
                var out: std.ArrayList(*Obj) = .empty;
                try out.appendSlice(a, self.childList());
                try out.appendSlice(a, self.scopeDataConst().in_children.items);
                return out.items;
            },
            .block, .do_, .if_, .where, .enum_, .associate, .select => return a.dupe(*Obj, self.childList()),
            else => {
                if (!public_only) return a.dupe(*Obj, self.childList());
                var out: std.ArrayList(*Obj) = .empty;
                for (self.childList()) |child| {
                    if (child.vis == .private or (self.def_vis == .private and child.vis != .public)) continue;
                    try out.append(a, child);
                }
                return out.items;
            },
        }
    }

    /// The parent submodules and the ancestor module of a submodule, nearest
    /// first
    pub fn getAncestors(self: *const Obj, a: Allocator) ![]*Obj {
        if (self.kind != .submodule) return &.{};
        var out: std.ArrayList(*Obj) = .empty;
        var cur = self;
        while (cur.kind == .submodule) {
            const anc = cur.submodDataConst().ancestor_obj orelse break;
            // submodules that name each other while code is being edited
            for (out.items) |o| if (o == anc) return out.items;
            if (anc == self) break;
            try out.append(a, anc);
            cur = anc;
        }
        return out.items;
    }

    /// The scope a submodule extends: its parent submodule, if that is a
    /// submodule of the same module, or else its ancestor module
    fn findSubmoduleParent(self: *const Obj, env: Env) ?*Obj {
        const sm = self.submodDataConst();
        if (sm.parent_smod_name.len > 0) if (env.global(self.file_ast, sm.parent_smod_name)) |p| {
            if (p != self and p.kind == .submodule and std.mem.eql(u8, p.submodData().ancestor_name, sm.ancestor_name)) return p;
        };
        if (sm.ancestor_name.len == 0) return null;
        return env.global(self.file_ast, sm.ancestor_name);
    }

    pub fn setParent(self: *Obj, parent_obj: ?*Obj) void {
        self.parent = parent_obj;
        if (self.kind == .method) {
            const p = parent_obj orelse return;
            if (p.getType(false) == C.TypeId.class) {
                if (!self.hasKeyword(KW.nopass)) self.varData().drop_arg = 0;
                if (p.scopeData().contains_start != null and self.sline > p.scopeData().contains_start.? and self.varData().link_name == null) {
                    self.varData().link_name = std.ascii.allocLowerString(self.al(), self.name) catch self.name;
                }
            }
        }
    }

    pub fn addChild(self: *Obj, child: *Obj) !void {
        try self.scopeData().children.append(self.al(), child);
        child.setParent(self);
    }

    pub fn updateFqsn(self: *Obj, enc_scope: ?[]const u8) !void {
        if (!self.kind.isScope() and !self.kind.isVariable()) return;
        const a = self.al();
        const lname = try std.ascii.allocLowerString(a, self.name);
        if (enc_scope) |e| {
            self.fqsn = try std.mem.concat(a, u8, &.{ try std.ascii.allocLowerString(a, e), "::", lname });
        } else {
            self.fqsn = lname;
        }
        for (self.childList()) |child| try child.updateFqsn(self.fqsn);
    }

    pub fn end(self: *Obj, line_number: usize) void {
        self.eline = line_number;
    }

    pub fn addDoc(self: *Obj, doc: []const u8) void {
        self.doc_str = doc;
    }

    pub fn setImplicit(self: *Obj, flag: bool, line_number: usize) void {
        self.implicit_vars = flag;
        self.scopeData().implicit_line = line_number;
    }

    pub fn markContains(self: *Obj, line_number: usize) error{MultipleContains}!void {
        if (self.scopeData().contains_start != null) return error.MultipleContains;
        self.scopeData().contains_start = line_number;
    }

    pub fn isTypeRegion(self: *const Obj) bool {
        return self.kind == .select and (self.selectDataConst().select_type == 3 or self.selectDataConst().select_type == 4);
    }

    pub fn isTypeBinding(self: *const Obj) bool {
        return self.kind == .select and self.selectDataConst().select_type == 2;
    }

    pub fn getDocumentation(self: *const Obj) ?[]const u8 {
        if (self.kind == .method) {
            if (self.linkObj()) |l| if (self.doc_str == null) return l.getDocumentation();
        }
        return self.doc_str;
    }

    pub fn getImplicit(self: *const Obj) ?bool {
        const p = self.parent orelse return self.implicit_vars;
        const parent_implicit = p.getImplicit();
        if (self.implicit_vars != null or parent_implicit == null) return self.implicit_vars;
        return parent_implicit;
    }

    pub fn isOptional(self: *const Obj) bool {
        return self.kind.isVariable() and self.hasKeyword(KW.optional);
    }

    pub fn isModScope(self: *const Obj) bool {
        return self.kind.isSubroutine() and self.procDataConst().mod_scope;
    }

    pub fn isCallable(self: *const Obj) bool {
        return switch (self.kind) {
            .interface, .subroutine, .method => true,
            .function => false,
            .variable => self.varDataConst().callable,
            .intrinsic => self.intrinsicData().itype == .subroutine,
            else => false,
        };
    }

    pub fn isExternalInt(self: *const Obj) bool {
        return self.kind == .interface and self.ifaceDataConst().external;
    }

    pub fn isAbstract(self: *const Obj) bool {
        return self.kind == .interface and self.ifaceDataConst().abstract;
    }

    pub fn reqNamedEnd(self: *const Obj) bool {
        return self.kind.isBlock();
    }

    pub fn isParameter(self: *const Obj) bool {
        return self.varDataConst().is_const;
    }

    pub fn setExternalAttr(self: *Obj) !void {
        try self.keywords.append(self.al(), KW.external);
        self.varData().is_external = true;
    }

    pub fn checkValidParent(self: *const Obj) bool {
        switch (self.kind) {
            .module, .program, .submodule => return self.parent == null,
            .type => {
                const p = self.parent orelse return false;
                const pt = p.getType(false);
                return pt != C.TypeId.class and !pt.isInnerScope();
            },
            .subroutine, .function => {
                if (self.parent) |p| {
                    const pt = p.getType(false);
                    if (pt == C.TypeId.class or pt.isInnerScope()) return false;
                }
                return true;
            },
            else => return true,
        }
    }

    pub fn requireInherit(self: *const Obj) bool {
        return self.kind == .type or self.kind == .submodule;
    }

    pub fn requireLink(self: *const Obj) bool {
        return switch (self.kind) {
            .variable, .method => self.varDataConst().link_name != null,
            .interface, .subroutine, .function, .submodule, .associate => true,
            else => false,
        };
    }

    // ------------------------------------------------------------------
    // Snippets, hover, signature

    pub const Snippet = struct { call: ?[]const u8 = null, snippet: ?[]const u8 = null };

    pub fn getSnippet(self: *const Obj, a: Allocator, name_replace: ?[]const u8, drop_arg: ?usize) Allocator.Error!Snippet {
        switch (self.kind) {
            .variable => {
                const name = name_replace orelse self.name;
                if (self.linkObj()) |l| return l.getSnippet(a, name, drop_arg);
                return .{};
            },
            .method => {
                if (self.linkObj()) |l| {
                    const name = name_replace orelse self.name;
                    return l.getSnippet(a, name, self.varDataConst().drop_arg);
                }
                return .{};
            },
            .subroutine, .function => {
                var arg_list: std.ArrayList([]const u8) = .empty;
                try arg_list.appendSlice(a, try str.split(a, self.procDataConst().args_snip, ","));
                if (drop_arg) |d| if (d < arg_list.items.len) {
                    _ = arg_list.orderedRemove(d);
                };
                var arg_str: []const u8 = "()";
                var arg_snip: ?[]const u8 = null;
                if (arg_list.items.len > 0) {
                    const ph = try helpers.getPlaceholders(a, arg_list.items);
                    arg_str = ph[0];
                    arg_snip = ph[1];
                }
                const name = name_replace orelse self.name;
                return .{
                    .call = try std.mem.concat(a, u8, &.{ name, arg_str }),
                    .snippet = if (arg_snip) |s| try std.mem.concat(a, u8, &.{ name, s }) else null,
                };
            },
            .intrinsic => {
                var arg_str: []const u8 = undefined;
                var arg_snip: ?[]const u8 = null;
                if (self.argList().len == 0) {
                    if (self.intrinsicData().itype == C.keyword_itype or self.intrinsicData().itype == C.statement_itype) return .{};
                    arg_str = "()";
                } else {
                    const ph = try helpers.getPlaceholders(a, try str.split(a, self.argList(), ","));
                    arg_str = ph[0];
                    arg_snip = ph[1];
                }
                const name = name_replace orelse self.name;
                return .{
                    .call = try std.mem.concat(a, u8, &.{ name, arg_str }),
                    .snippet = if (arg_snip) |s| try std.mem.concat(a, u8, &.{ name, s }) else null,
                };
            },
            else => return .{},
        }
    }

    pub const Hover = struct { msg: ?[]const u8 = null, docs: ?[]const u8 = null };

    pub fn getHover(self: *const Obj, a: Allocator, long: bool, drop_arg: ?usize) Allocator.Error!Hover {
        switch (self.kind) {
            .module, .program, .submodule => return .{
                .msg = try std.mem.concat(a, u8, &.{ try self.getDesc(a), " ", self.name }),
                .docs = self.getDocumentation(),
            },
            .type => {
                var kws: std.ArrayList([]const u8) = .empty;
                try kws.append(a, "TYPE");
                if (self.typeDataConst().abstract) try kws.append(a, "ABSTRACT");
                if (self.scopeDataConst().inherit) |inh| if (inh.len > 0) try kws.append(a, try std.fmt.allocPrint(a, "EXTENDS({s})", .{inh}));
                const decl = try std.mem.join(a, ", ", kws.items);
                return .{ .msg = try std.fmt.allocPrint(a, "{s} :: {s}", .{ decl, self.name }), .docs = self.getDocumentation() };
            },
            .subroutine => {
                const sig = try self.getSnippet(a, null, drop_arg);
                var kw: std.ArrayList([]const u8) = .empty;
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "SUBROUTINE ");
                var hover_array: std.ArrayList([]const u8) = .empty;
                try hover_array.append(a, try std.mem.concat(a, u8, &.{ try std.mem.join(a, " ", kw.items), sig.call.? }));
                var docs: std.ArrayList([]const u8) = .empty;
                try self.getDocsFull(a, &hover_array, &docs, long, drop_arg);
                return .{
                    .msg = try std.mem.join(a, "\n ", hover_array.items),
                    .docs = try std.mem.join(a, "   \n", docs.items),
                };
            },
            .function => {
                const proc = self.procDataConst();
                var fun_sig = (try self.getSnippet(a, null, drop_arg)).call.?;
                if (long) fun_sig = try std.fmt.allocPrint(a, "{s} RESULT({s})", .{ fun_sig, proc.result_name orelse self.name });
                var kw: std.ArrayList([]const u8) = .empty;
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "FUNCTION");
                var hover_array: std.ArrayList([]const u8) = .empty;
                try hover_array.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ try std.mem.join(a, " ", kw.items), fun_sig }));
                var docs: std.ArrayList([]const u8) = .empty;
                try self.getDocsFull(a, &hover_array, &docs, long, drop_arg);
                if (proc.result_obj != null and long) {
                    const ro = proc.result_obj.?;
                    const h = try ro.getHover(a, false, null);
                    if (h.docs) |d| {
                        try docs.append(a, try std.fmt.allocPrint(a, "\n**Return:**  \n`{s}`{s}", .{ ro.name, d }));
                    }
                    try hover_array.append(a, h.msg orelse "None");
                } else if (proc.result_type != null and proc.result_type.?.len > 0 and long) {
                    hover_array.items[0] = try std.fmt.allocPrint(a, "{s} {s}", .{ proc.result_type.?, hover_array.items[0] });
                }
                return .{
                    .msg = try std.mem.join(a, "\n ", hover_array.items),
                    .docs = try std.mem.join(a, "  \n", docs.items),
                };
            },
            .variable => {
                const doc_str = self.getDocumentation();
                var parts: std.ArrayList([]const u8) = .empty;
                try parts.append(a, try self.getDesc(a));
                try parts.appendSlice(a, try self.getKeywordStrings(a));
                var hover = try std.mem.join(a, ", ", parts.items);
                if (!std.mem.startsWith(u8, hover, "#")) hover = try std.fmt.allocPrint(a, "{s} :: {s}", .{ hover, self.name });
                if (self.isParameter()) if (self.varDataConst().param_val) |pv| {
                    hover = try std.fmt.allocPrint(a, "{s} = {s}", .{ hover, pv });
                };
                return .{ .msg = hover, .docs = doc_str };
            },
            .method => {
                var docs = self.getDocumentation();
                var hover_str: []const u8 = undefined;
                if (self.linkObj()) |l| {
                    const lh = try l.getHover(a, true, self.varDataConst().drop_arg);
                    const link_msg = lh.msg orelse "None";
                    hover_str = try str.replaceFirst(a, link_msg, l.name, self.name);
                    if (lh.docs) |link_docs| {
                        if (l.getDocumentation()) |top| {
                            docs = try str.replaceFirst(a, link_docs, top, docs orelse "None");
                        } else if (link_docs.len > 0) {
                            docs = try std.mem.concat(a, u8, &.{ docs orelse "", "  \n", link_docs });
                        }
                    }
                } else {
                    const sig = try self.getSnippet(a, null, null);
                    hover_str = try std.fmt.allocPrint(a, "{s} {s}", .{ try self.getDesc(a), sig.call orelse "None" });
                }
                return .{ .msg = hover_str, .docs = docs };
            },
            .intrinsic => return .{ .msg = null, .docs = self.doc_str },
            else => return .{},
        }
    }

    pub fn getHoverMd(self: *const Obj, a: Allocator, long: bool, drop_arg: ?usize) ![]const u8 {
        const h = try self.getHover(a, long, drop_arg);
        return helpers.fortranMd(a, h.msg, h.docs);
    }

    pub fn getKeywordStrings(self: *const Obj, a: Allocator) ![][]const u8 {
        if (self.linkObj()) |l| {
            if (self.varDataConst().slice_rank >= 0 and l.kind == .variable) {
                // a name bound to a section has the rank of the section, not
                // of the array it is cut from (upstream #108)
                var ids: std.ArrayList(C.Kw) = .empty;
                for (l.keywords.items) |id| if (id != KW.dimension) try ids.append(a, id);
                var info = l.keyword_info;
                info.dimension = null;
                if (self.varDataConst().slice_rank > 0) {
                    try ids.append(a, KW.dimension);
                    var dims: std.ArrayList(u8) = .empty;
                    for (0..@as(usize, @intCast(self.varDataConst().slice_rank))) |i| {
                        if (i > 0) try dims.append(a, ',');
                        try dims.append(a, ':');
                    }
                    info.dimension = dims.items;
                }
                return helpers.getKeywords(a, ids.items, info);
            }
            return helpers.getKeywords(a, l.keywords.items, l.keyword_info);
        }
        return helpers.getKeywords(a, self.keywords.items, self.keyword_info);
    }

    fn getDocsFull(self: *const Obj, a: Allocator, hover_array: *std.ArrayList([]const u8), doc_strs: *std.ArrayList([]const u8), long: bool, drop_arg: ?usize) !void {
        if (self.getDocumentation()) |d| try doc_strs.append(a, d);
        if (!long) return;
        var has_args = true;
        var in_list = false;
        for (self.procDataConst().arg_objs.items, 0..) |arg_obj_opt, i| {
            const arg_obj = arg_obj_opt orelse continue;
            if (i == drop_arg) continue;
            const h = try arg_obj.getHover(a, false, null);
            try hover_array.append(a, h.msg orelse "None");
            if (h.docs) |d| if (d.len > 0) {
                if (has_args) {
                    try doc_strs.append(a, "\n**Parameters:**  ");
                    has_args = false;
                }
                // a list in the previous parameter's text would swallow this one
                const entry = str.strip(try std.fmt.allocPrint(a, "`{s}` {s}", .{ arg_obj.name, d }));
                try doc_strs.append(a, if (in_list) try std.fmt.allocPrint(a, "\n{s}", .{entry}) else entry);
                in_list = endsInListItem(entry);
            };
        }
    }

    /// Whether the last line of a Markdown text is a list item (`- x`, `* x`, `+ x`, `1. x`)
    fn endsInListItem(text: []const u8) bool {
        const nl = std.mem.lastIndexOfScalar(u8, text, '\n');
        const line = std.mem.trimStart(u8, if (nl) |n| text[n + 1 ..] else text, " \t");
        if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') return true;
        var i: usize = 0;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        return i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and line[i + 1] == ' ';
    }

    pub const ArgSig = struct { label: []const u8, doc_md: ?[]const u8 = null };
    pub const Signature = struct { label: ?[]const u8 = null, doc: ?[]const u8 = null, params: []ArgSig = &.{} };

    pub fn getSignature(self: *const Obj, a: Allocator, drop_arg: ?usize) Allocator.Error!Signature {
        switch (self.kind) {
            .subroutine, .function => {
                var arg_sigs: std.ArrayList(ArgSig) = .empty;
                const arg_list = try str.split(a, self.argList(), ",");
                for (self.procDataConst().arg_objs.items, 0..) |arg_obj_opt, i| {
                    if (i == drop_arg) continue;
                    if (arg_obj_opt) |arg_obj| {
                        const lname = try std.ascii.allocLowerString(a, arg_obj.name);
                        const label = if (arg_obj.isOptional()) try std.fmt.allocPrint(a, "{s}={s}", .{ lname, lname }) else lname;
                        try arg_sigs.append(a, .{ .label = label, .doc_md = try arg_obj.getHoverMd(a, false, null) });
                    } else {
                        try arg_sigs.append(a, .{ .label = if (i < arg_list.len) arg_list[i] else "" });
                    }
                }
                const sig = try self.getSnippet(a, null, null);
                return .{ .label = sig.call, .doc = self.getDocumentation(), .params = arg_sigs.items };
            },
            .method => {
                if (self.linkObj()) |l| {
                    const sig = try self.getSnippet(a, null, null);
                    const ls = try l.getSignature(a, self.varDataConst().drop_arg);
                    return .{ .label = sig.call, .doc = self.getDocumentation(), .params = ls.params };
                }
                return .{};
            },
            .intrinsic => {
                var arg_sigs: std.ArrayList(ArgSig) = .empty;
                for (try str.split(a, self.argList(), ",")) |arg| try arg_sigs.append(a, .{ .label = arg });
                const sig = try self.getSnippet(a, null, null);
                return .{ .label = sig.call, .doc = self.doc_str, .params = arg_sigs.items };
            },
            else => return .{},
        }
    }

    fn getInterfaceArray(self: *const Obj, a: Allocator, keywords: []const []const u8, signature: []const u8, drop_arg: ?usize, change_strings: ?[2][]const u8) !?std.ArrayList([]const u8) {
        var arr: std.ArrayList([]const u8) = .empty;
        try arr.append(a, try std.mem.concat(a, u8, &.{ try std.mem.join(a, " ", keywords), signature }));
        for (self.procDataConst().arg_objs.items, 0..) |arg_obj_opt, i| {
            const arg_obj = arg_obj_opt orelse return null;
            const h = try arg_obj.getHover(a, false, null);
            var arg_doc = h.msg orelse "None";
            if (i == drop_arg) {
                if (change_strings) |cs| {
                    if (std.ascii.findIgnoreCase(arg_doc, cs[0])) |i_0| {
                        arg_doc = try std.mem.concat(a, u8, &.{ arg_doc[0..i_0], cs[1], arg_doc[i_0 + cs[0].len ..] });
                    }
                }
            }
            try arr.append(a, try std.fmt.allocPrint(a, "{s} :: {s}", .{ arg_doc, arg_obj.name }));
        }
        return arr;
    }

    pub fn getInterface(self: *const Obj, a: Allocator, name_replace: ?[]const u8, drop_arg: ?usize, change_strings: ?[2][]const u8) Allocator.Error!?[]const u8 {
        switch (self.kind) {
            .subroutine => {
                const sig = (try self.getSnippet(a, name_replace, null)).call.?;
                var kw: std.ArrayList([]const u8) = .empty;
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "SUBROUTINE ");
                var arr = (try self.getInterfaceArray(a, kw.items, sig, drop_arg, change_strings)) orelse return null;
                const name = name_replace orelse self.name;
                try arr.append(a, try std.fmt.allocPrint(a, "END SUBROUTINE {s}", .{name}));
                return try std.mem.join(a, "\n", arr.items);
            },
            .function => {
                var sig = (try self.getSnippet(a, name_replace, null)).call.?;
                sig = try std.fmt.allocPrint(a, "{s} RESULT({s})", .{ sig, self.procDataConst().result_name orelse self.name });
                var kw: std.ArrayList([]const u8) = .empty;
                if (self.procDataConst().result_type) |rt| if (rt.len > 0) try kw.append(a, rt);
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "FUNCTION ");
                var arr = (try self.getInterfaceArray(a, kw.items, sig, drop_arg, change_strings)) orelse return null;
                if (self.procDataConst().result_obj) |ro| {
                    const h = try ro.getHover(a, false, null);
                    try arr.append(a, try std.fmt.allocPrint(a, "{s} :: {s}", .{ h.msg orelse "None", ro.name }));
                }
                const name = name_replace orelse self.name;
                try arr.append(a, try std.fmt.allocPrint(a, "END FUNCTION {s}", .{name}));
                return try std.mem.join(a, "\n", arr.items);
            },
            .method => {
                if (self.linkObj()) |l| return l.getInterface(a, name_replace, self.varDataConst().drop_arg, change_strings);
                return null;
            },
            else => return null,
        }
    }

    // ------------------------------------------------------------------
    // Linking

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
    fn linkLoops(self: *const Obj, target: *const Obj) bool {
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

    fn resolveArgLink(self: *Obj) !void {
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
    fn copyInterface(self: *Obj, src: *Obj) !void {
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

    fn hasChildNamed(self: *const Obj, name: []const u8) bool {
        for (self.childList()) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return true;
        return false;
    }

    fn resolveSubmoduleLink(self: *Obj, env: Env) !void {
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
                        child.keyword_info = .{};
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
                if (p.getType(false) == C.TypeId.class) search_scope = p.parent;
                if (search_scope) |ss| {
                    const type_name = try std.ascii.allocLowerString(env.tmp, str.strip(tn));
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

    // ------------------------------------------------------------------
    // Diagnostics

    pub fn getDiagnostics(self: *const Obj, a: Allocator) ![]Diagnostic {
        var errors: std.ArrayList(Diagnostic) = .empty;
        switch (self.kind) {
            .type => {
                for (self.scopeDataConst().in_children.items) |in_child| {
                    if (!self.typeDataConst().abstract and in_child.hasKeyword(KW.deferred)) {
                        var d = Diagnostic.init(self.eline -| 1, try std.fmt.allocPrint(a, "Deferred procedure \"{s}\" not implemented", .{in_child.name}), 1, null);
                        d.addRelated(in_child.file_ast.path, in_child.sline -| 1, "Inherited procedure declaration");
                        try errors.append(a, d);
                    }
                }
            },
            .subroutine, .function => {
                for (self.procDataConst().missing_args.items) |m| {
                    try errors.append(a, Diagnostic.init(
                        m.sline -| 1,
                        try std.fmt.allocPrint(a, "Variable \"{s}\" with INTENT keyword not found in argument list", .{m.name}),
                        1,
                        m.name,
                    ));
                }
                const implicit_flag = self.getImplicit();
                if (implicit_flag == null or implicit_flag.?) return errors.items;
                const arg_list = try str.split(a, try std.mem.replaceOwned(u8, a, self.argList(), " ", ""), ",");
                for (self.procDataConst().arg_objs.items, 0..) |arg_obj, i| {
                    if (arg_obj == null) {
                        const arg_name = str.strip(if (i < arg_list.len) arg_list[i] else "");
                        try errors.append(a, Diagnostic.init(
                            self.sline -| 1,
                            try std.fmt.allocPrint(a, "No matching declaration found for argument \"{s}\"", .{arg_name}),
                            1,
                            arg_name,
                        ));
                    }
                }
            },
            else => {},
        }
        return errors.items;
    }

    const KnownType = struct { kind: u8, obj: *Obj };
    pub const KnownTypes = std.array_hash_map.String(?KnownType);

    pub fn checkDefinition(self: *Obj, env: Env, known_types: *KnownTypes, interface: bool) !?Diagnostic {
        if (self.kind != .variable) return null;
        const a = env.tmp;
        const m = R().DEF_KIND.match(try self.getDescNoLink(a)) orelse return null;
        const var_type = try std.ascii.allocLowerString(a, str.strip(m.group(1).?));
        if (std.mem.eql(u8, var_type, "procedure")) return null;
        const desc_obj_name = try std.ascii.allocLowerString(a, str.strip(m.group(2).?));
        if (!known_types.contains(desc_obj_name)) {
            const type_def = try findInScope(env, self.parent, desc_obj_name, .{ .interface = interface });
            if (type_def) |td| {
                try known_types.put(a, desc_obj_name, .{ .kind = 0, .obj = td });
            } else {
                const type_defs = try findInWorkspace(env, desc_obj_name, true, true);
                try known_types.put(a, desc_obj_name, null);
                const filter_id = if (std.mem.eql(u8, var_type, "class") or std.mem.eql(u8, var_type, "type")) C.TypeId.class else C.TypeId.variable;
                for (type_defs) |td| {
                    if (td.getType(false) == filter_id) {
                        try known_types.put(a, desc_obj_name, .{ .kind = 1, .obj = td });
                        break;
                    }
                }
            }
        }
        const info = known_types.get(desc_obj_name).?;
        if (info) |ti| if (ti.kind == 1) {
            if (interface) {
                return Diagnostic.init(self.sline -| 1, try std.fmt.allocPrint(a, "Object \"{s}\" not imported in interface", .{desc_obj_name}), 1, desc_obj_name);
            }
            var d = Diagnostic.init(self.sline -| 1, try std.fmt.allocPrint(a, "Object \"{s}\" not found in scope", .{desc_obj_name}), 1, desc_obj_name);
            d.addRelated(ti.obj.file_ast.path, ti.obj.sline -| 1, "Possible object");
            return d;
        };
        return null;
    }

    pub fn checkDefinitions(self: *Obj, env: Env) ![]Diagnostic {
        const a = env.tmp;
        var fqsn_dict = std.array_hash_map.String(usize).empty;
        var errors: std.ArrayList(Diagnostic) = .empty;
        var known_types = KnownTypes.empty;

        for (self.childList()) |child| {
            if (child.getType(false) == C.TypeId.interface) continue;
            if (fqsn_dict.get(child.fqsn)) |v| {
                if (child.sline < v) try fqsn_dict.put(a, child.fqsn, child.sline -| 1);
            } else {
                try fqsn_dict.put(a, child.fqsn, child.sline -| 1);
            }
        }

        var contains_line: ?usize = null;
        const st = self.getType(false);
        if (st == C.TypeId.module or st == C.TypeId.submodule or st == C.TypeId.subroutine or st == C.TypeId.function) {
            contains_line = self.scopeData().contains_start orelse self.eline;
        }
        const is_interface = self.parent != null and self.parent.?.getType(false) == C.TypeId.interface and !self.isModScope();

        for (self.childList()) |child| {
            if (std.mem.startsWith(u8, child.name, "#")) continue;
            const line_number = child.sline -| 1;
            if (try child.checkDefinition(env, &known_types, is_interface)) |d| try errors.append(a, d);
            const ct = child.getType(true);
            if (contains_line != null and contains_line.? >= child.sline and (ct == C.TypeId.subroutine or ct == C.TypeId.function)) {
                try errors.append(a, Diagnostic.init(line_number, "Subroutine/Function definition before CONTAINS statement", 1, null));
            }
            if (st == C.TypeId.interface or child.getType(false) == C.TypeId.interface) continue;
            if (fqsn_dict.get(child.fqsn)) |first| if (line_number > first) {
                var d = Diagnostic.init(line_number, try std.fmt.allocPrint(a, "Variable \"{s}\" declared twice in scope", .{child.name}), 1, child.name);
                d.addRelated(self.file_ast.path, first, "First declaration");
                try errors.append(a, d);
                continue;
            };
            // an interface body has no host association, so nothing in it masks
            // a variable of the scope around the interface (hansec #200)
            if (self.parent != null and !is_interface and (st == C.TypeId.subroutine or st == C.TypeId.function or st == C.TypeId.block)) {
                if (try findInScope(env, self.parent, child.name, .{})) |parent_var| {
                    if (st == C.TypeId.function and std.mem.eql(u8, parent_var.fqsn, self.fqsn)) continue;
                    var d = Diagnostic.init(line_number, try std.fmt.allocPrint(a, "Variable \"{s}\" masks variable in parent scope", .{child.name}), 2, child.name);
                    d.addRelated(parent_var.file_ast.path, parent_var.sline -| 1, "First declaration");
                    try errors.append(a, d);
                }
            }
        }
        return errors.items;
    }

    pub fn checkUse(self: *const Obj, env: Env) ![]Diagnostic {
        const a = env.tmp;
        var errors: std.ArrayList(Diagnostic) = .empty;
        // lines are 1-based, so 0 is before every USE statement
        var last_use_line: usize = 0;
        for (self.scopeDataConst().use.items) |u| {
            last_use_line = @max(last_use_line, u.line_number);
            if (u.is_import) {
                if (self.parent == null or self.parent.?.getType(false) != C.TypeId.interface) {
                    try errors.append(a, Diagnostic.init(u.line_number -| 1, "IMPORT statement outside of interface", 1, null));
                }
                continue;
            }
            if (!env.tree.contains(u.mod_name)) {
                try errors.append(a, Diagnostic.init(
                    u.line_number -| 1,
                    try std.fmt.allocPrint(a, "Module \"{s}\" not found in project", .{u.mod_name}),
                    3,
                    u.mod_name,
                ));
            }
        }
        if (self.scopeDataConst().implicit_line) |il| if (last_use_line >= il) {
            try errors.append(a, Diagnostic.init(il -| 1, "USE statements after IMPLICIT statement", 1, "IMPLICIT"));
        };
        return errors.items;
    }

    // ------------------------------------------------------------------
    // Code actions

    pub const Edit = struct { sline: usize, schar: usize, eline: usize, echar: usize, new_text: []const u8 };
    pub const Action = struct {
        title: []const u8,
        kind: []const u8,
        uri_path: []const u8,
        edits: []Edit,
        diagnostics: []Diagnostic,
    };

    fn addSubroutine(self: *const Obj, a: Allocator, interface_string: []const u8, no_contains: bool) !struct { path: ?[]const u8, edits: []Edit } {
        var edits: std.ArrayList(Edit) = .empty;
        const line_number = self.eline -| 1;
        if (self.scopeDataConst().contains_start == null and !no_contains) {
            var first_sub_line = line_number;
            for (self.childList()) |child| {
                const ct = child.getType(false);
                if (ct == C.TypeId.subroutine or ct == C.TypeId.function) first_sub_line = @min(first_sub_line, child.sline -| 1);
            }
            try edits.append(a, .{ .sline = first_sub_line, .schar = 0, .eline = first_sub_line, .echar = 0, .new_text = "CONTAINS\n" });
        }
        try edits.append(a, .{ .sline = line_number, .schar = 0, .eline = line_number, .echar = 0, .new_text = try std.mem.concat(a, u8, &.{ interface_string, "\n" }) });
        return .{ .path = self.file_ast.path, .edits = edits.items };
    }

    pub fn getActions(self: *const Obj, a: Allocator, sline: usize, eline: usize) !?[]Action {
        if (self.kind != .type) return null;
        var actions: std.ArrayList(Action) = .empty;
        var edits: std.ArrayList(Edit) = .empty;
        const line_number = self.eline -| 1;
        if (line_number < sline or line_number > eline) return actions.items;
        if (self.scopeDataConst().contains_start == null) {
            try edits.append(a, .{ .sline = line_number, .schar = 0, .eline = line_number, .echar = 0, .new_text = "CONTAINS\n" });
        }
        var diagnostics: std.ArrayList(Diagnostic) = .empty;
        var has_edits = false;
        for (self.scopeDataConst().in_children.items) |in_child| {
            if (!in_child.hasKeyword(KW.deferred)) continue;
            const in_parent_name = if (in_child.parent) |p| p.name else "None";
            const iface = (try in_child.getInterface(a, in_child.name, null, .{
                try std.fmt.allocPrint(a, "class({s})", .{in_parent_name}),
                try std.fmt.allocPrint(a, "CLASS({s})", .{self.name}),
            })) orelse continue;
            const parent = self.parent orelse continue;
            const res = try parent.addSubroutine(a, iface, has_edits);
            if (!optEql(res.path, self.file_ast.path)) continue;
            try edits.append(a, .{
                .sline = line_number,
                .schar = 0,
                .eline = line_number,
                .echar = 0,
                .new_text = try std.fmt.allocPrint(a, "  PROCEDURE :: {s} => {s}\n", .{ in_child.name, in_child.name }),
            });
            try edits.appendSlice(a, res.edits);
            var d = Diagnostic.init(line_number, try std.fmt.allocPrint(a, "Deferred procedure \"{s}\" not implemented", .{in_child.name}), 1, null);
            d.addRelated(in_child.file_ast.path, in_child.sline -| 1, "Inherited procedure declaration");
            try diagnostics.append(a, d);
            has_edits = true;
        }
        if (has_edits) {
            try actions.append(a, .{
                .title = "Implement deferred procedures",
                .kind = "quickfix",
                .uri_path = self.file_ast.path orelse "",
                .edits = edits.items,
                .diagnostics = diagnostics.items,
            });
        }
        return actions.items;
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// A diagnostic pending conversion into an LSP diagnostic
pub const Diagnostic = struct {
    sline: usize,
    message: []const u8,
    severity: i32 = 1,
    find_word: ?[]const u8 = null,
    related: ?Related = null,

    pub const Related = struct { path: ?[]const u8, line: usize, message: []const u8 };

    pub fn init(sline: usize, message: []const u8, severity: i32, find_word: ?[]const u8) Diagnostic {
        return .{ .sline = sline, .message = message, .severity = severity, .find_word = find_word };
    }

    pub fn addRelated(self: *Diagnostic, path: ?[]const u8, line: usize, message: []const u8) void {
        self.related = .{ .path = path, .line = line, .message = message };
    }

    pub fn build(self: Diagnostic, a: Allocator, file: *FortranFile) !BuiltDiag {
        var sline = self.sline;
        var schar: usize = 0;
        var echar: usize = 0;
        if (self.find_word) |w| {
            const res = try file.findWordInCodeLine(a, sline, w, true, false, false);
            sline = res.line;
            if (res.range.start >= 0) {
                schar = @intCast(res.range.start);
                echar = @intCast(res.range.end);
            }
        }
        return .{
            .sln = sline,
            .sch = schar,
            .eln = sline,
            .ech = echar,
            .message = self.message,
            .severity = self.severity,
            .related = self.related,
        };
    }
};

/// LSP-ready diagnostic with byte-based columns (range_json semantics:
/// a zero end line/char falls back to the start value)
pub const BuiltDiag = struct {
    sln: usize,
    sch: usize,
    eln: ?usize,
    ech: ?usize,
    message: []const u8,
    severity: i32,
    related: ?Diagnostic.Related = null,
    /// Columns are code point counts rather than byte offsets
    cols_are_codepoints: bool = false,
};

/// An END statement that does not match the scope that is open
pub const EndError = struct {
    /// Line of the END statement; null when it is the unnamed END of no scope at all
    end_line: ?usize,
    /// Line the diagnostic is reported at: the first line of the open scope,
    /// or the END statement itself when no scope is open
    scope_line: usize,
};

pub const IncludeInfo = struct {
    line_number: usize,
    path: []const u8,
    file: ?*FortranFile = null,
    scope_objs: std.ArrayList(*Obj) = .empty,
    /// Cached `Include` object returned by `find_in_scope`
    inc_obj: ?*Obj = null,
};

// --------------------------------------------------------------------------
// AST

pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    file: ?*FortranFile = null,
    path: ?[]const u8 = null,
    global_dict: std.array_hash_map.String(*Obj) = .empty,
    scope_list: std.ArrayList(*Obj) = .empty,
    variable_list: std.ArrayList(*Obj) = .empty,
    public_list: std.ArrayList([]const u8) = .empty,
    private_list: std.ArrayList([]const u8) = .empty,
    scope_stack: std.ArrayList(*Obj) = .empty,
    end_stack: std.ArrayList(*const regex.Regex) = .empty,
    include_statements: std.ArrayList(*IncludeInfo) = .empty,
    end_errors: std.ArrayList(EndError) = .empty,
    parse_errors: std.ArrayList(BuiltDiag) = .empty,
    inherit_objs: std.ArrayList(*Obj) = .empty,
    linkable_objs: std.ArrayList(*Obj) = .empty,
    external_objs: std.ArrayList(*Obj) = .empty,
    none_scope: ?*Obj = null,
    inc_scope: ?*Obj = null,
    /// The scope of the including file that this file is included into, so
    /// that names are looked up there after the file's own scopes (cleared
    /// when the workspace is relinked)
    included_in: ?*Obj = null,
    current_scope: ?*Obj = null,
    end_scope_regex: ?*const regex.Regex = null,
    enc_scope_name: ?[]const u8 = null,
    last_obj: ?*Obj = null,
    pending_doc: ?[]const u8 = null,

    pub fn create(gpa: Allocator, file: ?*FortranFile) !*Ast {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const self = try arena.allocator().create(Ast);
        self.* = .{ .arena = arena, .file = file };
        if (file) |f| self.path = try self.allocator().dupe(u8, f.path);
        return self;
    }

    /// Free the AST and every object it owns
    pub fn destroy(self: *Ast) void {
        var arena = self.arena;
        arena.deinit();
    }

    pub fn allocator(self: *Ast) Allocator {
        return self.arena.allocator();
    }

    fn createNoneScope(self: *Ast) Allocator.Error!void {
        std.debug.assert(self.none_scope == null);
        const ns = try Obj.newScope(self, .program, 1, "main", &.{});
        self.none_scope = ns;
        try self.addScope(ns, &R().END_PROGRAM_NONE, false, false);
    }

    fn getEncScopeName(self: *const Ast) ?[]const u8 {
        return if (self.current_scope) |cs| cs.fqsn else null;
    }

    pub fn addScope(self: *Ast, new_scope: *Obj, end_scope_regex: *const regex.Regex, exportable: bool, req_container: bool) !void {
        const a = self.allocator();
        try self.scope_list.append(a, new_scope);
        if (new_scope.requireInherit()) try self.inherit_objs.append(a, new_scope);
        if (new_scope.requireLink()) try self.linkable_objs.append(a, new_scope);
        if (self.current_scope == null) {
            if (req_container) {
                try self.createNoneScope();
                new_scope.fqsn = try std.mem.concat(a, u8, &.{ self.none_scope.?.fqsn, "::", try std.ascii.allocLowerString(a, new_scope.name) });
                try self.current_scope.?.addChild(new_scope);
                try self.scope_stack.append(a, self.current_scope.?);
            } else if (exportable) {
                try self.global_dict.put(a, new_scope.fqsn, new_scope);
            }
        } else {
            try self.current_scope.?.addChild(new_scope);
            try self.scope_stack.append(a, self.current_scope.?);
        }
        if (self.end_scope_regex) |r| try self.end_stack.append(a, r);
        self.current_scope = new_scope;
        self.end_scope_regex = end_scope_regex;
        self.enc_scope_name = self.getEncScopeName();
        self.last_obj = new_scope;
        if (self.pending_doc) |d| {
            new_scope.addDoc(d);
            self.pending_doc = null;
        }
    }

    pub fn endScope(self: *Ast, line_number: usize, check: bool) !void {
        if ((self.current_scope == null or self.current_scope == self.none_scope) and check) {
            try self.end_errors.append(self.allocator(), .{ .end_line = null, .scope_line = line_number });
            return;
        }
        self.current_scope.?.end(line_number);
        self.current_scope = self.scope_stack.pop();
        self.end_scope_regex = self.end_stack.pop();
        self.enc_scope_name = self.getEncScopeName();
    }

    pub fn addVariable(self: *Ast, new_var: *Obj) !void {
        const a = self.allocator();
        if (self.current_scope == null) {
            try self.createNoneScope();
            new_var.fqsn = try std.mem.concat(a, u8, &.{ self.none_scope.?.fqsn, "::", try std.ascii.allocLowerString(a, new_var.name) });
        }
        try self.current_scope.?.addChild(new_var);
        try self.variable_list.append(a, new_var);
        if (new_var.varData().is_external) try self.external_objs.append(a, new_var);
        if (new_var.requireLink()) try self.linkable_objs.append(a, new_var);
        self.last_obj = new_var;
        if (self.pending_doc) |d| {
            new_var.addDoc(d);
            self.pending_doc = null;
        }
    }

    pub fn addIntMember(self: *Ast, key: []const u8) !void {
        const cs = self.current_scope.?;
        try cs.scopeData().members.append(self.allocator(), try self.allocator().dupe(u8, key));
    }

    pub fn addPrivate(self: *Ast, name: []const u8) !void {
        try self.private_list.append(self.allocator(), try std.fmt.allocPrint(self.allocator(), "{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addPublic(self: *Ast, name: []const u8) !void {
        try self.public_list.append(self.allocator(), try std.fmt.allocPrint(self.allocator(), "{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addUse(self: *Ast, use_mod: *UseStmt) !void {
        if (self.current_scope == null) try self.createNoneScope();
        try self.current_scope.?.scopeData().use.append(self.allocator(), use_mod);
    }

    pub fn addInclude(self: *Ast, path: []const u8, line_number: usize) !void {
        const a = self.allocator();
        const inc = try a.create(IncludeInfo);
        inc.* = .{ .line_number = line_number, .path = try a.dupe(u8, path) };
        try self.include_statements.append(a, inc);
    }

    pub fn addDoc(self: *Ast, doc_string: []const u8, forward: bool) !void {
        if (doc_string.len == 0) return;
        const d = try self.allocator().dupe(u8, doc_string);
        if (forward) {
            self.pending_doc = d;
        } else if (self.last_obj) |lo| {
            lo.addDoc(d);
        }
    }

    pub fn addError(self: *Ast, msg: []const u8, sev: i32, ln: usize, sch: usize, ech: ?usize) !void {
        try self.parse_errors.append(self.allocator(), .{
            .sln = ln -| 1,
            .sch = sch,
            .eln = ln -| 1,
            .ech = ech,
            .message = try self.allocator().dupe(u8, msg),
            .severity = sev,
        });
    }

    /// All scopes containing the line (all scopes when null)
    pub fn getScopes(self: *Ast, a: Allocator, line_number: ?usize) ![]*Obj {
        const ln = line_number orelse return self.scope_list.items;
        var out: std.ArrayList(*Obj) = .empty;
        for (self.scope_list.items) |scope| {
            if (!(scope.sline <= ln and ln <= scope.eline)) continue;
            if (scope.parent) |p| if (p.kind == .interface) {
                for (scope.scopeData().use.items) |u| {
                    if (!u.is_import) continue;
                    if (u.import_type == .none) {
                        const single = try a.alloc(*Obj, 1);
                        single[0] = scope;
                        return single;
                    }
                }
            };
            try out.append(a, scope);
            try out.appendSlice(a, try scope.getAncestors(a));
        }
        if (out.items.len > 0 or self.none_scope == null) return out.items;
        const single = try a.alloc(*Obj, 1);
        single[0] = self.none_scope.?;
        return single;
    }

    pub fn getInnerScope(self: *Ast, line_number: usize) ?*Obj {
        var scope_sline: ?usize = null;
        var curr: ?*Obj = null;
        // scopes are listed as they open, so of those that open on the same
        // line (`do i = 1, n; associate (...)`) the last is the innermost
        // (hansec #229)
        for (self.scope_list.items) |scope| {
            if ((scope_sline == null or scope.sline >= scope_sline.?) and scope.sline <= line_number and line_number <= scope.eline) {
                curr = scope;
                scope_sline = scope.sline;
            }
        }
        if (curr == null) return self.none_scope;
        return curr;
    }

    fn findChildByName(parent: *Obj, name: []const u8) ?*Obj {
        for (parent.childList()) |child| {
            if (std.mem.eql(u8, child.name, name)) return child;
            if (std.mem.startsWith(u8, child.name, "#GEN_INT")) {
                for (child.childList()) |ic| if (std.mem.eql(u8, ic.name, name)) return ic;
            }
        }
        return null;
    }

    pub fn getObject(self: *Ast, fqsn: []const u8) ?*Obj {
        var it = std.mem.splitSequence(u8, fqsn, "::");
        const first = it.next() orelse return null;
        var current: ?*Obj = self.global_dict.get(first);
        if (current == null) {
            for (self.scope_list.items) |scope| {
                if (std.mem.eql(u8, scope.fqsn, first)) {
                    current = scope;
                    break;
                }
            }
            if (current == null) return null;
        }
        while (it.next()) |part| {
            current = findChildByName(current.?, part) orelse return null;
        }
        return current;
    }

    pub fn closeFile(self: *Ast, line_number: usize) !void {
        while (self.current_scope != null) try self.endScope(line_number, false);
        if (self.none_scope) |ns| {
            ns.end(line_number);
            for (self.scope_list.items, 0..) |s, i| if (s == ns) {
                _ = self.scope_list.orderedRemove(i);
                break;
            };
        }
        for (self.private_list.items) |name| {
            if (self.getObject(name)) |o| o.vis = .private;
        }
        for (self.public_list.items) |name| {
            if (self.getObject(name)) |o| o.vis = .public;
        }
    }

    pub fn resolveLinks(self: *Ast, env: Env, link_version: i64) !void {
        for (self.inherit_objs.items) |o| try o.resolveInherit(env, link_version);
        for (self.linkable_objs.items) |o| try o.resolveLink(env);
    }

    /// The workspace path of the file that an INCLUDE statement names: searched
    /// in the directory of the including file, then in `include_dirs`
    /// (absolute), as `#include` is (upstream #301)
    fn findInclude(workspace: anytype, file_dir: []const u8, include_dirs: []const []const u8, name: []const u8, tmp: Allocator) !?[]const u8 {
        // `#include` directives are resolved to absolute paths by the preprocessor
        if (std.fs.path.isAbsolute(name)) return try parser.normPath(tmp, name);
        const local = try parser.normPath(tmp, try std.fs.path.join(tmp, &.{ file_dir, name }));
        if (workspace.get(local) != null) return local;
        for (include_dirs) |dir| {
            const candidate = try parser.normPath(tmp, try std.fs.path.join(tmp, &.{ dir, name }));
            if (workspace.get(candidate) != null) return candidate;
        }
        return null;
    }

    /// Link the objects of included files into the including scopes
    pub fn resolveIncludes(self: *Ast, workspace: anytype, include_dirs: []const []const u8, only_path: ?[]const u8, tmp: Allocator) !void {
        const path = self.path orelse return;
        const file_dir = std.fs.path.dirname(path) orelse "";
        for (self.include_statements.items) |inc| {
            const file_path = (try findInclude(workspace, file_dir, include_dirs, inc.path, tmp)) orelse continue;
            if (only_path) |p| if (!std.mem.eql(u8, p, file_path)) continue;
            const parent_scope = self.getInnerScope(inc.line_number);
            const include_file = workspace.get(file_path) orelse continue;
            const include_ast = include_file.ast orelse continue;
            inc.file = include_file;
            inc.inc_obj = null;
            include_ast.included_in = parent_scope;
            if (include_ast.none_scope == null) continue;
            if (include_ast.inc_scope == null) include_ast.inc_scope = include_ast.none_scope;
            // Remove old objects
            if (parent_scope) |ps| {
                for (inc.scope_objs.items) |obj| {
                    for (ps.childList(), 0..) |c, i| if (c == obj) {
                        _ = ps.scopeData().children.orderedRemove(i);
                        break;
                    };
                }
            }
            inc.scope_objs.clearRetainingCapacity();
            for (include_ast.inc_scope.?.childList()) |child| {
                try inc.scope_objs.append(self.allocator(), child);
                if (parent_scope) |ps| {
                    try ps.addChild(child);
                    try child.updateFqsn(ps.fqsn);
                }
            }
            include_ast.none_scope = parent_scope;
        }
    }

    pub fn checkFile(self: *Ast, env: Env) !struct { errors: []Diagnostic, parse_errors: []BuiltDiag } {
        const a = env.tmp;
        var errors: std.ArrayList(Diagnostic) = .empty;
        var tmp_list: std.ArrayList(*Obj) = .empty;
        try tmp_list.appendSlice(a, self.scope_list.items);
        if (self.none_scope) |ns| try tmp_list.append(a, ns);
        for (self.end_errors.items) |e| {
            const message = if (e.end_line) |el|
                try std.fmt.allocPrint(a, "Unexpected end of scope at line {d}", .{el})
            else
                "Unexpected end statement: No open scopes";
            try errors.append(a, Diagnostic.init(e.scope_line -| 1, message, 1, null));
        }
        for (tmp_list.items) |scope| {
            if (!scope.checkValidParent()) {
                try errors.append(a, Diagnostic.init(
                    scope.sline -| 1,
                    try std.fmt.allocPrint(a, "Invalid parent for \"{s}\" declaration", .{try scope.getDesc(a)}),
                    1,
                    null,
                ));
            }
            try errors.appendSlice(a, try scope.checkUse(env));
            try errors.appendSlice(a, try scope.checkDefinitions(env));
            try errors.appendSlice(a, try scope.getDiagnostics(a));
        }
        return .{ .errors = errors.items, .parse_errors = self.parse_errors.items };
    }
};

// --------------------------------------------------------------------------
// Name resolution utilities (port of `utilities.py`)

/// Build the USE tree of a scope. `use_dict` maps module name -> merged USE.
pub fn getUseTree(
    env: Env,
    scope: *Obj,
    use_dict: *std.array_hash_map.String(*UseStmt),
    only_list: ?*const StrSet,
    rename_map: ?*const StrMap,
    curr_path: []const []const u8,
) Allocator.Error!void {
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

fn checkScope(env: Env, local_scope: *Obj, name_lower: []const u8, filter_public: bool, var_line_number: ?usize) Allocator.Error!?*Obj {
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

fn checkImportScope(scope: *const Obj, name_lower: []const u8) ?ImportType {
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
        i_var += 1;
        if (i_var == var_stack.len - 1) return type_obj;
        const name = try std.ascii.allocLowerString(env.tmp, str.strip(var_stack[i_var]));
        var_obj = (try findInScope(env, type_obj, name, .{ .local_only = true })) orelse return null;
    }
    // Python raises KeyError here
    return null;
}
