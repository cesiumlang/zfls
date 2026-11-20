//! Part of the parser (parse.zig): statement functions (#555), `f(x) = x**2
//! + 1` in the specification part of a procedure or main program, which
//! look like an assignment to an array element. One is a function of the
//! scope, with its dummy arguments (of the types the scope gives their
//! names) and its result (of the type the scope declares for its name), in
//! a scope of its one line; names without a declaration have their
//! implicit types.
//!
//! A statement is one when the scope has had no executable statement yet
//! (`State.exec`), its parenthesis holds names only, and its name is no
//! array: declared as a scalar in the scope, or not declared at all where
//! no USE, INCLUDE or host scope could declare it as one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const patterns = @import("../patterns.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const implicit = @import("../implicit.zig");
const attributes = @import("attributes.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// What the parser keeps for statement functions
pub const State = struct {
    /// The scopes that have had an executable statement
    exec: std.AutoHashMapUnmanaged(*const Obj, void) = .empty,
    /// The names (lowercase) that a COMMON statement of a scope gives
    /// bounds (`common /c/ a(10)`), which are arrays
    common_arrays: std.ArrayList(struct { scope: *const Obj, name: []const u8 }) = .empty,

    /// The current scope's specification part is over: at an executable
    /// statement, or a construct
    pub fn markExec(self: *State, a: Allocator, ast: *const Ast) !void {
        if (ast.current_scope) |cs| try self.exec.put(a, cs, {});
    }
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// `name(args) = expr`: the name, the arguments (each a name) and the
/// expression, or null
pub const Shape = struct { name: []const u8, args: []const []const u8, expr: []const u8 };

pub fn shape(a: Allocator, code: []const u8) !?Shape {
    const s = std.mem.trim(u8, code, " \t");
    if (s.len == 0 or !isNameStart(s[0])) return null;
    var i: usize = 1;
    while (i < s.len and isNameChar(s[i])) i += 1;
    const name = s[0..i];
    while (i < s.len and s[i] == ' ') i += 1;
    if (i >= s.len or s[i] != '(') return null;
    const close = std.mem.findScalarPos(u8, s, i, ')') orelse return null;
    const inside = s[i + 1 .. close];
    var j = close + 1;
    while (j < s.len and s[j] == ' ') j += 1;
    if (j >= s.len or s[j] != '=') return null;
    // not `==` nor `=>`
    if (j + 1 < s.len and (s[j + 1] == '=' or s[j + 1] == '>')) return null;
    var args: std.ArrayList([]const u8) = .empty;
    if (std.mem.trim(u8, inside, " ").len > 0) {
        var it = std.mem.splitScalar(u8, inside, ',');
        while (it.next()) |raw| {
            const arg = std.mem.trim(u8, raw, " ");
            if (arg.len == 0 or !isNameStart(arg[0])) return null;
            for (arg) |c| if (!isNameChar(c)) return null;
            for (args.items) |other| if (std.ascii.eqlIgnoreCase(other, arg)) return null;
            try args.append(a, arg);
        }
    }
    return .{ .name = name, .args = args.items, .expr = std.mem.trim(u8, s[j + 1 ..], " ") };
}

/// The statements that start the execution part (constructs aside, which
/// the parser reads as such)
const executable = [_][]const u8{
    "allocate", "assign",     "backspace", "call",   "change",  "close", "continue", "critical",
    "cycle",    "deallocate", "endfile",   "error",  "event",   "exit",  "fail",     "flush",
    "forall",   "go",         "goto",      "if",     "inquire", "lock",  "nullify",  "open",
    "pause",    "print",      "read",      "return", "rewind",  "stop",  "sync",     "unlock",
    "wait",     "write",
};

/// Whether statement `code` is an assignment: a name, its subscripts,
/// components and cosubscripts, then `=`
fn isAssignment(code: []const u8) bool {
    const s = std.mem.trim(u8, code, " \t");
    if (s.len == 0 or !isNameStart(s[0])) return false;
    var i: usize = 0;
    var depth: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (depth > 0) {
            switch (c) {
                '(', '[' => depth += 1,
                ')', ']' => depth -= 1,
                '\'', '"' => {
                    const close = std.mem.findScalarPos(u8, s, i + 1, c) orelse return false;
                    i = close;
                },
                else => {},
            }
            continue;
        }
        switch (c) {
            '(', '[' => depth += 1,
            '=' => return i + 1 >= s.len or (s[i + 1] != '=' and s[i + 1] != '>'),
            else => if (!isNameChar(c) and c != '%' and c != '.' and c != ' ') return false,
        }
    }
    return false;
}

/// Whether statement `code` is an executable statement: an assignment, or
/// one of `executable`
pub fn isExecutable(code: []const u8) bool {
    if (isAssignment(code)) return true;
    const s = std.mem.trimStart(u8, code, " \t");
    var n: usize = 0;
    while (n < s.len and std.ascii.isAlphabetic(s[n])) n += 1;
    if (n == 0 or n > 16) return false;
    var low: [16]u8 = undefined;
    const word = std.ascii.lowerString(&low, s[0..n]);
    for (executable) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

/// The names that a COMMON statement gives bounds, kept in `state`
pub fn readCommon(state: *State, a: Allocator, ast: *const Ast, code: []const u8) !void {
    const cs = ast.current_scope orelse return;
    const s = std.mem.trimStart(u8, code, " \t");
    if (!std.ascii.startsWithIgnoreCase(s, "common")) return;
    var i: usize = "common".len;
    if (i < s.len and isNameChar(s[i])) return;
    var depth: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '(') {
            if (depth == 0) {
                var k = i;
                while (k > 0 and s[k - 1] == ' ') k -= 1;
                const end = k;
                while (k > 0 and isNameChar(s[k - 1])) k -= 1;
                if (end > k) try state.common_arrays.append(a, .{ .scope = cs, .name = try std.ascii.allocLowerString(a, s[k..end]) });
            }
            depth += 1;
        } else if (c == ')') depth -|= 1;
    }
}

/// Whether a scope of this kind has statement functions
fn takes(scope: *const Obj) bool {
    return switch (scope.kind) {
        .subroutine, .function, .program => true,
        else => false,
    };
}

fn isArray(v: *const Obj) bool {
    return v.hasKeyword(C.KW.dimension) or v.keyword_info.dimension != null or v.hasKeyword(C.KW.codimension) or
        v.hasKeyword(C.KW.allocatable) or v.hasKeyword(C.KW.pointer);
}

/// The variable of the scope named `name`, and its index among the
/// scope's children
fn declared(scope: *Obj, name: []const u8) ?struct { obj: *Obj, index: usize } {
    for (scope.scopeData().children.items, 0..) |c, i| {
        if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, name)) return .{ .obj = c, .index = i };
    }
    return null;
}

/// Whether a dummy argument of `scope` is named `name`
fn isDummy(a: Allocator, scope: *const Obj, name: []const u8) !bool {
    var it = std.mem.splitScalar(u8, scope.argList(), ',');
    while (it.next()) |arg| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, arg, " "), name)) return true;
    _ = a;
    return false;
}

/// Whether `name` could be an array of `scope` that zfls does not see while
/// it parses: by USE, from an INCLUDE file or the host
fn mayBeHidden(state: *const State, ast: *const Ast, scope: *const Obj, name: []const u8) bool {
    if (scope.parent != null and scope != ast.none_scope) return true;
    if (scope.scopeDataConst().use.items.len > 0) return true;
    for (ast.include_statements.items) |inc| if (inc.line_number >= scope.sline) return true;
    for (state.common_arrays.items) |c| if (c.scope == scope and std.ascii.eqlIgnoreCase(c.name, name)) return true;
    return false;
}

/// Whether an attribute statement of the scope says `name` is an array
fn arrayByAttribute(attrs: []const attributes.Attr, scope: *const Obj, name: []const u8) bool {
    for (attrs) |at| {
        if (at.scope != scope or !std.ascii.eqlIgnoreCase(at.name, name)) continue;
        switch (at.kw) {
            .dimension, .codimension, .allocatable, .pointer => return true,
            else => {},
        }
    }
    return false;
}

/// Reads statement `code` (no label, no comment), at line `line_no`, as a
/// statement function if it is one: true when it is. Else, an
/// assignment ends the scope's specification part.
pub fn read(state: *State, a: Allocator, ast: *Ast, attrs: []const attributes.Attr, code: []const u8, line_no: usize) !bool {
    try readCommon(state, a, ast, code);
    const sh = (try shape(a, code)) orelse {
        if (isExecutable(code)) try state.markExec(a, ast);
        return false;
    };
    const cs = ast.current_scope orelse return false;
    if (!takes(cs) or state.exec.contains(cs)) return try notOne(state, a, ast);
    if (try isDummy(a, cs, sh.name)) return try notOne(state, a, ast);
    if (cs.kind == .function) {
        const result = cs.procDataConst().result_name orelse cs.name;
        if (std.ascii.eqlIgnoreCase(result, sh.name) or std.ascii.eqlIgnoreCase(cs.name, sh.name)) return try notOne(state, a, ast);
    }
    if (arrayByAttribute(attrs, cs, sh.name)) return try notOne(state, a, ast);
    const decl = declared(cs, sh.name);
    if (decl) |d| {
        if (isArray(d.obj) or d.obj.varDataConst().is_external) return try notOne(state, a, ast);
    } else if (mayBeHidden(state, ast, cs, sh.name)) return try notOne(state, a, ast);
    // the declaration of its name is the type of its result
    var result_type: ?[]const u8 = implicit.typeOf(cs, sh.name);
    var result_kind: ?[]const u8 = null;
    if (decl) |d| {
        result_type = d.obj.varDataConst().desc;
        result_kind = d.obj.varDataConst().vkind;
        cs.removeChild(d.index);
        for (ast.variable_list.items, 0..) |v, i| if (v == d.obj) {
            _ = ast.variable_list.orderedRemove(i);
            break;
        };
    }
    const args = try std.mem.join(a, ",", sh.args);
    const fun = try Obj.newFunction(ast, line_no, sh.name, .{ .args = args, .result_type = result_type });
    fun.procData().stmt_function = true;
    if (decl) |d| fun.doc_str = d.obj.doc_str;
    try ast.addScope(fun, &R().END_FUN, true, false);
    // its dummy arguments have the types of the variables of their names,
    // or the implicit types of the names
    for (sh.args) |arg| {
        if (declared(cs, arg)) |host| {
            const hv = host.obj.varDataConst();
            try ast.addVariable(try Obj.newVariable(ast, line_no, arg, hv.desc, &.{}, .{ .kind = hv.vkind }));
        } else if (implicit.typeOf(cs, arg)) |t| {
            try ast.addVariable(try Obj.newVariable(ast, line_no, arg, t, &.{}, .{}));
        }
    }
    if (result_type) |rt| try ast.addVariable(try Obj.newVariable(ast, line_no, sh.name, rt, &.{}, .{ .kind = result_kind }));
    ast.last_obj = fun;
    try ast.endScope(line_no, false);
    return true;
}

fn notOne(state: *State, a: Allocator, ast: *const Ast) !bool {
    try state.markExec(a, ast);
    return false;
}

test shape {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = (try shape(a, "  sf(i, j) = i * 2 + j")).?;
    try std.testing.expectEqualStrings("sf", s.name);
    try std.testing.expectEqual(@as(usize, 2), s.args.len);
    try std.testing.expectEqualStrings("j", s.args[1]);
    try std.testing.expectEqualStrings("i * 2 + j", s.expr);
    try std.testing.expectEqual(@as(usize, 0), (try shape(a, "f() = 1")).?.args.len);
    // an element, a section, a substring, a comparison, a pointer assignment
    try std.testing.expect(try shape(a, "a(1) = 0") == null);
    try std.testing.expect(try shape(a, "a(i:j) = 0") == null);
    try std.testing.expect(try shape(a, "a(i, i) = 0") == null);
    try std.testing.expect(try shape(a, "if (a(i) == 0) x = 1") == null);
    try std.testing.expect(try shape(a, "p(i) => t") == null);
    try std.testing.expect(try shape(a, "x = 1") == null);
    try std.testing.expect(try shape(a, "a(i)%b = 1") == null);
}

test isExecutable {
    try std.testing.expect(isExecutable("a(1) = 0"));
    try std.testing.expect(isExecutable("x%y(2)[1] = f(1, 'a=b')"));
    try std.testing.expect(isExecutable("  CALL S(X)"));
    try std.testing.expect(isExecutable("print *, x"));
    try std.testing.expect(isExecutable("if (a == b) c = 1"));
    try std.testing.expect(!isExecutable("data x /1/"));
    try std.testing.expect(!isExecutable("common /c/ a(10)"));
    try std.testing.expect(!isExecutable("equivalence (a, b)"));
    try std.testing.expect(!isExecutable("format (i5)"));
    try std.testing.expect(!isExecutable("p(i) => t"));
    try std.testing.expect(!isExecutable("a(i) == b"));
}
