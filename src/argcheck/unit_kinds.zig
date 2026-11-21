//! Part of the argument checks (argcheck.zig): Intel's `!DEC$ REAL:n` and
//! `!DEC$ INTEGER:n` (also `!DIR$`, and `C` or `*` in column 1), which set
//! the default REAL or INTEGER kind of the next program unit only (#512):
//! ifx's listing has `R(8)` for a module's `real :: inmod` after `!DEC$
//! REAL:8`, and `R(4)` for the program after the module.

const std = @import("std");
const default_kinds = @import("../default_kinds.zig");
const objects = @import("../objects.zig");
const Obj = objects.Obj;

const Kinds = default_kinds.Kinds;

/// What a line sets, if it is such a directive
pub const Directive = struct { real: bool, kind: u8 };

pub fn directive(line: []const u8) ?Directive {
    var rest = line;
    if (rest.len > 0 and (rest[0] == 'c' or rest[0] == 'C' or rest[0] == '*')) {
        rest = rest[1..];
    } else {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0 or rest[0] != '!') return null;
        rest = rest[1..];
    }
    if (!std.ascii.startsWithIgnoreCase(rest, "dec$") and !std.ascii.startsWithIgnoreCase(rest, "dir$")) return null;
    rest = std.mem.trimStart(u8, rest[4..], " \t");
    const real = std.ascii.startsWithIgnoreCase(rest, "real");
    if (!real and !std.ascii.startsWithIgnoreCase(rest, "integer")) return null;
    rest = std.mem.trimStart(u8, rest[if (real) 4 else 7..], " \t");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trim(u8, rest[1..], " \t\r");
    if (std.mem.findScalar(u8, rest, '!')) |i| rest = std.mem.trimEnd(u8, rest[0..i], " \t");
    const n = std.fmt.parseInt(u8, rest, 10) catch return null;
    const ok = if (real) n == 4 or n == 8 or n == 16 else n == 2 or n == 4 or n == 8;
    return if (ok) .{ .real = real, .kind = n } else null;
}

/// `k` with the directives of `lines` (0-based) between program unit `unit`
/// and the program unit before it in `ast`
pub fn ofUnit(k: Kinds, lines: []const []const u8, ast: *const objects.Ast, unit: *const Obj) Kinds {
    var out = k;
    if (unit.sline == 0) return out;
    var start: usize = 0;
    for (ast.scope_list.items) |s| {
        if (s.parent != null or s == unit) continue;
        if (s.eline < unit.sline and s.eline > start) start = s.eline;
    }
    const end = @min(unit.sline - 1, lines.len);
    if (start >= end) return out;
    for (lines[start..end]) |l| if (directive(l)) |d| {
        if (d.real) out.real = d.kind else out.integer = d.kind;
    };
    return out;
}

/// The kinds of the file that declares `v`, with the directives before its
/// program unit; null for an object of no file
pub fn ofDeclaration(v: *const Obj) ?Kinds {
    const f = v.file_ast.file orelse return null;
    const unit = unitOf(v) orelse return f.default_kinds;
    return ofUnit(f.default_kinds, f.lines.items, v.file_ast, unit);
}

/// The program unit `v` is in: its outermost scope
pub fn unitOf(v: *const Obj) ?*const Obj {
    var cur: *const Obj = v.parent orelse return null;
    while (cur.parent) |p| cur = p;
    return cur;
}

test "REAL:n and INTEGER:n" {
    try std.testing.expectEqual(Directive{ .real = true, .kind = 8 }, directive("!DEC$ REAL:8").?);
    try std.testing.expectEqual(Directive{ .real = false, .kind = 8 }, directive("CDEC$ INTEGER : 8 ! wide").?);
    try std.testing.expectEqual(Directive{ .real = true, .kind = 16 }, directive("!dir$ real:16").?);
    try std.testing.expect(directive("!DEC$ REAL:10") == null);
    try std.testing.expect(directive("!DEC$ REALLY:8") == null);
    try std.testing.expect(directive("      REAL X") == null);
}
