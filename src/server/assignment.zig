//! Defined assignment (`interface assignment(=)`, or `generic ::
//! assignment(=) => p` in a type; hansec #95): on the `=` of an assignment
//! to a variable of such a type, go to definition goes to the binding,
//! hover shows its procedures, and references are the binding and the
//! assignments it defines, in the workspace. The same from `assignment(=)`
//! on the binding's line.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const paths = @import("../paths.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;

/// Where an assignment is defined: the `assignment(=)` of an interface or
/// of a GENERIC statement in a type, and its procedures
pub const Binding = struct {
    file: *FortranFile,
    /// 0-based
    line: usize,
    start: usize,
    end: usize,
    procs: []const *Obj,
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The code of a 0-based line: strings blanked, without its comment
fn codeOf(a: Allocator, file: *const FortranFile, line: usize) !?[]const u8 {
    const text = file.getLine(line, false) orelse return null;
    if (helpers.isComment(file.fixed, text)) return null;
    var code = try helpers.stripStrings(a, text, true);
    if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
    return code;
}

/// The span of `assignment(=)` (spaces allowed) in `code`
fn assignmentSpan(code: []const u8) ?[2]usize {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(code, from, "assignment")) |s| : (from = s + 1) {
        if (s > 0 and isWord(code[s - 1])) continue;
        var i = s + "assignment".len;
        for ("(=)") |want| {
            while (i < code.len and code[i] == ' ') i += 1;
            if (i >= code.len or code[i] != want) break;
            i += 1;
        } else return .{ s, i };
    }
    return null;
}

/// The derived type of the variable that the `=` at byte `col` of 0-based
/// `line` assigns
fn assignedType(self: *Server, a: Allocator, file: *FortranFile, line: usize, col: usize) !?*Obj {
    const code = (try codeOf(a, file, line)) orelse return null;
    if (col >= code.len or code[col] != '=') return null;
    // not `==`, `=>`, `<=`, `>=`, `/=`
    if (col + 1 < code.len and (code[col + 1] == '=' or code[col + 1] == '>')) return null;
    if (col > 0 and std.mem.indexOfScalar(u8, "=<>/", code[col - 1]) != null) return null;
    // not a declaration's initializer, nor a keyword argument
    if (std.mem.indexOf(u8, code[0..col], "::") != null) return null;
    var depth: i64 = 0;
    for (code[0..col]) |c| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -= 1,
        else => {},
    };
    if (depth != 0) return null;
    // the variable: names, subscripts and `%`, back from the `=`
    var s = col;
    var names: std.ArrayList([]const u8) = .empty;
    while (true) {
        while (s > 0 and code[s - 1] == ' ') s -= 1;
        if (s > 0 and code[s - 1] == ')') {
            var d: usize = 0;
            while (s > 0) {
                s -= 1;
                if (code[s] == ')') d += 1;
                if (code[s] == '(') {
                    d -= 1;
                    if (d == 0) break;
                }
            }
            if (d != 0) return null;
            while (s > 0 and code[s - 1] == ' ') s -= 1;
        }
        const e = s;
        while (s > 0 and isWord(code[s - 1])) s -= 1;
        if (s == e or !std.ascii.isAlphabetic(code[s])) return null;
        try names.insert(a, 0, code[s..e]);
        var k = s;
        while (k > 0 and code[k - 1] == ' ') k -= 1;
        if (k > 0 and code[k - 1] == '%') {
            s = k - 1;
            continue;
        }
        s = k;
        break;
    }
    // the statement starts there, or after a label, `;` or the condition
    // of an IF or WHERE
    const before = std.mem.trim(u8, code[0..s], " ");
    if (before.len > 0) {
        const last = before[before.len - 1];
        if (!(last == ';' or last == ')' or std.ascii.isDigit(last))) return null;
        if (file.fixed and std.ascii.isDigit(last) and s > 6) return null;
    }
    const env = self.env(a);
    const ast = file.ast orelse return null;
    const scope = ast.getInnerScope(line + 1);
    const v = if (names.items.len == 1)
        try objects.findInScope(env, scope, try std.ascii.allocLowerString(a, names.items[0]), .{ .var_line_number = line + 1 })
    else blk: {
        const type_scope = (try objects.climbTypeTree(env, names.items, scope)) orelse return null;
        break :blk try objects.findInScope(env, type_scope, try std.ascii.allocLowerString(a, names.items[names.items.len - 1]), .{});
    };
    const t = (try (v orelse return null).getTypeObj(env)) orelse return null;
    return if (t.kind == .type) t else null;
}

/// The procedures named after `=>` on a GENERIC line of type `t`
fn boundProcs(self: *Server, a: Allocator, t: *Obj, code: []const u8) ![]const *Obj {
    var out: std.ArrayList(*Obj) = .empty;
    const arrow = std.mem.indexOf(u8, code, "=>") orelse return out.items;
    var it = std.mem.splitScalar(u8, code[arrow + 2 ..], ',');
    while (it.next()) |n| {
        const name = std.mem.trim(u8, n, " &");
        if (name.len == 0) continue;
        const m = (try objects.findInScope(self.env(a), t, try std.ascii.allocLowerString(a, name), .{ .local_only = true })) orelse continue;
        try out.append(a, m.linkObj() orelse m);
    }
    return out.items;
}

/// Whether the first dummy argument of `proc` is of type `t`
fn takes(self: *Server, a: Allocator, proc: *Obj, t: *Obj) !bool {
    const pd = proc.procDataOpt() orelse return false;
    if (pd.arg_objs.items.len == 0) return false;
    const arg = pd.arg_objs.items[0] orelse return false;
    const arg_type = (try arg.getTypeObj(self.env(a))) orelse return false;
    return arg_type == t or std.ascii.eqlIgnoreCase(arg_type.name, t.name);
}

/// The defined assignment of a variable of type `t`: a GENERIC binding in
/// it or a type it extends, else an interface for it
pub fn bindingOf(self: *Server, a: Allocator, t_in: *Obj) !?Binding {
    var t: ?*Obj = t_in;
    var n: usize = 0;
    while (t) |ty| : (t = ty.typeDataConst().inherit_var) {
        n += 1;
        if (n > 20) break;
        const f = ty.file_ast.file orelse continue;
        if (ty.sline == 0) continue;
        var ln = ty.sline - 1;
        const last = @min(ty.eline, f.nLines());
        while (ln < last) : (ln += 1) {
            const code = (try codeOf(a, f, ln)) orelse continue;
            const span = assignmentSpan(code) orelse continue;
            if (std.ascii.findIgnoreCase(code[0..span[0]], "generic") == null) continue;
            return .{ .file = f, .line = ln, .start = span[0], .end = span[1], .procs = try boundProcs(self, a, ty, code) };
        }
    }
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.scope_list.items) |sc| {
            if (sc.kind != .interface or sc.sline == 0) continue;
            const code = (try codeOf(a, f, sc.sline - 1)) orelse continue;
            const span = assignmentSpan(code) orelse continue;
            var procs: std.ArrayList(*Obj) = .empty;
            for (sc.memList()) |m| if (try takes(self, a, m, t_in)) try procs.append(a, m);
            if (procs.items.len > 0) return .{ .file = f, .line = sc.sline - 1, .start = span[0], .end = span[1], .procs = procs.items };
        }
    }
    return null;
}

/// The binding whose `assignment(=)` is at byte `col` of 0-based `line`
fn bindingAt(self: *Server, a: Allocator, file: *FortranFile, line: usize, col: usize) !?Binding {
    const code = (try codeOf(a, file, line)) orelse return null;
    const span = assignmentSpan(code) orelse return null;
    if (col < span[0] or col > span[1]) return null;
    const ast = file.ast orelse return null;
    const scope = ast.getInnerScope(line + 1) orelse return null;
    if (scope.kind == .type) {
        if (std.ascii.findIgnoreCase(code[0..span[0]], "generic") == null) return null;
        return .{ .file = file, .line = line, .start = span[0], .end = span[1], .procs = try boundProcs(self, a, scope, code) };
    }
    if (scope.kind == .interface and scope.sline == line + 1) {
        return .{ .file = file, .line = line, .start = span[0], .end = span[1], .procs = scope.memList() };
    }
    return null;
}

/// The defined assignment at a position: on the `=` of an assignment, or
/// on `assignment(=)` where it is defined
pub fn at(self: *Server, a: Allocator, file: *FortranFile, line: usize, col: usize) !?Binding {
    if (try bindingAt(self, a, file, line, col)) |b| return b;
    // on the `=`, or just after it
    for ([_]usize{ col, col -| 1 }) |c| {
        const t = (try assignedType(self, a, file, line, c)) orelse continue;
        return bindingOf(self, a, t);
    }
    return null;
}

pub fn definition(self: *Server, a: Allocator, b: Binding) !Value {
    _ = self;
    return json.from(a, Server.locationOf(try paths.pathToUri(a, b.file.path), b.file, b.line, b.start, b.line, b.end));
}

pub fn hover(self: *Server, a: Allocator, b: Binding) !Value {
    var parts: std.ArrayList([]const u8) = .empty;
    for (b.procs) |p| {
        const h = try p.getHover(a, true, null);
        if (h.msg != null) try parts.append(a, try helpers.fortranMd(a, h.msg, h.docs));
    }
    if (parts.items.len == 0) return .null;
    const md = try std.mem.join(a, "\n", parts.items);
    return json.from(a, lsp.Hover{ .contents = .{ .value = try srv.pyFormatLangid(a, md, self.s.hover_language) } });
}

/// The binding, and the assignments to variables whose type has it
pub fn references(self: *Server, a: Allocator, b: Binding) !Value {
    var out: std.ArrayList(lsp.Location) = .empty;
    try out.append(a, Server.locationOf(try paths.pathToUri(a, b.file.path), b.file, b.line, b.start, b.line, b.end));
    // the binding of each type, once
    var seen: std.AutoHashMapUnmanaged(*Obj, bool) = .empty;
    for (self.workspace.values()) |f| {
        if (f.ast == null) continue;
        var uri: ?[]const u8 = null;
        for (0..f.nLines()) |ln| {
            const code = (try codeOf(a, f, ln)) orelse continue;
            var from: usize = 0;
            while (std.mem.indexOfScalarPos(u8, code, from, '=')) |eq| : (from = eq + 1) {
                const t = (try assignedType(self, a, f, ln, eq)) orelse continue;
                const gop = try seen.getOrPut(a, t);
                if (!gop.found_existing) {
                    const tb = try bindingOf(self, a, t);
                    gop.value_ptr.* = tb != null and tb.?.file == b.file and tb.?.line == b.line;
                }
                if (!gop.value_ptr.*) continue;
                if (uri == null) uri = try paths.pathToUri(a, f.path);
                try out.append(a, Server.locationOf(uri.?, f, ln, eq, ln, eq + 1));
            }
        }
    }
    return json.from(a, out.items);
}
