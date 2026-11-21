//! gfortran's module files as Fortran (#544): a `.mod` of gfortran's is
//! gzip of `GFORTRAN module version 'N' created from F`, then
//! S-expressions (gfortran_mod/sexpr.zig): the generic interfaces, the
//! symbols (`ID 'name' 'module' 'binding' NS (attributes components
//! type ...)`) and the public names. zfls writes the module's interface as
//! free-form source, which it indexes as it does Flang's module files
//! (server/modfiles.zig): its public types (components, type-bound
//! procedures), variables and named constants (type, kind, rank,
//! ALLOCATABLE, POINTER, TARGET, the value of an integer or real
//! constant), generic interfaces and module procedures with their dummy
//! arguments. Read from gfortran 16.1's files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sexpr = @import("gfortran_mod/sexpr.zig");
const Node = sexpr.Node;

const header = "GFORTRAN module version '";

/// Whether `head`, the beginning of a file, is gzip's (a gfortran module
/// file, or any other)
pub fn isGzip(head: []const u8) bool {
    return head.len >= 2 and head[0] == 0x1f and head[1] == 0x8b;
}

/// The text of the gzip file `data`, null when it is no gzip
pub fn gunzip(a: Allocator, data: []const u8) !?[]const u8 {
    if (!isGzip(data)) return null;
    var in: std.Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(a);
    _ = inflate.reader.streamRemaining(&out.writer) catch |e| return if (e == error.WriteFailed) error.OutOfMemory else null;
    return out.written();
}

const Sym = struct { id: i64, name: []const u8, module: []const u8, ns: i64, data: Node };

const Module = struct {
    a: Allocator,
    name: []const u8,
    syms: std.AutoHashMapUnmanaged(i64, Sym) = .empty,
    order: std.ArrayList(i64) = .empty,
    out: std.ArrayList(u8) = .empty,

    fn sym(m: *const Module, id: i64) ?Sym {
        return m.syms.get(id);
    }

    fn print(m: *Module, comptime fmt: []const u8, args: anytype) !void {
        try m.out.print(m.a, fmt, args);
    }
};

/// The flags of a symbol's or component's attributes (after flavor,
/// intent, procedure, interface source, save and two numbers)
fn flags(attrs: Node) []const Node {
    const l = attrs.items();
    return if (l.len > 7) l[7..] else &.{};
}

fn hasFlag(attrs: Node, f: []const u8) bool {
    for (flags(attrs)) |x| if (x.isWord(f)) return true;
    return false;
}

fn lower(a: Allocator, s: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(a, s);
}

/// The value of a constant expression, `(CONSTANT (REAL 4 ...) 0 '0.3243f40@1' ())`:
/// an integer, or a real written in base 16 with `@` before its exponent
fn constant(a: Allocator, e: Node) !?[]const u8 {
    if (!(e.at(0) orelse return null).isWord("CONSTANT")) return null;
    const ts = e.at(1) orelse return null;
    const v = e.at(3) orelse return null;
    if (v != .string) return null;
    const t = (ts.at(0) orelse return null).word;
    if (std.mem.eql(u8, t, "INTEGER")) return v.string;
    if (!std.mem.eql(u8, t, "REAL")) return null;
    const s = v.string;
    const negative = s.len > 0 and s[0] == '-';
    const body = if (negative) s[1..] else s;
    const at = std.mem.findScalar(u8, body, '@') orelse body.len;
    const exp = if (at < body.len) std.fmt.parseInt(i32, body[at + 1 ..], 10) catch return null else 0;
    const mant = body[0..at];
    const dot = std.mem.findScalar(u8, mant, '.') orelse return null;
    var x: f64 = 0;
    for (mant[0..dot]) |c| x = x * 16 + @as(f64, @floatFromInt(std.fmt.charToDigit(c, 16) catch return null));
    var scale: f64 = 1.0 / 16.0;
    for (mant[dot + 1 ..]) |c| {
        x += scale * @as(f64, @floatFromInt(std.fmt.charToDigit(c, 16) catch return null));
        scale /= 16;
    }
    x *= std.math.pow(f64, 16, @floatFromInt(exp));
    if (negative) x = -x;
    const kind = (ts.at(1) orelse return null).int() orelse 4;
    return if (kind == 4) try a.print("{d}", .{@as(f32, @floatCast(x))}) else try a.print("{d}", .{x});
}

/// The type of type spec `ts` (`(REAL 8 0 0 0 REAL ())`) as declared, with
/// `deferred` for a CHARACTER that is ALLOCATABLE or a POINTER
fn typeText(m: *const Module, ts: Node, deferred: bool) !?[]const u8 {
    const a = m.a;
    const t = (ts.at(0) orelse return null).word;
    const k = (ts.at(1) orelse return null).int() orelse 0;
    if (std.mem.eql(u8, t, "REAL") or std.mem.eql(u8, t, "INTEGER") or std.mem.eql(u8, t, "LOGICAL") or std.mem.eql(u8, t, "COMPLEX"))
        return try a.print("{s}({d})", .{ try lower(a, t), k });
    if (std.mem.eql(u8, t, "CHARACTER")) {
        const len: []const u8 = if (ts.at(6)) |cl| (if (cl.at(0)) |e| try constant(a, e) else null) orelse (if (deferred) ":" else "*") else "*";
        return try a.print("character(len={s})", .{len});
    }
    if (std.mem.eql(u8, t, "DERIVED")) {
        const d = m.sym(k) orelse return null;
        return try a.print("type({s})", .{try lower(a, d.name)});
    }
    if (std.mem.eql(u8, t, "CLASS")) {
        // the class container's `_data` component has the declared type
        const c = m.sym(k) orelse return "class(*)";
        for ((c.data.at(1) orelse return "class(*)").items()) |comp| {
            const n = comp.at(1) orelse continue;
            if (n != .string or !std.mem.eql(u8, n.string, "_data")) continue;
            const dt = comp.at(2) orelse break;
            const d = m.sym((dt.at(1) orelse break).int() orelse break) orelse break;
            return try a.print("class({s})", .{try lower(a, d.name)});
        }
        return "class(*)";
    }
    return null;
}

/// `DIMENSION(...)` of array spec `as` (`(2 0 DEFERRED () () () ())`),
/// null for none
fn dimension(m: *const Module, as: Node) !?[]const u8 {
    const rank: usize = @intCast((as.at(0) orelse return null).int() orelse return null);
    if (rank == 0) return null;
    const kind = (as.at(2) orelse return null).word;
    var dims: std.ArrayList([]const u8) = .empty;
    for (0..rank) |i| {
        const d: []const u8 = blk: {
            if (std.mem.eql(u8, kind, "ASSUMED_RANK")) break :blk "..";
            if (!std.mem.eql(u8, kind, "EXPLICIT") and !std.mem.eql(u8, kind, "ASSUMED_SIZE")) break :blk ":";
            if (std.mem.eql(u8, kind, "ASSUMED_SIZE") and i == rank - 1) break :blk "*";
            const lo = if (as.at(3 + 2 * i)) |e| try constant(m.a, e) else null;
            const hi = if (as.at(4 + 2 * i)) |e| try constant(m.a, e) else null;
            if (hi == null) break :blk ":";
            if (lo == null or std.mem.eql(u8, lo.?, "1")) break :blk hi.?;
            break :blk try m.a.print("{s}:{s}", .{ lo.?, hi.? });
        };
        try dims.append(m.a, d);
    }
    return try m.a.print("dimension({s})", .{try std.mem.join(m.a, ",", dims.items)});
}

/// A declaration of `name`: its type, then the attributes
fn declaration(m: *Module, indent: []const u8, name: []const u8, ts: Node, attrs: Node, as: ?Node, value: ?Node, intent: ?[]const u8) !void {
    const deferred = hasFlag(attrs, "ALLOCATABLE") or hasFlag(attrs, "POINTER");
    const t = (try typeText(m, ts, deferred)) orelse return;
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(m.a, t);
    if (value != null) try parts.append(m.a, "parameter");
    if (as) |x| if (try dimension(m, x)) |d| try parts.append(m.a, d);
    for ([_][2][]const u8{ .{ "ALLOCATABLE", "allocatable" }, .{ "POINTER", "pointer" }, .{ "TARGET", "target" }, .{ "OPTIONAL", "optional" }, .{ "VALUE", "value" } }) |f|
        if (hasFlag(attrs, f[0])) try parts.append(m.a, f[1]);
    if (intent) |i| try parts.append(m.a, try m.a.print("intent({s})", .{try lower(m.a, i)}));
    try m.print("{s}{s} :: {s}", .{ indent, try std.mem.join(m.a, ", ", parts.items), try lower(m.a, name) });
    if (value) |v| if (try constant(m.a, v)) |c| try m.print(" = {s}", .{c});
    try m.print("\n", .{});
}

/// A derived type with its components and type-bound procedures
fn derivedType(m: *Module, s: Sym) !void {
    const comps = (s.data.at(1) orelse return).items();
    // an extension's parent type is its first component, named like it
    var parent: ?[]const u8 = null;
    if (comps.len > 0) if (comps[0].at(2)) |ts| if ((ts.at(0) orelse Node{ .word = "" }).isWord("DERIVED")) {
        const p = m.sym((ts.at(1) orelse Node{ .word = "0" }).int() orelse 0);
        if (p) |ps| if (std.ascii.eqlIgnoreCase(ps.name, (comps[0].at(1) orelse Node{ .string = "" }).string)) {
            parent = try lower(m.a, ps.name);
        };
    };
    if (parent) |p| try m.print("  type, extends({s}) :: {s}\n", .{ p, try lower(m.a, s.name) }) else try m.print("  type :: {s}\n", .{try lower(m.a, s.name)});
    for (comps, 0..) |c, i| {
        if (i == 0 and parent != null) continue;
        const n = c.at(1) orelse continue;
        if (n != .string) continue;
        const attrs = c.at(6) orelse continue;
        try declaration(m, "    ", n.string, c.at(2) orelse continue, attrs, c.at(3), null, null);
    }
    // the specific bindings: `(('norm' (PUBLIC OVERRIDABLE ... 1 7)))`
    var binds: std.ArrayList([]const u8) = .empty;
    if (s.data.at(9)) |tb| if (tb.at(1)) |specific| for (specific.items()) |b| {
        const bn = b.at(0) orelse continue;
        const info = (b.at(1) orelse continue).items();
        if (bn != .string or info.len == 0) continue;
        const target = m.sym(info[info.len - 1].int() orelse continue) orelse continue;
        const bname = try lower(m.a, bn.string);
        const tname = try lower(m.a, target.name);
        try binds.append(m.a, if (std.mem.eql(u8, bname, tname)) try m.a.print("    procedure :: {s}\n", .{bname}) else try m.a.print("    procedure :: {s} => {s}\n", .{ bname, tname }));
    };
    if (binds.items.len > 0) {
        try m.print("  contains\n", .{});
        for (binds.items) |b| try m.print("{s}", .{b});
    }
    try m.print("  end type {s}\n", .{try lower(m.a, s.name)});
}

/// A module procedure, with its dummy arguments and a function's result
fn procedure(m: *Module, s: Sym) !void {
    const attrs = s.data.at(0) orelse return;
    const function = hasFlag(attrs, "FUNCTION");
    var args: std.ArrayList([]const u8) = .empty;
    var dummies: std.ArrayList(Sym) = .empty;
    for ((s.data.at(5) orelse return).items()) |f| {
        const d = m.sym(f.int() orelse continue) orelse continue;
        try args.append(m.a, try lower(m.a, d.name));
        try dummies.append(m.a, d);
    }
    const name = try lower(m.a, s.name);
    const result = if (function) m.sym((s.data.at(7) orelse Node{ .word = "0" }).int() orelse 0) else null;
    const result_name = if (result) |r| try lower(m.a, r.name) else name;
    if (function) {
        try m.print("  function {s}({s})", .{ name, try std.mem.join(m.a, ", ", args.items) });
        if (!std.mem.eql(u8, result_name, name)) try m.print(" result({s})", .{result_name});
        try m.print("\n", .{});
    } else try m.print("  subroutine {s}({s})\n", .{ name, try std.mem.join(m.a, ", ", args.items) });
    for (dummies.items) |d| try variable(m, "    ", d);
    if (function) {
        const r = result orelse s;
        try declaration(m, "    ", result_name, r.data.at(2) orelse return, r.data.at(0) orelse return, r.data.at(6), null, null);
    }
    try m.print("  end {s} {s}\n", .{ if (function) "function" else "subroutine", name });
}

/// A variable, named constant or dummy argument
fn variable(m: *Module, indent: []const u8, s: Sym) !void {
    const attrs = s.data.at(0) orelse return;
    const param = (attrs.at(0) orelse return).isWord("PARAMETER");
    const intent = (attrs.at(1) orelse return).word;
    const has_intent = std.mem.eql(u8, intent, "IN") or std.mem.eql(u8, intent, "OUT") or std.mem.eql(u8, intent, "INOUT");
    try declaration(m, indent, s.name, s.data.at(2) orelse return, attrs, s.data.at(if (param) 7 else 6), if (param) s.data.at(6) else null, if (has_intent) intent else null);
}

/// The interface of module `name` (lowercase, as its file is named) of
/// gfortran module file text `text` as free-form Fortran, null when it is
/// no module file of gfortran's
pub fn source(a: Allocator, text: []const u8, name: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, text, header)) return null;
    const nl = std.mem.findScalar(u8, text, '\n') orelse return null;
    const nodes = sexpr.parseAll(a, text[nl + 1 ..]) catch |e| return if (e == error.OutOfMemory) e else null;
    if (nodes.len < 3) return null;
    var m: Module = .{ .a = a, .name = name };
    // the symbols, flat: ID 'name' 'module' 'binding' NS (data)
    const flat = nodes[nodes.len - 2].items();
    var i: usize = 0;
    while (i + 5 < flat.len) : (i += 6) {
        const id = flat[i].int() orelse return null;
        if (flat[i + 1] != .string or flat[i + 2] != .string) return null;
        try m.syms.put(a, id, .{ .id = id, .name = flat[i + 1].string, .module = flat[i + 2].string, .ns = flat[i + 4].int() orelse 0, .data = flat[i + 5] });
    }
    // the public names: 'name' AMBIGUOUS ID
    const names = nodes[nodes.len - 1].items();
    i = 0;
    while (i + 2 < names.len) : (i += 3) try m.order.append(a, names[i + 2].int() orelse continue);
    std.mem.sort(i64, m.order.items, {}, std.sort.asc(i64));
    try m.print("! The interface of module {s}, from its gfortran module file\nmodule {s}\n", .{ m.name, m.name });
    // the types, then the variables, the generic interfaces, the procedures
    var procs: std.ArrayList(Sym) = .empty;
    var types: std.AutoHashMapUnmanaged(i64, void) = .empty;
    for (m.order.items) |id| {
        const s = m.sym(id) orelse continue;
        const attrs = s.data.at(0) orelse continue;
        if (std.mem.startsWith(u8, s.name, "__") or hasFlag(attrs, "ARTIFICIAL") or !std.mem.eql(u8, s.module, m.name)) continue;
        const flavor = (attrs.at(0) orelse continue).word;
        if (std.mem.eql(u8, flavor, "DERIVED") and !hasFlag(attrs, "VTYPE") and !hasFlag(attrs, "IS_CLASS")) {
            if ((try types.getOrPut(a, id)).found_existing) continue;
            try derivedType(&m, s);
        }
    }
    for (m.order.items) |id| {
        const s = m.sym(id) orelse continue;
        const attrs = s.data.at(0) orelse continue;
        if (std.mem.startsWith(u8, s.name, "__") or hasFlag(attrs, "ARTIFICIAL") or !std.mem.eql(u8, s.module, m.name)) continue;
        const flavor = (attrs.at(0) orelse continue).word;
        if (std.mem.eql(u8, flavor, "VARIABLE") or std.mem.eql(u8, flavor, "PARAMETER")) {
            try variable(&m, "  ", s);
        } else if (std.mem.eql(u8, flavor, "PROCEDURE") and !hasFlag(attrs, "GENERIC") and (attrs.at(2) orelse Node{ .word = "" }).isWord("MODULE-PROC")) {
            try procs.append(a, s);
        }
    }
    // generic interfaces: ('gen' 'lib' 2 3), not a type's constructor
    for (nodes[2].items()) |g| {
        const gn = g.at(0) orelse continue;
        if (gn != .string) continue;
        var specifics: std.ArrayList([]const u8) = .empty;
        for (g.items()[@min(2, g.items().len)..]) |x| if (m.sym(x.int() orelse continue)) |s| {
            const flavor = ((s.data.at(0) orelse continue).at(0) orelse continue).word;
            if (!std.mem.eql(u8, flavor, "PROCEDURE")) continue;
            try specifics.append(a, try lower(a, s.name));
        };
        if (specifics.items.len == 0) continue;
        try m.print("  interface {s}\n    module procedure {s}\n  end interface {s}\n", .{ gn.string, try std.mem.join(a, ", ", specifics.items), gn.string });
    }
    if (procs.items.len > 0) {
        try m.print("contains\n", .{});
        for (procs.items) |s| try procedure(&m, s);
    }
    try m.print("end module {s}\n", .{m.name});
    return m.out.items;
}

test "the interface of a gfortran module file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // gfortran 16.1 (MSYS2), `gfortran -c` of a module with a parameter,
    // an allocatable array, a type with a type-bound procedure, a generic
    // and module procedures (abridged: the vtab and class symbols left out)
    const text =
        \\GFORTRAN module version '16' created from lib.f90
        \\(() () ())
        \\
        \\()
        \\
        \\(('gen' 'lib' 2 3) ('pt' 'lib' 4))
        \\
        \\()
        \\
        \\()
        \\
        \\()
        \\
        \\(4 'Pt' 'lib' '' 1 ((DERIVED UNKNOWN-INTENT UNKNOWN-PROC UNKNOWN UNKNOWN
        \\0 0) ((5 'a' (REAL 4 0 0 0 REAL ()) () () () (UNKNOWN-FL UNKNOWN-INTENT
        \\UNKNOWN-PROC UNKNOWN UNKNOWN 0 0) UNKNOWN-ACCESS (CONSTANT (REAL 4 0 0 0
        \\REAL ()) 0 '0.1000000@1' ())) (6 'b' (INTEGER 4 0 0 0 INTEGER ()) (1 0
        \\EXPLICIT (CONSTANT (INTEGER 4 0 0 0 INTEGER ()) 0 '1' ()) (CONSTANT (
        \\INTEGER 4 0 0 0 INTEGER ()) 0 '3' ())) () () (UNKNOWN-FL UNKNOWN-INTENT
        \\UNKNOWN-PROC UNKNOWN UNKNOWN 0 0 DIMENSION) UNKNOWN-ACCESS ())) PUBLIC (
        \\UNKNOWN 0 0 0 0 UNKNOWN ()) 0 0 () () 0 (() (('norm' (PUBLIC OVERRIDABLE
        \\PASS SPECIFIC NO_PPC '' 1 7))) () ()) () () 0 0 95466526)
        \\20 'arr' 'lib' '' 1 ((VARIABLE UNKNOWN-INTENT UNKNOWN-PROC UNKNOWN
        \\IMPLICIT-SAVE 0 0 ALLOCATABLE DIMENSION) () (REAL 4 0 0 0 REAL ()) 0 0 ()
        \\(2 0 DEFERRED () () () ()) 0 () () () 0 0)
        \\3 'f' 'lib' '' 1 ((PROCEDURE UNKNOWN-INTENT MODULE-PROC DECL UNKNOWN 0 0
        \\FUNCTION IMPLICIT_PURE) () (REAL 4 0 0 0 REAL ()) 22 0 (23) () 3 () () ()
        \\0 0)
        \\24 'label' 'lib' '' 1 ((VARIABLE UNKNOWN-INTENT UNKNOWN-PROC UNKNOWN
        \\IMPLICIT-SAVE 0 0) () (CHARACTER 1 0 0 0 CHARACTER ((CONSTANT (INTEGER 4
        \\0 0 0 INTEGER ()) 0 '10' ()))) 0 0 () () 0 () () () 0 0)
        \\25 'n' 'lib' '' 1 ((PARAMETER UNKNOWN-INTENT UNKNOWN-PROC UNKNOWN
        \\IMPLICIT-SAVE 0 0) () (INTEGER 4 0 0 0 INTEGER ()) 0 0 () (CONSTANT (
        \\INTEGER 4 0 0 0 INTEGER ()) 0 '3' ()) () 0 () () () 0 0)
        \\26 'pi' 'lib' '' 1 ((PARAMETER UNKNOWN-INTENT UNKNOWN-PROC UNKNOWN
        \\IMPLICIT-SAVE 0 0) () (REAL 4 0 0 0 REAL ()) 0 0 () (CONSTANT (REAL 4 0
        \\0 0 REAL ()) 0 '0.3243f40@1' ()) () 0 () () () 0 0)
        \\27 'pt' 'lib' '' 1 ((PROCEDURE UNKNOWN-INTENT UNKNOWN-PROC DECL UNKNOWN
        \\0 0 FUNCTION GENERIC) () (UNKNOWN 0 0 0 0 UNKNOWN ()) 0 0 () () 0 () ()
        \\() 0 0)
        \\28 's' 'lib' '' 1 ((PROCEDURE UNKNOWN-INTENT MODULE-PROC DECL UNKNOWN 0
        \\0 SUBROUTINE IMPLICIT_PURE ALWAYS_EXPLICIT) () (UNKNOWN 0 0 0 0 UNKNOWN
        \\()) 29 0 (30 31) () 0 () () () 0 0)
        \\33 'x' 'lib' '' 1 ((VARIABLE UNKNOWN-INTENT UNKNOWN-PROC UNKNOWN
        \\IMPLICIT-SAVE 0 0) () (REAL 8 0 0 0 REAL ()) 0 0 () () 0 () () () 0 0)
        \\2 'g' 'lib' '' 1 ((PROCEDURE UNKNOWN-INTENT MODULE-PROC DECL UNKNOWN 0 0
        \\FUNCTION IMPLICIT_PURE) () (REAL 4 0 0 0 REAL ()) 34 0 (35) () 2 () () ()
        \\0 0)
        \\7 'norm' 'lib' '' 1 ((PROCEDURE UNKNOWN-INTENT MODULE-PROC DECL UNKNOWN
        \\0 0 FUNCTION IMPLICIT_PURE) () (REAL 4 0 0 0 REAL ()) 36 0 (37) () 7 ()
        \\() () 0 0)
        \\23 'y' '' '' 22 ((VARIABLE IN UNKNOWN-PROC UNKNOWN UNKNOWN 0 0 DUMMY) ()
        \\(REAL 4 0 0 0 REAL ()) 0 0 () () 0 () () () 0 0)
        \\30 'a' '' '' 29 ((VARIABLE INOUT UNKNOWN-PROC UNKNOWN UNKNOWN 0 0
        \\DIMENSION DUMMY) () (REAL 4 0 0 0 REAL ()) 0 0 () (1 0 ASSUMED_SHAPE (
        \\CONSTANT (INTEGER 4 0 0 0 INTEGER ()) 0 '1' ()) ()) 0 () () () 0 0)
        \\31 'b' '' '' 29 ((VARIABLE OUT UNKNOWN-PROC UNKNOWN UNKNOWN 0 0 OPTIONAL
        \\DUMMY) () (INTEGER 4 0 0 0 INTEGER ()) 0 0 () () 0 () () () 0 0)
        \\35 'i' '' '' 34 ((VARIABLE IN UNKNOWN-PROC UNKNOWN UNKNOWN 0 0 DUMMY) ()
        \\(INTEGER 4 0 0 0 INTEGER ()) 0 0 () () 0 () () () 0 0)
        \\37 'self' '' '' 36 ((VARIABLE IN UNKNOWN-PROC UNKNOWN UNKNOWN 0 0 DUMMY)
        \\() (DERIVED 4 0 0 0 DERIVED ()) 0 0 () () 0 () () () 0 0)
        \\38 'lib' 'lib' '' 1 ((MODULE UNKNOWN-INTENT UNKNOWN-PROC UNKNOWN UNKNOWN
        \\0 0) () (UNKNOWN 0 0 0 0 UNKNOWN ()) 0 0 () () 0 () () () 0 0)
        \\)
        \\
        \\('Pt' 0 4 'arr' 0 20 'f' 0 3 'gen' 0 27 'label' 0 24 'n' 0 25 'pi' 0 26
        \\'pt' 0 27 's' 0 28 'x' 0 33)
        \\
    ;
    const src = (try source(a, text, "lib")).?;
    const want =
        \\! The interface of module lib, from its gfortran module file
        \\module lib
        \\  type :: pt
        \\    real(4) :: a
        \\    integer(4), dimension(3) :: b
        \\  contains
        \\    procedure :: norm
        \\  end type pt
        \\  real(4), dimension(:,:), allocatable :: arr
        \\  character(len=10) :: label
        \\  integer(4), parameter :: n = 3
        \\  real(4), parameter :: pi = 3.14159
        \\  real(8) :: x
        \\  interface gen
        \\    module procedure g, f
        \\  end interface gen
        \\contains
        \\  function f(y)
        \\    real(4), intent(in) :: y
        \\    real(4) :: f
        \\  end function f
        \\  subroutine s(a, b)
        \\    real(4), dimension(:), intent(inout) :: a
        \\    integer(4), optional, intent(out) :: b
        \\  end subroutine s
        \\end module lib
        \\
    ;
    try std.testing.expectEqualStrings(want, src);
    try std.testing.expect((try source(a, "!mod$ v1 sum:1\n", "lib")) == null);
}
