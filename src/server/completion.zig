//! Completion: names in scope, keywords, construct names, keyword arguments
//! and names of modules not used yet.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const constructs = @import("../constructs.zig");
const arguments = @import("../arguments.zig");
const autouse = @import("../autouse.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const workspace = @import("workspace.zig");
const signature = @import("signature.zig");

/// The inner scopes and the base type are always left out; `def` is
/// whether the types of named objects are
pub fn setTypeMask(def: bool) Server.TypeMask {
    var m = Server.TypeMask.initMany(&.{ .base, .submodule, .block, .select, .do_, .where, .if_, .assoc, .enum_ });
    if (def) m.setUnion(Server.TypeMask.initMany(&.{ .module, .subroutine, .function, .class, .interface, .variable, .method }));
    return m;
}

pub fn childCandidates(a: Allocator, scope: *Obj, only_list: ?*const objects.StrSet, filter_public: bool, req_abstract: bool, out: *std.ArrayList(*Obj)) !void {
    const nonly = if (only_list) |o| o.len() else 0;
    for (try scope.getChildren(a, filter_public)) |child| {
        if (req_abstract) {
            if (child.isAbstract()) try childCandidates(a, child, only_list, filter_public, false, out);
        } else {
            if (child.isExternalInt()) {
                try childCandidates(a, child, only_list, filter_public, false, out);
            } else {
                if (nonly > 0) {
                    var buf: [256]u8 = undefined;
                    const lname = if (child.name.len <= buf.len)
                        std.ascii.lowerString(&buf, child.name)
                    else
                        try std.ascii.allocLowerString(a, child.name);
                    if (!only_list.?.contains(lname)) continue;
                }
                try out.append(a, child);
            }
        }
    }
}

pub fn getCandidates(self: *Server, a: Allocator, scope_list: []const *Obj, var_prefix: []const u8, inc_globals: bool, public_only: bool, abstract_only: bool, no_use: bool) !Server.Candidates {
    var var_list: std.ArrayList(*Obj) = .empty;
    var use_dict = std.array_hash_map.String(*objects.UseStmt).empty;
    // global names resolve to the requesting file's own definitions first
    const own: ?*objects.Ast = if (scope_list.len > 0) scope_list[0].file_ast else null;
    for (scope_list) |scope| {
        try childCandidates(a, scope, null, public_only, abstract_only, &var_list);
        if (!no_use) try objects.getUseTree(self.env(a), scope, &use_dict, null, null, &.{});
    }
    var rename_list: std.ArrayList(?[]const u8) = .empty;
    try rename_list.appendNTimes(a, null, var_list.items.len);
    var import_var_list: std.ArrayList(*Obj) = .empty;
    var it = use_dict.iterator();
    while (it.next()) |e| {
        const use_mod = e.key_ptr.*;
        const use_info = e.value_ptr.*;
        if (!use_info.is_import) {
            const scope = (if (own) |ast| self.env(a).global(ast, use_mod) else if (self.obj_tree.get(use_mod)) |t| t.obj else null) orelse continue;
            var only: objects.StrSet = .{};
            for (try use_info.rename(a)) |o| try only.add(a, o);
            var tmp: std.ArrayList(*Obj) = .empty;
            try childCandidates(a, scope, &only, true, abstract_only, &tmp);
            if (use_info.rename_map.count() > 0) {
                for (tmp.items) |obj| {
                    try var_list.append(a, obj);
                    var rev: ?[]const u8 = null;
                    // reversed rename map (last key wins for duplicate values);
                    // the values are lowercase
                    for (use_info.rename_map.keys.items, use_info.rename_map.values.items) |k, v| {
                        if (std.ascii.eqlIgnoreCase(v, obj.name)) rev = k;
                    }
                    try rename_list.append(a, rev);
                }
            } else {
                try var_list.appendSlice(a, tmp.items);
                try rename_list.appendNTimes(a, null, tmp.items.len);
            }
        } else {
            const scope = use_info.scope orelse continue;
            try childCandidates(a, scope, &use_info.only_list, true, abstract_only, &import_var_list);
        }
    }
    if (inc_globals) {
        var tree_it = self.obj_tree.iterator();
        while (tree_it.next()) |e| {
            const mine = if (own) |ast| ast.global_dict.get(e.key_ptr.*) else null;
            try var_list.append(a, mine orelse e.value_ptr.obj);
            try rename_list.append(a, null);
        }
        for (self.intr.funs) |f| {
            try var_list.append(a, f);
            try rename_list.append(a, null);
        }
    }
    if (import_var_list.items.len > 0) {
        var_list = import_var_list;
        rename_list = .empty;
        try rename_list.appendNTimes(a, null, var_list.items.len);
    }
    if (var_prefix.len == 0) return .{ .objs = var_list.items, .renames = rename_list.items };
    var out_objs: std.ArrayList(*Obj) = .empty;
    var out_renames: std.ArrayList(?[]const u8) = .empty;
    for (var_list.items, rename_list.items) |v, rn| {
        const name = rn orelse v.name;
        if (std.ascii.startsWithIgnoreCase(name, var_prefix)) {
            try out_objs.append(a, v);
            try out_renames.append(a, rn);
        }
    }
    return .{ .objs = out_objs.items, .renames = out_renames.items };
}

/// The LSP completion item kind; the ids of the types that have no kind of
/// their own are used as they are, as fortls does
pub fn mapCompletionKind(t: C.TypeId) i64 {
    return switch (t) {
        .module => 9,
        .subroutine => 3,
        .class => 7,
        .variable => 6,
        else => @backingInt(t),
    };
}

pub fn buildComp(self: *Server, a: Allocator, candidate: *Obj, name_only: bool, name_replace: ?[]const u8, is_interface: bool, is_member: bool) !lsp.CompletionItem {
    var call_sig: ?[]const u8 = null;
    var label = candidate.name;
    var insert_text: ?[]const u8 = null;
    if (!name_only) {
        if (name_replace) |nr| label = nr;
        const sn = try candidate.getSnippet(a, name_replace, null);
        call_sig = sn.call;
        var snippet = sn.snippet;
        if (self.s.autocomplete_no_snippets) snippet = call_sig;
        if (snippet) |s0| {
            var s = s0;
            if (self.s.use_signature_help and !is_interface) {
                if (std.mem.indexOfScalar(u8, s, '(')) |arg_open| if (arg_open > 0) {
                    s = s[0..arg_open];
                };
            }
            insert_text = s;
        }
    }
    var kind = mapCompletionKind(candidate.getType(false));
    if (is_member and kind == 3) kind = 2;
    var detail = try candidate.getDesc(a);
    if (call_sig) |cs| detail = try std.fmt.allocPrint(a, "{s} {s}", .{ detail, cs });
    var documentation: ?lsp.MarkupContent = null;
    const hover_msg = try candidate.getHoverMd(a, true, null);
    if (hover_msg.len > 0) {
        documentation = .{ .value = try str.replaceFirst(a, hover_msg, "```{langid}", try std.fmt.allocPrint(a, "```{s}", .{self.s.hover_language})) };
    }
    return .{
        .label = label,
        .insertText = insert_text,
        .insertTextFormat = if (insert_text != null) lsp.snippet_format else null,
        .kind = kind,
        .detail = detail,
        .documentation = documentation,
    };
}

/// After `exit` or `cycle`, the names of the constructs that are open
/// (DO constructs for CYCLE), innermost first (hansec #157)
pub fn constructNameCompletion(self: *Server, a: Allocator, file: *const FortranFile, ast: *Ast, line: usize, col: usize) !?[]const lsp.CompletionItem {
    _ = self;
    const text = file.getLine(line, false) orelse return null;
    const prefix = text[0..@min(col, text.len)];
    // the start of a name, after `exit ` or `cycle `
    var n = prefix.len;
    while (n > 0 and (std.ascii.isAlphanumeric(prefix[n - 1]) or prefix[n - 1] == '_')) n -= 1;
    const typed = prefix[n..];
    const before = std.mem.trimEnd(u8, prefix[0..n], " \t");
    if (before.len == n) return null;
    var k = before.len;
    while (k > 0 and std.ascii.isAlphabetic(before[k - 1])) k -= 1;
    const keyword = before[k..];
    const loops_only = std.ascii.eqlIgnoreCase(keyword, "cycle");
    if (!loops_only and !std.ascii.eqlIgnoreCase(keyword, "exit")) return null;
    // which starts the statement, or follows the condition of an IF
    const lead = std.mem.trimEnd(u8, before[0..k], " \t");
    if (!(std.mem.trim(u8, lead, " \t0123456789").len == 0 or std.mem.endsWith(u8, lead, ")"))) return null;
    var items: std.ArrayList(lsp.CompletionItem) = .empty;
    for (try constructs.enclosingNames(a, file, ast, line, loops_only)) |cname| {
        if (!std.ascii.startsWithIgnoreCase(cname, typed)) continue;
        try items.append(a, .{ .label = cname, .kind = 14, .detail = if (loops_only) "DO construct" else "construct" });
    }
    return items.items;
}

/// Inside the argument list of a call, while an argument is a bare
/// name: `name=` for each argument the call can name and has not named
/// yet (hansec #133), sorted first
pub fn keywordArgItems(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, line: usize, col: usize, items: *std.ArrayList(lsp.CompletionItem)) !void {
    const call = (try signature.callAt(self, a, file, ast, line, col)) orelse return;
    if (call.args.len == 0) return;
    const typed = str.strip(call.args[call.args.len - 1]);
    for (typed) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return;
    const keywords = try arguments.keywordsOf(a, call.obj);
    next: for (keywords) |k| {
        for (call.args[0 .. call.args.len - 1]) |arg| {
            if (arguments.keywordOfArg(arg)) |given| if (std.ascii.eqlIgnoreCase(given, k.name)) continue :next;
        }
        if (!std.ascii.startsWithIgnoreCase(k.name, typed)) continue;
        const name = if (k.intrinsic and self.s.lowercase_intrinsics) try std.ascii.allocLowerString(a, k.name) else k.name;
        const label = try std.mem.concat(a, u8, &.{ name, "=" });
        const detail = k.detail orelse if (k.optional) "OPTIONAL" else "";
        try items.append(a, .{
            .label = label,
            .kind = 6,
            .detail = detail,
            .sortText = try std.mem.concat(a, u8, &.{ "0", name }),
            .filterText = name,
        });
    }
}

/// The parent components of a type that extends others (`x%feature_base`
/// for a type extending `feature_base`, hansec #121): the names of its
/// ancestor types
fn parentComponentItems(a: Allocator, type_scope: *Obj, prefix: []const u8, items: *std.ArrayList(lsp.CompletionItem)) !void {
    if (type_scope.kind != .type) return;
    var cur = type_scope.typeDataConst().inherit_var;
    var depth: usize = 0;
    while (cur) |p| : (depth += 1) {
        if (depth > 32 or p.kind != .type) break;
        if (std.ascii.startsWithIgnoreCase(p.name, prefix)) try items.append(a, .{
            .label = p.name,
            .kind = 5,
            .detail = try std.fmt.allocPrint(a, "TYPE({s})", .{p.name}),
            .labelDetails = .{ .description = "parent" },
        });
        cur = p.typeDataConst().inherit_var;
    }
}

pub fn serveAutocomplete(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const uri = params.textDocument.uri;
    const file = (try self.fileFromUri(a, uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const ac_line = params.position.line;
    const ac_char = Server.toByteCol(file, ac_line, params.position.character);
    if (try constructNameCompletion(self, a, file, ast, ac_line, ac_char)) |items| return json.from(a, items);
    const cl = try file.getCodeLine(a, ac_line, false, true, false, true);
    const line_prefix = (try helpers.getLinePrefix(a, cl.pre, cl.curr, ac_char, true)) orelse return .null;
    const var_stack = try helpers.getVarStack(a, line_prefix);
    const is_member = var_stack.len > 1;
    var var_prefix = str.strip(var_stack[var_stack.len - 1]);
    const typed_prefix = var_prefix;

    var item_list: std.ArrayList(lsp.CompletionItem) = .empty;
    var name_only = self.s.autocomplete_name_only;
    var public_only = false;
    var include_globals = true;
    const lc = try parser.getLineContext(a, line_prefix);
    if (lc.ctx == .skip or (var_prefix.len == 0 and !is_member)) return .null;
    if (self.s.autocomplete_no_prefix) var_prefix = "";

    var scope_list: []const *Obj = &.{};
    if (is_member) {
        const curr_scope = ast.getInnerScope(ac_line + 1);
        const type_scope = (try objects.climbTypeTree(self.env(a), var_stack, curr_scope)) orelse return .null;
        include_globals = false;
        const one = try a.alloc(*Obj, 1);
        one[0] = type_scope;
        scope_list = one;
        try parentComponentItems(a, type_scope, var_prefix, &item_list);
    } else {
        scope_list = try ast.getScopes(a, ac_line + 1);
    }
    var req_callable = false;
    var abstract_only = false;
    var no_use = false;
    var type_mask = setTypeMask(false);
    type_mask.insert(.module);
    type_mask.insert(.class);
    switch (lc.ctx) {
        .mod_only => {
            for (self.obj_tree.values()) |e| {
                const cand = e.obj;
                if (cand.getType(false) == C.TypeId.module and std.ascii.startsWithIgnoreCase(cand.name, var_prefix)) {
                    try item_list.append(a, try buildComp(self, a, cand, true, null, false, false));
                }
            }
            return json.from(a, item_list.items);
        },
        .mod_mems => {
            name_only = true;
            const mod_name = try std.ascii.allocLowerString(a, lc.info orelse "");
            const mod = self.env(a).global(ast, mod_name) orelse return .null;
            const one = try a.alloc(*Obj, 1);
            one[0] = mod;
            scope_list = one;
            public_only = true;
            include_globals = false;
            type_mask.remove(.class);
        },
        .pro_link => {
            type_mask = setTypeMask(true);
            type_mask.remove(.subroutine);
            type_mask.remove(.function);
            name_only = true;
            include_globals = false;
            no_use = true;
        },
        .call => req_callable = true,
        .type_only => {
            type_mask = setTypeMask(true);
            type_mask.remove(.class);
        },
        .import => {
            name_only = true;
            type_mask = setTypeMask(true);
            type_mask.remove(.class);
            type_mask.remove(.variable);
        },
        .vis => {
            include_globals = false;
            name_only = true;
            type_mask = setTypeMask(true);
            type_mask.remove(.class);
            type_mask.remove(.variable);
            type_mask.remove(.subroutine);
            type_mask.remove(.function);
        },
        .int_only => {
            abstract_only = true;
            include_globals = false;
            name_only = true;
            type_mask = setTypeMask(true);
            type_mask.remove(.subroutine);
            type_mask.remove(.function);
        },
        .var_only => {
            name_only = true;
            type_mask.insert(.subroutine);
            type_mask.insert(.function);
        },
        .var_key => {
            var key_context: i32 = 0;
            if (scope_list.len > 0) {
                const enc = scope_list[scope_list.len - 1].getType(false);
                if (enc == C.TypeId.module) {
                    key_context = 1;
                } else if (enc == C.TypeId.subroutine or enc == C.TypeId.function) {
                    key_context = 2;
                } else if (enc == C.TypeId.class) {
                    key_context = 3;
                }
            }
            for (try self.intr.keywordsFor(a, key_context)) |cand| {
                if (std.ascii.startsWithIgnoreCase(cand.name, var_prefix)) {
                    try item_list.append(a, try buildComp(self, a, cand, self.s.autocomplete_name_only, null, false, false));
                }
            }
            return json.from(a, item_list.items);
        },
        .first => {
            for (try self.intr.keywordsFor(a, 0)) |cand| {
                if (std.ascii.startsWithIgnoreCase(cand.name, var_prefix)) {
                    try item_list.append(a, try buildComp(self, a, cand, self.s.autocomplete_name_only, null, false, false));
                }
            }
        },
        else => {},
    }
    if (lc.ctx == .default and !is_member) try keywordArgItems(self, a, file, ast, ac_line, ac_char, &item_list);
    const cands = try getCandidates(self, a, scope_list, var_prefix, include_globals, public_only, abstract_only, no_use);
    for (cands.objs, cands.renames) |cand, rename| {
        const ctype = cand.getType(false);
        if (type_mask.contains(ctype)) continue;
        if (req_callable and !cand.isCallable()) continue;
        var name_replace = rename;
        if (ctype == C.TypeId.interface and lc.ctx != .mod_mems) {
            var seen: std.ArrayList([]const u8) = .empty;
            if (name_replace == null) name_replace = cand.name;
            for (cand.memList()) |member| {
                const text = (try member.getSnippet(a, name_replace, null)).call orelse "None";
                var dup = false;
                for (seen.items) |s| if (std.mem.eql(u8, s, text)) {
                    dup = true;
                };
                if (dup) continue;
                try seen.append(a, text);
                try item_list.append(a, try buildComp(self, a, member, self.s.autocomplete_name_only, name_replace, true, is_member));
            }
            continue;
        }
        try item_list.append(a, try buildComp(self, a, cand, name_only, name_replace, false, false));
    }
    if (!self.s.autocomplete_no_auto_use and !is_member and typed_prefix.len >= 2) switch (lc.ctx) {
        .default, .call, .type_only, .first => try autoUseItems(self, a, file, ast, ac_line, typed_prefix, type_mask, req_callable, &item_list),
        else => {},
    };
    return json.from(a, item_list.items);
}

/// The modules a USE statement can bring names in from: those of the
/// workspace and the intrinsic ones
pub fn usableModules(self: *Server, a: Allocator) ![]const *Obj {
    var out: std.ArrayList(*Obj) = .empty;
    for (self.obj_tree.values()) |e| if (e.obj.kind == .module) try out.append(a, e.obj);
    try out.appendSlice(a, self.intr.mods);
    return out.items;
}

/// The public names starting with `prefix` of modules the program unit
/// at 0-based `line` does not see, each completing with the USE
/// statement that brings it in (hansec #62), sorted after the others
pub fn autoUseItems(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, line: usize, prefix: []const u8, type_mask: Server.TypeMask, req_callable: bool, items: *std.ArrayList(lsp.CompletionItem)) !void {
    const unit = autouse.unitOf(try ast.getScopes(a, line + 1)) orelse return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (items.items) |it| try seen.put(a, try std.ascii.allocLowerString(a, it.label), {});
    const at = try autouse.insertionPoint(a, file, unit);
    const range = Server.rangeOf(file, at.line, 0, at.line, 0);
    for (try autouse.exports(a, try usableModules(self, a), .{ .prefix = prefix }, 50)) |e| {
        if (autouse.isWithin(unit, e.module)) continue;
        if (seen.contains(try std.ascii.allocLowerString(a, e.obj.name))) continue;
        if (type_mask.contains(e.obj.getType(false))) continue;
        if (req_callable and !e.obj.isCallable()) continue;
        var item = try buildComp(self, a, e.obj, self.s.autocomplete_name_only, null, false, false);
        item.detail = try std.fmt.allocPrint(a, "{s} (use {s})", .{ item.detail, e.module.name });
        item.sortText = try std.mem.concat(a, u8, &.{ "~", e.obj.name });
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = range, .newText = try autouse.statement(a, at.indent, e.module.name, e.obj.name) };
        item.additionalTextEdits = edits;
        try items.append(a, item);
    }
}
