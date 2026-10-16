//! Port of `fortls.constants`

const std = @import("std");

/// The keywords of declarations that objects keep, in the order fortls numbers them
pub const Kw = enum(u8) {
    pointer,
    allocatable,
    optional,
    public,
    private,
    nopass,
    target,
    save,
    parameter,
    contiguous,
    deferred,
    dimension,
    intent,
    pass,
    pure,
    impure,
    elemental,
    recursive,
    abstract,
    external,

    /// The keyword with this (lowercase) name
    pub fn fromName(name: []const u8) ?Kw {
        return std.meta.stringToEnum(Kw, name);
    }

    pub fn lessThan(_: void, x: Kw, y: Kw) bool {
        return @intFromEnum(x) < @intFromEnum(y);
    }
};

pub const KW = Kw;

/// The type id of an object, with the numbers fortls gives them
pub const TypeId = enum(i32) {
    base = -1,
    module = 1,
    subroutine = 2,
    function = 3,
    class = 4,
    interface = 5,
    variable = 6,
    method = 7,
    submodule = 8,
    block = 9,
    select = 10,
    do_ = 11,
    where = 12,
    if_ = 13,
    assoc = 14,
    enum_ = 15,

    /// Scopes that sit inside other scopes (BLOCK, SELECT, DO, ...)
    pub fn isInnerScope(self: TypeId) bool {
        return @intFromEnum(self) >= @intFromEnum(TypeId.block);
    }
};

/// fortls gives the intrinsic keyword and statement objects the ids of
/// ASSOCIATE and ENUM
pub const keyword_itype: TypeId = .assoc;
pub const statement_itype: TypeId = .enum_;

pub const Severity = struct {
    pub const err: i32 = 1;
    pub const warn: i32 = 2;
    pub const info: i32 = 3;
};

/// A string used to mark literals e.g. 10, 3.14, "words", etc.
pub const FORTRAN_LITERAL = "0^=__LITERAL_INTERNAL_DUMMY_VAR_";
