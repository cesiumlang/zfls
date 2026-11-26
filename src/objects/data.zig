//! Part of the object model (objects.zig): the data of an object, by its
//! kind: a scope's, with what each kind of scope keeps, a variable's, an
//! intrinsic's.

const std = @import("std");
const C = @import("../constants.zig");
const implicit = @import("../implicit.zig");
const objects = @import("../objects.zig");
const objects_index = @import("index.zig");
const Obj = objects.Obj;
const UseStmt = objects.UseStmt;
const AssocLink = objects.AssocLink;

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
    /// Its COMMON blocks (parser/groups.zig), which are no names of it
    commons: std.ArrayList(*Obj) = .empty,
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
    /// A statement function, `f(x) = x**2` (parser/stmt_functions.zig)
    stmt_function: bool = false,
    /// Of an ENTRY (parser/entries.zig): the procedure whose ENTRY statement
    /// it is, whose variables its dummy arguments and result are
    entry_of: ?*Obj = null,
    /// The dummy arguments and results of the procedure's ENTRY statements
    /// (lowercase, comma-separated), which its summary keeps
    entry_names: []const u8 = "",
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
    /// a CHANGE TEAM construct, whose associations are its coarrays'
    change_team: bool = false,
};

pub const Select = struct {
    select_type: i32 = 0,
    binding_name: ?[]const u8 = null,
    bound_var: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,
    /// Of a case of SELECT RANK: its rank, `2` or `*` (none for RANK DEFAULT)
    case_rank: ?[]const u8 = null,
};

/// A variable, or a method (type-bound procedure or procedure pointer)
pub const Variable = struct {
    desc: []const u8 = "",
    vkind: ?[]const u8 = null,
    type_obj: ?*Obj = null,
    is_const: bool = false,
    is_external: bool = false,
    param_val: ?[]const u8 = null,
    /// For an ASSOCIATE name: the rank of what it stands for when that is not
    /// the rank of the variable it is linked to (`b(:, 1)`), or of the
    /// expression it is bound to; else -1
    slice_rank: i32 = -1,
    /// Of the associate name of a RANK (*) block: assumed size, of rank 1
    assumed_size: bool = false,
    link_name: ?[]const u8 = null,
    /// What the variable stands for: the procedure of a procedure pointer or
    /// type-bound procedure, the selector of an ASSOCIATE name
    link_obj: ?*Obj = null,
    /// Of a TYPE IS or CLASS IS name: the variable its selector names, whose
    /// rank and attributes it has; its guard gives its type (#701)
    selector_obj: ?*Obj = null,
    callable: bool = false,
    drop_arg: ?usize = null,
    pass_name: ?[]const u8 = null,
    /// A COMMON block or NAMELIST group (parser/groups.zig), not a variable
    group: Group = .none,
    /// Of a group: the names it lists, as written (`a, b(10)`)
    members: []const u8 = "",
    /// A Cray pointer or pointee (`p` and `b` of `POINTER (p, b)`)
    cray: ?Cray = null,
    /// Declared `TYPEOF(ref)` or `CLASSOF(ref)` (F2023): `(ref)`, whose
    /// type linking gives it (#728)
    type_of: ?TypeOf = null,
    /// The rank of a RANK clause (F2023) that is no literal, `rank(n)`,
    /// which linking evaluates (#729)
    rank_clause: ?[]const u8 = null,
};

pub const TypeOf = struct { ref: []const u8, class: bool };

pub const Group = enum { none, common, namelist };

/// What a Cray pointer statement makes a variable: the pointer or the
/// pointee, and the name of the other
pub const Cray = struct { role: enum { pointer, pointee }, other: []const u8 };

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
