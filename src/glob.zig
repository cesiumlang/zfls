//! Directory walking and glob resolution (ports of `resolve_globs`, and the
//! `os.walk` / `os.listdir` usage in fortls)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const paths = @import("paths.zig");

const case_insensitive = builtin.os.tag == .windows or builtin.os.tag.isDarwin();

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    is_symlink: bool,
    /// Regular file (or symlink to one), like `os.path.isfile`
    is_file: bool,
};

fn lessName(_: void, x: Entry, y: Entry) bool {
    return std.ascii.orderIgnoreCase(x.name, y.name) == .lt;
}

/// List the entries of a directory, sorted by name (case-insensitive)
pub fn listEntries(io: Io, a: Allocator, dir_path: []const u8) ![]Entry {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        var is_dir = e.kind == .directory;
        var is_file = e.kind == .file;
        const is_link = e.kind == .sym_link;
        if (is_link) {
            const full = try paths.join(a, &.{ dir_path, e.name });
            is_dir = paths.isDir(io, full);
            is_file = paths.isFile(io, full);
        }
        try out.append(a, .{ .name = try a.dupe(u8, e.name), .is_dir = is_dir, .is_symlink = is_link, .is_file = is_file });
    }
    std.mem.sort(Entry, out.items, {}, lessName);
    return out.items;
}

/// Names of the non-directory entries of a directory
pub fn listFiles(io: Io, a: Allocator, dir_path: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try listEntries(io, a, dir_path)) |e| if (!e.is_dir) try out.append(a, e.name);
    return out.items;
}

pub const WalkEntry = struct { dir: []const u8, files: []const []const u8 };

/// `os.walk(root)`: directories in top-down order with their non-directory
/// entries (symlinked directories are not descended into)
pub fn walk(io: Io, a: Allocator, root: []const u8) ![]WalkEntry {
    var out: std.ArrayList(WalkEntry) = .empty;
    try walkInto(io, a, root, &out, 0);
    return out.items;
}

/// Directories visited by `walk`
pub fn walkDirs(io: Io, a: Allocator, root: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try walk(io, a, root)) |e| try out.append(a, e.dir);
    return out.items;
}

fn walkInto(io: Io, a: Allocator, dir: []const u8, out: *std.ArrayList(WalkEntry), depth: usize) !void {
    if (depth > 256) return;
    const entries = listEntries(io, a, dir) catch {
        try out.append(a, .{ .dir = dir, .files = &.{} });
        return;
    };
    var files: std.ArrayList([]const u8) = .empty;
    for (entries) |e| if (!e.is_dir) try files.append(a, e.name);
    try out.append(a, .{ .dir = dir, .files = files.items });
    for (entries) |e| {
        if (!e.is_dir or e.is_symlink) continue;
        try walkInto(io, a, try paths.join(a, &.{ dir, e.name }), out, depth + 1);
    }
}

fn hasWildcard(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?[") != null;
}

fn chEq(x: u8, y: u8) bool {
    return if (case_insensitive) std.ascii.toLower(x) == std.ascii.toLower(y) else x == y;
}

/// `fnmatch` pattern matching (`*`, `?`, `[seq]`, `[!seq]`)
pub fn fnmatch(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pat.len) {
            const c = pat[p];
            if (c == '*') {
                star_p = p;
                star_n = n;
                p += 1;
                continue;
            }
            if (c == '?') {
                p += 1;
                n += 1;
                continue;
            }
            if (c == '[') {
                if (matchClass(pat, p, name[n])) |res| {
                    if (res.matched) {
                        p = res.next;
                        n += 1;
                        continue;
                    }
                } else if (chEq(c, name[n])) {
                    p += 1;
                    n += 1;
                    continue;
                }
            } else if (chEq(c, name[n])) {
                p += 1;
                n += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn matchClass(pat: []const u8, start: usize, c: u8) ?struct { matched: bool, next: usize } {
    var i = start + 1;
    var negate = false;
    if (i < pat.len and pat[i] == '!') {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) return .{ .matched = matched != negate, .next = i + 1 };
        first = false;
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            const lo = pat[i];
            const hi = pat[i + 2];
            const cc = if (case_insensitive) std.ascii.toLower(c) else c;
            if ((cc >= lo and cc <= hi) or (c >= lo and c <= hi)) matched = true;
            i += 3;
        } else {
            if (chEq(pat[i], c)) matched = true;
            i += 1;
        }
    }
    return null; // no closing bracket: '[' is literal
}

fn splitParts(a: Allocator, pattern: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, pattern, "/\\");
    while (it.next()) |p| {
        if (str.eql(p, ".")) continue;
        try out.append(a, p);
    }
    return out.items;
}

fn globWalk(io: Io, a: Allocator, base: []const u8, parts: []const []const u8, out: *std.ArrayList([]const u8), depth: usize) !void {
    if (depth > 512) return;
    if (parts.len == 0) {
        try out.append(a, base);
        return;
    }
    const part = parts[0];
    const rest = parts[1..];
    if (str.eql(part, "**")) {
        // `**` matches this directory and all subdirectories
        const dirs = try walkDirs(io, a, base);
        for (dirs) |d| try globWalk(io, a, d, rest, out, depth + 1);
        return;
    }
    if (str.eql(part, "..")) {
        try globWalk(io, a, paths.dirname(base), rest, out, depth + 1);
        return;
    }
    if (hasWildcard(part)) {
        const entries = listEntries(io, a, base) catch return;
        for (entries) |e| {
            if (!fnmatch(part, e.name)) continue;
            if (rest.len > 0 and !e.is_dir) continue;
            try globWalk(io, a, try paths.join(a, &.{ base, e.name }), rest, out, depth + 1);
        }
        return;
    }
    const candidate = try paths.join(a, &.{ base, part });
    if (paths.exists(io, candidate) or rest.len == 0) {
        try globWalk(io, a, candidate, rest, out, depth + 1);
    }
}

/// Resolve paths (absolute and relative) and glob patterns; nonexistent
/// paths are ignored. Returns absolute, resolved paths.
pub fn resolveGlobs(io: Io, a: Allocator, glob_path: []const u8, root_path: ?[]const u8) ![][]const u8 {
    var base: []const u8 = undefined;
    var pattern: []const u8 = undefined;
    if (!std.fs.path.isAbsolute(glob_path) and root_path != null and root_path.?.len > 0) {
        base = try paths.realpath(io, a, root_path.?);
        pattern = glob_path;
    } else {
        const abs = try paths.abspath(a, glob_path);
        // anchor: drive + root separator, or "/"
        var anchor_len: usize = 0;
        if (builtin.os.tag == .windows and abs.len >= 3 and abs[1] == ':') {
            anchor_len = 3;
        } else if (abs.len >= 2 and (abs[0] == '\\' or abs[0] == '/') and (abs[1] == '\\' or abs[1] == '/')) {
            // UNC: \\server\share\
            var seps: usize = 0;
            var k: usize = 2;
            while (k < abs.len) : (k += 1) {
                if (abs[k] == '\\' or abs[k] == '/') {
                    seps += 1;
                    if (seps == 2) break;
                }
            }
            anchor_len = @min(k + 1, abs.len);
        } else {
            anchor_len = 1;
        }
        base = abs[0..anchor_len];
        pattern = abs[anchor_len..];
    }
    var raw: std.ArrayList([]const u8) = .empty;
    try globWalk(io, a, base, try splitParts(a, pattern), &raw, 0);
    var out: std.ArrayList([]const u8) = .empty;
    for (raw.items) |p| {
        if (!paths.exists(io, p)) continue;
        const rp = try paths.realpath(io, a, p);
        var dup = false;
        for (out.items) |o| if (str.eql(o, rp)) {
            dup = true;
        };
        if (!dup) try out.append(a, rp);
    }
    return out.items;
}

test "fnmatch" {
    try std.testing.expect(fnmatch("*.f90", "a.f90"));
    try std.testing.expect(fnmatch("a?c", "abc"));
    try std.testing.expect(fnmatch("[a-c]x", "bx"));
    try std.testing.expect(!fnmatch("[!a-c]x", "bx"));
    try std.testing.expect(!fnmatch("*.f90", "a.f9"));
    try std.testing.expect(fnmatch("*", ".hidden"));
}
