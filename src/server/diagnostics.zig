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
const definition = @import("definition.zig");
const semantic = @import("../semantic.zig");
const suppress = @import("../suppress.zig");
const implicit = @import("../implicit.zig");
const selection = @import("../selection.zig");
const unused = @import("../unused.zig");
const procinterface = @import("../procinterface.zig");
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
const compile = @import("compile.zig");
const linters = @import("linters.zig");

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
/// the scopes around them) all name modules zfls knows, and that no
/// INCLUDE zfls does not read is in (not found, or a part of a statement),
/// since a name could come from those.
pub fn undeclaredNames(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    if (file.nLines() == 0) return out.items;
    var unread: std.ArrayList(usize) = .empty;
    for (ast.include_statements.items) |inc| if (inc.file == null) {
        // outside every scope: any name of the file could come from it
        if (ast.getInnerScope(inc.line_number) == null) return out.items;
        try unread.append(a, inc.line_number);
    };
    // fypp's loops, macros and variables make names zfls cannot see
    if (usesFypp(file)) return out.items;
    const names = try semantic.unknownNames(a, self.env(a), file, ast, self.intr.funs, 0, file.nLines() - 1, self.fixedLimit());
    if (names.len == 0) return out.items;
    // whether the modules each scope uses are all known
    var known: std.AutoHashMapUnmanaged(*Obj, bool) = .empty;
    const renamed = try reexportedRenames(self, a);
    for (names) |u| {
        const scope = u.scope orelse continue;
        if (hasUnreadInclude(scope, unread.items)) continue;
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
            .message = try a.print("Name \"{s}\" is not declared (IMPLICIT NONE)", .{u.name}),
            .severity = C.Severity.warn,
            .code = .undeclared_name,
            .subject = u.name,
        });
    }
    return out.items;
}

/// Whether one of the (1-based) `lines` of unread includes is in `scope`
/// or a scope around it
fn hasUnreadInclude(scope: *Obj, lines: []const usize) bool {
    var s: ?*Obj = scope;
    while (s) |o| : (s = o.parent) {
        for (lines) |l| if (l >= o.sline and l <= o.eline) return true;
    }
    return false;
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
        edits[0] = .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = try a.print("{s}implicit none\n", .{at.indent}) };
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
    try edits.append(a, .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = text.items });
    return edits.items;
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
    for (try workspaceUnits(self, a)) |u| {
        if (u.kind != .submodule or u.submodDataConst().ancestor_obj != module or u.eline == 0) continue;
        const path = u.file_ast.path orelse continue;
        const target = self.fileForPath(path) orelse continue;
        const line = u.eline - 1;
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = Server.rangeOf(target, line, 0, line, 0), .newText = try a.print("  module procedure {s}\n  end procedure {s}\n", .{ proto.name, proto.name }) };
        try out.append(a, try action(a, try paths.pathToUri(a, path), try a.print("Implement {s} in submodule {s}", .{ proto.name, u.name }), "quickfix", edits));
        return;
    }
    // a new submodule after the module
    const end_line = file.nLines();
    const edits = try a.alloc(lsp.TextEdit, 1);
    edits[0] = .{
        .range = Server.rangeOf(file, end_line, 0, end_line, 0),
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
    for (try argcheck.check(a, self.env(a), file, ast, self.workspace.values())) |p| try out.append(a, .{
        .sln = p.line,
        .sch = p.start,
        .eln = p.line,
        .ech = p.end,
        .message = p.message,
        .severity = C.Severity.err,
        .code = switch (p.kind) {
            .arguments => .argument_mismatch,
            .kinds => .argument_kind,
            .intent_in => .intent_in_assigned,
        },
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
                .message = try a.print("Circular USE: modules {s} use each other", .{names.items}),
                .severity = C.Severity.err,
                .code = .circular_use,
                .subject = m.name,
            });
        }
    }
    return out.items;
}

/// The `#include` directives whose file is found neither next to the file
/// nor in `include_dirs` (`include-not-found`, information)
pub fn includesNotFound(a: Allocator, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    for (ast.include_statements.items) |inc| {
        const cols = inc.missing orelse continue;
        if (inc.file != null) continue;
        try out.append(a, .{
            .sln = inc.line_number -| 1,
            .sch = cols[0],
            .eln = inc.line_number -| 1,
            .ech = cols[1],
            .message = try a.print("Include file \"{s}\" not found (include_dirs)", .{inc.path}),
            .severity = C.Severity.info,
            .code = .include_not_found,
            .subject = inc.path,
        });
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
            .message = try a.print("{s} \"{s}\" is not used", .{ what, u.name }),
            .severity = C.Severity.hint,
            .code = .unused_name,
            .subject = u.name,
        });
    }
    return out.items;
}

/// For each unused name on 0-based lines `sline`..`eline`: a quick fix
/// removing it from its declaration (the whole statement when it declares
/// nothing else); and as a source action, removing all of the file's.
/// Names whose hint is hidden are left alone.
pub fn addRemoveUnusedActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, only: ?[]const []const u8, out: *std.ArrayList(lsp.CodeAction)) !void {
    if ((severityOf(self, .unused_name) orelse C.Severity.hint) == 0) return;
    const uri = try paths.pathToUri(a, file.path);
    const hidden = try suppress.of(a, file);
    const found = try unused.find(a, file, ast);
    // the names of each declaration statement, for the source action
    var by_statement: std.array_hash_map.Auto(usize, std.ArrayList([]const u8)) = .empty;
    for (found, try unusedNames(a, file, ast)) |u, d| {
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
    for (cuts, edits) |c, *e| e.* = .{
        .range = .{
            .start = .{ .line = c.sl, .character = Server.toLspCol(file, c.sl, c.sc) },
            .end = .{ .line = c.el, .character = Server.toLspCol(file, c.el, c.ec) },
        },
        .newText = "",
    };
    return edits;
}

/// Whether `file` has fypp directives (`#:for`, `#:set`, ...) or inline
/// expressions (`${...}$`)
fn usesFypp(file: *const FortranFile) bool {
    for (0..file.nLines()) |i| {
        const text = file.getLine(i, false) orelse continue;
        const t = std.mem.trimStart(u8, text, " \t");
        if (std.mem.startsWith(u8, t, "#:") or std.mem.startsWith(u8, t, "$:") or std.mem.startsWith(u8, t, "@:")) return true;
        if (std.mem.find(u8, text, "${") != null) return true;
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
    var seen: std.AutoHashMapUnmanaged(*Obj, void) = .empty;
    for (scopes.items) |s| {
        if (s.data != .scope) continue;
        if (s.kind == .submodule and s.submodDataConst().ancestor_obj == null) return false;
        if (s.isModScope() and s.linkObj() == null) return false;
        for (s.scopeDataConst().use.items) |u| {
            if (u.is_import) continue;
            if (!try moduleKnown(self, a, ast, u.mod_name, &seen)) return false;
        }
    }
    return true;
}

/// Whether module `name` is known, and the modules it uses, which it may
/// make names of public (`use stats_impl, only: mean` / `public :: mean`),
/// are too
fn moduleKnown(self: *Server, a: Allocator, ast: *Ast, name: []const u8, seen: *std.AutoHashMapUnmanaged(*Obj, void)) !bool {
    if (isExternalModule(self, name)) return false;
    const m = self.env(a).global(ast, name) orelse return false;
    if ((try seen.getOrPut(a, m)).found_existing or m.data != .scope) return true;
    for (m.scopeDataConst().use.items) |u| {
        if (u.is_import) continue;
        if (!try moduleKnown(self, a, ast, u.mod_name, seen)) return false;
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
        const key = try a.print("{x}:{s}", .{ @intFromPtr(unit), try std.ascii.allocLowerString(a, name) });
        if ((try seen.getOrPut(a, key)).found_existing) continue;
        const at = try declarationPoint(a, file, unit);
        const type_name = defaultType(name);
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = try a.print("{s}{s} :: {s}\n", .{ at.indent, type_name, name }) };
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
        const range = Server.rangeOf(file, at.line, 0, at.line, 0);
        for (diags) |d| {
            if (d.code != .argument_not_declared or d.sln != proc.sline - 1) continue;
            const name = d.subject orelse continue;
            if (name.len == 0) continue;
            const decl = try a.print("{s}{s} :: {s}\n", .{ at.indent, defaultType(name), name });
            const dv = try a.alloc(lsp.Diagnostic, 1);
            dv[0] = try self.diagnosticOf(a, file, d);
            try out.append(a, try declareAction(a, uri, range, try a.print("Declare {s} as {s}", .{ name, defaultType(name) }), decl, dv));
            try names.append(a, name);
            try text.appendSlice(a, decl);
            try found.append(a, dv[0]);
        }
        if (names.items.len < 2) continue;
        const title = try a.print("Declare the arguments {s}", .{try std.mem.join(a, ", ", names.items)});
        try out.append(a, try declareAction(a, uri, range, title, text.items, found.items));
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
        for (try autouse.exports(a, try completion.usableModules(self, a, ast), .{ .exact = name }, 10)) |e| {
            if (autouse.isWithin(unit, e.module)) continue;
            const text = try autouse.statement(a, at.indent, e.module.name, e.obj.name);
            const edits = try a.alloc(lsp.TextEdit, 1);
            edits[0] = .{ .range = Server.rangeOf(file, at.line, 0, at.line, 0), .newText = text };
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

pub fn diagnosticsOf(self: *Server, a: Allocator, uri: []const u8) !?[]const lsp.Diagnostic {
    const file = (try self.fileFromUri(a, uri)) orelse return null;
    var diags: []const objects.BuiltDiag = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
    if (file.ast) |ast| diags = try std.mem.concat(a, objects.BuiltDiag, &.{ diags, try includesNotFound(a, ast), try undeclaredNames(self, a, file, ast), try unusedNames(a, file, ast), try circularUses(self, a, file, ast), try argumentProblems(self, a, file, ast) });
    const hidden = try suppress.of(a, file);
    const included = isIncluded(self, file);
    var out: std.ArrayList(lsp.Diagnostic) = .empty;
    for (diags) |d| {
        if (hidden.hides(d.code, d.sln)) continue;
        // a file included by another may hold a part of a scope
        if (included and d.code == .unclosed_scope) continue;
        if (d.code == .module_not_found) if (d.subject) |m| if (isExternalModule(self, m)) continue;
        var dd = d;
        dd.severity = severityOf(self, d.code) orelse d.severity;
        if (dd.severity == 0) continue;
        try out.append(a, try self.diagnosticOf(a, file, dd));
    }
    return out.items;
}

/// Whether an INCLUDE statement or `#include` of a workspace file names
/// `file`
fn isIncluded(self: *Server, file: *const FortranFile) bool {
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.include_statements.items) |inc| if (inc.file == file) return true;
    }
    return false;
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
            self.postMessage(a, try a.print("diagnostic_severity: unknown diagnostic code \"{s}\"", .{l.code}), C.Severity.warn);
        } else if (Server.severity_names.get(l.level) == null) {
            self.postMessage(a, try a.print("diagnostic_severity: \"{s}\" for \"{s}\" is not off, error, warning, information or hint", .{ l.level, l.code }), C.Severity.warn);
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
        if (!publishedInWorkspace(self, f)) continue;
        const uri = paths.pathToUri(a, f.path) catch continue;
        sendDiagnostics(self, a, uri);
    }
}

/// Whether a file has diagnostics of its own with `workspace_diagnostics`:
/// a parsed one, but an included file (a part of others') only when it is
/// open
pub fn publishedInWorkspace(self: *const Server, f: *const FortranFile) bool {
    if (f.ast == null) return false;
    return !f.included or self.open_docs.contains(f.path);
}

pub fn sendDiagnostics(self: *Server, a: Allocator, uri: []const u8) void {
    // the client asks for them (pull.zig)
    if (self.pull_diagnostics) return;
    const res = diagnosticsOf(self, a, uri) catch |e| {
        self.writeError(a, .{ .integer = -1 }, -32603, @errorName(e), .{ .traceback = @errorName(e) }) catch |e2| self.logSendFailure(e2);
        return;
    };
    // with the last diagnostics of the file from the compiler and the
    // linters, whose publications have these with them
    if (res) |diags| compile.publish(self, a, uri, diags) catch |e| self.logSendFailure(e);
}
