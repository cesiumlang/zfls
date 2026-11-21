//! The differences between zfls and gfortran's dump that the gfortran
//! oracle (gfortran_oracle.zig) expects, each with its reason; any other
//! fails it.

const std = @import("std");

const Known = struct {
    /// the file's name
    file: []const u8,
    /// the difference as the oracle prints it
    diff: []const u8,
    why: []const u8,
};

/// fortls's corpus (`_fortls/test/test_source`), which CI checks
const all = [_]Known{
    .{ .file = "associate_block.f90", .diff = "differs: test_associate_block::array: rank 0, gfortran 1", .why = "zfls gives an associate name the type of its selector (`ARRAY => B(:,1)`) but not its rank" },
    .{ .file = "test_kinds_and_dims.f90", .diff = "missing in zfls: character_len_parsing::int_kind_imp (variable)", .why = "zfls, as fortls (its FIXME), does not read a kind in double parentheses, `INTEGER((4))`" },
    .{ .file = "preproc_else.F90", .diff = "missing in zfls: preprocessor_else::var (variable)", .why = "a dummy argument that nothing declares: gfortran types it implicitly, zfls has no object for it" },
    .{ .file = "test_rename_intrinsic.f90", .diff = "only in zfls: test_rename_intrinsic::size (procedure)", .why = "gfortran gives a generic interface named like an intrinsic (`size`) the intrinsic's INTRINSIC-PROC, which the oracle leaves out" },
    .{ .file = "test_abstract.f90", .diff = "only in zfls: test_abstract::test (procedure)", .why = "gfortran's symbol of `PROCEDURE(abs_interface) :: test` is IFSRC-IFBODY, as interface bodies are, which the oracle leaves out" },
    .{ .file = "test_submod.F90", .diff = "missing in zfls: points_a::point_dist::distance (variable)", .why = "the result of a separate module procedure comes from its interface in the ancestor module, which zfls attaches only when linking a workspace, as `--debug_parser` does not" },
};

pub fn isKnown(file: []const u8, diff: []const u8) bool {
    for (all) |k| if (std.mem.eql(u8, k.file, file) and std.mem.eql(u8, k.diff, diff)) return true;
    return false;
}
