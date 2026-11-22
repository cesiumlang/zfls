//! zfls's side of the ifx and gfortran oracles (ifx_oracle.zig,
//! gfortran_oracle.zig): the objects of
//! `--debug_parser`'s Object Tree and what hover shows of each variable
//! (its Declarations), and what a declaration's type spec says.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Object = struct {
    /// `getType`: 1 module or program, 2 subroutine, 3 function, 4 type,
    /// 5 interface, 6 variable, 7 type-bound procedure, 8 submodule, 9+
    /// constructs
    kind: i64,
    fqsn: []const u8,
    /// a COMMON block or NAMELIST group
    group: bool,
    /// the kind of the object it is in (0: none)
    parent_kind: i64 = 0,
    /// in an interface block (an interface body, its dummy arguments)
    in_interface: bool = false,
    /// the first line of its hover, for a variable
    declaration: ?[]const u8 = null,
    /// of the associate name of a block of SELECT TYPE or RANK: the line
    /// of its SELECT
    select_line: ?usize = null,

    pub fn name(o: Object) []const u8 {
        const i = std.mem.findLast(u8, o.fqsn, "::") orelse return o.fqsn;
        return o.fqsn[i + 2 ..];
    }

    pub fn parent(o: Object) ?[]const u8 {
        const i = std.mem.findLast(u8, o.fqsn, "::") orelse return null;
        return o.fqsn[0..i];
    }

    /// The name of the object it is in
    pub fn parentName(o: Object) []const u8 {
        const p = o.parent() orelse return "";
        const i = std.mem.findLast(u8, p, "::") orelse return p;
        return p[i + 2 ..];
    }
};

/// The objects of `--debug_parser` output, null without an Object Tree
pub fn objects(a: Allocator, out: []const u8) !?[]Object {
    const start = std.mem.find(u8, out, "Object Tree") orelse return null;
    const end = std.mem.find(u8, out, "Exportable Objects") orelse out.len;
    var list: std.ArrayList(Object) = .empty;
    // the objects the next is in: their indents and kinds
    const Open = struct { indent: usize, kind: i64, in_interface: bool };
    var open: std.ArrayList(Open) = .empty;
    var it = std.mem.splitScalar(u8, out[start..end], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const indent = raw.len - std.mem.trimStart(u8, raw, " ").len;
        const colon = std.mem.find(u8, line, ": ") orelse continue;
        const kind = std.fmt.parseInt(i64, line[0..colon], 10) catch continue;
        var rest = line[colon + 2 ..];
        const group = std.mem.endsWith(u8, rest, " COMMON") or std.mem.endsWith(u8, rest, " NAMELIST");
        if (std.mem.findScalar(u8, rest, ' ')) |sp| rest = rest[0..sp];
        if (rest.len == 0) continue;
        while (open.items.len > 0 and open.items[open.items.len - 1].indent >= indent) _ = open.pop();
        const up: ?Open = if (open.items.len > 0) open.items[open.items.len - 1] else null;
        const o: Object = .{
            .kind = kind,
            .fqsn = try std.ascii.allocLowerString(a, rest),
            .group = group,
            .parent_kind = if (up) |u| u.kind else 0,
            .in_interface = if (up) |u| u.kind == 5 or u.in_interface else false,
        };
        try open.append(a, .{ .indent = indent, .kind = kind, .in_interface = o.in_interface });
        // a scope is printed in its parent and again on its own: the first,
        // in its context, is kept
        const again = for (list.items) |x| {
            if (x.kind == o.kind and std.mem.eql(u8, x.fqsn, o.fqsn)) break true;
        } else false;
        if (!again) try list.append(a, o);
    }
    const blocks = try selectBlocks(a, out);
    for (list.items) |*o| if (o.kind == 6) if (o.parent()) |p| if (blocks.get(p)) |b| {
        o.select_line = b.select_line;
    };
    // the declarations, by fqsn
    if (std.mem.find(u8, out, "\nDeclarations")) |d| {
        var lines = std.mem.splitScalar(u8, out[d..], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const sep = std.mem.find(u8, line, ": ") orelse continue;
            const fq = try std.ascii.allocLowerString(a, line[0..sep]);
            for (list.items) |*o| if (std.mem.eql(u8, o.fqsn, fq)) {
                o.declaration = line[sep + 2 ..];
            };
        }
    }
    return list.items;
}

/// A block of SELECT TYPE or RANK: the lines (1-based) of its SELECT and
/// of its guard
pub const SelectBlock = struct { select_line: usize, line: usize };

/// The blocks of SELECT TYPE and RANK of `--debug_parser` output, by fqsn
/// in lower case
pub fn selectBlocks(a: Allocator, out: []const u8) !std.StringHashMapUnmanaged(SelectBlock) {
    var res: std.StringHashMapUnmanaged(SelectBlock) = .empty;
    const start = std.mem.find(u8, out, "\nSelect Blocks") orelse return res;
    const end = std.mem.findPos(u8, out, start, "\nDeclarations") orelse out.len;
    var lines = std.mem.splitScalar(u8, out[start..end], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const sep = std.mem.findLast(u8, line, ": ") orelse continue;
        var nums = std.mem.tokenizeScalar(u8, line[sep + 2 ..], ' ');
        const s = std.fmt.parseInt(usize, nums.next() orelse continue, 10) catch continue;
        const l = std.fmt.parseInt(usize, nums.next() orelse continue, 10) catch continue;
        try res.put(a, try std.ascii.allocLowerString(a, line[0..sep]), .{ .select_line = s, .line = l });
    }
    return res;
}

/// The type spec of a hover line (`REAL(8), PARAMETER :: pi = 3.1`:
/// `REAL(8)`)
pub fn typeSpec(decl: []const u8) []const u8 {
    var depth: usize = 0;
    for (decl, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 0) return decl[0..i],
        ':' => if (depth == 0 and i + 1 < decl.len and decl[i + 1] == ':') return std.mem.trimEnd(u8, decl[0..i], " "),
        else => {},
    };
    return decl;
}

/// The rank of a hover line's DIMENSION(...), 0 without one
pub fn rank(decl: []const u8) usize {
    const i = std.mem.find(u8, decl, "DIMENSION(") orelse return 0;
    var depth: usize = 0;
    var n: usize = 1;
    for (decl[i + "DIMENSION(".len ..]) |c| switch (c) {
        '(' => depth += 1,
        ')' => if (depth == 0) return n else {
            depth -= 1;
        },
        ',' => if (depth == 0) {
            n += 1;
        },
        else => {},
    };
    return n;
}

/// What a type spec says: an intrinsic type and its kind, a derived type
pub const Type = union(enum) {
    /// `REAL`, `INTEGER`, `LOGICAL`, `COMPLEX` (its kind, not its bytes)
    intrinsic: struct { name: []const u8, kind: u8 },
    character,
    /// `TYPE(x)` (`class` false) or `CLASS(x)`, `x` uppercase
    derived: struct { name: []const u8, class: bool },
};

/// The type of type spec `spec`; null when the spec does not tell (a named
/// kind, `REAL(dp)`)
pub fn typeOf(a: Allocator, spec_in: []const u8) !?Type {
    const spec = try std.ascii.allocUpperString(a, spec_in);
    if (std.mem.startsWith(u8, spec, "CHARACTER")) return .character;
    if (std.mem.eql(u8, spec, "DOUBLE PRECISION")) return .{ .intrinsic = .{ .name = "REAL", .kind = 8 } };
    if (std.mem.eql(u8, spec, "DOUBLE COMPLEX")) return .{ .intrinsic = .{ .name = "COMPLEX", .kind = 8 } };
    if (std.mem.eql(u8, spec, "BYTE")) return .{ .intrinsic = .{ .name = "INTEGER", .kind = 1 } };
    if (std.mem.startsWith(u8, spec, "TYPE(") or std.mem.startsWith(u8, spec, "CLASS(")) {
        const open = std.mem.findScalar(u8, spec, '(').?;
        return .{ .derived = .{ .name = spec[open + 1 .. spec.len - 1], .class = spec[0] == 'C' } };
    }
    for ([_][]const u8{ "REAL", "INTEGER", "LOGICAL", "COMPLEX" }) |name| {
        if (!std.mem.startsWith(u8, spec, name)) continue;
        var rest = spec[name.len..];
        var kind: u8 = 4;
        if (rest.len > 0) {
            if (rest[0] == '*') {
                kind = std.fmt.parseInt(u8, rest[1..], 10) catch return null;
                // COMPLEX*16 is COMPLEX(8)
                if (std.mem.eql(u8, name, "COMPLEX")) kind /= 2;
            } else if (rest[0] == '(' and rest[rest.len - 1] == ')') {
                rest = rest[1 .. rest.len - 1];
                if (std.mem.startsWith(u8, rest, "KIND=")) rest = rest["KIND=".len..];
                kind = std.fmt.parseInt(u8, std.mem.trim(u8, rest, " "), 10) catch return null;
            } else return null;
        }
        return .{ .intrinsic = .{ .name = name, .kind = kind } };
    }
    return null;
}

test selectBlocks {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try selectBlocks(arena.allocator(),
        \\Exportable Objects
        \\1: m
        \\
        \\Select Blocks
        \\M::s::#select1::#select2: 11 12
        \\
        \\Declarations
        \\m::s::#select1::#select2::r: REAL :: r
    );
    try std.testing.expectEqual(1, b.count());
    try std.testing.expectEqual(@as(usize, 12), b.get("m::s::#select1::#select2").?.line);
}

test "the type of a declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("REAL(8)", typeSpec("REAL(8), PARAMETER :: pi = 3.1"));
    try std.testing.expectEqualStrings("CHARACTER(len=16)", typeSpec("CHARACTER(len=16) :: label"));
    try std.testing.expectEqual(@as(usize, 2), rank("INTEGER, ALLOCATABLE, DIMENSION(:,size(a, 1)) :: x"));
    try std.testing.expectEqual(@as(usize, 0), rank("INTEGER :: n"));
    try std.testing.expectEqual(@as(u8, 4), (try typeOf(a, "REAL")).?.intrinsic.kind);
    try std.testing.expectEqual(@as(u8, 8), (try typeOf(a, "integer(kind=8)")).?.intrinsic.kind);
    try std.testing.expectEqual(@as(u8, 8), (try typeOf(a, "COMPLEX*16")).?.intrinsic.kind);
    try std.testing.expectEqualStrings("SHAPE", (try typeOf(a, "CLASS(shape)")).?.derived.name);
    try std.testing.expect((try typeOf(a, "REAL(dp)")) == null);
}
