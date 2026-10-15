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

// Type identifiers
pub const BASE_TYPE_ID: i32 = -1;
pub const MODULE_TYPE_ID: i32 = 1;
pub const SUBROUTINE_TYPE_ID: i32 = 2;
pub const FUNCTION_TYPE_ID: i32 = 3;
pub const CLASS_TYPE_ID: i32 = 4;
pub const INTERFACE_TYPE_ID: i32 = 5;
pub const VAR_TYPE_ID: i32 = 6;
pub const METH_TYPE_ID: i32 = 7;
pub const SUBMODULE_TYPE_ID: i32 = 8;
pub const BLOCK_TYPE_ID: i32 = 9;
pub const SELECT_TYPE_ID: i32 = 10;
pub const DO_TYPE_ID: i32 = 11;
pub const WHERE_TYPE_ID: i32 = 12;
pub const IF_TYPE_ID: i32 = 13;
pub const ASSOC_TYPE_ID: i32 = 14;
pub const ENUM_TYPE_ID: i32 = 15;

pub const Severity = struct {
    pub const err: i32 = 1;
    pub const warn: i32 = 2;
    pub const info: i32 = 3;
};

/// A string used to mark literals e.g. 10, 3.14, "words", etc.
pub const FORTRAN_LITERAL = "0^=__LITERAL_INTERNAL_DUMMY_VAR_";
