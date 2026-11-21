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

/// `name` in the directories of `PATH`, or itself when it is a path
pub fn onPath(a: Allocator, io: Io, env: *const Environ.Map, name: []const u8) !?[]const u8 {
    if (std.mem.findAny(u8, name, if (is_windows) "/\\" else "/") != null)
        return try inDir(a, io, env, paths.dirname(name), std.Io.Dir.path.basename(name));
    var dirs = std.mem.tokenizeScalar(u8, env.get("PATH") orelse "", std.Io.Dir.path.delimiter);
    while (dirs.next()) |dir| if (try inDir(a, io, env, dir, name)) |p| return p;
    return null;
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
