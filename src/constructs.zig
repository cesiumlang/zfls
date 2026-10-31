//! Construct names (`outer: do ... exit outer ... end do outer`) and
//! statement labels (`10 continue`, `go to 10`, `read (*, 100)`), which the
//! parser does not keep: found in the text of the program unit around a
//! position, for go to definition, references, rename and completion
//! (fortls #424, hansec #157).

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const objects = @import("objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;

/// A name or label on a line: 0-based line, byte columns
pub const Span = struct { line: usize, start: usize, end: usize };

pub const Kind = enum { construct, label };

/// A construct name or label and where it is written
pub const Target = struct {
    kind: Kind,
    name: []const u8,
    /// where it is defined, when that is in the unit
    def: ?Span,
    /// every occurrence, the definition included
    spans: []const Span,
};

const Token = struct {
    kind: enum { word, number, punct },
    start: usize,
    end: usize,
    /// paren depth before the token
    depth: usize,
};

/// What a line holds of construct names and labels
const LineInfo = struct {
    construct_def: ?Token = null,
    /// the keyword of the construct defined (`do`, `if`, ...)
    construct_kw: []const u8 = "",
    construct_uses: std.ArrayList(Token) = .empty,
    label_def: ?Token = null,
    label_refs: std.ArrayList(Token) = .empty,
    /// the statement ends the construct named by its last word
    ends: bool = false,
};

const construct_keywords = [_][]const u8{ "do", "if", "select", "block", "associate", "where", "forall", "critical", "change" };

/// Statements that name a construct with their last word
const naming_statements = [_][]const u8{ "exit", "cycle", "else", "elseif", "elsewhere", "case", "type", "class", "rank" };

fn eqlAny(word: []const u8, list: []const []const u8) bool {
    for (list) |w| if (std.ascii.eqlIgnoreCase(word, w)) return true;
    return false;
}

/// The code of a line: strings blanked and the comment cut; null for
/// comment lines and directives
fn codeOf(a: Allocator, file: *const FortranFile, ln: usize) !?[]const u8 {
    const raw = file.getLine(ln, false) orelse return null;
    if (helpers.isComment(file.fixed, raw)) return null;
    const t = std.mem.trimStart(u8, raw, " \t");
    if (t.len > 0 and t[0] == '#') return null;
    var code = try helpers.stripStrings(a, raw, true);
    if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
    return code;
}

fn tokenize(a: Allocator, code: []const u8, from: usize) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    var depth: usize = 0;
    var i = from;
    while (i < code.len) {
        const c = code[i];
        if (c == ' ' or c == '\t') {
            i += 1;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            const s = i;
            while (i < code.len and (std.ascii.isAlphanumeric(code[i]) or code[i] == '_' or code[i] == '$')) i += 1;
            try out.append(a, .{ .kind = .word, .start = s, .end = i, .depth = depth });
        } else if (std.ascii.isDigit(c)) {
            const s = i;
            while (i < code.len and std.ascii.isDigit(code[i])) i += 1;
            // a real literal or a kind (`1.5`, `1_8`) is not a label
            if (i < code.len and (code[i] == '.' or code[i] == '_' or std.ascii.isAlphabetic(code[i]))) {
                while (i < code.len and (std.ascii.isAlphanumeric(code[i]) or code[i] == '.' or code[i] == '_')) i += 1;
                continue;
            }
            try out.append(a, .{ .kind = .number, .start = s, .end = i, .depth = depth });
        } else {
            if (c == ')') depth -|= 1;
            try out.append(a, .{ .kind = .punct, .start = i, .end = i + 1, .depth = depth });
            if (c == '(') depth += 1;
            i += 1;
        }
    }
    return out.items;
}

fn analyze(a: Allocator, code: []const u8, fixed: bool) !LineInfo {
    var info: LineInfo = .{};
    var from: usize = 0;
    if (fixed) {
        // the label field, then code from column 7
        const field = code[0..@min(code.len, 5)];
        const trimmed = std.mem.trim(u8, field, " ");
        const cont = code.len > 5 and code[5] != ' ' and code[5] != '0';
        if (trimmed.len > 0 and !cont and std.mem.indexOfNone(u8, trimmed, "0123456789") == null) {
            const s = std.mem.indexOf(u8, field, trimmed).?;
            info.label_def = .{ .kind = .number, .start = s, .end = s + trimmed.len, .depth = 0 };
        }
        from = @min(code.len, 6);
    }
    var toks = try tokenize(a, code, from);
    // ; separates statements: only the first is looked at here
    for (toks, 0..) |t, i| if (t.kind == .punct and code[t.start] == ';') {
        toks = toks[0..i];
        break;
    };
    if (!fixed and toks.len > 1 and toks[0].kind == .number) {
        info.label_def = toks[0];
        toks = toks[1..];
    }
    if (toks.len == 0) return info;
    const text = struct {
        fn of(c: []const u8, t: Token) []const u8 {
            return c[t.start..t.end];
        }
    }.of;
    // `name: do`
    var stmt = toks;
    if (toks.len >= 3 and toks[0].kind == .word and code[toks[1].start] == ':' and
        !(toks[2].kind == .punct and code[toks[2].start] == ':') and toks[2].kind == .word and
        eqlAny(text(code, toks[2]), &construct_keywords))
    {
        info.construct_def = toks[0];
        info.construct_kw = text(code, toks[2]);
        stmt = toks[2..];
    }
    // a logical IF: the statement after its condition
    if (stmt.len > 2 and std.ascii.eqlIgnoreCase(text(code, stmt[0]), "if") and stmt[1].kind == .punct and code[stmt[1].start] == '(') {
        var j: usize = 2;
        while (j < stmt.len and !(stmt[j].depth == 0 and code[stmt[j].start] == ')')) j += 1;
        // not `if (...) then`, nor the arithmetic IF `if (x) 10, 20, 30`
        if (j + 1 < stmt.len and stmt[j + 1].kind == .word and !std.ascii.eqlIgnoreCase(text(code, stmt[j + 1]), "then")) {
            stmt = stmt[j + 1 ..];
            try analyzeStatement(a, code, stmt, &info);
            try labelRefs(a, code, stmt, &info);
            return info;
        }
    }
    try analyzeStatement(a, code, stmt, &info);
    try labelRefs(a, code, stmt, &info);
    return info;
}

/// The construct names that statement `stmt` uses
fn analyzeStatement(a: Allocator, code: []const u8, stmt: []const Token, info: *LineInfo) !void {
    const text = struct {
        fn of(c: []const u8, t: Token) []const u8 {
            return c[t.start..t.end];
        }
    }.of;
    if (stmt.len == 0) return;
    const first = text(code, stmt[0]);
    // the last word at depth 0 of a statement that names a construct
    const last = stmt[stmt.len - 1];
    const second: []const u8 = if (stmt.len > 1 and stmt[1].kind == .word) text(code, stmt[1]) else "";
    // the END of a construct, not of a program unit or a type
    const ends = std.ascii.startsWithIgnoreCase(first, "end") and
        !eqlAny(first, &.{ "endfile", "endsubroutine", "endfunction", "endprogram", "endmodule", "endsubmodule", "endtype", "endinterface", "endprocedure", "endenum" }) and
        !(std.ascii.eqlIgnoreCase(first, "end") and eqlAny(second, &.{ "subroutine", "function", "program", "module", "submodule", "type", "interface", "procedure", "enum", "file" }));
    // `type is (t) name`, not `type(t) :: x`
    const names = eqlAny(first, &naming_statements) and
        (!eqlAny(first, &.{ "type", "class" }) or eqlAny(second, &.{ "is", "default" }));
    if (stmt.len >= 2 and last.kind == .word and last.depth == 0 and (ends or names)) {
        // `end do`, `else if (...) then` name nothing
        const lw = text(code, last);
        if (!(eqlAny(lw, &construct_keywords) or eqlAny(lw, &.{ "then", "default", "where", "team", "is" }))) {
            try info.construct_uses.append(a, last);
            info.ends = ends;
        }
    }
}

/// The labels a statement refers to
fn labelRefs(a: Allocator, code: []const u8, stmt: []const Token, info: *LineInfo) !void {
    const W = struct {
        fn is(c: []const u8, t: Token, w: []const u8) bool {
            return t.kind == .word and std.ascii.eqlIgnoreCase(c[t.start..t.end], w);
        }
        fn punct(c: []const u8, t: Token, p: u8) bool {
            return t.kind == .punct and c[t.start] == p;
        }
    };
    var i: usize = 0;
    while (i < stmt.len) : (i += 1) {
        const t = stmt[i];
        // go to 10, goto (10, 20) i, assign 10 to f
        const goto_len: usize = if (W.is(code, t, "goto") or W.is(code, t, "assign"))
            1
        else if (W.is(code, t, "go") and i + 1 < stmt.len and W.is(code, stmt[i + 1], "to")) 2 else 0;
        if (goto_len > 0) {
            var j = i + goto_len;
            if (j < stmt.len and stmt[j].kind == .number) {
                try info.label_refs.append(a, stmt[j]);
            } else if (j < stmt.len and W.punct(code, stmt[j], '(')) {
                j += 1;
                while (j < stmt.len and !W.punct(code, stmt[j], ')')) : (j += 1) {
                    if (stmt[j].kind == .number) try info.label_refs.append(a, stmt[j]);
                }
            }
            continue;
        }
        // err=10, end=20, eor=30, fmt=100
        if (t.kind == .word and t.depth >= 1 and eqlAny(code[t.start..t.end], &.{ "err", "end", "eor", "fmt" }) and
            i + 2 < stmt.len and W.punct(code, stmt[i + 1], '=') and stmt[i + 2].kind == .number)
        {
            try info.label_refs.append(a, stmt[i + 2]);
        }
    }
    const first = stmt[0];
    // do 10 i = 1, n
    if (W.is(code, first, "do") and stmt.len > 1 and stmt[1].kind == .number) try info.label_refs.append(a, stmt[1]);
    // print 100, x / read 100, x
    if ((W.is(code, first, "print") or W.is(code, first, "read")) and stmt.len > 1 and stmt[1].kind == .number) {
        try info.label_refs.append(a, stmt[1]);
    }
    // read (u, 100) / write (*, 100): the second item of the control list
    if ((W.is(code, first, "read") or W.is(code, first, "write")) and stmt.len > 1 and W.punct(code, stmt[1], '(')) {
        var item: usize = 0;
        var j: usize = 2;
        var item_start = j;
        while (j < stmt.len) : (j += 1) {
            const end_of_item = (stmt[j].depth == 1 and W.punct(code, stmt[j], ',')) or
                (stmt[j].depth == 0 and W.punct(code, stmt[j], ')'));
            if (!end_of_item) continue;
            if (item == 1 and j == item_start + 1 and stmt[item_start].kind == .number) {
                try info.label_refs.append(a, stmt[item_start]);
            }
            item += 1;
            item_start = j + 1;
            if (W.punct(code, stmt[j], ')')) break;
        }
    }
    // the arithmetic IF, `if (x) 10, 20, 30`
    if (W.is(code, first, "if") and stmt.len > 1 and W.punct(code, stmt[1], '(')) {
        var j: usize = 2;
        while (j < stmt.len and !(stmt[j].depth == 0 and W.punct(code, stmt[j], ')'))) j += 1;
        j += 1;
        if (j + 1 < stmt.len and stmt[j].kind == .number and W.punct(code, stmt[j + 1], ',')) {
            while (j < stmt.len) : (j += 1) {
                if (stmt[j].kind == .number) try info.label_refs.append(a, stmt[j]);
            }
        }
    }
}

/// The 0-based lines of the program unit (procedure, program, module)
/// around 0-based line `ln`; the whole file outside any
fn unitLines(file: *const FortranFile, ast: *Ast, ln: usize) struct { first: usize, last: usize } {
    var scope = ast.getInnerScope(ln + 1);
    while (scope) |s| : (scope = s.parent) {
        switch (s.kind) {
            .subroutine, .function, .program, .module, .submodule, .scope => {
                if (s.eline > s.sline) return .{ .first = s.sline - 1, .last = s.eline - 1 };
                break;
            },
            else => {},
        }
    }
    return .{ .first = 0, .last = file.nLines() -| 1 };
}

fn tokenAt(toks: []const Token, col: usize) ?Token {
    for (toks) |t| if (t.start <= col and col <= t.end) return t;
    return null;
}

/// The construct name or label at byte column `col` of 0-based line `ln`
pub fn at(a: Allocator, file: *const FortranFile, ast: *Ast, ln: usize, col: usize) !?Target {
    const code = (try codeOf(a, file, ln)) orelse return null;
    const info = try analyze(a, code, file.fixed);
    var kind: Kind = undefined;
    var name: []const u8 = undefined;
    found: {
        if (info.construct_def) |t| if (t.start <= col and col <= t.end) {
            kind = .construct;
            name = code[t.start..t.end];
            break :found;
        };
        if (tokenAt(info.construct_uses.items, col)) |t| {
            kind = .construct;
            name = code[t.start..t.end];
            break :found;
        }
        if (info.label_def) |t| if (t.start <= col and col <= t.end) {
            kind = .label;
            name = code[t.start..t.end];
            break :found;
        };
        if (tokenAt(info.label_refs.items, col)) |t| {
            kind = .label;
            name = code[t.start..t.end];
            break :found;
        }
        return null;
    }
    const unit = unitLines(file, ast, ln);
    var def: ?Span = null;
    var spans: std.ArrayList(Span) = .empty;
    var l = unit.first;
    while (l <= unit.last) : (l += 1) {
        const c = (try codeOf(a, file, l)) orelse continue;
        const li = try analyze(a, c, file.fixed);
        switch (kind) {
            .construct => {
                if (li.construct_def) |t| if (sameName(c[t.start..t.end], name, kind)) {
                    def = .{ .line = l, .start = t.start, .end = t.end };
                    try spans.append(a, def.?);
                };
                for (li.construct_uses.items) |t| if (sameName(c[t.start..t.end], name, kind)) {
                    try spans.append(a, .{ .line = l, .start = t.start, .end = t.end });
                };
            },
            .label => {
                if (li.label_def) |t| if (sameName(c[t.start..t.end], name, kind)) {
                    def = .{ .line = l, .start = t.start, .end = t.end };
                    try spans.append(a, def.?);
                };
                for (li.label_refs.items) |t| if (sameName(c[t.start..t.end], name, kind)) {
                    try spans.append(a, .{ .line = l, .start = t.start, .end = t.end });
                };
            },
        }
    }
    // a name that no construct of the unit has is something else
    if (kind == .construct and def == null) return null;
    return .{ .kind = kind, .name = name, .def = def, .spans = spans.items };
}

fn sameName(x: []const u8, y: []const u8, kind: Kind) bool {
    return switch (kind) {
        .construct => std.ascii.eqlIgnoreCase(x, y),
        // `10` and `010` are the same label
        .label => (std.fmt.parseInt(u32, x, 10) catch return false) == (std.fmt.parseInt(u32, y, 10) catch return false),
    };
}

/// The names of the constructs open at 0-based line `ln`, innermost first;
/// with `loops_only`, only DO constructs (for CYCLE)
pub fn enclosingNames(a: Allocator, file: *const FortranFile, ast: *Ast, ln: usize, loops_only: bool) ![]const []const u8 {
    const unit = unitLines(file, ast, ln);
    var open: std.ArrayList(struct { name: []const u8, loop: bool }) = .empty;
    var l = unit.first;
    while (l < ln) : (l += 1) {
        const c = (try codeOf(a, file, l)) orelse continue;
        const li = try analyze(a, c, file.fixed);
        if (li.construct_def) |t| try open.append(a, .{ .name = c[t.start..t.end], .loop = std.ascii.eqlIgnoreCase(li.construct_kw, "do") });
        if (li.ends) if (li.construct_uses.items.len > 0) {
            const t = li.construct_uses.items[0];
            const n = c[t.start..t.end];
            var k = open.items.len;
            while (k > 0) {
                k -= 1;
                if (std.ascii.eqlIgnoreCase(open.items[k].name, n)) {
                    _ = open.orderedRemove(k);
                    break;
                }
            }
        };
    }
    var out: std.ArrayList([]const u8) = .empty;
    var k = open.items.len;
    while (k > 0) {
        k -= 1;
        if (!loops_only or open.items[k].loop) try out.append(a, open.items[k].name);
    }
    return out.items;
}

test "construct names and labels on a line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const def = try analyze(a, "  outer: do i = 1, n", false);
    try std.testing.expectEqual(@as(usize, 2), def.construct_def.?.start);
    try std.testing.expectEqualStrings("do", def.construct_kw);
    const exit = try analyze(a, "      exit outer", false);
    try std.testing.expectEqual(@as(usize, 1), exit.construct_uses.items.len);
    const end = try analyze(a, "  end do outer", false);
    try std.testing.expect(end.ends);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "  end do", false)).construct_uses.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "  x = outer", false)).construct_uses.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "  case (outer)", false)).construct_uses.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "  end subroutine outer", false)).construct_uses.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "  type(t) :: outer", false)).construct_uses.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try analyze(a, "  type is (integer) outer", false)).construct_uses.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try analyze(a, "  if (x(i) < 0) cycle outer", false)).construct_uses.items.len);
    const go = try analyze(a, "  if (x > 0) go to 10", false);
    try std.testing.expectEqual(@as(usize, 1), go.label_refs.items.len);
    const io = try analyze(a, "  read (5, 100, err=20) x", false);
    try std.testing.expectEqual(@as(usize, 2), io.label_refs.items.len);
    const arith = try analyze(a, "  if (x) 10, 20, 30", false);
    try std.testing.expectEqual(@as(usize, 3), arith.label_refs.items.len);
    const labelled = try analyze(a, "100 format (i5)", false);
    try std.testing.expectEqual(@as(usize, 0), labelled.label_def.?.start);
    const fixed = try analyze(a, "   10 CONTINUE", true);
    try std.testing.expectEqual(@as(usize, 3), fixed.label_def.?.start);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "  x = 1.5 + 10", false)).label_refs.items.len);
}
