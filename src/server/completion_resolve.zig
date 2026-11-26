//! The documentation of completion items, sent when the client resolves an
//! item (`completionItem/resolve`) for a client that does so, in every
//! item otherwise: a list of hundreds of names is then only names, kinds
//! and details, and the documentation of the one the user selects follows.
//! An item names its object in its `data` (`lsp.CompletionData`): the file
//! and fully qualified name, or its place among the intrinsics.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const objects = @import("../objects.zig");
const docmath = @import("../docmath.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const Value = json.Value;

const Server = @import("../server.zig").Server;

/// Whether the client resolves the documentation of completion items
pub fn wanted(caps: lsp.ClientCapabilities) bool {
    for (caps.textDocument.completion.completionItem.resolveSupport.properties) |p| {
        if (std.mem.eql(u8, p, "documentation")) return true;
    }
    return false;
}

/// The documentation of an item for `obj`: its hover text, its formulas
/// written as `doc_math` says
pub fn documentation(self: *Server, a: Allocator, obj: *const Obj) !?lsp.MarkupContent {
    const hover_msg = try obj.getHoverMd(a, true, null);
    if (hover_msg.len == 0) return null;
    const md = try str.replaceFirst(a, hover_msg, "```{langid}", try a.print("```{s}", .{self.s.hover_language}));
    return .{ .value = try docmath.rewrite(a, md, docmath.Mode.of(self.s.doc_math)) };
}

/// What finds `obj` again, null for an object that cannot be found (its
/// item then carries its documentation)
pub fn dataOf(self: *Server, obj: *const Obj) ?lsp.CompletionData {
    if (obj.file_ast == self.intr.ast) {
        // a name of an intrinsic module
        if (obj.fqsn.len > 0) return .{ .q = obj.fqsn };
        var i: usize = 0;
        for (intrinsicLists(self)) |list| for (list) |o| {
            if (o == obj) return .{ .i = i };
            i += 1;
        };
        return null;
    }
    const path = obj.file_ast.path orelse return null;
    if (obj.fqsn.len == 0) return null;
    return .{ .f = self.workspace.getIndex(path) orelse return null, .q = obj.fqsn, .l = obj.sline };
}

/// The intrinsic procedures and keywords, in the order of the indices of
/// `CompletionData.i`
fn intrinsicLists(self: *const Server) [8][]const *Obj {
    const t = &self.intr;
    return .{ t.stmt_int_stmnts, t.stmt_var_def, t.kw_var_def, t.kw_arg, t.kw_type_mem, t.kw_vis, t.kw_param, t.funs };
}

/// `completionItem/resolve`: the item with its documentation, as it came
/// when its object is no longer there
pub fn serveResolve(self: *Server, a: Allocator, params: Value) !Value {
    if (params != .object) return params;
    const raw = json.get(params, "data") orelse return params;
    const data = json.decode(lsp.CompletionData, a, raw) catch return params;
    const obj = find(self, data) orelse return params;
    const doc = (try documentation(self, a, obj)) orelse return params;
    var item = params;
    try item.object.put(a, "documentation", try json.from(a, doc));
    return item;
}

fn find(self: *Server, data: lsp.CompletionData) ?*Obj {
    if (data.i) |want| {
        var i: usize = 0;
        for (intrinsicLists(self)) |list| for (list) |o| {
            if (i == want) return o;
            i += 1;
        };
        return null;
    }
    const fqsn = data.q orelse return null;
    const f = data.f orelse {
        for (self.intr.mods) |m| if (inTree(m, fqsn)) |o| return o;
        return null;
    };
    const files = self.workspace.values();
    if (f < files.len) if (files[f].ast) |ast| if (inAst(ast, fqsn, data.l orelse 0)) |o| return o;
    // the workspace's files changed since
    for (files) |file| if (file.ast) |ast| if (inAst(ast, fqsn, data.l orelse 0)) |o| return o;
    return null;
}

/// The object of a file: by name and line, else (the file changed since)
/// the first by name
fn inAst(ast: *Ast, fqsn: []const u8, line: usize) ?*Obj {
    var first: ?*Obj = null;
    for (0..ast.scope_list.items.len + 1) |k| {
        // the implicit main program is not among the scopes
        const scope = if (k < ast.scope_list.items.len) ast.scope_list.items[k] else ast.none_scope orelse break;
        if (scope.file_ast != ast) continue;
        if (std.mem.eql(u8, scope.fqsn, fqsn)) {
            if (scope.sline == line) return scope;
            if (first == null) first = scope;
        }
        for (scope.childList()) |child| {
            if (child.file_ast != ast or !std.mem.eql(u8, child.fqsn, fqsn)) continue;
            if (child.sline == line) return child;
            if (first == null) first = child;
        }
    }
    return first;
}

fn inTree(obj: *Obj, fqsn: []const u8) ?*Obj {
    if (std.mem.eql(u8, obj.fqsn, fqsn)) return obj;
    for (obj.childList()) |child| if (inTree(child, fqsn)) |o| return o;
    return null;
}
