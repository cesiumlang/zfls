//! Port of `fortls.constants`

const std = @import("std");

pub const keyword_list = [_][]const u8{
    "pointer",
    "allocatable",
    "optional",
    "public",
    "private",
    "nopass",
    "target",
    "save",
    "parameter",
    "contiguous",
    "deferred",
    "dimension",
    "intent",
    "pass",
    "pure",
    "impure",
    "elemental",
    "recursive",
    "abstract",
    "external",
};

pub fn keywordId(name: []const u8) ?u8 {
    for (keyword_list, 0..) |k, i| {
        if (std.mem.eql(u8, k, name)) return @intCast(i);
    }
    return null;
}

pub const KW = struct {
    pub const pointer: u8 = 0;
    pub const allocatable: u8 = 1;
    pub const optional: u8 = 2;
    pub const public: u8 = 3;
    pub const private: u8 = 4;
    pub const nopass: u8 = 5;
    pub const target: u8 = 6;
    pub const save: u8 = 7;
    pub const parameter: u8 = 8;
    pub const contiguous: u8 = 9;
    pub const deferred: u8 = 10;
    pub const dimension: u8 = 11;
    pub const intent: u8 = 12;
    pub const pass: u8 = 13;
    pub const pure: u8 = 14;
    pub const impure: u8 = 15;
    pub const elemental: u8 = 16;
    pub const recursive: u8 = 17;
    pub const abstract: u8 = 18;
    pub const external: u8 = 19;
};

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
