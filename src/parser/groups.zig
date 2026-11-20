//! Part of the parser (parse.zig): COMMON blocks and NAMELIST groups
//! (#556). `common /blk/ a, b(10), /other/ c` names the block `blk` of the
//! scope, whose object (`Variable.group` `.common`, named `/blk/`: block
//! names are no names of the scope, `common /x/ x` is right) is kept in
//! `Scope.commons`; blank common is `//`. The bounds a COMMON statement
//! gives are its objects' DIMENSION. `namelist /nl/ a, b` declares the
//! group `nl`, a name of the scope (`.namelist`), which `write (*, nl)`
//! and `nml=nl` name. A block or group named again in the scope gets the
//! names that follow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const attributes = @import("attributes.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

pub const Kind = enum { common, namelist };

/// One group of a statement: its name (null: blank common) and its items
/// (a name with its bounds, if any)
pub const Group = struct { name: ?[]const u8, items: []const Item };
pub const Item = struct { name: []const u8, bounds: ?[]const u8 };

/// The statement's kind and the text after its keyword, or null
fn keyword(code: []const u8) ?struct { kind: Kind, rest: []const u8 } {
    const s = std.mem.trimStart(u8, code, " \t");
    const kinds = [_]struct { []const u8, Kind }{ .{ "common", .common }, .{ "namelist", .namelist } };
    for (kinds) |k| {
        if (!std.ascii.startsWithIgnoreCase(s, k[0])) continue;
        const rest = s[k[0].len..];
        // `common = 1`, `commonx(1) = 2`: no statement of these
        if (rest.len == 0 or isNameChar(rest[0])) return null;
        const t = std.mem.trimStart(u8, rest, " \t");
        if (t.len == 0) return null;
        if (k[1] == .namelist and t[0] != '/') return null;
        if (k[1] == .common and t[0] != '/' and !std.ascii.isAlphabetic(t[0])) return null;
        return .{ .kind = k[1], .rest = t };
    }
    return null;
}

/// The groups of a COMMON or NAMELIST statement's list
pub fn parse(a: Allocator, rest: []const u8) !?[]const Group {
    var groups: std.ArrayList(Group) = .empty;
    var i: usize = 0;
    var name: ?[]const u8 = null;
    var items: std.ArrayList(Item) = .empty;
    var started = false;
    while (true) {
        while (i < rest.len and (rest[i] == ' ' or rest[i] == ',')) i += 1;
        if (i >= rest.len) break;
        if (rest[i] == '/') {
            const close = std.mem.findScalarPos(u8, rest, i + 1, '/') orelse return null;
            if (started) try groups.append(a, .{ .name = name, .items = items.items });
            items = .empty;
            const n = std.mem.trim(u8, rest[i + 1 .. close], " ");
            for (n) |c| if (!isNameChar(c)) return null;
            name = if (n.len == 0) null else n;
            started = true;
            i = close + 1;
            continue;
        }
        if (!std.ascii.isAlphabetic(rest[i])) return null;
        const start = i;
        while (i < rest.len and isNameChar(rest[i])) i += 1;
        const item_name = rest[start..i];
        while (i < rest.len and rest[i] == ' ') i += 1;
        var bounds: ?[]const u8 = null;
        if (i < rest.len and rest[i] == '(') {
            var depth: usize = 0;
            const open = i;
            while (i < rest.len) : (i += 1) {
                if (rest[i] == '(') depth += 1 else if (rest[i] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (i >= rest.len) return null;
            bounds = std.mem.trim(u8, rest[open + 1 .. i], " ");
            i += 1;
        }
        started = true;
        try items.append(a, .{ .name = item_name, .bounds = bounds });
    }
    if (started) try groups.append(a, .{ .name = name, .items = items.items });
    return groups.items;
}

/// The name of a group's object
fn objectName(a: Allocator, kind: Kind, name: ?[]const u8) ![]const u8 {
    return switch (kind) {
        .common => a.print("/{s}/", .{name orelse ""}),
        .namelist => name orelse "",
    };
}

/// The object of the group in `scope` named `name`, if one is there
fn existing(scope: *Obj, kind: Kind, name: []const u8) ?*Obj {
    const list = if (kind == .common) scope.scopeData().commons.items else scope.scopeData().children.items;
    for (list) |o| {
        if (o.kind != .variable or o.varDataConst().group == .none) continue;
        if (std.ascii.eqlIgnoreCase(o.name, name)) return o;
    }
    return null;
}

/// Reads statement `code` (no label, no comment), at line `line_no`, as a
/// COMMON or NAMELIST statement if it is one: true when it is. The bounds
/// it gives are attributes (`attrs`, in `sa`).
pub fn read(ast: *Ast, sa: Allocator, attrs: *std.ArrayList(attributes.Attr), code: []const u8, line_no: usize) !bool {
    const kw = keyword(code) orelse return false;
    const groups = (try parse(sa, kw.rest)) orelse return false;
    if (kw.kind == .namelist) for (groups) |g| if (g.name == null) return false;
    if (ast.current_scope == null) try ast.openMain(line_no);
    const scope = ast.current_scope.?;
    const pa = ast.allocator();
    for (groups) |g| {
        const name = try objectName(sa, kw.kind, g.name);
        var names: std.ArrayList([]const u8) = .empty;
        for (g.items) |it| {
            try names.append(sa, if (it.bounds) |b| try sa.print("{s}({s})", .{ it.name, b }) else it.name);
            if (it.bounds) |b| try attrs.append(sa, .{ .scope = scope, .line = line_no, .name = it.name, .kw = .dimension, .text = b });
        }
        const listed = try std.mem.join(sa, ", ", names.items);
        if (existing(scope, kw.kind, name)) |o| {
            const v = o.varData();
            v.members = if (v.members.len == 0) try pa.dupe(u8, listed) else try std.mem.concat(pa, u8, &.{ v.members, ", ", listed });
            continue;
        }
        const o = try Obj.newVariable(ast, line_no, name, if (kw.kind == .common) "COMMON" else "NAMELIST", &.{}, .{});
        const v = o.varData();
        v.group = if (kw.kind == .common) .common else .namelist;
        v.members = try pa.dupe(u8, listed);
        if (kw.kind == .namelist) {
            try ast.addVariable(o);
        } else {
            try scope.scopeData().commons.append(pa, o);
            o.setParent(scope);
            if (ast.pending_doc) |d| {
                o.addDoc(d);
                ast.pending_doc = null;
            }
            ast.last_obj = o;
        }
    }
    return true;
}

test parse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = (try parse(a, "/blk/ a, b(10, 2), /other/ c")).?;
    try std.testing.expectEqual(@as(usize, 2), g.len);
    try std.testing.expectEqualStrings("blk", g[0].name.?);
    try std.testing.expectEqualStrings("10, 2", g[0].items[1].bounds.?);
    try std.testing.expectEqualStrings("c", g[1].items[0].name);
    const blank = (try parse(a, "x, y // z")).?;
    try std.testing.expect(blank[0].name == null and blank[1].name == null);
    try std.testing.expectEqual(@as(usize, 2), blank[0].items.len);
    const nl = (try parse(a, "/nl/ a, k /nl2/ c")).?;
    try std.testing.expectEqualStrings("nl2", nl[1].name.?);
    try std.testing.expect(keyword("common = 1") == null);
    try std.testing.expect(keyword("namelist = 2") == null);
    try std.testing.expect(keyword("namelist /nl/ a").?.kind == .namelist);
}
