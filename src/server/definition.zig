//! Go to definition and implementation, hover, include files, selection
//! ranges and document links.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const regex = @import("../regex.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const constructs = @import("../constructs.zig");
const selection = @import("../selection.zig");
const semantic = @import("../semantic.zig");
const implicit = @import("../implicit.zig");
const directives = @import("../data/directives.zig");
const operators = @import("operators.zig");
const literals = @import("../literals.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const srv = @import("../server.zig");
const Server = srv.Server;
const workspace = @import("workspace.zig");
const signature = @import("signature.zig");

/// A temporary variable allocated in `a` (not owned by any AST)
pub fn tempVariable(a: Allocator, file_ast: *Ast, line: usize, name: []const u8, desc: []const u8, keywords: []const C.Kw) !*Obj {
    const o = try a.create(Obj);
    o.* = .{
        .kind = .variable,
        .name = name,
        .file_ast = file_ast,
        .sline = line,
        .eline = line,
        .fqsn = try std.ascii.allocLowerString(a, name),
        .data = .{ .variable = .{ .desc = desc } },
    };
    try o.keywords.appendSlice(a, keywords);
    if (file_ast.enc_scope_name) |enc| o.fqsn = try std.mem.concat(a, u8, &.{ try std.ascii.allocLowerString(a, enc), "::", try std.ascii.allocLowerString(a, name) });
    o.varData().callable = R().CLASS_VAR.match(desc) != null;
    if (o.hasKeyword(C.KW.public)) o.vis = .public;
    if (o.hasKeyword(C.KW.private)) o.vis = .private;
    if (o.hasKeyword(C.KW.parameter)) o.varData().is_const = true;
    return o;
}

/// `get_definition` with `def_char` as a byte offset on the line
pub fn getDefinition(self: *Server, a: Allocator, def_file: *FortranFile, def_line: usize, def_char: usize, hover_req: bool) !?*Obj {
    const ast = def_file.ast orelse return null;
    const cl = try def_file.getCodeLine(a, def_line, false, true, false, true);
    const curr_line = cl.curr orelse return null;
    const line_prefix = (try helpers.getLinePrefix(a, cl.pre, curr_line, def_char, false)) orelse return null;
    const var_stack = try helpers.getVarStack(a, line_prefix);
    const is_member = var_stack.len > 1;
    const def_name = helpers.expandName(curr_line, def_char);
    if (def_name.len == 0) return null;
    // On a USE statement, both names of a rename are the module's entity
    if (try useRenameTarget(self, a, ast, curr_line, def_char, def_name)) |o| return o;
    // Search in Preprocessor defined variables
    if (def_file.pp_defs.get(def_name)) |d| {
        var arg_str: []const u8 = "";
        if (d.args) |args| {
            var parts: std.ArrayList([]const u8) = .empty;
            for (try str.split(a, args, ",")) |p| try parts.append(a, str.strip(p));
            arg_str = try std.fmt.allocPrint(a, "({s})", .{try std.mem.join(a, ", ", parts.items)});
        }
        const desc = try std.fmt.allocPrint(a, "#define {s}{s} {s}", .{ def_name, arg_str, d.value });
        return try tempVariable(a, ast, def_line + 1, def_name, desc, &.{});
    }
    var curr_scope = ast.getInnerScope(def_line + 1);
    if (is_member) {
        curr_scope = (try objects.climbTypeTree(self.env(a), var_stack, curr_scope)) orelse return null;
    }
    var var_obj: ?*Obj = null;
    if (curr_scope) |cs0| {
        var cs = cs0;
        if (cs.getType(false) == C.TypeId.class and !is_member) {
            const lp = str.lstrip(line_prefix);
            if ((std.mem.startsWith(u8, lp, "procedure") and std.mem.count(u8, line_prefix, "=>") > 0) or R().TYPE_DEF_CTX.match(line_prefix) != null) {
                if (cs.parent) |p| cs = p;
            }
        }
        var_obj = try objects.findInScope(self.env(a), cs, def_name, .{ .var_line_number = def_line + 1 });
        curr_scope = cs;
    }
    if (var_obj) |v| return v;
    if (is_member) return null;
    const key = try std.ascii.allocLowerString(a, def_name);
    // the file's own global definition before another file's of the
    // same name (fortls gets this from parsing the open file last)
    if (ast.global_dict.get(key)) |o| return o;
    if (self.obj_tree.get(key)) |e| return e.obj;
    for (self.intr.funs) |f| if (std.ascii.eqlIgnoreCase(f.name, key)) return f;
    if (hover_req) if (curr_scope) |cs| {
        var var_type: ?[]const u8 = null;
        if (R().NUMBER.match(def_name) != null) {
            if (std.mem.indexOfAny(u8, def_name, ".ed") != null) {
                var_type = C.FORTRAN_LITERAL ++ "REAL";
            } else {
                var_type = C.FORTRAN_LITERAL ++ "INTEGER";
            }
        } else if (R().LOGICAL.match(def_name) != null) {
            var_type = C.FORTRAN_LITERAL ++ "LOGICAL";
        } else if (R().SQ_STRING.match(def_name) != null or R().DQ_STRING.match(def_name) != null) {
            var_type = C.FORTRAN_LITERAL ++ "STRING";
        }
        if (var_type) |vt| return try tempVariable(a, cs.file_ast, def_line + 1, def_name, vt, cs.keywords.items);
    };
    return null;
}

pub fn definitionAt(self: *Server, a: Allocator, params: lsp.PositionParams, hover_req: bool) !?struct { file: *FortranFile, obj: *Obj, line: usize, col: usize } {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
    const pos = params.position;
    const col = Server.toByteCol(file, pos.line, pos.character);
    const obj = (try getDefinition(self, a, file, pos.line, col, hover_req)) orelse return null;
    return .{ .file = file, .obj = obj, .line = pos.line, .col = col };
}

pub fn createRefLink(self: *Server, a: Allocator, obj: *Obj) !Value {
    _ = self;
    const obj_file = obj.file_ast.file.?;
    const res = try obj_file.findWordInCodeLine(a, obj.sline -| 1, obj.name, true, false, false);
    const found = res.range.start >= 0;
    const schar: usize = if (found) @intCast(res.range.start) else 0;
    const echar: usize = if (found) @intCast(res.range.end) else 0;
    return json.from(a, Server.locationOf(try paths.pathToUri(a, obj_file.path), obj_file, res.line, schar, res.line, echar));
}

/// The module entity that the name at `col` stands for when it is one of
/// the two names of a rename on a USE statement, `use m, local => original`
/// (hansec #137): the original name is not visible under that name in the
/// using scope, and a variable there may even have it.
pub fn useRenameTarget(self: *Server, a: Allocator, ast: *Ast, line: []const u8, col: usize, name: []const u8) !?*Obj {
    const m = R().USE.match(line) orelse return null;
    if (col < m.end(0)) return null;
    var start = @min(col, line.len);
    while (start > 0 and regex.isWordChar(line[start - 1])) start -= 1;
    const before = str.rstrip(line[0..start]);
    var end = start;
    while (end < line.len and regex.isWordChar(line[end])) end += 1;
    const after = str.lstrip(line[end..]);
    const lower = try std.ascii.allocLowerString(a, name);
    const original = if (std.mem.endsWith(u8, before, "=>"))
        lower
    else if (std.mem.startsWith(u8, after, "=>")) blk: {
        const rest = str.lstrip(after[2..]);
        var n: usize = 0;
        while (n < rest.len and regex.isWordChar(rest[n])) n += 1;
        if (n == 0) return null;
        break :blk try std.ascii.allocLowerString(a, rest[0..n]);
    } else return null;
    const e = self.env(a);
    const mod = e.global(ast, try std.ascii.allocLowerString(a, m.group(2).?)) orelse return null;
    return objects.findInScope(e, mod, original, .{});
}

/// The include directories as absolute paths (relative ones are relative
/// to the workspace root)
pub fn includeDirs(self: *Server, a: Allocator) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    for (self.s.include_dirs.slice()) |d| try dirs.append(a, if (std.fs.path.isAbsolute(d)) d else try paths.join(a, &.{ self.root_path, d }));
    return dirs.items;
}

/// The file that the `#include` directive (or, with `statement`, the
/// INCLUDE statement) under the cursor names, searched in the directory
/// of the including file and in the include directories (upstream #498,
/// #301)
pub fn includeDirectiveTarget(self: *Server, a: Allocator, params: lsp.PositionParams, statement: bool) !?[]const u8 {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
    const text = file.getLine(params.position.line, false) orelse return null;
    const re = if (statement) &R().INCLUDE else &R().INCLUDE_DIRECTIVE;
    const m = re.match(text) orelse return null;
    const col = Server.toByteCol(file, params.position.line, params.position.character);
    if (col < m.start(1) or col > m.end(1)) return null;
    return resolveInclude(self, a, file, m.group(1).?);
}

/// The file an `#include` or `INCLUDE` of `name` in `file` reads: next
/// to the file, else in the include directories
pub fn resolveInclude(self: *Server, a: Allocator, file: *const FortranFile, name: []const u8) !?[]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.append(a, paths.dirname(file.path));
    try dirs.appendSlice(a, try includeDirs(self, a));
    for (dirs.items) |dir| {
        const candidate = try paths.abspath(a, try paths.join(a, &.{ dir, name }));
        if (paths.isFile(self.io, candidate)) return candidate;
    }
    return null;
}

/// Links on the file names of `#include` directives and `INCLUDE`
/// statements whose files are found
pub fn serveDocumentLinks(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    var out: std.ArrayList(lsp.DocumentLink) = .empty;
    for (0..file.nLines()) |i| {
        const text = file.getLine(i, false) orelse continue;
        const m = R().INCLUDE_DIRECTIVE.match(text) orelse R().INCLUDE.match(text) orelse continue;
        const target = (try resolveInclude(self, a, file, m.group(1).?)) orelse continue;
        try out.append(a, .{ .range = Server.rangeOf(file, i, m.start(1), i, m.end(1)), .target = try paths.pathToUri(a, target) });
    }
    return json.from(a, out.items);
}

/// The selection ranges around each position: name, parentheses,
/// statement, constructs and program units, file
pub fn serveSelectionRanges(self: *Server, a: Allocator, params: lsp.SelectionRangeParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const out = try a.alloc(lsp.SelectionRange, params.positions.len);
    for (params.positions, out) |p, *o| {
        const col = Server.toByteCol(file, p.line, p.character);
        const spans = try selection.around(a, file, ast, p.line, col);
        var parent: ?*const lsp.SelectionRange = null;
        var i = spans.len;
        while (i > 0) {
            i -= 1;
            const s = spans[i];
            const node = try a.create(lsp.SelectionRange);
            node.* = .{ .range = Server.rangeOf(file, s.sline, s.scol, s.eline, s.ecol), .parent = parent };
            parent = node;
        }
        o.* = if (parent) |n| n.* else .{ .range = Server.rangeOf(file, p.line, col, p.line, col) };
    }
    return json.from(a, out);
}

/// The construct name or statement label at a position, with its file
pub fn constructAt(self: *Server, a: Allocator, params: lsp.PositionParams) !?struct { file: *FortranFile, target: constructs.Target } {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
    const ast = file.ast orelse return null;
    const col = Server.toByteCol(file, params.position.line, params.position.character);
    const t = (try constructs.at(a, file, ast, params.position.line, col)) orelse return null;
    return .{ .file = file, .target = t };
}

pub fn constructLocations(a: Allocator, uri: []const u8, file: *const FortranFile, spans: []const constructs.Span) ![]const lsp.Location {
    const out = try a.alloc(lsp.Location, spans.len);
    for (spans, out) |s, *o| o.* = Server.locationOf(uri, file, s.line, s.start, s.line, s.end);
    return out;
}

/// The user-defined operator at a position (`.ord.`)
pub fn operatorAt(self: *Server, a: Allocator, params: lsp.PositionParams) !?[]const u8 {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
    const line = params.position.line;
    return operators.at(a, file, line, Server.toByteCol(file, line, params.position.character));
}

pub fn serveDefinition(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    if (try operatorAt(self, a, params)) |op| return operators.definition(self, a, op);
    if (try constructAt(self, a, params)) |c| {
        const d = c.target.def orelse return .null;
        return json.from(a, Server.locationOf(try paths.pathToUri(a, c.file.path), c.file, d.line, d.start, d.line, d.end));
    }
    const start: lsp.Position = .{ .line = 0, .character = 0 };
    if (try includeDirectiveTarget(self, a, params, false)) |target| {
        return json.from(a, lsp.Location{ .uri = try paths.pathToUri(a, target), .range = .{ .start = start, .end = start } });
    }
    if (try definitionAt(self, a, params, false)) |d| {
        if (try signature.genericSpecific(self, a, d.file, d.line, d.col, d.obj)) |s| if (s.file_ast.file != null) return createRefLink(self, a, preferredBody(self, s));
        const target = preferredBody(self, d.obj);
        if (target.file_ast.file != null) return createRefLink(self, a, target);
        return .null;
    }
    // an INCLUDE statement is its own definition when its file is in the
    // workspace; open one that is not
    if (try includeDirectiveTarget(self, a, params, true)) |target| {
        return json.from(a, lsp.Location{ .uri = try paths.pathToUri(a, target), .range = .{ .start = start, .end = start } });
    }
    return .null;
}

/// The subroutine or function that an EXTERNAL declaration stands for: the
/// global procedure of that name, if there is one (upstream #483, #23)
pub fn externalTarget(self: *Server, a: Allocator, ast: *Ast, v: *const Obj) !?*Obj {
    if (v.kind != .variable or !v.varDataConst().is_external) return null;
    const key = try std.ascii.allocLowerString(a, v.name);
    const cand = ast.global_dict.get(key) orelse (if (self.obj_tree.get(key)) |e| e.obj else return null);
    return switch (cand.kind) {
        .subroutine, .function => cand,
        else => null,
    };
}

/// The global function that a variable of the same name stands for when it
/// is called: `real fff` in the caller and then `fff(1.2, 3.3)` declares
/// the type of the function, not a variable (upstream #118)
pub fn calledFunction(self: *Server, a: Allocator, ast: *Ast, d: anytype) !?*Obj {
    const v = d.obj;
    if (v.kind != .variable or v.varData().is_const or v.hasKeyword(C.KW.dimension) or v.keyword_info.dimension != null) return null;
    if (v.parent) |p| if (p.getType(false) == C.TypeId.class) return null;
    const text = d.file.getLine(d.line, false) orelse return null;
    var end = d.col;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    if (!std.mem.startsWith(u8, str.lstrip(text[end..]), "(")) return null;
    const key = try std.ascii.allocLowerString(a, v.name);
    const cand = ast.global_dict.get(key) orelse (if (self.obj_tree.get(key)) |e| e.obj else return null);
    return if (cand.kind == .function) cand else null;
}

/// With `prefer_implementation`, the implementation of a procedure that
/// `obj` declares in an interface (a separate module procedure's body in
/// a submodule, upstream #501 #502), else `obj`
pub fn preferredBody(self: *Server, obj: *Obj) *Obj {
    if (!self.s.prefer_implementation) return obj;
    if (obj.kind != .subroutine and obj.kind != .function) return obj;
    const parent = obj.parent orelse return obj;
    if (parent.getType(false) != C.TypeId.interface) return obj;
    const impl = obj.linkObj() orelse return obj;
    if (impl.file_ast.file == null or (impl.kind != .subroutine and impl.kind != .function)) return obj;
    return impl;
}

/// Hover on a name that is not declared: the type implicit typing gives it
/// (hansec #201), unless IMPLICIT NONE applies
/// Hover on a literal constant: its type (fortls #125); fortls shows only
/// REAL, INTEGER, LOGICAL or CHARACTER(LEN=n), without kinds
fn literalHover(self: *Server, a: Allocator, params: lsp.PositionParams) !?Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
    const line = params.position.line;
    const text = file.getLine(line, false) orelse return null;
    if (helpers.isComment(file.fixed, text)) return null;
    const lit = (try literals.at(a, text, Server.toByteCol(file, line, params.position.character))) orelse return null;
    const docs = if (lit.value) |v|
        try std.fmt.allocPrint(a, "Literal constant (BOZ), value {d}", .{v})
    else if (std.mem.eql(u8, lit.type, "BOZ"))
        "Literal constant (BOZ)"
    else
        "Literal constant";
    return try json.from(a, lsp.Hover{ .contents = .{ .value = try createHover(self, a, lit.type, docs) } });
}

fn implicitHover(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const line = params.position.line;
    const col = Server.toByteCol(file, line, params.position.character);
    const st = selection.statementLines(file, line);
    for (try semantic.unknownNames(a, self.env(a), file, ast, self.intr.funs, st.first, st.last, self.fixedLimit())) |u| {
        if (u.line != line or col < u.start or col > u.end) continue;
        const t = implicit.typeOf(u.scope, u.name) orelse return .null;
        const msg = try std.fmt.allocPrint(a, "{s} :: {s}", .{ t, u.name });
        return json.from(a, lsp.Hover{ .contents = .{ .value = try createHover(self, a, msg, "Implicitly typed (not declared)") } });
    }
    return keywordHover(self, a, file, line, col);
}

/// Hover on a word of an OpenMP (`!$omp`) or OpenACC (`!$acc`) directive
/// (also `c$omp`, `*$omp` in fixed form): its documentation
fn directiveHover(self: *Server, a: Allocator, text: []const u8, col: usize) !?Value {
    const t = std.mem.trimStart(u8, text, " \t");
    if (t.len < 5 or !(t[0] == '!' or t[0] == 'c' or t[0] == 'C' or t[0] == '*') or t[1] != '$') return null;
    const omp = std.ascii.eqlIgnoreCase(t[2..5], "omp");
    if (!omp and !std.ascii.eqlIgnoreCase(t[2..5], "acc")) return null;
    const start = text.len - t.len + 5;
    const c = @min(col, text.len);
    if (c < start) return null;
    var s = c;
    while (s > start and (std.ascii.isAlphanumeric(text[s - 1]) or text[s - 1] == '_')) s -= 1;
    var e = c;
    while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_')) e += 1;
    if (e == s) return null;
    const table: []const directives.Directive = if (omp) &directives.omp else &directives.acc;
    for (table) |d| if (std.ascii.eqlIgnoreCase(d.name, text[s..e])) {
        const title = try std.fmt.allocPrint(a, "{s} {s}", .{ if (omp) "!$OMP" else "!$ACC", try std.ascii.allocUpperString(a, d.name) });
        const docs = try std.fmt.allocPrint(a, "{s}\n\n{s} directive", .{ d.doc, if (omp) "OpenMP" else "OpenACC" });
        return try json.from(a, lsp.Hover{ .contents = .{ .value = try createHover(self, a, title, docs) } });
    };
    return null;
}

/// Hover on a statement or attribute keyword: its documentation (fortls
/// #547)
fn keywordHover(self: *Server, a: Allocator, file: *FortranFile, line: usize, col: usize) !Value {
    const text = file.getLine(line, false) orelse return .null;
    if (try directiveHover(self, a, text, col)) |v| return v;
    if (helpers.isComment(file.fixed, text)) return .null;
    const code = try helpers.stripStrings(a, text, true);
    const c = @min(col, code.len);
    if (std.mem.indexOfScalar(u8, code[0..c], '!') != null) return .null;
    var s = c;
    while (s > 0 and (std.ascii.isAlphanumeric(code[s - 1]) or code[s - 1] == '_')) s -= 1;
    var e = c;
    while (e < code.len and (std.ascii.isAlphanumeric(code[e]) or code[e] == '_')) e += 1;
    if (e == s or !semantic.isKeyword(code[s..e])) return .null;
    var arg: ?[]const u8 = null;
    var k = e;
    while (k < code.len and code[k] == ' ') k += 1;
    if (k < code.len and code[k] == '(') if (std.mem.indexOfScalarPos(u8, code, k, ')')) |close| {
        arg = code[k + 1 .. close];
    };
    const kw = (try self.intr.keywordDoc(a, code[s..e], arg)) orelse return .null;
    const docs = try std.fmt.allocPrint(a, "{s}\n\nFortran keyword", .{kw.doc});
    return json.from(a, lsp.Hover{ .contents = .{ .value = try createHover(self, a, kw.name, docs) } });
}

pub fn serveHover(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    if (try operatorAt(self, a, params)) |op| return operators.hover(self, a, op);
    const d = (try definitionAt(self, a, params, true)) orelse {
        if (try literalHover(self, a, params)) |v| return v;
        return implicitHover(self, a, params);
    };
    if (std.mem.startsWith(u8, d.obj.descOf(), C.FORTRAN_LITERAL)) if (try literalHover(self, a, params)) |v| return v;
    const ast = d.file.ast.?;
    var var_obj = (try externalTarget(self, a, ast, d.obj)) orelse (try calledFunction(self, a, ast, d)) orelse d.obj;
    // the implementation's documentation, or the interface's when it has none
    const body = preferredBody(self, var_obj);
    if (body != var_obj) {
        const bh = try body.getHover(a, true, null);
        if (bh.docs != null and bh.docs.?.len > 0) var_obj = body;
    }
    const lang_fence = try std.fmt.allocPrint(a, "```{s}", .{self.s.hover_language});
    var hover_array: std.ArrayList([]const u8) = .empty;
    const vt = var_obj.getType(false);
    if (vt == C.TypeId.subroutine or vt == C.TypeId.function or vt == C.TypeId.module or vt == C.TypeId.class) {
        try hover_array.append(a, try str.replaceFirst(a, try var_obj.getHoverMd(a, true, null), "```{langid}", lang_fence));
    } else if (vt == C.TypeId.interface) {
        for (var_obj.memList()) |member| {
            const h = try member.getHover(a, true, null);
            if (h.msg != null) try hover_array.append(a, try createHover(self, a, h.msg, h.docs));
        }
    } else if (vt == C.TypeId.variable) {
        if (!std.mem.startsWith(u8, var_obj.descOf(), C.FORTRAN_LITERAL)) {
            try hover_array.append(a, try str.replaceFirst(a, try var_obj.getHoverMd(a, true, null), "```{langid}", lang_fence));
        } else if (std.mem.endsWith(u8, var_obj.descOf(), "REAL")) {
            try hover_array.append(a, try createHover(self, a, "REAL", null));
        } else if (std.mem.endsWith(u8, var_obj.descOf(), "INTEGER")) {
            try hover_array.append(a, try createHover(self, a, "INTEGER", null));
        } else if (std.mem.endsWith(u8, var_obj.descOf(), "LOGICAL")) {
            try hover_array.append(a, try createHover(self, a, "LOGICAL", null));
        } else if (std.mem.endsWith(u8, var_obj.descOf(), "STRING")) {
            const n = str.codepointLen(var_obj.name);
            try hover_array.append(a, try createHover(self, a, try std.fmt.allocPrint(a, "CHARACTER(LEN={d})", .{@as(i64, @intCast(n)) - 2}), null));
        }
    }
    if (hover_array.items.len == 0) return .null;
    return json.from(a, lsp.Hover{ .contents = .{ .value = try std.mem.join(a, "\n", hover_array.items) } });
}

/// `fortran_md(...).format(langid=...)`
pub fn createHover(self: *Server, a: Allocator, msg: ?[]const u8, docs: ?[]const u8) ![]const u8 {
    const md = try helpers.fortranMd(a, msg, docs);
    return srv.pyFormatLangid(a, md, self.s.hover_language);
}

pub fn serveImplementation(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const d = (try definitionAt(self, a, params, false)) orelse return .null;
    const var_obj = d.obj;
    if (var_obj.kind == .intrinsic) return .null;
    if (try externalTarget(self, a, d.file.ast.?, var_obj)) |target| {
        if (target.file_ast.file != null) return createRefLink(self, a, target);
        return .null;
    }
    const parent = var_obj.parent orelse return .null;
    if (parent.getType(false) == C.TypeId.class) {
        if (var_obj.linkObj()) |impl| if (impl.file_ast.file != null) return createRefLink(self, a, impl);
    } else if (parent.getType(false) == C.TypeId.interface) {
        if (var_obj.linkObj()) |impl| return createRefLink(self, a, impl);
    }
    return .null;
}
