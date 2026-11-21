//! Path and URI helpers mirroring the Python `os.path` / `pathlib` calls
//! used by fortls.

const std = @import("std");
const builtin = @import("builtin");

/// Whether two paths name the same file, as the file system compares them
/// (without case on Windows)
pub fn eql(x: []const u8, y: []const u8) bool {
    return if (builtin.target.os.tag == .windows) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
}
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const win32 = @import("win32");

const is_windows = builtin.target.os.tag == .windows;

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

var cache_root: ?[]const u8 = null;

/// Find zfls's cache directory (call once at startup): `%LOCALAPPDATA%\zfls`
/// on Windows, `~/Library/Caches/zfls` on macOS, else
/// `$XDG_CACHE_HOME/zfls` or `~/.cache/zfls`
pub fn initCache(a: Allocator, env: *const std.process.Environ.Map) void {
    const tag = builtin.target.os.tag;
    const base: ?[]const u8 = if (tag == .windows)
        env.get("LOCALAPPDATA")
    else if (tag == .macos)
        (if (env.get("HOME")) |h| std.Io.Dir.path.join(a, &.{ h, "Library", "Caches" }) catch null else null)
    else if (env.get("XDG_CACHE_HOME")) |x| (if (x.len > 0) x else null) else if (env.get("HOME")) |h| std.Io.Dir.path.join(a, &.{ h, ".cache" }) catch null else null;
    const b = base orelse return;
    if (b.len == 0) return;
    cache_root = std.Io.Dir.path.join(a, &.{ b, "zfls" }) catch null;
}

/// zfls's cache directory, null when there is none (no home directory)
pub fn cacheDir() ?[]const u8 {
    return cache_root;
}

var user_config: ?[]const u8 = null;

/// Find the user's configuration file (call once at startup):
/// `%APPDATA%\zfls\config.json` on Windows, else
/// `$XDG_CONFIG_HOME/zfls/config.json` or `~/.config/zfls/config.json`.
/// It need not exist.
pub fn initUserConfig(a: Allocator, env: *const std.process.Environ.Map) void {
    const nonempty = struct {
        fn f(x: ?[]const u8) ?[]const u8 {
            const v = x orelse return null;
            return if (v.len > 0) v else null;
        }
    }.f;
    const base: ?[]const u8 = if (builtin.target.os.tag == .windows)
        nonempty(env.get("APPDATA"))
    else if (nonempty(env.get("XDG_CONFIG_HOME"))) |x| x else if (nonempty(env.get("HOME"))) |h| std.Io.Dir.path.join(a, &.{ h, ".config" }) catch null else null;
    user_config = if (base) |b| std.Io.Dir.path.join(a, &.{ b, "zfls", "config.json" }) catch null else null;
}

/// The path of the user's configuration file, null without a home
/// directory
pub fn userConfigFile() ?[]const u8 {
    return user_config;
}

/// Whether `path` is inside directory `dir`
pub fn isUnder(path: []const u8, dir: []const u8) bool {
    if (path.len <= dir.len + 1) return false;
    if (!eql(path[0..dir.len], dir)) return false;
    return std.Io.Dir.path.isSep(path[dir.len]);
}

/// `os.path.normpath`
pub fn normpath(a: Allocator, p: []const u8) ![]u8 {
    if (p.len == 0) return a.dupe(u8, ".");
    return std.Io.Dir.path.resolveAlloc(a, &.{p});
}

/// `os.path.abspath`
pub fn abspath(a: Allocator, p: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(p)) return normpath(a, p);
    if (cwd.len == 0) return normpath(a, p);
    return std.Io.Dir.path.resolveAlloc(a, &.{ cwd, p });
}

/// `os.path.join`
pub fn join(a: Allocator, parts: []const []const u8) ![]u8 {
    // Python discards everything before an absolute component
    var start: usize = 0;
    for (parts, 0..) |p, i| if (std.Io.Dir.path.isAbsolute(p)) {
        start = i;
    };
    return std.Io.Dir.path.join(a, parts[start..]);
}

/// `pathlib.Path(p).resolve()`: absolute path with symlinks resolved when
/// the path exists
pub fn realpath(io: Io, a: Allocator, p: []const u8) ![]u8 {
    const abs = try abspath(a, p);
    const rp = Io.Dir.realPathFileAbsoluteAlloc(io, abs, a) catch return abs;
    return rp[0..rp.len];
}

/// On Windows, the long form of a path that has 8.3 short names in it
/// (`C:\Users\EMANSP~1\x`, as `%TEMP%` gives it), as the file system and
/// compilers' debug information name it; `p` itself otherwise, also when
/// it does not exist. Takes `p`, allocated with `a`.
pub fn longName(a: Allocator, p: []u8) ![]u8 {
    if (!is_windows) return p;
    if (std.mem.findScalar(u8, p, '~') == null) return p;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(a, p) catch return p;
    defer a.free(wide);
    // the length it needs (with the terminating 0), then the path
    const need = win32.kernel32.GetLongPathNameW(wide.ptr, null, 0);
    if (need == 0) return p;
    const buf = try a.allocSentinel(u16, need, 0);
    defer a.free(buf);
    const n = win32.kernel32.GetLongPathNameW(wide.ptr, buf.ptr, need + 1);
    if (n == 0 or n > need) return p;
    const long = try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]);
    a.free(p);
    return long;
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
    return std.Io.Dir.path.dirname(p) orelse "";
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

/// Whether `s` is a URI of a document that is not a file (`untitled:...`),
/// which zfls uses as the document's path. A scheme has two or more
/// characters, so a Windows path (`C:...`) is not one.
pub fn isVirtualUri(s: []const u8) bool {
    const colon = std.mem.findScalar(u8, s, ':') orelse return false;
    if (colon < 2 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[0..colon]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    return !std.mem.startsWith(u8, s, "file:");
}

/// Convert file uri to path (`fortls.jsonrpc.path_from_uri`); the URI of a
/// document that is not a file is its own path
pub fn pathFromUri(io: Io, a: Allocator, uri: []const u8) ![]u8 {
    if (isVirtualUri(uri)) return a.dupe(u8, uri);
    if (!std.mem.startsWith(u8, uri, "file://")) return longName(a, try abspath(a, uri));
    const p = try uriPath(a, uri["file://".len..], is_windows);
    return longName(a, try realpath(io, a, p));
}

fn isDriveAt(s: []const u8, at: usize) bool {
    return s.len >= at + 2 and std.ascii.isAlphabetic(s[at]) and s[at + 1] == ':';
}

/// The path that a `file://` URI names, from what follows `file://`. On
/// Windows:
///
/// - `/C:/dir/x` (no host) is `C:/dir/x`;
/// - `host/share/dir/x` is the UNC path `\\host\share\dir\x`: a network
///   share, `\\wsl.localhost\...`, `\\localhost\c$\...`;
/// - so are the forms with the host in the path, `//host/share/x` and
///   `///host/share/x` (`file:////host/...`, `file://///host/...`);
/// - `localhost/C:/dir/x` is `C:/dir/x`, this machine's.
fn uriPath(a: Allocator, rest: []const u8, windows: bool) ![]u8 {
    const p = try unquote(a, rest);
    if (!windows) return p;
    defer a.free(p);
    const unc_prefix = "\\\\";
    if (p.len == 0 or isDriveAt(p, 0)) return a.dupe(u8, p);
    if (p[0] != '/') {
        const slash = std.mem.findScalar(u8, p, '/') orelse p.len;
        if (std.ascii.eqlIgnoreCase(p[0..slash], "localhost") and isDriveAt(p, slash + 1)) return a.dupe(u8, p[slash + 1 ..]);
        return std.mem.concat(a, u8, &.{ unc_prefix, p });
    }
    const body = std.mem.trimStart(u8, p, "/");
    if (p.len - body.len >= 2 and body.len > 0) return std.mem.concat(a, u8, &.{ unc_prefix, body });
    return a.dupe(u8, body);
}

/// Convert path to file uri (`fortls.jsonrpc.path_to_uri`); the path of a
/// document that is not a file is its URI
pub fn pathToUri(a: Allocator, path: []const u8) ![]u8 {
    if (isVirtualUri(path)) return a.dupe(u8, path);
    return fileUri(a, path, is_windows);
}

/// The `file://` URI of a path. On Windows a UNC path `\\host\share\x` has
/// its host as the URI's: `file://host/share/x`, as editors write it.
fn fileUri(a: Allocator, path: []const u8, windows: bool) ![]u8 {
    if (!windows) {
        const q = try quote(a, path);
        defer a.free(q);
        return std.mem.concat(a, u8, &.{ "file://", q });
    }
    const fwd = try std.mem.replaceOwned(u8, a, path, "\\", "/");
    defer a.free(fwd);
    // the forms that switch path parsing off: `\\?\C:\x`, `\\?\UNC\host\share\x`
    var p: []const u8 = fwd;
    var unc = false;
    if (std.mem.startsWith(u8, p, "//?/")) {
        p = p["//?/".len..];
        if (std.ascii.startsWithIgnoreCase(p, "UNC/")) {
            p = p["UNC/".len..];
            unc = true;
        }
    } else if (std.mem.startsWith(u8, p, "//") and p.len > 2 and p[2] != '/') {
        p = p[2..];
        unc = true;
    }
    const q = try quote(a, p);
    defer a.free(q);
    return std.mem.concat(a, u8, &.{ if (unc) "file://" else "file:///", q });
}

test "the paths of file URIs" {
    const a = std.testing.allocator;
    const cases = [_]struct { windows: bool, uri_rest: []const u8, path: []const u8 }{
        .{ .windows = false, .uri_rest = "/home/u/a%20b/c.f90", .path = "/home/u/a b/c.f90" },
        .{ .windows = true, .uri_rest = "/c%3A/dir/a%20b/c.f90", .path = "c:/dir/a b/c.f90" },
        .{ .windows = true, .uri_rest = "/C:/dir/c.f90", .path = "C:/dir/c.f90" },
        .{ .windows = true, .uri_rest = "C:/dir/c.f90", .path = "C:/dir/c.f90" },
        .{ .windows = true, .uri_rest = "localhost/C:/dir/c.f90", .path = "C:/dir/c.f90" },
        // UNC paths: a share, an administrative share, WSL
        .{ .windows = true, .uri_rest = "server/share/a%20b/c.f90", .path = "\\\\server/share/a b/c.f90" },
        .{ .windows = true, .uri_rest = "localhost/c%24/dir/c.f90", .path = "\\\\localhost/c$/dir/c.f90" },
        .{ .windows = true, .uri_rest = "wsl.localhost/Ubuntu/home/u/c.f90", .path = "\\\\wsl.localhost/Ubuntu/home/u/c.f90" },
        .{ .windows = true, .uri_rest = "//server/share/c.f90", .path = "\\\\server/share/c.f90" },
        .{ .windows = true, .uri_rest = "///server/share/c.f90", .path = "\\\\server/share/c.f90" },
    };
    for (cases) |c| {
        const p = try uriPath(a, c.uri_rest, c.windows);
        defer a.free(p);
        try std.testing.expectEqualStrings(c.path, p);
    }
}

test "the file URIs of paths" {
    const a = std.testing.allocator;
    const cases = [_]struct { windows: bool, path: []const u8, uri: []const u8 }{
        .{ .windows = false, .path = "/home/u/a b/c.f90", .uri = "file:///home/u/a%20b/c.f90" },
        .{ .windows = true, .path = "C:\\dir\\a b\\c.f90", .uri = "file:///C%3A/dir/a%20b/c.f90" },
        .{ .windows = true, .path = "\\\\server\\share\\a b\\c.f90", .uri = "file://server/share/a%20b/c.f90" },
        .{ .windows = true, .path = "//server/share/c.f90", .uri = "file://server/share/c.f90" },
        .{ .windows = true, .path = "\\\\localhost\\c$\\dir\\c.f90", .uri = "file://localhost/c%24/dir/c.f90" },
        .{ .windows = true, .path = "\\\\?\\UNC\\server\\share\\c.f90", .uri = "file://server/share/c.f90" },
        .{ .windows = true, .path = "\\\\?\\C:\\dir\\c.f90", .uri = "file:///C%3A/dir/c.f90" },
    };
    for (cases) |c| {
        const uri = try fileUri(a, c.path, c.windows);
        defer a.free(uri);
        try std.testing.expectEqualStrings(c.uri, uri);
    }
}

test "a UNC path and its URI, there and back" {
    if (!is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // nothing is there: the path is taken as it is written
    const path = try pathFromUri(std.testing.io, a, "file://zfls-no-such-host.invalid/share/a%20b/c.f90");
    try std.testing.expectEqualStrings("\\\\zfls-no-such-host.invalid\\share\\a b\\c.f90", path);
    try std.testing.expectEqualStrings("file://zfls-no-such-host.invalid/share/a%20b/c.f90", try pathToUri(a, path));
}

test "documents that are not files" {
    try std.testing.expect(isVirtualUri("untitled:Untitled-1"));
    try std.testing.expect(isVirtualUri("vscode-notebook-cell:/a#b"));
    try std.testing.expect(!isVirtualUri("C:\\a\\b.f90"));
    try std.testing.expect(!isVirtualUri("/a/b.f90"));
    try std.testing.expect(!isVirtualUri("file:///a/b.f90"));
    try std.testing.expect(!isVirtualUri("relative/b.f90"));
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

/// The 8.3 short form of an existing path (Windows), or null where the
/// volume makes no short names
pub fn shortName(a: Allocator, p: []const u8) !?[]u8 {
    if (!is_windows) return null;
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(a, p);
    defer a.free(wide);
    const need = win32.kernel32.GetShortPathNameW(wide.ptr, null, 0);
    if (need == 0) return null;
    const buf = try a.allocSentinel(u16, need, 0);
    defer a.free(buf);
    const n = win32.kernel32.GetShortPathNameW(wide.ptr, buf.ptr, need + 1);
    if (n == 0 or n > need) return null;
    const short = try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]);
    if (std.mem.findScalar(u8, short, '~') == null) {
        a.free(short);
        return null;
    }
    return short;
}

test "a path by its 8.3 short name, as its long one" {
    if (!is_windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "a long directory name/source file.f90");
    const long = try tmp.dir.realPathFileAlloc(io, "a long directory name/source file.f90", a);
    const short = try shortName(a, long) orelse return error.SkipZigTest;
    try std.testing.expect(!std.mem.eql(u8, short, long));
    try std.testing.expectEqualStrings(long, try longName(a, short));
    // a name that does not exist, and one without a short name, unchanged
    try std.testing.expectEqualStrings("C:\\NO~1\\x.f90", try longName(a, try a.dupe(u8, "C:\\NO~1\\x.f90")));
    try std.testing.expectEqualStrings(long, try longName(a, try a.dupe(u8, long)));
}
