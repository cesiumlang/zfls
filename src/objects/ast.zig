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
const Obj = objects.Obj;
const UseStmt = objects.UseStmt;
const Env = objects.Env;
const Diagnostic = objects.Diagnostic;
const BuiltDiag = objects.BuiltDiag;
const EndError = objects.EndError;

pub const IncludeInfo = struct {
    line_number: usize,
    path: []const u8,
    file: ?*FortranFile = null,
    scope_objs: std.ArrayList(*Obj) = .empty,
    /// Cached `Include` object returned by `find_in_scope`
    inc_obj: ?*Obj = null,
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
    parse_errors: std.ArrayList(BuiltDiag) = .empty,
    inherit_objs: std.ArrayList(*Obj) = .empty,
    linkable_objs: std.ArrayList(*Obj) = .empty,
    external_objs: std.ArrayList(*Obj) = .empty,
    none_scope: ?*Obj = null,
    inc_scope: ?*Obj = null,
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

    fn createNoneScope(self: *Ast) Allocator.Error!void {
        std.debug.assert(self.none_scope == null);
        const ns = try Obj.newScope(self, .program, 1, "main", &.{});
        self.none_scope = ns;
        try self.addScope(ns, &R().END_PROGRAM_NONE, false, false);
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
                try self.createNoneScope();
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
            try self.createNoneScope();
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
        try self.private_list.append(self.allocator(), try std.fmt.allocPrint(self.allocator(), "{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addPublic(self: *Ast, name: []const u8) !void {
        try self.public_list.append(self.allocator(), try std.fmt.allocPrint(self.allocator(), "{s}::{s}", .{ self.enc_scope_name orelse "None", name }));
    }

    pub fn addUse(self: *Ast, use_mod: *UseStmt) !void {
        if (self.current_scope == null) try self.createNoneScope();
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

    fn findChildByName(parent: *Obj, name: []const u8) ?*Obj {
        for (parent.childList()) |child| {
            if (std.mem.eql(u8, child.name, name)) return child;
            if (std.mem.startsWith(u8, child.name, "#GEN_INT")) {
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

    pub fn closeFile(self: *Ast, line_number: usize) !void {
        while (self.current_scope != null) try self.endScope(line_number, false);
        if (self.none_scope) |ns| {
            ns.end(line_number);
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
        if (std.fs.path.isAbsolute(name)) return try parser.normPath(tmp, name);
        const local = try parser.normPath(tmp, try std.fs.path.join(tmp, &.{ file_dir, name }));
        if (workspace.get(local) != null) return local;
        for (include_dirs) |dir| {
            const candidate = try parser.normPath(tmp, try std.fs.path.join(tmp, &.{ dir, name }));
            if (workspace.get(candidate) != null) return candidate;
        }
        return null;
    }

    /// Link the objects of included files into the including scopes
    pub fn resolveIncludes(self: *Ast, workspace: anytype, include_dirs: []const []const u8, only_path: ?[]const u8, tmp: Allocator) !void {
        const path = self.path orelse return;
        const file_dir = std.fs.path.dirname(path) orelse "";
        for (self.include_statements.items) |inc| {
            const file_path = (try findInclude(workspace, file_dir, include_dirs, inc.path, tmp)) orelse continue;
            if (only_path) |p| if (!std.mem.eql(u8, p, file_path)) continue;
            const parent_scope = self.getInnerScope(inc.line_number);
            const include_file = workspace.get(file_path) orelse continue;
            const include_ast = include_file.ast orelse continue;
            inc.file = include_file;
            inc.inc_obj = null;
            include_ast.included_in = parent_scope;
            if (include_ast.none_scope == null) continue;
            if (include_ast.inc_scope == null) include_ast.inc_scope = include_ast.none_scope;
            // Remove old objects
            if (parent_scope) |ps| {
                for (inc.scope_objs.items) |obj| {
                    for (ps.childList(), 0..) |c, i| if (c == obj) {
                        _ = ps.scopeData().children.orderedRemove(i);
                        break;
                    };
                }
            }
            inc.scope_objs.clearRetainingCapacity();
            for (include_ast.inc_scope.?.childList()) |child| {
                try inc.scope_objs.append(self.allocator(), child);
                if (parent_scope) |ps| {
                    try ps.addChild(child);
                    try child.updateFqsn(ps.fqsn);
                }
            }
            include_ast.none_scope = parent_scope;
        }
    }

    pub fn checkFile(self: *Ast, env: Env) !struct { errors: []Diagnostic, parse_errors: []BuiltDiag } {
        const a = env.tmp;
        var errors: std.ArrayList(Diagnostic) = .empty;
        var tmp_list: std.ArrayList(*Obj) = .empty;
        try tmp_list.appendSlice(a, self.scope_list.items);
        if (self.none_scope) |ns| try tmp_list.append(a, ns);
        for (self.end_errors.items) |e| {
            const message = if (e.end_line) |el|
                try std.fmt.allocPrint(a, "Unexpected end of scope at line {d}", .{el})
            else
                "Unexpected end statement: No open scopes";
            try errors.append(a, Diagnostic.init(.unexpected_end, e.scope_line -| 1, message, 1, null));
        }
        for (tmp_list.items) |scope| {
            if (!scope.checkValidParent()) {
                try errors.append(a, Diagnostic.init(
                    .invalid_parent,
                    scope.sline -| 1,
                    try std.fmt.allocPrint(a, "Invalid parent for \"{s}\" declaration", .{try scope.getDesc(a)}),
                    1,
                    null,
                ));
            }
            try errors.appendSlice(a, try scope.checkUse(env));
            try errors.appendSlice(a, try scope.checkDefinitions(env));
            try errors.appendSlice(a, try scope.getDiagnostics(a));
        }
        return .{ .errors = errors.items, .parse_errors = self.parse_errors.items };
    }
};
