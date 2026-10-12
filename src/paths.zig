//! Path and URI helpers mirroring the Python `os.path` / `pathlib` calls
//! used by fortls.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");

const is_windows = builtin.os.tag == .windows;

var cwd_buf: [4096]u8 = undefined;
var cwd: []const u8 = "";

/// Cache the current working directory (call once at startup)
pub fn init(io: Io) void {
    const n = std.process.currentPath(io, &cwd_buf) catch 0;
    cwd = cwd_buf[0..n];
}

pub fn getCwd() []const u8 {
    return cwd;
}

/// `os.path.normpath`
pub fn normpath(a: Allocator, p: []const u8) ![]u8 {
    if (p.len == 0) return a.dupe(u8, ".");
    return std.fs.path.resolveAlloc(a, &.{p});
}

/// `os.path.abspath`
pub fn abspath(a: Allocator, p: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(p)) return normpath(a, p);
    if (cwd.len == 0) return normpath(a, p);
    return std.fs.path.resolveAlloc(a, &.{ cwd, p });
}

/// `os.path.join`
pub fn join(a: Allocator, parts: []const []const u8) ![]u8 {
    // Python discards everything before an absolute component
    var start: usize = 0;
    for (parts, 0..) |p, i| if (std.fs.path.isAbsolute(p)) {
        start = i;
    };
    return std.fs.path.join(a, parts[start..]);
}

/// `pathlib.Path(p).resolve()`: absolute path with symlinks resolved when
/// the path exists
pub fn realpath(io: Io, a: Allocator, p: []const u8) ![]u8 {
    const abs = try abspath(a, p);
    const rp = Io.Dir.realPathFileAbsoluteAlloc(io, abs, a) catch return abs;
    return rp[0..rp.len];
}

pub fn isFile(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .file;
}

pub fn isDir(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

pub fn exists(io: Io, p: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

/// `os.path.dirname`
pub fn dirname(p: []const u8) []const u8 {
    return std.fs.path.dirname(p) orelse "";
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '~';
}

/// `urllib.parse.quote` with the default safe character '/'
pub fn quote(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (isUnreserved(c) or c == '/') {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(a);
}

/// `urllib.parse.unquote`
pub fn unquote(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(a, s[i]);
                continue;
            };
            try out.append(a, v);
            i += 2;
        } else {
            try out.append(a, s[i]);
        }
    }
    return out.toOwnedSlice(a);
}

/// Convert file uri to path (`fortls.jsonrpc.path_from_uri`)
pub fn pathFromUri(io: Io, a: Allocator, uri: []const u8) ![]u8 {
    if (!str.startsWith(uri, "file://")) return abspath(a, uri);
    const rest = if (is_windows)
        (if (str.startsWith(uri, "file:///")) uri["file:///".len..] else uri["file://".len..])
    else
        uri["file://".len..];
    const p = try unquote(a, rest);
    return realpath(io, a, p);
}

/// Convert path to file uri (`fortls.jsonrpc.path_to_uri`)
pub fn pathToUri(a: Allocator, path: []const u8) ![]u8 {
    if (is_windows) {
        const fwd = try str.replace(a, path, "\\", "/");
        return str.concat(a, &.{ "file:///", try quote(a, fwd) });
    }
    return str.concat(a, &.{ "file://", try quote(a, path) });
}

test "uri round trip" {
    const a = std.testing.allocator;
    const q = try quote(a, "C:/a b/c.f90");
    defer a.free(q);
    try std.testing.expectEqualStrings("C%3A/a%20b/c.f90", q);
    const u = try unquote(a, q);
    defer a.free(u);
    try std.testing.expectEqualStrings("C:/a b/c.f90", u);
}
