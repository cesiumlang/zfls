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
    codimension,

    /// The keyword with this (lowercase) name
    pub fn fromName(name: []const u8) ?Kw {
        return std.meta.stringToEnum(Kw, name);
    }

    pub fn lessThan(_: void, x: Kw, y: Kw) bool {
        return @backingInt(x) < @backingInt(y);
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
        return @backingInt(self) >= @backingInt(TypeId.block);
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
    pub const hint: i32 = 4;
};

/// The kinds of diagnostics zfls reports. Their names, with `-` for `_`, are
/// the LSP `code` of each diagnostic, and what `diagnostic_severity` and
/// `! zfls: disable=` comments name.
pub const DiagCode = enum {
    line_too_long,
    comment_too_long,
    statement_without_scope,
    multiple_contains,
    unexpected_end,
    invalid_parent,
    procedure_before_contains,
    declared_twice,
    masks_parent,
    import_outside_interface,
    module_not_found,
    use_after_implicit,
    deferred_not_implemented,
    intent_not_in_arguments,
    argument_not_declared,
    not_imported,
    object_not_found,
    undeclared_name,
    unused_name,
    circular_use,
    argument_mismatch,
    intent_in_assigned,

    /// The name of the code, `masks-parent`
    pub fn name(self: DiagCode) []const u8 {
        return names[@backingInt(self)];
    }

    pub fn fromName(s: []const u8) ?DiagCode {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @fromBackingInt(@intCast(i));
        return null;
    }

    const names = blk: {
        const fields = std.meta.fieldNames(DiagCode);
        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            var buf: [f.len]u8 = undefined;
            for (f, 0..) |c, j| buf[j] = if (c == '_') '-' else c;
            const final = buf;
            out[i] = &final;
        }
        const final = out;
        break :blk final;
    };
};

/// A string used to mark literals e.g. 10, 3.14, "words", etc.
pub const FORTRAN_LITERAL = "0^=__LITERAL_INTERNAL_DUMMY_VAR_";
