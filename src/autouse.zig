//! Names from modules that a program unit does not use yet (hansec #62):
//! completion offers them with the USE statement that brings them in, and a
//! quick fix adds that statement for a name that is not found.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("objects.zig");
const Obj = objects.Obj;
const FortranFile = @import("parser.zig").FortranFile;

/// A public name of a module
pub const Export = struct { obj: *Obj, module: *Obj };

pub const Match = union(enum) { prefix: []const u8, exact: []const u8 };

/// The public variables, procedures, types and generic interfaces of
/// `modules` whose names match (case-insensitively), at most `limit`
pub fn exports(a: Allocator, modules: []const *Obj, match: Match, limit: usize) ![]Export {
    var out: std.ArrayList(Export) = .empty;
    for (modules) |m| {
        for (try m.getChildren(a, true)) |child| {
            switch (child.kind) {
                .variable, .subroutine, .function, .type, .interface => {},
                else => continue,
            }
            // unnamed interface blocks
            if (child.name.len == 0 or child.name[0] == '#') continue;
            const ok = switch (match) {
                .prefix => |p| std.ascii.startsWithIgnoreCase(child.name, p),
                .exact => |n| std.ascii.eqlIgnoreCase(child.name, n),
            };
            if (!ok) continue;
            try out.append(a, .{ .obj = child, .module = m });
            if (out.items.len >= limit) return out.items;
        }
    }
    return out.items;
}

/// The program unit a new USE statement goes in, of the scopes around a
/// position (outermost first): the innermost module, submodule, program or
/// procedure
pub fn unitOf(scopes: []const *Obj) ?*Obj {
    var i = scopes.len;
    while (i > 0) {
        i -= 1;
        switch (scopes[i].kind) {
            .module, .submodule, .program, .subroutine, .function => return scopes[i],
            else => {},
        }
    }
    return null;
}

/// Whether `unit` (or a scope around it) is module `m` itself, which it
/// cannot use
pub fn isWithin(unit: *const Obj, m: *const Obj) bool {
    var cur: ?*const Obj = unit;
    var depth: usize = 0;
    while (cur) |c| : (depth += 1) {
        if (c == m or depth > 64) return true;
        cur = c.parent;
    }
    return false;
}

/// Where a new USE statement of `unit` goes: before 0-based line `line`,
/// with the indentation `indent`. After the unit's last USE statement, or
/// else after the statement that opens it.
pub const Insertion = struct { line: usize, indent: []const u8 };

pub fn insertionPoint(a: Allocator, file: *const FortranFile, unit: *const Obj) !Insertion {
    var after: usize = unit.sline -| 1;
    var last_use: ?usize = null;
    for (unit.scopeDataConst().use.items) |u| {
        if (u.is_import or u.line_number == 0) continue;
        const l = u.line_number - 1;
        if (l >= after) {
            after = l;
            last_use = l;
        }
    }
    const end = statementEnd(file, after);
    const indent = if (last_use) |l|
        leading(file.getLine(l, false) orelse "")
    else
        try std.mem.concat(a, u8, &.{ leading(file.getLine(unit.sline -| 1, false) orelse ""), "  " });
    return .{ .line = end + 1, .indent = indent };
}

fn leading(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return line[0..n];
}

/// The last line of the statement that starts on 0-based line `start`
fn statementEnd(file: *const FortranFile, start: usize) usize {
    var l = start;
    while (l + 1 < file.nLines()) {
        if (file.fixed) {
            // a fixed-form continuation line has a character in column 6
            const next = file.getLine(l + 1, false) orelse break;
            const comment = next.len > 0 and (next[0] == 'c' or next[0] == 'C' or next[0] == '*' or next[0] == '!');
            if (comment or next.len < 6 or next[5] == ' ' or next[5] == '0') break;
        } else {
            const text = file.getLine(l, false) orelse break;
            const code = if (std.mem.indexOfScalar(u8, text, '!')) |c| text[0..c] else text;
            if (!std.mem.endsWith(u8, std.mem.trimEnd(u8, code, " \t\r"), "&")) break;
        }
        l += 1;
    }
    return l;
}

/// The USE statement that brings `name` in from module `module`
pub fn statement(a: Allocator, indent: []const u8, module: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}use {s}, only: {s}\n", .{ indent, module, name });
}
