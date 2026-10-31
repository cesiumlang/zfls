//! Semantic tokens (`textDocument/semanticTokens/full`): what each name in
//! the code stands for, found as go to definition finds it, so that editors
//! color modules, types, procedures, dummy arguments, components and
//! variables by meaning rather than by the TextMate grammar's guess (a
//! variable named like a keyword or an intrinsic is a variable). Lines that a
//! preprocessor conditional leaves out are `comment` tokens, shown inactive.
//!
//! Intrinsic procedures are not tokens: the grammar colors them, and the
//! name of an intrinsic type in a declaration (`real(8)`) is not a call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const lsp = @import("lsp.zig");
const objects = @import("objects.zig");
const str = @import("str.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;

pub const TokenType = enum(u32) {
    namespace,
    type,
    function,
    method,
    parameter,
    property,
    variable,
    macro,
    comment,
};

pub const Modifier = enum(u5) {
    declaration,
    readonly,
};

/// The token types and modifiers, in the order of their numbers
pub const legend: lsp.SemanticTokensLegend = .{
    .tokenTypes = names(TokenType),
    .tokenModifiers = names(Modifier),
};

fn names(comptime E: type) []const []const u8 {
    const fields = std.meta.fieldNames(E);
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = f;
    const final = out;
    return &final;
}

const Token = struct {
    line: usize,
    /// UTF-16 offsets
    start: usize,
    len: usize,
    type: TokenType,
    mods: u32 = 0,
};

const Kind = struct { type: TokenType, mods: u32 = 0 };

fn bit(m: Modifier) u32 {
    return @as(u32, 1) << @backingInt(m);
}

const Tokenizer = struct {
    a: Allocator,
    env: objects.Env,
    file: *const FortranFile,
    ast: *Ast,
    /// What a name means in a scope: `{scope address}:{lowercase name}`
    cache: std.StringHashMapUnmanaged(?*Obj) = .empty,
    tokens: std.ArrayList(Token) = .empty,
    /// the last code line ended with `&` (free form)
    continued: bool = false,
    /// When set, the names that stand for nothing found are collected here
    /// (see `noteUnknown`)
    unknown: ?*std.ArrayList(Unknown) = null,
    /// the intrinsic procedures, which `lookup` leaves out
    intrinsics: []const *Obj = &.{},
    /// the statement being read declares or defines (its unknown names are
    /// attributes, kinds, letters, ...); carried over continuation lines
    spec_stmt: bool = false,
    /// the depth of parentheses at the end of the last line, for the line
    /// that continues it
    depth: usize = 0,

    /// Collect a name that stands for nothing found, unless it is a word
    /// that is no name: in a specification or END statement, after CALL
    /// (an external subroutine) or EXIT/CYCLE (a construct), a keyword
    /// inside a statement (`then`, `while`, `concurrent`, ...), an
    /// intrinsic procedure, a component
    fn noteUnknown(t: *Tokenizer, scope: ?*Obj, ln: usize, w: helpers.Word, before: u8, prev: ?[]const u8, in_end: bool) !void {
        const list = t.unknown orelse return;
        if (t.spec_stmt or in_end or before == '%') return;
        if (prev) |p| for ([_][]const u8{ "call", "exit", "cycle" }) |k| {
            if (std.ascii.eqlIgnoreCase(p, k)) return;
        };
        for (inner_keywords) |k| if (std.ascii.eqlIgnoreCase(w.str, k)) return;
        for (t.intrinsics) |f| if (std.ascii.eqlIgnoreCase(f.name, w.str)) return;
        try list.append(t.a, .{ .line = ln, .start = w.start, .end = w.end, .name = w.str, .scope = scope });
    }

    fn add(t: *Tokenizer, line: usize, text: []const u8, start: usize, end: usize, kind: Kind) !void {
        const s = str.byteToUtf16(text, start);
        try t.tokens.append(t.a, .{
            .line = line,
            .start = s,
            .len = str.byteToUtf16(text, end) - s,
            .type = kind.type,
            .mods = kind.mods,
        });
    }

    /// The object `name` stands for in `scope` (not intrinsics)
    fn lookup(t: *Tokenizer, scope: ?*Obj, name: []const u8, line_no: usize) !?*Obj {
        const lower = try std.ascii.allocLowerString(t.a, name);
        const key = try std.fmt.allocPrint(t.a, "{x}:{s}", .{ @intFromPtr(scope), lower });
        const gop = try t.cache.getOrPut(t.a, key);
        if (gop.found_existing) return gop.value_ptr.*;
        var found = try objects.findInScope(t.env, scope, lower, .{ .var_line_number = line_no });
        // in a derived type, the procedures its bindings name (`procedure
        // :: get => get_area`) and its parent type are those of the
        // enclosing scope
        if (found == null) if (scope) |s| if (s.kind == .type) {
            found = try objects.findInScope(t.env, s.parent, lower, .{ .var_line_number = line_no });
        };
        if (found == null) found = t.env.global(t.ast, lower);
        if (found) |o| if (o.kind == .intrinsic) {
            found = null;
        };
        gop.value_ptr.* = found;
        return found;
    }

    /// What kind of token a name standing for `obj` is
    fn kindOf(t: *const Tokenizer, obj: *Obj, line_no: usize) ?Kind {
        var kind: Kind = switch (obj.kind) {
            .module, .program, .submodule => .{ .type = .namespace },
            .type => .{ .type = .type },
            .subroutine, .function, .interface, .scope => .{ .type = .function },
            .method => .{ .type = .method },
            .variable => variableKind(obj),
            else => return null,
        };
        if (obj.file_ast == t.ast and obj.sline == line_no) kind.mods |= bit(.declaration);
        return kind;
    }

    fn variableKind(obj: *Obj) Kind {
        if (obj.parent) |p| {
            if (p.kind == .type) return .{ .type = .property };
            // the result of a function named after it
            if (p.kind == .function and obj.nameLowerEql(p.name)) return .{ .type = .variable };
            if (p.procDataOpt()) |proc| {
                for (proc.arg_objs.items) |arg| if (arg == obj) return .{ .type = .parameter };
            }
        }
        // a procedure pointer, or a variable declared EXTERNAL
        switch (obj.getType(false)) {
            .subroutine, .function => return .{ .type = .function },
            else => {},
        }
        return .{ .type = .variable, .mods = if (obj.varData().is_const) bit(.readonly) else 0 };
    }

    fn tokenizeLine(t: *Tokenizer, ln: usize) !void {
        const raw = t.file.getLine(ln, false) orelse return;
        if (helpers.isComment(t.file.fixed, raw)) return;
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        if (trimmed.len > 0 and trimmed[0] == '#') return;
        var code = try helpers.stripStrings(t.a, raw, true);
        if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
        const scope = t.ast.getInnerScope(ln + 1);
        var it = helpers.words(code);
        // a statement starts the line unless the line continues one
        var stmt_start = !t.continued;
        if (t.file.fixed) {
            // the label and continuation columns
            it.pos = @min(code.len, 6);
            if (code.len > 5 and code[5] != ' ' and code[5] != '0') stmt_start = false;
        } else {
            t.continued = std.mem.endsWith(u8, std.mem.trimEnd(u8, code, " \t"), "&");
            if (std.mem.startsWith(u8, trimmed, "&")) stmt_start = false;
        }
        var depth: usize = if (stmt_start) 0 else t.depth;
        defer t.depth = depth;
        var scanned: usize = it.pos;
        // a lexical token split over two lines (`inte&` / `&ger`): its
        // pieces are no names
        const split_line = !t.file.fixed and trimmed.len > 1 and trimmed[0] == '&' and trimmed[1] != ' ' and trimmed[1] != '\t';
        // IF, WHERE and FORALL with a condition: a statement follows the
        // condition (`if (x) print *, y`)
        var cond_stmt = false;
        // the keyword a statement started with, for the one after it
        // (`else if`, `end do`, `select case`)
        var keyword: ?[]const u8 = null;
        // an END statement names the unit it ends
        var in_end = false;
        // the word before, on this line
        var prev: ?[]const u8 = null;
        while (it.next()) |w| {
            for (code[scanned..w.start]) |c| switch (c) {
                '(' => depth += 1,
                ')' => {
                    depth -|= 1;
                    if (depth == 0 and cond_stmt) {
                        cond_stmt = false;
                        stmt_start = true;
                    }
                },
                ';' => {
                    stmt_start = true;
                    depth = 0;
                    in_end = false;
                    prev = null;
                },
                else => {},
            };
            scanned = w.end;
            const prev_word = prev;
            prev = w.str;
            // a component after a dot (`rec.field`, DEC) is one after `%`
            const component_dot = w.start > 0 and code[w.start - 1] == '.' and helpers.isComponentDot(code, w.start - 1);
            const before: u8 = if (component_dot) '%' else prevChar(code, w.start);
            const after = nextChar(code, w.end);
            const follows = keyword;
            keyword = null;
            if (stmt_start) {
                stmt_start = false;
                // a construct name, `outer: do`
                if (after == ':' and !startsWithOp(code, w.end, "::")) {
                    stmt_start = true;
                    continue;
                }
                if (isStatementKeyword(w.str) and !isAssignment(code, w.end)) {
                    keyword = w.str;
                    in_end = isEndKeyword(w.str);
                    t.spec_stmt = isSpecKeyword(w.str);
                    cond_stmt = isConditionKeyword(w.str);
                    continue;
                }
                t.spec_stmt = false;
            } else if (follows) |k| {
                if (isSecondKeyword(k, w.str)) {
                    // `else if (x) then`
                    if (std.ascii.eqlIgnoreCase(w.str, "if")) cond_stmt = true;
                    continue;
                }
            }
            // `.and.`, `.true.`, user operators
            if (before == '.' and after == '.') continue;
            // after the digits of a literal, or after its decimal point
            // (`0._dp`, `1.d0`)
            const after_point = w.start > 1 and code[w.start - 1] == '.' and std.ascii.isDigit(code[w.start - 2]);
            if (after_point or w.start > 0 and (std.ascii.isDigit(code[w.start - 1]) or code[w.start - 1] == '\'' or code[w.start - 1] == '"')) {
                // the kind of a literal: `1.0_dp`, `'text'_ck`; not the
                // exponent of `1.0d0`
                if (w.str[0] != '_' or w.str.len < 2) continue;
                if (try t.lookup(scope, w.str[1..], ln + 1)) |o| {
                    if (t.kindOf(o, ln + 1)) |k| try t.add(ln, raw, w.start + 1, w.end, k);
                }
                continue;
            }
            // a keyword argument, `f(x, kind=dp)`: a dummy argument of what
            // is called, not a name of this scope (also first on a line
            // that continues the call)
            const in_list = before == '(' or before == ',' or before == '&' or before == 0;
            if (depth > 0 and after == '=' and !startsWithOp(code, w.end, "==") and !startsWithOp(code, w.end, "=>") and in_list) continue;
            if (t.file.pp_defs.contains(w.str)) {
                try t.add(ln, raw, w.start, w.end, .{ .type = .macro });
                continue;
            }
            var obj = if (before == '%')
                try t.member(scope, code[0..w.end], w.str)
            else
                try t.lookup(scope, w.str, ln + 1);
            // on its FUNCTION statement, the name of a function is the
            // function, not its result
            if (obj) |o| if (o.kind == .variable) if (o.parent) |p| {
                if (p.kind == .function and p.sline == ln + 1 and o.nameLowerEql(p.name)) obj = p;
            };
            const o = obj orelse {
                // a name that ASSOCIATE or SELECT TYPE defines (`this =>
                // self`), or a piece of a token split over two lines
                const defines = depth > 0 and startsWithOp(code, w.end, "=>") and in_list;
                const split = split_line or w.end < code.len and code[w.end] == '&';
                // the kind of a character literal, `ck_'text'`
                const kind_prefix = w.str[w.str.len - 1] == '_' and w.end < code.len and (code[w.end] == '\'' or code[w.end] == '"');
                if (!defines and !split and !kind_prefix) try t.noteUnknown(scope, ln, w, before, prev_word, in_end);
                continue;
            };
            // elsewhere in a function, its name is its result
            if (o.kind == .function and o == scope and o.sline != ln + 1 and !in_end) {
                try t.add(ln, raw, w.start, w.end, .{ .type = .variable });
                continue;
            }
            if (t.kindOf(o, ln + 1)) |k| try t.add(ln, raw, w.start, w.end, k);
        }
    }

    /// The component or binding `name` of the object that `prefix` (the
    /// line up to the name) ends with, `a%b%name`
    fn member(t: *Tokenizer, scope: ?*Obj, prefix: []const u8, name: []const u8) !?*Obj {
        const line_prefix = (try helpers.getLinePrefix(t.a, &.{}, prefix, prefix.len, false)) orelse return null;
        const var_stack = try helpers.getVarStack(t.a, line_prefix);
        if (var_stack.len < 2) return null;
        const type_scope = (try objects.climbTypeTree(t.env, var_stack, scope)) orelse return null;
        const lower = try std.ascii.allocLowerString(t.a, name);
        return objects.findInScope(t.env, type_scope, lower, .{});
    }

    /// The lines between the directives of each preprocessor branch that is
    /// left out
    fn inactiveLines(t: *Tokenizer, inactive: []bool) !void {
        for (t.file.pp_skips) |sk| {
            // 1-based, from the directive that starts the branch to the one
            // that ends it
            var ln = sk.start;
            while (ln + 1 < sk.end) : (ln += 1) {
                if (ln >= inactive.len) break;
                inactive[ln] = true;
                const text = t.file.getLine(ln, false) orelse continue;
                if (text.len == 0) continue;
                try t.add(ln, text, 0, text.len, .{ .type = .comment });
            }
        }
    }
};

/// The words that start a statement (when it does not assign to a variable
/// of that name)
const statement_keywords = [_][]const u8{
    "abstract",        "allocatable",   "allocate",    "associate",       "asynchronous",
    "backspace",       "bind",          "block",       "call",            "case",
    "character",       "class",         "close",       "codimension",     "common",
    "complex",         "contains",      "contiguous",  "continue",        "critical",
    "cycle",           "data",          "deallocate",  "default",         "dimension",
    "do",              "double",        "elemental",   "else",            "elseif",
    "elsewhere",       "end",           "enddo",       "endif",           "entry",
    "enum",            "enumerator",    "equivalence", "error",           "exit",
    "external",        "final",         "flush",       "forall",          "format",
    "function",        "generic",       "go",          "goto",            "if",
    "implicit",        "import",        "impure",      "include",         "inquire",
    "integer",         "intent",        "interface",   "intrinsic",       "lock",
    "logical",         "module",        "namelist",    "non_overridable", "nullify",
    "open",            "optional",      "parameter",   "pause",           "pointer",
    "print",           "private",       "procedure",   "program",         "protected",
    "public",          "pure",          "rank",        "read",            "real",
    "recursive",       "return",        "rewind",      "save",            "select",
    "sequence",        "stop",          "submodule",   "subroutine",      "sync",
    "target",          "type",          "unlock",      "use",             "value",
    "volatile",        "wait",          "where",       "write",
    // written as one word
              "blockdata",
    "doubleprecision", "doublecomplex", "selectcase",  "selecttype",      "selectrank",
    "errorstop",       "syncall",       "syncimages",  "syncmemory",      "endfile",
    // DEC structures
    "structure",       "record",        "union",       "map",
    // CUDA Fortran
                "attributes",
};

/// The statement keywords that start a specification or a definition, whose
/// other words need not be names of the scope (attributes, kinds, the
/// letters of IMPLICIT, names being defined)
const spec_keywords = [_][]const u8{
    "abstract",    "allocatable", "asynchronous", "bind",            "character",     "class",
    "codimension", "common",      "complex",      "contains",        "contiguous",    "data",
    "dimension",   "double",      "elemental",    "entry",           "enum",          "enumerator",
    "equivalence", "external",    "final",        "format",          "function",      "generic",
    "implicit",    "import",      "impure",       "include",         "integer",       "intent",
    "interface",   "intrinsic",   "logical",      "module",          "namelist",      "non_overridable",
    "optional",    "parameter",   "pointer",      "private",         "procedure",     "program",
    "protected",   "public",      "pure",         "real",            "recursive",     "save",
    "sequence",    "submodule",   "subroutine",   "target",          "type",          "use",
    "value",       "volatile",    "blockdata",    "doubleprecision", "doublecomplex", "structure",
    "record",      "union",       "map",          "attributes",
};

fn isSpecKeyword(word: []const u8) bool {
    for (spec_keywords) |k| if (std.ascii.eqlIgnoreCase(word, k)) return true;
    return false;
}

/// Keywords that appear inside executable statements, never names there
const inner_keywords = [_][]const u8{
    "then",    "while",  "concurrent", "to",         "default", "is",      "none",
    "only",    "result", "local",      "local_init", "shared",  "reduce",  "all",
    "images",  "memory", "team",       "integer",    "real",    "logical", "character",
    "complex", "double", "precision",  "type",       "class",
};

/// A name in the code that stands for nothing found
pub const Unknown = struct { line: usize, start: usize, end: usize, name: []const u8, scope: ?*Obj };

/// The names on 0-based lines `first`..`last` (a statement, or the file)
/// that stand for nothing the scope, its USE statements or the workspace
/// define, and are no keyword, intrinsic procedure or component
pub fn unknownNames(a: Allocator, env: objects.Env, file: *const FortranFile, ast: *Ast, intrinsics: []const *Obj, first: usize, last: usize) ![]const Unknown {
    var list: std.ArrayList(Unknown) = .empty;
    var t: Tokenizer = .{ .a = a, .env = env, .file = file, .ast = ast, .unknown = &list, .intrinsics = intrinsics };
    const n = file.nLines();
    if (n == 0) return list.items;
    const inactive = try a.alloc(bool, n);
    @memset(inactive, false);
    try t.inactiveLines(inactive);
    var ln = first;
    while (ln <= @min(last, n - 1)) : (ln += 1) if (!inactive[ln]) try t.tokenizeLine(ln);
    return list.items;
}

fn isStatementKeyword(word: []const u8) bool {
    for (statement_keywords) |k| if (std.ascii.eqlIgnoreCase(word, k)) return true;
    // END joined to what it ends: `endenum`, `endmodule`, `endselect`
    return word.len > 3 and std.ascii.startsWithIgnoreCase(word, "end") and isStatementKeyword(word[3..]);
}

/// Whether `word` starts an END statement (`end`, `endmodule`, ...)
fn isEndKeyword(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, "end") or (word.len > 3 and std.ascii.startsWithIgnoreCase(word, "end") and isStatementKeyword(word[3..]));
}

/// The statements whose condition may be followed by another statement
fn isConditionKeyword(word: []const u8) bool {
    for ([_][]const u8{ "if", "where", "forall" }) |k| if (std.ascii.eqlIgnoreCase(word, k)) return true;
    return false;
}

/// Whether `word` is the second word of a statement that `first` started:
/// `else if`, `end do`, `select case`, `type is`, `go to`, ...
fn isSecondKeyword(first: []const u8, word: []const u8) bool {
    const pairs = [_][2][]const u8{
        .{ "else", "if" },          .{ "else", "where" },      .{ "select", "case" },
        .{ "select", "type" },      .{ "select", "rank" },     .{ "type", "is" },
        .{ "class", "is" },         .{ "class", "default" },   .{ "case", "default" },
        .{ "rank", "default" },     .{ "go", "to" },           .{ "double", "precision" },
        .{ "double", "complex" },   .{ "block", "data" },      .{ "sync", "all" },
        .{ "sync", "images" },      .{ "sync", "memory" },     .{ "error", "stop" },
        .{ "module", "procedure" }, .{ "module", "function" }, .{ "module", "subroutine" },
    };
    for (pairs) |p| if (std.ascii.eqlIgnoreCase(first, p[0]) and std.ascii.eqlIgnoreCase(word, p[1])) return true;
    if (std.ascii.eqlIgnoreCase(first, "end")) return isStatementKeyword(word) or std.ascii.eqlIgnoreCase(word, "team");
    return false;
}

/// Whether the text after a name at `end` assigns to it: `x = `, `x(i) =`,
/// `x%c =`, `x => ` (not `x == `)
fn isAssignment(code: []const u8, end: usize) bool {
    var j = end;
    while (j < code.len and code[j] == ' ') j += 1;
    if (j < code.len and code[j] == '(') {
        var d: usize = 0;
        while (j < code.len) : (j += 1) {
            if (code[j] == '(') d += 1;
            if (code[j] == ')') {
                d -= 1;
                if (d == 0) break;
            }
        }
        j += 1;
        while (j < code.len and code[j] == ' ') j += 1;
    }
    if (j >= code.len) return false;
    if (code[j] == '%') return true;
    return code[j] == '=' and !(j + 1 < code.len and code[j + 1] == '=');
}

/// Whether the text after `end` starts with operator `op`
fn startsWithOp(code: []const u8, end: usize, op: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, code[end..], " "), op);
}

fn prevChar(code: []const u8, i: usize) u8 {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (code[j] != ' ' and code[j] != '\t') return code[j];
    }
    return 0;
}

fn nextChar(code: []const u8, i: usize) u8 {
    var j = i;
    while (j < code.len) : (j += 1) {
        if (code[j] != ' ' and code[j] != '\t') return code[j];
    }
    return 0;
}

/// The semantic tokens of a file, encoded as LSP sends them: per token the
/// line and start relative to the previous token, its length, type and
/// modifiers
pub fn tokens(a: Allocator, env: objects.Env, file: *const FortranFile, ast: *Ast) ![]const u32 {
    var t: Tokenizer = .{ .a = a, .env = env, .file = file, .ast = ast };
    const n = file.nLines();
    const inactive = try a.alloc(bool, n);
    @memset(inactive, false);
    try t.inactiveLines(inactive);
    for (0..n) |ln| if (!inactive[ln]) try t.tokenizeLine(ln);
    const toks = t.tokens.items;
    std.mem.sort(Token, toks, {}, struct {
        fn lt(_: void, x: Token, y: Token) bool {
            return x.line < y.line or (x.line == y.line and x.start < y.start);
        }
    }.lt);
    var data = try a.alloc(u32, toks.len * 5);
    var prev_line: usize = 0;
    var prev_start: usize = 0;
    for (toks, 0..) |tok, i| {
        const dl = tok.line - prev_line;
        data[i * 5 + 0] = @intCast(dl);
        data[i * 5 + 1] = @intCast(if (dl == 0) tok.start - prev_start else tok.start);
        data[i * 5 + 2] = @intCast(tok.len);
        data[i * 5 + 3] = @backingInt(tok.type);
        data[i * 5 + 4] = tok.mods;
        prev_line = tok.line;
        prev_start = tok.start;
    }
    return data;
}

test "the legend lists the token types in the order of their numbers" {
    try std.testing.expectEqualStrings("namespace", legend.tokenTypes[@backingInt(TokenType.namespace)]);
    try std.testing.expectEqualStrings("comment", legend.tokenTypes[@backingInt(TokenType.comment)]);
    try std.testing.expectEqualStrings("readonly", legend.tokenModifiers[@backingInt(Modifier.readonly)]);
}
