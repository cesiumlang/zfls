//! The parser of a file: walks its lines, opens and closes scopes and adds
//! the objects they define to the file's AST (port of `FortranFile.parse`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const regex = @import("../regex.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const implicit = @import("../implicit.zig");
const pp = @import("../preprocessor.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const UseStmt = objects.UseStmt;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const parser = @import("../parser.zig");
const FortranFile = parser.FortranFile;
const Trace = parser.Trace;
const Options = parser.Options;
const DefResult = @import("definitions.zig").DefResult;
const getFortranDefinition = @import("definitions.zig").getFortranDefinition;

pub fn findExternalType(file_ast: *Ast, desc_string: []const u8, name: []const u8) !bool {
    if (!std.ascii.eqlIgnoreCase(desc_string, "EXTERNAL")) return false;
    var counter: usize = 0;
    for (file_ast.variable_list.items) |v| {
        if (!std.mem.eql(u8, name, v.name) or v.parent != file_ast.current_scope) continue;
        for (file_ast.external_objs.items) |e| if (e == v) return false;
        try v.setExternalAttr();
        try file_ast.external_objs.append(file_ast.allocator(), v);
        counter += 1;
    }
    return counter == 1;
}

pub fn findExternalAttr(file_ast: *Ast, name: []const u8, new_var: *Obj) !bool {
    var counter: usize = 0;
    for (file_ast.external_objs.items) |v| {
        if (!std.mem.eql(u8, v.name, name) or v.parent != file_ast.current_scope) continue;
        if (!std.ascii.eqlIgnoreCase(v.varData().desc, "EXTERNAL")) continue;
        if (counter == 0) {
            v.varData().desc = new_var.varData().desc;
            try v.setExternalAttr();
        }
        counter += 1;
    }
    return counter == 1;
}

pub fn findExternal(file_ast: *Ast, desc_string: []const u8, name: []const u8, new_var: *Obj) !bool {
    if (try findExternalType(file_ast, desc_string, name)) return true;
    if (!std.ascii.eqlIgnoreCase(desc_string, "EXTERNAL")) {
        if (try findExternalAttr(file_ast, name, new_var)) return true;
    }
    return false;
}

pub const Counters = struct {
    do_: u32 = 0,
    if_: u32 = 0,
    block: u32 = 0,
    select: u32 = 0,
    interface: u32 = 0,
};

pub const Parser = struct {
    opts: Options,
    file: *FortranFile,
    file_ast: *Ast,
    scratch: std.heap.ArenaAllocator,
    pp_skips: []const pp.Skip = &.{},
    pp_defines: []const usize = &.{},
    docs: std.ArrayList([]const u8) = .empty,
    comment_re: *const regex.Regex = undefined,
    cur_line: usize = 0,
    doc_re: *const regex.Regex = undefined,

    pub fn dbg(p: *const Parser, comptime fmt: []const u8, args: anytype) void {
        Trace.print(p.opts.trace, fmt, args);
    }

    pub fn run(p: *Parser) !void {
        const f = p.file;
        const ast = p.file_ast;
        const sa = p.scratch.allocator();
        if (f.fixed) {
            p.comment_re = &R().FIXED_COMMENT;
            p.doc_re = &R().FIXED_DOC;
        } else {
            p.comment_re = &R().FREE_COMMENT;
            p.doc_re = &R().FREE_DOC;
        }
        const n_lines = f.nLines();
        var line_no: usize = 0;
        var line_no_end: usize = 0;
        var block_id_stack: std.ArrayList([]const u8) = .empty;
        var counters: Counters = .{};
        // stack of pending statements split by ';' (popped from the end)
        var multi_lines: std.ArrayList([]const u8) = .empty;

        // Per-line temporary arena
        var line_arena = std.heap.ArenaAllocator.init(f.gpa);
        defer line_arena.deinit();

        while (line_no_end < n_lines or multi_lines.items.len > 0) {
            if (multi_lines.items.len == 0) _ = line_arena.reset(.retain_capacity);
            const a = line_arena.allocator();
            var line: []const u8 = undefined;
            var get_full: bool = undefined;
            if (multi_lines.items.len == 0) {
                line_no = if (line_no_end > line_no) line_no_end else line_no;
                line = f.getLine(line_no, true) orelse "";
                line_no += 1;
                line_no_end = line_no;
                get_full = true;
            } else {
                line = multi_lines.pop().?;
                get_full = false;
            }
            if (line.len == 0) continue;
            // a fixed-form comment line (C, D or * in column 1) has no code,
            // whatever it contains, even a semicolon (#411)
            if (get_full and f.fixed and std.mem.indexOfScalar(u8, "cCdD*", line[0]) != null) continue;

            p.cur_line = line_no;
            if (try p.parseDocs(line, line_no)) |idx| {
                line_no = idx;
                line_no_end = line_no;
                continue;
            }
            // Handle preprocessing regions
            var do_skip = false;
            for (p.pp_skips) |reg| {
                if (line_no >= reg.start and line_no <= reg.end) {
                    do_skip = true;
                    break;
                }
            }
            for (p.pp_defines) |d| if (d == line_no) {
                do_skip = true;
            };
            if (do_skip) continue;

            if (get_full) {
                const cl = try f.getCodeLine(a, line_no -| 1, true, false, true, false);
                line_no_end += @intCast(cl.post.len);
                var parts: std.ArrayList([]const u8) = .empty;
                try parts.append(a, cl.curr.?);
                try parts.appendSlice(a, cl.post);
                line = try std.mem.concat(a, u8, parts.items);
            }
            const lr = try helpers.stripLineLabel(a, line);
            line = lr.line;
            const line_label = lr.label;
            var line_stripped = try helpers.stripStrings(a, line, true);
            var line_no_comment = line;
            if (std.mem.indexOfScalar(u8, line_stripped, '!')) |ci| {
                line_no_comment = line[0..ci];
                line_stripped = line_stripped[0..ci];
                try p.setSingleLineDocstring(line[ci..]);
            }
            if (std.mem.indexOfScalar(u8, line_stripped, ';') != null) {
                const pieces = try str.split(sa, line_stripped, ";");
                // extendleft + pop: process pieces in order
                var k: usize = pieces.len;
                var tmp: std.ArrayList([]const u8) = .empty;
                while (k > 0) {
                    k -= 1;
                    try tmp.append(sa, try sa.dupe(u8, pieces[k]));
                }
                // existing entries stay on the left (bottom) of the stack
                var merged: std.ArrayList([]const u8) = .empty;
                try merged.appendSlice(sa, multi_lines.items);
                try merged.appendSlice(sa, tmp.items);
                multi_lines = merged;
                // deque.extendleft puts pieces on the left; pop() takes from the
                // right, so existing entries are processed first. Since the
                // stack is empty here in practice, take the first piece.
                line = multi_lines.pop().?;
                line_stripped = line;
                line_no_comment = line;
            }
            // UNION and MAP in a DEC structure only overlay its fields: `END
            // MAP` ends no scope
            if (ast.current_scope) |cs| if (cs.kind == .type and R().DEC_UNION_MAP.match(line_no_comment) != null) {
                ast.pending_doc = null;
                continue;
            };
            // Test for scope end
            if (ast.end_scope_regex != null) {
                const m = R().END_WORD.match(line_no_comment);
                if (try p.parseEndScopeWord(line_no_comment, line_no, m)) {
                    ast.pending_doc = null;
                    continue;
                }
                if (try p.parseDoFixedFormat(line, line_no, line_label, &block_id_stack)) {
                    ast.pending_doc = null;
                    continue;
                }
            }
            if (try p.parseDecStructure(a, line_no_comment, line_no, &counters, &block_id_stack)) {
                ast.pending_doc = null;
                continue;
            }
            // A `!>` comment documents what follows it, not a statement that
            // cannot have documentation: it must not wait for a later
            // procedure (upstream #237)
            if (R().NON_DEF.match(line_no_comment) != null) {
                ast.pending_doc = null;
                continue;
            }
            if (try p.parseParameterStmt(a, line_no_comment)) {
                ast.pending_doc = null;
                continue;
            }
            if (try p.parseImplicit(line_no_comment, line_no)) {
                ast.pending_doc = null;
                continue;
            }
            if (try p.parseContains(line_no_comment, line_no)) {
                ast.pending_doc = null;
                continue;
            }
            const obj_read = (try getFortranDefinition(a, line)) orelse continue;
            try p.handleDef(a, obj_read, line, line_no, &counters, &block_id_stack);
        }
        try ast.closeFile(line_no);
    }

    fn handleDef(p: *Parser, a: Allocator, obj_read: DefResult, line: []const u8, line_no: usize, counters: *Counters, block_id_stack: *std.ArrayList([]const u8)) !void {
        const ast = p.file_ast;
        const pa = ast.allocator();
        switch (obj_read) {
            .var_ => |info| {
                const var_names = info.var_names orelse return;
                var procedure_def = false;
                if (std.mem.startsWith(u8, info.var_type, "PRO")) {
                    if (ast.current_scope) |cs| if (cs.getType(false) == C.TypeId.interface) {
                        for (var_names) |vn| try ast.addIntMember(vn);
                        p.dbg("{s} !!! INTERFACE-PRO - Ln:{d}", .{ str.strip(line), line_no });
                        return;
                    };
                    procedure_def = true;
                }
                for (var_names) |var_name| {
                    var desc: []const u8 = info.var_type;
                    var link_name: ?[]const u8 = null;
                    var name: []const u8 = undefined;
                    if (std.mem.indexOf(u8, var_name, "=>")) |_| {
                        const parts = try str.split(a, var_name, "=>");
                        name = parts[0];
                        const ln = str.strip(str.beforeFirst(parts[1], "("));
                        link_name = if (std.ascii.eqlIgnoreCase(ln, "null")) null else ln;
                    } else {
                        name = str.beforeFirst(var_name, "=");
                    }
                    var var_keywords: std.ArrayList([]const u8) = .empty;
                    try var_keywords.appendSlice(a, info.keywords);
                    if (std.mem.startsWith(u8, name, "(")) continue;
                    const dim = try parseImpDim(a, name);
                    name = dim.line;
                    const chr = try parseImpChar(a, name);
                    name = chr.line;
                    if (dim.extra) |d| try var_keywords.append(a, d);
                    if (chr.extra) |c| desc = try std.mem.concat(a, u8, &.{ desc, c });
                    // the codimensions of a coarray, x[:], are not part of its name (upstream #172)
                    if (std.mem.indexOfScalar(u8, name, '[')) |bracket| name = name[0..bracket];
                    name = str.strip(name);
                    const mk = try helpers.mapKeywords(a, var_keywords.items, p.opts.sort_keywords);
                    var new_var: *Obj = undefined;
                    if (procedure_def) {
                        new_var = try Obj.newMethod(ast, line_no, name, desc, mk.ids, mk.info, info.var_kind, link_name);
                    } else {
                        new_var = try Obj.newVariable(ast, line_no, name, desc, mk.ids, .{
                            .keyword_info = mk.info,
                            .kind = info.var_kind,
                            .link_obj = link_name,
                        });
                        if (new_var.isParameter()) {
                            const r = helpers.findWordInLine(line, name);
                            const col: usize = @intCast(@max(r.end, 0));
                            if (helpers.parameterValue(str.from(line, col))) |value| {
                                const words = try str.splitWhitespace(a, value);
                                new_var.varData().param_val = try pa.dupe(u8, try std.mem.join(a, " ", words));
                            }
                        }
                        if (try findExternal(ast, desc, name, new_var)) continue;
                    }
                    try ast.addVariable(new_var);
                }
                p.dbg("{s} !!! VARIABLE - Ln:{d}", .{ line, line_no });
            },
            .mod => |name| {
                const o = try Obj.newScope(ast, .module, line_no, name, &.{});
                try ast.addScope(o, &R().END_MOD, true, false);
                p.dbg("{s} !!! MODULE - Ln:{d}", .{ line, line_no });
            },
            .smod => |info| {
                const o = try Obj.newSubmodule(ast, line_no, info.name, info.ancestor, info.parent);
                try ast.addScope(o, &R().END_SMOD, true, false);
                p.dbg("{s} !!! SUBMODULE - Ln:{d}", .{ line, line_no });
            },
            .prog => |name| {
                const o = try Obj.newScope(ast, .program, line_no, name, &.{});
                try ast.addScope(o, &R().END_PROG, true, false);
                p.dbg("{s} !!! PROGRAM - Ln:{d}", .{ line, line_no });
            },
            .sub => |info| {
                const mk = try helpers.mapKeywords(a, info.keywords, p.opts.sort_keywords);
                const o = try Obj.newSubroutine(ast, line_no, info.name, info.args, info.mod_flag, mk.ids);
                try ast.addScope(o, &R().END_SUB, true, false);
                p.dbg("{s} !!! SUBROUTINE - Ln:{d}", .{ line, line_no });
            },
            .fun => |info| {
                const mk = try helpers.mapKeywords(a, info.keywords, p.opts.sort_keywords);
                const o = try Obj.newFunction(ast, line_no, info.name, .{
                    .args = info.args,
                    .mod_flag = info.mod_flag,
                    .keywords = mk.ids,
                    .keyword_info = mk.info,
                    .result_type = info.result.type,
                    .result_name = info.result.name,
                });
                try ast.addScope(o, &R().END_FUN, true, false);
                if (info.result.type) |rt| if (rt.len > 0) {
                    const rk = try helpers.mapKeywords(a, info.result.keywords, p.opts.sort_keywords);
                    const v = try Obj.newVariable(ast, line_no, info.result.name orelse info.name, rt, rk.ids, .{
                        .keyword_info = rk.info,
                        .kind = info.result.kind,
                    });
                    try ast.addVariable(v);
                };
                p.dbg("{s} !!! FUNCTION - Ln:{d}", .{ line, line_no });
            },
            .block => |name_opt| {
                var name = name_opt orelse "";
                if (name_opt == null) {
                    counters.block += 1;
                    name = try std.fmt.allocPrint(a, "#BLOCK{d}", .{counters.block});
                }
                const o = try Obj.newScope(ast, .block, line_no, name, &.{});
                try ast.addScope(o, &R().END_BLOCK, true, true);
                p.dbg("{s} !!! BLOCK - Ln:{d}", .{ line, line_no });
            },
            .block_data => |name_opt| {
                var name = name_opt orelse "";
                if (name_opt == null) {
                    counters.block += 1;
                    name = try std.fmt.allocPrint(a, "#BLOCKDATA{d}", .{counters.block});
                }
                const o = try Obj.newScope(ast, .block, line_no, name, &.{});
                try ast.addScope(o, &R().END_BLOCK_DATA, true, false);
                p.dbg("{s} !!! BLOCK DATA - Ln:{d}", .{ line, line_no });
            },
            .do_ => |label| {
                counters.do_ += 1;
                const name = try std.fmt.allocPrint(a, "#DO{d}", .{counters.do_});
                if (label.len > 0) try block_id_stack.append(p.scratch.allocator(), try p.scratch.allocator().dupe(u8, label));
                const o = try Obj.newScope(ast, .do_, line_no, name, &.{});
                try ast.addScope(o, &R().END_DO, true, true);
                p.dbg("{s} !!! DO - Ln:{d}", .{ line, line_no });
            },
            .where => |single| {
                if (!single) {
                    counters.do_ += 1;
                    const name = try std.fmt.allocPrint(a, "#WHERE{d}", .{counters.do_});
                    const o = try Obj.newScope(ast, .where, line_no, name, &.{});
                    try ast.addScope(o, &R().END_WHERE, true, true);
                }
                p.dbg("{s} !!! WHERE - Ln:{d}", .{ line, line_no });
            },
            .assoc => |bound| {
                counters.block += 1;
                const name = try std.fmt.allocPrint(a, "#ASSOC{d}", .{counters.block});
                const o = try Obj.newScope(ast, .associate, line_no, name, &.{});
                try ast.addScope(o, &R().END_ASSOCIATE, true, true);
                for (bound) |bv| {
                    const parts = try str.split(a, bv, "=>");
                    if (parts.len != 2) continue;
                    const bind_name = str.strip(parts[0]);
                    const link = str.strip(parts[1]);
                    const v = try Obj.newVariable(ast, line_no, bind_name, "UNKNOWN", &.{}, .{});
                    if (helpers.getParenSubstring(link)) |subscripts| {
                        var rank: i32 = 0;
                        for (try helpers.splitArgs(a, subscripts)) |sub| {
                            if (std.mem.indexOfScalar(u8, sub, ':') != null) rank += 1;
                        }
                        v.varData().slice_rank = rank;
                    }
                    try o.assocData().links.append(pa, .{ .var_ = v, .bind_name = try pa.dupe(u8, bind_name), .link_name = try pa.dupe(u8, link) });
                    try ast.addVariable(v);
                }
                p.dbg("{s} !!! ASSOCIATE - Ln:{d}", .{ line, line_no });
            },
            .if_ => {
                counters.if_ += 1;
                const name = try std.fmt.allocPrint(a, "#IF{d}", .{counters.if_});
                const o = try Obj.newScope(ast, .if_, line_no, name, &.{});
                try ast.addScope(o, &R().END_IF, true, true);
                p.dbg("{s} !!! IF - Ln:{d}", .{ line, line_no });
            },
            .select => |info| {
                counters.select += 1;
                const name = try std.fmt.allocPrint(a, "#SELECT{d}", .{counters.select});
                const o = try Obj.newSelect(ast, line_no, name, info);
                try ast.addScope(o, &R().END_SELECT, true, true);
                const var_desc = try std.fmt.allocPrint(a, "{s}({s})", .{ info.desc orelse "None", info.binding orelse "None" });
                if (try createSelectBindingVariable(o, ast, line_no, var_desc, info.type)) |v| try ast.addVariable(v);
                p.dbg("{s} !!! SELECT - Ln:{d}", .{ line, line_no });
            },
            .typ => |info| {
                const mk = try helpers.mapKeywords(a, info.keywords, p.opts.sort_keywords);
                const o = try Obj.newScope(ast, .type, line_no, info.name, mk.ids);
                if (info.parent) |par| o.scopeData().inherit = try pa.dupe(u8, par);
                try ast.addScope(o, &R().END_TYPED, true, true);
                p.dbg("{s} !!! TYPE - Ln:{d}", .{ line, line_no });
            },
            .enum_ => {
                counters.block += 1;
                const name = try std.fmt.allocPrint(a, "#ENUM{d}", .{counters.block});
                const o = try Obj.newScope(ast, .enum_, line_no, name, &.{});
                try ast.addScope(o, &R().END_ENUMD, true, true);
                p.dbg("{s} !!! ENUM - Ln:{d}", .{ line, line_no });
            },
            .int => |info| {
                var name = info.name orelse "";
                if (info.name == null) {
                    counters.interface += 1;
                    name = try std.fmt.allocPrint(a, "#GEN_INT{d}", .{counters.interface});
                }
                const o = try Obj.newInterface(ast, line_no, name, info.abstract);
                try ast.addScope(o, &R().END_INT, true, true);
                p.dbg("{s} !!! INTERFACE - Ln:{d}", .{ line, line_no });
            },
            .gen => |info| {
                const o = try Obj.newInterface(ast, line_no, info.bound_name, false);
                o.vis = info.vis_flag;
                try ast.addScope(o, &R().END_INT, true, true);
                for (info.pro_links) |pl| try ast.addIntMember(pl);
                try ast.endScope(line_no, true);
                p.dbg("{s} !!! GENERIC - Ln:{d}", .{ line, line_no });
            },
            .int_pro => |names| {
                if (ast.current_scope) |cs| {
                    if (cs.getType(false) == C.TypeId.interface) {
                        for (names) |nm| try ast.addIntMember(nm);
                        p.dbg("{s} !!! INTERFACE-PRO - Ln:{d}", .{ line, line_no });
                    } else if (cs.getType(false) == C.TypeId.submodule) {
                        const o = try Obj.newScope(ast, .scope, line_no, names[0], &.{});
                        try ast.addScope(o, &R().END_PRO, true, false);
                        p.dbg("{s} !!! INTERFACE-IMPL - Ln:{d}", .{ line, line_no });
                    }
                }
            },
            .use => |info| {
                const u = try UseStmt.init(pa, info.mod_name, info.only_list, info.renames);
                u.line_number = line_no;
                try ast.addUse(u);
                p.dbg("{s} !!! USE - Ln:{d}", .{ line, line_no });
            },
            .import => |info| {
                // fortls appends counters["import"], which is always 0
                const u = try UseStmt.init(pa, "#import0", info.only_list, &.{});
                u.is_import = true;
                u.import_type = info.import_type;
                u.line_number = line_no;
                try ast.addUse(u);
                p.dbg("{s} !!! IMPORT - Ln:{d}", .{ line, line_no });
            },
            .inc => |path| {
                try ast.addInclude(path, line_no);
                p.dbg("{s} !!! INCLUDE - Ln:{d}", .{ line, line_no });
            },
            .vis => |info| {
                if (ast.current_scope) |cs| {
                    if (info.obj_names.len == 0 and info.private) {
                        cs.def_vis = .private;
                    } else if (info.private) {
                        for (info.obj_names) |w| try ast.addPrivate(w);
                    } else {
                        for (info.obj_names) |w| try ast.addPublic(w);
                    }
                } else {
                    try ast.addError(.statement_without_scope, "Visibility statement without enclosing scope", C.Severity.err, line_no, 0, null);
                }
                p.dbg("{s} !!! VISIBILITY - Ln:{d}", .{ line, line_no });
            },
        }
    }

    fn parseEndScopeWord(p: *Parser, line: []const u8, ln: usize, match: ?regex.Match) !bool {
        const m = match orelse return false;
        const ast = p.file_ast;
        const cs = ast.current_scope orelse return false;
        var end_scope_word: ?[]const u8 = null;
        if (m.group(1) == null) {
            end_scope_word = "";
            if (cs.reqNamedEnd() and cs != ast.none_scope) {
                try ast.end_errors.append(ast.allocator(), .{ .end_line = ln, .scope_line = cs.sline });
            }
        } else {
            if (ast.end_scope_regex.?.match(line[m.start(1)..])) |sm| end_scope_word = sm.str();
        }
        if (end_scope_word != null) {
            if (cs.getType(false) == C.TypeId.select and cs.isTypeRegion()) try ast.endScope(ln, true);
            try ast.endScope(ln, true);
            if (p.opts.trace != null) {
                var ub: [64]u8 = undefined;
                const w = end_scope_word.?;
                const n = @min(w.len, ub.len);
                p.dbg("{s} !!! END {s} Scope - Ln:{d}", .{ line, std.ascii.upperString(ub[0..n], w[0..n]), ln });
            }
            return true;
        }
        return false;
    }

    fn parseDoFixedFormat(p: *Parser, line: []const u8, ln: usize, line_label: ?[]const u8, block_id_stack: *std.ArrayList([]const u8)) !bool {
        const ast = p.file_ast;
        const cs = ast.current_scope orelse return false;
        const label = line_label orelse return false;
        if (cs.getType(false) != C.TypeId.do_) return false;
        var did_close = false;
        while (block_id_stack.items.len > 0 and std.mem.eql(u8, label, block_id_stack.items[block_id_stack.items.len - 1])) {
            try ast.endScope(ln, true);
            _ = block_id_stack.pop();
            did_close = true;
            p.dbg("{s} !!! END DO-LABELLED - Ln:{d}", .{ line, ln });
        }
        return did_close;
    }

    /// `PARAMETER (name = value, ...)`: makes variables already declared in
    /// the current scope constants, with their values (upstream #203)
    /// DEC structures (fortls #171, hansec #230): STRUCTURE defines a
    /// derived type (a nested one with a name list also declares those
    /// fields of the structure around it), RECORD declares variables of one
    /// as TYPE(name) does, and UNION and MAP only overlay the fields of the
    /// structure around them
    fn parseDecStructure(p: *Parser, a: Allocator, line: []const u8, ln: usize, counters: *Counters, block_id_stack: *std.ArrayList([]const u8)) !bool {
        const ast = p.file_ast;
        const in_type = if (ast.current_scope) |cs| cs.kind == .type else false;
        if (R().RECORD_STMT.match(line)) |m| {
            const decl = try std.fmt.allocPrint(a, "TYPE({s}) :: {s}", .{ m.group(1).?, m.group(2) orelse "" });
            if (try getFortranDefinition(a, decl)) |def| try p.handleDef(a, def, decl, ln, counters, block_id_stack);
            p.dbg("{s} !!! RECORD - Ln:{d}", .{ line, ln });
            return true;
        }
        const m = R().STRUCTURE_DEF.match(line) orelse return false;
        // `structure fields` without a name only nests in a structure
        if (m.group(1) == null and !in_type) return false;
        var name = m.group(1) orelse "";
        if (name.len == 0) {
            counters.block += 1;
            name = try std.fmt.allocPrint(a, "#STRUCT{d}", .{counters.block});
        }
        const fields = str.strip(m.group(2) orelse "");
        if (fields.len > 0) {
            const decl = try std.fmt.allocPrint(a, "TYPE({s}) :: {s}", .{ name, fields });
            if (try getFortranDefinition(a, decl)) |def| try p.handleDef(a, def, decl, ln, counters, block_id_stack);
        }
        const o = try Obj.newScope(ast, .type, ln, name, &.{});
        o.typeData().dec_structure = true;
        try ast.addScope(o, &R().END_STRUCTURED, true, true);
        p.dbg("{s} !!! STRUCTURE - Ln:{d}", .{ line, ln });
        return true;
    }

    fn parseParameterStmt(p: *Parser, a: Allocator, line: []const u8) !bool {
        const m = R().PARAMETER_STMT.match(line) orelse return false;
        const ast = p.file_ast;
        const cs = ast.current_scope orelse return false;
        const pa = ast.allocator();
        for (try helpers.splitArgs(a, m.group(1) orelse "")) |item| {
            const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            const name = str.strip(item[0..eq]);
            for (cs.childList()) |child| {
                if (child.kind != .variable or !std.ascii.eqlIgnoreCase(child.name, name)) continue;
                if (!child.varData().is_const) {
                    child.varData().is_const = true;
                    try child.keywords.append(pa, C.KW.parameter);
                }
                const words = try str.splitWhitespace(a, str.strip(item[eq + 1 ..]));
                child.varData().param_val = try pa.dupe(u8, try std.mem.join(a, " ", words));
            }
        }
        p.dbg("{s} !!! PARAMETER statement - Ln:{d}", .{ str.strip(line), p.cur_line });
        return true;
    }

    fn parseImplicit(p: *Parser, line: []const u8, ln: usize) !bool {
        const m = R().IMPLICIT.match(line) orelse return false;
        const ast = p.file_ast;
        if (ast.current_scope) |cs| {
            cs.setImplicit(!std.ascii.eqlIgnoreCase(m.group(1).?, "none"), ln);
            // the types of the letters, for names that are not declared
            var spec = line[m.start(1)..];
            if (std.mem.indexOfScalar(u8, spec, '!')) |c| spec = spec[0..c];
            const pa = ast.allocator();
            const rules = try implicit.parseRules(pa, spec);
            if (rules.len > 0 and cs.data == .scope) {
                const sd = cs.scopeData();
                sd.implicit_rules = try std.mem.concat(pa, implicit.Rule, &.{ sd.implicit_rules, rules });
            }
        } else {
            try ast.addError(.statement_without_scope, "IMPLICIT statement without enclosing scope", C.Severity.err, ln, @intCast(m.start(1)), @intCast(m.end(1)));
        }
        p.dbg("{s} !!! IMPLICIT - Ln:{d}", .{ line, ln });
        return true;
    }

    fn parseContains(p: *Parser, line: []const u8, ln: usize) !bool {
        const m = R().CONTAINS.match(line) orelse return false;
        const ast = p.file_ast;
        var msg: ?[]const u8 = null;
        var code: C.DiagCode = .statement_without_scope;
        if (ast.current_scope) |cs| {
            cs.markContains(ln) catch {
                msg = "Multiple CONTAINS statements in scope";
                code = .multiple_contains;
            };
        } else {
            msg = "CONTAINS statement without enclosing scope";
        }
        if (msg) |mm| try ast.addError(code, mm, C.Severity.err, ln, @intCast(m.start(1)), @intCast(m.end(1)));
        p.dbg("{s} !!! CONTAINS - Ln:{d}", .{ line, ln });
        return true;
    }

    fn setSingleLineDocstring(p: *Parser, line: []const u8) !void {
        p.docs = .empty;
        const mark = helpers.docMark(false, line) orelse return;
        const doc = str.strip(line[mark + 1 ..]);
        if (doc.len > 0) try p.docs.append(p.scratch.allocator(), try p.scratch.allocator().dupe(u8, doc));
    }

    fn formatDocs(p: *Parser, docs: []const []const u8) ![]const u8 {
        const a = p.scratch.allocator();
        if (docs.len == 1) return docs[0];
        var docstr: std.ArrayList(u8) = .empty;
        var has_args = true;
        var idx_args: isize = -1;
        for (docs) |line| {
            if (std.mem.startsWith(u8, line, "@brief")) {
                try docstr.appendSlice(a, str.strip(try str.replaceFirst(a, line, "@brief", "")));
                try docstr.append(a, '\n');
            } else if (std.mem.startsWith(u8, line, "@param")) {
                if (has_args) {
                    try docstr.appendSlice(a, "\n**Parameters:**  \n");
                    has_args = false;
                    idx_args = @intCast(docstr.items.len);
                }
                try docstr.appendSlice(a, try R().DOC_PARAM.sub(a, "  \\n`\\1` - ", try std.mem.concat(a, u8, &.{ line, " " })));
            } else if (std.mem.startsWith(u8, line, "@return")) {
                try docstr.appendSlice(a, "\n**Returns:**  \n");
                try docstr.appendSlice(a, str.strip(try str.replaceFirst(a, line, "@return", "")));
                try docstr.append(a, '\n');
            } else {
                try docstr.appendSlice(a, str.strip(line));
                try docstr.append(a, '\n');
            }
        }
        if (idx_args > 0) {
            const ia: usize = @intCast(idx_args);
            const head = str.slice(docstr.items, 0, idx_args - 3);
            const tail = try str.replaceFirst(a, docstr.items[ia..], "  \n ", "");
            return std.mem.concat(a, u8, &.{ head, tail });
        }
        return docstr.items;
    }

    fn addLineComment(p: *Parser) !void {
        if (p.docs.items.len > 0) {
            const fd = try p.formatDocs(p.docs.items);
            try p.file_ast.addDoc(fd, false);
            p.dbg("{s} !!! Doc string - Line:{d}", .{ fd, p.cur_line });
            p.docs.clearRetainingCapacity();
        }
    }

    /// Parse documentation strings; returns the new line number, or null when the line is no documentation
    fn parseDocs(p: *Parser, line: []const u8, ln: usize) !?usize {
        const fixed = p.file.fixed;
        if (!helpers.isComment(fixed, line)) {
            try p.addLineComment();
            return null;
        }
        const mark = helpers.docMark(fixed, line) orelse {
            try p.addLineComment();
            return null;
        };
        const sa = p.scratch.allocator();
        // get_docstring
        try p.docs.append(sa, str.strip(line[mark + 1 ..]));
        const predocmark = line[mark] == '>';
        var new_ln = ln;
        const n = p.file.nLines();
        if (ln < n) {
            var i = ln;
            while (i < n) : (i += 1) {
                const next_line = p.file.getLine(i, true) orelse "";
                const next_mark = helpers.docMark(fixed, next_line) orelse {
                    new_ln = i;
                    break;
                };
                try p.docs.append(sa, str.strip(next_line[next_mark + 1 ..]));
            }
        }
        var total: usize = 0;
        for (p.docs.items) |d| total += d.len;
        if (total > 0) try p.file_ast.addDoc(try p.formatDocs(p.docs.items), predocmark);
        for (p.docs.items, 0..) |d, k| p.dbg("{s} !!! Doc string - Line:{d}", .{ d, ln + k });
        p.docs.clearRetainingCapacity();
        return new_ln;
    }
};

pub fn createSelectBindingVariable(self: *Obj, ast: *Ast, line_number: usize, var_desc: []const u8, case_type: i32) !?*Obj {
    const parent = self.parent orelse return null;
    if (parent.getType(false) != C.TypeId.select) return null;
    var binding_name: ?[]const u8 = null;
    var bound_var: ?[]const u8 = null;
    if (parent.isTypeBinding()) {
        binding_name = parent.selectData().binding_name;
        bound_var = parent.selectData().bound_var;
    }
    if (binding_name != null and case_type != 4) bound_var = null;
    if (binding_name) |bn| {
        return try Obj.newVariable(ast, line_number, bn, var_desc, &.{}, .{ .link_obj = bound_var });
    } else if (bound_var) |bv| {
        return try Obj.newVariable(ast, line_number, bv, var_desc, &.{}, .{});
    }
    return null;
}

pub const Split = struct { line: []const u8, extra: ?[]const u8 };

/// Parse the implicit dimension of an array e.g. var(3,4)
pub fn parseImpDim(a: Allocator, line: []const u8) !Split {
    const m = R().IMP_DIM.match(line) orelse return .{ .line = line, .extra = null };
    const i = helpers.findParenMatch(line[m.end(1)..]);
    if (i < 0) return .{ .line = line, .extra = null };
    const iu: usize = @intCast(i);
    const dims = line[m.start(1) .. m.end(1) + iu + 1];
    const rest = try std.mem.concat(a, u8, &.{ line[0..m.start(1)], line[m.end(1) + iu + 1 ..] });
    return .{ .line = rest, .extra = try std.mem.concat(a, u8, &.{ "dimension", dims }) };
}

/// Parse the implicit character length from a variable e.g. var_name*10
pub fn parseImpChar(a: Allocator, line: []const u8) !Split {
    const m = R().IMP_CHAR.match(line) orelse return .{ .line = line, .extra = null };
    const g2 = m.group(2).?;
    var char_len: []const u8 = undefined;
    if (std.mem.eql(u8, g2, "(")) {
        const i = helpers.findParenMatch(line[m.end(2)..]);
        if (i < 0) return .{ .line = line, .extra = null };
        char_len = line[m.start(2) .. m.end(2) + @as(usize, @intCast(i)) + 1];
    } else {
        char_len = g2;
    }
    return .{ .line = m.group(1).?, .extra = try std.mem.concat(a, u8, &.{ "*", char_len }) };
}
