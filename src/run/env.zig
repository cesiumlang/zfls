//! Environment variables of a build or a program: looked up by their name
//! in any case on Windows, and the additions that a build or a run makes
//! to the editor's environment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Os = std.Target.Os.Tag;

/// A variable set: its name as the environment spells it, and its value
pub const Var = struct { name: []const u8, value: []const u8 };

/// Variable `name` of `env`, in any case on Windows (also where the map is
/// not Windows's own, in tests)
pub fn lookup(env: *const Environ.Map, os: Os, name: []const u8) ?Var {
    var it = env.iterator();
    while (it.next()) |e| {
        const same = if (os == .windows) std.ascii.eqlIgnoreCase(e.key_ptr.*, name) else std.mem.eql(u8, e.key_ptr.*, name);
        if (same) return .{ .name = e.key_ptr.*, .value = e.value_ptr.* };
    }
    return null;
}

/// The name `env` spells `PATH` with (Windows's `Path` when it has none)
pub fn pathName(env: *const Environ.Map, os: Os) []const u8 {
    if (lookup(env, os, "PATH")) |v| return v.name;
    return if (os == .windows) "Path" else "PATH";
}

/// `parts` that are not empty, joined by `sep`
pub fn join(a: Allocator, sep: []const u8, parts: []const ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(a, sep);
        try out.appendSlice(a, p);
    }
    return out.items;
}

/// `PATH` with `dir` first
pub fn prependPath(a: Allocator, env: *const Environ.Map, os: Os, dir: []const u8) !Var {
    const sep = if (os == .windows) ";" else ":";
    const current = if (lookup(env, os, "PATH")) |v| v.value else null;
    return .{ .name = pathName(env, os), .value = try join(a, sep, &.{ dir, current }) };
}

/// Whether `dir` is on `PATH` already, a final separator aside (on Windows
/// without case, and `/` the same as `\`)
pub fn onPath(env: *const Environ.Map, os: Os, dir: []const u8) bool {
    const current = (lookup(env, os, "PATH") orelse return false).value;
    var it = std.mem.tokenizeScalar(u8, current, if (os == .windows) ';' else ':');
    while (it.next()) |entry| if (sameDir(os, entry, dir)) return true;
    return false;
}

fn sameDir(os: Os, x: []const u8, y: []const u8) bool {
    const seps = if (os == .windows) "\\/" else "/";
    const p = std.mem.trimEnd(u8, x, seps);
    const q = std.mem.trimEnd(u8, y, seps);
    if (os != .windows) return std.mem.eql(u8, p, q);
    if (p.len != q.len) return false;
    for (p, q) |c, d| {
        const both_seps = std.mem.findScalar(u8, seps, c) != null and std.mem.findScalar(u8, seps, d) != null;
        if (std.ascii.toLower(c) != std.ascii.toLower(d) and !both_seps) return false;
    }
    return true;
}

test "variables by name, and PATH's additions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Environ.Map = .init(a);
    try env.put("Path", "C:\\Windows");
    try std.testing.expectEqualStrings("Path", pathName(&env, .windows));
    try std.testing.expectEqualStrings("C:\\Windows", lookup(&env, .windows, "PATH").?.value);
    const p = try prependPath(a, &env, .windows, "C:\\mingw64\\bin");
    try std.testing.expectEqualStrings("Path", p.name);
    try std.testing.expectEqualStrings("C:\\mingw64\\bin;C:\\Windows", p.value);
    try std.testing.expect(onPath(&env, .windows, "c:\\windows\\"));
    try std.testing.expect(onPath(&env, .windows, "C:/Windows/"));
    try std.testing.expect(!onPath(&env, .windows, "C:\\mingw64\\bin"));
    var empty: Environ.Map = .init(a);
    try std.testing.expectEqualStrings("PATH", pathName(&empty, .linux));
    try std.testing.expectEqualStrings("/opt/bin", (try prependPath(a, &empty, .linux, "/opt/bin")).value);
    try std.testing.expectEqualStrings("a b", try join(a, " ", &.{ "a", null, "", "b" }));
}
