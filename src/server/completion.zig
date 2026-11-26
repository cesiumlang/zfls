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
const completion_resolve = @import("completion_resolve.zig");
const snippets = @import("snippets.zig");
const directive_completion = @import("directive_completion.zig");

/// The inner scopes and the base type are always left out; `def` is
/// whether the types of named objects are
pub fn setTypeMask(def: bool) Server.TypeMask {
    var m = Server.TypeMask.initMany(&.{ .base, .submodule, .block, .select, .do_, .where, .if_, .assoc, .enum_ });
    if (def) m.setUnion(Server.TypeMask.initMany(&.{ .module, .subroutine, .function, .class, .interface, .variable, .method }));
    return m;
}

/// Which abstract interfaces completion offers: none (where a procedure
/// goes), only them (`procedure(`), or them too (the lists of names of a
/// USE ONLY, PUBLIC, PRIVATE or IMPORT statement, #481)
pub const Abstract = enum { no, only, too };

pub fn childCandidates(a: Allocator, scope: *Obj, only_list: ?*const objects.StrSet, filter_public: bool, abstract: Abstract, out: *std.ArrayList(*Obj)) !void {
    const req_abstract = abstract == .only;
    if (!req_abstract) for (try scope.getChildren(a, filter_public)) |child| {
        // not an interface block without a name (`#GEN_INT`: unnamed,
        // abstract, OPERATOR, ASSIGNMENT), but a named generic
        if (child.kind == .interface and std.mem.startsWith(u8, child.name, "#")) continue;
        if (try inOnlyList(a, only_list, child.name)) try out.append(a, child);
    };
    // the interface bodies of its interface blocks (of its abstract ones,
    // for `.only`, of every one for `.too`) are names of the scope, public or
    // not as its own names (as `checkScope` finds them, #474); one that has
    // the name of its generic is offered by the generic
    for (scope.childList()) |child| {
        if (child.kind != .interface) continue;
        if (abstract != .too and child.isAbstract() != req_abstract) continue;
        for (child.childList()) |body| {
            if (!child.bodiesAreNames(body.name)) continue;
            const private = body.vis == .private or (scope.def_vis == .private and body.vis != .public);
            if (filter_public and private) continue;
            if (try inOnlyList(a, only_list, body.name)) try out.append(a, body);
        }
    }
    if (req_abstract) return;
    // the enumerators of an ENUM are names of the scope around it, public
    // or not as its own names (as `checkScope` finds them)
    for (scope.childList()) |child| {
        if (child.kind != .enum_) continue;
        for (child.childList()) |e| {
            const private = e.vis == .private or (scope.def_vis == .private and e.vis != .public);
            if (filter_public and private) continue;
            if (!try inOnlyList(a, only_list, e.name)) continue;
            try out.append(a, e);
        }
    }
}

/// Whether `name` passes an ONLY list (an empty or no list passes all)
fn inOnlyList(a: Allocator, only_list: ?*const objects.StrSet, name: []const u8) !bool {
    const only = only_list orelse return true;
    if (only.len() == 0) return true;
    var buf: [256]u8 = undefined;
    const lname = if (name.len <= buf.len) std.ascii.lowerString(&buf, name) else try std.ascii.allocLowerString(a, name);
    return only.contains(lname);
}

pub fn getCandidates(self: *Server, a: Allocator, scope_list: []const *Obj, var_prefix: []const u8, inc_globals: bool, public_only: bool, abstract: Abstract, no_use: bool) !Server.Candidates {
    var var_list: std.ArrayList(*Obj) = .empty;
    var use_dict = std.array_hash_map.String(*objects.UseStmt).empty;
    // global names resolve to the requesting file's own definitions first
    const own: ?*objects.Ast = if (scope_list.len > 0) scope_list[0].file_ast else null;
    for (scope_list) |scope| {
        try childCandidates(a, scope, null, public_only, abstract, &var_list);
        if (!no_use) try objects.getUseTree(self.env(a), scope, &use_dict, null, null, &.{});
    }
    // inside an ENUM its enumerators are names of it and of the scope
    // around it: each once
    var seen: std.AutoHashMapUnmanaged(*Obj, void) = .empty;
    var n: usize = 0;
    for (var_list.items) |o| {
        if ((try seen.getOrPut(a, o)).found_existing) continue;
        var_list.items[n] = o;
        n += 1;
    }
    var_list.shrinkRetainingCapacity(n);
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
            try childCandidates(a, scope, &only, true, abstract, &tmp);
            for (tmp.items) |obj| {
                var rev: ?[]const u8 = null;
                // reversed rename map (last key wins for duplicate values);
                // the values are lowercase
                for (use_info.rename_map.keys.items, use_info.rename_map.values.items) |k, v| {
                    if (std.ascii.eqlIgnoreCase(v, obj.name)) rev = k;
                }
                const local = rev orelse obj.name;
                if (!std.ascii.startsWithIgnoreCase(local, var_prefix)) continue;
                // a module that the USE tree passes through may keep it
                // from the scopes (#235)
                if (!try seenThroughUse(self, a, scope_list, local, public_only)) continue;
                try var_list.append(a, obj);
                try rename_list.append(a, rev);
            }
        } else {
            const scope = use_info.scope orelse continue;
            try childCandidates(a, scope, &use_info.only_list, true, abstract, &import_var_list);
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

/// Whether a name of a used module, `local` as the scopes have it, is one
/// of theirs by USE; `outside`: as the users of the module that is the
/// one scope see it
fn seenThroughUse(self: *Server, a: Allocator, scope_list: []const *Obj, local: []const u8, outside: bool) !bool {
    const lower = try std.ascii.allocLowerString(a, local);
    for (scope_list) |s| {
        if (try objects.findThroughUse(self.env(a), s, lower, outside) != null) return true;
    }
    return false;
}

/// The scopes whose names an IMPORT statement on line `line` (1-based) can
/// name: of `scopes`, those around the host of the interface body it is in,
/// not the body nor any scope inside it. `scopes` as they are when the line
/// is in no interface body.
fn importHostScopes(a: Allocator, ast: *Ast, scopes: []const *Obj, line: usize) ![]const *Obj {
    var body = ast.getInnerScope(line) orelse return scopes;
    while (true) {
        const p = body.parent orelse return scopes;
        if (p.kind == .interface) break;
        body = p;
    }
    var out: std.ArrayList(*Obj) = .empty;
    next: for (scopes) |s| {
        var cur: ?*Obj = s;
        while (cur) |c| : (cur = c.parent) if (c == body) continue :next;
        try out.append(a, s);
    }
    return out.items;
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
                if (std.mem.findScalar(u8, s, '(')) |arg_open| if (arg_open > 0) {
                    s = s[0..arg_open];
                };
            }
            insert_text = s;
        }
    }
    var kind = mapCompletionKind(candidate.getType(false));
    if (is_member and kind == 3) kind = 2;
    var detail = try candidate.getDesc(a);
    if (call_sig) |cs| detail = try a.print("{s} {s}", .{ detail, cs });
    // left to completionItem/resolve where the client resolves it
    const data = if (self.completion_resolve) completion_resolve.dataOf(self, candidate) else null;
    const documentation = if (data == null) try completion_resolve.documentation(self, a, candidate) else null;
    return .{
        .label = label,
        .insertText = insert_text,
        .insertTextFormat = if (insert_text != null) lsp.snippet_format else null,
        .kind = kind,
        .detail = detail,
        .documentation = documentation,
        .data = data,
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
            .detail = try a.print("TYPE({s})", .{p.name}),
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
    // the names of a directive and its clauses (#742)
    if (try directive_completion.items(a, file, ac_line, ac_char)) |items| return if (items.len > 0) json.from(a, items) else .null;
    const cl = try file.getCodeLine(a, ac_line, false, true, false, true);
    const line_prefix = (try helpers.getLinePrefix(a, cl.pre, cl.curr, ac_char, true)) orelse return .null;
    const var_stack = try helpers.getVarStack(a, line_prefix);
    const is_member = var_stack.len > 1;
    // after a space no name is begun (`use `, not `use`)
    const after_space = line_prefix.len > 0 and std.ascii.isWhitespace(line_prefix[line_prefix.len - 1]);
    var var_prefix = if (after_space and !is_member) "" else str.strip(var_stack[var_stack.len - 1]);
    const typed_prefix = var_prefix;

    var item_list: std.ArrayList(lsp.CompletionItem) = .empty;
    var name_only = self.s.autocomplete_name_only;
    var public_only = false;
    var include_globals = true;
    const lc = try parser.getLineContext(a, line_prefix);
    // constructs and program units at the start of a statement (#264)
    if (!is_member and cl.pre.len == 0) if (try snippets.constructItems(self, a, file, ast, ac_line, ac_char)) |c| {
        if (c.alone or lc.ctx == .skip) return json.from(a, c.items);
        try item_list.appendSlice(a, c.items);
    };
    if (lc.ctx == .skip) return .null;
    // a name of the entity list of a declaration: the dummy arguments of
    // the procedure that are not declared yet, first, and with nothing
    // typed alone (#270)
    const entity = !is_member and entityNameAt(lc.ctx, line_prefix);
    if (entity) {
        try undeclaredArgItems(a, ast, ac_line, typed_prefix, &item_list);
        if (typed_prefix.len == 0) return if (item_list.items.len > 0) json.from(a, item_list.items) else .null;
    }
    // with nothing typed, only where the names are few and wanted (#283)
    const short_list = switch (lc.ctx) {
        .mod_mems, .mod_only, .type_only, .int_only, .import, .vis => true,
        else => false,
    };
    if (var_prefix.len == 0 and !is_member and !short_list) return if (item_list.items.len > 0) json.from(a, item_list.items) else .null;
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
    // the names an ONLY list has already
    var listed: []const []const u8 = &.{};
    var abstract: Abstract = .no;
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
            listed = try onlyListed(a, line_prefix);
            abstract = .too;
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
            // the names the host sees (#486): its own, those of the scopes
            // around it and those it has by USE, private ones too
            scope_list = try importHostScopes(a, ast, scope_list, ac_line + 1);
            include_globals = false;
            name_only = true;
            type_mask = setTypeMask(true);
            type_mask.remove(.class);
            type_mask.remove(.variable);
            // the abstract interfaces of the host (#481), its procedures and
            // its generics
            type_mask.remove(.subroutine);
            type_mask.remove(.function);
            type_mask.remove(.interface);
            abstract = .too;
        },
        .vis => {
            abstract = .too;
            include_globals = false;
            name_only = true;
            type_mask = setTypeMask(true);
            type_mask.remove(.class);
            type_mask.remove(.variable);
            type_mask.remove(.subroutine);
            type_mask.remove(.function);
            // a named generic, which a PUBLIC or PRIVATE statement can name
            type_mask.remove(.interface);
        },
        .int_only => {
            abstract = .only;
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
    // no intrinsics nor global names for nothing typed
    if (typed_prefix.len == 0) include_globals = false;
    const cands = try getCandidates(self, a, scope_list, var_prefix, include_globals, public_only, abstract, no_use);
    // a specific that has the name of its generic (#469) is offered once,
    // by the generic
    var by_generic: std.AutoHashMapUnmanaged(*const Obj, void) = .empty;
    if (!type_mask.contains(C.TypeId.interface)) for (cands.objs) |cand| for (cand.memList()) |m| {
        if (m != cand and std.ascii.eqlIgnoreCase(m.name, cand.name)) try by_generic.put(a, m, {});
    };
    next: for (cands.objs, cands.renames) |cand, rename| {
        const ctype = cand.getType(false);
        if (type_mask.contains(ctype)) continue;
        if (by_generic.contains(cand)) continue;
        // the name being typed, which this declaration declares
        if (entity and cand.kind == .variable and cand.file_ast == ast and cand.sline == ac_line + 1 and std.ascii.eqlIgnoreCase(cand.name, typed_prefix)) continue;
        for (listed) |l| if (std.ascii.eqlIgnoreCase(l, cand.name)) continue :next;
        if (req_callable and !cand.isCallable()) continue;
        var name_replace = rename;
        // a generic is offered as its specifics, except where only its own
        // name can stand (an IMPORT, PUBLIC or PRIVATE statement)
        if (ctype == C.TypeId.interface and lc.ctx != .mod_mems and lc.ctx != .vis and lc.ctx != .import) {
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

/// Whether the end of `line`, in line context `ctx`, is a name of the
/// entity list of a declaration (`real :: a, b`, `real x`), not its type,
/// attributes or an initialization
fn entityNameAt(ctx: parser.LineContext, line: []const u8) bool {
    const colons = std.mem.findLast(u8, line, "::");
    switch (ctx) {
        .var_only => {},
        .var_key => if (colons == null) return false,
        else => return false,
    }
    var list = if (colons) |c| line[c + 2 ..] else line;
    var depth: usize = 0;
    var i = list.len;
    while (i > 0) : (i -= 1) switch (list[i - 1]) {
        ')', ']' => depth += 1,
        '(', '[' => depth -|= 1,
        ',' => if (depth == 0) break,
        else => {},
    };
    list = list[i..];
    // the old form: the name after the type
    if (colons == null and i == 0) list = list[(std.mem.findScalarLast(u8, str.rstrip(list), ' ') orelse return false) + 1 ..];
    for (str.strip(list)) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// The dummy arguments starting with `prefix` of the procedure at 0-based
/// `line` that have no declaration (those `argument-not-declared` reports),
/// sorted first
fn undeclaredArgItems(a: Allocator, ast: *Ast, line: usize, prefix: []const u8, items: *std.ArrayList(lsp.CompletionItem)) !void {
    const proc = ast.getInnerScope(line + 1) orelse return;
    if (proc.kind != .subroutine and proc.kind != .function) return;
    const names = try str.split(a, proc.argList(), ",");
    for (proc.procDataConst().arg_objs.items, 0..) |arg, i| {
        if (arg != null or i >= names.len) continue;
        const name = str.strip(names[i]);
        // alternate returns
        if (name.len == 0 or name[0] == '*') continue;
        if (!std.ascii.startsWithIgnoreCase(name, prefix)) continue;
        try items.append(a, .{
            .label = name,
            .kind = 6,
            .detail = "argument not declared",
            .sortText = try std.mem.concat(a, u8, &.{ "0", name }),
        });
    }
}

/// The names of the module an ONLY list (at the end of `line`) has before
/// the one being written: `alpha` of `use m, only: alpha, a => beta, al`
/// and `beta`
fn onlyListed(a: Allocator, line: []const u8) ![]const []const u8 {
    const u = ((try parser.readUseStmt(a, line)) orelse return &.{}).use;
    if (u.only_list.len < 2) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (u.only_list[0 .. u.only_list.len - 1]) |local| {
        const original = for (u.renames) |r| {
            if (std.mem.eql(u8, r[0], local)) break r[1];
        } else local;
        try out.append(a, original);
    }
    return out.items;
}

/// The modules a USE statement in `ast` can bring names in from: those of
/// the workspace (of a name that several files define, the one `ast` sees)
/// and the intrinsic ones
pub fn usableModules(self: *Server, a: Allocator, ast: *const Ast) ![]const *Obj {
    var out: std.ArrayList(*Obj) = .empty;
    for (self.obj_tree.keys(), self.obj_tree.values()) |k, e| if (e.obj.kind == .module) {
        const seen = self.env(a).global(ast, k) orelse e.obj;
        try out.append(a, if (seen.kind == .module) seen else e.obj);
    };
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
    const ins = Server.lineInsertion(file, at.line);
    for (try autouse.exports(a, try usableModules(self, a, ast), .{ .prefix = prefix }, 50)) |e| {
        if (autouse.isWithin(unit, e.module)) continue;
        if (seen.contains(try std.ascii.allocLowerString(a, e.obj.name))) continue;
        if (type_mask.contains(e.obj.getType(false))) continue;
        if (req_callable and !e.obj.isCallable()) continue;
        var item = try buildComp(self, a, e.obj, self.s.autocomplete_name_only, null, false, false);
        item.detail = try a.print("{s} (use {s})", .{ item.detail, e.module.name });
        item.sortText = try std.mem.concat(a, u8, &.{ "~", e.obj.name });
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = ins.range, .newText = try std.mem.concat(a, u8, &.{ ins.prefix, try autouse.statement(a, at.indent, e.module.name, e.obj.name) }) };
        item.additionalTextEdits = edits;
        try items.append(a, item);
    }
}
