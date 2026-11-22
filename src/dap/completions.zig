//! The Debug Console's completions (`completions`) of Fortran names, for
//! gdb (gdb_completions.zig) and Windows's Debugger Engine
//! (engine_completions.zig): the designator before the cursor, and the
//! names it may go on with, as the protocol's targets (#744).

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;
const Session = @import("session.zig").Session;

/// The completion characters: `%` too, for components
pub const trigger_characters = [_][]const u8{"%"};

/// The designator that ends a text (before the cursor): `p origin%x` is
/// `origin%x`, its base `origin` and the name begun `x`
pub const Designator = struct {
    /// Where the designator begins in the text
    start: usize,
    /// Before the last `%`; null without one
    base: ?[]const u8,
    /// The name being typed (after the last `%`)
    prefix: []const u8,
};

/// The request's text before the cursor, and the client's first column
pub const Cursor = struct {
    before: []const u8,
    /// 1, or 0 when the client said `columnsStartAt1: false`
    first: i64,

    pub fn of(s: *Session, a: Allocator, args: ?Value) Cursor {
        const init = if (s.client_init.len > 0) json.parse(a, s.client_init) catch Value.null else Value.null;
        const from1 = json.get(init, "columnsStartAt1");
        const first: i64 = if (from1 != null and from1.? == .bool and !from1.?.bool) 0 else 1;
        const text = json.str(json.get(args, "text")) orelse "";
        const column = json.int(json.get(args, "column")) orelse @as(i64, @intCast(text.len)) + first;
        return .{ .before = beforeCursor(text, json.int(json.get(args, "line")), column, first), .first = first };
    }
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The designator at the end of `text`: names, `%` and balanced
/// parentheses (`ts(2)%point%`); null when the text ends otherwise (in a
/// string, after a parenthesized expression's `%`)
pub fn designatorAt(text: []const u8) ?Designator {
    var i = text.len;
    var depth: usize = 0;
    var last_pct: ?usize = null;
    while (i > 0) {
        const c = text[i - 1];
        if (depth > 0) {
            if (c == ')') depth += 1;
            if (c == '(') depth -= 1;
            if (c == '\'' or c == '"') return null;
            i -= 1;
        } else if (isNameChar(c)) {
            i -= 1;
        } else if (c == '%') {
            if (last_pct == null) last_pct = i - 1;
            i -= 1;
        } else if (c == ')' and last_pct != null) {
            depth = 1;
            i -= 1;
        } else break;
    }
    if (depth > 0) return null;
    // a designator begins with a name
    if (i < text.len and !std.ascii.isAlphabetic(text[i])) return null;
    // in a string
    if (i > 0 and (text[i - 1] == '\'' or text[i - 1] == '"')) return null;
    const prefix = text[if (last_pct) |p| p + 1 else i..];
    return .{ .start = i, .base = if (last_pct) |p| text[i..p] else null, .prefix = prefix };
}

/// gdb's commands whose argument is an expression
const expression_commands = [_][]const u8{ "p", "print", "inspect", "output", "call", "ptype", "whatis", "display", "x", "set", "explore" };

/// Whether what comes before a name makes it a name of an expression: a
/// command of an expression's (`p `, `print/x `), or an operator, a
/// parenthesis, a comma; not a line's first word (a gdb command)
pub fn inExpression(head: []const u8) bool {
    const t = std.mem.trimEnd(u8, head, " \t");
    if (t.len == 0) return false;
    if (std.mem.findScalar(u8, "(,=+-*/<>.:", t[t.len - 1]) != null) return true;
    const word = t[0 .. std.mem.findAny(u8, t, " \t/") orelse t.len];
    for (expression_commands) |c| if (std.mem.eql(u8, c, word)) return true;
    return false;
}

/// The text before the cursor: `text`'s line `line` (1-based, or the
/// first) up to `column` (whose first is `first`)
pub fn beforeCursor(text: []const u8, line: ?i64, column: i64, first: i64) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var l = it.first();
    var n: i64 = 1;
    while (n < (line orelse 1)) : (n += 1) l = it.next() orelse "";
    const col: usize = @intCast(std.math.clamp(column - first, 0, @as(i64, @intCast(l.len))));
    return l[0..col];
}

/// A module variable's local name (`nhits => hits`: `nhits`)
pub fn localName(name: []const u8) []const u8 {
    return name[0 .. std.mem.find(u8, name, " => ") orelse name.len];
}

pub const Target = struct { label: []const u8, text: []const u8, start: i64, length: i64, type: []const u8 };

/// The names of `names` that the designator's name begins (case not
/// minded, each once), as targets that replace it; null when none
pub fn targets(a: Allocator, names: []const []const u8, d: Designator, at: Cursor) !?[]Target {
    var out: std.ArrayList(Target) = .empty;
    const start: i64 = @intCast(at.before.len - d.prefix.len);
    for (names) |name| {
        if (name.len < d.prefix.len or !std.ascii.eqlIgnoreCase(name[0..d.prefix.len], d.prefix)) continue;
        const seen = for (out.items) |t| {
            if (std.ascii.eqlIgnoreCase(t.label, name)) break true;
        } else false;
        if (seen) continue;
        try out.append(a, .{ .label = name, .text = name, .start = start + at.first, .length = @intCast(d.prefix.len), .type = if (d.base != null) "property" else "variable" });
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(a);
}

test designatorAt {
    const t = std.testing;
    var d = designatorAt("origin%").?;
    try t.expectEqualStrings("origin", d.base.?);
    try t.expectEqualStrings("", d.prefix);
    try t.expectEqual(@as(usize, 0), d.start);
    d = designatorAt("p origin%i").?;
    try t.expectEqualStrings("origin", d.base.?);
    try t.expectEqualStrings("i", d.prefix);
    try t.expectEqual(@as(usize, 2), d.start);
    d = designatorAt("print ts(2)%point%").?;
    try t.expectEqualStrings("ts(2)%point", d.base.?);
    d = designatorAt("p a(i, b(1))%x").?;
    try t.expectEqualStrings("a(i, b(1))", d.base.?);
    try t.expectEqualStrings("x", d.prefix);
    d = designatorAt("p ori").?;
    try t.expect(d.base == null);
    try t.expectEqualStrings("ori", d.prefix);
    // a module's: the name after `::`
    d = designatorAt("p grid::nc").?;
    try t.expectEqualStrings("nc", d.prefix);
    try t.expect(designatorAt("p 'abc%") == null);
    try t.expect(designatorAt("p (a)%x") == null);
    try t.expect(designatorAt("p 1%") == null);
    try t.expectEqualStrings("", designatorAt("p ").?.prefix);
}

test inExpression {
    try std.testing.expect(inExpression("p "));
    try std.testing.expect(inExpression("print/x "));
    try std.testing.expect(inExpression("p a + "));
    try std.testing.expect(inExpression("p f("));
    try std.testing.expect(!inExpression(""));
    try std.testing.expect(!inExpression("info "));
}

test targets {
    const a = std.testing.allocator;
    const at: Cursor = .{ .before = "p origin%i", .first = 1 };
    const got = (try targets(a, &.{ "x", "y", "id", "ID" }, designatorAt(at.before).?, at)).?;
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("id", got[0].text);
    // after `p origin%`: column 10 of 1-based columns, one character replaced
    try std.testing.expectEqual(@as(i64, 10), got[0].start);
    try std.testing.expectEqual(@as(i64, 1), got[0].length);
    try std.testing.expect(try targets(a, &.{"x"}, designatorAt(at.before).?, at) == null);
    try std.testing.expectEqualStrings("p ori", beforeCursor("p origin", null, 6, 1));
    try std.testing.expectEqualStrings("nhits", localName("nhits => hits"));
}
