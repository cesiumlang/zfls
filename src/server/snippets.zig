//! Completion of constructs and program units at the start of a statement
//! (#264): `DO WHILE`, `SELECT CASE`, `SUBROUTINE` as snippets with their
//! end statement, the blocks of the construct that is open (`ELSE`,
//! `CASE`), `THEN` after `IF (...)`, and after `END` the end statement of
//! the scope that is open.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const table = @import("../data/constructs.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;

const srv = @import("../server.zig");
const Server = srv.Server;

pub const Items = struct {
    items: []const lsp.CompletionItem,
    /// the items are the whole answer (after `END`)
    alone: bool = false,
};

/// The items for the start of the statement that byte column `col` of
/// 0-based line `line` is in, or null when the cursor is not in its first
/// words. The statement must begin on that line.
pub fn constructItems(self: *Server, a: Allocator, file: *const FortranFile, ast: *Ast, line: usize, col: usize) !?Items {
    const text = file.getLine(line, false) orelse return null;
    const prefix = text[0..@min(col, text.len)];
    const start = statementStart(prefix, file.fixed) orelse return null;
    const words = prefix[start..];
    if (words.len == 0) return null;
    var out: std.ArrayList(lsp.CompletionItem) = .empty;
    const lower = try std.ascii.allocLowerString(a, words);
    // `END`: only the end statement of the scope that is open
    if (std.mem.startsWith(u8, lower, "end") and isWords(lower, true)) {
        const scope = ast.getInnerScope(line + 1) orelse return null;
        const end = (try endPhrase(a, self, file, scope)) orelse return null;
        if (!std.ascii.startsWithIgnoreCase(end, try collapse(a, lower))) return null;
        const shown = end;
        try out.append(a, .{
            .label = shown,
            .kind = 14,
            .detail = "end statement",
            .filterText = shown,
            .textEdit = .{ .range = Server.rangeOf(file, line, start, line, prefix.len), .newText = shown },
        });
        return .{ .items = out.items, .alone = true };
    }
    // `THEN` after the condition of an IF
    if (thenWord(lower)) |w| {
        const is_else = std.mem.startsWith(u8, lower, "else");
        const at = prefix.len - w.len;
        const snippet = if (is_else) "THEN" else "THEN\n\t$0\nEND IF";
        try out.append(a, try item(self, a, file, line, at, prefix.len, "THEN", snippet, if (is_else) "ELSE IF (...) THEN" else "IF (...) THEN ... END IF"));
        return .{ .items = out.items };
    }
    if (!isWords(lower, false)) return null;
    const typed = try collapse(a, lower);
    const where = placesAt(file, ast, line);
    for (table.all) |c| {
        const ok = switch (c.place) {
            .unit => where.unit,
            .procedure => where.procedure,
            .spec => where.spec,
            .exec => where.exec,
            .part => c.within == where.within,
        };
        if (!ok or !std.ascii.startsWithIgnoreCase(c.name, typed)) continue;
        try out.append(a, try item(self, a, file, line, start, prefix.len, c.name, c.snippet, c.detail));
    }
    if (out.items.len == 0) return null;
    return .{ .items = out.items };
}

/// A completion item replacing bytes `from`..`to` of 0-based `line` with
/// keyword `name`, or `snippet` for a client that takes snippets
fn item(self: *Server, a: Allocator, file: *const FortranFile, line: usize, from: usize, to: usize, name: []const u8, snippet: []const u8, detail: []const u8) !lsp.CompletionItem {
    const snippets = self.completion_snippets and !self.s.autocomplete_no_snippets;
    const label = try keywordCase(self, a, name);
    var new_text = label;
    if (snippets) {
        new_text = try keywordCase(self, a, snippet);
        // fixed form: no tabs
        if (file.fixed) new_text = try std.mem.replaceOwned(u8, a, new_text, "\t", "   ");
    }
    return .{
        .label = label,
        .kind = if (snippets) 15 else 14,
        .detail = try keywordCase(self, a, detail),
        .sortText = try std.mem.concat(a, u8, &.{ "0", label }),
        .filterText = label,
        .insertTextFormat = if (snippets) lsp.snippet_format else null,
        .textEdit = .{ .range = Server.rangeOf(file, line, from, line, to), .newText = new_text },
    };
}

/// Where the words of the statement begin in `prefix` (the start of a line
/// up to the cursor): after the indentation, a statement label and a
/// construct name (`outer: do`); null on a continuation line of fixed form
fn statementStart(prefix: []const u8, fixed: bool) ?usize {
    var i: usize = 0;
    if (fixed) {
        if (prefix.len < 6) return null;
        if (prefix[5] != ' ' and prefix[5] != '0') return null;
        for (prefix[0..5]) |c| if (c != ' ' and !std.ascii.isDigit(c)) return null;
        i = 6;
    } else {
        while (i < prefix.len and (prefix[i] == ' ' or prefix[i] == '\t')) i += 1;
        var j = i;
        while (j < prefix.len and std.ascii.isDigit(prefix[j])) j += 1;
        if (j > i and j < prefix.len and prefix[j] == ' ') i = j;
    }
    while (i < prefix.len and (prefix[i] == ' ' or prefix[i] == '\t')) i += 1;
    // a construct name
    var j = i;
    while (j < prefix.len and (std.ascii.isAlphanumeric(prefix[j]) or prefix[j] == '_')) j += 1;
    var k = j;
    while (k < prefix.len and prefix[k] == ' ') k += 1;
    if (j > i and k < prefix.len and prefix[k] == ':' and !(k + 1 < prefix.len and prefix[k + 1] == ':')) {
        i = k + 1;
        while (i < prefix.len and (prefix[i] == ' ' or prefix[i] == '\t')) i += 1;
    }
    return i;
}

/// Whether `s` is only letters and spaces; `names`: or names
fn isWords(s: []const u8, names: bool) bool {
    for (s) |c| {
        if (std.ascii.isAlphabetic(c) or c == ' ' or c == '\t') continue;
        if (names and (std.ascii.isDigit(c) or c == '_')) continue;
        return false;
    }
    return true;
}

/// Keyword `s` in the letter case of the settings (`lowercase_intrinsics`)
fn keywordCase(self: *const Server, a: Allocator, s: []const u8) ![]const u8 {
    return if (self.s.lowercase_intrinsics) std.ascii.allocLowerString(a, s) else s;
}

/// `s` with each run of spaces made one space
fn collapse(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        const space = c == ' ' or c == '\t';
        if (space and out.items.len > 0 and out.items[out.items.len - 1] == ' ') continue;
        try out.append(a, if (space) ' ' else c);
    }
    return out.items;
}

/// The start of THEN being written after `if (...)` or `else if (...)`
/// (lowercase `s`): that start, or null
fn thenWord(s: []const u8) ?[]const u8 {
    var rest = s;
    if (std.mem.startsWith(u8, rest, "else")) rest = std.mem.trimStart(u8, rest[4..], " ");
    if (!std.mem.startsWith(u8, rest, "if")) return null;
    rest = std.mem.trimStart(u8, rest[2..], " ");
    if (rest.len == 0 or rest[0] != '(') return null;
    var depth: usize = 0;
    const close = for (rest, 0..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) break i;
        }
    } else return null;
    const after = rest[close + 1 ..];
    const w = std.mem.trimStart(u8, after, " ");
    if (w.len == 0 or w.len == after.len or !std.mem.startsWith(u8, "then", w)) return null;
    return w;
}

const Places = struct { unit: bool = false, procedure: bool = false, spec: bool = false, exec: bool = false, within: table.Within = .none };

/// What can begin at 0-based `line`: in which part of which scope it is,
/// and the construct whose blocks (ELSE, CASE) it can begin
fn placesAt(file: *const FortranFile, ast: *Ast, line: usize) Places {
    var p: Places = .{};
    const inner = ast.getInnerScope(line + 1);
    var s = inner;
    var in_construct = false;
    while (s) |scope| : (s = scope.parent) {
        switch (scope.kind) {
            .do_, .if_, .select, .where, .associate, .block => in_construct = true,
            .module, .submodule => {
                if (afterContains(scope, line)) p.procedure = true else if (!in_construct) p.spec = true;
                break;
            },
            .program, .subroutine, .function, .scope => {
                if (afterContains(scope, line) and !in_construct) {
                    p.procedure = true;
                } else {
                    p.exec = true;
                    if (!in_construct) p.spec = true;
                }
                break;
            },
            .interface => {
                p.procedure = true;
                break;
            },
            else => break,
        }
    } else {
        p.unit = true;
        p.procedure = true;
    }
    if (in_construct) p.exec = true;
    if (inner) |scope| p.within = withinOf(file, scope);
    return p;
}

fn afterContains(scope: *const Obj, line: usize) bool {
    const cs = scope.scopeDataConst().contains_start orelse return false;
    return line + 1 > cs;
}

/// The construct whose blocks a statement directly in `scope` can begin
fn withinOf(file: *const FortranFile, scope: *const Obj) table.Within {
    return switch (scope.kind) {
        .if_ => .if_,
        .where => .where,
        .select => switch (scope.selectDataConst().select_type) {
            1 => .select_case,
            2 => if (std.ascii.findIgnoreCase(file.getLine(scope.sline -| 1, false) orelse "", "rank") != null) .select_rank else .select_type,
            3 => .select_type,
            4 => if (scope.parent) |p| withinOf(file, p) else .none,
            5 => .select_rank,
            else => .none,
        },
        else => .none,
    };
}

/// The end statement of `scope` (`END SUBROUTINE s`, `END DO`), in the
/// keyword case of the settings, or null
fn endPhrase(a: Allocator, self: *const Server, file: *const FortranFile, scope: *const Obj) !?[]const u8 {
    const word: []const u8 = switch (scope.kind) {
        .program => "PROGRAM",
        .module => "MODULE",
        .submodule => "SUBMODULE",
        .subroutine => "SUBROUTINE",
        .function => "FUNCTION",
        .type => "TYPE",
        .interface => "INTERFACE",
        .enum_ => "ENUM",
        .do_ => "DO",
        .if_ => "IF",
        .where => "WHERE",
        .associate => "ASSOCIATE",
        // a block of a SELECT ends with it
        .select => "SELECT",
        .block => if (std.ascii.findIgnoreCase(file.getLine(scope.sline -| 1, false) orelse "", "critical") != null) "CRITICAL" else "BLOCK",
        else => return null,
    };
    const named = switch (scope.kind) {
        .program, .module, .submodule, .subroutine, .function, .type, .interface => scope.name.len > 0 and std.ascii.isAlphabetic(scope.name[0]),
        else => false,
    };
    const keywords = try keywordCase(self, a, try std.mem.concat(a, u8, &.{ "END ", word }));
    if (!named) return keywords;
    return try std.mem.concat(a, u8, &.{ keywords, " ", scope.name });
}

test "the start of a statement" {
    try std.testing.expectEqual(@as(?usize, 4), statementStart("    do wh", false));
    try std.testing.expectEqual(@as(?usize, 9), statementStart("  outer: do", false));
    try std.testing.expectEqual(@as(?usize, 4), statementStart("10  do", false));
    try std.testing.expectEqual(@as(?usize, 6), statementStart("      do", true));
    try std.testing.expectEqual(@as(?usize, null), statementStart("     &do", true));
    try std.testing.expectEqualStrings("th", thenWord("if (n > 0) th").?);
    try std.testing.expectEqualStrings("t", thenWord("else if (a(1) > 0) t").?);
    try std.testing.expect(thenWord("if (n > 0)th") == null);
    try std.testing.expect(thenWord("if (n > 0) x") == null);
}
