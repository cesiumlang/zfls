//! zfls's own formatter (#986, `formatter = "zfls"`): free-form files
//! indented by the parser's scopes, with no tool to install. Each statement
//! at its depth (one level per scope it is in: program units, procedures,
//! derived types, interfaces and constructs); ELSE, CASE, CONTAINS and the
//! like at their construct's; continuation lines one level further. The
//! lines of a preprocessor and the rest of a character literal stay as they
//! are, and only the blanks around a line's text change (indent.zig).
//! The width is `formatter_args`' `--indent N` (fprettify's), else 3; and
//! `--case upper`, `lower` or `title` writes the keywords so (as the
//! keyword case actions do).
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const indent_text = @import("../indent.zig");
const rewrite = @import("../rewrite.zig");
const semantic = @import("../semantic.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const srv = @import("../server.zig");
const Server = srv.Server;
const code_actions = @import("code_actions.zig");

pub const default_width = 3;

/// The width of a level: `--indent N` or `--indent=N` in `args`
pub fn width(args: []const []const u8) usize {
    for (args, 0..) |arg, i| {
        const value = if (std.mem.startsWith(u8, arg, "--indent=")) arg["--indent=".len..] else if (std.mem.eql(u8, arg, "--indent") and i + 1 < args.len) args[i + 1] else continue;
        return std.fmt.parseInt(usize, value, 10) catch continue;
    }
    return default_width;
}

/// The case of the keywords: `--case upper`, `lower` or `title` in `args`
pub fn caseOf(args: []const []const u8) ?rewrite.Case {
    for (args, 0..) |arg, i| {
        const value = if (std.mem.startsWith(u8, arg, "--case=")) arg["--case=".len..] else if (std.mem.eql(u8, arg, "--case") and i + 1 < args.len) args[i + 1] else continue;
        return std.meta.stringToEnum(rewrite.Case, value);
    }
    return null;
}

/// The whole free-form `file` formatted (its editor's lines) with the
/// formatter's `args`, or null for a file without an AST or in fixed form
pub fn formatLines(self: *Server, a: Allocator, file: *FortranFile, args: []const []const u8) !?[]const []const u8 {
    if (file.fixed) return null;
    const ast = file.ast orelse return null;
    var lines = file.editLines();
    if (caseOf(args)) |case| {
        const cased = try a.dupe([]const u8, lines);
        const names = try semantic.namePositions(a, self.env(a), file, ast);
        const changes = try code_actions.keywordChanges(a, file, names, case);
        // the last first, so that a line's earlier places stay where they are
        var i = changes.len;
        while (i > 0) {
            i -= 1;
            const c = changes[i];
            const l = cased[c.line];
            if (c.end > l.len or !std.ascii.eqlIgnoreCase(l[c.start..c.end], c.text)) continue;
            cased[c.line] = try std.mem.concat(a, u8, &.{ l[0..c.start], c.text, l[c.end..] });
        }
        lines = cased;
    }
    return try indent_text.indent(a, lines, try depths(a, ast, lines), width(args));
}

/// Each line's depth, or null for a line to leave as it is
fn depths(a: Allocator, ast: *objects.Ast, lines: []const []const u8) ![]const ?usize {
    const n = lines.len;
    const inside = try a.alloc(usize, n);
    @memset(inside, 0);
    for (ast.scope_list.items) |sc| {
        if (sc == ast.none_scope or sc.file_ast != ast or sc.kind == .include or sc.sline == 0 or sc.eline <= sc.sline) continue;
        // the lines after its first statement's, before its END's
        var l = sc.sline;
        while (l + 1 < sc.eline and l < n) : (l += 1) inside[l] += 1;
    }
    const out = try a.alloc(?usize, n);
    var quote: u8 = 0;
    var continues = false;
    var start_depth: usize = 0;
    for (lines, 0..) |line, i| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len > 0 and text[0] == '#') {
            out[i] = null;
            continue;
        }
        if (continues) {
            // the rest of a character literal: its blanks are its own
            const lead = std.mem.trimStart(u8, line, " \t");
            out[i] = if (quote != 0 and (lead.len == 0 or lead[0] != '&')) null else start_depth + 1;
        } else if (text.len > 0 and text[0] == '!') {
            out[i] = inside[i];
        } else {
            start_depth = inside[i] -| @intFromBool(middle(ast, text, i));
            out[i] = start_depth;
        }
        if (text.len == 0 or text[0] == '!') continue;
        quote = indent_text.endQuote(line, if (continues) quote else 0);
        continues = endsWithAmpersand(line, quote);
    }
    return out;
}

/// Whether a free-form line goes on to the next: an `&` that ends its code
fn endsWithAmpersand(line: []const u8, quote: u8) bool {
    if (quote != 0) return true;
    var q: u8 = 0;
    var last: u8 = 0;
    for (line) |c| {
        if (q != 0) {
            if (c == q) q = 0;
            last = c;
            continue;
        }
        if (c == '\'' or c == '"') q = c else if (c == '!') break;
        if (c != ' ' and c != '\t' and c != '\r') last = c;
    }
    return last == '&';
}

/// Whether the statement `text` of line `i` (0-based) is one in the middle
/// of the construct or unit it is in, at that construct's depth: ELSE of an
/// IF, ELSEWHERE of a WHERE, CASE and the like of a SELECT, CONTAINS
fn middle(ast: *objects.Ast, text: []const u8, i: usize) bool {
    const scope = ast.getInnerScope(i + 1) orelse return false;
    var t = text;
    // a statement's label
    var e: usize = 0;
    while (e < t.len and std.ascii.isDigit(t[e])) e += 1;
    if (e > 0) t = std.mem.trimStart(u8, t[e..], " \t");
    var buf: [24]u8 = undefined;
    const head = std.ascii.lowerString(buf[0..@min(buf.len, t.len)], t[0..@min(buf.len, t.len)]);
    return switch (scope.kind) {
        .if_ => startsWord(head, "else"),
        .where => startsWord(head, "elsewhere") or startsWord(head, "else"),
        .select => startsWord(head, "case") or std.mem.startsWith(u8, head, "class is") or std.mem.startsWith(u8, head, "class default") or std.mem.startsWith(u8, head, "type is") or startsWord(head, "rank"),
        .module, .submodule, .program, .subroutine, .function, .type => std.mem.eql(u8, std.mem.trimEnd(u8, head, " "), "contains"),
        else => false,
    };
}

/// Whether `head` starts with the keyword `word`, not with a longer name
/// (`else`, `elseif`, `else if`; not `elsewise = 1`)
fn startsWord(head: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, head, word)) return false;
    if (head.len == word.len) return true;
    const next = head[word.len];
    if (next == ' ' or next == '(' or next == '\t') return !assignment(head[word.len..]);
    // `elseif`, `elsewhere`
    return std.mem.eql(u8, word, "else") and (std.mem.startsWith(u8, head[word.len..], "if") or std.mem.startsWith(u8, head[word.len..], "where"));
}

/// Whether the rest after a keyword makes the statement an assignment to
/// a name like it (`case = 1`, `rank (2) = 1` stays a CASE's look-alike)
fn assignment(rest: []const u8) bool {
    const t = std.mem.trimStart(u8, rest, " \t");
    return t.len > 0 and t[0] == '=' and !(t.len > 1 and t[1] == '=');
}

test "the width of --indent (#986)" {
    try std.testing.expectEqual(@as(usize, 4), width(&.{"--indent=4"}));
    try std.testing.expectEqual(@as(usize, 2), width(&.{ "--indent", "2" }));
    try std.testing.expectEqual(@as(usize, 3), width(&.{}));
}
