//! Code actions (`textDocument/codeAction`): quick fixes for the
//! diagnostics, and the refactoring and source actions.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const autouse = @import("../autouse.zig");
const definition = @import("definition.zig");
const semantic = @import("../semantic.zig");
const suppress = @import("../suppress.zig");
const implicit = @import("../implicit.zig");
const selection = @import("../selection.zig");
const unused = @import("../unused.zig");
const procinterface = @import("../procinterface.zig");
const extract = @import("../extract.zig");
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
const linters = @import("linters.zig");
const convert = @import("convert.zig");
const diagnostics = @import("diagnostics.zig");
const doc_stub = @import("doc_stub.zig");
const modernize_actions = @import("modernize_actions.zig");

pub fn serveCodeActions(self: *Server, a: Allocator, params: lsp.CodeActionParams) !Value {
    var out: std.ArrayList(lsp.CodeAction) = .empty;
    // fortitude's fixes; when they are why actions are offered (fortitude
    // on, enable_code_actions off), only them
    try linters.addActions(self, a, params.textDocument.uri, params.range, params.context.only, &out);
    if (self.s.fortitude and !self.s.enable_code_actions) return if (out.items.len > 0) json.from(a, out.items) else .null;
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const sline = params.range.start.line;
    const eline = params.range.end.line;
    try addUseActions(self, a, file, ast, sline, eline, &out);
    try addDeclareActions(self, a, file, ast, sline, eline, &out);
    try addDeclareArgActions(self, a, file, ast, sline, eline, &out);
    try addRemoveUnusedActions(self, a, file, ast, sline, eline, params.context.only, &out);
    try addRewriteActions(self, a, file, ast, sline, eline, &out);
    try addStubActions(self, a, file, ast, sline, eline, &out);
    try doc_stub.addDocStubActions(self, a, file, ast, sline, eline, &out);
    try modernize_actions.addActions(self, a, file, ast, sline, eline, params.context.only, &out);
    try addExtractAction(self, a, file, ast, params.range, params.context.only, &out);
    if (wants(params.context.only, "source")) try addKeywordCaseActions(self, a, file, ast, &out);
    // findent runs only when source actions are asked for
    if (wants(params.context.only, "source")) if (try convert.freeFormAction(self, a, file, false)) |act| try out.append(a, act);
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

/// Whether the client asks for actions of `kind` (all, when it names none)
fn wants(only: ?[]const []const u8, kind: []const u8) bool {
    const kinds = only orelse return false;
    for (kinds) |k| if (std.mem.startsWith(u8, k, kind) or std.mem.startsWith(u8, kind, k)) return true;
    return false;
}

pub fn action(a: Allocator, uri: []const u8, title: []const u8, kind: []const u8, edits: []const lsp.TextEdit) !lsp.CodeAction {
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
        const ins = Server.lineInsertion(file, at.line);
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = ins.range, .newText = try a.print("{s}{s}implicit none\n", .{ ins.prefix, at.indent }) };
        try out.append(a, try action(a, uri, try a.print("Add IMPLICIT NONE to {s}", .{sc.name}), "quickfix", edits));
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

/// Writes `stmt` (one line) after `indent`, continued on further lines
/// where it is long: at a comma, in the form of the file (`fixed`)
fn writeStatement(a: Allocator, out: *std.ArrayList(u8), indent: []const u8, stmt: []const u8, fixed: bool) !void {
    const limit: usize = if (fixed) 72 else 100;
    // where the code of a continuation line starts
    const cont_col = indent.len + 4;
    var rest = stmt;
    var lead = indent;
    while (true) {
        try out.appendSlice(a, lead);
        const room = limit -| lead.len -| @as(usize, if (fixed) 0 else 2);
        if (rest.len <= limit -| lead.len or room == 0) {
            try out.appendSlice(a, rest);
            try out.append(a, '\n');
            return;
        }
        const cut = if (std.mem.findLast(u8, rest[0..room], ", ")) |i| i + 1 else if (fixed) room else {
            try out.appendSlice(a, rest);
            try out.append(a, '\n');
            return;
        };
        try out.appendSlice(a, rest[0..cut]);
        try out.appendSlice(a, if (fixed) "\n" else " &\n");
        rest = std.mem.trimStart(u8, rest[cut..], " ");
        lead = if (fixed)
            try std.mem.concat(a, u8, &.{ "     &", try spaces(a, cont_col -| 6) })
        else
            try spaces(a, cont_col);
    }
}

fn spaces(a: Allocator, n: usize) ![]const u8 {
    const out = try a.alloc(u8, n);
    @memset(out, ' ');
    return out;
}

/// The interface block of external procedure `proc` for `unit`, at the
/// end of its declarations, and the cuts removing the declarations of its
/// name that `unit` has (`external f`, `real f`), which the block replaces
fn interfaceEdits(a: Allocator, file: *FortranFile, ast: *Ast, unit: *Obj, proc: *const Obj) !?[]const lsp.TextEdit {
    const stmts = (try procinterface.body(a, proc)) orelse return null;
    const at = try declarationPoint(a, file, unit);
    var text: std.ArrayList(u8) = .empty;
    try writeStatement(a, &text, at.indent, "interface", file.fixed);
    const inner = try std.mem.concat(a, u8, &.{ at.indent, "  " });
    const body = try std.mem.concat(a, u8, &.{ at.indent, "    " });
    for (stmts, 0..) |st, i| try writeStatement(a, &text, if (i == 0 or i + 1 == stmts.len) inner else body, st, file.fixed);
    try writeStatement(a, &text, at.indent, "end interface", file.fixed);
    var edits: std.ArrayList(lsp.TextEdit) = .empty;
    // the unit's own declarations of the name, outside the scopes in it
    const sd = unit.scopeDataConst();
    const end = @min((sd.contains_start orelse unit.eline) -| 1, file.nLines());
    var l: usize = unit.sline;
    while (l < end) : (l += 1) {
        if (selection.statementLines(file, l).first != l) continue;
        if (ast.getInnerScope(l + 1) != unit) continue;
        const raw = file.getLine(l, false) orelse continue;
        var words = helpers.words(raw);
        const first = words.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(first.str, "use")) continue;
        const cuts = (try unused.removal(a, file, l, &.{proc.name})) orelse continue;
        try edits.appendSlice(a, try cutEdits(a, file, cuts));
    }
    const ins = Server.lineInsertion(file, at.line);
    try edits.append(a, .{ .range = ins.range, .newText = try std.mem.concat(a, u8, &.{ ins.prefix, text.items }) });
    return edits.items;
}

/// On a selection of whole statements of a procedure or program: moving
/// them into a new internal subroutine, called in their place (#222). When
/// they cannot be moved, and the client asks for refactorings and shows
/// actions that cannot be taken, the action with why.
fn addExtractAction(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, range: lsp.Range, only: ?[]const []const u8, out: *std.ArrayList(lsp.CodeAction)) !void {
    if (only != null and !wants(only, "refactor.extract")) return;
    const first = range.start.line;
    // a selection of whole lines ends at the start of the next one
    const last = if (range.end.line > first and range.end.character == 0) range.end.line - 1 else range.end.line;
    if (range.start.line == range.end.line and range.start.character == range.end.character) return;
    const p = (try extract.plan(a, file, ast, first, last)) orelse return;
    const ok = switch (p) {
        .refused => |why| {
            if (only == null or !self.config.client.textDocument.codeAction.disabledSupport) return;
            var act = try action(a, try paths.pathToUri(a, file.path), "Extract into subroutine", "refactor.extract", &.{});
            act.disabled = .{ .reason = try a.print("Cannot extract: {s}", .{why}) };
            return out.append(a, act);
        },
        .extracted => |e| e,
    };
    const edits = try a.alloc(lsp.TextEdit, ok.edits.len);
    for (ok.edits, edits) |e, *te| te.* = .{
        .range = .{
            .start = .{ .line = e.sl, .character = Server.toLspCol(file, e.sl, e.sc) },
            .end = .{ .line = e.el, .character = Server.toLspCol(file, e.el, e.ec) },
        },
        .newText = e.text,
    };
    try out.append(a, try action(a, try paths.pathToUri(a, file.path), try a.print("Extract into subroutine {s}", .{ok.name}), "refactor.extract", edits));
}

/// Code actions that write declarations from others:
/// - on a line calling a procedure defined outside any module, an
///   interface block for it in the unit around the call, replacing the
///   unit's EXTERNAL or type declaration of it;
/// - on a separate module procedure that has no implementation, its
///   `module procedure` stub in a submodule of its module (a new one at the
///   end of the file when there is none)
pub fn addStubActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    const uri = try paths.pathToUri(a, file.path);
    var ln = sline;
    while (ln <= eline and ln < file.nLines()) : (ln += 1) {
        const raw = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        var code = try helpers.stripStrings(a, raw, true);
        if (std.mem.findScalar(u8, code, '!')) |i| code = code[0..i];
        var it = helpers.words(code);
        var offered: std.ArrayList(*Obj) = .empty;
        while (it.next()) |w| {
            var o = (try definition.getDefinition(self, a, file, ln, w.start, false)) orelse continue;
            // the caller's own declaration of an external procedure
            if (o.kind == .variable) o = (try definition.callerTarget(self, a, file, ln, w.start, o)) orelse continue;
            if ((o.kind != .subroutine and o.kind != .function) or o.file_ast.file == null) continue;
            if (std.mem.findScalar(*Obj, offered.items, o) != null) continue;
            try offered.append(a, o);
            if (o.parent == null) {
                // an external procedure, called from another unit
                const unit = autouse.unitOf(try ast.getScopes(a, ln + 1)) orelse continue;
                if (unit == o or o.sline == ln + 1) continue;
                const edits = (try interfaceEdits(a, file, ast, unit, o)) orelse continue;
                try out.append(a, try action(a, uri, try a.print("Add an interface block for {s}", .{o.name}), "quickfix", edits));
            } else if (o.parent.?.kind == .interface and o.isModScope() and o.linkObj() == null and o.sline == ln + 1) {
                try submoduleStub(self, a, file, o, out);
            }
        }
    }
}

/// The `module procedure` stub of separate module procedure `proto`
fn submoduleStub(self: *Server, a: Allocator, file: *FortranFile, proto: *Obj, out: *std.ArrayList(lsp.CodeAction)) !void {
    // the module of the interface
    var m: ?*Obj = proto.parent;
    while (m) |s| : (m = s.parent) if (s.kind == .module) break;
    const module = m orelse return;
    // a submodule of it in the workspace
    for (try diagnostics.workspaceUnits(self, a)) |u| {
        if (u.kind != .submodule or u.submodDataConst().ancestor_obj != module or u.eline == 0) continue;
        const path = u.file_ast.path orelse continue;
        const target = self.fileForPath(path) orelse continue;
        const line = u.eline - 1;
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = Server.rangeOf(target, line, 0, line, 0), .newText = try a.print("  module procedure {s}\n  end procedure {s}\n", .{ proto.name, proto.name }) };
        try out.append(a, try action(a, try paths.pathToUri(a, path), try a.print("Implement {s} in submodule {s}", .{ proto.name, u.name }), "quickfix", edits));
        return;
    }
    // a new submodule after the module, at the end of the last line (a
    // line after it is not in the document)
    const end_line = file.nLines() -| 1;
    const end_col = if (file.getLine(end_line, false)) |l| l.len else 0;
    const edits = try a.alloc(lsp.TextEdit, 1);
    edits[0] = .{
        .range = Server.rangeOf(file, end_line, end_col, end_line, end_col),
        .newText = try a.print("\nsubmodule ({s}) {s}_impl\ncontains\n  module procedure {s}\n  end procedure {s}\nend submodule {s}_impl\n", .{ module.name, module.name, proto.name, proto.name, module.name }),
    };
    try out.append(a, try action(a, try paths.pathToUri(a, file.path), try a.print("Implement {s} in a new submodule", .{proto.name}), "quickfix", edits));
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
        for (try keywordChanges(a, file, names, cs.case)) |c| {
            try edits.append(a, .{ .range = Server.rangeOf(file, c.line, c.start, c.line, c.end), .newText = c.text });
        }
        if (edits.items.len > 0) try out.append(a, try action(a, uri, cs.title, cs.kind, edits.items));
    }
}

/// A keyword written in another case: its line (0-based), bytes and text
pub const CaseChange = struct { line: usize, start: usize, end: usize, text: []const u8 };

/// The keywords of `file` (not the names, `names`: `semantic.namePositions`)
/// that `case` writes otherwise, in order; for the keyword case actions and
/// the formatter's `--case` (indent_format.zig)
pub fn keywordChanges(a: Allocator, file: *const FortranFile, names: anytype, case: rewrite.Case) ![]const CaseChange {
    var out: std.ArrayList(CaseChange) = .empty;
    for (0..file.nLines()) |ln| {
        const raw = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        const t = std.mem.trimStart(u8, raw, " \t");
        if (t.len > 0 and t[0] == '#') continue;
        var code = try helpers.stripStrings(a, raw, true);
        if (std.mem.findScalar(u8, code, '!')) |i| code = code[0..i];
        var it = helpers.words(code);
        while (it.next()) |w| {
            // `.and.`, `.true.`: their words are keywords too
            const dotted = w.start > 0 and code[w.start - 1] == '.' and w.end < code.len and code[w.end] == '.';
            if (!dotted and !semantic.isKeyword(w.str)) continue;
            if (dotted and !isDotWord(w.str)) continue;
            if (names.contains(.{ ln, str.byteToUtf16(raw, w.start) })) continue;
            const new = try rewrite.inCase(a, w.str, case);
            if (std.mem.eql(u8, new, w.str)) continue;
            try out.append(a, .{ .line = ln, .start = w.start, .end = w.end, .text = new });
        }
    }
    return out.items;
}

fn isDotWord(w: []const u8) bool {
    for ([_][]const u8{ "and", "or", "not", "eqv", "neqv", "true", "false", "eq", "ne", "lt", "le", "gt", "ge" }) |k| {
        if (std.ascii.eqlIgnoreCase(w, k)) return true;
    }
    return false;
}

/// For each unused name on 0-based lines `sline`..`eline`: a quick fix
/// removing it from its declaration (the whole statement when it declares
/// nothing else); and as a source action, removing all of the file's.
/// Names whose hint is hidden are left alone.
pub fn addRemoveUnusedActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, only: ?[]const []const u8, out: *std.ArrayList(lsp.CodeAction)) !void {
    if ((diagnostics.severityOf(self, .unused_name) orelse C.Severity.hint) == 0) return;
    const uri = try paths.pathToUri(a, file.path);
    const hidden = try suppress.of(a, file);
    const found = try unused.find(a, file, ast);
    // the names of each declaration statement, for the source action
    var by_statement: std.array_hash_map.Auto(usize, std.ArrayList([]const u8)) = .empty;
    for (found, try diagnostics.unusedDiagnostics(a, found)) |u, d| {
        if (hidden.hides(d.code, d.sln)) continue;
        const gop = try by_statement.getOrPut(a, u.decl_line);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, u.name);
        if (u.line < sline or u.line > eline) continue;
        const cuts = (try unused.removal(a, file, u.decl_line, &.{u.name})) orelse continue;
        const dv = try a.alloc(lsp.Diagnostic, 1);
        dv[0] = try self.diagnosticOf(a, file, d);
        var act = try action(a, uri, try a.print("Remove unused {s}", .{u.name}), "quickfix", try cutEdits(a, file, cuts));
        act.diagnostics = dv;
        try out.append(a, act);
    }
    if (!wants(only, "source")) return;
    var edits: std.ArrayList(lsp.TextEdit) = .empty;
    var it = by_statement.iterator();
    while (it.next()) |e| {
        const cuts = (try unused.removal(a, file, e.key_ptr.*, e.value_ptr.items)) orelse continue;
        try edits.appendSlice(a, try cutEdits(a, file, cuts));
    }
    if (edits.items.len > 0) try out.append(a, try action(a, uri, "Remove all unused declarations", "source.removeUnused", edits.items));
}

fn cutEdits(a: Allocator, file: *const FortranFile, cuts: []const unused.Cut) ![]const lsp.TextEdit {
    const edits = try a.alloc(lsp.TextEdit, cuts.len);
    for (cuts, edits) |c_in, *e| {
        var c = c_in;
        // whole lines up to a line after the last, which is not in the
        // document: to the end of the last, from the end of the line before
        if (c.el >= file.nLines()) {
            c.el = file.nLines() -| 1;
            c.ec = if (file.getLine(c.el, false)) |l| l.len else 0;
            if (c.sc == 0 and c.sl > 0) {
                c.sl -= 1;
                c.sc = if (file.getLine(c.sl, false)) |l| l.len else 0;
            }
        }
        e.* = .{
            .range = .{
                .start = .{ .line = c.sl, .character = Server.toLspCol(file, c.sl, c.sc) },
                .end = .{ .line = c.el, .character = Server.toLspCol(file, c.el, c.ec) },
            },
            .newText = "",
        };
    }
    return edits;
}

/// For each name on 0-based lines `sline`..`eline` that is not declared
/// under IMPLICIT NONE: a quick fix declaring it, with the type the default
/// rules would give it, after the last declaration of its program unit
pub fn addDeclareActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    const uri = try paths.pathToUri(a, file.path);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try diagnostics.undeclaredNames(self, a, file, ast)) |d| {
        if (d.code != .undeclared_name) continue;
        if (d.sln < sline or d.sln > eline) continue;
        const name = d.subject orelse continue;
        const unit = autouse.unitOf(try ast.getScopes(a, d.sln + 1)) orelse continue;
        const key = try a.print("{x}:{s}", .{ @intFromPtr(unit), try std.ascii.allocLowerString(a, name) });
        if ((try seen.getOrPut(a, key)).found_existing) continue;
        const at = try declarationPoint(a, file, unit);
        const ins = Server.lineInsertion(file, at.line);
        const type_name = defaultType(name);
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = ins.range, .newText = try a.print("{s}{s}{s} :: {s}\n", .{ ins.prefix, at.indent, type_name, name }) };
        const files = try a.alloc(lsp.Changes.File, 1);
        files[0] = .{ .uri = uri, .edits = edits };
        const dv = try a.alloc(lsp.Diagnostic, 1);
        dv[0] = try self.diagnosticOf(a, file, d);
        try out.append(a, .{
            .title = try a.print("Declare {s} as {s}", .{ name, type_name }),
            .kind = "quickfix",
            .edit = .{ .changes = .{ .files = files } },
            .diagnostics = dv,
        });
    }
}

/// The type the default IMPLICIT rules give `name`
fn defaultType(name: []const u8) []const u8 {
    const letter = std.ascii.toLower(name[0]);
    return if (letter >= 'i' and letter <= 'n') "integer" else "real";
}

/// For each dummy argument with no declaration (`argument-not-declared`)
/// on the procedure headers of 0-based lines `sline`..`eline`: a quick fix
/// declaring it with the type of the default rules, after the last
/// declaration of the procedure; and one declaring all of a procedure's
/// when it has several
pub fn addDeclareArgActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, out: *std.ArrayList(lsp.CodeAction)) !void {
    const uri = try paths.pathToUri(a, file.path);
    const diags = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
    for (ast.scope_list.items) |proc| {
        if (proc.kind != .subroutine and proc.kind != .function) continue;
        if (proc.sline == 0 or proc.sline - 1 < sline or proc.sline - 1 > eline) continue;
        var names: std.ArrayList([]const u8) = .empty;
        var text: std.ArrayList(u8) = .empty;
        var found: std.ArrayList(lsp.Diagnostic) = .empty;
        const at = try declarationPoint(a, file, proc);
        const ins = Server.lineInsertion(file, at.line);
        for (diags) |d| {
            if (d.code != .argument_not_declared or d.sln != proc.sline - 1) continue;
            const name = d.subject orelse continue;
            if (name.len == 0) continue;
            const decl = try a.print("{s}{s} :: {s}\n", .{ at.indent, defaultType(name), name });
            const dv = try a.alloc(lsp.Diagnostic, 1);
            dv[0] = try self.diagnosticOf(a, file, d);
            try out.append(a, try declareAction(a, uri, ins.range, try a.print("Declare {s} as {s}", .{ name, defaultType(name) }), try std.mem.concat(a, u8, &.{ ins.prefix, decl }), dv));
            try names.append(a, name);
            try text.appendSlice(a, decl);
            try found.append(a, dv[0]);
        }
        if (names.items.len < 2) continue;
        const title = try a.print("Declare the arguments {s}", .{try std.mem.join(a, ", ", names.items)});
        try out.append(a, try declareAction(a, uri, ins.range, title, try std.mem.concat(a, u8, &.{ ins.prefix, text.items }), found.items));
    }
}

/// A quick fix inserting `text` at `range` of the document `uri`
fn declareAction(a: Allocator, uri: []const u8, range: lsp.Range, title: []const u8, text: []const u8, diags: []const lsp.Diagnostic) !lsp.CodeAction {
    const edits = try a.alloc(lsp.TextEdit, 1);
    edits[0] = .{ .range = range, .newText = text };
    const files = try a.alloc(lsp.Changes.File, 1);
    files[0] = .{ .uri = uri, .edits = edits };
    return .{ .title = title, .kind = "quickfix", .edit = .{ .changes = .{ .files = files } }, .diagnostics = diags };
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
        const ins = Server.lineInsertion(file, at.line);
        for (try autouse.exports(a, try completion.usableModules(self, a, ast), .{ .exact = name }, 10)) |e| {
            if (autouse.isWithin(unit, e.module)) continue;
            const text = try autouse.statement(a, at.indent, e.module.name, e.obj.name);
            const edits = try a.alloc(lsp.TextEdit, 1);
            edits[0] = .{ .range = ins.range, .newText = try std.mem.concat(a, u8, &.{ ins.prefix, text }) };
            const files = try a.alloc(lsp.Changes.File, 1);
            files[0] = .{ .uri = uri, .edits = edits };
            const dv = try a.alloc(lsp.Diagnostic, 1);
            dv[0] = try self.diagnosticOf(a, file, d);
            try out.append(a, .{
                .title = try a.print("Add use {s}, only: {s}", .{ e.module.name, e.obj.name }),
                .kind = "quickfix",
                .edit = .{ .changes = .{ .files = files } },
                .diagnostics = dv,
            });
        }
    }
}

/// `codeAction/resolve` (#984): the edit of an action listed without it
/// (the conversion to free form, whose findent runs now); any other action
/// as it is
pub fn serveResolve(self: *Server, a: Allocator, params: Value) !Value {
    const data = json.get(params, "data") orelse return params;
    if (!std.mem.eql(u8, json.str(json.get(data, "resolve")) orelse "", convert.resolve_kind)) return params;
    const file = (try self.fileFromUri(a, json.str(json.get(data, "uri")) orelse return params)) orelse return params;
    const act = (try convert.freeFormAction(self, a, file, true)) orelse return params;
    return json.from(a, act);
}
