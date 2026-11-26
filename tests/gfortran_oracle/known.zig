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

/// fortls's corpus (`_fortls/test/test_source`), which CI checks, and ours
const all = [_]Known{
    .{ .file = "preproc_else.F90", .diff = "missing in zfls: preprocessor_else::var (variable)", .why = "a dummy argument that nothing declares: gfortran types it implicitly, zfls has no object for it" },
    .{ .file = "test_rename_intrinsic.f90", .diff = "only in zfls: test_rename_intrinsic::size (procedure)", .why = "gfortran gives a generic interface named like an intrinsic (`size`) the intrinsic's INTRINSIC-PROC, which the oracle leaves out" },
    .{ .file = "test_abstract.f90", .diff = "only in zfls: test_abstract::test (procedure)", .why = "gfortran's symbol of `PROCEDURE(abs_interface) :: test` is IFSRC-IFBODY, as interface bodies are, which the oracle leaves out" },
    .{ .file = "test_submod.F90", .diff = "missing in zfls: points_a::point_dist::distance (variable)", .why = "the result of a separate module procedure comes from its interface in the ancestor module, which zfls attaches only in a workspace, not in `--debug_parser`" },
    // the corpus (tests/fortran)
    .{ .file = "f2018.f90", .diff = "missing in zfls: f2018::team_type (procedure)", .why = "the structure constructor of an intrinsic module's type by USE, which gfortran lists as a generic of the unit that uses it, without USE-ASSOC" },
};

pub fn isKnown(file: []const u8, diff: []const u8) bool {
    for (all) |k| if (std.mem.eql(u8, k.file, file) and std.mem.eql(u8, k.diff, diff)) return true;
    return false;
}
