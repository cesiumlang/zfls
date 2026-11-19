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
const docmath = @import("../docmath.zig");
const generic = @import("../argcheck/generic.zig");
const autouse = @import("../autouse.zig");

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
    // a generic interface: the signature of each of its procedures, active
    // the one the arguments so far reference by their type, kind and rank,
    // else the first that takes them (fortls #6); an intrinsic with several
    // forms: the signature of each; a derived type: the procedures of the
    // generic interface of its name and its structure constructor (hansec
    // #148)
    var forms: std.ArrayList(Obj.Signature) = .empty;
    // the procedure of each form, of a generic interface
    var form_objs: std.ArrayList(?*Obj) = .empty;
    var is_generic = vo.kind == .interface;
    switch (vo.kind) {
        .interface => {
            for (vo.memList()) |member| {
                try forms.append(a, try member.getSignature(a, null));
                try form_objs.append(a, member);
            }
            if (arguments.namesake(vo, .type)) |t| {
                if (try constructorSignature(a, ast, sig_line, t)) |s| {
                    try forms.append(a, s);
                    try form_objs.append(a, null);
                }
            }
        },
        .type => {
            is_generic = true;
            if (arguments.namesake(vo, .interface)) |g| {
                for (g.memList()) |member| {
                    try forms.append(a, try member.getSignature(a, null));
                    try form_objs.append(a, member);
                }
            }
            if (try constructorSignature(a, ast, sig_line, vo)) |s| {
                try forms.append(a, s);
                try form_objs.append(a, null);
            }
        },
        else => for (try vo.getSignatures(a)) |sg| {
            try forms.append(a, sg);
            try form_objs.append(a, null);
        },
    }
    if (forms.items.len > 1 or is_generic) {
        var sigs: std.ArrayList(lsp.SignatureInformation) = .empty;
        var members: std.ArrayList(?*Obj) = .empty;
        var candidates: std.ArrayList(*Obj) = .empty;
        var active: ?usize = null;
        var active_size: usize = std.math.maxInt(usize);
        for (forms.items, form_objs.items) |form, member| {
            const s = (try signatureFrom(self, a, form, arg_strings)) orelse continue;
            var info = s.info;
            info.activeParameter = s.param;
            // of a generic the smallest procedure, of an intrinsic its
            // first form
            if (s.fits) {
                if (member) |m| try candidates.append(a, m);
                if (active == null or (is_generic and s.size < active_size)) {
                    active = sigs.items.len;
                    active_size = s.size;
                }
            }
            try sigs.append(a, info);
            try members.append(a, member);
        }
        if (sigs.items.len == 0) return .null;
        if (candidates.items.len > 1) {
            if (try generic.resolve(a, self.env(a), ast, ast.getInnerScope(sig_line + 1), sig_line + 1, candidates.items, arg_strings)) |r| {
                active = std.mem.findScalar(?*Obj, members.items, r);
            }
        }
        const chosen = active orelse 0;
        return json.from(a, lsp.SignatureHelp{
            .signatures = sigs.items,
            .activeParameter = sigs.items[chosen].activeParameter.?,
            .activeSignature = @intCast(chosen),
        });
    }
    const s = (try signatureOf(self, a, vo, arg_strings)) orelse return .null;
    return json.from(a, lsp.SignatureHelp{ .signatures = &.{s.info}, .activeParameter = s.param });
}

/// The signature of the structure constructor of type `t` for a call at
/// 0-based `line` of `ast`: its data components, those of the type it
/// extends first, a component with a default value optional; null for an
/// abstract type, or outside the type's module when a component is private
fn constructorSignature(a: Allocator, ast: *Ast, line: usize, t: *Obj) !?Obj.Signature {
    if (t.typeDataConst().abstract) return null;
    const comps = try arguments.components(a, t);
    const module = t.parent;
    const inside = if (module) |m| (if (ast.getInnerScope(line + 1)) |s| t.file_ast == ast and autouse.isWithin(s, m) else false) else true;
    const params = try a.alloc(Obj.ArgSig, comps.len);
    var labels: std.ArrayList([]const u8) = .empty;
    for (comps, params) |c, *p| {
        const owner = c.parent orelse t;
        const private = c.vis == .private or (owner.def_vis == .private and c.vis != .public);
        if (private and !inside) return null;
        const lname = try std.ascii.allocLowerString(a, c.name);
        const label = if (hasDefault(c)) try a.print("{s}={s}", .{ lname, lname }) else lname;
        p.* = .{ .label = label, .doc_md = try c.getHoverMd(a, false, null) };
        try labels.append(a, label);
    }
    return .{
        .label = try a.print("{s}({s})", .{ t.name, try std.mem.join(a, ", ", labels.items) }),
        .doc = t.getDocumentation(),
        .params = params,
    };
}

/// Whether component `c` is declared with a default value (`= 0`,
/// `=> null()`)
fn hasDefault(c: *const Obj) bool {
    const file = c.file_ast.file orelse return false;
    const text = file.getLine(c.sline -| 1, false) orelse return false;
    const after = if (std.mem.find(u8, text, "::")) |i| text[i + 2 ..] else text;
    const r = helpers.findWordInLineIgnoreCase(after, c.name);
    if (r.end < 0) return false;
    var rest = str.lstrip(after[@intCast(r.end)..]);
    // its shape, coshape, length
    while (rest.len > 0 and (rest[0] == '(' or rest[0] == '[' or rest[0] == '*')) {
        if (rest[0] == '*') {
            rest = str.lstrip(rest[1..]);
            var n: usize = 0;
            while (n < rest.len and std.ascii.isAlphanumeric(rest[n])) n += 1;
            rest = str.lstrip(rest[n..]);
            continue;
        }
        var depth: usize = 0;
        const close = for (rest, 0..) |ch, i| {
            if (ch == '(' or ch == '[') depth += 1;
            if (ch == ')' or ch == ']') {
                depth -|= 1;
                if (depth == 0) break i;
            }
        } else return false;
        rest = str.lstrip(rest[close + 1 ..]);
    }
    return rest.len > 0 and rest[0] == '=';
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
    const open = (try argListOpen(a, line_prefix)) orelse return null;
    const arg_string = line_prefix[open + 1 ..];
    const pl2 = try helpers.getParenLevel(a, line_prefix[0..open]);
    var sub_name_raw = str.strip(pl2.str);
    // a CUDA Fortran kernel launch, `call k<<<grid, block>>>(args)`
    if (std.mem.endsWith(u8, sub_name_raw, ">>>")) {
        if (std.mem.find(u8, sub_name_raw, "<<<")) |i| sub_name_raw = str.strip(sub_name_raw[0..i]);
    }
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
        if (self.env(a).global(ast, key)) |o| {
            var_obj = o;
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
    // the caller's own declaration of a procedure it calls (#232)
    if (var_obj) |v| if (try objects.declaredProcedure(self.env(a), ast, self.workspace.values(), v, true)) |p| {
        var_obj = p;
    };
    return .{ .obj = var_obj orelse return null, .args = arg_strings };
}

/// The index in `line` of the bracket that opens the argument list the
/// end of `line` is in, or null. An array constructor (`[`, `(/`) and a
/// parenthesis that follows no name (an implied DO, an expression in
/// parentheses) are not argument lists: the search goes on outside them,
/// and they are part of the argument they are in (hansec #60).
pub fn argListOpen(a: Allocator, line: []const u8) !?usize {
    var end = line.len;
    while (true) {
        const pl = try helpers.getParenLevel(a, line[0..end]);
        if (pl.sections[0].start <= 1) return null;
        const open: usize = @intCast(pl.sections[0].start - 1);
        if (line[open] == '(' and !opensConstructor(line, open) and followsName(line[0..open])) return open;
        end = open;
    }
}

/// Whether the `(` at `i` of `line` is the `(/` of an array constructor
fn opensConstructor(line: []const u8, i: usize) bool {
    const rest = str.lstrip(line[i + 1 ..]);
    return rest.len > 0 and rest[0] == '/' and !(rest.len > 1 and rest[1] == '=');
}

/// Whether `before` ends in what a `(` after it can be the argument list
/// of: a name, a subscript or coarray subscript (`a(1)(`, `a[2](`) or a
/// CUDA kernel launch (`k<<<g, b>>>(`)
fn followsName(before: []const u8) bool {
    const t = str.rstrip(before);
    if (t.len == 0) return false;
    const c = t[t.len - 1];
    return std.ascii.isAlphanumeric(c) or c == '_' or c == ')' or c == ']' or std.mem.endsWith(u8, t, ">>>");
}

/// The specific procedure of a generic interface that a call references,
/// and whether it is the only one the call fits
pub const Specific = struct { obj: *Obj, unique: bool };

/// For a call of generic interface `obj` at byte column `col` of 0-based
/// line `line`, `name(args)`: the procedure of the interface the call
/// references, by the type, kind and rank of its arguments when they tell;
/// else the procedure that takes those arguments (their number and
/// keywords), the one with the fewest parameters if several do; null when
/// it is no such call
pub fn genericSpecific(self: *Server, a: Allocator, file: *const FortranFile, line: usize, col: usize, obj: *Obj) !?*Obj {
    const s = (try resolved(self, a, file, line, col, obj)) orelse return null;
    return s.obj;
}

/// `genericSpecific`, and whether the call fits no other procedure
pub fn resolved(self: *Server, a: Allocator, file: *const FortranFile, line: usize, col: usize, obj: *Obj) !?Specific {
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
    var candidates: std.ArrayList(*Obj) = .empty;
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
            const eq = std.mem.findScalar(u8, arg, '=') orelse continue;
            if (std.mem.find(u8, arg, "==") != null or str.strip(arg[0..eq]).len == 0) continue;
            if (checkOptional(arg, sig.params) == null) break false;
        } else true;
        if (!keywords_ok) continue;
        try candidates.append(a, member);
        if (sig.params.len < best_size) {
            best = member;
            best_size = sig.params.len;
        }
    }
    const first = best orelse return null;
    if (candidates.items.len == 1) return .{ .obj = first, .unique = true };
    const ast = file.ast orelse return .{ .obj = first, .unique = false };
    if (try generic.resolve(a, self.env(a), ast, ast.getInnerScope(line + 1), line + 1, candidates.items, args)) |r| return .{ .obj = r, .unique = true };
    return .{ .obj = first, .unique = false };
}

/// The signature of procedure `vo` for a call whose arguments so far are
/// `arg_strings`: the parameter they reach, whether the procedure takes
/// them (their number and keywords), and its number of parameters
pub fn signatureOf(self: *Server, a: Allocator, vo: *Obj, arg_strings: []const []const u8) !?SignatureFit {
    return signatureFrom(self, a, try vo.getSignature(a, null), arg_strings);
}

pub const SignatureFit = struct { info: lsp.SignatureInformation, param: i64, fits: bool, size: usize };

/// `signatureOf` for signature `sig`
fn signatureFrom(self: *Server, a: Allocator, sig: Obj.Signature, arg_strings: []const []const u8) !?SignatureFit {
    const label = sig.label orelse return null;
    const lang_fence = try a.print("```{s}", .{self.s.hover_language});
    const math = docmath.Mode.of(self.s.doc_math);
    const parameters = try a.alloc(lsp.ParameterInformation, sig.params.len);
    for (sig.params, parameters) |p, *pv| {
        pv.* = .{ .label = p.label };
        if (p.doc_md) |md| pv.documentation = .{ .value = try docmath.rewrite(a, try str.replaceFirst(a, md, "```{langid}", lang_fence), math) };
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
    if (sig.doc) |doc| info.documentation = .{ .value = try docmath.rewrite(a, try srv.pyFormatLangid(a, doc, self.s.hover_language), math) };
    // it takes as many arguments, and has the keywords given
    var fits = arg_strings.len <= sig.params.len;
    for (arg_strings) |arg| {
        const eq = std.mem.findScalar(u8, arg, '=') orelse continue;
        if (std.mem.find(u8, arg, "==") != null) continue;
        if (checkOptional(arg, sig.params) == null and str.strip(arg[0..eq]).len > 0) fits = false;
    }
    return .{ .info = info, .param = param_num, .fits = fits, .size = sig.params.len };
}

pub fn checkOptional(arg: []const u8, params: []const Obj.ArgSig) ?i64 {
    const eq = std.mem.findScalar(u8, arg, '=') orelse return null;
    const opt_arg = str.strip(arg[0..eq]);
    for (params, 0..) |p, i| {
        const lbl = str.beforeFirst(p.label, "=");
        if (std.ascii.eqlIgnoreCase(lbl, opt_arg)) return @intCast(i);
    }
    return null;
}

test "argListOpen steps out of array constructors and parentheses after no name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?usize, 6), try argListOpen(a, "call s([1, 2, "));
    try std.testing.expectEqual(@as(?usize, 6), try argListOpen(a, "call s((/ 9, "));
    try std.testing.expectEqual(@as(?usize, 6), try argListOpen(a, "call s([(i, i = 1, "));
    try std.testing.expectEqual(@as(?usize, 9), try argListOpen(a, "call s([f(1, "));
    try std.testing.expectEqual(@as(?usize, 6), try argListOpen(a, "call s(a(1), "));
    try std.testing.expectEqual(@as(?usize, 16), try argListOpen(a, "call k<<<1, 2>>>(x, "));
    try std.testing.expectEqual(@as(?usize, null), try argListOpen(a, "x = [1, 2"));
    try std.testing.expectEqual(@as(?usize, null), try argListOpen(a, "x = 1"));
}
