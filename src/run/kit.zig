//! Linking on Windows without Visual Studio: LLVM Flang's and LFortran's
//! programs link with lld-link and zfls's ifx kit (a startup object and
//! import libraries of Windows's C runtime) instead of Visual Studio's
//! linker and libraries. The readme's "ifx without Visual Studio" has the
//! same by hand.

const std = @import("std");
const run_env = @import("env.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const Var = run_env.Var;

/// What a build adds to link with the kit
pub const Link = struct {
    /// After the build's own arguments
    args: []const []const u8 = &.{},
    /// The build's environment beyond the editor's
    env: []const Var = &.{},
};

/// The kit's import libraries that LFortran's and LLVM Flang's programs need
const kit_libs = "msvcrt.lib ucrt.lib vcruntime.lib kernel32.lib";

/// LLVM Flang's arguments for the kit: the C runtime in DLLs (`/MD`, which
/// the kit's import libraries are; Flang's default is the static `/MT`),
/// and lld-link
pub const flang_args = [_][]const u8{ "-fms-runtime-lib=dll", "-fuse-ld=lld" };

/// The kit next to zfls: `ifx-kit` beside it (release packages), or
/// `../lib/ifx` (zig build's prefix)
pub fn find(a: Allocator, io: Io) !?[]const u8 {
    const exe_dir = std.process.executableDirPathAlloc(io, a) catch return null;
    for ([_][]const []const u8{ &.{ exe_dir, "ifx-kit" }, &.{ exe_dir, "..", "lib", "ifx" } }) |parts| {
        const dir = try std.Io.Dir.path.join(a, parts);
        const shim = try std.Io.Dir.path.join(a, &.{ dir, "zfls_ifx_shim.obj" });
        if (Io.Dir.cwd().access(io, shim, .{})) |_| return dir else |_| {}
    }
    return null;
}

/// In a Visual Studio environment, whose linker links
fn visualStudio(env: *const Environ.Map) bool {
    return run_env.lookup(env, .windows, "VCToolsInstallDir") != null;
}

/// `LIB`, the kit's directory first, and `LINK`, which lld-link reads as
/// arguments: the kit's startup object and import libraries first
fn kitVars(a: Allocator, kit_dir: []const u8, env: *const Environ.Map) ![2]Var {
    const lib = run_env.lookup(env, .windows, "LIB");
    const link = run_env.lookup(env, .windows, "LINK");
    const shim = try a.print("\"{s}\\zfls_ifx_shim.obj\"", .{kit_dir});
    return .{
        .{ .name = "LIB", .value = try run_env.join(a, ";", &.{ kit_dir, if (lib) |v| v.value else null }) },
        .{ .name = "LINK", .value = try run_env.join(a, " ", &.{ shim, kit_libs, if (link) |v| v.value else null }) },
    };
}

/// How LLVM Flang links with the kit in `kit_dir`: Flang runs lld-link
/// itself (`flang_args`), and with `LIB` set neither looks for Visual
/// Studio's libraries. Null in a Visual Studio environment, and when the
/// build's arguments (`user_args`) choose the linker or the C runtime.
pub fn flang(a: Allocator, kit_dir: []const u8, user_args: ?[]const []const u8, env: *const Environ.Map) !?Link {
    if (visualStudio(env)) return null;
    for (user_args orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "-fuse-ld=") or std.mem.startsWith(u8, arg, "-fms-runtime-lib=")) return null;
    }
    const vars = try a.dupe(Var, &try kitVars(a, kit_dir, env));
    return .{ .args = &flang_args, .env = vars };
}

/// How LFortran links with the kit in `kit_dir`: it runs `link` from the
/// `PATH`, so `link_dir`, put first, holds a `link.cmd` that runs lld-link
/// (`linkScript`). Null in a Visual Studio environment.
pub fn lfortran(a: Allocator, kit_dir: []const u8, link_dir: []const u8, env: *const Environ.Map) !?Link {
    if (visualStudio(env)) return null;
    const vars = try kitVars(a, kit_dir, env);
    return .{ .env = try a.dupe(Var, &.{ try run_env.prependPath(a, env, .windows, link_dir), vars[0], vars[1] }) };
}

/// The `link.cmd` that stands for Visual Studio's `link`: lld-link run where
/// it is, so that it finds its DLLs (a copy of conda-forge's elsewhere
/// would not)
pub fn linkScript(a: Allocator, lld_link: []const u8) ![]const u8 {
    return a.print("@\"{s}\" %*\r\n", .{lld_link});
}

const testing = std.testing;

fn expectVars(expected: []const Var, got: []const Var) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| {
        try testing.expectEqualStrings(e.name, g.name);
        try testing.expectEqualStrings(e.value, g.value);
    }
}

test "LFortran on Windows links with lld-link and the ifx kit, unless Visual Studio's environment is set up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kit = "C:\\zfls\\bin\\ifx-kit";
    var env: Environ.Map = .init(a);
    try env.put("Path", "C:\\Windows");
    try env.put("LINK", "/DEBUG");
    try expectVars(&.{
        .{ .name = "Path", .value = "C:\\store\\link;C:\\Windows" },
        .{ .name = "LIB", .value = kit },
        .{ .name = "LINK", .value = "\"C:\\zfls\\bin\\ifx-kit\\zfls_ifx_shim.obj\" msvcrt.lib ucrt.lib vcruntime.lib kernel32.lib /DEBUG" },
    }, (try lfortran(a, kit, "C:\\store\\link", &env)).?.env);
    try env.put("LIB", "C:\\sdk");
    try testing.expectEqualStrings(kit ++ ";C:\\sdk", (try lfortran(a, kit, "C:\\l", &env)).?.env[1].value);
    try env.put("VCToolsInstallDir", "C:\\VS\\MSVC\\14.4");
    try testing.expectEqual(null, try lfortran(a, kit, "C:\\l", &env));
    // `link` runs lld-link where it is
    try testing.expectEqualStrings("@\"C:\\conda\\Library\\bin\\lld-link.exe\" %*\r\n", try linkScript(a, "C:\\conda\\Library\\bin\\lld-link.exe"));
}

test "LLVM Flang on Windows links with lld-link and the ifx kit, unless Visual Studio's environment is set up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kit = "C:\\zfls\\bin\\ifx-kit";
    var env: Environ.Map = .init(a);
    try env.put("Path", "C:\\Windows");
    try env.put("LINK", "/DEBUG");
    const link = (try flang(a, kit, null, &env)).?;
    try testing.expectEqualDeep(@as([]const []const u8, &flang_args), link.args);
    try expectVars(&.{
        .{ .name = "LIB", .value = kit },
        .{ .name = "LINK", .value = "\"C:\\zfls\\bin\\ifx-kit\\zfls_ifx_shim.obj\" msvcrt.lib ucrt.lib vcruntime.lib kernel32.lib /DEBUG" },
    }, link.env);
    // the build's own choice of linker or C runtime
    try testing.expectEqual(null, try flang(a, kit, &.{ "-g", "-fuse-ld=link" }, &env));
    try testing.expectEqual(null, try flang(a, kit, &.{"-fms-runtime-lib=static"}, &env));
    try testing.expect(try flang(a, kit, &.{"-g"}, &env) != null);
    try env.put("VCToolsInstallDir", "C:\\VS\\MSVC\\14.4");
    try testing.expectEqual(null, try flang(a, kit, null, &env));
}
