//! The module sources a compiler ships with its `.mod` files, which zfls
//! indexes for the modules nothing else defines (server/compiler_sources.zig):
//! ifx's and ifort's `opt/compiler/include/*.f90` (`ifport`, `ifcore`,
//! `kernel32`, ..., #513), gfortran's `finclude/*.f90` (`omp_lib`,
//! `openacc`, #544).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("../paths.zig");
const tools = @import("../server/tools.zig");

/// Module names (lowercase) and the files that define them
pub const Modules = std.array_hash_map.String([]const u8);

/// The directory of the module sources of Intel's compiler at `exe` (a
/// path): `<bin>/../opt/compiler/include` (oneAPI's
/// `compiler/<version>/bin/ifx`, conda-forge's Linux `<prefix>/bin/ifx`),
/// or `<bin>/../../opt/compiler/include` (conda-forge's Windows
/// `<prefix>\Library\bin\ifx.exe`), when it has `ifcore.f90`
pub fn intelDir(io: Io, a: Allocator, exe: []const u8) !?[]const u8 {
    const bin = std.Io.Dir.path.dirname(exe) orelse return null;
    for ([_][]const u8{ "..", "../.." }) |up| {
        const dir = try std.Io.Dir.path.resolveAlloc(a, &.{ bin, up, "opt", "compiler", "include" });
        if (paths.isFile(io, try std.Io.Dir.path.join(a, &.{ dir, "ifcore.f90" }))) return dir;
    }
    return null;
}

/// The `finclude` directory of gfortran `exe`, from
/// `-print-file-name=finclude` (which prints the name alone when there is
/// none): MSYS2's gfortran 16.1 `lib/gcc/x86_64-w64-mingw32/16.1.0/finclude`
/// has `omp_lib.f90` and `openacc.f90`
pub fn gfortranDir(io: Io, a: Allocator, exe: []const u8, env: ?*const std.process.Environ.Map) ?[]const u8 {
    const r = tools.run(a, io, .{
        .argv = &.{ exe, "-print-file-name=finclude" },
        .environ_map = tools.withExeDir(a, env, exe) catch return null,
        .timeout = tools.seconds(10),
    }) catch return null;
    if (!r.term.success()) return null;
    const dir = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (!std.Io.Dir.path.isAbsolute(dir) or !paths.isDir(io, dir)) return null;
    return std.Io.Dir.path.resolveAlloc(a, &.{dir}) catch null;
}

/// Whether module `name` (lowercase) of a compiler's sources comes before
/// that of zfls's table: OpenMP's and OpenACC's, whose routines differ
/// between compilers and versions (gfortran 16's `omp_lib` has 73 the
/// table has not), but not the intrinsic modules
pub fn replacesTable(name: []const u8) bool {
    for ([_][]const u8{ "omp_lib", "omp_lib_kinds", "openacc", "openacc_kinds" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Adds to `out` (in `out_a`) the modules that the `.f90` files of `dir`
/// define; a module several files define keeps the first's
pub fn scan(io: Io, a: Allocator, out_a: Allocator, dir: []const u8, out: *Modules) !void {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".f90")) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    // the same order everywhere
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (names.items) |name| {
        const path = try std.Io.Dir.path.join(out_a, &.{ dir, name });
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 26)) catch continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const m = moduleOf(line) orelse continue;
            const gop = try out.getOrPut(out_a, try std.ascii.allocLowerString(out_a, m));
            if (!gop.found_existing) gop.value_ptr.* = path;
        }
    }
}

/// The name of the module a free-form `MODULE name` line starts (not
/// `MODULE PROCEDURE`, `MODULE FUNCTION`, `MODULE SUBROUTINE`)
fn moduleOf(line: []const u8) ?[]const u8 {
    const code = std.mem.trim(u8, line[0 .. std.mem.findScalar(u8, line, '!') orelse line.len], " \t\r");
    if (code.len < 8 or !std.ascii.startsWithIgnoreCase(code, "module") or (code[6] != ' ' and code[6] != '\t')) return null;
    const name = std.mem.trim(u8, code[7..], " \t");
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return null;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    for ([_][]const u8{ "procedure", "function", "subroutine" }) |kw| if (std.ascii.eqlIgnoreCase(name, kw)) return null;
    return name;
}

test "the module a line starts" {
    try std.testing.expectEqualStrings("IFPORT", moduleOf("      MODULE IFPORT\r").?);
    try std.testing.expectEqualStrings("ifport_types", moduleOf("module ifport_types ! the types").?);
    try std.testing.expect(moduleOf("MODULE PROCEDURE f") == null);
    try std.testing.expect(moduleOf("module procedure") == null);
    try std.testing.expect(moduleOf("end module ifport") == null);
    try std.testing.expect(moduleOf("modulex = 1") == null);
    try std.testing.expect(moduleOf("! module ifport") == null);
}
