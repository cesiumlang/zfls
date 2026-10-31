//! Signature help and the call around a position.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const arguments = @import("../arguments.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const srv = @import("../server.zig");
const Server = srv.Server;

pub fn serveSignature(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
    const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
    const ast = file.ast orelse return .null;
    const sig_line = params.position.line;
    const sig_char = Server.toByteCol(file, sig_line, params.position.character);
    const call = (try callAt(self, a, file, ast, sig_line, sig_char)) orelse return .null;
    const vo = call.obj;
    const arg_strings = call.args;
    // a generic interface: the signature of each of its procedures, the
    // first that takes the arguments so far active (fortls #6)
    if (vo.kind == .interface and vo.memList().len > 0) {
        var sigs: std.ArrayList(lsp.SignatureInformation) = .empty;
        var active: ?i64 = null;
        var active_size: usize = std.math.maxInt(usize);
        for (vo.memList()) |member| {
            const s = (try signatureOf(self, a, member, arg_strings)) orelse continue;
            var info = s.info;
            info.activeParameter = s.param;
            if (s.fits and s.size < active_size) {
                active = @intCast(sigs.items.len);
                active_size = s.size;
            }
            try sigs.append(a, info);
        }
        if (sigs.items.len == 0) return .null;
        const chosen: usize = @intCast(active orelse 0);
        return json.from(a, lsp.SignatureHelp{
            .signatures = sigs.items,
            .activeParameter = sigs.items[chosen].activeParameter.?,
            .activeSignature = @intCast(chosen),
        });
    }
    const s = (try signatureOf(self, a, vo, arg_strings)) orelse return .null;
    return json.from(a, lsp.SignatureHelp{ .signatures = &.{s.info}, .activeParameter = s.param });
}

/// The call whose argument list holds byte column `col` of 0-based line
/// `line`: what it calls, and its arguments up to that column (the last
/// is the one being written)
pub fn callAt(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sig_line: usize, sig_char: usize) !?struct { obj: *Obj, args: []const []const u8 } {
    const cl = try file.getCodeLine(a, sig_line, false, true, false, true);
    const curr_line = cl.curr orelse return null;
    const line_prefix = (try helpers.getLinePrefix(a, cl.pre, curr_line, sig_char, true)) orelse return null;
    if (R().SCOPE_DEF.match(curr_line) != null or R().END.match(curr_line) != null) return null;
    // get_sub_name
    const pl = try helpers.getParenLevel(a, line_prefix);
    if (pl.sections[0].start <= 1) return null;
    const arg_string = str.slice(line_prefix, pl.sections[0].start, pl.sections[pl.sections.len - 1].end);
    const pl2 = try helpers.getParenLevel(a, str.slice(line_prefix, 0, pl.sections[0].start - 1));
    const sub_name_raw = str.strip(pl2.str);
    const arg_strings = try helpers.splitArgs(a, arg_string);
    const sub_end = pl2.sections[pl2.sections.len - 1].start;

    const var_stack = try helpers.getVarStack(a, sub_name_raw);
    const is_member = var_stack.len > 1;
    var curr_scope = ast.getInnerScope(sig_line + 1);
    if (is_member) curr_scope = try objects.climbTypeTree(self.env(a), var_stack, curr_scope);
    const sub_name = var_stack[var_stack.len - 1];
    var var_obj: ?*Obj = null;
    if (curr_scope) |cs| var_obj = try objects.findInScope(self.env(a), cs, sub_name, .{});
    if (var_obj == null) {
        const key = try std.ascii.allocLowerString(a, sub_name);
        if (ast.global_dict.get(key)) |o| {
            var_obj = o;
        } else if (self.obj_tree.get(key)) |e| {
            var_obj = e.obj;
        } else {
            for (self.intr.funs) |f| if (std.ascii.eqlIgnoreCase(f.name, key)) {
                var_obj = f;
                break;
            };
        }
    }
    if (var_obj == null and R().INT_STMNT.match(str.slice(line_prefix, 0, sub_end)) != null) {
        const key = try std.ascii.allocLowerString(a, sub_name);
        for (try self.intr.keywordsFor(a, 0)) |cand| if (std.ascii.eqlIgnoreCase(cand.name, key)) {
            var_obj = cand;
            break;
        };
    }
    return .{ .obj = var_obj orelse return null, .args = arg_strings };
}

/// For a call of generic interface `obj` at byte column `col` of 0-based
/// line `line`, `name(args)`: the procedure of the interface that takes
/// those arguments (their number and keywords), the one with the fewest
/// parameters if several do; null when it is no such call
pub fn genericSpecific(self: *Server, a: Allocator, file: *const FortranFile, line: usize, col: usize, obj: *Obj) !?*Obj {
    _ = self;
    if (obj.kind != .interface or obj.memList().len == 0) return null;
    const text = file.getLine(line, false) orelse return null;
    var end = @min(col, text.len);
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    const rest = str.lstrip(text[end..]);
    if (rest.len == 0 or rest[0] != '(') return null;
    var depth: usize = 0;
    var close = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const inside = str.strip(rest[1..close]);
    const args: []const []const u8 = if (inside.len == 0) &.{} else try helpers.splitArgs(a, inside);
    var best: ?*Obj = null;
    var best_size: usize = std.math.maxInt(usize);
    for (obj.memList()) |member| {
        const sig = try member.getSignature(a, null);
        if (sig.label == null or args.len > sig.params.len) continue;
        // the call gives every argument that is not OPTIONAL (else it may
        // be another procedure of that name, such as an intrinsic)
        if (member.procDataOpt()) |proc| {
            var required: usize = 0;
            for (proc.arg_objs.items) |arg| {
                if (arg) |o| {
                    if (!o.hasKeyword(C.KW.optional)) required += 1;
                } else required += 1;
            }
            if (args.len < required) continue;
        }
        const keywords_ok = for (args) |arg| {
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse continue;
            if (std.mem.indexOf(u8, arg, "==") != null or str.strip(arg[0..eq]).len == 0) continue;
            if (checkOptional(arg, sig.params) == null) break false;
        } else true;
        if (keywords_ok and sig.params.len < best_size) {
            best = member;
            best_size = sig.params.len;
        }
    }
    return best;
}

/// The signature of procedure `vo` for a call whose arguments so far are
/// `arg_strings`: the parameter they reach, whether the procedure takes
/// them (their number and keywords), and its number of parameters
pub fn signatureOf(self: *Server, a: Allocator, vo: *Obj, arg_strings: []const []const u8) !?struct { info: lsp.SignatureInformation, param: i64, fits: bool, size: usize } {
    const sig = try vo.getSignature(a, null);
    const label = sig.label orelse return null;
    const lang_fence = try std.fmt.allocPrint(a, "```{s}", .{self.s.hover_language});
    const parameters = try a.alloc(lsp.ParameterInformation, sig.params.len);
    for (sig.params, parameters) |p, *pv| {
        pv.* = .{ .label = p.label };
        if (p.doc_md) |md| pv.documentation = .{ .value = try str.replaceFirst(a, md, "```{langid}", lang_fence) };
    }
    // Find current parameter by index or by last arg with optional name
    var param_num: i64 = @as(i64, @intCast(arg_strings.len)) - 1;
    var opt_num = checkOptional(arg_strings[arg_strings.len - 1], sig.params);
    if (opt_num == null) {
        if (arg_strings.len > 1) {
            opt_num = checkOptional(arg_strings[arg_strings.len - 2], sig.params);
            if (opt_num) |o| param_num = o + 1;
        }
    } else param_num = opt_num.?;
    var info: lsp.SignatureInformation = .{ .label = label, .parameters = parameters };
    if (sig.doc) |doc| info.documentation = .{ .value = try srv.pyFormatLangid(a, doc, self.s.hover_language) };
    // it takes as many arguments, and has the keywords given
    var fits = arg_strings.len <= sig.params.len;
    for (arg_strings) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse continue;
        if (std.mem.indexOf(u8, arg, "==") != null) continue;
        if (checkOptional(arg, sig.params) == null and str.strip(arg[0..eq]).len > 0) fits = false;
    }
    return .{ .info = info, .param = param_num, .fits = fits, .size = sig.params.len };
}

pub fn checkOptional(arg: []const u8, params: []const Obj.ArgSig) ?i64 {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    const opt_arg = str.strip(arg[0..eq]);
    for (params, 0..) |p, i| {
        const lbl = str.beforeFirst(p.label, "=");
        if (std.ascii.eqlIgnoreCase(lbl, opt_arg)) return @intCast(i);
    }
    return null;
}
