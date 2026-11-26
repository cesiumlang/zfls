//! File system access with a bound on the length of a path. A path from a
//! document, a configuration file or a URI can be of any length, and the
//! standard library converts it into a fixed buffer (32767 UTF-16 units on
//! Windows), so every path that is not zfls's own goes through here and a
//! path that is too long is a `PathTooLong` error, not a crash.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

/// The longest path (in bytes of UTF-8) that is passed on; a UTF-16 form
/// of it is never longer, and what the system adds to it fits in the rest.
pub const max_path_len = 32000;

pub const PathTooLong = error{PathTooLong};

pub fn fits(path: []const u8) bool {
    return path.len <= max_path_len;
}

pub fn check(path: []const u8) PathTooLong!void {
    if (!fits(path)) return error.PathTooLong;
}

pub const SpawnError = PathTooLong || error{ArgumentsTooLong};

/// A program, a directory or a command line that is longer than the system
/// takes is an error, not a crash: for every spawn of a program or a
/// directory that a client or a configuration names.
pub fn checkSpawn(argv: []const []const u8, cwd: ?[]const u8) SpawnError!void {
    if (argv.len > 0) try check(argv[0]);
    if (cwd) |d| try check(d);
    var total: usize = 0;
    for (argv) |arg| total += arg.len + 1;
    if (total > max_path_len) return error.ArgumentsTooLong;
}

pub fn readFile(io: Io, a: Allocator, path: []const u8, limit: Io.Limit) (PathTooLong || Dir.ReadFileAllocError)![]u8 {
    try check(path);
    return Dir.cwd().readFileAlloc(io, path, a, limit);
}

pub fn statFile(io: Io, path: []const u8) (PathTooLong || Dir.StatFileError)!Dir.Stat {
    try check(path);
    return Dir.cwd().statFile(io, path, .{});
}

pub fn openFile(io: Io, path: []const u8) (PathTooLong || Io.File.OpenError)!Io.File {
    try check(path);
    return Dir.cwd().openFile(io, path, .{});
}

pub fn openDir(io: Io, path: []const u8, options: Dir.OpenOptions) (PathTooLong || Dir.OpenError)!Dir {
    try check(path);
    return Dir.cwd().openDir(io, path, options);
}

pub fn access(io: Io, path: []const u8) (PathTooLong || Dir.AccessError)!void {
    try check(path);
    return Dir.cwd().access(io, path, .{});
}

pub fn createDirPath(io: Io, path: []const u8) (PathTooLong || Dir.CreateDirPathError)!void {
    try check(path);
    return Dir.cwd().createDirPath(io, path);
}

pub fn writeFile(io: Io, path: []const u8, data: []const u8) (PathTooLong || Dir.WriteFileError)!void {
    try check(path);
    return Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

test "a spawn of a program or a directory that is too long is an error" {
    const long = try std.testing.allocator.alloc(u8, max_path_len + 1);
    defer std.testing.allocator.free(long);
    @memset(long, 'a');
    try checkSpawn(&.{ "gfortran", "-c", "a.f90" }, "/tmp");
    try std.testing.expectError(error.PathTooLong, checkSpawn(&.{long}, null));
    try std.testing.expectError(error.PathTooLong, checkSpawn(&.{"gdb"}, long));
    try std.testing.expectError(error.ArgumentsTooLong, checkSpawn(&.{ "gdb", long[0..20000], long[0..20000] }, null));
}

test "a path that is too long is an error" {
    const long = try std.testing.allocator.alloc(u8, max_path_len + 1);
    defer std.testing.allocator.free(long);
    @memset(long, 'a');
    try std.testing.expectError(error.PathTooLong, readFile(std.testing.io, std.testing.allocator, long, .limited(1)));
    try std.testing.expectError(error.PathTooLong, statFile(std.testing.io, long));
    try std.testing.expectError(error.PathTooLong, openFile(std.testing.io, long));
    try std.testing.expectError(error.PathTooLong, openDir(std.testing.io, long, .{}));
    try std.testing.expectError(error.PathTooLong, access(std.testing.io, long));
    try std.testing.expectError(error.PathTooLong, createDirPath(std.testing.io, long));
    try std.testing.expectError(error.PathTooLong, writeFile(std.testing.io, long, ""));
    try std.testing.expectError(error.FileNotFound, statFile(std.testing.io, "no such file in zfls tests"));
}
