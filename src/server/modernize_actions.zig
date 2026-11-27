//! The code actions of #985: the rewrites of legacy statements on the
//! lines of the range (modernize.zig), organizing the USE statements of the
//! file's program units (`source.organizeImports`, organize_use.zig), and
//! ONLY lists for the USE statements of modules zfls knows in full.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const helpers = @import("../helpers.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const modernize = @import("../modernize.zig");
const organize_use = @import("../organize_use.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const srv = @import("../server.zig");
const Server = srv.Server;
const code_actions = @import("code_actions.zig");

pub fn addActions(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, sline: usize, eline: usize, only: ?[]const []const u8, out: *std.ArrayList(lsp.CodeAction)) !void {
    if (file.nLines() == 0) return;
    const uri = try paths.pathToUri(a, file.path);
    const lines = try a.alloc([]const u8, file.nLines());
    for (lines, 0..) |*l, i| l.* = file.getLine(i, false) orelse "";
    var ln = sline;
    while (ln <= @min(eline, lines.len - 1)) : (ln += 1) {
        if (try modernize.labeledDo(a, lines, ln, file.fixed)) |r| {
            try out.append(a, try replace(a, uri, file, lines, r.first, r.last, r.lines, "Convert to DO ... END DO"));
        }
        if (try modernize.arithmeticIf(a, lines[ln], file.fixed)) |new| {
            try out.append(a, try replace(a, uri, file, lines, ln, ln, new, "Convert the arithmetic IF to an IF block"));
        }
    }
    if (!wantsOrganize(only) or file.fixed) return;
    var edits: std.ArrayList(lsp.TextEdit) = .empty;
    var only_edits: std.ArrayList(lsp.TextEdit) = .empty;
    for (ast.scope_list.items) |sc| {
        const block = (try useBlock(a, sc, lines)) orelse continue;
        const indent = block.lines[0][0 .. block.lines[0].len - std.mem.trimStart(u8, block.lines[0], " \t").len];
        const organized = try organize_use.organize(a, block.uses, indent);
        if (!same(organized, block.lines)) try edits.append(a, try edit(a, file, lines, block.first, block.last, organized));
        if (try withOnly(self, a, file, ast, sc, lines, block, indent)) |e| try only_edits.append(a, e);
    }
    if (edits.items.len > 0) try out.append(a, try code_actions.action(a, uri, "Organize USE statements", "source.organizeImports", edits.items));
    if (only_edits.items.len > 0) try out.append(a, try code_actions.action(a, uri, "Add ONLY lists to the USE statements", "source.organizeImports.only", only_edits.items));
}

/// Whether the client asks for the organizing source actions
fn wantsOrganize(only: ?[]const []const u8) bool {
    for (only orelse return false) |k| if (std.mem.startsWith(u8, "source.organizeImports", k) or std.mem.startsWith(u8, k, "source.organizeImports")) return true;
    return false;
}

fn same(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, std.mem.trimEnd(u8, q, " \r"))) return false;
    return true;
}

fn edit(a: Allocator, file: *const FortranFile, lines: []const []const u8, first: usize, last: usize, new: []const []const u8) !lsp.TextEdit {
    return .{ .range = Server.rangeOf(file, first, 0, last, lines[last].len), .newText = try std.mem.join(a, "\n", new) };
}

fn replace(a: Allocator, uri: []const u8, file: *const FortranFile, lines: []const []const u8, first: usize, last: usize, new: []const []const u8, title: []const u8) !lsp.CodeAction {
    const edits = try a.alloc(lsp.TextEdit, 1);
    edits[0] = .{ .range = Server.rangeOf(file, first, 0, last, lines[last].len), .newText = try std.mem.join(a, "\n", new) };
    return code_actions.action(a, uri, title, "refactor.rewrite", edits);
}

/// The USE statements of scope `sc`: one block of lines with nothing else
/// between them, each a plain USE statement (organize_use.zig), or null
const Block = struct { first: usize, last: usize, lines: []const []const u8, uses: []const organize_use.Use, modules: []const []const u8 };

fn useBlock(a: Allocator, sc: *Obj, lines: []const []const u8) !?Block {
    if (sc.data != .scope) return null;
    var numbers: std.ArrayList(usize) = .empty;
    for (sc.scopeDataConst().use.items) |u| {
        if (u.is_import or u.included or u.line_number == 0) continue;
        try numbers.append(a, u.line_number - 1);
    }
    if (numbers.items.len == 0) return null;
    std.mem.sort(usize, numbers.items, {}, std.sort.asc(usize));
    const first = numbers.items[0];
    const last = numbers.items[numbers.items.len - 1];
    if (last >= lines.len or last - first + 1 != numbers.items.len) return null;
    var uses: std.ArrayList(organize_use.Use) = .empty;
    var modules: std.ArrayList([]const u8) = .empty;
    for (lines[first .. last + 1]) |l| {
        const u = (try organize_use.parse(a, l)) orelse return null;
        try uses.append(a, u);
        try modules.append(a, try std.ascii.allocLowerString(a, u.module));
    }
    return .{ .first = first, .last = last, .lines = lines[first .. last + 1], .uses = uses.items, .modules = modules.items };
}

/// The block's USE statements with ONLY lists of the names the scope uses,
/// for the plain ones (`use m`) of modules zfls knows in full: of the
/// workspace, using no module, defining no operator or assignment (which
/// are used without their names), in a file of no INCLUDE or macro (which
/// could use names zfls does not see); null when none changes
fn withOnly(self: *Server, a: Allocator, file: *const FortranFile, ast: *Ast, sc: *Obj, lines: []const []const u8, block: Block, indent: []const u8) !?lsp.TextEdit {
    if (ast.include_statements.items.len > 0 or file.pp_defs.count() > 0) return null;
    const env = self.env(a);
    var changed = false;
    const new = try a.alloc(organize_use.Use, block.uses.len);
    for (block.uses, block.modules, new) |u, name, *n| {
        n.* = u;
        if (u.only != null or u.renames.len > 0) continue;
        const m = env.global(ast, name) orelse continue;
        if (m.kind != .module or m.scopeDataConst().use.items.len > 0) continue;
        const public = try m.getChildren(a, true);
        var operators = false;
        for (m.childList()) |c| {
            // an OPERATOR or ASSIGNMENT interface has no name of its own
            if (c.kind == .interface and (c.name.len == 0 or !std.ascii.isAlphabetic(c.name[0]) or std.ascii.startsWithIgnoreCase(c.name, "operator") or std.ascii.startsWithIgnoreCase(c.name, "assignment"))) operators = true;
        }
        if (operators) continue;
        var used: std.ArrayList([]const u8) = .empty;
        for (lines[sc.sline - 1 .. @min(sc.eline, lines.len)], sc.sline - 1..) |l, i| {
            if (i >= block.first and i <= block.last) continue;
            const code = try helpers.stripStrings(a, l, true);
            const cut = if (std.mem.findScalar(u8, code, '!')) |x| code[0..x] else code;
            var it = helpers.words(cut);
            while (it.next()) |w| for (public) |p| {
                if (!std.ascii.eqlIgnoreCase(p.name, w.str)) continue;
                const seen = for (used.items) |x| {
                    if (std.ascii.eqlIgnoreCase(x, p.name)) break true;
                } else false;
                if (!seen) try used.append(a, p.name);
            };
        }
        // a module none of whose names is used: left to the unused-names fix
        if (used.items.len == 0) continue;
        n.only = used.items;
        changed = true;
    }
    if (!changed) return null;
    return try edit(a, file, lines, block.first, block.last, try organize_use.organize(a, new, indent));
}
