//! Fortran values from a program's memory, for `zfls dap`: the types of
//! zfls's declarations (`REAL(8)`, `CHARACTER(LEN=*)`, `TYPE(point)`) and
//! their dimensions, numbers and characters as Fortran writes them, Intel's
//! array descriptors, and the names and previews of arrays' elements (as
//! zfls's gdb adapter shows them: `(2,-1)`, `[1.0, 2.0, …]`, `[2×3]`).
//! No Windows here: the engine reads the bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { integer, real, complex, logical, character, derived, unknown };

/// A declared type: its kind and size in bytes (for CHARACTER, the length,
/// null when assumed or deferred), and for a derived type its name
pub const Type = struct {
    kind: Kind,
    size: u32 = 0,
    name: []const u8 = "",
    /// CLASS(...)
    polymorphic: bool = false,
};

/// The type of a declaration's description (`REAL(8)`, `INTEGER(KIND=2)`,
/// `DOUBLE PRECISION`, `CHARACTER(LEN=10)`, `TYPE(point)`), Intel's sizes
pub fn parseType(desc: []const u8) Type {
    var buf: [128]u8 = undefined;
    const d = std.ascii.upperString(&buf, desc[0..@min(desc.len, buf.len)]);
    const kind_value = kindOf(d);
    if (std.mem.startsWith(u8, d, "DOUBLE PRECISION")) return .{ .kind = .real, .size = 8 };
    if (std.mem.startsWith(u8, d, "DOUBLE COMPLEX")) return .{ .kind = .complex, .size = 16 };
    if (std.mem.startsWith(u8, d, "INTEGER")) return .{ .kind = .integer, .size = kind_value orelse 4 };
    if (std.mem.startsWith(u8, d, "REAL")) return .{ .kind = .real, .size = kind_value orelse 4 };
    if (std.mem.startsWith(u8, d, "COMPLEX")) return .{ .kind = .complex, .size = 2 * (kind_value orelse 4) };
    if (std.mem.startsWith(u8, d, "LOGICAL")) return .{ .kind = .logical, .size = kind_value orelse 4 };
    if (std.mem.startsWith(u8, d, "CHARACTER")) return .{ .kind = .character, .size = charLen(d) orelse 0 };
    for ([_][]const u8{ "TYPE(", "CLASS(" }) |p| if (std.mem.startsWith(u8, d, p)) {
        const close = std.mem.indexOfScalar(u8, desc, ')') orelse desc.len;
        return .{ .kind = .derived, .name = std.mem.trim(u8, desc[p.len..close], " "), .polymorphic = p[0] == 'C' };
    };
    return .{ .kind = .unknown };
}

/// `(8)`, `(KIND=8)`, `*8`: 8
fn kindOf(d: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, d, '*')) |star| {
        return std.fmt.parseInt(u32, std.mem.trim(u8, d[star + 1 ..], " "), 10) catch null;
    }
    const open = std.mem.indexOfScalar(u8, d, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, d, open, ')') orelse return null;
    var inner = std.mem.trim(u8, d[open + 1 .. close], " ");
    if (std.mem.startsWith(u8, inner, "KIND=")) inner = std.mem.trim(u8, inner[5..], " ");
    return std.fmt.parseInt(u32, inner, 10) catch null;
}

/// `CHARACTER(LEN=10)`, `CHARACTER(10)`, `CHARACTER*10`: 10; `*`, `:`: null
fn charLen(d: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, d, '*')) |star| {
        return std.fmt.parseInt(u32, std.mem.trim(u8, d[star + 1 ..], " ()"), 10) catch null;
    }
    const open = std.mem.indexOfScalar(u8, d, '(') orelse return 1;
    const close = std.mem.indexOfScalarPos(u8, d, open, ')') orelse return null;
    var inner = std.mem.trim(u8, d[open + 1 .. close], " ");
    if (std.mem.indexOf(u8, inner, "LEN=")) |l| {
        inner = inner[l + 4 ..];
        inner = inner[0 .. std.mem.indexOfScalar(u8, inner, ',') orelse inner.len];
    } else if (std.mem.indexOfScalar(u8, inner, ',')) |comma| inner = inner[0..comma];
    return std.fmt.parseInt(u32, std.mem.trim(u8, inner, " "), 10) catch null;
}

/// A dimension: `lo:hi`; deferred (`:`) or assumed (`*`) has no `hi`, and
/// one of a variable (`n`) neither
pub const Dim = struct { lo: ?i64 = 1, hi: ?i64 = null };

/// The dimensions of `DIMENSION(...)`'s text: `3`, `2:3,-1:1`, `:,:`, `*`
pub fn parseDims(a: Allocator, text: []const u8) ![]Dim {
    var out: std.ArrayList(Dim) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) {
                try out.append(a, dim(text[start..i]));
                start = i + 1;
            },
            else => {},
        }
    }
    if (std.mem.trim(u8, text, " ").len > 0) try out.append(a, dim(text[start..]));
    return out.items;
}

fn dim(t: []const u8) Dim {
    const s = std.mem.trim(u8, t, " ");
    if (std.mem.indexOfScalar(u8, s, ':')) |c| {
        const lo = std.mem.trim(u8, s[0..c], " ");
        const hi = std.mem.trim(u8, s[c + 1 ..], " ");
        return .{
            .lo = if (lo.len == 0) null else std.fmt.parseInt(i64, lo, 10) catch null,
            .hi = if (hi.len == 0 or std.mem.eql(u8, hi, "*")) null else std.fmt.parseInt(i64, hi, 10) catch null,
        };
    }
    if (std.mem.eql(u8, s, "*")) return .{ .lo = 1, .hi = null };
    return .{ .lo = 1, .hi = std.fmt.parseInt(i64, s, 10) catch null };
}

/// Whether the dimensions are all known numbers (an explicit shape)
pub fn constantShape(dims: []const Dim) bool {
    for (dims) |d| if (d.lo == null or d.hi == null) return false;
    return dims.len > 0;
}

/// A dimension of an array in memory: its bounds and the bytes between
/// elements
pub const Extent = struct { lo: i64, count: u64, stride: i64 };

/// Intel's array descriptor (ifx, ifort): the data's address, an element's
/// length, an offset, flags, the rank, a reserved word, then for each
/// dimension its extent, its stride in bytes and its lower bound
pub const Descriptor = struct {
    base: u64,
    elem_len: u64,
    flags: u64,
    dims: [7]Extent = undefined,
    rank: u32,

    pub const header_words = 6;

    pub fn bytes(rank: u32) usize {
        return (header_words + 3 * @as(usize, rank)) * 8;
    }

    pub fn parse(words: []const u64) ?Descriptor {
        if (words.len < header_words) return null;
        const rank = words[4];
        if (rank > 7 or words.len < header_words + 3 * rank) return null;
        var d: Descriptor = .{ .base = words[0], .elem_len = words[1], .flags = words[3], .rank = @intCast(rank) };
        for (0..d.rank) |i| d.dims[i] = .{
            .count = words[header_words + 3 * i],
            .stride = @bitCast(words[header_words + 3 * i + 1]),
            .lo = @bitCast(words[header_words + 3 * i + 2]),
        };
        return d;
    }

    /// Not allocated, not associated
    pub fn empty(d: Descriptor) bool {
        return d.base == 0;
    }
};

/// The extents of an explicit-shape array, contiguous, of `elem` bytes
pub fn contiguous(dims: []const Dim, elem: u64, out: []Extent) []Extent {
    var stride: i64 = @intCast(elem);
    for (dims, 0..) |d, i| {
        const count: u64 = @intCast(@max(0, d.hi.? - d.lo.? + 1));
        out[i] = .{ .lo = d.lo.?, .count = count, .stride = stride };
        stride *= @intCast(count);
    }
    return out[0..dims.len];
}

// Values

/// A scalar as Fortran writes it, from its bytes
pub fn scalar(a: Allocator, t: Type, b: []const u8) ![]const u8 {
    switch (t.kind) {
        .integer => return switch (b.len) {
            1 => a.print("{d}", .{@as(i8, @bitCast(b[0]))}),
            2 => a.print("{d}", .{std.mem.readInt(i16, b[0..2], .little)}),
            4 => a.print("{d}", .{std.mem.readInt(i32, b[0..4], .little)}),
            8 => a.print("{d}", .{std.mem.readInt(i64, b[0..8], .little)}),
            else => hex(a, b),
        },
        .real => return real(a, b),
        .complex => {
            const half = b.len / 2;
            return a.print("({s}, {s})", .{ try real(a, b[0..half]), try real(a, b[half..]) });
        },
        // Intel's: true when the lowest bit is set
        .logical => return if (b.len > 0 and b[0] & 1 == 1) ".TRUE." else ".FALSE.",
        .character => return a.print("'{s}'", .{b}),
        .derived, .unknown => return hex(a, b),
    }
}

fn real(a: Allocator, b: []const u8) ![]const u8 {
    const text = switch (b.len) {
        4 => try a.print("{d}", .{@as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .little)))}),
        8 => try a.print("{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little)))}),
        else => return hex(a, b),
    };
    // `6` -> `6.0`, as Fortran writes a real
    for (text) |c| if (c == '.' or c == 'e' or c == 'n' or c == 'i') return text;
    return a.print("{s}.0", .{text});
}

fn hex(a: Allocator, b: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "0x");
    var i = b.len;
    while (i > 0) : (i -= 1) try out.print(a, "{x:0>2}", .{b[i - 1]});
    return out.items;
}

/// The subscripts of an element: `(2)`, `(2,-1)`; of a column, `(:,-1)`
pub fn subscripts(a: Allocator, rank: usize, chosen: []const i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '(');
    for (0..rank - chosen.len) |i| {
        if (i > 0) try out.append(a, ',');
        try out.append(a, ':');
    }
    for (chosen, 0..) |c, i| {
        if (i > 0 or chosen.len < rank) try out.append(a, ',');
        try out.print(a, "{d}", .{c});
    }
    try out.append(a, ')');
    return out.items;
}

/// `[1.0, 2.0, 3.0]`, `[1.0, 2.0, …]`
pub fn preview(a: Allocator, values: []const []const u8, total: u64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    const shown = @min(values.len, 6);
    for (values[0..shown], 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, v);
    }
    if (total > shown) try out.appendSlice(a, ", …");
    try out.append(a, ']');
    return out.items;
}

/// `[2×3]`
pub fn shape(a: Allocator, extents: []const Extent) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (extents, 0..) |e, i| {
        if (i > 0) try out.appendSlice(a, "×");
        try out.print(a, "{d}", .{e.count});
    }
    try out.append(a, ']');
    return out.items;
}

test "types of declarations" {
    try std.testing.expectEqual(Type{ .kind = .real, .size = 8 }, parseType("REAL(8)"));
    try std.testing.expectEqual(Type{ .kind = .real, .size = 8 }, parseType("real(kind=8)"));
    try std.testing.expectEqual(Type{ .kind = .real, .size = 8 }, parseType("DOUBLE PRECISION"));
    try std.testing.expectEqual(Type{ .kind = .integer, .size = 4 }, parseType("INTEGER"));
    try std.testing.expectEqual(Type{ .kind = .integer, .size = 2 }, parseType("INTEGER*2"));
    try std.testing.expectEqual(Type{ .kind = .complex, .size = 8 }, parseType("COMPLEX"));
    try std.testing.expectEqual(Type{ .kind = .complex, .size = 16 }, parseType("COMPLEX(8)"));
    try std.testing.expectEqual(Type{ .kind = .logical, .size = 4 }, parseType("LOGICAL"));
    try std.testing.expectEqual(@as(u32, 10), parseType("CHARACTER(LEN=10)").size);
    try std.testing.expectEqual(@as(u32, 5), parseType("character*5").size);
    try std.testing.expectEqual(@as(u32, 0), parseType("CHARACTER(LEN=*)").size);
    try std.testing.expectEqual(@as(u32, 1), parseType("CHARACTER").size);
    const t = parseType("CLASS(point)");
    try std.testing.expectEqual(Kind.derived, t.kind);
    try std.testing.expectEqualStrings("point", t.name);
    try std.testing.expect(t.polymorphic);
}

test "dimensions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseDims(a, "2:3, -1:1");
    try std.testing.expectEqual(@as(usize, 2), d.len);
    try std.testing.expectEqual(Dim{ .lo = 2, .hi = 3 }, d[0]);
    try std.testing.expectEqual(Dim{ .lo = -1, .hi = 1 }, d[1]);
    try std.testing.expect(constantShape(d));
    const deferred = try parseDims(a, ":,:");
    try std.testing.expectEqual(Dim{ .lo = null, .hi = null }, deferred[1]);
    try std.testing.expect(!constantShape(deferred));
    try std.testing.expect(!constantShape(try parseDims(a, "n")));
    try std.testing.expectEqual(Dim{ .lo = 1, .hi = null }, (try parseDims(a, "*"))[0]);
    try std.testing.expectEqual(@as(usize, 1), (try parseDims(a, "size(x, 1)")).len);
    var ext: [7]Extent = undefined;
    const c = contiguous(d, 4, &ext);
    try std.testing.expectEqual(Extent{ .lo = 2, .count = 2, .stride = 4 }, c[0]);
    try std.testing.expectEqual(Extent{ .lo = -1, .count = 3, .stride = 8 }, c[1]);
}

test "Intel's descriptor" {
    // ifx's of b(2,3), integer: from a program stopped in the debugger
    const words = [_]u64{ 0x7ff6cfe14380, 4, 0, 1, 2, 0, 2, 4, 1, 3, 8, 1 };
    const d = Descriptor.parse(&words).?;
    try std.testing.expectEqual(@as(u32, 2), d.rank);
    try std.testing.expectEqual(Extent{ .lo = 1, .count = 3, .stride = 8 }, d.dims[1]);
    try std.testing.expect(!d.empty());
    try std.testing.expectEqual(@as(usize, 96), Descriptor.bytes(2));
}

test "values as Fortran writes them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: [8]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], @bitCast(@as(f32, 6.0)), .little);
    try std.testing.expectEqualStrings("6.0", try scalar(a, .{ .kind = .real, .size = 4 }, b[0..4]));
    std.mem.writeInt(u64, &b, @bitCast(@as(f64, 1.5)), .little);
    try std.testing.expectEqualStrings("1.5", try scalar(a, .{ .kind = .real, .size = 8 }, &b));
    std.mem.writeInt(i32, b[0..4], -20, .little);
    try std.testing.expectEqualStrings("-20", try scalar(a, .{ .kind = .integer, .size = 4 }, b[0..4]));
    std.mem.writeInt(u32, b[0..4], @bitCast(@as(f32, 1.0)), .little);
    std.mem.writeInt(u32, b[4..8], @bitCast(@as(f32, -2.0)), .little);
    try std.testing.expectEqualStrings("(1.0, -2.0)", try scalar(a, .{ .kind = .complex, .size = 8 }, &b));
    try std.testing.expectEqualStrings(".TRUE.", try scalar(a, .{ .kind = .logical, .size = 4 }, &[_]u8{ 0xff, 0xff, 0xff, 0xff }));
    try std.testing.expectEqualStrings(".FALSE.", try scalar(a, .{ .kind = .logical, .size = 4 }, &[_]u8{ 0, 0, 0, 0 }));
    try std.testing.expectEqualStrings("'abc'", try scalar(a, .{ .kind = .character, .size = 3 }, "abc"));
    try std.testing.expectEqualStrings("(2)", try subscripts(a, 1, &.{2}));
    try std.testing.expectEqualStrings("(2,-1)", try subscripts(a, 2, &.{ 2, -1 }));
    try std.testing.expectEqualStrings("(:,-1)", try subscripts(a, 2, &.{-1}));
    try std.testing.expectEqualStrings("[1.0, 2.0]", try preview(a, &.{ "1.0", "2.0" }, 2));
    try std.testing.expectEqualStrings("[1, 2, 3, 4, 5, 6, …]", try preview(a, &.{ "1", "2", "3", "4", "5", "6", "7" }, 100));
    try std.testing.expectEqualStrings("[2×3]", try shape(a, &.{ .{ .lo = 1, .count = 2, .stride = 4 }, .{ .lo = 1, .count = 3, .stride = 8 } }));
}
