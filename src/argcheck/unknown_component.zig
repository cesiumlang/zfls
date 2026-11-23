//! A component a derived type does not have (#850): `v%b`. gfortran, Flang
//! and ifx all report it. Only a type found whole is checked: its own
//! components and bindings, those of the types it extends (all found), and
//! no type with parameters or with an INCLUDE that is not read.

const std = @import("std");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const objects = @import("../objects.zig");

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;
const Obj = objects.Obj;

/// Whether every type `t` extends is found, and no INCLUDE or type
/// parameter can add a component the text does not show
fn isWhole(t: *const Obj) bool {
    var cur: *const Obj = t;
    // (a chain of parents is free of loops)
    for (0..64) |_| {
        if (cur.kind != .type) return false;
        if (hasUnreadInclude(cur)) return false;
        if (hasParameters(cur)) return false;
        if (cur.scopeDataConst().inherit == null) return true;
        cur = cur.typeDataConst().inherit_var orelse return false;
    }
    return false;
}

fn hasUnreadInclude(t: *const Obj) bool {
    for (t.file_ast.include_statements.items) |inc| {
        if (inc.file == null and inc.line_number >= t.sline and inc.line_number <= t.eline) return true;
    }
    // conditional compilation inside the type (Intel's `!DEC$ IF`, `#if`)
    // that may leave components out of what is indexed
    const f = t.file_ast.file orelse return true;
    var ln = t.sline;
    while (ln < t.eline) : (ln += 1) {
        const line = std.mem.trimStart(u8, f.getLine(ln, false) orelse continue, " \t");
        if (line.len == 0) continue;
        if (line[0] == '#') return true;
        if (line[0] == '!' and (std.ascii.startsWithIgnoreCase(line[1..], "dec$") or std.ascii.startsWithIgnoreCase(line[1..], "dir$") or std.ascii.startsWithIgnoreCase(line[1..], "ms$"))) return true;
    }
    return false;
}

/// Whether the TYPE statement has a parenthesized list after the name
/// (type parameters), as the first line of the type shows it
fn hasParameters(t: *const Obj) bool {
    const f = t.file_ast.file orelse return true;
    if (t.sline == 0) return true;
    const line = f.getLine(t.sline - 1, false) orelse return true;
    const at = std.ascii.findIgnoreCase(line, t.name) orelse return true;
    const after = std.mem.trimStart(u8, line[at + t.name.len ..], " ");
    return after.len > 0 and after[0] == '(';
}

fn declares(env: objects.Env, t: *Obj, name: []const u8) !bool {
    var cur: ?*Obj = t;
    for (0..64) |_| {
        const o = cur orelse return false;
        if (try objects.checkScope(env, o, name, false, null) != null) return true;
        cur = o.typeDataConst().inherit_var;
        // the parent component, named like the type extended (`c%base`)
        if (cur) |parent| if (std.ascii.eqlIgnoreCase(parent.name, name)) return true;
    }
    return true;
}

/// Reports each `%name` of the statement `text` (at offset `s` of the
/// joined statement) whose type is found and does not have the component
pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, scope: ?*Obj) !void {
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, text, from, '%')) |p| : (from = p + 1) {
        var k = p + 1;
        while (k < text.len and text[k] == ' ') k += 1;
        const start = k;
        while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_')) k += 1;
        if (k == start) continue;
        const name = text[start..k];
        const type_scope = (try c.memberScope(scope, text[0..k])) orelse continue;
        if (!isWhole(type_scope)) continue;
        const lower = try std.ascii.allocLowerString(c.a, name);
        if (try declares(c.env, type_scope, lower)) continue;
        try c.report(j, s + start, s + k, .unknown_component, "Component {s} is not a member of type {s}", .{ name, type_scope.name });
    }
}
