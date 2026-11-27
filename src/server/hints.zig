//! Inlay hints (`textDocument/inlayHint`): the names of the dummy arguments
//! that the positional arguments of a call to a workspace procedure go to,
//! the types of ASSOCIATE names, the implicit type of a name that is not
//! declared where it is first written in the range, and the values of named
//! constants where they are used.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const str = @import("../str.zig");
const selection = @import("../selection.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const definition = @import("definition.zig");
const argument_hover = @import("argument_hover.zig");
const signature = @import("signature.zig");
const semantic = @import("../semantic.zig");
const implicit = @import("../implicit.zig");

pub fn serveInlayHints(self: *Server, a: Allocator, params: lsp.InlayHintParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    if (file.nLines() == 0) return json.from(a, &[_]lsp.InlayHint{});
    const first = params.range.start.line;
    const last = @min(params.range.end.line, file.nLines() - 1);
    var out: std.ArrayList(lsp.InlayHint) = .empty;
    var ln = first;
    while (ln <= last) : (ln += 1) try argumentHints(self, a, file, ln, &out);
    for (ast.scope_list.items) |sc| {
        if (sc.kind != .associate or sc.sline == 0 or sc.sline - 1 < first or sc.sline - 1 > last) continue;
        try associateHints(a, file, sc, &out);
    }
    try closingHints(self, a, file, ast, first, last, &out);
    // the values of named constants, once per line and name
    var shown: std.StringHashMapUnmanaged(void) = .empty;
    for (try semantic.constantUses(a, self.env(a), file, ast, first, last)) |c| {
        const value = str.strip(c.obj.varDataConst().param_val orelse continue);
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, c.obj.name)) continue;
        const key = try a.print("{d}:{x}", .{ c.line, @intFromPtr(c.obj) });
        if ((try shown.getOrPut(a, key)).found_existing) continue;
        const short = if (value.len > 24) try a.print("{s}...", .{value[0..21]}) else value;
        try out.append(a, .{
            .position = .{ .line = c.line, .character = Server.toLspCol(file, c.line, c.end) },
            .label = try linked(self, a, try a.print("= {s}", .{short}), c.obj),
            .kind = 1,
            .paddingLeft = true,
        });
    }
    // implicit types (hansec #201): once per scope and name
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try semantic.unknownNames(a, self.env(a), file, ast, self.intr.funs, first, last, self.fixedLimit())) |u| {
        const t = implicit.typeOf(u.scope, u.name) orelse continue;
        const key = try a.print("{x}:{s}", .{ @intFromPtr(u.scope), try std.ascii.allocLowerString(a, u.name) });
        if ((try seen.getOrPut(a, key)).found_existing) continue;
        try out.append(a, .{
            .position = .{ .line = u.line, .character = Server.toLspCol(file, u.line, u.end) },
            .label = .{ .string = try a.print(": {s}", .{t}) },
            .kind = 1,
        });
    }
    return json.from(a, out.items);
}

/// `name:` before each positional argument of the calls on 0-based line
/// `ln` (on the line of their parenthesis), unless the argument is that
/// name already
fn argumentHints(self: *Server, a: Allocator, file: *FortranFile, ln: usize, out: *std.ArrayList(lsp.InlayHint)) !void {
    const raw = file.getLine(ln, false) orelse return;
    if (helpers.isComment(file.fixed, raw)) return;
    var code = try helpers.stripStrings(a, raw, true);
    if (std.mem.findScalar(u8, code, '!')) |i| code = code[0..i];
    var it = helpers.words(code);
    while (it.next()) |w| {
        var j = w.end;
        while (j < code.len and code[j] == ' ') j += 1;
        // a CUDA Fortran kernel launch, `k<<<grid, block>>>(args)`
        if (std.mem.startsWith(u8, code[j..], "<<<")) {
            const e = std.mem.findPos(u8, code, j, ">>>") orelse continue;
            j = e + 3;
            while (j < code.len and code[j] == ' ') j += 1;
        }
        if (j >= code.len or code[j] != '(') continue;
        const close = matchingParen(code, j) orelse continue;
        var obj = (try definition.getDefinition(self, a, file, ln, w.start, false)) orelse continue;
        // the caller's own declaration of a procedure it calls (#232)
        if (file.ast) |ast| if (try objects.declaredProcedure(self.env(a), ast, self.workspace.values(), obj, true)) |p| {
            obj = p;
        };
        const target = switch (obj.kind) {
            .subroutine, .function, .method => obj,
            .interface => (try signature.genericSpecific(self, a, file, ln, w.start, obj)) orelse continue,
            else => continue,
        };
        if (target.file_ast.file == null) continue;
        const sig = try target.getSignature(a, null);
        if (sig.params.len == 0) continue;
        var i: usize = 0;
        var start = j + 1;
        var depth: usize = 0;
        var k = j + 1;
        while (k <= close) : (k += 1) {
            const c = code[k];
            if (c == '(' or c == '[') depth += 1;
            if ((c == ')' or c == ']') and k != close) depth -|= 1;
            if (k != close and !(c == ',' and depth == 0)) continue;
            const arg = code[start..k];
            start = k + 1;
            defer i += 1;
            if (i >= sig.params.len) break;
            const text = str.strip(arg);
            if (text.len == 0) continue;
            // keyword arguments come after the positional ones
            if (keywordOf(text) != null) break;
            const name = str.strip(str.beforeFirst(sig.params[i].label, "="));
            if (name.len == 0 or std.ascii.eqlIgnoreCase(text, name)) continue;
            const at = @intFromPtr(text.ptr) - @intFromPtr(code.ptr);
            try out.append(a, .{
                .position = .{ .line = ln, .character = Server.toLspCol(file, ln, at) },
                .label = if (argument_hover.dummyNamed(target, name)) |d| try linked(self, a, try a.print("{s}:", .{name}), d) else .{ .string = try a.print("{s}:", .{name}) },
                .kind = 2,
                .paddingRight = true,
            });
        }
    }
}

/// `: TYPE` after each name an ASSOCIATE statement defines
fn associateHints(a: Allocator, file: *FortranFile, sc: *Obj, out: *std.ArrayList(lsp.InlayHint)) !void {
    if (sc.data != .scope or sc.data.scope.ext != .associate) return;
    const st = selection.statementLines(file, sc.sline - 1);
    for (sc.data.scope.ext.associate.links.items) |l| {
        const h = try l.var_.getHover(a, false, null);
        const msg = h.msg orelse continue;
        const sep = std.mem.find(u8, msg, "::") orelse continue;
        const type_text = str.strip(msg[0..sep]);
        if (type_text.len == 0) continue;
        // the name, before its `=>`
        var ln = st.first;
        while (ln <= st.last) : (ln += 1) {
            const text = file.getLine(ln, false) orelse continue;
            var it = helpers.words(text);
            const end = while (it.next()) |w| {
                if (!std.ascii.eqlIgnoreCase(w.str, l.bind_name)) continue;
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, text[w.end..], " "), "=>")) break w.end;
            } else null;
            if (end) |e| {
                try out.append(a, .{
                    .position = .{ .line = ln, .character = Server.toLspCol(file, ln, e) },
                    .label = .{ .string = try a.print(": {s}", .{type_text}) },
                    .kind = 1,
                });
                break;
            }
        }
    }
}

/// The keyword of an argument, `dx` of `dx = 1.0`
fn keywordOf(arg: []const u8) ?[]const u8 {
    const eq = std.mem.findScalar(u8, arg, '=') orelse return null;
    if (eq + 1 < arg.len and (arg[eq + 1] == '=' or arg[eq + 1] == '>')) return null;
    if (eq > 0 and (arg[eq - 1] == '/' or arg[eq - 1] == '<' or arg[eq - 1] == '>')) return null;
    const name = str.strip(arg[0..eq]);
    if (name.len == 0) return null;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return null;
    return name;
}

/// The `)` that closes the `(` at `open`, on the line
fn matchingParen(code: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (code[open..], open..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// `text` as a hint's label of one part that links to `obj`'s declaration
/// (Ctrl+click goes there, #981); plain text for an object of no file
fn linked(self: *Server, a: Allocator, text: []const u8, obj: *Obj) !Value {
    if (obj.file_ast.file == null) return .{ .string = text };
    const location = try definition.createRefLink(self, a, obj);
    return json.from(a, &[_]struct { value: []const u8, location: Value }{.{ .value = text, .location = location }});
}

/// The name before a construct's statement, `outer` of `outer: do i = 1, n`
fn constructName(statement: []const u8) ?[]const u8 {
    var e: usize = 0;
    while (e < statement.len and (std.ascii.isAlphanumeric(statement[e]) or statement[e] == '_')) e += 1;
    if (e == 0) return null;
    const rest = std.mem.trimStart(u8, statement[e..], " \t");
    if (rest.len == 0 or rest[0] != ':' or (rest.len > 1 and rest[1] == ':')) return null;
    return statement[0..e];
}

/// The kinds of scope whose END has a closing hint
fn closes(k: objects.Kind) bool {
    return switch (k) {
        .module, .program, .submodule, .subroutine, .function, .type, .interface, .block, .do_, .if_, .where, .associate, .select, .enum_ => true,
        .scope, .include, .variable, .method, .intrinsic => false,
    };
}

/// After the END of each construct or procedure of `closing_hint_lines`
/// lines or more whose END is in lines `first` to `last` (0-based), its
/// opening statement (#981): `! do i = 1, n`. None where the END names it.
fn closingHints(self: *Server, a: Allocator, file: *FortranFile, ast: *objects.Ast, first: usize, last: usize, out: *std.ArrayList(lsp.InlayHint)) !void {
    const min = self.s.closing_hint_lines;
    if (min <= 0) return;
    for (ast.scope_list.items) |sc| {
        if (!closes(sc.kind) or sc.sline == 0 or sc.eline <= sc.sline) continue;
        const end_ln = sc.eline - 1;
        if (end_ln < first or end_ln > last or sc.eline - sc.sline + 1 < min) continue;
        const end_text = file.getLine(end_ln, false) orelse continue;
        const end_code = str.rstrip(helpers.beforeComment(end_text));
        if (!std.ascii.startsWithIgnoreCase(str.lstrip(end_code), "end")) continue;
        if (sc.name.len > 0 and helpers.findWordInLineIgnoreCase(end_code, sc.name).start >= 0) continue;
        const open = str.strip(helpers.beforeComment(file.getLine(sc.sline - 1, false) orelse continue));
        if (open.len == 0) continue;
        // a construct's name, `outer: do`, which its END names
        if (constructName(open)) |n| if (helpers.findWordInLineIgnoreCase(end_code, n).start >= 0) continue;
        const shown = if (open.len > 40) try a.print("{s}...", .{std.mem.trimEnd(u8, open[0..37], " &")}) else std.mem.trimEnd(u8, open, " &");
        try out.append(a, .{
            .position = .{ .line = end_ln, .character = Server.toLspCol(file, end_ln, end_code.len) },
            .label = .{ .string = try a.print("! {s}", .{shown}) },
            .paddingLeft = true,
        });
    }
}
