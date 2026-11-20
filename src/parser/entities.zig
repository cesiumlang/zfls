//! The text of a declaration's entities after their names: their own
//! lengths, bounds and values (`c*8`, `v(3)`, `(3)[*]*10 = 'x'`), and the
//! dimension and length of an implicitly typed name's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");

fn R() *const patterns.Patterns {
    return patterns.get();
}

pub const Split = struct { line: []const u8, extra: ?[]const u8 };

/// The type parameters of an entity with its own length `len` (`*8`,
/// `*(n)`) declared with `kind` (`*(*)`, `(len=5)`, `(KIND=4, LEN=200)`):
/// the length replaces the declaration's, a KIND stays
pub fn entityLength(a: Allocator, kind: ?[]const u8, len: []const u8) ![]const u8 {
    const k = kind orelse return len;
    if (k.len < 2 or k[0] != '(' or std.ascii.findIgnoreCase(k, "kind") == null) return len;
    var value = str.strip(len[1..]);
    if (value.len > 1 and value[0] == '(' and value[value.len - 1] == ')') value = value[1 .. value.len - 1];
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '(');
    for (try helpers.splitArgs(a, k[1 .. k.len - 1])) |item| {
        const t = str.strip(item);
        if (!std.ascii.startsWithIgnoreCase(t, "kind")) continue;
        try out.appendSlice(a, t);
        try out.appendSlice(a, ", ");
    }
    try out.print(a, "LEN={s})", .{value});
    return out.items;
}

/// `s` after the bounds, cobounds and length that may follow an entity's
/// name in a declaration: `(3)[*]*10 = ...`
pub fn afterEntitySpecs(s: []const u8) []const u8 {
    var t = str.lstrip(s);
    if (t.len > 0 and t[0] == '(') {
        const m = helpers.findParenMatch(t[1..]);
        if (m >= 0) t = str.lstrip(t[@as(usize, @intCast(m)) + 2 ..]);
    }
    if (t.len > 0 and t[0] == '[') {
        if (std.mem.findScalar(u8, t, ']')) |c| t = str.lstrip(t[c + 1 ..]);
    }
    if (t.len > 0 and t[0] == '*') {
        t = str.lstrip(t[1..]);
        if (t.len > 0 and t[0] == '(') {
            const m = helpers.findParenMatch(t[1..]);
            if (m >= 0) t = t[@as(usize, @intCast(m)) + 2 ..];
        } else {
            while (t.len > 0 and std.ascii.isDigit(t[0])) t = t[1..];
        }
    }
    return str.lstrip(t);
}

/// Parse the implicit dimension of an array e.g. var(3,4)
pub fn parseImpDim(a: Allocator, line: []const u8) !Split {
    const m = R().IMP_DIM.match(line) orelse return .{ .line = line, .extra = null };
    const i = helpers.findParenMatch(line[m.end(1)..]);
    if (i < 0) return .{ .line = line, .extra = null };
    const iu: usize = @intCast(i);
    const dims = line[m.start(1) .. m.end(1) + iu + 1];
    const rest = try std.mem.concat(a, u8, &.{ line[0..m.start(1)], line[m.end(1) + iu + 1 ..] });
    return .{ .line = rest, .extra = try std.mem.concat(a, u8, &.{ "dimension", dims }) };
}

/// Parse the implicit character length from a variable e.g. var_name*10
pub fn parseImpChar(a: Allocator, line: []const u8) !Split {
    const m = R().IMP_CHAR.match(line) orelse return .{ .line = line, .extra = null };
    const g2 = m.group(2).?;
    var char_len: []const u8 = undefined;
    if (std.mem.eql(u8, g2, "(")) {
        const i = helpers.findParenMatch(line[m.end(2)..]);
        if (i < 0) return .{ .line = line, .extra = null };
        char_len = line[m.start(2) .. m.end(2) + @as(usize, @intCast(i)) + 1];
    } else {
        char_len = g2;
    }
    return .{ .line = m.group(1).?, .extra = try std.mem.concat(a, u8, &.{ "*", char_len }) };
}

test "an entity's own length replaces its declaration's, a KIND stays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("*8", try entityLength(a, "*(*)", "*8"));
    try std.testing.expectEqualStrings("*10", try entityLength(a, null, "*10"));
    try std.testing.expectEqualStrings("*4", try entityLength(a, "(len=5)", "*4"));
    try std.testing.expectEqualStrings("(KIND=4, LEN=100)", try entityLength(a, "(KIND=4, LEN=200)", "*100"));
    try std.testing.expectEqualStrings("(KIND=4, LEN=LEN(B))", try entityLength(a, "(KIND=4)", "*(LEN(B))"));
    try std.testing.expectEqualStrings("= 'x'", afterEntitySpecs("(3)[*]*10 = 'x'"));
    try std.testing.expectEqualStrings("= 1", afterEntitySpecs("*(len(a)) = 1"));
}
