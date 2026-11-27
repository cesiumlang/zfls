//! Hover on a parenthesis (#987): the type and rank of what it encloses, a
//! parenthesized expression or the call or element it opens, as the
//! argument checks' expression typer tells them (argcheck.zig); nothing
//! where it cannot tell.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const helpers = @import("../helpers.zig");
const parser = @import("../parser.zig");
const argcheck = @import("../argcheck.zig");
const typing = @import("../argcheck/typing.zig");

const FortranFile = parser.FortranFile;
const Value = json.Value;
const srv = @import("../server.zig");
const Server = srv.Server;

/// The hover at byte `col` of 0-based `line` of `file`, or null when it is
/// on no parenthesis of code, or the type cannot be told
pub fn hover(self: *Server, a: Allocator, file: *FortranFile, line: usize, col: usize) !?Value {
    const ast = file.ast orelse return null;
    const text = file.getLine(line, false) orelse return null;
    if (col >= text.len or helpers.isComment(file.fixed, text)) return null;
    const code = try helpers.stripStrings(a, text, true);
    if (col >= code.len or (code[col] != '(' and code[col] != ')')) return null;
    // a parenthesis right after a name is the name's hover (`f(`, `x)`)
    if (col > 0 and (std.ascii.isAlphanumeric(code[col - 1]) or code[col - 1] == '_')) return null;
    const span = enclosing(code, col) orelse return null;
    // the name before a parenthesis that opens a call or an element, with
    // the designator it is a part of (`p%a(2)`)
    var start = span[0];
    while (start > 0 and code[start - 1] == ' ') start -= 1;
    const name_end = start;
    while (start > 0 and (std.ascii.isAlphanumeric(code[start - 1]) or code[start - 1] == '_' or code[start - 1] == '%')) start -= 1;
    // a keyword's parenthesis (`if (`, `print (`) is no call
    if (start < name_end and isStatementKeyword(code[start..name_end])) start = span[0];
    if (start == name_end) start = span[0];
    const expr = text[start .. span[1] + 1];
    const t = (try argcheck.expressionType(a, self.env(a), ast, ast.getInnerScope(line + 1), expr, line + 1)) orelse return null;
    const shown = try typeText(a, t) orelse return null;
    const md = try a.print("```{s}\n{s}\n```", .{ self.s.hover_language, shown });
    return try json.from(a, lsp.Hover{ .contents = .{ .value = md } });
}

/// The parentheses of `code` that the one at `col` opens or closes, on this
/// line
fn enclosing(code: []const u8, col: usize) ?[2]usize {
    if (code[col] == '(') {
        var depth: usize = 0;
        for (code[col..], col..) |c, i| {
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) return .{ col, i };
            }
        }
        return null;
    }
    var depth: usize = 0;
    var i = col + 1;
    while (i > 0) {
        i -= 1;
        if (code[i] == ')') depth += 1;
        if (code[i] == '(') {
            depth -= 1;
            if (depth == 0) return .{ i, col };
        }
    }
    return null;
}

fn isStatementKeyword(word: []const u8) bool {
    for ([_][]const u8{ "if", "while", "print", "write", "read", "allocate", "deallocate", "select", "case", "where", "forall", "call", "return", "stop", "open", "close", "inquire", "elseif", "rank" }) |k| {
        if (std.ascii.eqlIgnoreCase(word, k)) return true;
    }
    return false;
}

/// `REAL`, `INTEGER, DIMENSION(:,:)`, `TYPE(point)`; null for none told
fn typeText(a: Allocator, t: typing.Typed) !?[]const u8 {
    const base: []const u8 = switch (t.cat) {
        .unknown => return null,
        .character => "CHARACTER",
        .derived => if (t.obj) |o| (try o.getDescNoLink(a)) else return null,
        else => if (t.kind) |k| try a.print("{s}({d})", .{ typing.typeName(t.cat), k }) else typing.typeName(t.cat),
    };
    if (!t.array or !t.rank_known or t.rank == 0) return base;
    var dims: std.ArrayList(u8) = .empty;
    for (0..t.rank) |i| try dims.appendSlice(a, if (i == 0) ":" else ",:");
    return try a.print("{s}, DIMENSION({s})", .{ base, dims.items });
}
