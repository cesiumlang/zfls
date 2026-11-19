//! The objects of one parsed file: its scopes, the global names it defines,
//! its USE statements, includes and the diagnostics of parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const patterns = @import("../patterns.zig");
const regex = @import("../regex.zig");
const C = @import("../constants.zig");
const parser = @import("../parser.zig");
const FortranFile = parser.FortranFile;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const objects = @import("../objects.zig");
const implicit = @import("../implicit.zig");
const Obj = objects.Obj;
const UseStmt = objects.UseStmt;
const Env = objects.Env;
const Diagnostic = objects.Diagnostic;
const BuiltDiag = objects.BuiltDiag;
const EndError = objects.EndError;

/// Whether a file has `#if`, `#ifdef` or `#ifndef` directives
fn hasConditionals(file: *const FortranFile) bool {
    for (0..file.nLines()) |ln| {
        const t = std.mem.trimStart(u8, file.getLine(ln, false) orelse continue, " \t");
        if (t.len < 3 or t[0] != '#') continue;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, t[1..], " \t"), "if")) return true;
    }
    return false;
}

/// An END statement that does not fit the scope open there
/// (`mismatched-end`), or a scope still open at the end of the file
/// (`unclosed-scope`)
pub const ScopeError = struct {
    code: C.DiagCode,
    /// 1-based line of the error
    line: usize,
    message: []const u8,
    /// the scope it is about (opened at its `sline`)
    scope: *Obj,
};

pub const IncludeInfo = struct {
    line_number: usize,
    path: []const u8,
    file: ?*FortranFile = null,
    scope_objs: std.ArrayList(*Obj) = .empty,
    /// Cached `Include` object returned by `find_in_scope`
    inc_obj: ?*Obj = null,
    /// The scope the file's USE statements and IMPLICIT state are linked
    /// into (see `Ast.linkIncludeScope`)
    parent: ?*Obj = null,
    /// The copies of the file's USE statements in `parent`'s list
    uses: std.ArrayList(*UseStmt) = .empty,
    /// `parent`'s IMPLICIT state before the file's IMPLICIT statement set it
    implicit_before: ?ImplicitState = null,

    pub const ImplicitState = struct { vars: ?bool, line: ?usize, rules: []const implicit.Rule };

    /// Take the file's USE statements and IMPLICIT state out of the
    /// including scope again
    pub fn unlink(inc: *IncludeInfo) void {
        const ps = inc.parent orelse return;
        inc.parent = null;
        const use = &ps.scopeData().use;
        for (inc.uses.items) |u| {
            for (use.items, 0..) |x, i| if (x == u) {
                _ = use.orderedRemove(i);
                break;
            };
        }
        inc.uses.clearRetainingCapacity();
        if (inc.implicit_before) |before| {
            ps.implicit_vars = before.vars;
            ps.scopeData().implicit_line = before.line;
            ps.scopeData().implicit_rules = before.rules;
            inc.implicit_before = null;
        }
    }
};

/// The IMPLICIT statement of an included file (`Ast.inc_implicit`): NONE
/// (`vars` false) or its rules
pub const IncludeImplicit = struct { vars: bool, rules: []const implicit.Rule };

/// The innermost scope of each line of a file (`Ast.innerScopes`)
pub const InnerScopes = struct {
    lines: []const ?*Obj,
    none_scope: ?*Obj,

    /// What `Ast.getInnerScope(line_number)` gives
    pub fn at(self: InnerScopes, line_number: usize) ?*Obj {
        if (line_number >= 1 and line_number <= self.lines.len) if (self.lines[line_number - 1]) |s| return s;
        return self.none_scope;
    }
};

pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    file: ?*FortranFile = null,
    path: ?[]const u8 = null,
    global_dict: std.array_hash_map.String(*Obj) = .empty,
    scope_list: std.ArrayList(*Obj) = .empty,
    variable_list: std.ArrayList(*Obj) = .empty,
    public_list: std.ArrayList([]const u8) = .empty,
    private_list: std.ArrayList([]const u8) = .empty,
    scope_stack: std.ArrayList(*Obj) = .empty,
    end_stack: std.ArrayList(*const regex.Regex) = .empty,
    include_statements: std.ArrayList(*IncludeInfo) = .empty,
    end_errors: std.ArrayList(EndError) = .empty,
    scope_errors: std.ArrayList(ScopeError) = .empty,
    parse_errors: std.ArrayList(BuiltDiag) = .empty,
    inherit_objs: std.ArrayList(*Obj) = .empty,
    linkable_objs: std.ArrayList(*Obj) = .empty,
    external_objs: std.ArrayList(*Obj) = .empty,
    none_scope: ?*Obj = null,
    /// Indices of `parse_errors` that an END of the unnamed scope withdraws
    /// (`addMainError`)
    main_errors: std.ArrayList(usize) = .empty,
    /// The indices of `parse_errors` (in `main_errors`) that are IMPLICIT
    /// statements' (`addMainImplicitError`)
    implicit_errors: std.ArrayList(usize) = .empty,
    inc_scope: ?*Obj = null,
    /// The IMPLICIT statement of the unnamed scope that no END closes (the
    /// text of an include): `closeFile` takes it out of the scope, and
    /// `linkIncludeScope` applies it in the scope that includes the file
    inc_implicit: ?IncludeImplicit = null,
    /// The scope of the including file that this file is included into, so
    /// that names are looked up there after the file's own scopes (cleared
    /// when the workspace is relinked)
    included_in: ?*Obj = null,
    current_scope: ?*Obj = null,
    end_scope_regex: ?*const regex.Regex = null,
    enc_scope_name: ?[]const u8 = null,
    last_obj: ?*Obj = null,
    pending_doc: ?[]const u8 = null,

    pub fn create(gpa: Allocator, file: ?*FortranFile) !*Ast {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const self = try arena.allocator().create(Ast);
        self.* = .{ .arena = arena, .file = file };
        if (file) |f| self.path = try self.allocator().dupe(u8, f.path);
        return self;
    }

    /// Free the AST and every object it owns
    pub fn destroy(self: *Ast) void {
        var arena = self.arena;
        arena.deinit();
    }

    pub fn allocator(self: *Ast) Allocator {
        return self.arena.allocator();
    }

    /// Makes the unnamed scope of the statements outside every program unit
    /// (`none_scope`) the current scope, created at line `line_number` if
    /// there is none. It is the main program when an END closes it
    /// (`endMain`), else the text of an include.
    pub fn openMain(self: *Ast, line_number: usize) Allocator.Error!void {
        std.debug.assert(self.current_scope == null);
        if (self.none_scope) |ns| {
            self.current_scope = ns;
            self.end_scope_regex = &R().END_PROGRAM_NONE;
            self.enc_scope_name = ns.fqsn;
            return;
        }
        const ns = try Obj.newScope(self, .program, line_number, "main", &.{});
        self.none_scope = ns;
        try self.addScope(ns, &R().END_PROGRAM_NONE, false, false);
    }

    /// Whether the current scope is the unnamed one outside every program
    /// unit
    pub fn inMain(self: *const Ast) bool {
        return self.current_scope != null and self.current_scope == self.none_scope and self.scope_stack.items.len == 0;
    }

    /// Leaves the unnamed scope for a program unit that starts after its
    /// statements: one cannot be inside it (an include's text before it)
    pub fn leaveMain(self: *Ast) void {
        std.debug.assert(self.inMain());
        self.current_scope = null;
        self.end_scope_regex = null;
        self.enc_scope_name = null;
    }

    /// An error of a statement in the unnamed scope that is no error in a
    /// main program: withdrawn when an END makes the scope one
    pub fn addMainError(self: *Ast, code: C.DiagCode, msg: []const u8, ln: usize, sch: usize, ech: ?usize) !void {
        try self.main_errors.append(self.allocator(), self.parse_errors.items.len);
        try self.addError(code, msg, C.Severity.err, ln, sch, ech);
    }

    /// The error of an IMPLICIT statement in the unnamed scope: also no
    /// error while the file is included into a scope, where the statement
    /// applies (`linkIncludeScope`)
    pub fn addMainImplicitError(self: *Ast, msg: []const u8, ln: usize, sch: usize, ech: ?usize) !void {
        try self.implicit_errors.append(self.allocator(), self.parse_errors.items.len);
        try self.addMainError(.statement_without_scope, msg, ln, sch, ech);
    }

    /// An END at line `line_number` closes the unnamed scope: it is a main
    /// program without a PROGRAM statement, which stays in the scope list,
    /// and statements after it open a new unnamed scope
    pub fn endMain(self: *Ast, line_number: usize) void {
        std.debug.assert(self.inMain());
        self.none_scope.?.end(line_number);
        self.leaveMain();
        self.none_scope = null;
        var k = self.main_errors.items.len;
        while (k > 0) {
            k -= 1;
            _ = self.parse_errors.orderedRemove(self.main_errors.items[k]);
        }
        self.main_errors.clearRetainingCapacity();
        self.implicit_errors.clearRetainingCapacity();
    }

    fn getEncScopeName(self: *const Ast) ?[]const u8 {
        return if (self.current_scope) |cs| cs.fqsn else null;
    }

    pub fn addScope(self: *Ast, new_scope: *Obj, end_scope_regex: *const regex.Regex, exportable: bool, req_container: bool) !void {
        const a = self.allocator();
        try self.scope_list.append(a, new_scope);
        if (new_scope.requireInherit()) try self.inherit_objs.append(a, new_scope);
        if (new_scope.requireLink()) try self.linkable_objs.append(a, new_scope);
        if (self.current_scope == null) {
            if (req_container) {
                try self.openMain(new_scope.sline);
                new_scope.fqsn = try std.mem.concat(a, u8, &.{ self.none_scope.?.fqsn, "::", try std.ascii.allocLowerString(a, new_scope.name) });
                try self.current_scope.?.addChild(new_scope);
                try self.scope_stack.append(a, self.current_scope.?);
            } else if (exportable) {
                try self.global_dict.put(a, new_scope.fqsn, new_scope);
            }
        } else {
            try self.current_scope.?.addChild(new_scope);
            try self.scope_stack.append(a, self.current_scope.?);
        }
        if (self.end_scope_regex) |r| try self.end_stack.append(a, r);
        self.current_scope = new_scope;
        self.end_scope_regex = end_scope_regex;
        self.enc_scope_name = self.getEncScopeName();
        self.last_obj = new_scope;
        if (self.pending_doc) |d| {
            new_scope.addDoc(d);
            self.pending_doc = null;
        }
    }

    pub fn endScope(self: *Ast, line_number: usize, check: bool) !void {
        if ((self.current_scope == null or self.current_scope == self.none_scope) and check) {
            try self.end_errors.append(self.allocator(), .{ .end_line = null, .scope_line = line_number });
            return;
        }
        self.current_scope.?.end(line_number);
        self.current_scope = self.scope_stack.pop();
        self.end_scope_regex = self.end_stack.pop();
        self.enc_scope_name = self.getEncScopeName();
    }

    pub fn addVariable(self: *Ast, new_var: *Obj) !void {
        const a = self.allocator();
        if (self.current_scope == null) {
            try self.openMain(new_var.sline);
            new_var.fqsn = try std.mem.concat(a, u8, &.{ self.none_scope.?.fqsn, "::", try std.ascii.allocLowerString(a, new_var.name) });
        }
        try self.current_scope.?.addChild(new_var);
        try self.variable_list.append(a, new_var);
        if (new_var.varData().is_external) try self.external_objs.append(a, new_var);
        if (new_var.requireLink()) try self.linkable_objs.append(a, new_var);
        self.last_obj = new_var;
        if (self.pending_doc) |d| {
            new_var.addDoc(d);
            self.pending_doc = null;
        }
    }

    pub fn addIntMember(self: *Ast, key: []const u8) !void {
        const cs = self.current_scope.?;
        try cs.scopeData().members.append(self.allocator(), try self.allocator().dupe(u8, key));
    }

    pub fn addPrivate(self: *Ast, name: []const u8) !void {
        try self.private_list.append(self.allocator(), try self.allocator().print("{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addPublic(self: *Ast, name: []const u8) !void {
        try self.public_list.append(self.allocator(), try self.allocator().print("{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addUse(self: *Ast, use_mod: *UseStmt) !void {
        if (self.current_scope == null) try self.openMain(use_mod.line_number);
        try self.current_scope.?.scopeData().use.append(self.allocator(), use_mod);
    }

    pub fn addInclude(self: *Ast, path: []const u8, line_number: usize) !void {
        const a = self.allocator();
        const inc = try a.create(IncludeInfo);
        inc.* = .{ .line_number = line_number, .path = try a.dupe(u8, path) };
        try self.include_statements.append(a, inc);
    }

    pub fn addDoc(self: *Ast, doc_string: []const u8, forward: bool) !void {
        if (doc_string.len == 0) return;
        const d = try self.allocator().dupe(u8, doc_string);
        if (forward) {
            self.pending_doc = d;
        } else if (self.last_obj) |lo| {
            lo.addDoc(d);
        }
    }

    pub fn addError(self: *Ast, code: C.DiagCode, msg: []const u8, sev: i32, ln: usize, sch: usize, ech: ?usize) !void {
        try self.parse_errors.append(self.allocator(), .{
            .code = code,
            .sln = ln -| 1,
            .sch = sch,
            .eln = ln -| 1,
            .ech = ech,
            .message = try self.allocator().dupe(u8, msg),
            .severity = sev,
        });
    }

    /// All scopes containing the line (all scopes when null)
    pub fn getScopes(self: *Ast, a: Allocator, line_number: ?usize) ![]*Obj {
        const ln = line_number orelse return self.scope_list.items;
        var out: std.ArrayList(*Obj) = .empty;
        for (self.scope_list.items) |scope| {
            if (!(scope.sline <= ln and ln <= scope.eline)) continue;
            if (scope.parent) |p| if (p.kind == .interface) {
                for (scope.scopeData().use.items) |u| {
                    if (!u.is_import) continue;
                    if (u.import_type == .none) {
                        const single = try a.alloc(*Obj, 1);
                        single[0] = scope;
                        return single;
                    }
                }
            };
            try out.append(a, scope);
            try out.appendSlice(a, try scope.getAncestors(a));
        }
        if (out.items.len > 0 or self.none_scope == null) return out.items;
        const single = try a.alloc(*Obj, 1);
        single[0] = self.none_scope.?;
        return single;
    }

    pub fn getInnerScope(self: *Ast, line_number: usize) ?*Obj {
        var scope_sline: ?usize = null;
        var curr: ?*Obj = null;
        // scopes are listed as they open, so of those that open on the same
        // line (`do i = 1, n; associate (...)`) the last is the innermost
        // (hansec #229)
        for (self.scope_list.items) |scope| {
            if ((scope_sline == null or scope.sline >= scope_sline.?) and scope.sline <= line_number and line_number <= scope.eline) {
                curr = scope;
                scope_sline = scope.sline;
            }
        }
        if (curr == null) return self.none_scope;
        return curr;
    }

    /// The scope `getInnerScope` gives each of the first `n_lines` lines, for
    /// a caller that asks for many lines: `getInnerScope` looks at every
    /// scope of the file, which for every line of a long file of many
    /// procedures is quadratic in its length. This finds them in one pass
    /// over the scopes, by the same rule: of the scopes around the line, the
    /// last listed of those that open last.
    pub fn innerScopes(self: *Ast, a: Allocator, n_lines: usize) Allocator.Error!InnerScopes {
        const scopes = try a.alloc(?*Obj, n_lines);
        @memset(scopes, null);
        for (self.scope_list.items) |s| {
            // scopes count lines from 1
            var l = @max(s.sline, 1);
            while (l <= s.eline and l <= n_lines) : (l += 1) {
                if (scopes[l - 1]) |prev| if (s.sline < prev.sline) continue;
                scopes[l - 1] = s;
            }
        }
        return .{ .lines = scopes, .none_scope = self.none_scope };
    }

    fn findChildByName(parent: *Obj, name: []const u8) ?*Obj {
        for (parent.childList()) |child| {
            if (std.mem.eql(u8, child.name, name)) return child;
            // the enumerators of an ENUM are names of the scope around it
            if (std.mem.startsWith(u8, child.name, "#GEN_INT") or child.kind == .enum_) {
                for (child.childList()) |ic| if (std.mem.eql(u8, ic.name, name)) return ic;
            }
        }
        return null;
    }

    pub fn getObject(self: *Ast, fqsn: []const u8) ?*Obj {
        var it = std.mem.splitSequence(u8, fqsn, "::");
        const first = it.next() orelse return null;
        var current: ?*Obj = self.global_dict.get(first);
        if (current == null) {
            for (self.scope_list.items) |scope| {
                if (std.mem.eql(u8, scope.fqsn, first)) {
                    current = scope;
                    break;
                }
            }
            if (current == null) return null;
        }
        while (it.next()) |part| {
            current = findChildByName(current.?, part) orelse return null;
        }
        return current;
    }

    /// What an error message calls scope `s`: `IF construct`,
    /// `SUBROUTINE "name"`
    pub fn scopeLabel(self: *Ast, s: *Obj) ![]const u8 {
        const a = self.allocator();
        const kw: []const u8 = switch (s.kind) {
            .function => "FUNCTION",
            .scope => "PROCEDURE",
            else => try s.getDesc(a),
        };
        if (s.kind.isBlock()) return a.print("{s} construct", .{kw});
        if (s.name.len == 0) return kw;
        if (s.name[0] == '#') return a.print("{s} block", .{kw});
        return a.print("{s} \"{s}\"", .{ kw, s.name });
    }

    /// Whether an error names scope `s` already
    pub fn scopeReported(self: *const Ast, s: *const Obj) bool {
        for (self.scope_errors.items) |e| if (e.scope == s) return true;
        return false;
    }

    /// A SELECT TYPE or SELECT RANK construct for one of its blocks (the
    /// parser opens a scope for each), else `s`
    pub fn constructOf(s: *Obj) *Obj {
        if (s.kind == .select and s.isTypeRegion()) if (s.parent) |p| return p;
        return s;
    }

    /// Records that scope `s` is not closed, unless an error names it
    /// already
    pub fn reportUnclosed(self: *Ast, s_in: *Obj) !void {
        const s = constructOf(s_in);
        if (s == self.none_scope or self.scopeReported(s)) return;
        const message = try self.allocator().print("{s} is not closed", .{try self.scopeLabel(s)});
        try self.scope_errors.append(self.allocator(), .{ .code = .unclosed_scope, .line = s.sline, .message = message, .scope = s });
    }

    pub fn closeFile(self: *Ast, line_number: usize) !void {
        // the scopes still open, outermost first
        for (self.scope_stack.items) |s| try self.reportUnclosed(s);
        if (self.current_scope) |cs| try self.reportUnclosed(cs);
        while (self.current_scope != null) try self.endScope(line_number, false);
        if (self.none_scope) |ns| {
            ns.end(line_number);
            // no END closes it: the text of an include, whose IMPLICIT and
            // CONTAINS belong to the scope that includes it (its errors
            // stay, but for the IMPLICIT's while the file is included into
            // a scope: `checkFile`); `linkIncludeScope` applies the
            // IMPLICIT there
            const sd = ns.scopeData();
            if (ns.implicit_vars) |flag| self.inc_implicit = .{ .vars = flag, .rules = sd.implicit_rules };
            ns.implicit_vars = null;
            sd.implicit_line = null;
            sd.implicit_rules = &.{};
            sd.contains_start = null;
            for (self.scope_list.items, 0..) |s, i| if (s == ns) {
                _ = self.scope_list.orderedRemove(i);
                break;
            };
        }
        for (self.private_list.items) |name| {
            if (self.getObject(name)) |o| o.vis = .private;
        }
        for (self.public_list.items) |name| {
            if (self.getObject(name)) |o| o.vis = .public;
        }
    }

    pub fn resolveLinks(self: *Ast, env: Env, link_version: i64) !void {
        for (self.inherit_objs.items) |o| try o.resolveInherit(env, link_version);
        for (self.linkable_objs.items) |o| try o.resolveLink(env);
    }

    /// The workspace path of the file that an INCLUDE statement names: searched
    /// in the directory of the including file, then in `include_dirs`
    /// (absolute), as `#include` is (upstream #301)
    fn findInclude(workspace: anytype, file_dir: []const u8, include_dirs: []const []const u8, name: []const u8, tmp: Allocator) !?[]const u8 {
        // `#include` directives are resolved to absolute paths by the preprocessor
        if (std.Io.Dir.path.isAbsolute(name)) return try parser.normPath(tmp, name);
        const local = try parser.normPath(tmp, try std.Io.Dir.path.join(tmp, &.{ file_dir, name }));
        if (workspace.get(local) != null) return local;
        for (include_dirs) |dir| {
            const candidate = try parser.normPath(tmp, try std.Io.Dir.path.join(tmp, &.{ dir, name }));
            if (workspace.get(candidate) != null) return candidate;
        }
        return null;
    }

    /// Link the objects of included files into the including scopes
    pub fn resolveIncludes(self: *Ast, workspace: anytype, include_dirs: []const []const u8, only_path: ?[]const u8, tmp: Allocator) !void {
        const path = self.path orelse return;
        const file_dir = std.Io.Dir.path.dirname(path) orelse "";
        for (self.include_statements.items) |inc| {
            // a part of a statement's text: no declarations to link
            if (self.file) |f| if (f.continuesInto(inc.line_number -| 1)) continue;
            const file_path = (try findInclude(workspace, file_dir, include_dirs, inc.path, tmp)) orelse {
                if (only_path == null) inc.unlink();
                continue;
            };
            if (only_path) |p| if (!std.mem.eql(u8, p, file_path)) continue;
            inc.unlink();
            const parent_scope = self.getInnerScope(inc.line_number);
            const include_file = workspace.get(file_path) orelse continue;
            const include_ast = include_file.ast orelse continue;
            inc.file = include_file;
            inc.inc_obj = null;
            include_ast.included_in = parent_scope;
            // what the file declares: the children of its unnamed scope, or,
            // for a file of whole procedures (which has none), those
            // procedures, as the procedures of the including scope
            const units: []const *Obj = if (include_ast.inc_scope orelse include_ast.none_scope) |ns| blk: {
                include_ast.inc_scope = ns;
                break :blk ns.childList();
            } else try include_ast.topProcedures(tmp);
            // Remove old objects
            if (parent_scope) |ps| {
                for (inc.scope_objs.items) |obj| {
                    for (ps.childList(), 0..) |c, i| if (c == obj) {
                        ps.removeChild(i);
                        break;
                    };
                }
            }
            inc.scope_objs.clearRetainingCapacity();
            for (units) |child| {
                try inc.scope_objs.append(self.allocator(), child);
                if (parent_scope) |ps| {
                    try ps.addChild(child);
                    try child.updateFqsn(ps.fqsn);
                }
            }
            if (include_ast.inc_scope) |ns| if (parent_scope) |ps| try self.linkIncludeScope(inc, ps, ns, include_ast.inc_implicit);
            if (include_ast.inc_scope != null) include_ast.none_scope = parent_scope;
        }
    }

    /// The USE statements of an included file's unnamed scope `ns` are USE
    /// statements of the including scope `ps` too, at the include line, and
    /// its IMPLICIT statement `imp` (`inc_implicit`, which is no longer in
    /// `ns`) sets `ps`'s rule; copied into this file's memory, so that they
    /// outlive the included file's parse
    fn linkIncludeScope(self: *Ast, inc: *IncludeInfo, ps: *Obj, ns: *Obj, imp: ?IncludeImplicit) !void {
        if (ps.data != .scope or ns.data != .scope or ps == ns) return;
        const a = self.allocator();
        inc.parent = ps;
        const sd = ns.scopeDataConst();
        for (sd.use.items) |u| {
            if (u.is_import) continue;
            const copy = try a.create(UseStmt);
            copy.* = .{ .mod_name = try a.dupe(u8, u.mod_name), .line_number = inc.line_number, .included = true };
            for (u.only_list.items.items) |name| try copy.only_list.add(a, try a.dupe(u8, name));
            for (u.rename_map.keys.items, u.rename_map.values.items) |k, v| try copy.rename_map.put(a, try a.dupe(u8, k), try a.dupe(u8, v));
            try ps.scopeData().use.append(a, copy);
            try inc.uses.append(a, copy);
        }
        const im = imp orelse return;
        const psd = ps.scopeData();
        inc.implicit_before = .{ .vars = ps.implicit_vars, .line = psd.implicit_line, .rules = psd.implicit_rules };
        ps.setImplicit(im.vars, inc.line_number);
        if (im.rules.len > 0) {
            const rules = try a.alloc(implicit.Rule, im.rules.len);
            for (im.rules, rules) |r, *out| out.* = .{ .first = r.first, .last = r.last, .type = try a.dupe(u8, r.type) };
            psd.implicit_rules = try std.mem.concat(a, implicit.Rule, &.{ psd.implicit_rules, rules });
        }
    }

    /// The procedures of the file outside any other scope (those another
    /// file's include has linked into a scope of its own included)
    fn topProcedures(self: *Ast, tmp: Allocator) ![]const *Obj {
        var out: std.ArrayList(*Obj) = .empty;
        for (self.scope_list.items) |s| {
            if (!s.kind.isSubroutine()) continue;
            if (s.parent) |p| if (p.file_ast == self) continue;
            try out.append(tmp, s);
        }
        return out.items;
    }

    pub fn checkFile(self: *Ast, env: Env) !struct { errors: []Diagnostic, parse_errors: []BuiltDiag } {
        const a = env.tmp;
        var errors: std.ArrayList(Diagnostic) = .empty;
        var tmp_list: std.ArrayList(*Obj) = .empty;
        try tmp_list.appendSlice(a, self.scope_list.items);
        if (self.none_scope) |ns| try tmp_list.append(a, ns);
        for (self.end_errors.items) |e| {
            const message = if (e.end_line) |el|
                try a.print("Unexpected end of scope at line {d}", .{el})
            else
                "Unexpected end statement: No open scopes";
            try errors.append(a, Diagnostic.init(.unexpected_end, e.scope_line -| 1, message, 1, null));
        }
        // the parser reads every branch of the preprocessor conditionals of
        // a file that is not preprocessed: each may open the same scope
        const unpreprocessed = if (self.file) |f| !f.preproc and hasConditionals(f) else false;
        if (!unpreprocessed) for (self.scope_errors.items) |e| {
            // an INCLUDE after its first line may close it
            if (e.code == .unclosed_scope) if (for (self.include_statements.items) |inc| {
                if (inc.line_number >= e.scope.sline) break true;
            } else false) continue;
            var d = Diagnostic.init(e.code, e.line -| 1, e.message, 1, null);
            if (e.code == .mismatched_end) d.addRelated(self.path, e.scope.sline -| 1, "Opened here");
            try errors.append(a, d);
        };
        for (tmp_list.items) |scope| {
            if (!scope.checkValidParent()) {
                try errors.append(a, Diagnostic.init(
                    .invalid_parent,
                    scope.sline -| 1,
                    try a.print("Invalid parent for \"{s}\" declaration", .{try scope.getDesc(a)}),
                    1,
                    null,
                ));
            }
            try errors.appendSlice(a, try scope.checkUse(env));
            try errors.appendSlice(a, try scope.checkDefinitions(env));
            try errors.appendSlice(a, try scope.getDiagnostics(a));
        }
        // an included file's IMPLICIT applies in the scope it is included
        // into (`linkIncludeScope`)
        if (self.included_in == null or self.implicit_errors.items.len == 0)
            return .{ .errors = errors.items, .parse_errors = self.parse_errors.items };
        var parse_errors: std.ArrayList(BuiltDiag) = .empty;
        for (self.parse_errors.items, 0..) |e, i| {
            if (std.mem.findScalar(usize, self.implicit_errors.items, i) == null) try parse_errors.append(a, e);
        }
        return .{ .errors = errors.items, .parse_errors = parse_errors.items };
    }
};

test "innerScopes gives each line the scope getInnerScope gives it (#209)" {
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    const src =
        \\module m
        \\  integer :: x
        \\contains
        \\  subroutine s(n)
        \\    integer :: n, i
        \\    do i = 1, n; associate (y => x)
        \\      block
        \\        x = y
        \\      end block
        \\    end associate; end do
        \\  end subroutine s
        \\  function f()
        \\    integer :: f
        \\    f = 1
        \\  end function f
        \\end module m
        \\program p
        \\  use m
        \\  call s(2)
        \\end program p
        \\
    ;
    const f = try FortranFile.create(gpa, "/w/inner.f90", null);
    defer f.destroy();
    _ = try f.setTextOwned(try gpa.dupe(u8, src));
    const ast = try f.parse(std.testing.io, null, &.{}, .{});
    defer ast.destroy();
    const n = f.nLines();
    const inner = try ast.innerScopes(gpa, n);
    defer gpa.free(inner.lines);
    for (0..n + 2) |ln| try std.testing.expectEqual(ast.getInnerScope(ln), inner.at(ln));
}

test "statements outside every program unit: a main program when END closes them (#229)" {
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    const Case = struct { path: []const u8, text: []const u8, main: ?[2]usize, none: bool };
    for ([_]Case{
        .{ .path = "/w/a.f90", .text = "implicit none\ninteger :: i\ni = 1\nend\nsubroutine s\nend subroutine\n", .main = .{ 1, 4 }, .none = false },
        .{ .path = "/w/b.f90", .text = "subroutine s\nend subroutine\n\n  print *, 1\nend program\n", .main = .{ 4, 5 }, .none = false },
        // the text of an include: no END
        .{ .path = "/w/c.inc", .text = "  integer :: n\n  n = 1\n", .main = null, .none = true },
        // the body of a macro is no statement
        .{ .path = "/w/d.h", .text = "#define ewrite(p, f) \\\n    if (p <= 3) write(p, f)\n", .main = null, .none = false },
    }) |c| {
        const f = try FortranFile.create(gpa, c.path, null);
        defer f.destroy();
        _ = try f.setTextOwned(try gpa.dupe(u8, c.text));
        const ast = try f.parse(std.testing.io, null, &.{}, .{});
        defer ast.destroy();
        var main: ?*Obj = null;
        for (ast.scope_list.items) |s| if (s.kind == .program) {
            main = s;
        };
        if (c.main) |lines| {
            try std.testing.expectEqual(lines[0], main.?.sline);
            try std.testing.expectEqual(lines[1], main.?.eline);
            try std.testing.expect(main.?.parent == null);
        } else try std.testing.expect(main == null);
        try std.testing.expectEqual(c.none, ast.none_scope != null);
        for (ast.scope_list.items) |s| if (s.kind == .subroutine) try std.testing.expect(s.parent == null);
    }
}
