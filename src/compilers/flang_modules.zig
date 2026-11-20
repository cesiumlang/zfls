//! LLVM Flang's intrinsic modules (`iso_fortran_env`, `ieee_arithmetic`,
//! `__fortran_type_info`, ...) where its driver does not look for them.
//! Flang 21 and later look under `<prefix>/lib/clang/<version>/finclude/flang/<triple>`,
//! with the driver's triple, but conda-forge's Flang 23 for Linux is
//! `x86_64-conda-linux-gnu` and has them under `x86_64-unknown-linux-gnu`:
//! every `use iso_fortran_env` is an error ("Cannot parse module file"),
//! and the compiler check gives it for every file that has one (#438).
//! Then the directory that has them, of the same processor, is passed with
//! `-fintrinsic-modules-path`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The driver's target and directory, from `flang --version`'s `Target:`
/// and `InstalledDir:` lines
pub const Install = struct { target: []const u8, bin: []const u8 };

pub fn parseInstall(output: []const u8) ?Install {
    var target: ?[]const u8 = null;
    var bin: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Target:")) target = std.mem.trim(u8, line["Target:".len..], " \t");
        if (std.mem.startsWith(u8, line, "InstalledDir:")) bin = std.mem.trim(u8, line["InstalledDir:".len..], " \t");
    }
    const t = target orelse return null;
    const b = bin orelse return null;
    if (t.len == 0 or b.len == 0) return null;
    return .{ .target = t, .bin = b };
}

/// The directory of the intrinsic modules to pass to the Flang that
/// `version_output` describes, or null when its driver finds them itself
/// (or none are found): under `<bin>/../lib/clang/<version>/finclude/flang`,
/// when there is no directory of the driver's target there, the one of
/// another triple of the same processor that has `iso_fortran_env.mod`
pub fn intrinsicModules(io: Io, a: Allocator, version_output: []const u8) !?[]const u8 {
    const install = parseInstall(version_output) orelse return null;
    const arch = install.target[0 .. std.mem.findScalar(u8, install.target, '-') orelse install.target.len];
    const clang = try std.Io.Dir.path.join(a, &.{ install.bin, "..", "lib", "clang" });
    var versions = Io.Dir.cwd().openDir(io, clang, .{ .iterate = true }) catch return null;
    defer versions.close(io);
    var found: ?[]const u8 = null;
    var vit = versions.iterate();
    while (try vit.next(io)) |v| {
        if (v.kind != .directory) continue;
        const flang = try std.Io.Dir.path.join(a, &.{ clang, v.name, "finclude", "flang" });
        if (hasModules(io, a, try std.Io.Dir.path.join(a, &.{ flang, install.target }))) return null;
        // the layout before the triples (Flang 20)
        if (hasModules(io, a, flang)) return null;
        var triples = Io.Dir.cwd().openDir(io, flang, .{ .iterate = true }) catch continue;
        defer triples.close(io);
        var tit = triples.iterate();
        while (try tit.next(io)) |t| {
            if (t.kind != .directory or !std.mem.startsWith(u8, t.name, arch) or !std.mem.startsWith(u8, t.name[arch.len..], "-")) continue;
            const dir = try std.Io.Dir.path.join(a, &.{ flang, t.name });
            if (found == null and hasModules(io, a, dir)) found = dir;
        }
    }
    return found;
}

fn hasModules(io: Io, a: Allocator, dir: []const u8) bool {
    const mod = std.Io.Dir.path.join(a, &.{ dir, "iso_fortran_env.mod" }) catch return false;
    Io.Dir.cwd().access(io, mod, .{}) catch return false;
    return true;
}

test "flang --version: the driver's target and directory" {
    const got = parseInstall("flang version 23.1.5 (https://github.com/conda-forge/clangdev-feedstock 30fd4e9)\nTarget: x86_64-conda-linux-gnu\nThread model: posix\nInstalledDir: /opt/flang/bin\nConfiguration file: /opt/flang/bin/x86_64-conda-linux-gnu-flang.cfg\n").?;
    try std.testing.expectEqualStrings("x86_64-conda-linux-gnu", got.target);
    try std.testing.expectEqualStrings("/opt/flang/bin", got.bin);
    const win = parseInstall("flang version 23.1.5\r\nTarget: x86_64-pc-windows-msvc\r\nThread model: posix\r\nInstalledDir: C:\\flang\\Library\\bin\r\n").?;
    try std.testing.expectEqualStrings("C:\\flang\\Library\\bin", win.bin);
    try std.testing.expect(parseInstall("flang version 23.1.5\n") == null);
}

test "the intrinsic modules of another triple, when the driver's has none" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "lib/clang/23/finclude/flang/x86_64-unknown-linux-gnu");
    try tmp.dir.createDirPath(io, "lib/clang/23/finclude/flang/aarch64-unknown-linux-gnu");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/clang/23/finclude/flang/aarch64-unknown-linux-gnu/iso_fortran_env.mod", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const bin = try std.Io.Dir.path.join(a, &.{ root, "bin" });
    const conda = try a.print("Target: x86_64-conda-linux-gnu\nInstalledDir: {s}\n", .{bin});
    // none of the same processor has them
    try std.testing.expect(try intrinsicModules(io, a, conda) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/clang/23/finclude/flang/x86_64-unknown-linux-gnu/iso_fortran_env.mod", .data = "" });
    const dir = (try intrinsicModules(io, a, conda)).?;
    try std.testing.expect(std.mem.endsWith(u8, dir, "x86_64-unknown-linux-gnu"));
    // the driver's own triple has them: nothing to pass
    try std.testing.expect(try intrinsicModules(io, a, try a.print("Target: x86_64-unknown-linux-gnu\nInstalledDir: {s}\n", .{bin})) == null);
    // no InstalledDir
    try std.testing.expect(try intrinsicModules(io, a, "Target: x86_64-conda-linux-gnu\n") == null);
}
