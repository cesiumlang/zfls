//! Attribute statements: `DIMENSION v(n)`, `OPTIONAL :: w`, `INTENT(IN) a`,
//! `PARAMETER (pi = 3.14)`, ... give an attribute to the names they list
//! instead of the type declaration. A declaration may come after the
//! statement, or none at all under implicit typing, so the parser keeps
//! what the statements say and applies it when the file is read: to the
//! variable the scope declares, or to a new one of the implicit type, at the
//! statement.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const implicit = @import("../implicit.zig");
const definitions = @import("definitions.zig");
const literals = @import("../literals.zig");
const typing = @import("../argcheck/typing.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const Kw = C.Kw;

/// What a statement says of one name: an attribute, with its text (the
/// bounds of DIMENSION and CODIMENSION, IN or OUT of INTENT, the value of a
/// PARAMETER)
pub const Attr = struct {
    /// null: the scope current when the file is read to its end (the main
    /// program without a PROGRAM statement, created later)
    scope: ?*Obj,
    line: usize,
    name: []const u8,
    kw: Kw,
    text: ?[]const u8 = null,
    /// the pointer of a Cray pointer, `p` of `POINTER (p, b)`: an integer
    /// variable the statement declares, not an attribute
    cray_pointer: bool = false,
    /// of a Cray pointer or its pointee, the other's name (`b` of `p`)
    cray_other: ?[]const u8 = null,
    /// a constant of DEC's `PARAMETER name = value` (ifx): of the type of
    /// its value, not the implicit type of its name
    typed_by_value: bool = false,
};

/// The statements and the attribute each gives; DEC's VIRTUAL (ifx) is
/// DIMENSION, and AUTOMATIC and STATIC are DEC's (ifx, gfortran's
/// `-fdec-static`)
const statements = [_]struct { []const u8, Kw }{
    .{ "dimension", .dimension },     .{ "codimension", .codimension },
    .{ "allocatable", .allocatable }, .{ "pointer", .pointer },
    .{ "target", .target },           .{ "optional", .optional },
    .{ "intent", .intent },           .{ "save", .save },
    .{ "volatile", .@"volatile" },    .{ "asynchronous", .asynchronous },
    .{ "contiguous", .contiguous },   .{ "protected", .protected },
    .{ "value", .value },             .{ "virtual", .dimension },
    .{ "automatic", .automatic },     .{ "static", .static },
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!isWordChar(c)) return false;
    return true;
}

/// The text between the bracket at `s[0]` and its match, or null
fn bracketed(s: []const u8, open: u8, close: u8) ?[]const u8 {
    if (s.len == 0 or s[0] != open) return null;
    var depth: usize = 0;
    var quote: ?u8 = null;
    for (s, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return s[1..i];
        }
    }
    return null;
}

fn add(a: Allocator, out: *std.ArrayList(Attr), at: Attr) !void {
    var copy = at;
    copy.name = try a.dupe(u8, at.name);
    copy.text = try str.dupeOpt(a, at.text);
    copy.cray_other = try str.dupeOpt(a, at.cray_other);
    try out.append(a, copy);
}

/// Read `line` as an attribute statement, adding what it says to `out` (in
/// `a`, which must outlive the line): false when it is none
pub fn read(a: Allocator, line: []const u8, scope: ?*Obj, ln: usize, out: *std.ArrayList(Attr)) !bool {
    if (patterns.get().PARAMETER_STMT.match(line)) |m| {
        for (try helpers.splitArgs(a, m.group(1) orelse "")) |item| {
            const eq = std.mem.findScalar(u8, item, '=') orelse continue;
            const name = str.strip(item[0..eq]);
            if (name.len == 0) continue;
            const value = try helpers.collapseBlanks(a, item[eq + 1 ..]);
            try add(a, out, .{ .scope = scope, .line = ln, .name = name, .kw = .parameter, .text = value });
        }
        return true;
    }
    if (try decParameter(a, line, scope, ln, out)) return true;
    const s = std.mem.trimStart(u8, line, " \t");
    var n: usize = 0;
    while (n < s.len and std.ascii.isAlphabetic(s[n])) n += 1;
    const kw = for (statements) |st| {
        if (std.ascii.eqlIgnoreCase(s[0..n], st[0])) break st[1];
    } else return false;
    var rest = s[n..];
    var intent: ?[]const u8 = null;
    if (kw == .intent) {
        rest = std.mem.trimStart(u8, rest, " \t");
        const inner = bracketed(rest, '(', ')') orelse return false;
        rest = rest[inner.len + 2 ..];
        const spec = try std.mem.replaceOwned(u8, a, inner, " ", "");
        if (!std.ascii.eqlIgnoreCase(spec, "in") and !std.ascii.eqlIgnoreCase(spec, "out") and !std.ascii.eqlIgnoreCase(spec, "inout")) return false;
        intent = try std.ascii.allocUpperString(a, spec);
    }
    var list = std.mem.trimStart(u8, rest, " \t");
    // `SAVE` alone saves all the scope's variables, which the hover does not
    // show
    if (list.len == 0) return kw == .save;
    if (std.mem.startsWith(u8, list, "::")) {
        list = std.mem.trimStart(u8, list[2..], " \t");
    } else if (kw != .intent and list.len == rest.len) {
        // a keyword runs into the name only in fixed form, which is not read
        // here: `save = 1`, `pointer (p, b)` (a Cray pointer) are no
        // attribute statements
        return false;
    }
    if (list.len == 0) return kw == .save;
    if (kw == .pointer and list[0] == '(') return crayPointers(a, list, scope, ln, out);
    if (!std.ascii.isAlphabetic(list[0]) and !(kw == .save and list[0] == '/')) return false;
    for (try helpers.splitArgs(a, list)) |item_in| {
        const item = str.strip(item_in);
        // `SAVE /block/`: a common block
        if (item.len == 0 or !std.ascii.isAlphabetic(item[0])) continue;
        var e: usize = 0;
        while (e < item.len and isWordChar(item[e])) e += 1;
        const name = item[0..e];
        var after = std.mem.trimStart(u8, item[e..], " \t");
        const dims = bracketed(after, '(', ')');
        if (dims) |d| after = std.mem.trimStart(u8, after[d.len + 2 ..], " \t");
        const codims = bracketed(after, '[', ']');
        if (kw == .dimension and dims == null) continue;
        if (kw == .codimension and codims == null) continue;
        const text: ?[]const u8 = switch (kw) {
            .dimension => str.strip(dims.?),
            .codimension => str.strip(codims.?),
            .intent => intent,
            else => null,
        };
        try add(a, out, .{ .scope = scope, .line = ln, .name = name, .kw = kw, .text = text });
        if (dims) |d| if (kw != .dimension) try add(a, out, .{ .scope = scope, .line = ln, .name = name, .kw = .dimension, .text = str.strip(d) });
        if (codims) |d| if (kw != .codimension) try add(a, out, .{ .scope = scope, .line = ln, .name = name, .kw = .codimension, .text = str.strip(d) });
    }
    return true;
}

/// DEC's `PARAMETER n = 10, s = 'ab'` (ifx): constants without
/// parentheses, each of the type of its value
fn decParameter(a: Allocator, line: []const u8, scope: ?*Obj, ln: usize, out: *std.ArrayList(Attr)) !bool {
    const s = std.mem.trimStart(u8, line, " \t");
    const key = "parameter";
    if (s.len <= key.len or !std.ascii.startsWithIgnoreCase(s, key) or (s[key.len] != ' ' and s[key.len] != '\t')) return false;
    const list = str.strip(s[key.len..]);
    if (list.len == 0 or !std.ascii.isAlphabetic(list[0])) return false;
    const items = try helpers.splitArgs(a, list);
    for (items) |item| {
        const eq = std.mem.findScalar(u8, item, '=') orelse return false;
        const name = str.strip(item[0..eq]);
        if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
        for (name) |c| if (!isWordChar(c)) return false;
        if (eq + 1 < item.len and item[eq + 1] == '=') return false;
    }
    for (items) |item| {
        const eq = std.mem.findScalar(u8, item, '=').?;
        const value = try helpers.collapseBlanks(a, item[eq + 1 ..]);
        try add(a, out, .{ .scope = scope, .line = ln, .name = str.strip(item[0..eq]), .kw = .parameter, .text = value, .typed_by_value = true });
    }
    return true;
}

/// `POINTER (p, b), (q, c(10))`: Cray pointers, an extension of gfortran,
/// ifx and LLVM Flang; each pointer `p` is an integer variable the
/// statement declares, and its pointee `b` a variable declared as any
/// other, which takes the bounds the statement gives it
fn crayPointers(a: Allocator, list_in: []const u8, scope: ?*Obj, ln: usize, out: *std.ArrayList(Attr)) !bool {
    var list = list_in;
    var any = false;
    while (bracketed(list, '(', ')')) |pair| {
        const comma = std.mem.findScalar(u8, pair, ',') orelse return any;
        const name = str.strip(pair[0..comma]);
        if (!isName(name)) return any;
        const rest = str.strip(pair[comma + 1 ..]);
        var e: usize = 0;
        while (e < rest.len and isWordChar(rest[e])) e += 1;
        const pointee = rest[0..e];
        if (!isName(pointee)) return any;
        const after = std.mem.trimStart(u8, rest[e..], " \t");
        const dims = bracketed(after, '(', ')');
        if (after.len > 0 and (dims == null or dims.?.len + 2 != after.len)) return any;
        try add(a, out, .{ .scope = scope, .line = ln, .name = name, .kw = .pointer, .cray_pointer = true, .cray_other = pointee });
        try add(a, out, .{ .scope = scope, .line = ln, .name = pointee, .kw = .pointer, .cray_other = name });
        if (dims) |d| try add(a, out, .{ .scope = scope, .line = ln, .name = pointee, .kw = .dimension, .text = str.strip(d) });
        any = true;
        list = std.mem.trimStart(u8, list[pair.len + 2 ..], " \t");
        if (list.len == 0 or list[0] != ',') break;
        list = std.mem.trimStart(u8, list[1..], " \t");
    }
    return any;
}

/// Give the attributes to the variables they name, in the order of the
/// statements; a name not declared gets a variable of its implicit type, if
/// it has one
pub fn apply(ast: *Ast, a: Allocator, attrs: []const Attr, sort: bool) !void {
    const pa = ast.allocator();
    for (attrs) |at| {
        const scope = at.scope orelse ast.none_scope orelse continue;
        if (scope.data != .scope) continue;
        const v = for (scope.childList()) |child| {
            if (child.nameLowerEql(at.name)) break child;
        } else (if (at.cray_pointer)
            try newVariable(ast, a, scope, at, cray_pointer_type)
        else if (at.typed_by_value)
            try valueTypedVariable(ast, a, scope, at)
        else
            try implicitVariable(ast, a, scope, at)) orelse continue;
        if (!v.kind.isVariable()) continue;
        // a Cray pointer or pointee, no attribute
        if (at.cray_other) |other| {
            if (v.kind == .variable) v.varData().cray = .{ .role = if (at.cray_pointer) .pointer else .pointee, .other = try pa.dupe(u8, other) };
            continue;
        }
        var info = v.keyword_info.*;
        const had = v.hasKeyword(at.kw);
        switch (at.kw) {
            .dimension => if (info.dimension == null) {
                info.dimension = try pa.dupe(u8, at.text.?);
            } else continue,
            .codimension => if (info.codimension == null) {
                info.codimension = try pa.dupe(u8, at.text.?);
            } else continue,
            .intent => if (info.intent == null) {
                info.intent = try pa.dupe(u8, at.text.?);
            } else continue,
            .parameter => {
                v.varData().is_const = true;
                v.varData().param_val = try pa.dupe(u8, at.text.?);
            },
            else => {},
        }
        v.keyword_info = try info.dupe(pa);
        if (!had) {
            try v.keywords.append(pa, at.kw);
            if (sort) std.mem.sort(Kw, v.keywords.items, {}, Kw.lessThan);
        }
    }
}

/// A variable of the implicit type of `at.name` in `scope`, declared at the
/// statement; null under IMPLICIT NONE
fn implicitVariable(ast: *Ast, a: Allocator, scope: *Obj, at: Attr) !?*Obj {
    const type_name = implicit.typeOf(scope, at.name) orelse return null;
    return newVariable(ast, a, scope, at, type_name);
}

/// A constant of the type of its value `at.text` when that is a literal,
/// else of the implicit type of its name (null under IMPLICIT NONE)
fn valueTypedVariable(ast: *Ast, a: Allocator, scope: *Obj, at: Attr) !?*Obj {
    const value = at.text orelse "";
    if (typing.literalCategory(value) != null) {
        const sign: usize = if (value.len > 0 and (value[0] == '-' or value[0] == '+')) 1 else 0;
        if (try literals.at(a, value, sign)) |lit| if (!std.mem.eql(u8, lit.type, "BOZ"))
            return newVariable(ast, a, scope, at, lit.type);
    }
    return implicitVariable(ast, a, scope, at);
}

/// The type of a Cray pointer: an address, as LLVM Flang has it on 64-bit
/// targets (gfortran and ifx use the size of an address too)
const cray_pointer_type = "INTEGER(8)";

/// A variable of type `type_name` named `at.name` in `scope`, declared at
/// the statement
fn newVariable(ast: *Ast, a: Allocator, scope: *Obj, at: Attr, type_name: []const u8) !?*Obj {
    const decl = try a.print("{s} :: {s}", .{ type_name, at.name });
    const def = (try definitions.readVarDef(a, decl, null, false)) orelse return null;
    if (def != .var_) return null;
    const pa = ast.allocator();
    const v = try Obj.newVariable(ast, at.line, at.name, def.var_.var_type, &.{}, .{ .kind = def.var_.var_kind });
    v.fqsn = try std.mem.concat(pa, u8, &.{ scope.fqsn, "::", try std.ascii.allocLowerString(a, at.name) });
    try scope.addChild(v);
    try ast.variable_list.append(pa, v);
    return v;
}

const testing = std.testing;

test "attribute statements" {
    patterns.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Attr) = .empty;
    try testing.expect(try read(a, "  dimension x(3), a(*)", null, 1, &out));
    try testing.expect(try read(a, "allocatable :: y(:), q[:]", null, 1, &out));
    try testing.expect(try read(a, "intent ( in out ) :: u, v", null, 1, &out));
    try testing.expect(try read(a, "save x, /blk/", null, 1, &out));
    try testing.expect(try read(a, "save", null, 1, &out));
    try testing.expect(try read(a, "PARAMETER (PI=3.14159, KMAX=10)", null, 1, &out));
    const want = [_]struct { []const u8, Kw, ?[]const u8 }{
        .{ "x", .dimension, "3" },     .{ "a", .dimension, "*" },
        .{ "y", .allocatable, null },  .{ "y", .dimension, ":" },
        .{ "q", .allocatable, null },  .{ "q", .codimension, ":" },
        .{ "u", .intent, "INOUT" },    .{ "v", .intent, "INOUT" },
        .{ "x", .save, null },         .{ "PI", .parameter, "3.14159" },
        .{ "KMAX", .parameter, "10" },
    };
    try testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, got| {
        try testing.expectEqualStrings(w[0], got.name);
        try testing.expectEqual(w[1], got.kw);
        if (w[2]) |t| try testing.expectEqualStrings(t, got.text.?) else try testing.expect(got.text == null);
    }
    // statements that only start with the word of one
    for ([_][]const u8{ "save = 1", "pointer(1) = 2", "dimension(3) = 1", "target%x = 2", "value", "intent(sideways) :: x", "optional_x = 1" }) |line| {
        try testing.expect(!try read(a, line, null, 1, &out));
    }
    // DEC's statements (ifx): VIRTUAL, AUTOMATIC, STATIC; PARAMETER
    // without parentheses, typed by its values
    out.clearRetainingCapacity();
    try testing.expect(try read(a, "virtual w(5)", null, 1, &out));
    try testing.expect(try read(a, "automatic :: tmp", null, 1, &out));
    try testing.expect(try read(a, "STATIC calls", null, 1, &out));
    try testing.expect(try read(a, "PARAMETER NMAX = 10, s = 'a=b'", null, 1, &out));
    const dec = [_]struct { []const u8, Kw, ?[]const u8 }{
        .{ "w", .dimension, "5" },     .{ "tmp", .automatic, null },
        .{ "calls", .static, null },   .{ "NMAX", .parameter, "10" },
        .{ "s", .parameter, "'a=b'" },
    };
    try testing.expectEqual(dec.len, out.items.len);
    for (dec, out.items) |w, got| {
        try testing.expectEqualStrings(w[0], got.name);
        try testing.expectEqual(w[1], got.kw);
        if (w[2]) |t| try testing.expectEqualStrings(t, got.text.?) else try testing.expect(got.text == null);
        try testing.expectEqual(w[1] == .parameter, got.typed_by_value);
    }
    for ([_][]const u8{ "parameter x", "parameter = 3", "parameter x == 1", "virtual = 2", "static(1) = 2" }) |line| {
        try testing.expect(!try read(a, line, null, 1, &out));
    }
    // Cray pointers: the pointers, their pointees and the pointees' bounds
    // (#692)
    out.clearRetainingCapacity();
    try testing.expect(try read(a, "pointer (p, b), (q2, c(n, 2))", null, 1, &out));
    const cray = [_]struct { []const u8, bool, ?[]const u8, ?[]const u8 }{
        .{ "p", true, "b", null },     .{ "b", false, "p", null },
        .{ "q2", true, "c", null },    .{ "c", false, "q2", null },
        .{ "c", false, null, "n, 2" },
    };
    try testing.expectEqual(cray.len, out.items.len);
    for (cray, out.items) |w, got| {
        try testing.expectEqualStrings(w[0], got.name);
        try testing.expectEqual(w[1], got.cray_pointer);
        if (w[2]) |o| try testing.expectEqualStrings(o, got.cray_other.?) else try testing.expect(got.cray_other == null);
        if (w[3]) |t| try testing.expectEqualStrings(t, got.text.?) else try testing.expect(got.text == null);
    }
}
