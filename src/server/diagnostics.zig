//! Diagnostics (computing, filtering by settings and suppression comments,
//! publishing) and code actions.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const glob = @import("../glob.zig");
const autouse = @import("../autouse.zig");
const semantic = @import("../semantic.zig");
const suppress = @import("../suppress.zig");
const implicit = @import("../implicit.zig");
const selection = @import("../selection.zig");
const unused = @import("../unused.zig");
const modgraph = @import("../modgraph.zig");
const argcheck = @import("../argcheck.zig");
const rewrite = @import("../rewrite.zig");
const helpers = @import("../helpers.zig");
const str = @import("../str.zig");

const Ast = objects.Ast;
const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const completion = @import("completion.zig");

pub fn serveCodeActions(self: *Server, a: Allocator, params: lsp.CodeActionParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const sline = params.range.start.line;
    const eline = params.range.end.line;
    var out: std.ArrayList(lsp.CodeAction) = .empty;
    try addUseActions(self, a, file, ast, sline, eline, &out);
    try addDeclareActions(self, a, file, ast, sline, eline, &out);
    try addRemoveUnusedActions(self, a, file, ast, sline, eline, &out);
    try addRewriteActions(self, a, file, ast, sline, eline, &out);
    if (wants(params.context.only, "source")) try addKeywordCaseActions(self, a, file, ast, &out);
    const curr_scope = ast.getInnerScope(sline) orelse return if (out.items.len > 0) json.from(a, out.items) else .null;
    const actions = (try curr_scope.getActions(a, sline, eline)) orelse return if (out.items.len > 0) json.from(a, out.items) else .null;
    for (actions) |act| {
        const edit_file = self.fileForPath(act.uri_path);
        const edits = try a.alloc(lsp.TextEdit, act.edits.len);
        for (act.edits, edits) |e, *ev| {
            ev.* = .{ .range = Server.rangeOf(edit_file, e.sline, e.schar, e.eline, e.echar), .newText = e.new_text };
        }
        const files = try a.alloc(lsp.Changes.File, 1);
        files[0] = .{ .uri = try paths.pathToUri(a, act.uri_path), .edits = edits };
        const diags = try a.alloc(lsp.Diagnostic, act.diagnostics.len);
        for (act.diagnostics, diags) |dg, *dv| dv.* = try self.diagnosticOf(a, file, try dg.build(a, file));
        try out.append(a, .{ .title = act.title, .kind = act.kind, .edit = .{ .changes = .{ .files = files } }, .diagnostics = diags });
    }
    return json.from(a, out.items);
}

/// The names of `file` that stand for nothing found where IMPLICIT NONE
/// applies (hansec #129). Only in scopes whose USE statements (and those of
/// the scopes around them) all name modules zfls knows, and in files whose
/// INCLUDE files are all found, since a name could come from those.
pub fn undeclaredNames(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    if (file.nLines() == 0) return out.items;
    for (ast.include_statements.items) |inc| if (inc.file == null) return out.items;
    // fypp's loops, macros and variables make names zfls cannot see
    if (usesFypp(file)) return out.items;
    const names = try semantic.unknownNames(a, self.env(a), file, ast, self.intr.funs, 0, file.nLines() - 1, self.fixedLimit());
    if (names.len == 0) return out.items;
    // whether the modules each scope uses are all known
    var known: std.AutoHashMapUnmanaged(*Obj, bool) = .empty;
    const renamed = try reexportedRenames(self, a);
    for (names) |u| {
        const scope = u.scope orelse continue;
        if (implicit.typeOf(scope, u.name) != null) continue;
        if (renamed.contains(try std.ascii.allocLowerString(a, u.name))) continue;
        const gop = try known.getOrPut(a, scope);
        if (!gop.found_existing) gop.value_ptr.* = try usesKnownModules(self, a, ast, scope);
        if (!gop.value_ptr.*) continue;
        try out.append(a, .{
            .sln = u.line,
            .sch = u.start,
            .eln = u.line,
            .ech = u.end,
            .message = try std.fmt.allocPrint(a, "Name \"{s}\" is not declared (IMPLICIT NONE)", .{u.name}),
            .severity = C.Severity.warn,
            .code = .undeclared_name,
            .subject = u.name,
        });
    }
    return out.items;
}

/// The local names of the renames in the USE statements of the workspace's
/// modules (`use kinds, only: json_ck => ck`): a module that uses another
/// with a rename makes the local name public, which name lookup does not
/// follow yet, so such names are not reported as undeclared
fn reexportedRenames(self: *Server, a: Allocator) !std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    for (self.obj_tree.values()) |e| {
        if (e.obj.kind != .module or e.obj.data != .scope) continue;
        for (e.obj.scopeDataConst().use.items) |u| {
            for (u.rename_map.keys.items) |k| try out.put(a, k, {});
        }
    }
    return out;
}

/// Whether the client asks for actions of `kind` (all, when it names none)
fn wants(only: ?[]const []const u8, kind: []const u8) bool {
    const kinds = only orelse return false;
    for (kinds) |k| if (std.mem.startsWith(u8, k, kind) or std.mem.startsWith(u8, kind, k)) return true;
    return false;
}

fn action(a: Allocator, uri: []const u8, title: []const u8, kind: []const u8, edits: []const lsp.TextEdit) !lsp.CodeAction {
    const files = try a.alloc(lsp.Changes.File, 1);
    files[0] = .{ .uri = uri, .edits = edits };
    return .{ .title = title, .kind = kind, .edit = .{ .changes = .{ .files = files } }, .diagnostics = &.{} };
}

/// IMPLICIT NONE for a program unit without IMPLICIT statement (on its
/// first line); modern relational operators and kind parameters for the
/// lines of the range
pub fn addRewriteActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    _ = self;
    const uri = try paths.pathToUri(a, file.path);
    for (ast.scope_list.items) |sc| {
        switch (sc.kind) {
            .program, .module, .subroutine, .function => {},
            else => continue,
        }
        if (sc.sline == 0 or sc.sline - 1 < sline or sc.sline - 1 > eline) continue;
        if (sc.parent) |p| if (p.kind == .interface) continue;
        if (sc.getImplicit() != null) continue;
        const at = try autouse.insertionPoint(a, file, sc);
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = try std.fmt.allocPrint(a, "{s}implicit none\n", .{at.indent}) };
        try out.append(a, try action(a, uri, try std.fmt.allocPrint(a, "Add IMPLICIT NONE to {s}", .{sc.name}), "quickfix", edits));
    }
    var op_edits: std.ArrayList(lsp.TextEdit) = .empty;
    var kind_edits: std.ArrayList(lsp.TextEdit) = .empty;
    var ln = sline;
    while (ln <= eline and ln < file.nLines()) : (ln += 1) {
        const text = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, text)) continue;
        const whole = Server.rangeOf(file, ln, 0, ln, text.len);
        if (try rewrite.modernOperators(a, text)) |new| try op_edits.append(a, .{ .range = whole, .newText = new });
        if (try rewrite.kindParameters(a, text)) |new| try kind_edits.append(a, .{ .range = whole, .newText = new });
    }
    if (op_edits.items.len > 0) try out.append(a, try action(a, uri, "Write .eq. ... .ge. as == ... >=", "refactor.rewrite", op_edits.items));
    if (kind_edits.items.len > 0) try out.append(a, try action(a, uri, "Write the kinds given with * as kind parameters", "refactor.rewrite", kind_edits.items));
}

/// The keywords of the file in upper, lower or title case (hansec #226,
/// Modern Fortran #234): Source Actions; a name spelled like a keyword
/// keeps its case
pub fn addKeywordCaseActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, out: *std.ArrayList(lsp.CodeAction)) !void {
    const uri = try paths.pathToUri(a, file.path);
    const names = try semantic.namePositions(a, self.env(a), file, ast);
    const Case = rewrite.Case;
    const cases = [_]struct { case: Case, title: []const u8, kind: []const u8 }{
        .{ .case = .upper, .title = "Keywords in upper case", .kind = "source.keywordCase.upper" },
        .{ .case = .lower, .title = "Keywords in lower case", .kind = "source.keywordCase.lower" },
        .{ .case = .title, .title = "Keywords in title case", .kind = "source.keywordCase.title" },
    };
    for (cases) |cs| {
        var edits: std.ArrayList(lsp.TextEdit) = .empty;
        for (0..file.nLines()) |ln| {
            const raw = file.getLine(ln, false) orelse continue;
            if (helpers.isComment(file.fixed, raw)) continue;
            const t = std.mem.trimStart(u8, raw, " \t");
            if (t.len > 0 and t[0] == '#') continue;
            var code = try helpers.stripStrings(a, raw, true);
            if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
            var it = helpers.words(code);
            while (it.next()) |w| {
                // `.and.`, `.true.`: their words are keywords too
                const dotted = w.start > 0 and code[w.start - 1] == '.' and w.end < code.len and code[w.end] == '.';
                if (!dotted and !semantic.isKeyword(w.str)) continue;
                if (dotted and !isDotWord(w.str)) continue;
                if (names.contains(.{ ln, str.byteToUtf16(raw, w.start) })) continue;
                const new = try rewrite.inCase(a, w.str, cs.case);
                if (std.mem.eql(u8, new, w.str)) continue;
                try edits.append(a, .{ .range = Server.rangeOf(file, ln, w.start, ln, w.end), .newText = new });
            }
        }
        if (edits.items.len > 0) try out.append(a, try action(a, uri, cs.title, cs.kind, edits.items));
    }
}

fn isDotWord(w: []const u8) bool {
    for ([_][]const u8{ "and", "or", "not", "eqv", "neqv", "true", "false", "eq", "ne", "lt", "le", "gt", "ge" }) |k| {
        if (std.ascii.eqlIgnoreCase(w, k)) return true;
    }
    return false;
}

/// The calls of workspace procedures whose arguments do not fit them, and
/// assignments to INTENT(IN) arguments
pub fn argumentProblems(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    for (try argcheck.check(a, self.env(a), file, ast)) |p| try out.append(a, .{
        .sln = p.line,
        .sch = p.start,
        .eln = p.line,
        .ech = p.end,
        .message = p.message,
        .severity = C.Severity.err,
        .code = if (p.kind == .arguments) .argument_mismatch else .intent_in_assigned,
    });
    return out.items;
}

/// The modules and submodules of the workspace
pub fn workspaceUnits(self: *Server, a: Allocator) ![]const *Obj {
    var out: std.ArrayList(*Obj) = .empty;
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.scope_list.items) |sc| if (sc.kind == .module or sc.kind == .submodule) try out.append(a, sc);
    }
    return out.items;
}

/// `zfls/compileOrder`: the workspace's modules and submodules in an order
/// to compile them (each after those it uses), with the files that define
/// them, and the groups of modules that use each other
pub fn serveCompileOrder(self: *Server, a: Allocator) !Value {
    const g = try modgraph.build(a, try workspaceUnits(self, a));
    const Unit = struct { name: []const u8, kind: []const u8, uri: []const u8 };
    var order: std.ArrayList(Unit) = .empty;
    var cycles: std.ArrayList([]const []const u8) = .empty;
    for (g.components) |members| {
        for (members) |i| {
            const u = g.units[i];
            try order.append(a, .{
                .name = u.name,
                .kind = if (u.kind == .submodule) "submodule" else "module",
                .uri = try paths.pathToUri(a, u.file_ast.path orelse ""),
            });
        }
        if (members.len > 1 or g.inCycle(members[0])) {
            const names = try a.alloc([]const u8, members.len);
            for (members, names) |i, *n| n.* = g.units[i].name;
            try cycles.append(a, names);
        }
    }
    return json.from(a, .{ .order = order.items, .cycles = cycles.items });
}

/// The USE statements of `file` that close a cycle of modules using each
/// other, which compilers reject (`circular-use`)
pub fn circularUses(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    var mine = false;
    for (ast.scope_list.items) |sc| if (sc.kind == .module or sc.kind == .submodule) {
        mine = true;
    };
    if (!mine) return out.items;
    const g = try modgraph.build(a, try workspaceUnits(self, a));
    for (g.units, 0..) |u, i| {
        if (u.file_ast != ast or !g.inCycle(i)) continue;
        var names: std.ArrayList(u8) = .empty;
        for (g.components[g.comp[i]]) |j| {
            if (names.items.len > 0) try names.appendSlice(a, ", ");
            try names.appendSlice(a, g.units[j].name);
        }
        var uses: std.ArrayList(modgraph.Use) = .empty;
        try modgraph.usedModules(a, u, &uses);
        for (uses.items) |m| {
            const j = for (g.units, 0..) |v, k| {
                if (v.kind == .module and v.nameLowerEql(m.name)) break k;
            } else continue;
            if (g.comp[j] != g.comp[i] or m.line == 0) continue;
            const line = m.line - 1;
            const text = file.getLine(line, false) orelse continue;
            const col = std.ascii.findIgnoreCase(text, m.name) orelse 0;
            try out.append(a, .{
                .sln = line,
                .sch = col,
                .eln = line,
                .ech = col + m.name.len,
                .message = try std.fmt.allocPrint(a, "Circular USE: modules {s} use each other", .{names.items}),
                .severity = C.Severity.err,
                .code = .circular_use,
                .subject = m.name,
            });
        }
    }
    return out.items;
}

/// The local variables and USE ONLY names that their scope never uses,
/// shown faded (`unused-name`, a hint)
pub fn unusedNames(a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    for (try unused.find(a, file, ast)) |u| {
        const what: []const u8 = if (u.kind == .variable) "Variable" else "Name";
        try out.append(a, .{
            .sln = u.line,
            .sch = u.start,
            .eln = u.line,
            .ech = u.end,
            .message = try std.fmt.allocPrint(a, "{s} \"{s}\" is not used", .{ what, u.name }),
            .severity = C.Severity.hint,
            .code = .unused_name,
            .subject = u.name,
        });
    }
    return out.items;
}

/// For each unused name on 0-based lines `sline`..`eline` whose statement
/// declares nothing else: a quick fix removing that statement
pub fn addRemoveUnusedActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    const uri = try paths.pathToUri(a, file.path);
    const diags = try unusedNames(a, file, ast);
    for (try unused.find(a, file, ast), diags) |u, d| {
        if (u.line < sline or u.line > eline) continue;
        const r = u.removable orelse continue;
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = Server.rangeOf(file, r.first, 0, r.last + 1, 0), .newText = "" };
        const files = try a.alloc(lsp.Changes.File, 1);
        files[0] = .{ .uri = uri, .edits = edits };
        const dv = try a.alloc(lsp.Diagnostic, 1);
        dv[0] = try self.diagnosticOf(a, file, d);
        try out.append(a, .{
            .title = try std.fmt.allocPrint(a, "Remove unused {s}", .{u.name}),
            .kind = "quickfix",
            .edit = .{ .changes = .{ .files = files } },
            .diagnostics = dv,
        });
    }
}

/// Whether `file` has fypp directives (`#:for`, `#:set`, ...) or inline
/// expressions (`${...}$`)
fn usesFypp(file: *const FortranFile) bool {
    for (0..file.nLines()) |i| {
        const text = file.getLine(i, false) orelse continue;
        const t = std.mem.trimStart(u8, text, " \t");
        if (std.mem.startsWith(u8, t, "#:") or std.mem.startsWith(u8, t, "$:") or std.mem.startsWith(u8, t, "@:")) return true;
        if (std.mem.indexOf(u8, text, "${") != null) return true;
    }
    return false;
}

/// Whether every module that `scope`, the scopes around it and the
/// ancestors of a submodule among them use is in the workspace or
/// intrinsic, and not an external module; and the module of a submodule
/// and the interface of a separate module procedure among them are found
/// (they declare its names and arguments)
fn usesKnownModules(self: *Server, a: Allocator, ast: *Ast, scope: *Obj) !bool {
    var scopes: std.ArrayList(*Obj) = .empty;
    var cur: ?*Obj = scope;
    var depth: usize = 0;
    while (cur) |s| : (cur = s.parent) {
        depth += 1;
        if (depth > 64) break;
        try scopes.append(a, s);
        try scopes.appendSlice(a, try s.getAncestors(a));
    }
    for (scopes.items) |s| {
        if (s.data != .scope) continue;
        if (s.kind == .submodule and s.submodDataConst().ancestor_obj == null) return false;
        if (s.isModScope() and s.linkObj() == null) return false;
        for (s.scopeDataConst().use.items) |u| {
            if (u.is_import) continue;
            if (isExternalModule(self, u.mod_name)) return false;
            if (self.env(a).global(ast, u.mod_name) == null) return false;
        }
    }
    return true;
}

/// For each name on 0-based lines `sline`..`eline` that is not declared
/// under IMPLICIT NONE: a quick fix declaring it, with the type the default
/// rules would give it, after the last declaration of its program unit
pub fn addDeclareActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    const uri = try paths.pathToUri(a, file.path);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try undeclaredNames(self, a, file, ast)) |d| {
        if (d.sln < sline or d.sln > eline) continue;
        const name = d.subject orelse continue;
        const unit = autouse.unitOf(try ast.getScopes(a, d.sln + 1)) orelse continue;
        const key = try std.fmt.allocPrint(a, "{x}:{s}", .{ @intFromPtr(unit), try std.ascii.allocLowerString(a, name) });
        if ((try seen.getOrPut(a, key)).found_existing) continue;
        const at = try declarationPoint(a, file, unit);
        const letter = std.ascii.toLower(name[0]);
        const type_name: []const u8 = if (letter >= 'i' and letter <= 'n') "integer" else "real";
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = try std.fmt.allocPrint(a, "{s}{s} :: {s}\n", .{ at.indent, type_name, name }) };
        const files = try a.alloc(lsp.Changes.File, 1);
        files[0] = .{ .uri = uri, .edits = edits };
        const dv = try a.alloc(lsp.Diagnostic, 1);
        dv[0] = try self.diagnosticOf(a, file, d);
        try out.append(a, .{
            .title = try std.fmt.allocPrint(a, "Declare {s} as {s}", .{ name, type_name }),
            .kind = "quickfix",
            .edit = .{ .changes = .{ .files = files } },
            .diagnostics = dv,
        });
    }
}

/// Where a new declaration of `unit` goes: after the last declaration of
/// its own variables or its IMPLICIT statement, else where a USE statement
/// would go; with the indentation of the line before
fn declarationPoint(a: Allocator, file: *const FortranFile, unit: *const Obj) !autouse.Insertion {
    var last: ?usize = null;
    const sd = unit.scopeDataConst();
    for (unit.childList()) |c| {
        if (c.kind != .variable or c.sline <= unit.sline) continue;
        if (sd.contains_start) |cs| if (c.sline >= cs) continue;
        if (last == null or c.sline - 1 > last.?) last = c.sline - 1;
    }
    if (sd.implicit_line) |il| if (il > 0 and (last == null or il - 1 > last.?)) {
        last = il - 1;
    };
    const l = last orelse return autouse.insertionPoint(a, file, unit);
    const text = file.getLine(l, false) orelse "";
    var n: usize = 0;
    while (n < text.len and (text[n] == ' ' or text[n] == '\t')) n += 1;
    return .{ .line = selection.statementLines(file, l).last + 1, .indent = text[0..n] };
}

/// For each name on 0-based lines `sline`..`eline` that is not found in
/// scope but is public in a module: a quick fix adding the USE statement
/// that brings it in (hansec #62)
pub fn addUseActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    const diags = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
    const uri = try paths.pathToUri(a, file.path);
    for (diags) |d| {
        if (d.code != .object_not_found or d.sln < sline or d.sln > eline) continue;
        const name = d.subject orelse continue;
        const unit = autouse.unitOf(try ast.getScopes(a, d.sln + 1)) orelse continue;
        const at = try autouse.insertionPoint(a, file, unit);
        for (try autouse.exports(a, try completion.usableModules(self, a), .{ .exact = name }, 10)) |e| {
            if (autouse.isWithin(unit, e.module)) continue;
            const text = try autouse.statement(a, at.indent, e.module.name, e.obj.name);
            const edits = try a.alloc(lsp.TextEdit, 1);
            edits[0] = .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = text };
            const files = try a.alloc(lsp.Changes.File, 1);
            files[0] = .{ .uri = uri, .edits = edits };
            const dv = try a.alloc(lsp.Diagnostic, 1);
            dv[0] = try self.diagnosticOf(a, file, d);
            try out.append(a, .{
                .title = try std.fmt.allocPrint(a, "Add use {s}, only: {s}", .{ e.module.name, e.obj.name }),
                .kind = "quickfix",
                .edit = .{ .changes = .{ .files = files } },
                .diagnostics = dv,
            });
        }
    }
}

pub fn diagnosticsOf(self: *Server, a: Allocator, uri: []const u8) !?[]const lsp.Diagnostic {
    const file = (try self.fileFromUri(a, uri)) orelse return null;
    var diags: []const objects.BuiltDiag = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
    if (file.ast) |ast| diags = try std.mem.concat(a, objects.BuiltDiag, &.{ diags, try undeclaredNames(self, a, file, ast), try unusedNames(a, file, ast), try circularUses(self, a, file, ast), try argumentProblems(self, a, file, ast) });
    const hidden = try suppress.of(a, file);
    var out: std.ArrayList(lsp.Diagnostic) = .empty;
    for (diags) |d| {
        if (hidden.hides(d.code, d.sln)) continue;
        if (d.code == .module_not_found) if (d.subject) |m| if (isExternalModule(self, m)) continue;
        var dd = d;
        dd.severity = severityOf(self, d.code) orelse d.severity;
        if (dd.severity == 0) continue;
        try out.append(a, try self.diagnosticOf(a, file, dd));
    }
    return out.items;
}

/// The severity `diagnostic_severity` gives the diagnostics of `code`
/// (0: hidden), if it names it
pub fn severityOf(self: *const Server, code: C.DiagCode) ?i32 {
    for (self.s.diagnostic_severity.items) |l| if (std.mem.eql(u8, l.code, code.name())) {
        return Server.severity_names.get(l.level);
    };
    return null;
}

/// Modules zfls knows partly or not at all: those of NVIDIA's CUDA Fortran,
/// which come with its compiler, and MPI's, of which it has stubs
const vendor_modules = [_][]const u8{ "cudafor", "cublas", "cublas_v2", "cufft", "curand", "cusparse", "cusolverdn", "cutensorex", "nvtx", "cooperative_groups", "wmma", "mpi", "mpi_f08" };

/// Whether `external_modules` names module `name`, or it is a CUDA Fortran
/// module
pub fn isExternalModule(self: *const Server, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (name.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, name);
    for (vendor_modules) |m| if (std.mem.eql(u8, m, lower)) return true;
    for (self.s.external_modules.slice()) |pat| {
        var pbuf: [256]u8 = undefined;
        if (pat.len > pbuf.len) continue;
        if (glob.fnmatch(std.ascii.lowerString(&pbuf, pat), lower)) return true;
    }
    return false;
}

/// Warns about the codes and severities of `diagnostic_severity` that
/// zfls does not know
pub fn checkDiagnosticSeverity(self: *Server, a: Allocator) !void {
    for (self.s.diagnostic_severity.items) |l| {
        if (C.DiagCode.fromName(l.code) == null) {
            self.postMessage(a, try std.fmt.allocPrint(a, "diagnostic_severity: unknown diagnostic code \"{s}\"", .{l.code}), C.Severity.warn);
        } else if (Server.severity_names.get(l.level) == null) {
            self.postMessage(a, try std.fmt.allocPrint(a, "diagnostic_severity: \"{s}\" for \"{s}\" is not off, error, warning, information or hint", .{ l.level, l.code }), C.Severity.warn);
        }
    }
}

/// The diagnostics of a file as a JSON array (used by the debug CLI)
pub fn getDiagnostics(self: *Server, a: Allocator, uri: []const u8) !?Value {
    const diags = (try diagnosticsOf(self, a, uri)) orelse return null;
    return try json.from(a, diags);
}

/// The diagnostics of every workspace file (`workspace_diagnostics`), so
/// that editors list the problems of files that are not open
pub fn publishWorkspace(self: *Server, a: Allocator) void {
    if (self.s.disable_diagnostics) return;
    for (self.workspace.values()) |f| {
        if (f.ast == null) continue;
        const uri = paths.pathToUri(a, f.path) catch continue;
        sendDiagnostics(self, a, uri);
    }
}

pub fn sendDiagnostics(self: *Server, a: Allocator, uri: []const u8) void {
    const res = diagnosticsOf(self, a, uri) catch |e| {
        self.writeError(a, .{ .integer = -1 }, -32603, @errorName(e), .{ .traceback = @errorName(e) }) catch |e2| self.logSendFailure(e2);
        return;
    };
    if (res) |diags| {
        self.sendNotification(a, "textDocument/publishDiagnostics", json.from(a, lsp.PublishDiagnosticsParams{ .uri = uri, .diagnostics = diags }) catch return) catch |e| self.logSendFailure(e);
    }
}
