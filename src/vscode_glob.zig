//! VS Code's glob patterns as `files.associations` matches them (#686):
//! a pattern with a `/` against the whole path, one without against the
//! file name, ignoring case; `*` and `?` within a path segment, `**` a
//! segment of any number of segments, `{a,b}` alternatives, `[a-z]` and
//! `[!a-z]` (or `[^a-z]`) classes; `/` matches either separator.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Whether `pattern` matches the file `path`, as VS Code matches a
/// `files.associations` pattern
pub fn matchesFile(a: Allocator, pattern: []const u8, path: []const u8) Allocator.Error!bool {
    const target = if (std.mem.findScalar(u8, pattern, '/') != null) path else basename(path);
    return matches(a, pattern, target);
}

/// Whether `pattern` matches all of `s`
pub fn matches(a: Allocator, pattern: []const u8, s: []const u8) Allocator.Error!bool {
    const open = std.mem.findScalar(u8, pattern, '{') orelse return core(pattern, s, true);
    const close = closing(pattern, open) orelse return core(pattern, s, true);
    var alts = std.mem.splitScalar(u8, pattern[open + 1 .. close], ',');
    while (alts.next()) |alt| {
        const one = try std.mem.concat(a, u8, &.{ pattern[0..open], alt, pattern[close + 1 ..] });
        defer a.free(one);
        if (try matches(a, one, s)) return true;
    }
    return false;
}

/// The `}` that closes the `{` at `open`, past nested groups
fn closing(pattern: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (pattern[open..], open..) |c, i| switch (c) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0 and !isSep(path[i - 1])) i -= 1;
    return path[i..];
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn same(x: u8, y: u8) bool {
    return std.ascii.toLower(x) == std.ascii.toLower(y) or (isSep(x) and isSep(y));
}

/// A pattern without braces; `seg`: `p` starts a path segment
fn core(p: []const u8, s: []const u8, seg: bool) bool {
    if (p.len == 0) return s.len == 0;
    if (seg and std.mem.startsWith(u8, p, "**") and (p.len == 2 or isSep(p[2]))) {
        if (p.len == 2) return true;
        // any number of whole segments
        var k: usize = 0;
        while (true) {
            if (core(p[3..], s[k..], true)) return true;
            const next = std.mem.findAnyPos(u8, s, k, "/\\") orelse return false;
            k = next + 1;
        }
    }
    switch (p[0]) {
        '*' => {
            var k: usize = 0;
            while (true) : (k += 1) {
                if (core(p[1..], s[k..], false)) return true;
                if (k == s.len or isSep(s[k])) return false;
            }
        },
        '?' => return s.len > 0 and !isSep(s[0]) and core(p[1..], s[1..], false),
        '[' => if (class(p, if (s.len > 0) s[0] else null)) |c| {
            return c.matched and core(p[c.next..], s[1..], false);
        },
        else => {},
    }
    return s.len > 0 and same(p[0], s[0]) and core(p[1..], s[1..], isSep(p[0]));
}

/// The class at the start of `p` against `c`; null when it is not closed
/// (a plain `[`)
fn class(p: []const u8, c: ?u8) ?struct { matched: bool, next: usize } {
    var i: usize = 1;
    const negate = i < p.len and (p[i] == '!' or p[i] == '^');
    if (negate) i += 1;
    const start = i;
    var matched = false;
    while (i < p.len) {
        if (p[i] == ']' and i > start) {
            const ch = c orelse return .{ .matched = false, .next = i + 1 };
            return .{ .matched = !isSep(ch) and matched != negate, .next = i + 1 };
        }
        const lo = std.ascii.toLower(p[i]);
        const hi, const width: usize = if (i + 2 < p.len and p[i + 1] == '-' and p[i + 2] != ']') .{ std.ascii.toLower(p[i + 2]), 3 } else .{ lo, 1 };
        if (c) |ch| {
            const x = std.ascii.toLower(ch);
            if (x >= lo and x <= hi) matched = true;
        }
        i += width;
    }
    return null;
}

const testing = std.testing;

fn expectMatch(pattern: []const u8, path: []const u8, want: bool) !void {
    try testing.expectEqual(want, try matchesFile(testing.allocator, pattern, path));
}

test "a pattern without a slash matches the file name, ignoring case" {
    try expectMatch("*.fpp", "/w/src/a.fpp", true);
    try expectMatch("*.fpp", "C:\\w\\src\\A.FPP", true);
    try expectMatch("a.fpp", "/w/src/a.fpp", true);
    try expectMatch("*.fpp", "/w/src/a.f90", false);
    try expectMatch("?.fpp", "/w/ab.fpp", false);
    try expectMatch("[a-c]*.fpp", "/w/Beta.fpp", true);
    try expectMatch("[!a-c]*.fpp", "/w/beta.fpp", false);
    try expectMatch("*.{fpp,FOR}", "/w/x.for", true);
}

test "a pattern with a slash matches the whole path" {
    try expectMatch("**/legacy/*.fpp", "/w/legacy/a.fpp", true);
    try expectMatch("**/legacy/*.fpp", "C:\\w\\Legacy\\a.fpp", true);
    try expectMatch("**/legacy/*.fpp", "/w/legacy/sub/a.fpp", false);
    try expectMatch("**/legacy/**/*.fpp", "/w/legacy/sub/a.fpp", true);
    try expectMatch("**/legacy/**/*.fpp", "/w/legacy/a.fpp", true);
    // relative to nothing: the absolute path does not start with it
    try expectMatch("legacy/*.fpp", "/w/legacy/a.fpp", false);
    try expectMatch("/w/legacy/*.fpp", "/w/legacy/a.fpp", true);
    try expectMatch("**/*.fpp", "/w/a.fpp", true);
    try expectMatch("/w/**", "/w/x/y.fpp", true);
    try expectMatch("**/{old,legacy}/*.fpp", "/w/old/a.fpp", true);
}
