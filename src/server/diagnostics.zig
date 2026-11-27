//! Diagnostics: computing them, filtering by settings and suppression
//! comments, and publishing them. Code actions are code_actions.zig's.
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
const semantic = @import("../semantic.zig");
const suppress = @import("../suppress.zig");
const implicit = @import("../implicit.zig");
const unused = @import("../unused.zig");
const modgraph = @import("../modgraph.zig");
const argcheck = @import("../argcheck.zig");
const str = @import("../str.zig");

const Ast = objects.Ast;
const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const compile = @import("compile.zig");
const dialect = @import("dialect.zig");
const use_only = @import("use_only.zig");
const statement_problems = @import("statement_problems.zig");
const compiler_macros = @import("compiler_macros.zig");
const linters = @import("linters.zig");
const summary = @import("summary.zig");
const import_hidden = @import("import_hidden.zig");

/// Modules zfls knows partly or not at all: those of NVIDIA's CUDA Fortran,
/// which come with its compiler, and MPI's, of which it has stubs
const vendor_modules = [_][]const u8{ "cudafor", "cublas", "cublas_v2", "cufft", "curand", "cusparse", "cusolverdn", "cutensorex", "nvtx", "cooperative_groups", "wmma", "mpi", "mpi_f08" };

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
        if (try import_hidden.diagnostic(self.env(a), a, scope, u)) |d| {
            try out.append(a, d);
            continue;
        }
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

/// The calls of workspace procedures whose arguments do not fit them, and
/// assignments to INTENT(IN) arguments
pub fn argumentProblems(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    for (try argcheck.check(a, self.env(a), file, ast, self.workspace.values(), compiler_macros.hasReal10(self), dialect.of(self, file.declared_fixed))) |p| try out.append(a, .{
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
            .not_definable => .argument_not_definable,
            .too_short => .argument_too_short,
            .storage_short => .argument_storage_short,
            .constant_assigned => .constant_assigned,
            .parameter_without_value => .parameter_without_value,
            .duplicate_dummy => .duplicate_dummy,
            .bad_kind => .bad_kind,
            .subscript_count => .subscript_count,
            .unknown_component => .unknown_component,
            .allocate_object => .allocate_object,
            .allocate_duplicate => .allocate_duplicate,
            .allocate_shape => .allocate_shape,
            .assignment_type => .assignment_type,
            .condition_type => .condition_type,
            .intrinsic_arguments => .intrinsic_arguments,
            .unbalanced_parentheses => .unbalanced_parentheses,
            .dangling_operator => .dangling_operator,
            .abstract_type_declared => .abstract_type_declared,
            .extends_unknown_type => .extends_unknown_type,
            .pure_function_argument => .pure_function_argument,
            .unknown_io_specifier => .unknown_io_specifier,
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
    return unusedDiagnostics(a, try unused.find(a, file, ast));
}

/// The hints of the names `found`
pub fn unusedDiagnostics(a: Allocator, found: []const unused.Unused) ![]const objects.BuiltDiag {
    var out: std.ArrayList(objects.BuiltDiag) = .empty;
    for (found) |u| {
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

/// Whether `file` has fypp directives (`#:for`, `#:set`, ...) or inline
/// expressions (`${...}$`)
pub fn usesFypp(file: *const FortranFile) bool {
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

pub fn diagnosticsOf(self: *Server, a: Allocator, uri: []const u8) !?[]const lsp.Diagnostic {
    const file = (try self.fileFromUri(a, uri)) orelse return null;
    // those of its full AST
    if (summary.dormant(file)) try summary.wake(self, a, &.{file});
    var diags: []const objects.BuiltDiag = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
    if (file.ast) |ast| diags = try std.mem.concat(a, objects.BuiltDiag, &.{ diags, try includesNotFound(a, ast), try undeclaredNames(self, a, file, ast), try unusedNames(a, file, ast), try circularUses(self, a, file, ast), try argumentProblems(self, a, file, ast), try use_only.check(self, a, file, ast), try statement_problems.check(a, file, ast) });
    const hidden = try suppress.of(a, file);
    const included = isIncluded(self, file);
    var out: std.ArrayList(lsp.Diagnostic) = .empty;
    var cursor: str.Utf16Cursor = .{};
    const dia = dialect.of(self, file.declared_fixed);
    for (diags) |d| {
        if (hidden.hides(d.code, d.sln)) continue;
        // an INTENT outside the argument list: gfortran and ifx report it, Flang does not (#850)
        if (d.code == .intent_not_in_arguments and !dia.applies(.initMany(&.{ .gfortran, .ifx }))) continue;
        // a file included by another may hold a part of a scope
        if (included and d.code == .unclosed_scope) continue;
        if (d.code == .module_not_found) if (d.subject) |m| if (isExternalModule(self, m)) continue;
        var dd = d;
        dd.severity = severityOf(self, d.code) orelse d.severity;
        if (dd.severity == 0) continue;
        try out.append(a, try self.diagnosticOfAt(a, file, dd, &cursor));
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
    // those of the files' full ASTs
    summary.wakeAll(self, a) catch |e| self.log.err("parsing the workspace's files in full: {s}", .{@errorName(e)});
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
