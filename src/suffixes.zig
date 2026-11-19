//! The file extensions of Fortran sources, in either letter case, and the
//! source form each names (#250). One table for the workspace scan's
//! default (`patterns.createSrcFileExtsRegex`), the form a file is read in
//! (parser.zig, format.zig), the Fortran entries of a compilation database
//! (project.zig) and the languages of the VS Code extension's package.json,
//! which `zig build generated` writes from it.

const std = @import("std");

/// The source form an extension names; `detect`: none, the text decides
pub const Form = enum { free, fixed, detect };

pub const Suffix = struct { ext: []const u8, form: Form };

pub const all = [_]Suffix{
    .{ .ext = ".f90", .form = .free },
    .{ .ext = ".f95", .form = .free },
    .{ .ext = ".f03", .form = .free },
    .{ .ext = ".f05", .form = .free },
    .{ .ext = ".f08", .form = .free },
    .{ .ext = ".f18", .form = .free },
    .{ .ext = ".f23", .form = .free },
    .{ .ext = ".fpp", .form = .detect },
    // CUDA Fortran
    .{ .ext = ".cuf", .form = .free },
    // pFUnit's tests and fypp's templates, Fortran with their directives
    .{ .ext = ".pf", .form = .free },
    .{ .ext = ".fypp", .form = .free },
    .{ .ext = ".f", .form = .fixed },
    .{ .ext = ".f77", .form = .fixed },
    .{ .ext = ".for", .form = .fixed },
    .{ .ext = ".ftn", .form = .fixed },
};

/// The entry of the extension of `path`, in any letter case
pub fn of(path: []const u8) ?Suffix {
    const ext = std.Io.Dir.path.extension(path);
    for (all) |s| if (std.ascii.eqlIgnoreCase(ext, s.ext)) return s;
    return null;
}

/// Whether `path` has the extension of a Fortran source
pub fn isFortran(path: []const u8) bool {
    return of(path) != null;
}

/// The form the extension of `path` names; null for another extension
pub fn formOf(path: []const u8) ?Form {
    return if (of(path)) |s| s.form else null;
}

/// The regular expression of the extensions, in either letter case, without
/// the end anchor: `\.([fF]90|...)`
pub const pattern: []const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var p: []const u8 = "\\.(";
    for (all, 0..) |s, i| {
        if (i > 0) p = p ++ "|";
        for (s.ext[1..]) |c| {
            p = p ++ if (std.ascii.isAlphabetic(c)) &[_]u8{ '[', c, std.ascii.toUpper(c), ']' } else &[_]u8{c};
        }
    }
    break :blk p ++ ")";
};

test "the table" {
    try std.testing.expect(isFortran("a/b.F90"));
    try std.testing.expect(isFortran("x.FtN"));
    try std.testing.expect(!isFortran("x.f2"));
    try std.testing.expect(!isFortran("x.c"));
    try std.testing.expectEqual(Form.fixed, formOf("x.FOR").?);
    try std.testing.expectEqual(Form.free, formOf("x.f23").?);
    try std.testing.expectEqual(Form.detect, formOf("x.fpp").?);
    try std.testing.expect(std.mem.startsWith(u8, pattern, "\\.([fF]90|[fF]95|"));
    try std.testing.expect(std.mem.endsWith(u8, pattern, "|[fF][tT][nN])"));
}
