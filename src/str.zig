//! Python-like string helpers operating on byte slices. Plain operations
//! use `std.mem` and `std.ascii` directly; these keep Python's semantics.

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

/// Python `s.replace(old, new, 1)`
pub fn replaceFirst(a: Allocator, s: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return std.mem.concat(a, u8, &.{ new, s });
    const i = std.mem.indexOf(u8, s, old) orelse return a.dupe(u8, s);
    return std.mem.concat(a, u8, &.{ s[0..i], new, s[i + old.len ..] });
}

pub fn dupeOpt(a: Allocator, s: ?[]const u8) !?[]u8 {
    return if (s) |v| try a.dupe(u8, v) else null;
}

pub fn spaces(a: Allocator, n: usize) ![]u8 {
    const out = try a.alloc(u8, n);
    @memset(out, ' ');
    return out;
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
