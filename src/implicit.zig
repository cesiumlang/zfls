//! Implicit typing (hansec #201): the type a name that is not declared gets
//! from the IMPLICIT statements of its scope and of the scopes around it
//! (host association), or from the default rules: names starting with I to N
//! are INTEGER, the others REAL. `IMPLICIT NONE` leaves names untyped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("objects.zig");
const Obj = objects.Obj;

/// The type of the names whose first letter is in `first`..`last`
/// (lowercase)
pub const Rule = struct { first: u8, last: u8, type: []const u8 };

/// The rules of an IMPLICIT statement (`implicit real(8) (a-h, o-z),
/// integer (i-n)`), the text after the keyword; empty for `NONE`
pub fn parseRules(a: Allocator, spec_in: []const u8) ![]const Rule {
    const spec = std.mem.trim(u8, spec_in, " \t");
    if (std.ascii.startsWithIgnoreCase(spec, "none")) return &.{};
    var out: std.ArrayList(Rule) = .empty;
    // items separated by commas outside parentheses: `type-spec (letters)`
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= spec.len) : (i += 1) {
        const c: u8 = if (i < spec.len) spec[i] else ',';
        switch (c) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) {
                try addItem(a, &out, spec[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    return out.items;
}

/// One `type-spec (letter-spec, ...)` of an IMPLICIT statement
fn addItem(a: Allocator, out: *std.ArrayList(Rule), item_in: []const u8) !void {
    const item = std.mem.trim(u8, item_in, " \t\r\n&");
    if (item.len < 3 or item[item.len - 1] != ')') return;
    // the letters are in the last parentheses
    var depth: usize = 0;
    var open = item.len;
    while (open > 0) {
        open -= 1;
        if (item[open] == ')') depth += 1;
        if (item[open] == '(') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    const type_text = std.mem.trim(u8, item[0..open], " \t");
    if (type_text.len == 0) return;
    const type_name = try typeName(a, type_text);
    var letters = std.mem.splitScalar(u8, item[open + 1 .. item.len - 1], ',');
    while (letters.next()) |l_in| {
        const l = std.mem.trim(u8, l_in, " \t");
        if (l.len == 0 or !std.ascii.isAlphabetic(l[0])) continue;
        var last = l[0];
        if (std.mem.indexOfScalar(u8, l, '-')) |dash| {
            const rest = std.mem.trim(u8, l[dash + 1 ..], " \t");
            if (rest.len == 0 or !std.ascii.isAlphabetic(rest[0])) continue;
            last = rest[0];
        }
        try out.append(a, .{ .first = std.ascii.toLower(l[0]), .last = std.ascii.toLower(last), .type = type_name });
    }
}

/// The type of an IMPLICIT item as hover shows declared types: the type
/// keyword in upper case, its parameters as written (`REAL(c_double)`)
fn typeName(a: Allocator, text: []const u8) ![]const u8 {
    var n: usize = 0;
    while (n < text.len and (std.ascii.isAlphabetic(text[n]) or text[n] == ' ')) n += 1;
    const keyword = std.mem.trimEnd(u8, text[0..n], " ");
    const upper = try std.ascii.allocUpperString(a, keyword);
    // `double precision` is written with one space
    var words = std.mem.tokenizeScalar(u8, upper, ' ');
    var parts: std.ArrayList(u8) = .empty;
    while (words.next()) |w| {
        if (parts.items.len > 0) try parts.append(a, ' ');
        try parts.appendSlice(a, w);
    }
    try parts.appendSlice(a, std.mem.trim(u8, text[n..], " "));
    return parts.items;
}

/// The type `name` has without a declaration in `scope`, or null under
/// IMPLICIT NONE
pub fn typeOf(scope: ?*const Obj, name: []const u8) ?[]const u8 {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return null;
    const letter = std.ascii.toLower(name[0]);
    var cur = scope;
    var depth: usize = 0;
    while (cur) |s| : ({
        cur = s.parent;
        depth += 1;
    }) {
        if (depth > 64) break;
        const flag = s.implicit_vars orelse continue;
        if (!flag) return null;
        if (s.data == .scope) for (s.scopeDataConst().implicit_rules) |r| {
            if (letter >= r.first and letter <= r.last) return r.type;
        };
    }
    return if (letter >= 'i' and letter <= 'n') "INTEGER" else "REAL";
}

test "IMPLICIT rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = try parseRules(a, "integer(c_int) (i-k), integer(c_int) (m,n), &\n & real(c_double) (a-h), double  precision (o - z)");
    try std.testing.expectEqual(@as(usize, 5), rules.len);
    try std.testing.expectEqualStrings("INTEGER(c_int)", rules[0].type);
    try std.testing.expectEqual(@as(u8, 'i'), rules[0].first);
    try std.testing.expectEqual(@as(u8, 'k'), rules[0].last);
    try std.testing.expectEqual(@as(u8, 'n'), rules[2].first);
    try std.testing.expectEqualStrings("REAL(c_double)", rules[3].type);
    try std.testing.expectEqualStrings("DOUBLE PRECISION", rules[4].type);
    try std.testing.expectEqual(@as(u8, 'z'), rules[4].last);
    try std.testing.expectEqual(@as(usize, 0), (try parseRules(a, "none")).len);
    try std.testing.expectEqual(@as(usize, 1), (try parseRules(a, "character*8 (c)")).len);
}
