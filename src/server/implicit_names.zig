//! Implicitly typed variables (#849): the first use in a scope is the
//! variable's definition, and its other uses are its references, for go to
//! definition, references, highlights and rename, as for construct names
//! (constructs.zig). A use in a nested scope that does not declare the name
//! is the host's variable when the host uses it too.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const constructs = @import("../constructs.zig");
const implicit = @import("../implicit.zig");
const objects = @import("../objects.zig");
const selection = @import("../selection.zig");
const helpers = @import("../helpers.zig");
const typing = @import("../argcheck/typing.zig");
const semantic = @import("../semantic.zig");
const FortranFile = @import("../parser.zig").FortranFile;

const Obj = objects.Obj;
const Ast = objects.Ast;
const Server = @import("../server.zig").Server;

/// The implicitly typed variable at byte column `col` of 0-based `line`
pub fn at(self: *Server, a: Allocator, file: *FortranFile, ast: *Ast, line: usize, col: usize) !?constructs.Target {
    const st = selection.statementLines(file, line);
    const here = for (try semantic.unknownNames(a, self.env(a), file, ast, self.intr.funs, st.first, st.last, self.fixedLimit())) |u| {
        if (u.line == line and col >= u.start and col <= u.end and isVariable(file, u)) break u;
    } else return null;
    const scope = here.scope orelse return null;
    if (implicit.typeOf(scope, here.name) == null) return null;
    // the uses in the program unit around
    var top = scope;
    while (top.parent) |p| top = p;
    if (top.sline == 0 or file.nLines() == 0) return null;
    const first = top.sline - 1;
    const last = @min(@max(top.eline, top.sline) - 1, file.nLines() - 1);
    var uses: std.ArrayList(constructs.Span) = .empty;
    var owners: std.ArrayList(?*Obj) = .empty;
    for (try semantic.unknownNames(a, self.env(a), file, ast, self.intr.funs, first, last, self.fixedLimit())) |u| {
        if (!std.ascii.eqlIgnoreCase(u.name, here.name) or !isVariable(file, u)) continue;
        try uses.append(a, .{ .line = u.line, .start = u.start, .end = u.end });
        try owners.append(a, u.scope);
    }
    // the outermost scope around that uses the name itself
    var target = scope;
    var cur = scope.parent;
    while (cur) |p| : (cur = p.parent) {
        for (owners.items) |o| if (o == p) {
            target = p;
            break;
        };
    }
    var spans: std.ArrayList(constructs.Span) = .empty;
    for (uses.items, owners.items) |sp, o| {
        if (o != null and isWithin(o.?, target)) try spans.append(a, sp);
    }
    if (spans.items.len == 0) return null;
    std.mem.sort(constructs.Span, spans.items, {}, before);
    return .{ .kind = .implicit, .name = here.name, .def = spans.items[0], .spans = spans.items, .scope = target };
}

/// Whether the unknown name is no variable: a kind parameter, in the type
/// spec of a declaration (`complex(c_double_complex) z`) or a literal's
/// suffix (`2.0_c_double`)
fn isVariable(file: *const FortranFile, u: semantic.Unknown) bool {
    const text = file.getLine(u.line, false) orelse return true;
    if (u.start > 0 and u.start <= text.len and text[u.start - 1] == '_') return false;
    const st = selection.statementLines(file, u.line);
    if (st.first != u.line) return true;
    var it = helpers.words(text);
    const first = it.next() orelse return true;
    const types = [_][]const u8{ "integer", "real", "complex", "logical", "character", "type", "class" };
    for (types) |t| if (std.ascii.eqlIgnoreCase(first.str, t)) {
        var k = first.end;
        while (k < text.len and text[k] == ' ') k += 1;
        if (k >= text.len or text[k] != '(') return true;
        const close = typing.matching(text, k) orelse return true;
        return !(u.start > k and u.start < close);
    };
    return true;
}

fn before(_: void, x: constructs.Span, y: constructs.Span) bool {
    return x.line < y.line or (x.line == y.line and x.start < y.start);
}

fn isWithin(scope: *Obj, outer: *const Obj) bool {
    var cur: ?*Obj = scope;
    var n: usize = 0;
    while (cur) |s| : (cur = s.parent) {
        if (s == outer) return true;
        n += 1;
        if (n > 64) break;
    }
    return false;
}

/// Whether `name` is already a name in the scope of implicit variable `t`:
/// declared there or around it, or another implicitly typed variable
pub fn taken(self: *Server, a: Allocator, file: *const FortranFile, t: constructs.Target, name: []const u8) !bool {
    const scope = t.scope orelse return false;
    const lower = try std.ascii.allocLowerString(a, name);
    if (try objects.findInScope(self.env(a), scope, lower, .{})) |_| return true;
    if (self.env(a).global(scope.file_ast, lower) != null) return true;
    const ast = file.ast orelse return false;
    var top = scope;
    while (top.parent) |p| top = p;
    if (top.sline == 0 or file.nLines() == 0) return false;
    const last = @min(@max(top.eline, top.sline) - 1, file.nLines() - 1);
    for (try semantic.unknownNames(a, self.env(a), file, ast, self.intr.funs, top.sline - 1, last, self.fixedLimit())) |u| {
        if (std.ascii.eqlIgnoreCase(u.name, name)) if (u.scope) |s| if (isWithin(s, scope) or isWithin(scope, s)) return true;
    }
    return false;
}
