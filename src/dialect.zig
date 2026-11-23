//! The dialect zfls lints against (`lint_dialect`, else the compiler of
//! `compiler_diagnostics`): neutral checks only what gfortran, ifx and
//! LLVM Flang agree on; a compiler's dialect also applies that compiler's
//! own quirks, so that they are reported as you type.

const std = @import("std");

pub const Dialect = enum {
    neutral,
    gfortran,
    ifx,
    flang,

    /// A set of dialects: where a rule applies
    pub const Set = std.EnumSet(Dialect);

    /// The rule applies to every dialect, neutral included
    pub const all: Set = .full;

    /// The dialect of a setting's value, in any case: `neutral`, a
    /// compiler (`ifort` is Intel's, as `ifx`), or null for anything else
    pub fn fromName(name: []const u8) ?Dialect {
        const n = std.mem.trim(u8, name, " ");
        const names = [_]struct { []const u8, Dialect }{
            .{ "neutral", .neutral },
            .{ "gfortran", .gfortran },
            .{ "ifx", .ifx },
            .{ "ifort", .ifx },
            .{ "flang", .flang },
        };
        for (names) |e| if (std.ascii.eqlIgnoreCase(n, e[0])) return e[1];
        return null;
    }

    /// Whether a rule that applies to `set` applies in this dialect
    pub fn applies(self: Dialect, set: Set) bool {
        return set.contains(self);
    }
};

test "dialect names" {
    try std.testing.expectEqual(Dialect.ifx, Dialect.fromName(" IFORT ").?);
    try std.testing.expectEqual(Dialect.flang, Dialect.fromName("Flang").?);
    try std.testing.expectEqual(Dialect.neutral, Dialect.fromName("neutral").?);
    try std.testing.expect(Dialect.fromName("nvfortran") == null);
    try std.testing.expect(Dialect.fromName("") == null);
}

test "a rule's dialects" {
    const gf_only: Dialect.Set = .initOne(.gfortran);
    try std.testing.expect(Dialect.gfortran.applies(gf_only));
    try std.testing.expect(!Dialect.neutral.applies(gf_only));
    try std.testing.expect(Dialect.neutral.applies(Dialect.all));
}
