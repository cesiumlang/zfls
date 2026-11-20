//! The known differences between zfls's reading of a file and LLVM Flang's,
//! each with its reason. A difference that no rule names fails the oracle,
//! and so does a rule that names no difference any more (on the default
//! files): fix the rule, or remove it with the difference.
//!
//! `file` is the file's path as the oracle prints it (`tests/flang/x.f90`,
//! `tests/flang/x.f90 > m.mod` for the module file Flang wrote of it,
//! `intrinsic > m.mod` for one of Flang's intrinsic modules), `entity` the
//! entity's path; both may have `*` for any characters.

const std = @import("std");
const Kind = @import("entities.zig").Kind;

pub const Diff = enum {
    /// Flang has it, zfls does not
    missing,
    /// zfls has it, Flang does not
    extra,
    /// both, of other kinds
    kind,
};

/// `kind`, when set, is the entity's kind: Flang's for `missing` and
/// `kind`, zfls's for `extra`
pub const Rule = struct { file: []const u8, entity: []const u8, diff: Diff, kind: ?Kind = null, why: []const u8 };

pub const rules = [_]Rule{
    // what zfls has no entity for
    .{
        .file = "*",
        .entity = "*",
        .diff = .missing,
        .kind = .common,
        .why = "zfls lists no COMMON block names (their objects are variables of the scope)",
    },
    .{
        .file = "*",
        .entity = "*",
        .diff = .missing,
        .kind = .namelist,
        .why = "zfls lists no NAMELIST group names",
    },
    .{
        .file = "*",
        .entity = "*::operator(*)",
        .diff = .missing,
        .kind = .generic,
        .why = "zfls keeps an OPERATOR interface as an interface block without a name (#gen_int)",
    },
    .{
        .file = "*",
        .entity = "*::.*.",
        .diff = .missing,
        .kind = .generic,
        .why = "zfls keeps a defined OPERATOR(.op.) interface as an interface block without a name (#gen_int)",
    },
    .{
        .file = "*",
        .entity = "*::assignment(=)",
        .diff = .missing,
        .kind = .generic,
        .why = "zfls keeps an ASSIGNMENT(=) interface as an interface block without a name (#gen_int)",
    },
    .{
        .file = "tests/flang/extensions.f90",
        .entity = "extensions::other_entry",
        .diff = .missing,
        .kind = .procedure,
        .why = "zfls declares no procedure of an ENTRY statement (in the module file Flang writes it as a procedure of its own, which zfls reads)",
    },
    // what zfls reads in another place
    .{
        .file = "tests/fortran/submodules.f90",
        .entity = "geometry_impl::translate::*",
        .diff = .missing,
        .kind = .variable,
        .why = "the dummy arguments of a MODULE PROCEDURE body are its interface's, which zfls attaches when it links a workspace; --debug_parser reads the file alone (as in the gfortran oracle)",
    },
    .{
        .file = "tests/flang/include.f90",
        .entity = "include_m::*",
        .diff = .missing,
        .kind = .variable,
        .why = "an INCLUDE file's names are its own tree's in zfls, which a workspace links into the including scope (no not-declared warnings for them); --debug_parser prints the including file's tree alone",
    },
    .{
        .file = "tests/flang/dec_structure.f90*",
        .entity = "*::inner*",
        .diff = .missing,
        .why = "a STRUCTURE nested in another declares its type in the scope for Flang, inside the outer structure for zfls",
    },
    .{
        .file = "tests/flang/dec_structure.f90",
        .entity = "use_dec::pt::inner*",
        .diff = .extra,
        .why = "a STRUCTURE nested in another declares its type in the scope for Flang, inside the outer structure for zfls",
    },
    .{
        .file = "tests/flang/dec_structure.f90 > dec_structure.mod",
        .entity = "dec_structure::move::point*",
        .diff = .missing,
        .why = "a STRUCTURE nested in another (as Flang writes `segment` in the interface of `move`) declares its type in the scope for Flang, inside the outer structure for zfls",
    },
    .{
        .file = "tests/flang/dec_structure.f90 > dec_structure.mod",
        .entity = "dec_structure::move::segment::point*",
        .diff = .extra,
        .why = "a STRUCTURE nested in another (as Flang writes `segment` in the interface of `move`) declares its type in the scope for Flang, inside the outer structure for zfls",
    },
    // what Flang reads otherwise than the compiler zfls follows
    .{
        .file = "tests/flang/intel_dir_if.f90",
        .entity = "intel_dir_if::only_if_defined",
        .diff = .missing,
        .kind = .variable,
        .why = "Flang ignores Intel's !DIR$ IF (with a warning) and compiles every branch; zfls evaluates it as ifx does",
    },
    .{
        .file = "tests/flang/preprocessor.F90",
        .entity = "preprocessor::in_flang",
        .diff = .missing,
        .kind = .variable,
        .why = "Flang predefines __flang__ (and __flang_major__, ...); zfls defines only pp_defs",
    },
    .{
        .file = "tests/flang/preprocessor.F90",
        .entity = "preprocessor::not_flang",
        .diff = .extra,
        .kind = .variable,
        .why = "Flang predefines __flang__ (and __flang_major__, ...); zfls defines only pp_defs",
    },
    .{
        .file = "tests/flang/detect.fpp",
        .entity = "detected::not_declared",
        .diff = .extra,
        .kind = .variable,
        .why = "zfls preprocesses only the upper-case suffixes by default (pp_suffixes); Flang, gfortran and ifx preprocess .fpp too",
    },
};

/// Whether `text` matches `pattern`, in which `*` is any characters
pub fn glob(pattern: []const u8, text: []const u8) bool {
    const star = std.mem.findScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, text);
    if (!std.mem.startsWith(u8, text, pattern[0..star])) return false;
    const rest = pattern[star + 1 ..];
    var i: usize = star;
    while (i <= text.len) : (i += 1) if (glob(rest, text[i..])) return true;
    return false;
}

/// The first rule for a difference, or null; `kind`: as `Rule.kind`
pub fn find(file: []const u8, entity: []const u8, diff: Diff, kind: Kind) ?usize {
    for (rules, 0..) |r, i| {
        if (r.diff != diff or !glob(r.file, file) or !glob(r.entity, entity)) continue;
        if (r.kind) |k| if (k != kind) continue;
        return i;
    }
    return null;
}

test glob {
    try std.testing.expect(glob("*", "anything"));
    try std.testing.expect(glob("tests/flang/*.f90", "tests/flang/x.f90"));
    try std.testing.expect(!glob("tests/flang/*.f90", "tests/flang/x.f90 > x.mod"));
    try std.testing.expect(glob("*::operator(*)", "m::operator(+)"));
    try std.testing.expect(glob("a*b*c", "aXbYc"));
    try std.testing.expect(!glob("a*b*c", "aXbY"));
}
