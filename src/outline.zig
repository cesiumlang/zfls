//! The structure of a file for the editor: its outline as a tree of symbols
//! (`textDocument/documentSymbol` for clients with
//! `hierarchicalDocumentSymbolSupport`; others get fortls's flat list) and
//! its folding ranges (`textDocument/foldingRange`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const lsp = @import("lsp.zig");
const objects = @import("objects.zig");
const str = @import("str.zig");
const C = @import("constants.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;

/// LSP `SymbolKind`s
const Kind = struct {
    const file: i64 = 1;
    const module: i64 = 2;
    const class: i64 = 5;
    const method: i64 = 6;
    const field: i64 = 8;
    const interface: i64 = 11;
    const function: i64 = 12;
    const variable: i64 = 13;
    const constant: i64 = 14;
};

/// The `SymbolKind` of an object in fortls's flat symbol list
pub fn flatKind(t: C.TypeId, in_class: bool) i64 {
    return switch (t) {
        .module, .submodule => Kind.module,
        .subroutine, .function => if (in_class) Kind.method else Kind.function,
        .class => Kind.class,
        .interface => Kind.interface,
        .variable => Kind.variable,
        .method => Kind.method,
        else => Kind.file,
    };
}

// --------------------------------------------------------------------------
// Symbols

const Outline = struct {
    a: Allocator,
    file: *const FortranFile,
    /// leave out the components and bindings of derived types
    /// (`--symbol_skip_mem`)
    skip_members: bool,

    /// The range of lines `sline` to `eline` (1-based; `eline` 0: one line),
    /// whole
    fn lines(o: Outline, sline: usize, eline: usize) lsp.Range {
        const first = sline -| 1;
        const last = @max(first, eline -| 1);
        const text = o.file.getLine(last, false) orelse "";
        return .{
            .start = .{ .line = first, .character = 0 },
            .end = .{ .line = last, .character = str.byteToUtf16(text, text.len) },
        };
    }

    /// The name of `obj` on its first line; the start of the line when it
    /// is not there (a preprocessor macro, a continuation)
    fn nameRange(o: Outline, obj: *const Obj) lsp.Range {
        const ln = obj.sline -| 1;
        const text = o.file.getLine(ln, false) orelse "";
        const w = helpers.findWordInLineIgnoreCase(text, obj.name);
        if (w.start < 0) return .{ .start = .{ .line = ln, .character = 0 }, .end = .{ .line = ln, .character = 0 } };
        return .{
            .start = .{ .line = ln, .character = str.byteToUtf16(text, @intCast(w.start)) },
            .end = .{ .line = ln, .character = str.byteToUtf16(text, @intCast(w.end)) },
        };
    }

    fn symbol(o: Outline, obj: *Obj, kind: i64, detail: ?[]const u8, children: []const lsp.DocumentSymbol) lsp.DocumentSymbol {
        return .{
            .name = obj.name,
            .detail = detail,
            .kind = kind,
            .range = o.lines(obj.sline, obj.eline),
            .selectionRange = o.nameRange(obj),
            .children = children,
        };
    }

    /// The symbols of the children of `scope`
    fn childrenOf(o: Outline, scope: *Obj) Allocator.Error![]const lsp.DocumentSymbol {
        if (scope.kind == .type and o.skip_members) return &.{};
        var out: std.ArrayList(lsp.DocumentSymbol) = .empty;
        for (scope.childList()) |child| try o.append(child, scope, &out);
        return out.items;
    }

    /// The symbol of `obj`, a child of `parent`, if the outline shows it:
    /// program units, procedures, derived types (with their components and
    /// bindings), interfaces, and the data of modules. Not the local
    /// variables of procedures, nor constructs (DO, IF, BLOCK, ...).
    fn append(o: Outline, obj: *Obj, parent: *Obj, out: *std.ArrayList(lsp.DocumentSymbol)) Allocator.Error!void {
        switch (obj.kind) {
            .include, .block, .do_, .if_, .where, .select, .associate => {},
            .variable, .method => {
                const in_type = parent.kind == .type;
                if (!in_type and !isModuleLike(parent)) return;
                const kind = if (in_type)
                    (if (obj.kind == .method) Kind.method else Kind.field)
                else if (obj.kind == .variable and obj.varData().is_const) Kind.constant else Kind.variable;
                try out.append(o.a, o.symbol(obj, kind, try obj.getDescNoLink(o.a), &.{}));
            },
            .enum_ => {
                // its enumerators are constants of the enclosing scope
                for (obj.childList()) |e| try o.append(e, parent, out);
            },
            .interface => if (std.mem.startsWith(u8, obj.name, "#")) {
                // an interface block without a name: its procedures, in its
                // place (as interfaces, as in the flat list)
                for (obj.childList()) |p| {
                    try out.append(o.a, o.symbol(p, Kind.interface, null, try o.childrenOf(p)));
                }
            } else {
                try out.append(o.a, o.symbol(obj, Kind.interface, null, try o.childrenOf(obj)));
            },
            .module, .program, .submodule => try out.append(o.a, o.symbol(obj, Kind.module, null, try o.childrenOf(obj))),
            .type => try out.append(o.a, o.symbol(obj, Kind.class, null, try o.childrenOf(obj))),
            // `scope`: a MODULE PROCEDURE of a submodule
            .subroutine, .function, .scope => try out.append(o.a, o.symbol(obj, Kind.function, null, try o.childrenOf(obj))),
            .intrinsic => {},
        }
    }
};

fn isModuleLike(obj: *const Obj) bool {
    return obj.kind == .module or obj.kind == .submodule;
}

/// The outline of a file: its program units, with what they contain
pub fn documentSymbols(a: Allocator, file: *const FortranFile, ast: *Ast, skip_members: bool) Allocator.Error![]const lsp.DocumentSymbol {
    const o: Outline = .{ .a = a, .file = file, .skip_members = skip_members };
    var out: std.ArrayList(lsp.DocumentSymbol) = .empty;
    for (ast.scope_list.items) |scope| {
        if (scope.parent != null or scope.name.len == 0) continue;
        if (scope.kind == .include) continue;
        try o.append(scope, scope, &out);
    }
    return out.items;
}

// --------------------------------------------------------------------------
// Folding

const comment_kind = "comment";

/// The folding ranges of a file: each construct and program unit (up to the
/// line before its END, which stays in view), each branch of IF, SELECT and
/// WHERE constructs, each branch of preprocessor conditionals, and runs of
/// comment lines
pub fn foldingRanges(a: Allocator, file: *const FortranFile, ast: *Ast) Allocator.Error![]const lsp.FoldingRange {
    var out: std.ArrayList(lsp.FoldingRange) = .empty;
    for (ast.scope_list.items) |scope| try scopeFolds(a, file, ast, scope, &out);
    try preprocessorFolds(a, file, &out);
    try commentFolds(a, file, &out);
    std.mem.sort(lsp.FoldingRange, out.items, {}, struct {
        fn lt(_: void, x: lsp.FoldingRange, y: lsp.FoldingRange) bool {
            return x.startLine < y.startLine or (x.startLine == y.startLine and x.endLine > y.endLine);
        }
    }.lt);
    return out.items;
}

/// Appends the range of 0-based lines `start` to `end` if it folds anything
fn fold(a: Allocator, out: *std.ArrayList(lsp.FoldingRange), start: usize, end: usize, kind: ?[]const u8) Allocator.Error!void {
    if (end > start) try out.append(a, .{ .startLine = start, .endLine = end, .kind = kind });
}

fn scopeFolds(a: Allocator, file: *const FortranFile, ast: *Ast, scope: *Obj, out: *std.ArrayList(lsp.FoldingRange)) Allocator.Error!void {
    if (scope.kind == .include or scope == ast.none_scope) return;
    if (scope.eline <= scope.sline) return;
    // the parser opens a scope for each branch of a SELECT: the SELECT folds
    // them
    if (scope.kind == .select and !opensSelect(file, scope)) return;
    // 1-based: from the opening line to the line before END
    var start = scope.sline;
    switch (scope.kind) {
        .if_, .where, .select => {
            var ln = scope.sline + 1;
            while (ln < scope.eline) : (ln += 1) {
                if (!isBranch(file, scope.kind, ln) or inNested(file, ast, scope, ln)) continue;
                try fold(a, out, start -| 1, ln -| 2, null);
                start = ln;
            }
        },
        else => {},
    }
    try fold(a, out, start -| 1, scope.eline -| 2, null);
}

/// The first two names of the code on 1-based line `ln`, if it is not a
/// comment
fn leadingWords(file: *const FortranFile, ln: usize) ?[2][]const u8 {
    const text = file.getLine(ln - 1, false) orelse return null;
    if (helpers.isComment(file.fixed, text)) return null;
    var it = helpers.words(text);
    const w1 = it.next() orelse return null;
    const w2 = it.next();
    return .{ w1.str, if (w2) |w| w.str else "" };
}

fn eqlAny(word: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |opt| if (std.ascii.eqlIgnoreCase(word, opt)) return true;
    return false;
}

/// Whether a SELECT scope is the SELECT statement itself (`[name:] select
/// ...`), not one of the branches the parser opens a scope for
fn opensSelect(file: *const FortranFile, scope: *const Obj) bool {
    const w = leadingWords(file, scope.sline) orelse return true;
    return eqlAny(w[0], &.{"select"}) or eqlAny(w[1], &.{"select"});
}

/// Whether 1-based line `ln` starts a new branch of a construct of `kind`
fn isBranch(file: *const FortranFile, kind: objects.Kind, ln: usize) bool {
    const w = leadingWords(file, ln) orelse return false;
    return switch (kind) {
        .if_ => eqlAny(w[0], &.{ "else", "elseif" }),
        .where => eqlAny(w[0], &.{"elsewhere"}) or (eqlAny(w[0], &.{"else"}) and eqlAny(w[1], &.{"where"})),
        .select => eqlAny(w[0], &.{ "case", "rank" }) or
            (eqlAny(w[0], &.{ "type", "class" }) and eqlAny(w[1], &.{ "is", "default" })),
        else => false,
    };
}

/// Whether 1-based line `ln` of `scope` is inside a construct nested in it
/// (other than the branches of `scope` itself, when it is a SELECT)
fn inNested(file: *const FortranFile, ast: *Ast, scope: *const Obj, ln: usize) bool {
    for (ast.scope_list.items) |s| {
        if (s == scope or s.sline <= scope.sline or s.sline >= scope.eline) continue;
        if (s.kind == .select and !opensSelect(file, s)) continue;
        if (s.sline <= ln and ln <= s.eline) return true;
    }
    return false;
}

/// `#if`/`#ifdef`/`#ifndef` ... `#elif`/`#else` ... `#endif`: each branch
fn preprocessorFolds(a: Allocator, file: *const FortranFile, out: *std.ArrayList(lsp.FoldingRange)) Allocator.Error!void {
    var open: std.ArrayList(usize) = .empty;
    for (0..file.nLines()) |ln| {
        const text = file.getLine(ln, false) orelse continue;
        const t = std.mem.trimStart(u8, text, " \t");
        if (t.len == 0 or t[0] != '#') continue;
        var it = helpers.words(t[1..]);
        const d = (it.next() orelse continue).str;
        if (eqlAny(d, &.{ "if", "ifdef", "ifndef" })) {
            try open.append(a, ln);
        } else if (eqlAny(d, &.{ "elif", "else" })) {
            if (open.items.len == 0) continue;
            const top = &open.items[open.items.len - 1];
            try fold(a, out, top.*, ln -| 1, null);
            top.* = ln;
        } else if (eqlAny(d, &.{"endif"})) {
            const start = open.pop() orelse continue;
            try fold(a, out, start, ln -| 1, null);
        }
    }
}

/// Two or more comment lines in a row; not directives such as `!$omp`
fn commentFolds(a: Allocator, file: *const FortranFile, out: *std.ArrayList(lsp.FoldingRange)) Allocator.Error!void {
    var run_start: ?usize = null;
    const n = file.nLines();
    for (0..n + 1) |ln| {
        const is_comment = ln < n and isPlainComment(file, file.getLine(ln, false) orelse "");
        if (is_comment) {
            if (run_start == null) run_start = ln;
        } else if (run_start) |s| {
            try fold(a, out, s, ln - 1, comment_kind);
            run_start = null;
        }
    }
}

fn isPlainComment(file: *const FortranFile, text: []const u8) bool {
    if (!helpers.isComment(file.fixed, text)) return false;
    // the character after the comment mark: `$` for a directive sentinel
    const mark = if (file.fixed and text.len > 0 and std.mem.indexOfScalar(u8, "!cCdD*", text[0]) != null)
        0
    else
        std.mem.indexOfScalar(u8, text, '!') orelse return true;
    return !(mark + 1 < text.len and text[mark + 1] == '$');
}
