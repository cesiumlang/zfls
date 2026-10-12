//! Python-like string helpers operating on byte slices

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const whitespace = " \t\n\r\x0b\x0c";

pub fn strip(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, whitespace);
}

pub fn lstrip(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, whitespace);
}

pub fn rstrip(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, whitespace);
}

pub fn lower(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

pub fn upper(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

pub fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

pub fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Python `str.find`: index or -1
pub fn find(s: []const u8, needle: []const u8) isize {
    const i = std.mem.indexOf(u8, s, needle) orelse return -1;
    return @intCast(i);
}

pub fn findChar(s: []const u8, c: u8) isize {
    const i = std.mem.indexOfScalar(u8, s, c) orelse return -1;
    return @intCast(i);
}

pub fn rfind(s: []const u8, needle: []const u8) isize {
    const i = std.mem.lastIndexOf(u8, s, needle) orelse return -1;
    return @intCast(i);
}

pub fn contains(s: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, s, needle) != null;
}

/// Python `a.lower().find(b.lower()) >= 0`
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn count(s: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, s, needle);
}

/// Python `s.split(sep)[0]`
pub fn beforeFirst(s: []const u8, sep: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, s, sep) orelse return s;
    return s[0..i];
}

/// Python `s.split(sep)` (sep non-empty)
pub fn split(a: Allocator, s: []const u8, sep: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |p| try out.append(a, p);
    return out.toOwnedSlice(a);
}

/// Python `s.split()` (whitespace, no empty parts)
pub fn splitWhitespace(a: Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, whitespace);
    while (it.next()) |p| try out.append(a, p);
    return out.toOwnedSlice(a);
}

pub fn join(a: Allocator, sep: []const u8, parts: []const []const u8) ![]u8 {
    return std.mem.join(a, sep, parts);
}

pub fn concat(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}

/// Python `s.replace(old, new)` (all occurrences)
pub fn replace(a: Allocator, s: []const u8, old: []const u8, new: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, s, old, new);
}

/// Python `s.replace(old, new, 1)`
pub fn replaceFirst(a: Allocator, s: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return concat(a, &.{ new, s });
    const i = std.mem.indexOf(u8, s, old) orelse return a.dupe(u8, s);
    return concat(a, &.{ s[0..i], new, s[i + old.len ..] });
}

pub fn dupe(a: Allocator, s: []const u8) ![]u8 {
    return a.dupe(u8, s);
}

pub fn dupeOpt(a: Allocator, s: ?[]const u8) !?[]u8 {
    return if (s) |v| try a.dupe(u8, v) else null;
}

pub fn print(a: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(a, fmt, args);
}

pub fn spaces(a: Allocator, n: usize) ![]u8 {
    const out = try a.alloc(u8, n);
    @memset(out, ' ');
    return out;
}

pub fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Slice `s[start..end]` with Python clamping semantics for possibly
/// negative or out-of-range indices.
pub fn slice(s: []const u8, start: isize, end: isize) []const u8 {
    const n: isize = @intCast(s.len);
    var b = if (start < 0) @max(n + start, 0) else @min(start, n);
    var e = if (end < 0) @max(n + end, 0) else @min(end, n);
    if (e < b) e = b;
    b = @max(b, 0);
    return s[@intCast(b)..@intCast(e)];
}

/// `s[start:]` with clamping
pub fn from(s: []const u8, start: usize) []const u8 {
    return if (start >= s.len) s[s.len..] else s[start..];
}

/// `s[:end]` with clamping
pub fn upto(s: []const u8, end: usize) []const u8 {
    return if (end >= s.len) s else s[0..end];
}

/// Number of Unicode code points in UTF-8 text (invalid bytes count as one)
pub fn codepointLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Convert a UTF-16 code unit offset into a byte offset within `line`.
/// Offsets past the end of the line map past the end (by the excess amount).
pub fn utf16ToByte(line: []const u8, col: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (units >= col) return i;
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        if (i + len > line.len) {
            units += 1;
            i += 1;
            continue;
        }
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return line.len + (col -| units);
}

/// Convert a byte offset within `line` into UTF-16 code units.
pub fn byteToUtf16(line: []const u8, off: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    const lim = @min(off, line.len);
    while (i < lim) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return units + (off -| line.len);
}

test "slicing helpers" {
    try std.testing.expectEqualStrings("bc", slice("abcd", 1, 3));
    try std.testing.expectEqualStrings("abc", slice("abcd", 0, -1));
    try std.testing.expectEqualStrings("", slice("abcd", 3, 1));
    try std.testing.expectEqual(@as(usize, 3), utf16ToByte("abc", 3));
    try std.testing.expectEqual(@as(usize, 3), utf16ToByte("é1", 2));
    try std.testing.expectEqual(@as(usize, 2), byteToUtf16("é1", 3));
}
