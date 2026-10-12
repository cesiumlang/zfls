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

pub const ImportType = enum(i8) { default = -1, none = 0, all = 1, only = 2 };

/// USE or IMPORT statement
pub const UseStmt = struct {
    mod_name: []const u8,
    only_list: StrSet = .{},
    rename_map: StrMap = .{},
    line_number: i64 = 0,
    is_import: bool = false,
    import_type: ImportType = .default,
    /// Parent scope of IMPORT statement i.e. parent of the interface
    scope: ?*Obj = null,

    /// Construct (lowercasing names like the Python `Use` initializer)
    pub fn init(a: Allocator, mod_name: []const u8, only: []const []const u8, renames: []const [2][]const u8) !*UseStmt {
        const u = try a.create(UseStmt);
        u.* = .{ .mod_name = try str.lower(a, mod_name) };
        for (only) |o| try u.only_list.add(a, try str.lower(a, o));
        for (renames) |r| try u.rename_map.put(a, try str.lower(a, r[0]), try str.lower(a, r[1]));
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
        for (self.items.items) |it| if (str.eql(it, s)) return true;
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

    pub fn get(self: *const StrMap, k: []const u8) ?[]const u8 {
        for (self.keys.items, 0..) |key, i| if (str.eql(key, k)) return self.values.items[i];
        return null;
    }

    pub fn put(self: *StrMap, a: Allocator, k: []const u8, v: []const u8) !void {
        for (self.keys.items, 0..) |key, i| if (str.eql(key, k)) {
            self.values.items[i] = v;
            return;
        };
        try self.keys.append(a, k);
        try self.values.append(a, v);
    }

    pub fn remove(self: *StrMap, k: []const u8) void {
        for (self.keys.items, 0..) |key, i| if (str.eql(key, k)) {
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
};

pub const Obj = struct {
    kind: Kind,
    name: []const u8,
    fqsn: []const u8 = "",
    sline: i64 = 0,
    eline: i64 = -1,
    vis: i8 = 0,
    def_vis: i8 = 0,
    doc_str: ?[]const u8 = null,
    parent: ?*Obj = null,
    implicit_vars: ?bool = null,
    file_ast: *Ast,
    keywords: std.ArrayList(u8) = .empty,
    keyword_info: KeywordInfo = .{},

    // Scope
    children: std.ArrayList(*Obj) = .empty,
    members: std.ArrayList([]const u8) = .empty,
    use: std.ArrayList(*UseStmt) = .empty,
    inherit: ?[]const u8 = null,
    contains_start: ?i64 = null,
    implicit_line: ?i64 = null,

    // Type
    in_children: std.ArrayList(*Obj) = .empty,
    inherit_var: ?*Obj = null,
    inherit_tmp: ?[]const u8 = null,
    inherit_version: i64 = -1,
    abstract: bool = false,

    // Interface
    mems: std.ArrayList(*Obj) = .empty,
    external: bool = false,

    // Submodule
    ancestor_name: []const u8 = "",
    ancestor_obj: ?*Obj = null,

    // Subroutine / Function
    args: []const u8 = "",
    args_snip: []const u8 = "",
    arg_objs: std.ArrayList(?*Obj) = .empty,
    missing_args: std.ArrayList(*Obj) = .empty,
    mod_scope: bool = false,
    /// Subroutine/Function prototype link, Variable/Method link
    link_obj: ?*Obj = null,
    result_name: ?[]const u8 = null,
    result_type: ?[]const u8 = null,
    result_obj: ?*Obj = null,

    // Associate
    links: std.ArrayList(AssocLink) = .empty,

    // Select
    select_type: i32 = 0,
    binding_name: ?[]const u8 = null,
    bound_var: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,

    // Variable / Method
    desc: []const u8 = "",
    vkind: ?[]const u8 = null,
    type_obj: ?*Obj = null,
    is_const: bool = false,
    is_external: bool = false,
    param_val: ?[]const u8 = null,
    link_name: ?[]const u8 = null,
    callable: bool = false,
    drop_arg: i64 = -1,
    pass_name: ?[]const u8 = null,

    // Intrinsic
    itype: i32 = 0,

    /// Set when `copyInterface` imported data from a submodule prototype
    linked_from_interface: bool = false,

    /// Allocator owning this object's persistent data
    pub fn al(self: *const Obj) Allocator {
        return self.file_ast.allocator();
    }

    pub fn nameLowerEql(self: *const Obj, other: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, other);
    }

    pub fn hasKeyword(self: *const Obj, id: u8) bool {
        return std.mem.indexOfScalar(u8, self.keywords.items, id) != null;
    }

    // ------------------------------------------------------------------
    // Construction

    fn computeFqsn(a: Allocator, file_ast: *Ast, name: []const u8) ![]const u8 {
        const lname = try str.lower(a, name);
        if (file_ast.enc_scope_name) |enc| {
            return str.concat(a, &.{ try str.lower(a, enc), "::", lname });
        }
        return lname;
    }

    /// Create a Scope-derived object (`Scope.__init__`)
    pub fn newScope(file_ast: *Ast, kind: Kind, line_number: i64, name: []const u8, keywords: []const u8) !*Obj {
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
        };
        try o.keywords.appendSlice(a, keywords);
        switch (kind) {
            .type => {
                o.abstract = o.hasKeyword(KW.abstract);
                if (o.hasKeyword(KW.public)) o.vis = 1;
                if (o.hasKeyword(KW.private)) o.vis = -1;
            },
            .interface => {},
            else => {},
        }
        return o;
    }

    pub fn newInterface(file_ast: *Ast, line_number: i64, name: []const u8, abstract: bool) !*Obj {
        const o = try newScope(file_ast, .interface, line_number, name, &.{});
        o.abstract = abstract;
        o.external = str.startsWith(name, "#GEN_INT") and !abstract;
        return o;
    }

    pub fn newSubmodule(file_ast: *Ast, line_number: i64, name: []const u8, ancestor_name: []const u8) !*Obj {
        const o = try newScope(file_ast, .submodule, line_number, name, &.{});
        o.ancestor_name = try o.al().dupe(u8, ancestor_name);
        return o;
    }

    pub fn newSubroutine(file_ast: *Ast, line_number: i64, name: []const u8, args: []const u8, mod_flag: bool, keywords: []const u8) !*Obj {
        const o = try newScope(file_ast, .subroutine, line_number, name, keywords);
        const a = o.al();
        o.args = try str.replace(a, args, " ", "");
        o.args_snip = o.args;
        o.mod_scope = mod_flag;
        return o;
    }

    pub const FunOpts = struct {
        args: []const u8 = "",
        mod_flag: bool = false,
        keywords: []const u8 = &.{},
        keyword_info: KeywordInfo = .{},
        result_type: ?[]const u8 = null,
        result_name: ?[]const u8 = null,
    };

    pub fn newFunction(file_ast: *Ast, line_number: i64, name: []const u8, opts: FunOpts) !*Obj {
        const o = try newScope(file_ast, .function, line_number, name, opts.keywords);
        const a = o.al();
        o.args = try str.lower(a, try str.replace(a, opts.args, " ", ""));
        o.args_snip = o.args;
        o.mod_scope = opts.mod_flag;
        o.result_name = try str.dupeOpt(a, opts.result_name);
        o.result_type = try str.dupeOpt(a, opts.result_type);
        o.keyword_info = try opts.keyword_info.dupe(a);
        if (o.result_name == null) o.result_name = o.name;
        return o;
    }

    pub fn newSelect(file_ast: *Ast, line_number: i64, name: []const u8, info: parser.SelectInfo) !*Obj {
        const o = try newScope(file_ast, .select, line_number, name, &.{});
        const a = o.al();
        o.select_type = info.type;
        if (o.select_type == 2) {
            const binding = info.binding orelse "";
            const parts = try str.split(a, binding, "=>");
            if (parts.len == 1) {
                o.bound_var = try a.dupe(u8, str.strip(parts[0]));
            } else if (parts.len == 2) {
                o.binding_name = try a.dupe(u8, str.strip(parts[0]));
                o.bound_var = try a.dupe(u8, str.strip(parts[1]));
            }
        } else if (o.select_type == 3) {
            o.binding_type = try str.dupeOpt(a, info.binding);
        }
        // Close previous "TYPE IS" region if open
        if (file_ast.current_scope) |cs| {
            if (cs.getType(false) == C.SELECT_TYPE_ID and cs.isTypeRegion()) {
                file_ast.endScope(line_number, true);
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
    pub fn newVariable(file_ast: *Ast, line_number: i64, name: []const u8, var_desc: []const u8, keywords: []const u8, opts: VarOpts) !*Obj {
        const a = file_ast.allocator();
        const o = try a.create(Obj);
        const nm = try a.dupe(u8, name);
        o.* = .{
            .kind = .variable,
            .name = nm,
            .file_ast = file_ast,
            .sline = line_number,
            .eline = line_number,
            .desc = try a.dupe(u8, var_desc),
            .keyword_info = try opts.keyword_info.dupe(a),
            .vkind = try str.dupeOpt(a, opts.kind),
            .fqsn = try computeFqsn(a, file_ast, nm),
        };
        try o.keywords.appendSlice(a, keywords);
        o.callable = R().CLASS_VAR.match(try o.getDescNoLink(a)) != null;
        if (opts.link_obj) |l| o.link_name = try str.lower(a, l);
        if (o.hasKeyword(KW.public)) o.vis = 1;
        if (o.hasKeyword(KW.private)) o.vis = -1;
        if (o.hasKeyword(KW.parameter)) o.is_const = true;
        if (o.hasKeyword(KW.external) or std.ascii.eqlIgnoreCase(o.desc, "external")) o.is_external = true;
        return o;
    }

    /// `Method.__init__` (type-bound procedure / procedure pointer)
    pub fn newMethod(file_ast: *Ast, line_number: i64, name: []const u8, var_desc: []const u8, keywords: []const u8, keyword_info: KeywordInfo, proc_ptr: ?[]const u8, link_obj: ?[]const u8) !*Obj {
        const o = try newVariable(file_ast, line_number, name, var_desc, keywords, .{
            .keyword_info = keyword_info,
            .kind = proc_ptr,
            .link_obj = link_obj,
        });
        const a = o.al();
        o.kind = .method;
        o.drop_arg = -1;
        o.pass_name = o.keyword_info.pass;
        if (link_obj == null) {
            const d = try str.lower(a, try o.getDescNoLink(a));
            if (helpers.getParenSubstring(d)) |sub| o.link_name = sub else o.link_name = null;
        }
        return o;
    }

    pub fn newIntrinsic(file_ast: *Ast, name: []const u8, itype: i32, doc_str: ?[]const u8, args: []const u8) !*Obj {
        const a = file_ast.allocator();
        const o = try a.create(Obj);
        o.* = .{
            .kind = .intrinsic,
            .name = try a.dupe(u8, name),
            .file_ast = file_ast,
            .itype = itype,
            .doc_str = try str.dupeOpt(a, doc_str),
            .args = try str.replace(a, args, " ", ""),
            .fqsn = "",
        };
        return o;
    }

    // ------------------------------------------------------------------
    // Basic accessors

    pub fn getType(self: *const Obj, no_link: bool) i32 {
        return switch (self.kind) {
            .scope, .include => C.BASE_TYPE_ID,
            .module, .program => C.MODULE_TYPE_ID,
            .submodule => C.SUBMODULE_TYPE_ID,
            .subroutine => C.SUBROUTINE_TYPE_ID,
            .function => C.FUNCTION_TYPE_ID,
            .type => C.CLASS_TYPE_ID,
            .interface => C.INTERFACE_TYPE_ID,
            .block => C.BLOCK_TYPE_ID,
            .select => C.SELECT_TYPE_ID,
            .do_ => C.DO_TYPE_ID,
            .where => C.WHERE_TYPE_ID,
            .if_ => C.IF_TYPE_ID,
            .associate => C.ASSOC_TYPE_ID,
            .enum_ => C.ENUM_TYPE_ID,
            .variable => if (self.link_obj) |l| l.getType(false) else C.VAR_TYPE_ID,
            .method => if (!no_link and self.link_obj != null) self.link_obj.?.getType(false) else C.METH_TYPE_ID,
            .intrinsic => self.itype,
        };
    }

    /// Variable description without following links (`get_desc(True)`)
    pub fn getDescNoLink(self: *const Obj, a: Allocator) ![]const u8 {
        if (self.kind.isVariable()) {
            if (self.vkind) |k| if (k.len > 0) return str.concat(a, &.{ self.desc, k });
            return self.desc;
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
            .function => if (self.result_type) |rt| (if (rt.len > 0) try str.concat(a, &.{ rt, " FUNCTION" }) else "FUNCTION") else "FUNCTION",
            .type => "TYPE",
            .interface => "INTERFACE",
            .block => "BLOCK",
            .do_ => "DO",
            .if_ => "IF",
            .where => "WHERE",
            .enum_ => "ENUM",
            .associate => "ASSOCIATE",
            .select => "SELECT",
            .variable, .method => if (self.link_obj) |l| l.getDesc(a) else self.getDescNoLink(a),
            .intrinsic => switch (self.itype) {
                2 => "SUBROUTINE",
                14 => "KEYWORD",
                15 => "STATEMENT",
                else => "INTRINSIC",
            },
        };
    }

    pub fn getChildren(self: *const Obj, a: Allocator, public_only: bool) ![]*Obj {
        switch (self.kind) {
            .variable, .method, .intrinsic => return &.{},
            .type, .subroutine, .function => {
                var out: std.ArrayList(*Obj) = .empty;
                try out.appendSlice(a, self.children.items);
                try out.appendSlice(a, self.in_children.items);
                return out.items;
            },
            .block, .do_, .if_, .where, .enum_, .associate, .select => return a.dupe(*Obj, self.children.items),
            else => {
                if (!public_only) return a.dupe(*Obj, self.children.items);
                var out: std.ArrayList(*Obj) = .empty;
                for (self.children.items) |child| {
                    if (child.vis < 0 or (self.def_vis < 0 and child.vis <= 0)) continue;
                    try out.append(a, child);
                }
                return out.items;
            },
        }
    }

    pub fn getAncestors(self: *const Obj, a: Allocator) ![]*Obj {
        if (self.kind != .submodule) return &.{};
        const anc = self.ancestor_obj orelse return &.{};
        var out: std.ArrayList(*Obj) = .empty;
        try out.append(a, anc);
        try out.appendSlice(a, try anc.getAncestors(a));
        return out.items;
    }

    pub fn setParent(self: *Obj, parent_obj: ?*Obj) void {
        self.parent = parent_obj;
        if (self.kind == .method) {
            const p = parent_obj orelse return;
            if (p.getType(false) == C.CLASS_TYPE_ID) {
                if (!self.hasKeyword(KW.nopass)) self.drop_arg = 0;
                if (p.contains_start != null and self.sline > p.contains_start.? and self.link_name == null) {
                    self.link_name = str.lower(self.al(), self.name) catch self.name;
                }
            }
        }
    }

    pub fn addChild(self: *Obj, child: *Obj) !void {
        try self.children.append(self.al(), child);
        child.setParent(self);
    }

    pub fn updateFqsn(self: *Obj, enc_scope: ?[]const u8) !void {
        if (!self.kind.isScope() and !self.kind.isVariable()) return;
        const a = self.al();
        const lname = try str.lower(a, self.name);
        if (enc_scope) |e| {
            self.fqsn = try str.concat(a, &.{ try str.lower(a, e), "::", lname });
        } else {
            self.fqsn = lname;
        }
        for (self.children.items) |child| try child.updateFqsn(self.fqsn);
    }

    pub fn end(self: *Obj, line_number: i64) void {
        self.eline = line_number;
    }

    pub fn addDoc(self: *Obj, doc: []const u8) void {
        self.doc_str = doc;
    }

    pub fn setImplicit(self: *Obj, flag: bool, line_number: i64) void {
        self.implicit_vars = flag;
        self.implicit_line = line_number;
    }

    pub fn markContains(self: *Obj, line_number: i64) error{MultipleContains}!void {
        if (self.contains_start != null) return error.MultipleContains;
        self.contains_start = line_number;
    }

    pub fn isTypeRegion(self: *const Obj) bool {
        return self.kind == .select and (self.select_type == 3 or self.select_type == 4);
    }

    pub fn isTypeBinding(self: *const Obj) bool {
        return self.kind == .select and self.select_type == 2;
    }

    pub fn getDocumentation(self: *const Obj) ?[]const u8 {
        if (self.kind == .method) {
            if (self.link_obj) |l| if (self.doc_str == null) return l.getDocumentation();
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
        return self.kind.isSubroutine() and self.mod_scope;
    }

    pub fn isCallable(self: *const Obj) bool {
        return switch (self.kind) {
            .interface, .subroutine, .method => true,
            .function => false,
            .variable => self.callable,
            .intrinsic => self.itype == 2,
            else => false,
        };
    }

    pub fn isExternalInt(self: *const Obj) bool {
        return self.kind == .interface and self.external;
    }

    pub fn isAbstract(self: *const Obj) bool {
        return self.kind == .interface and self.abstract;
    }

    pub fn reqNamedEnd(self: *const Obj) bool {
        return self.kind.isBlock();
    }

    pub fn isParameter(self: *const Obj) bool {
        return self.is_const;
    }

    pub fn setExternalAttr(self: *Obj) !void {
        try self.keywords.append(self.al(), KW.external);
        self.is_external = true;
    }

    pub fn checkValidParent(self: *const Obj) bool {
        switch (self.kind) {
            .module, .program, .submodule => return self.parent == null,
            .type => {
                const p = self.parent orelse return false;
                const pt = p.getType(false);
                return pt != C.CLASS_TYPE_ID and pt < C.BLOCK_TYPE_ID;
            },
            .subroutine, .function => {
                if (self.parent) |p| {
                    const pt = p.getType(false);
                    if (pt == C.CLASS_TYPE_ID or pt >= C.BLOCK_TYPE_ID) return false;
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
            .variable, .method => self.link_name != null,
            .interface, .subroutine, .function, .submodule, .associate => true,
            else => false,
        };
    }

    // ------------------------------------------------------------------
    // Snippets, hover, signature

    pub const Snippet = struct { call: ?[]const u8 = null, snippet: ?[]const u8 = null };

    pub fn getSnippet(self: *const Obj, a: Allocator, name_replace: ?[]const u8, drop_arg: i64) Allocator.Error!Snippet {
        switch (self.kind) {
            .variable => {
                const name = name_replace orelse self.name;
                if (self.link_obj) |l| return l.getSnippet(a, name, drop_arg);
                return .{};
            },
            .method => {
                if (self.link_obj) |l| {
                    const name = name_replace orelse self.name;
                    return l.getSnippet(a, name, self.drop_arg);
                }
                return .{};
            },
            .subroutine, .function => {
                var arg_list: std.ArrayList([]const u8) = .empty;
                try arg_list.appendSlice(a, try str.split(a, self.args_snip, ","));
                if (drop_arg >= 0 and drop_arg < arg_list.items.len) {
                    _ = arg_list.orderedRemove(@intCast(drop_arg));
                }
                var arg_str: []const u8 = "()";
                var arg_snip: ?[]const u8 = null;
                if (arg_list.items.len > 0) {
                    const ph = try helpers.getPlaceholders(a, arg_list.items);
                    arg_str = ph[0];
                    arg_snip = ph[1];
                }
                const name = name_replace orelse self.name;
                return .{
                    .call = try str.concat(a, &.{ name, arg_str }),
                    .snippet = if (arg_snip) |s| try str.concat(a, &.{ name, s }) else null,
                };
            },
            .intrinsic => {
                var arg_str: []const u8 = undefined;
                var arg_snip: ?[]const u8 = null;
                if (self.args.len == 0) {
                    if (self.itype >= 14) return .{};
                    arg_str = "()";
                } else {
                    const ph = try helpers.getPlaceholders(a, try str.split(a, self.args, ","));
                    arg_str = ph[0];
                    arg_snip = ph[1];
                }
                const name = name_replace orelse self.name;
                return .{
                    .call = try str.concat(a, &.{ name, arg_str }),
                    .snippet = if (arg_snip) |s| try str.concat(a, &.{ name, s }) else null,
                };
            },
            else => return .{},
        }
    }

    pub const Hover = struct { msg: ?[]const u8 = null, docs: ?[]const u8 = null };

    pub fn getHover(self: *const Obj, a: Allocator, long: bool, drop_arg: i64) Allocator.Error!Hover {
        switch (self.kind) {
            .module, .program, .submodule => return .{
                .msg = try str.concat(a, &.{ try self.getDesc(a), " ", self.name }),
                .docs = self.getDocumentation(),
            },
            .type => {
                var kws: std.ArrayList([]const u8) = .empty;
                try kws.append(a, "TYPE");
                if (self.abstract) try kws.append(a, "ABSTRACT");
                if (self.inherit) |inh| if (inh.len > 0) try kws.append(a, try str.print(a, "EXTENDS({s})", .{inh}));
                const decl = try str.join(a, ", ", kws.items);
                return .{ .msg = try str.print(a, "{s} :: {s}", .{ decl, self.name }), .docs = self.getDocumentation() };
            },
            .subroutine => {
                const sig = try self.getSnippet(a, null, drop_arg);
                var kw: std.ArrayList([]const u8) = .empty;
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "SUBROUTINE ");
                var hover_array: std.ArrayList([]const u8) = .empty;
                try hover_array.append(a, try str.concat(a, &.{ try str.join(a, " ", kw.items), sig.call.? }));
                var docs: std.ArrayList([]const u8) = .empty;
                try self.getDocsFull(a, &hover_array, &docs, long, drop_arg);
                return .{
                    .msg = try str.join(a, "\n ", hover_array.items),
                    .docs = try str.join(a, "   \n", docs.items),
                };
            },
            .function => {
                var fun_sig = (try self.getSnippet(a, null, drop_arg)).call.?;
                if (long) fun_sig = try str.print(a, "{s} RESULT({s})", .{ fun_sig, self.result_name orelse self.name });
                var kw: std.ArrayList([]const u8) = .empty;
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "FUNCTION");
                var hover_array: std.ArrayList([]const u8) = .empty;
                try hover_array.append(a, try str.print(a, "{s} {s}", .{ try str.join(a, " ", kw.items), fun_sig }));
                var docs: std.ArrayList([]const u8) = .empty;
                try self.getDocsFull(a, &hover_array, &docs, long, drop_arg);
                if (self.result_obj != null and long) {
                    const ro = self.result_obj.?;
                    const h = try ro.getHover(a, false, -1);
                    if (h.docs) |d| {
                        try docs.append(a, try str.print(a, "\n**Return:**  \n`{s}`{s}", .{ ro.name, d }));
                    }
                    try hover_array.append(a, h.msg orelse "None");
                } else if (self.result_type != null and self.result_type.?.len > 0 and long) {
                    hover_array.items[0] = try str.print(a, "{s} {s}", .{ self.result_type.?, hover_array.items[0] });
                }
                return .{
                    .msg = try str.join(a, "\n ", hover_array.items),
                    .docs = try str.join(a, "  \n", docs.items),
                };
            },
            .variable => {
                const doc_str = self.getDocumentation();
                var parts: std.ArrayList([]const u8) = .empty;
                try parts.append(a, try self.getDesc(a));
                try parts.appendSlice(a, try self.getKeywordStrings(a));
                var hover = try str.join(a, ", ", parts.items);
                if (!str.startsWith(hover, "#")) hover = try str.print(a, "{s} :: {s}", .{ hover, self.name });
                if (self.isParameter()) if (self.param_val) |pv| {
                    hover = try str.print(a, "{s} = {s}", .{ hover, pv });
                };
                return .{ .msg = hover, .docs = doc_str };
            },
            .method => {
                var docs = self.getDocumentation();
                var hover_str: []const u8 = undefined;
                if (self.link_obj) |l| {
                    const lh = try l.getHover(a, true, self.drop_arg);
                    const link_msg = lh.msg orelse "None";
                    hover_str = try str.replaceFirst(a, link_msg, l.name, self.name);
                    if (lh.docs) |link_docs| {
                        if (l.getDocumentation()) |top| {
                            docs = try str.replaceFirst(a, link_docs, top, docs orelse "None");
                        } else if (link_docs.len > 0) {
                            docs = try str.concat(a, &.{ docs orelse "", "  \n", link_docs });
                        }
                    }
                } else {
                    const sig = try self.getSnippet(a, null, -1);
                    hover_str = try str.print(a, "{s} {s}", .{ try self.getDesc(a), sig.call orelse "None" });
                }
                return .{ .msg = hover_str, .docs = docs };
            },
            .intrinsic => return .{ .msg = null, .docs = self.doc_str },
            else => return .{},
        }
    }

    pub fn getHoverMd(self: *const Obj, a: Allocator, long: bool, drop_arg: i64) ![]const u8 {
        const h = try self.getHover(a, long, drop_arg);
        return helpers.fortranMd(a, h.msg, h.docs);
    }

    pub fn getKeywordStrings(self: *const Obj, a: Allocator) ![][]const u8 {
        if (self.link_obj) |l| return helpers.getKeywords(a, l.keywords.items, l.keyword_info);
        return helpers.getKeywords(a, self.keywords.items, self.keyword_info);
    }

    fn getDocsFull(self: *const Obj, a: Allocator, hover_array: *std.ArrayList([]const u8), doc_strs: *std.ArrayList([]const u8), long: bool, drop_arg: i64) !void {
        if (self.getDocumentation()) |d| try doc_strs.append(a, d);
        if (!long) return;
        var has_args = true;
        for (self.arg_objs.items, 0..) |arg_obj_opt, i| {
            const arg_obj = arg_obj_opt orelse continue;
            if (@as(i64, @intCast(i)) == drop_arg) continue;
            const h = try arg_obj.getHover(a, false, -1);
            try hover_array.append(a, h.msg orelse "None");
            if (h.docs) |d| if (d.len > 0) {
                if (has_args) {
                    try doc_strs.append(a, "\n**Parameters:**  ");
                    has_args = false;
                }
                try doc_strs.append(a, str.strip(try str.print(a, "`{s}` {s}", .{ arg_obj.name, d })));
            };
        }
    }

    pub const ArgSig = struct { label: []const u8, doc_md: ?[]const u8 = null };
    pub const Signature = struct { label: ?[]const u8 = null, doc: ?[]const u8 = null, params: []ArgSig = &.{} };

    pub fn getSignature(self: *const Obj, a: Allocator, drop_arg: i64) Allocator.Error!Signature {
        switch (self.kind) {
            .subroutine, .function => {
                var arg_sigs: std.ArrayList(ArgSig) = .empty;
                const arg_list = try str.split(a, self.args, ",");
                for (self.arg_objs.items, 0..) |arg_obj_opt, i| {
                    if (@as(i64, @intCast(i)) == drop_arg) continue;
                    if (arg_obj_opt) |arg_obj| {
                        const lname = try str.lower(a, arg_obj.name);
                        const label = if (arg_obj.isOptional()) try str.print(a, "{s}={s}", .{ lname, lname }) else lname;
                        try arg_sigs.append(a, .{ .label = label, .doc_md = try arg_obj.getHoverMd(a, false, -1) });
                    } else {
                        try arg_sigs.append(a, .{ .label = if (i < arg_list.len) arg_list[i] else "" });
                    }
                }
                const sig = try self.getSnippet(a, null, -1);
                return .{ .label = sig.call, .doc = self.getDocumentation(), .params = arg_sigs.items };
            },
            .method => {
                if (self.link_obj) |l| {
                    const sig = try self.getSnippet(a, null, -1);
                    const ls = try l.getSignature(a, self.drop_arg);
                    return .{ .label = sig.call, .doc = self.getDocumentation(), .params = ls.params };
                }
                return .{};
            },
            .intrinsic => {
                var arg_sigs: std.ArrayList(ArgSig) = .empty;
                for (try str.split(a, self.args, ",")) |arg| try arg_sigs.append(a, .{ .label = arg });
                const sig = try self.getSnippet(a, null, -1);
                return .{ .label = sig.call, .doc = self.doc_str, .params = arg_sigs.items };
            },
            else => return .{},
        }
    }

    fn getInterfaceArray(self: *const Obj, a: Allocator, keywords: []const []const u8, signature: []const u8, drop_arg: i64, change_strings: ?[2][]const u8) !?std.ArrayList([]const u8) {
        var arr: std.ArrayList([]const u8) = .empty;
        try arr.append(a, try str.concat(a, &.{ try str.join(a, " ", keywords), signature }));
        for (self.arg_objs.items, 0..) |arg_obj_opt, i| {
            const arg_obj = arg_obj_opt orelse return null;
            const h = try arg_obj.getHover(a, false, -1);
            var arg_doc = h.msg orelse "None";
            if (@as(i64, @intCast(i)) == drop_arg) {
                if (change_strings) |cs| {
                    const lower_doc = try str.lower(a, arg_doc);
                    const lower_cs = try str.lower(a, cs[0]);
                    if (std.mem.indexOf(u8, lower_doc, lower_cs)) |i_0| {
                        arg_doc = try str.concat(a, &.{ arg_doc[0..i_0], cs[1], arg_doc[i_0 + cs[0].len ..] });
                    }
                }
            }
            try arr.append(a, try str.print(a, "{s} :: {s}", .{ arg_doc, arg_obj.name }));
        }
        return arr;
    }

    pub fn getInterface(self: *const Obj, a: Allocator, name_replace: ?[]const u8, drop_arg: i64, change_strings: ?[2][]const u8) Allocator.Error!?[]const u8 {
        switch (self.kind) {
            .subroutine => {
                const sig = (try self.getSnippet(a, name_replace, -1)).call.?;
                var kw: std.ArrayList([]const u8) = .empty;
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "SUBROUTINE ");
                var arr = (try self.getInterfaceArray(a, kw.items, sig, drop_arg, change_strings)) orelse return null;
                const name = name_replace orelse self.name;
                try arr.append(a, try str.print(a, "END SUBROUTINE {s}", .{name}));
                return try str.join(a, "\n", arr.items);
            },
            .function => {
                var sig = (try self.getSnippet(a, name_replace, -1)).call.?;
                sig = try str.print(a, "{s} RESULT({s})", .{ sig, self.result_name orelse self.name });
                var kw: std.ArrayList([]const u8) = .empty;
                if (self.result_type) |rt| if (rt.len > 0) try kw.append(a, rt);
                try kw.appendSlice(a, try helpers.getKeywords(a, self.keywords.items, .{}));
                try kw.append(a, "FUNCTION ");
                var arr = (try self.getInterfaceArray(a, kw.items, sig, drop_arg, change_strings)) orelse return null;
                if (self.result_obj) |ro| {
                    const h = try ro.getHover(a, false, -1);
                    try arr.append(a, try str.print(a, "{s} :: {s}", .{ h.msg orelse "None", ro.name }));
                }
                const name = name_replace orelse self.name;
                try arr.append(a, try str.print(a, "END FUNCTION {s}", .{name}));
                return try str.join(a, "\n", arr.items);
            },
            .method => {
                if (self.link_obj) |l| return l.getInterface(a, name_replace, self.drop_arg, change_strings);
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
                if (self.inherit == null or self.inherit_version == inherit_version) return;
                self.inherit_version = inherit_version;
                self.inherit_var = try findInScope(env, self.parent, self.inherit.?, .{});
                if (self.inherit_var) |iv| {
                    // Resolve parent inheritance while avoiding circular recursion
                    self.inherit_tmp = self.inherit;
                    self.inherit = null;
                    try iv.resolveInherit(env, inherit_version);
                    self.inherit = self.inherit_tmp;
                    self.inherit_tmp = null;
                    self.in_children.clearRetainingCapacity();
                    const parent_children = try iv.getChildren(env.tmp, false);
                    for (parent_children) |child| {
                        var found = false;
                        for (self.children.items) |own| {
                            if (std.ascii.eqlIgnoreCase(own.name, child.name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) try self.in_children.append(self.al(), child);
                    }
                } else {
                    self.in_children.clearRetainingCapacity();
                }
            },
            .submodule => {
                self.ancestor_obj = null;
                if (self.ancestor_name.len == 0) return;
                if (env.tree.get(self.ancestor_name)) |e| self.ancestor_obj = e.obj;
            },
            else => {},
        }
    }

    pub fn resolveLink(self: *Obj, env: Env) Allocator.Error!void {
        switch (self.kind) {
            .variable => {
                self.link_obj = null;
                self.type_obj = null;
                const ln = self.link_name orelse return;
                if (self.parent) |p| {
                    if (try findInScope(env, p, ln, .{})) |l| self.link_obj = l;
                }
            },
            .method => {
                self.link_obj = null;
                self.type_obj = null;
                const ln = self.link_name orelse return;
                const p = self.parent orelse return;
                const link_obj = if (p.getType(false) == C.CLASS_TYPE_ID)
                    try findInScope(env, p.parent, ln, .{})
                else
                    try findInScope(env, p, ln, .{});
                if (link_obj) |l| {
                    self.link_obj = l;
                    if (self.pass_name) |pn| {
                        const pnl = try str.lower(self.al(), pn);
                        self.pass_name = pnl;
                        if (l.kind.isSubroutine()) {
                            var it = std.mem.splitScalar(u8, l.args_snip, ',');
                            var i: i64 = 0;
                            while (it.next()) |arg| : (i += 1) {
                                if (std.ascii.eqlIgnoreCase(arg, pnl)) {
                                    self.drop_arg = i;
                                    break;
                                }
                            }
                        }
                    }
                }
            },
            .interface => {
                self.mems.clearRetainingCapacity();
                const p = self.parent orelse return;
                for (self.members.items) |member| {
                    if (try findInScope(env, p, member, .{})) |m| try self.mems.append(self.al(), m);
                }
            },
            .subroutine => try self.resolveArgLink(),
            .function => {
                try self.resolveArgLink();
                const rn = self.result_name orelse self.name;
                for (self.children.items) |child| {
                    if (std.ascii.eqlIgnoreCase(child.name, rn)) {
                        self.result_obj = child;
                        self.result_name = child.name;
                        self.result_type = try child.getDesc(self.al());
                    }
                }
            },
            .submodule => try self.resolveSubmoduleLink(env),
            .associate => {
                for (self.links.items) |*assoc| {
                    assoc.var_.link_obj = null;
                    assoc.link_name = try R().PAREN_CONTENT.sub(self.al(), "", assoc.link_name);
                    const var_stack = try helpers.getVarStack(env.tmp, assoc.link_name);
                    var var_obj: ?*Obj = null;
                    if (var_stack.len > 1) {
                        const type_scope = (try climbTypeTree(env, var_stack, self)) orelse continue;
                        var_obj = try findInScope(env, type_scope, var_stack[var_stack.len - 1], .{});
                    } else {
                        var_obj = try findInScope(env, self, assoc.link_name, .{});
                    }
                    if (var_obj) |v| assoc.var_.link_obj = v;
                }
            },
            else => {},
        }
    }

    fn resolveArgLink(self: *Obj) !void {
        if (self.args.len == 0 or self.in_children.items.len > 0) return;
        const a = self.al();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const t = arena.allocator();
        const arg_list = try str.split(t, self.args, ",");
        const arg_list_lower = try str.split(t, try str.lower(t, self.args), ",");
        self.arg_objs.clearRetainingCapacity();
        try self.arg_objs.appendNTimes(a, null, arg_list.len);
        self.missing_args.clearRetainingCapacity();
        for (self.children.items) |child| {
            var ind: ?usize = null;
            const child_lower = try str.lower(t, child.name);
            for (arg_list_lower, 0..) |arg, i| {
                if (str.eql(arg, child_lower)) {
                    ind = i;
                    break;
                } else if (str.startsWith(child_lower, "#gen_int")) {
                    for (child.children.items) |sub_child| {
                        if (std.ascii.eqlIgnoreCase(arg, sub_child.name)) {
                            self.arg_objs.items[i] = sub_child;
                            break;
                        }
                    }
                }
            }
            if (ind) |i| {
                self.arg_objs.items[i] = child;
                if (child.isOptional()) arg_list[i] = try str.print(t, "{s}={s}", .{ arg_list[i], arg_list[i] });
            } else if (child.hasKeyword(KW.intent)) {
                try self.missing_args.append(a, child);
            }
        }
        const snip = try str.join(t, ",", arg_list);
        if (!str.eql(snip, self.args_snip)) self.args_snip = try a.dupe(u8, snip);
    }

    /// `Subroutine.copy_interface`; returns lowercased child names
    fn copyInterface(self: *Obj, src: *Obj) !void {
        self.linked_from_interface = true;
        self.args = src.args;
        self.args_snip = src.args_snip;
        // Python shares the list object; copy the contents
        self.arg_objs.clearRetainingCapacity();
        try self.arg_objs.appendSlice(self.al(), src.arg_objs.items);
        self.in_children.clearRetainingCapacity();
        for (src.arg_objs.items) |child_opt| {
            const child = child_opt orelse continue;
            if (!self.hasChildNamed(child.name)) try self.in_children.append(self.al(), child);
        }
        if (self.kind == .function) {
            self.result_name = src.result_name;
            self.result_type = src.result_type;
            self.result_obj = src.result_obj;
            if (src.result_obj) |ro| {
                if (!self.hasChildNamed(ro.name)) try self.in_children.append(self.al(), ro);
            }
        }
    }

    /// Drop data imported by `copyInterface` (it may reference other ASTs)
    pub fn resetInterfaceCopy(self: *Obj) void {
        self.in_children.clearRetainingCapacity();
        self.arg_objs.clearRetainingCapacity();
        if (self.result_obj) |ro| if (ro.file_ast != self.file_ast) {
            self.result_obj = null;
        };
        self.linked_from_interface = false;
    }

    fn hasChildNamed(self: *const Obj, name: []const u8) bool {
        for (self.children.items) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return true;
        return false;
    }

    fn resolveSubmoduleLink(self: *Obj, env: Env) !void {
        const anc = self.ancestor_obj orelse return;
        // Collect ancestor interface prototypes
        var interfaces: std.ArrayList(*Obj) = .empty;
        for (anc.children.items) |child| {
            if (child.getType(false) != C.INTERFACE_TYPE_ID) continue;
            for (child.children.items) |iface| {
                const it = iface.getType(false);
                if ((it == C.SUBROUTINE_TYPE_ID or it == C.FUNCTION_TYPE_ID or it == C.BASE_TYPE_ID) and iface.isModScope()) {
                    try interfaces.append(env.tmp, iface);
                }
            }
        }
        for (interfaces.items) |iface| {
            for (self.children.items) |child| {
                if (!std.ascii.eqlIgnoreCase(child.name, iface.name)) continue;
                if (child.getType(false) == C.BASE_TYPE_ID) {
                    // Convert the plain scope into a subroutine/function in place
                    if (iface.kind == .subroutine) {
                        child.kind = .subroutine;
                    } else if (iface.kind == .function) {
                        child.kind = .function;
                        child.result_name = child.name;
                        child.keyword_info = .{};
                    } else continue;
                    child.args = "";
                    child.args_snip = "";
                    child.mod_scope = false;
                }
                if (child.getType(false) == iface.getType(false)) {
                    iface.link_obj = child;
                    try iface.resolveLink(env);
                    try child.copyInterface(iface);
                    break;
                }
            }
        }
    }

    pub fn getTypeObj(self: *Obj, env: Env) !?*Obj {
        if (!self.kind.isVariable()) return null;
        if (self.link_obj) |l| return l.getTypeObj(env);
        if (self.type_obj == null) if (self.parent) |p| {
            const desc = try self.getDescNoLink(env.tmp);
            if (helpers.getParenSubstring(desc)) |tn| {
                var search_scope: ?*Obj = p;
                if (p.getType(false) == C.CLASS_TYPE_ID) search_scope = p.parent;
                if (search_scope) |ss| {
                    const type_name = try str.lower(env.tmp, str.strip(tn));
                    if (try findInScope(env, ss, type_name, .{})) |t| self.type_obj = t;
                }
            }
        };
        return self.type_obj;
    }

    pub fn getOverridden(self: *const Obj, a: Allocator, field_name: []const u8) ![]*Obj {
        var out: std.ArrayList(*Obj) = .empty;
        if (self.kind != .type) return out.items;
        for (self.children.items) |child| {
            if (std.ascii.eqlIgnoreCase(child.name, field_name)) {
                try out.append(a, child);
                break;
            }
        }
        if (self.inherit_var) |iv| try out.appendSlice(a, try iv.getOverridden(a, field_name));
        return out.items;
    }

    // ------------------------------------------------------------------
    // Diagnostics

    pub fn getDiagnostics(self: *const Obj, a: Allocator) ![]Diagnostic {
        var errors: std.ArrayList(Diagnostic) = .empty;
        switch (self.kind) {
            .type => {
                for (self.in_children.items) |in_child| {
                    if (!self.abstract and in_child.hasKeyword(KW.deferred)) {
                        var d = Diagnostic.init(self.eline - 1, try str.print(a, "Deferred procedure \"{s}\" not implemented", .{in_child.name}), 1, null);
                        d.addRelated(in_child.file_ast.path, in_child.sline - 1, "Inherited procedure declaration");
                        try errors.append(a, d);
                    }
                }
            },
            .subroutine, .function => {
                for (self.missing_args.items) |m| {
                    try errors.append(a, Diagnostic.init(
                        m.sline - 1,
                        try str.print(a, "Variable \"{s}\" with INTENT keyword not found in argument list", .{m.name}),
                        1,
                        m.name,
                    ));
                }
                const implicit_flag = self.getImplicit();
                if (implicit_flag == null or implicit_flag.?) return errors.items;
                const arg_list = try str.split(a, try str.replace(a, self.args, " ", ""), ",");
                for (self.arg_objs.items, 0..) |arg_obj, i| {
                    if (arg_obj == null) {
                        const arg_name = str.strip(if (i < arg_list.len) arg_list[i] else "");
                        try errors.append(a, Diagnostic.init(
                            self.sline - 1,
                            try str.print(a, "No matching declaration found for argument \"{s}\"", .{arg_name}),
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
        const var_type = try str.lower(a, str.strip(m.group(1).?));
        if (str.eql(var_type, "procedure")) return null;
        const desc_obj_name = try str.lower(a, str.strip(m.group(2).?));
        if (!known_types.contains(desc_obj_name)) {
            const type_def = try findInScope(env, self.parent, desc_obj_name, .{ .interface = interface });
            if (type_def) |td| {
                try known_types.put(a, desc_obj_name, .{ .kind = 0, .obj = td });
            } else {
                const type_defs = try findInWorkspace(env, desc_obj_name, true, true);
                try known_types.put(a, desc_obj_name, null);
                const filter_id = if (str.eql(var_type, "class") or str.eql(var_type, "type")) C.CLASS_TYPE_ID else C.VAR_TYPE_ID;
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
                return Diagnostic.init(self.sline - 1, try str.print(a, "Object \"{s}\" not imported in interface", .{desc_obj_name}), 1, desc_obj_name);
            }
            var d = Diagnostic.init(self.sline - 1, try str.print(a, "Object \"{s}\" not found in scope", .{desc_obj_name}), 1, desc_obj_name);
            d.addRelated(ti.obj.file_ast.path, ti.obj.sline - 1, "Possible object");
            return d;
        };
        return null;
    }

    pub fn checkDefinitions(self: *Obj, env: Env) ![]Diagnostic {
        const a = env.tmp;
        var fqsn_dict = std.array_hash_map.String(i64).empty;
        var errors: std.ArrayList(Diagnostic) = .empty;
        var known_types = KnownTypes.empty;

        for (self.children.items) |child| {
            if (child.getType(false) == C.INTERFACE_TYPE_ID) continue;
            if (fqsn_dict.get(child.fqsn)) |v| {
                if (child.sline < v) try fqsn_dict.put(a, child.fqsn, child.sline - 1);
            } else {
                try fqsn_dict.put(a, child.fqsn, child.sline - 1);
            }
        }

        var contains_line: i64 = -1;
        const st = self.getType(false);
        if (st == C.MODULE_TYPE_ID or st == C.SUBMODULE_TYPE_ID or st == C.SUBROUTINE_TYPE_ID or st == C.FUNCTION_TYPE_ID) {
            contains_line = self.contains_start orelse self.eline;
        }
        const is_interface = self.parent != null and self.parent.?.getType(false) == C.INTERFACE_TYPE_ID and !self.isModScope();

        for (self.children.items) |child| {
            if (str.startsWith(child.name, "#")) continue;
            const line_number = child.sline - 1;
            if (try child.checkDefinition(env, &known_types, is_interface)) |d| try errors.append(a, d);
            const ct = child.getType(true);
            if (contains_line >= child.sline and (ct == C.SUBROUTINE_TYPE_ID or ct == C.FUNCTION_TYPE_ID)) {
                try errors.append(a, Diagnostic.init(line_number, "Subroutine/Function definition before CONTAINS statement", 1, null));
            }
            if (st == C.INTERFACE_TYPE_ID or child.getType(false) == C.INTERFACE_TYPE_ID) continue;
            if (fqsn_dict.get(child.fqsn)) |first| if (line_number > first) {
                var d = Diagnostic.init(line_number, try str.print(a, "Variable \"{s}\" declared twice in scope", .{child.name}), 1, child.name);
                d.addRelated(self.file_ast.path, first, "First declaration");
                try errors.append(a, d);
                continue;
            };
            if (self.parent != null and (st == C.SUBROUTINE_TYPE_ID or st == C.FUNCTION_TYPE_ID or st == C.BLOCK_TYPE_ID)) {
                if (try findInScope(env, self.parent, child.name, .{})) |parent_var| {
                    if (st == C.FUNCTION_TYPE_ID and str.eql(parent_var.fqsn, self.fqsn)) continue;
                    var d = Diagnostic.init(line_number, try str.print(a, "Variable \"{s}\" masks variable in parent scope", .{child.name}), 2, child.name);
                    d.addRelated(parent_var.file_ast.path, parent_var.sline - 1, "First declaration");
                    try errors.append(a, d);
                }
            }
        }
        return errors.items;
    }

    pub fn checkUse(self: *const Obj, env: Env) ![]Diagnostic {
        const a = env.tmp;
        var errors: std.ArrayList(Diagnostic) = .empty;
        var last_use_line: i64 = -1;
        for (self.use.items) |u| {
            last_use_line = @max(last_use_line, u.line_number);
            if (u.is_import) {
                if (self.parent == null or self.parent.?.getType(false) != C.INTERFACE_TYPE_ID) {
                    try errors.append(a, Diagnostic.init(u.line_number - 1, "IMPORT statement outside of interface", 1, null));
                }
                continue;
            }
            if (!env.tree.contains(u.mod_name)) {
                try errors.append(a, Diagnostic.init(
                    u.line_number - 1,
                    try str.print(a, "Module \"{s}\" not found in project", .{u.mod_name}),
                    3,
                    u.mod_name,
                ));
            }
        }
        if (self.implicit_line) |il| if (last_use_line >= il) {
            try errors.append(a, Diagnostic.init(il - 1, "USE statements after IMPLICIT statement", 1, "IMPLICIT"));
        };
        return errors.items;
    }

    // ------------------------------------------------------------------
    // Code actions

    pub const Edit = struct { sline: i64, schar: i64, eline: i64, echar: i64, new_text: []const u8 };
    pub const Action = struct {
        title: []const u8,
        kind: []const u8,
        uri_path: []const u8,
        edits: []Edit,
        diagnostics: []Diagnostic,
    };

    fn addSubroutine(self: *const Obj, a: Allocator, interface_string: []const u8, no_contains: bool) !struct { path: ?[]const u8, edits: []Edit } {
        var edits: std.ArrayList(Edit) = .empty;
        const line_number = self.eline - 1;
        if (self.contains_start == null and !no_contains) {
            var first_sub_line = line_number;
            for (self.children.items) |child| {
                const ct = child.getType(false);
                if (ct == C.SUBROUTINE_TYPE_ID or ct == C.FUNCTION_TYPE_ID) first_sub_line = @min(first_sub_line, child.sline - 1);
            }
            try edits.append(a, .{ .sline = first_sub_line, .schar = 0, .eline = first_sub_line, .echar = 0, .new_text = "CONTAINS\n" });
        }
        try edits.append(a, .{ .sline = line_number, .schar = 0, .eline = line_number, .echar = 0, .new_text = try str.concat(a, &.{ interface_string, "\n" }) });
        return .{ .path = self.file_ast.path, .edits = edits.items };
    }

    pub fn getActions(self: *const Obj, a: Allocator, sline: i64, eline: i64) !?[]Action {
        if (self.kind != .type) return null;
        var actions: std.ArrayList(Action) = .empty;
        var edits: std.ArrayList(Edit) = .empty;
        const line_number = self.eline - 1;
        if (line_number < sline or line_number > eline) return actions.items;
        if (self.contains_start == null) {
            try edits.append(a, .{ .sline = line_number, .schar = 0, .eline = line_number, .echar = 0, .new_text = "CONTAINS\n" });
        }
        var diagnostics: std.ArrayList(Diagnostic) = .empty;
        var has_edits = false;
        for (self.in_children.items) |in_child| {
            if (!in_child.hasKeyword(KW.deferred)) continue;
            const in_parent_name = if (in_child.parent) |p| p.name else "None";
            const iface = (try in_child.getInterface(a, in_child.name, -1, .{
                try str.print(a, "class({s})", .{in_parent_name}),
                try str.print(a, "CLASS({s})", .{self.name}),
            })) orelse continue;
            const parent = self.parent orelse continue;
            const res = try parent.addSubroutine(a, iface, has_edits);
            if (!optEql(res.path, self.file_ast.path)) continue;
            try edits.append(a, .{
                .sline = line_number,
                .schar = 0,
                .eline = line_number,
                .echar = 0,
                .new_text = try str.print(a, "  PROCEDURE :: {s} => {s}\n", .{ in_child.name, in_child.name }),
            });
            try edits.appendSlice(a, res.edits);
            var d = Diagnostic.init(line_number, try str.print(a, "Deferred procedure \"{s}\" not implemented", .{in_child.name}), 1, null);
            d.addRelated(in_child.file_ast.path, in_child.sline - 1, "Inherited procedure declaration");
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
    return str.eql(a.?, b.?);
}

/// A diagnostic pending conversion into an LSP diagnostic
pub const Diagnostic = struct {
    sline: i64,
    message: []const u8,
    severity: i32 = 1,
    find_word: ?[]const u8 = null,
    related: ?Related = null,

    pub const Related = struct { path: ?[]const u8, line: i64, message: []const u8 };

    pub fn init(sline: i64, message: []const u8, severity: i32, find_word: ?[]const u8) Diagnostic {
        return .{ .sline = sline, .message = message, .severity = severity, .find_word = find_word };
    }

    pub fn addRelated(self: *Diagnostic, path: ?[]const u8, line: i64, message: []const u8) void {
        self.related = .{ .path = path, .line = line, .message = message };
    }

    pub fn build(self: Diagnostic, a: Allocator, file: *FortranFile) !BuiltDiag {
        var sline = self.sline;
        var schar: i64 = 0;
        var echar: i64 = 0;
        if (self.find_word) |w| {
            const res = try file.findWordInCodeLine(a, sline, w, true, false, false);
            sline = res.line;
            if (res.range.start >= 0) {
                schar = res.range.start;
                echar = res.range.end;
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
    sln: i64,
    sch: i64,
    eln: ?i64,
    ech: ?i64,
    message: []const u8,
    severity: i32,
    related: ?Diagnostic.Related = null,
    /// Columns are code point counts rather than byte offsets
    cols_are_codepoints: bool = false,
};

pub const IncludeInfo = struct {
    line_number: i64,
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
    pp_if: std.ArrayList([2]i64) = .empty,
    include_statements: std.ArrayList(*IncludeInfo) = .empty,
    end_errors: std.ArrayList([2]i64) = .empty,
    parse_errors: std.ArrayList(BuiltDiag) = .empty,
    inherit_objs: std.ArrayList(*Obj) = .empty,
    linkable_objs: std.ArrayList(*Obj) = .empty,
    external_objs: std.ArrayList(*Obj) = .empty,
    none_scope: ?*Obj = null,
    inc_scope: ?*Obj = null,
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
                new_scope.fqsn = try str.concat(a, &.{ self.none_scope.?.fqsn, "::", try str.lower(a, new_scope.name) });
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

    pub fn endScope(self: *Ast, line_number: i64, check: bool) void {
        if ((self.current_scope == null or self.current_scope == self.none_scope) and check) {
            self.end_errors.append(self.allocator(), .{ -1, line_number }) catch {};
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
            new_var.fqsn = try str.concat(a, &.{ self.none_scope.?.fqsn, "::", try str.lower(a, new_var.name) });
        }
        try self.current_scope.?.addChild(new_var);
        try self.variable_list.append(a, new_var);
        if (new_var.is_external) try self.external_objs.append(a, new_var);
        if (new_var.requireLink()) try self.linkable_objs.append(a, new_var);
        self.last_obj = new_var;
        if (self.pending_doc) |d| {
            new_var.addDoc(d);
            self.pending_doc = null;
        }
    }

    pub fn addIntMember(self: *Ast, key: []const u8) !void {
        const cs = self.current_scope.?;
        try cs.members.append(self.allocator(), try self.allocator().dupe(u8, key));
    }

    pub fn addPrivate(self: *Ast, name: []const u8) !void {
        try self.private_list.append(self.allocator(), try str.print(self.allocator(), "{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addPublic(self: *Ast, name: []const u8) !void {
        try self.public_list.append(self.allocator(), try str.print(self.allocator(), "{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addUse(self: *Ast, use_mod: *UseStmt) !void {
        if (self.current_scope == null) try self.createNoneScope();
        try self.current_scope.?.use.append(self.allocator(), use_mod);
    }

    pub fn addInclude(self: *Ast, path: []const u8, line_number: i64) !void {
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

    pub fn addError(self: *Ast, msg: []const u8, sev: i32, ln: i64, sch: i64, ech: ?i64) !void {
        try self.parse_errors.append(self.allocator(), .{
            .sln = ln - 1,
            .sch = sch,
            .eln = ln - 1,
            .ech = ech,
            .message = try self.allocator().dupe(u8, msg),
            .severity = sev,
        });
    }

    pub fn startPpif(self: *Ast, line_number: i64) !void {
        try self.pp_if.append(self.allocator(), .{ line_number - 1, -1 });
    }

    pub fn endPpif(self: *Ast, line_number: i64) void {
        if (self.pp_if.items.len > 0) self.pp_if.items[self.pp_if.items.len - 1][1] = line_number - 1;
    }

    /// All scopes containing the line (all scopes when null)
    pub fn getScopes(self: *Ast, a: Allocator, line_number: ?i64) ![]*Obj {
        const ln = line_number orelse return self.scope_list.items;
        var out: std.ArrayList(*Obj) = .empty;
        for (self.scope_list.items) |scope| {
            if (!(scope.sline <= ln and ln <= scope.eline)) continue;
            if (scope.parent) |p| if (p.kind == .interface) {
                for (scope.use.items) |u| {
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

    pub fn getInnerScope(self: *Ast, line_number: i64) ?*Obj {
        var scope_sline: i64 = -1;
        var curr: ?*Obj = null;
        for (self.scope_list.items) |scope| {
            if (scope.sline > scope_sline and scope.sline <= line_number and line_number <= scope.eline) {
                curr = scope;
                scope_sline = scope.sline;
            }
        }
        if (curr == null) return self.none_scope;
        return curr;
    }

    fn findChildByName(parent: *Obj, name: []const u8) ?*Obj {
        for (parent.children.items) |child| {
            if (str.eql(child.name, name)) return child;
            if (str.startsWith(child.name, "#GEN_INT")) {
                for (child.children.items) |ic| if (str.eql(ic.name, name)) return ic;
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
                if (str.eql(scope.fqsn, first)) {
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

    pub fn closeFile(self: *Ast, line_number: i64) !void {
        while (self.current_scope != null) self.endScope(line_number, false);
        if (self.none_scope) |ns| {
            ns.end(line_number);
            for (self.scope_list.items, 0..) |s, i| if (s == ns) {
                _ = self.scope_list.orderedRemove(i);
                break;
            };
        }
        for (self.private_list.items) |name| {
            if (self.getObject(name)) |o| o.vis = -1;
        }
        for (self.public_list.items) |name| {
            if (self.getObject(name)) |o| o.vis = 1;
        }
    }

    pub fn resolveLinks(self: *Ast, env: Env, link_version: i64) !void {
        for (self.inherit_objs.items) |o| try o.resolveInherit(env, link_version);
        for (self.linkable_objs.items) |o| try o.resolveLink(env);
    }

    /// Link the objects of included files into the including scopes
    pub fn resolveIncludes(self: *Ast, workspace: anytype, only_path: ?[]const u8, tmp: Allocator) !void {
        const path = self.path orelse return;
        const file_dir = std.fs.path.dirname(path) orelse "";
        for (self.include_statements.items) |inc| {
            const joined = try std.fs.path.join(tmp, &.{ file_dir, inc.path });
            const file_path = try parser.normPath(tmp, joined);
            if (only_path) |p| if (!str.eql(p, file_path)) continue;
            const parent_scope = self.getInnerScope(inc.line_number);
            const include_file = workspace.get(file_path) orelse continue;
            const include_ast = include_file.ast orelse continue;
            inc.file = include_file;
            inc.inc_obj = null;
            if (include_ast.none_scope == null) continue;
            if (include_ast.inc_scope == null) include_ast.inc_scope = include_ast.none_scope;
            // Remove old objects
            if (parent_scope) |ps| {
                for (inc.scope_objs.items) |obj| {
                    for (ps.children.items, 0..) |c, i| if (c == obj) {
                        _ = ps.children.orderedRemove(i);
                        break;
                    };
                }
            }
            inc.scope_objs.clearRetainingCapacity();
            for (include_ast.inc_scope.?.children.items) |child| {
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
            const message = if (e[0] >= 0)
                try str.print(a, "Unexpected end of scope at line {d}", .{e[0]})
            else
                "Unexpected end statement: No open scopes";
            try errors.append(a, Diagnostic.init(e[1] - 1, message, 1, null));
        }
        for (tmp_list.items) |scope| {
            if (!scope.checkValidParent()) {
                try errors.append(a, Diagnostic.init(
                    scope.sline - 1,
                    try str.print(a, "Invalid parent for \"{s}\" declaration", .{try scope.getDesc(a)}),
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

    for (curr_path) |p| if (str.eql(p, scope.fqsn)) return;
    var new_path: std.ArrayList([]const u8) = .empty;
    try new_path.appendSlice(a, curr_path);
    try new_path.append(a, scope.fqsn);

    for (scope.use.items) |use_stmnt| {
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
            if (old_len == use_dict_mod.only_list.len()) continue;
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
        const next = env.tree.get(use_stmnt.mod_name).?.obj;
        try getUseTree(env, next, use_dict, &merged_use_list, &merged_rename, new_path.items);
    }
}

pub const FindOpts = struct {
    interface: bool = false,
    local_only: bool = false,
    var_line_number: ?i64 = null,
};

fn checkScope(env: Env, local_scope: *Obj, name_lower: []const u8, filter_public: bool, var_line_number: ?i64) Allocator.Error!?*Obj {
    const children = try local_scope.getChildren(env.tmp, false);
    for (children) |child| {
        if (str.startsWith(child.name, "#GEN_INT")) {
            if (try checkScope(env, child, name_lower, filter_public, null)) |v| return v;
        }
        const is_private = child.vis < 0 or (local_scope.def_vis < 0 and child.vis <= 0);
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
    for (scope.use.items) |u| {
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
    const name_lower = try str.lower(a, var_name);
    const tmp_var = try checkScope(env, scope, name_lower, false, opts.var_line_number);
    if (opts.local_only or tmp_var != null) return tmp_var;
    // Check INCLUDE statements
    if (scope.file_ast.include_statements.items.len > 0) {
        const strip1 = try str.replace(a, var_name, "\"", "");
        const strip_str = try str.replace(a, strip1, "'", "");
        for (scope.file_ast.include_statements.items) |inc| {
            if (str.eql(strip_str, inc.path)) {
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
        const use_scope = (env.tree.get(use_mod) orelse continue).obj;
        if (str.eql(use_mod, name_lower)) return use_scope;
        if (use_info.only_list.len() > 0 and !use_info.only_list.contains(name_lower)) continue;
        const mod_name = use_info.rename_map.get(name_lower) orelse name_lower;
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
    return null;
}

pub fn findInWorkspace(env: Env, query_in: []const u8, filter_public: bool, exact_match: bool) ![]*Obj {
    const a = env.tmp;
    const query = try str.lower(a, query_in);
    var matching: std.ArrayList(*Obj) = .empty;
    var it = env.tree.iterator();
    while (it.next()) |entry| {
        const top_obj = entry.value_ptr.obj;
        if (entry.value_ptr.path == null) continue;
        if (str.containsIgnoreCase(top_obj.name, query)) try matching.append(a, top_obj);
        if (top_obj.getType(false) == C.MODULE_TYPE_ID) {
            for (try top_obj.getChildren(a, filter_public)) |child| {
                if (str.containsIgnoreCase(child.name, query)) try matching.append(a, child);
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
    const first = try str.lower(env.tmp, str.strip(var_stack[i_var]));
    var var_obj = (try findInScope(env, curr_scope, first, .{})) orelse return null;
    var n: usize = 0;
    while (n < 30) : (n += 1) {
        const type_obj = (try var_obj.getTypeObj(env)) orelse return null;
        i_var += 1;
        if (i_var == var_stack.len - 1) return type_obj;
        const name = try str.lower(env.tmp, str.strip(var_stack[i_var]));
        var_obj = (try findInScope(env, type_obj, name, .{ .local_only = true })) orelse return null;
    }
    // Python raises KeyError here
    return null;
}
