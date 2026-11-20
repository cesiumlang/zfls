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
const implicit = @import("implicit.zig");

fn R() *const patterns.Patterns {
    return patterns.get();
}

// The rest of the object model, in objects/
const objects_new = @import("objects/new.zig");
const objects_hover = @import("objects/hover.zig");
const objects_link = @import("objects/link.zig");
const objects_check = @import("objects/check.zig");
const objects_diagnostic = @import("objects/diagnostic.zig");
const objects_ast = @import("objects/ast.zig");
const objects_resolve = @import("objects/resolve.zig");
const objects_index = @import("objects/index.zig");
pub const same_name = @import("objects/same_name.zig");
pub const summary = @import("objects/summary.zig");

pub const Diagnostic = objects_diagnostic.Diagnostic;
pub const BuiltDiag = objects_diagnostic.BuiltDiag;
pub const EndError = objects_diagnostic.EndError;
pub const IncludeInfo = objects_ast.IncludeInfo;
pub const Ast = objects_ast.Ast;
pub const InnerScopes = objects_ast.InnerScopes;
pub const getUseTree = objects_resolve.getUseTree;
pub const FindOpts = objects_resolve.FindOpts;
pub const findInScope = objects_resolve.findInScope;
pub const findThroughUse = objects_resolve.findThroughUse;
pub const findAllThroughUse = objects_resolve.findAllThroughUse;
pub const comesThrough = objects_resolve.comesThrough;
pub const findInWorkspace = objects_resolve.findInWorkspace;
pub const declaredProcedure = objects_resolve.declaredProcedure;
pub const findSymbolsInWorkspace = objects_resolve.findSymbolsInWorkspace;
pub const climbTypeTree = objects_resolve.climbTypeTree;

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

const use_stmt = @import("objects/use.zig");
pub const ImportType = use_stmt.ImportType;
pub const UseStmt = use_stmt.UseStmt;
pub const StrSet = use_stmt.StrSet;
pub const StrMap = use_stmt.StrMap;

pub const AssocLink = struct { var_: *Obj, bind_name: []const u8, link_name: []const u8 };

pub const ObjTree = std.array_hash_map.String(TreeEntry);
pub const TreeEntry = struct { obj: *Obj, path: ?[]const u8 };

/// Shared context for name resolution: object tree and a scratch allocator
pub const Env = struct {
    tree: *ObjTree,
    tmp: Allocator,
    /// The definitions of the names that several files define, and the
    /// build's module directories, to choose among them (#187)
    same_names: ?*const same_name.SameNames = null,
    module_dirs: ?*const @import("project.zig").ModuleDirsMap = null,

    /// The global (module, program, top-level procedure) `name` as seen from
    /// file `ast`: its own definition before another file's of that name,
    /// and of several files', the one `same_name.pick` chooses.
    pub fn global(env: Env, ast: *const Ast, name: []const u8) ?*Obj {
        if (ast.global_dict.get(name)) |o| return o;
        if (env.same_names) |s| if (same_name.global(s, env.module_dirs, env.tmp, ast, name)) |o| return o;
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
    /// a BLOCK DATA unit, a scope of kind `.block` (a program unit, not
    /// the BLOCK construct)
    block_data: bool = false,
    implicit_line: ?usize = null,
    /// the letter ranges of its IMPLICIT statements and their types
    implicit_rules: []const implicit.Rule = &.{},
    /// Inherited children: of a type from its parent type, of a procedure
    /// from the submodule prototype it implements
    in_children: std.ArrayList(*Obj) = .empty,
    /// The names (lowercase) its PUBLIC and PRIVATE statements list: for
    /// those it has by USE, which have no object of their own to mark
    public_names: std.ArrayList([]const u8) = .empty,
    private_names: std.ArrayList([]const u8) = .empty,
    ext: ScopeExt = .none,
    /// `children` by name, for lookups (objects/index.zig)
    index: objects_index.ChildIndex = .{},
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
    /// a DEC STRUCTURE, which may nest in another
    dec_structure: bool = false,
    inherit_var: ?*Obj = null,
    inherit_tmp: ?[]const u8 = null,
    inherit_version: i64 = -1,
    abstract: bool = false,
};

pub const Interface = struct {
    mems: std.ArrayList(*Obj) = .empty,
    external: bool = false,
    abstract: bool = false,
    /// A generic interface, `interface f`, `interface operator(.op.)` or
    /// `interface assignment(=)`: its interface bodies are its specifics
    /// (#472), as are the names of its procedure statements
    generic: bool = false,
    /// The other interface blocks of a generic's name that make one generic
    /// with it (#478): in its scope, by USE, from its host. Their specifics
    /// are among `mems`.
    extends: std.ArrayList(*Obj) = .empty,
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
/// A scope's is apart (in its AST's arena), so that variables, most of the
/// objects, are not the size of a scope.
pub const Data = union(enum) {
    scope: *Scope,
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
    /// shared `KeywordInfo.empty` unless the object has some
    keyword_info: *const KeywordInfo = &KeywordInfo.empty,
    data: Data,

    /// Allocator owning this object's persistent data
    pub fn al(self: *const Obj) Allocator {
        return self.file_ast.allocator();
    }

    pub fn nameLowerEql(self: *const Obj, other: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, other);
    }

    pub fn hasKeyword(self: *const Obj, id: C.Kw) bool {
        return std.mem.findScalar(C.Kw, self.keywords.items, id) != null;
    }

    // ------------------------------------------------------------------
    // Data by kind

    pub fn scopeData(self: *Obj) *Scope {
        return self.data.scope;
    }

    pub fn scopeDataConst(self: *const Obj) *const Scope {
        return self.data.scope;
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
            .scope => |s| switch (s.ext) {
                .procedure => |*p| p,
                else => null,
            },
            else => null,
        };
    }

    pub fn procDataOptConst(self: *const Obj) ?*const Procedure {
        return switch (self.data) {
            .scope => |s| switch (s.ext) {
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

    /// The argument list of a procedure or intrinsic, "" for others; of an
    /// intrinsic with several forms, the first one's
    pub fn argList(self: *const Obj) []const u8 {
        return switch (self.data) {
            .scope => |s| switch (s.ext) {
                .procedure => |p| p.args,
                else => "",
            },
            .intrinsic => |i| str.beforeFirst(i.args, "|"),
            .variable => "",
        };
    }

    /// The argument lists of the forms of an intrinsic (`THIS_IMAGE` has
    /// two); the one of `argList` for others
    pub fn argForms(self: *const Obj, a: Allocator) ![]const []const u8 {
        return switch (self.data) {
            .intrinsic => |i| str.split(a, i.args, "|"),
            else => {
                const one = try a.alloc([]const u8, 1);
                one[0] = self.argList();
                return one;
            },
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

    pub fn computeFqsn(a: Allocator, file_ast: *Ast, name: []const u8) ![]const u8 {
        const lname = try std.ascii.allocLowerString(a, name);
        if (file_ast.enc_scope_name) |enc| {
            return std.mem.concat(a, u8, &.{ try std.ascii.allocLowerString(a, enc), "::", lname });
        }
        return lname;
    }

    pub const FunOpts = struct {
        args: []const u8 = "",
        mod_flag: bool = false,
        keywords: []const C.Kw = &.{},
        keyword_info: KeywordInfo = .{},
        result_type: ?[]const u8 = null,
        result_name: ?[]const u8 = null,
    };

    pub const VarOpts = struct {
        keyword_info: KeywordInfo = .{},
        kind: ?[]const u8 = null,
        link_obj: ?[]const u8 = null,
    };

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
            .block => if (self.isBlockData()) "BLOCK DATA" else "BLOCK",
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
    pub fn findSubmoduleParent(self: *const Obj, env: Env) ?*Obj {
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
        objects_index.changed(self);
        child.setParent(self);
    }

    /// Remove the child at position `i`
    pub fn removeChild(self: *Obj, i: usize) void {
        _ = self.scopeData().children.orderedRemove(i);
        objects_index.changed(self);
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
        const t = if (self.kind == .select) self.selectDataConst().select_type else return false;
        // TYPE IS, CLASS IS, CLASS DEFAULT; a case of SELECT RANK
        return t == 3 or t == 4 or t == 5;
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

    /// Whether the interface bodies of this interface block are names of
    /// the scope around it, as the procedures they declare are: those of
    /// every interface block, an unnamed (`#GEN_INT`), abstract, OPERATOR or
    /// ASSIGNMENT one and a named generic one (#474), but for a body that
    /// has the generic's name, which is the generic's there
    pub fn bodiesAreNames(self: *const Obj, name: []const u8) bool {
        return self.kind == .interface and !std.ascii.eqlIgnoreCase(self.name, name);
    }

    pub fn isAbstract(self: *const Obj) bool {
        return self.kind == .interface and self.ifaceDataConst().abstract;
    }

    /// Whether an END alone cannot end it: a construct, not a BLOCK DATA
    pub fn reqNamedEnd(self: *const Obj) bool {
        return self.kind.isBlock() and !self.isBlockData();
    }

    pub fn isBlockData(self: *const Obj) bool {
        return self.kind == .block and self.scopeDataConst().block_data;
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
                if (pt == C.TypeId.class and self.typeDataConst().dec_structure) return true;
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

    pub const Hover = struct { msg: ?[]const u8 = null, docs: ?[]const u8 = null };

    pub const ArgSig = struct { label: []const u8, doc_md: ?[]const u8 = null };
    pub const Signature = struct { label: ?[]const u8 = null, doc: ?[]const u8 = null, params: []ArgSig = &.{} };

    // ------------------------------------------------------------------
    // Linking

    // ------------------------------------------------------------------
    // Diagnostics

    const KnownType = struct { kind: u8, obj: *Obj };
    pub const KnownTypes = std.array_hash_map.String(?KnownType);

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

    // objects/new.zig
    const scopeExtFor = objects_new.scopeExtFor;
    pub const becomeProcedure = objects_new.becomeProcedure;
    pub const newScope = objects_new.newScope;
    pub const newInterface = objects_new.newInterface;
    pub const newSubmodule = objects_new.newSubmodule;
    pub const newSubroutine = objects_new.newSubroutine;
    pub const newFunction = objects_new.newFunction;
    pub const newSelect = objects_new.newSelect;
    pub const newVariable = objects_new.newVariable;
    pub const newMethod = objects_new.newMethod;
    pub const newIntrinsic = objects_new.newIntrinsic;

    // objects/hover.zig
    pub const getSnippet = objects_hover.getSnippet;
    pub const getHover = objects_hover.getHover;
    pub const getHoverMd = objects_hover.getHoverMd;
    pub const getKeywordStrings = objects_hover.getKeywordStrings;
    pub const getDocsFull = objects_hover.getDocsFull;
    const endsInListItem = objects_hover.endsInListItem;
    pub const getSignature = objects_hover.getSignature;
    pub const getSignatures = objects_hover.getSignatures;
    pub const getInterfaceArray = objects_hover.getInterfaceArray;
    pub const getInterface = objects_hover.getInterface;

    // objects/link.zig
    pub const resolveInherit = objects_link.resolveInherit;
    pub const linkLoops = objects_link.linkLoops;
    pub const resolveLink = objects_link.resolveLink;
    pub const resolveArgLink = objects_link.resolveArgLink;
    pub const copyInterface = objects_link.copyInterface;
    pub const resetInterfaceCopy = objects_link.resetInterfaceCopy;
    pub const hasChildNamed = objects_link.hasChildNamed;
    pub const resolveSubmoduleLink = objects_link.resolveSubmoduleLink;
    pub const getTypeObj = objects_link.getTypeObj;
    pub const getOverridden = objects_link.getOverridden;

    // objects/check.zig
    pub const getDiagnostics = objects_check.getDiagnostics;
    pub const checkDefinition = objects_check.checkDefinition;
    pub const checkDefinitions = objects_check.checkDefinitions;
    pub const checkUse = objects_check.checkUse;
    pub const addSubroutine = objects_check.addSubroutine;
    pub const getActions = objects_check.getActions;
};

pub fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// --------------------------------------------------------------------------
// AST

// --------------------------------------------------------------------------
// Name resolution utilities (port of `utilities.py`)
