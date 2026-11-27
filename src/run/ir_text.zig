//! Reading LLVM IR as text, for the patches of LFortran's IR
//! (lfortran_lines.zig, lfortran_types.zig): lines, metadata ids, fields.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The id of an instruction's `!dbg !N` (or a `define`'s)
pub fn dbgOf(l: []const u8) ?u64 {
    const at = std.mem.findLast(u8, l, "!dbg !") orelse return null;
    return number(l[at + "!dbg !".len ..]);
}

/// The id of a metadata line, `!N = ...`
pub fn metadataId(l: []const u8) ?u64 {
    if (l.len < 2 or l[0] != '!' or !std.ascii.isDigit(l[1])) return null;
    return number(l[1..]);
}

/// The text after `key` up to `end`
pub fn field(l: []const u8, key: []const u8, end: u8) ?[]const u8 {
    const at = (std.mem.find(u8, l, key) orelse return null) + key.len;
    const e = std.mem.findScalarPos(u8, l, at, end) orelse l.len;
    return l[at..e];
}

/// The number at the start of `s`
pub fn number(s: ?[]const u8) ?u64 {
    const t = s orelse return null;
    var e: usize = 0;
    while (e < t.len and std.ascii.isDigit(t[e])) e += 1;
    return std.fmt.parseInt(u64, t[0..e], 10) catch null;
}

/// The text's lines, without carriage returns
pub fn splitLines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    return out.items;
}

/// The word (letters, digits, `_`) at the start of `s`
pub fn word(s: []const u8) []const u8 {
    var e: usize = 0;
    while (e < s.len and (std.ascii.isAlphanumeric(s[e]) or s[e] == '_')) e += 1;
    return s[0..e];
}
