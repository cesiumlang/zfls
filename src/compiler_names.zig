//! A compiler by the name of its executable, with a version, a target or
//! an `.exe`: for the compiler check's command (server/compile_args.zig)
//! and the compiler that Run Fortran File builds with (run/).

const std = @import("std");
const compilers = @import("compilers.zig");

/// The compiler an executable is, by its name (`namesCompiler`):
/// `C:\x\ifx.exe`, `gfortran-14`, `x86_64-w64-mingw32-gfortran`, in any
/// case; null for another
pub fn idOf(exe: []const u8) ?compilers.Id {
    var buf: [128]u8 = undefined;
    const name = unversionedName(exe);
    if (name.len > buf.len) return null;
    const base = std.ascii.lowerString(&buf, name);
    for (std.enums.values(compilers.Id)) |id| {
        for (compilers.executables(id)) |n| if (namesCompiler(base, n)) return id;
    }
    return null;
}

/// The name of a compiler's executable without its directory, `.exe` and
/// version: `C:\x\flang-new-23.exe` and `flang-21` are flang-new and flang
/// (Ubuntu's and Nix's names), `gfortran-14` is gfortran
pub fn unversionedName(exe: []const u8) []const u8 {
    var base = exe[if (std.mem.findLastAny(u8, exe, "/\\")) |i| i + 1 else 0..];
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    // `-N`, `-N.N`, ...: digits and dots after the last `-`, starting and
    // ending with a digit
    const dash = std.mem.findScalarLast(u8, base, '-') orelse return base;
    const version = base[dash + 1 ..];
    if (version.len == 0 or !std.ascii.isDigit(version[0]) or !std.ascii.isDigit(version[version.len - 1])) return base;
    for (version) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return base;
    return base[0..dash];
}

/// Whether `base`, a command's compiler without its directory, `.exe` and
/// version (`unversionedName`), is the compiler `name`: also with a target
/// before it, as toolchains name theirs (MSYS2's
/// `x86_64-w64-mingw32-gfortran`, conda-forge's
/// `x86_64-conda-linux-gnu-gfortran`, Debian's `x86_64-linux-gnu-gfortran`),
/// or MacPorts' `-mp` after it (`gfortran-mp-14`)
pub fn namesCompiler(base: []const u8, name: []const u8) bool {
    const b = if (std.mem.endsWith(u8, base, "-mp")) base[0 .. base.len - 3] else base;
    if (std.mem.eql(u8, b, name)) return true;
    return b.len > name.len + 1 and std.mem.endsWith(u8, b, name) and b[b.len - name.len - 1] == '-';
}

test "a command's compiler: with a version, a target, or MacPorts' -mp" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "C:/msys64/ucrt64/bin/x86_64-w64-mingw32-gfortran.exe", "gfortran", true },
        .{ "/opt/conda/bin/x86_64-conda-linux-gnu-gfortran", "gfortran", true },
        .{ "x86_64-apple-darwin13.4.0-gfortran", "gfortran", true },
        .{ "/usr/bin/x86_64-linux-gnu-gfortran-13", "gfortran", true },
        .{ "/opt/local/bin/gfortran-mp-14", "gfortran", true },
        .{ "gfortran-14", "gfortran", true },
        .{ "gfortran", "gfortran", true },
        .{ "x86_64-conda-linux-gnu-flang-new", "flang-new", true },
        .{ "flang-new-19", "flang", false },
        .{ "mygfortran", "gfortran", false },
        .{ "-gfortran", "gfortran", false },
        .{ "gfortran-wrapper", "gfortran", false },
        .{ "x86_64-w64-mingw32-gcc", "gfortran", false },
    };
    for (cases) |c| {
        if (namesCompiler(unversionedName(c[0]), c[1]) != c[2]) {
            std.debug.print("{s} as {s}: expected {}\n", .{ c[0], c[1], c[2] });
            return error.TestUnexpectedResult;
        }
    }
}

test "a compiler's name, without its directory, .exe and version" {
    try std.testing.expectEqualStrings("flang-new", unversionedName("C:\\x\\bin\\flang-new-23.exe"));
    try std.testing.expectEqualStrings("flang-new", unversionedName("/usr/bin/flang-new-19"));
    try std.testing.expectEqualStrings("flang", unversionedName("/nix/store/x-flang-21.1.8/bin/flang-21"));
    try std.testing.expectEqualStrings("flang", unversionedName("flang-23.1.EXE"));
    try std.testing.expectEqualStrings("gfortran", unversionedName("gfortran-14"));
    try std.testing.expectEqualStrings("flang", unversionedName("C:/x/flang.exe"));
    try std.testing.expectEqualStrings("flang-new", unversionedName("flang-new"));
    // no version
    try std.testing.expectEqualStrings("flang-", unversionedName("flang-"));
    try std.testing.expectEqualStrings("flang-1.", unversionedName("flang-1."));
    try std.testing.expectEqualStrings("flang-x1", unversionedName("flang-x1"));
}

test "a compiler by its executable" {
    const cases = [_]struct { []const u8, ?compilers.Id }{
        .{ "gfortran", .gfortran },
        .{ "/usr/bin/gfortran-14", .gfortran },
        .{ "C:\\oneAPI\\bin\\ifx.exe", .ifx },
        .{ "C:\\oneAPI\\bin\\IFX.EXE", .ifx },
        .{ "flang-new-19", .flang },
        .{ "x86_64-w64-mingw32-gfortran.exe", .gfortran },
        .{ "/opt/conda/bin/x86_64-conda-linux-gnu-gfortran", .gfortran },
        .{ "/opt/local/bin/gfortran-mp-14", .gfortran },
        .{ "x86_64-conda-linux-gnu-flang-new", .flang },
        .{ "lfortran", .lfortran },
        .{ "mygfortran", null },
        .{ "mpif90", null },
    };
    for (cases) |c| try std.testing.expectEqual(c[1], idOf(c[0]));
}
