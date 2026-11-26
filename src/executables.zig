//! Finding an executable: on the `PATH`, in a directory, or as a configured
//! file or directory, with Windows's `PATHEXT` extensions.

const std = @import("std");
const sysinfo = @import("builtin");
const paths = @import("paths.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const is_windows = sysinfo.target.os.tag == .windows;

/// The executable `name` in `dir`: on Windows also with the extensions of
/// `PATHEXT` (`.exe`, ...)
pub fn inDir(a: Allocator, io: Io, env: *const Environ.Map, dir: []const u8, name: []const u8) !?[]const u8 {
    const base = try paths.normpath(a, try std.Io.Dir.path.join(a, &.{ dir, name }));
    if (paths.isFile(io, base)) return base;
    if (!is_windows) return null;
    var exts = std.mem.tokenizeScalar(u8, env.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD", ';');
    while (exts.next()) |ext| {
        const p = try std.mem.concat(a, u8, &.{ base, ext });
        _ = std.ascii.lowerString(p[base.len..], ext);
        if (paths.isFile(io, p)) return p;
    }
    return null;
}

/// `name` in the directories of `PATH` (never in the working directory: a
/// relative entry, as `.`, is skipped), or itself when it is a path
pub fn onPath(a: Allocator, io: Io, env: *const Environ.Map, name: []const u8) !?[]const u8 {
    if (isPath(name)) return try inDir(a, io, env, paths.dirname(name), std.Io.Dir.path.basename(name));
    var dirs = std.mem.tokenizeScalar(u8, env.get("PATH") orelse "", std.Io.Dir.path.delimiter);
    while (dirs.next()) |dir| {
        if (!std.Io.Dir.path.isAbsolute(dir)) continue;
        if (try inDir(a, io, env, dir, name)) |p| return p;
    }
    return null;
}

/// Whether `name` has a directory part (or a drive, on Windows)
fn isPath(name: []const u8) bool {
    return std.mem.findAny(u8, name, if (is_windows) "/\\:" else "/") != null;
}

/// zfls's own environment, for `resolve` of a program that gets none
var process_env: ?*const Environ.Map = null;

/// Sets the environment `resolve` looks for programs in, at start-up
pub fn initProcessEnv(env: *const Environ.Map) void {
    process_env = env;
}

/// The program to spawn for `name`: a bare name is looked up on the PATH of
/// `env` (null: zfls's own) and given as an absolute path, so that the
/// system never looks for it in the working directory (Windows does, before
/// the PATH). A name with a directory part is left as it is.
/// `error.FileNotFound` when a bare name is on no PATH directory.
pub fn resolve(a: Allocator, io: Io, env: ?*const Environ.Map, name: []const u8) ![]const u8 {
    if (name.len == 0 or isPath(name)) return name;
    const e = env orelse process_env orelse return name;
    return try onPath(a, io, e, name) orelse error.FileNotFound;
}

/// The executable for `name`: `configured` when it is not empty (the file
/// itself, or a directory that holds `name`; relative to `base`), else
/// `name` on the `PATH`. A configured bare name not found in `base` is
/// looked up on the `PATH`.
pub fn find(a: Allocator, io: Io, env: *const Environ.Map, name: []const u8, configured: []const u8, base: ?[]const u8) !?[]const u8 {
    if (configured.len == 0) return onPath(a, io, env, name);
    const full = if (std.Io.Dir.path.isAbsolute(configured) or base == null) configured else try std.Io.Dir.path.join(a, &.{ base.?, configured });
    if (paths.isDir(io, full)) return inDir(a, io, env, full, name);
    if (try inDir(a, io, env, paths.dirname(full), std.Io.Dir.path.basename(full))) |p| return p;
    if (std.mem.findAny(u8, configured, "/\\") != null) return null;
    return onPath(a, io, env, configured);
}

test "an executable in a directory, on the PATH, or configured" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const exe_name = if (is_windows) "tool.exe" else "tool";
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/" ++ exe_name, .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const bin = try std.Io.Dir.path.join(a, &.{ root, "bin" });
    const exe = try std.Io.Dir.path.join(a, &.{ bin, exe_name });
    var env: Environ.Map = .init(a);
    try env.put("PATH", bin);
    try std.testing.expectEqualStrings(exe, (try onPath(a, io, &env, "tool")).?);
    try std.testing.expectEqual(null, try onPath(a, io, &env, "other"));
    try std.testing.expectEqualStrings(exe, (try find(a, io, &env, "tool", "bin", root)).?);
    try std.testing.expectEqualStrings(exe, (try find(a, io, &env, "x", exe, null)).?);
    // a bare name configured: from the PATH
    try std.testing.expectEqualStrings(exe, (try find(a, io, &env, "x", "tool", root)).?);
    try std.testing.expectEqual(null, try find(a, io, &env, "tool", "bin/other", root));
}

test "a bare name is resolved on the PATH, never in a relative entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const exe_name = if (is_windows) "tool.exe" else "tool";
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/" ++ exe_name, .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const bin = try std.Io.Dir.path.join(a, &.{ root, "bin" });
    var env: Environ.Map = .init(a);
    try env.put("PATH", try std.mem.concat(a, u8, &.{ ".", &.{std.Io.Dir.path.delimiter}, "bin", &.{std.Io.Dir.path.delimiter}, bin }));
    const got = try resolve(a, io, &env, "tool");
    try std.testing.expect(std.Io.Dir.path.isAbsolute(got));
    try std.testing.expectEqualStrings(try std.Io.Dir.path.join(a, &.{ bin, exe_name }), got);
    // only relative entries: not found
    try env.put("PATH", "." ++ [_]u8{std.Io.Dir.path.delimiter} ++ "bin");
    try std.testing.expectError(error.FileNotFound, resolve(a, io, &env, "tool"));
    // a path is left alone
    try std.testing.expectEqualStrings("./tool", try resolve(a, io, &env, "./tool"));
}
