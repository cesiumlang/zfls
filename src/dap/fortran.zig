//! Fortran in gdb, for `zfls dap`'s gdb backend (gdb_variables.zig): gdb's
//! variables read as Fortran. The bounds of an array from gdb's type
//! string, the names and expressions of its elements and sections,
//! previews of values, the hidden arguments to leave out, the dynamic type
//! of a polymorphic object, and the runtime's error functions. Pure
//! functions: no gdb here.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A dimension of an array: `lo:hi`; `:` (deferred: not allocated, not
/// associated) has neither, `*` (assumed size) no `hi`
pub const Dim = struct {
    lo: ?i64 = null,
    hi: ?i64 = null,
};

/// An array as gdb's type string gives it: `real(kind=4), allocatable (2:3,-1:1)`
pub const ArrayType = struct {
    /// The type of its elements, without `, allocatable`
    element: []const u8,
    allocatable: bool,
    dims: []const Dim,
};

/// The array of a gdb type string, or null for a scalar
pub fn arrayType(a: Allocator, type_: ?[]const u8) !?ArrayType {
    const t = type_ orelse return null;
    if (t.len == 0 or t[t.len - 1] != ')') return null;
    const open = std.mem.findScalarLast(u8, t, '(') orelse return null;
    const inner = t[open + 1 .. t.len - 1];
    if (std.mem.findAny(u8, inner, "()") != null) return null;
    // `(.*\S)\s+` before the parenthesis
    const head = std.mem.trimEnd(u8, t[0..open], " \t");
    if (head.len == 0 or head.len == t[0..open].len) return null;
    var dims: std.ArrayList(Dim) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| try dims.append(a, parseDim(std.mem.trim(u8, raw, " \t")) orelse return null);
    const suffix = ", allocatable";
    var element_type = head;
    var allocatable = false;
    if (std.mem.findScalarLast(u8, head, ',')) |comma| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, head[comma + 1 ..], " \t"), suffix[2..])) {
            element_type = head[0..comma];
            allocatable = true;
        }
    }
    return .{ .element = element_type, .allocatable = allocatable, .dims = dims.items };
}

/// `3`, `2:3`, `:`, `*`, `0:*`
fn parseDim(d: []const u8) ?Dim {
    if (std.mem.eql(u8, d, ":")) return .{};
    if (std.mem.eql(u8, d, "*")) return .{ .lo = 1 };
    if (std.mem.findScalar(u8, d, ':')) |colon| {
        const lo = parseBound(d[0..colon]) orelse return null;
        if (std.mem.eql(u8, d[colon + 1 ..], "*")) return .{ .lo = lo };
        return .{ .lo = lo, .hi = parseBound(d[colon + 1 ..]) orelse return null };
    }
    return .{ .lo = 1, .hi = parseBound(d) orelse return null };
}

/// `-?\d+`
fn parseBound(s: []const u8) ?i64 {
    const digits = if (s.len > 0 and s[0] == '-') s[1..] else s;
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// Whether the array has no elements to show: deferred-shape and not
/// allocated or not associated
pub fn isUnallocated(t: ArrayType) bool {
    for (t.dims) |d| if (d.lo != null) return false;
    return true;
}

/// The extent of a dimension, when known
pub fn extent(d: Dim) ?u64 {
    const lo = d.lo orelse return null;
    const hi = d.hi orelse return null;
    return @intCast(@max(0, hi - lo + 1));
}

/// Where a node is in an array: its expression, the array's dimensions,
/// and the subscripts already chosen for its last ones. gdb gives an array
/// of rank n as its last dimension's elements, each of rank n-1.
pub const ArrayContext = struct {
    /// The array's expression, when it has one
    expr: ?[]const u8 = null,
    dims: []const Dim,
    /// Subscripts of the last dimensions, outermost last
    fixed: []const []const u8 = &.{},
    /// For the elements of a section (`a(:,101:200)`), which gdb numbers
    /// from 1 in each dimension: what to add to gdb's name, by dimension
    offsets: ?[]const i64 = null,

    /// A copy whose slices are `a`'s
    pub fn dupe(ctx: ArrayContext, a: Allocator) !ArrayContext {
        const fixed = try a.alloc([]const u8, ctx.fixed.len);
        for (ctx.fixed, fixed) |f, *o| o.* = try a.dupe(u8, f);
        return .{
            .expr = if (ctx.expr) |e| try a.dupe(u8, e) else null,
            .dims = try a.dupe(Dim, ctx.dims),
            .fixed = fixed,
            .offsets = if (ctx.offsets) |o| try a.dupe(i64, o) else null,
        };
    }
};

/// The rank of the node an array context describes
pub fn rankOf(ctx: ArrayContext) usize {
    return ctx.dims.len -| ctx.fixed.len;
}

fn offsetOf(ctx: ArrayContext) ?i64 {
    const offsets = ctx.offsets orelse return null;
    const rank = rankOf(ctx);
    if (rank == 0 or rank - 1 >= offsets.len) return null;
    return offsets[rank - 1];
}

/// The subscript of gdb's `name` for an element of the node of `ctx`
fn subscript(a: Allocator, ctx: ArrayContext, name: []const u8) ![]const u8 {
    const offset = offsetOf(ctx) orelse return name;
    const n = parseBound(name) orelse return name;
    return a.print("{d}", .{n + offset});
}

/// The subscript of the first element of the node
fn firstIndex(ctx: ArrayContext) i64 {
    if (offsetOf(ctx)) |o| return o + 1;
    return indexedDim(ctx).lo orelse 1;
}

/// The node's dimension that its children index: the last not chosen
pub fn indexedDim(ctx: ArrayContext) Dim {
    const rank = rankOf(ctx);
    return if (rank > 0 and rank - 1 < ctx.dims.len) ctx.dims[rank - 1] else .{};
}

pub const Element = struct {
    /// `(2)`, `(2,-1)`, `(:,-1)`
    name: []const u8,
    evaluate_name: ?[]const u8,
    /// For an element that is itself an array (a column): its context
    sub: ?ArrayContext,
};

/// `(:,:,s,fixed...)`: the subscripts of a node's child
fn subscriptList(a: Allocator, rank: usize, s: []const u8, fixed: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '(');
    for (1..@max(rank, 1)) |_| try out.appendSlice(a, ":,");
    try out.appendSlice(a, s);
    for (fixed) |f| try out.print(a, ",{s}", .{f});
    try out.append(a, ')');
    return out.items;
}

/// The name, expression and context of gdb's child `name` of an array node
pub fn element(a: Allocator, ctx: ArrayContext, name: []const u8) !Element {
    const rank = rankOf(ctx);
    const s = try subscript(a, ctx, name);
    const list = try subscriptList(a, rank, s, ctx.fixed);
    var sub: ?ArrayContext = null;
    if (rank > 1) {
        const fixed = try a.alloc([]const u8, ctx.fixed.len + 1);
        fixed[0] = s;
        @memcpy(fixed[1..], ctx.fixed);
        sub = .{ .expr = ctx.expr, .dims = ctx.dims, .fixed = fixed, .offsets = ctx.offsets };
    }
    return .{
        .name = list,
        .evaluate_name = if (ctx.expr) |e| try a.print("{s}{s}", .{ e, list }) else null,
        .sub = sub,
    };
}

pub const Chunk = struct {
    /// 0-based position of its first element
    start: u64,
    count: u64,
};

/// Arrays of more elements are shown in sections
pub const chunk_size = 100;

/// The chunks a node of `count` elements is shown in: none up to 100,
/// else at most 100 chunks of a power of 100
pub fn chunks(a: Allocator, count: u64) ![]Chunk {
    if (count <= chunk_size) return &.{};
    var per: u64 = chunk_size;
    while (count > per * chunk_size) per *= chunk_size;
    var out: std.ArrayList(Chunk) = .empty;
    var start: u64 = 0;
    while (start < count) : (start += per) try out.append(a, .{ .start = start, .count = @min(per, count - start) });
    return out.items;
}

pub const Section = struct { name: []const u8, evaluate_name: ?[]const u8 };

/// The section of a chunk of a node: its subscripts (`(:,101:200)`), and
/// its expression when the array has one
pub fn chunkSection(a: Allocator, ctx: ArrayContext, c: Chunk) !Section {
    const lo = firstIndex(ctx) + @as(i64, @intCast(c.start));
    const range = try a.print("{d}:{d}", .{ lo, lo + @as(i64, @intCast(c.count)) - 1 });
    const list = try subscriptList(a, rankOf(ctx), range, ctx.fixed);
    return .{ .name = list, .evaluate_name = if (ctx.expr) |e| try a.print("{s}{s}", .{ e, list }) else null };
}

/// The context of the elements of a chunk's section, which gdb numbers
/// from 1 in each of its dimensions
pub fn chunkContext(a: Allocator, ctx: ArrayContext, c: Chunk) !ArrayContext {
    const rank = rankOf(ctx);
    const offsets = try a.alloc(i64, ctx.dims.len);
    for (ctx.dims, 0..) |d, i| {
        offsets[i] = if (rank > 0 and i == rank - 1)
            firstIndex(ctx) + @as(i64, @intCast(c.start)) - 1
        else if (ctx.offsets != null and i < ctx.offsets.?.len)
            ctx.offsets.?[i]
        else
            (d.lo orelse 1) - 1;
    }
    var out = ctx;
    out.offsets = offsets;
    return out;
}

// Values

/// A type as Fortran names it: the C types gdb gives the values of
/// expressions (`a(2) + 1`) translated
pub fn fortranType(type_: ?[]const u8) ?[]const u8 {
    const t = type_ orelse return null;
    const c_types = [_][2][]const u8{
        .{ "int", "integer(kind=4)" },
        .{ "long", "integer(kind=8)" },
        .{ "long long", "integer(kind=8)" },
        .{ "float", "real(kind=4)" },
        .{ "double", "real(kind=8)" },
        .{ "long double", "real(kind=10)" },
    };
    for (c_types) |c| if (std.mem.eql(u8, t, c[0])) return c[1];
    return t;
}

/// A real or complex value as Fortran writes it: `6` -> `6.0`
pub fn fortranNumber(a: Allocator, value: []const u8, type_: ?[]const u8) ![]const u8 {
    const t = type_ orelse "";
    if (startsWithIgnoreCase(t, "real")) return real(a, value);
    if (startsWithIgnoreCase(t, "complex")) {
        const v = std.mem.trim(u8, value, " \t\r\n");
        if (v.len < 2 or v[0] != '(' or v[v.len - 1] != ')') return value;
        // the last comma: `(.*),(.*)`
        const comma = std.mem.findScalarLast(u8, v, ',') orelse return value;
        return a.print("({s}, {s})", .{ try real(a, v[1..comma]), try real(a, v[comma + 1 .. v.len - 1]) });
    }
    return value;
}

fn real(a: Allocator, v: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    const digits = if (t.len > 0 and (t[0] == '-' or t[0] == '+')) t[1..] else t;
    if (digits.len == 0) return t;
    for (digits) |c| if (!std.ascii.isDigit(c)) return t;
    return a.print("{s}.0", .{t});
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The previews of values: what an array or a derived type shows before
/// it is expanded
const max_preview = 6;

/// `[1.0, 2.0, 3.0]`, `[1.0, 2.0, …]`
pub fn arrayPreview(a: Allocator, shown_values: []const []const u8, total: u64) ![]const u8 {
    const shown = shown_values[0..@min(shown_values.len, max_preview)];
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (shown, 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, v);
    }
    if (total > shown.len) try out.appendSlice(a, ", …");
    try out.append(a, ']');
    return out.items;
}

/// The shape of an array of rank 2 or more: `[2×3]`
pub fn shapePreview(a: Allocator, dims: []const Dim) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (dims, 0..) |d, i| {
        if (i > 0) try out.appendSlice(a, "×");
        if (extent(d)) |e| try out.print(a, "{d}", .{e}) else try out.append(a, '?');
    }
    try out.append(a, ']');
    return out.items;
}

pub const Component = struct { name: []const u8, value: []const u8 };

/// `point(x=9.0, y=-2.0, id=7)`
pub fn structPreview(a: Allocator, type_name: []const u8, components: []const Component) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}(", .{type_name});
    for (components[0..@min(components.len, 4)], 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "{s}={s}", .{ c.name, c.value });
    }
    if (components.len > 4) try out.appendSlice(a, ", …");
    try out.append(a, ')');
    return out.items;
}

/// The name of a derived type of a gdb type string: `Type point` -> `point`
pub fn derivedTypeName(type_: ?[]const u8) ?[]const u8 {
    const t = type_ orelse return null;
    if (!std.mem.startsWith(u8, t, "Type ")) return null;
    const name = t["Type ".len..];
    if (name.len == 0 or std.mem.findAny(u8, name, " \t\r\n") != null) return null;
    return if (std.mem.startsWith(u8, name, "__class_")) null else name;
}

/// The type a gdb pointer points to: `PTR TO -> ( character*7 )`
pub fn pointerTarget(type_: ?[]const u8) ?[]const u8 {
    const t = type_ orelse return null;
    const head = "PTR TO -> ( ";
    if (!std.mem.startsWith(u8, t, head) or !std.mem.endsWith(u8, t, " )") or t.len < head.len + 2) return null;
    return t[head.len .. t.len - 2];
}

/// Whether a pointer's value is null
pub fn isNullPointer(value: []const u8) bool {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len < 3 or v[0] != '0' or (v[1] != 'x' and v[1] != 'X')) return false;
    var i: usize = 2;
    while (i < v.len and v[i] == '0') i += 1;
    return i > 2 and (i == v.len or std.ascii.isWhitespace(v[i]));
}

pub const Named = struct { name: []const u8, type: ?[]const u8 };

/// Whether a variable is gfortran's hidden length of a CHARACTER argument
/// (`_s` for `s`), which the program never names
pub fn isHiddenLength(name: []const u8, siblings: []const Named) bool {
    if (name.len < 2 or name[0] != '_') return false;
    const of = name[1..];
    for (of) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    for (siblings) |s| if (std.ascii.eqlIgnoreCase(s.name, of)) {
        return std.ascii.findIgnoreCase(s.type orelse "", "character") != null;
    };
    return false;
}

// Polymorphic objects (CLASS)

/// Whether a gdb type is gfortran's wrapper of a polymorphic object, whose
/// components are `_data` (the object) and `_vptr` (its dynamic type)
pub fn isClassWrapper(type_: ?[]const u8) bool {
    return std.mem.startsWith(u8, type_ orelse "", "Type __class_");
}

pub const DynamicType = struct { module: []const u8, name: []const u8 };

/// The dynamic type of a polymorphic object, from its `_vptr` value
/// (`0x7ff6... <__grid_MOD___vtab_grid_Tagged>`): the type's module and
/// name, for gdb's `module::type`; null for an intrinsic type or one
/// outside a module
pub fn dynamicType(a: Allocator, vptr_value: []const u8) !?DynamicType {
    const lt = std.mem.find(u8, vptr_value, "<__") orelse return null;
    const gt = std.mem.findScalarPos(u8, vptr_value, lt, '>') orelse return null;
    const inner = vptr_value[lt + 3 .. gt];
    for (inner) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    // `(\w+?)_MOD___vtab_(\w+)`: the first `_MOD___vtab_`
    const mark = "_MOD___vtab_";
    const at = std.mem.find(u8, inner, mark) orelse return null;
    if (at == 0) return null;
    const module = inner[0..at];
    const rest = inner[at + mark.len ..];
    if (rest.len <= module.len + 1 or !startsWithIgnoreCase(rest, module) or rest[module.len] != '_') return null;
    return .{ .module = module, .name = try std.ascii.allocLowerString(a, rest[module.len + 1 ..]) };
}

/// The address of a pointer value: `0x7ff6c1d640c0 <tg>` -> `0x7ff6c1d640c0`
pub fn addressOf(value: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len < 3 or v[0] != '0' or (v[1] != 'x' and v[1] != 'X')) return null;
    var i: usize = 2;
    while (i < v.len and std.ascii.isHex(v[i])) i += 1;
    return if (i > 2) v[0..i] else null;
}

/// The gdb command that sets the convenience variable `$name` to the
/// object at `address` as a pointer to its dynamic type
pub fn castCommand(a: Allocator, variable: []const u8, address: []const u8, t: DynamicType) ![]const u8 {
    const type_name = try a.print("{s}::{s}", .{ t.module, t.name });
    return a.print("python gdb.set_convenience_variable({f}, gdb.Value({s}).cast(gdb.lookup_type({f}).pointer()))", .{
        std.json.fmt(variable, .{}), address, std.json.fmt(type_name, .{}),
    });
}

// Errors at run time

/// The functions of the Fortran runtimes that a program calls on an error
/// (an array bound exceeded with `-fcheck=bounds`, a failed allocation, an
/// I/O error without `iostat=`) or `ERROR STOP`: gfortran's, LLVM Flang's,
/// Intel's
pub const runtime_error_functions = [_][]const u8{
    "_gfortran_runtime_error",
    "_gfortran_runtime_error_at",
    "_gfortran_os_error",
    "_gfortran_os_error_at",
    "_gfortran_error_stop_string",
    "_gfortran_error_stop_numeric",
    "_FortranAReportFatalUserError",
    "for__issue_diagnostic",
};

/// Whether a runtime function is one of `ERROR STOP`
pub fn isErrorStop(function: []const u8) bool {
    return std.ascii.findIgnoreCase(function, "error_stop") != null;
}

// gdb itself

/// gdb's version of `gdb --version`, the end of its first line:
/// `GNU gdb (GDB) 17.2` -> 17.2
pub fn gdbVersion(text: []const u8) ?[2]u32 {
    const line = std.mem.trimEnd(u8, text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len], " \t\r");
    if (!std.mem.startsWith(u8, line, "GNU gdb")) return null;
    if (line.len > "GNU gdb".len and (std.ascii.isAlphanumeric(line[7]) or line[7] == '_')) return null;
    const space = std.mem.findLastAny(u8, line, " \t") orelse return null;
    const last = line[space + 1 ..];
    const dot = std.mem.findScalar(u8, last, '.') orelse return null;
    var end = dot + 1;
    while (end < last.len and std.ascii.isDigit(last[end])) end += 1;
    if (end == dot + 1) return null;
    const major = std.fmt.parseInt(u32, last[0..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u32, last[dot + 1 .. end], 10) catch return null;
    return .{ major, minor };
}

test "arrays of gdb's type strings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = (try arrayType(a, "real(kind=4) (3)")).?;
    try std.testing.expectEqualStrings("real(kind=4)", v.element);
    try std.testing.expect(!v.allocatable);
    try std.testing.expectEqualDeep(@as([]const Dim, &.{.{ .lo = 1, .hi = 3 }}), v.dims);
    try std.testing.expectEqualDeep(@as([]const Dim, &.{ .{ .lo = 2, .hi = 3 }, .{ .lo = -1, .hi = 1 } }), (try arrayType(a, "integer(kind=4) (2:3,-1:1)")).?.dims);
    const unallocated = (try arrayType(a, "real(kind=4), allocatable (:)")).?;
    try std.testing.expect(unallocated.allocatable);
    try std.testing.expectEqualStrings("real(kind=4)", unallocated.element);
    try std.testing.expect(isUnallocated(unallocated));
    try std.testing.expect(isUnallocated((try arrayType(a, "real(kind=4) (:,:)")).?));
    try std.testing.expect(!isUnallocated((try arrayType(a, "real(kind=4), allocatable (2,3)")).?));
    try std.testing.expectEqualDeep(@as([]const Dim, &.{.{ .lo = 0 }}), (try arrayType(a, "real(kind=8) (0:*)")).?.dims);
    try std.testing.expectEqualDeep(@as([]const Dim, &.{.{ .lo = 1, .hi = 2 }}), (try arrayType(a, "character*5 (2)")).?.dims);
    // scalars
    try std.testing.expect(try arrayType(a, "real(kind=4)") == null);
    try std.testing.expect(try arrayType(a, "Type point") == null);
    try std.testing.expect(try arrayType(a, "character*8") == null);
    try std.testing.expect(try arrayType(a, null) == null);
}

test "elements by their subscripts, columns of arrays" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v: ArrayContext = .{ .expr = "v", .dims = &.{.{ .lo = 1, .hi = 3 }} };
    const e = try element(a, v, "2");
    try std.testing.expectEqualStrings("(2)", e.name);
    try std.testing.expectEqualStrings("v(2)", e.evaluate_name.?);
    try std.testing.expect(e.sub == null);
    // gdb gives m(2:3,-1:1) as its columns m(:,-1), m(:,0), m(:,1)
    const m: ArrayContext = .{ .expr = "m", .dims = &.{ .{ .lo = 2, .hi = 3 }, .{ .lo = -1, .hi = 1 } } };
    const column = try element(a, m, "-1");
    try std.testing.expectEqualStrings("(:,-1)", column.name);
    try std.testing.expectEqualStrings("m(:,-1)", column.evaluate_name.?);
    const el = try element(a, column.sub.?, "3");
    try std.testing.expectEqualStrings("(3,-1)", el.name);
    try std.testing.expectEqualStrings("m(3,-1)", el.evaluate_name.?);
    try std.testing.expect(el.sub == null);
    // no expression: names only
    try std.testing.expect((try element(a, .{ .dims = &.{.{ .lo = 1, .hi = 2 }} }, "1")).evaluate_name == null);
}

test "large arrays in sections" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try chunks(a, 100)).len);
    try std.testing.expectEqualDeep(@as([]const Chunk, &.{ .{ .start = 0, .count = 100 }, .{ .start = 100, .count = 100 }, .{ .start = 200, .count = 50 } }), try chunks(a, 250));
    // at most 100 sections: of 10000 for a million
    const big = try chunks(a, 1_000_000);
    try std.testing.expectEqual(@as(usize, 100), big.len);
    try std.testing.expectEqual(@as(u64, 10000), big[0].count);
    const arr: ArrayContext = .{ .expr = "a", .dims = &.{.{ .lo = 0, .hi = 999 }} };
    const s = try chunkSection(a, arr, .{ .start = 100, .count = 100 });
    try std.testing.expectEqualStrings("(100:199)", s.name);
    try std.testing.expectEqualStrings("a(100:199)", s.evaluate_name.?);
    // gdb numbers a section's elements from 1
    const section = try chunkContext(a, arr, .{ .start = 100, .count = 100 });
    try std.testing.expectEqualStrings("a(100)", (try element(a, section, "1")).evaluate_name.?);
    try std.testing.expectEqualStrings("(199)", (try element(a, section, "100")).name);
    // a section of a section
    try std.testing.expectEqualStrings("(110:114)", (try chunkSection(a, section, .{ .start = 10, .count = 5 })).name);
    // the columns of a matrix of many columns, by their bounds
    const m: ArrayContext = .{ .expr = "m", .dims = &.{ .{ .lo = 2, .hi = 3 }, .{ .lo = 1, .hi = 500 } } };
    try std.testing.expectEqualStrings("m(:,201:300)", (try chunkSection(a, m, .{ .start = 200, .count = 100 })).evaluate_name.?);
    const columns = try chunkContext(a, m, .{ .start = 200, .count = 100 });
    const column = try element(a, columns, "1");
    try std.testing.expectEqualStrings("(:,201)", column.name);
    try std.testing.expectEqualStrings("m(2,201)", (try element(a, column.sub.?, "1")).evaluate_name.?);
}

test "values as Fortran writes them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const eq = std.testing.expectEqualStrings;
    try eq("6.0", try fortranNumber(a, "6", "real(kind=4)"));
    try eq("-2.0", try fortranNumber(a, "-2", "real(kind=8)"));
    try eq("1.5", try fortranNumber(a, "1.5", "real(kind=4)"));
    try eq("inf", try fortranNumber(a, "inf", "real(kind=4)"));
    try eq("(1.0, -2.0)", try fortranNumber(a, "(1,-2)", "complex(kind=4)"));
    try eq("6", try fortranNumber(a, "6", "integer(kind=4)"));
    try eq(".TRUE.", try fortranNumber(a, ".TRUE.", "logical(kind=4)"));
    try eq("real(kind=8)", fortranType("double").?);
    try eq("Type point", fortranType("Type point").?);
    try eq("[1.0, 2.0]", try arrayPreview(a, &.{ "1.0", "2.0" }, 2));
    try eq("[1, 2, 3, 4, 5, 6, …]", try arrayPreview(a, &.{ "1", "2", "3", "4", "5", "6", "7" }, 1000));
    try eq("[2×3]", try shapePreview(a, &.{ .{ .lo = 2, .hi = 3 }, .{ .lo = -1, .hi = 1 } }));
    try eq("[?]", try shapePreview(a, &.{.{ .lo = 1 }}));
    try eq("point(x=9.0, id=7)", try structPreview(a, "point", &.{ .{ .name = "x", .value = "9.0" }, .{ .name = "id", .value = "7" } }));
    const five = [_]Component{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "1" }, .{ .name = "c", .value = "1" }, .{ .name = "d", .value = "1" }, .{ .name = "e", .value = "1" } };
    try eq("t(a=1, b=1, c=1, d=1, …)", try structPreview(a, "t", &five));
    try eq("point", derivedTypeName("Type point").?);
    try std.testing.expect(derivedTypeName("Type __class_grid_Point_t") == null);
    try std.testing.expect(derivedTypeName("real(kind=4)") == null);
    try eq("character*7", pointerTarget("PTR TO -> ( character*7 )").?);
    try std.testing.expect(pointerTarget("real(kind=4)") == null);
    try std.testing.expect(isNullPointer("0x0"));
    try std.testing.expect(isNullPointer("0x0000 <x>"));
    try std.testing.expect(!isNullPointer("0x7ff63be140c0 <tg>"));
}

test "gfortran's hidden lengths of CHARACTER arguments" {
    const args = [_]Named{
        .{ .name = "s", .type = "character*6" },
        .{ .name = "n", .type = "integer(kind=4)" },
        .{ .name = "_s", .type = "integer(kind=8)" },
        .{ .name = "_n", .type = "integer(kind=8)" },
    };
    try std.testing.expect(isHiddenLength("_s", &args));
    try std.testing.expect(!isHiddenLength("_n", &args));
    try std.testing.expect(!isHiddenLength("s", &args));
}

test "the dynamic type of a polymorphic object" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(isClassWrapper("Type __class_grid_Point_t"));
    try std.testing.expect(!isClassWrapper("Type point"));
    try std.testing.expectEqualDeep(DynamicType{ .module = "grid", .name = "tagged" }, (try dynamicType(a, "0x7ff63be14040 <__grid_MOD___vtab_grid_Tagged>")).?);
    try std.testing.expectEqualDeep(DynamicType{ .module = "my_mod", .name = "my_type" }, (try dynamicType(a, "0x1 <__my_mod_MOD___vtab_my_mod_My_type>")).?);
    // intrinsic types, and those of no module
    try std.testing.expect(try dynamicType(a, "0x1 <__vtab_INTEGER_4_>") == null);
    try std.testing.expect(try dynamicType(a, "0x0") == null);
    try std.testing.expectEqualStrings("0x7ff6c1d640c0", addressOf("0x7ff6c1d640c0 <tg>").?);
    try std.testing.expectEqualStrings(
        "python gdb.set_convenience_variable(\"zfls_1\", gdb.Value(0x10).cast(gdb.lookup_type(\"grid::tagged\").pointer()))",
        try castCommand(a, "zfls_1", "0x10", .{ .module = "grid", .name = "tagged" }),
    );
    try std.testing.expect(isErrorStop("_gfortran_error_stop_string"));
    try std.testing.expect(!isErrorStop("_gfortran_runtime_error_at"));
}

test "gdb's version" {
    try std.testing.expectEqual([2]u32{ 17, 2 }, gdbVersion("GNU gdb (GDB) 17.2\nCopyright").?);
    try std.testing.expectEqual([2]u32{ 15, 0 }, gdbVersion("GNU gdb (Ubuntu 15.0.50.20240403-0ubuntu1) 15.0.50.20240403-git").?);
    try std.testing.expectEqual([2]u32{ 12, 1 }, gdbVersion("GNU gdb (GDB; SUSE Linux Enterprise 15) 12.1").?);
    try std.testing.expectEqual([2]u32{ 14, 1 }, gdbVersion("GNU gdb (Fedora Linux) 14.1-2.fc39\r\nCopyright").?);
    try std.testing.expect(gdbVersion("lldb version 21") == null);
}
