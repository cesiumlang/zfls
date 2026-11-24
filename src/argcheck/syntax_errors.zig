//! Statements the compilers reject as malformed (#875), as far as zfls can
//! tell for certain: parentheses that do not match, an assignment that
//! ends in an operator, a `type(t)` declaration of an ABSTRACT type, a type
//! that extends one nothing defines, a PURE function with a dummy argument
//! that has no INTENT(IN) (INTENT(OUT) and INTENT(INOUT) are gfortran's and
//! ifx's errors, Flang accepts them), and an unknown specifier in a READ or
//! WRITE. gfortran, Flang and ifx report all of them. A statement of a file
//! with preprocessor lines inside it, or that is cut by a continuation
//! line, is left alone.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const assign_types = @import("assign_types.zig");
const objects = @import("../objects.zig");
const objects_check = @import("../objects/check.zig");
const selection = @import("../selection.zig");
const FortranFile = @import("../parser.zig").FortranFile;
const KW = @import("../constants.zig").KW;

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;
const Obj = objects.Obj;
const Word = helpers.Word;

pub fn check(c: *Checker, j: Joined, s: usize, e: usize, first: Word, scope: ?*Obj, line_no: usize) !void {
    const text = j.text[s..e];
    if (c.cut_statement or hasPreprocessorLine(c, j, s, e) or isPartial(c, j)) return;
    if (!std.ascii.isAlphabetic(text[first.start])) return;
    try parentheses(c, j, s, text, first);
    try danglingOperator(c, j, s, text, first, scope, line_no);
    try abstractType(c, j, s, text, first, scope, line_no);
    try extendsUnknown(c, j, s, text, first, scope, line_no);
    try pureDummies(c, j, s, text, scope, line_no);
    try ioSpecifiers(c, j, s, text, first);
}

/// Whether a line of the statement is a preprocessor directive (`#if`)
fn hasPreprocessorLine(c: *Checker, j: Joined, s: usize, e: usize) bool {
    const file = c.ast.file orelse return false;
    if (e <= s) return false;
    var ln = j.lines[s];
    const last = j.lines[e - 1];
    while (ln <= last) : (ln += 1) {
        const raw = file.getLine(ln, false) orelse continue;
        const t = std.mem.trimStart(u8, raw, " \t");
        if (t.len > 0 and t[0] == '#') return true;
    }
    return false;
}

/// Whether `raw` has no code: blank, a comment or a preprocessor line
fn noCode(file: *const FortranFile, raw: []const u8) bool {
    const t = std.mem.trim(u8, raw, " \t\r");
    return t.len == 0 or t[0] == '#' or helpers.isComment(file.fixed, raw);
}

/// Whether a string literal of `raw` goes on in the next line
fn openString(raw: []const u8) bool {
    var quote: u8 = 0;
    for (raw) |ch| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '!') return false;
    }
    return quote != 0;
}

/// Whether the statement is a part of a larger one: a string goes on over
/// its lines, or a blank line, a comment or a preprocessor line cuts its
/// continuation before or after it (#259)
fn isPartial(c: *Checker, j: Joined) bool {
    // once for the many statements of a long line
    const key = @intFromPtr(j.text.ptr);
    if (c.partial_of != key) {
        c.partial = partOfLarger(c, j);
        c.partial_of = key;
    }
    return c.partial;
}

fn partOfLarger(c: *Checker, j: Joined) bool {
    const file = c.ast.file orelse return false;
    if (j.lines.len == 0) return false;
    const first = j.lines[0];
    const last = j.lines[j.lines.len - 1];
    var ln = first;
    while (ln <= last) : (ln += 1) {
        if (openString(file.getLine(ln, false) orelse continue)) return true;
    }
    if (file.fixed) {
        if (helpers.fixedContMark(file.getLine(first, false) orelse return false) != null) return true;
        ln = last + 1;
        while (ln < file.nLines()) : (ln += 1) {
            const raw = file.getLine(ln, false) orelse continue;
            if (noCode(file, raw)) continue;
            return helpers.fixedContMark(raw) != null;
        }
        return false;
    }
    ln = first;
    while (ln > 0) {
        ln -= 1;
        const raw = file.getLine(ln, false) orelse continue;
        if (noCode(file, raw)) continue;
        const code = std.mem.trimEnd(u8, raw[0..selection.codeEnd(raw)], " \t\r");
        return std.mem.endsWith(u8, code, "&");
    }
    return false;
}

fn parentheses(c: *Checker, j: Joined, s: usize, text: []const u8, first: Word) !void {
    // text kept in a FORMAT or DATA statement can hold anything
    if (typing.oneOf(first.str, &.{ "format", "data" })) return;
    var stack: std.ArrayList(usize) = .empty;
    for (text, 0..) |ch, i| switch (ch) {
        '(' => try stack.append(c.a, i),
        ')' => if (stack.pop() == null) {
            return c.report(j, s + i, s + i + 1, .unbalanced_parentheses, "This ) has no matching (", .{});
        },
        else => {},
    };
    if (stack.items.len > 0) {
        const at = stack.items[stack.items.len - 1];
        try c.report(j, s + at, s + at + 1, .unbalanced_parentheses, "This ( has no matching )", .{});
    }
}

/// The operators and keywords an expression cannot end with
fn endsInOperator(rhs: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, rhs, " ");
    if (t.len == 0) return null;
    switch (t[t.len - 1]) {
        '+', '-', '*', '/' => return t[t.len - 1 ..],
        '.' => {
            const open = std.mem.findScalarLast(u8, t[0 .. t.len - 1], '.') orelse return null;
            const word = t[open + 1 .. t.len - 1];
            if (typing.oneOf(word, &.{ "and", "or", "eqv", "neqv", "not", "eq", "ne", "lt", "le", "gt", "ge" })) return t[open..];
            return null;
        },
        else => return null,
    }
}

fn danglingOperator(c: *Checker, j: Joined, s: usize, text: []const u8, first: Word, scope: ?*Obj, line_no: usize) !void {
    const t = (try assign_types.target(c, text, first, scope, line_no)) orelse return;
    const rhs = text[t.rhs_at..];
    const op = endsInOperator(rhs) orelse return;
    const end = t.rhs_at + std.mem.trimEnd(u8, rhs, " ").len;
    try c.report(j, s + end - op.len, s + end, .dangling_operator, "The expression ends in the operator {s}", .{op});
}

/// The name of the type in `type(name)` at the start of `text`, with its
/// offset
fn typeName(text: []const u8, first: Word) ?struct { name: []const u8, at: usize } {
    if (!std.ascii.eqlIgnoreCase(first.str, "type")) return null;
    var k = first.end;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '(') return null;
    const close = typing.matching(text, k) orelse return null;
    const name = std.mem.trim(u8, text[k + 1 .. close], " ");
    if (!typing.isName(name)) return null;
    return .{ .name = name, .at = k + 1 + (std.mem.find(u8, text[k + 1 ..], name) orelse 0) };
}

fn abstractType(c: *Checker, j: Joined, s: usize, text: []const u8, first: Word, scope: ?*Obj, line_no: usize) !void {
    const t = typeName(text, first) orelse return;
    const obj = (try c.lookup(scope, t.name, line_no)) orelse return;
    if (obj.kind != .type or !obj.typeDataConst().abstract) return;
    try c.report(j, s + t.at, s + t.at + t.name.len, .abstract_type_declared, "The type {s} is ABSTRACT: declare a CLASS({s}) variable", .{ obj.name, obj.name });
}

fn extendsUnknown(c: *Checker, j: Joined, s: usize, text: []const u8, first: Word, scope: ?*Obj, line_no: usize) !void {
    if (!std.ascii.eqlIgnoreCase(first.str, "type")) return;
    const ext = std.ascii.findIgnoreCase(text, "extends") orelse return;
    var k = ext + "extends".len;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '(') return;
    const close = typing.matching(text, k) orelse return;
    const name = std.mem.trim(u8, text[k + 1 .. close], " ");
    if (!typing.isName(name)) return;
    // what a module of another project, or an include, may bring in
    if (c.ast.include_statements.items.len > 0 or objects_check.seesUnknownModule(c.env, scope)) return;
    if ((try c.lookup(scope, name, line_no)) != null) return;
    const at = k + 1 + (std.mem.find(u8, text[k + 1 ..], name) orelse 0);
    try c.report(j, s + at, s + at + name.len, .extends_unknown_type, "The type {s} that this type extends is not defined", .{name});
}

fn pureDummies(c: *Checker, j: Joined, s: usize, text: []const u8, scope: ?*Obj, line_no: usize) !void {
    const f = scope orelse return;
    if (f.kind != .function or f.sline != line_no or !f.hasKeyword(KW.pure)) return;
    const kw = std.ascii.findIgnoreCase(text, "function") orelse return;
    var k = kw + "function".len;
    while (k < text.len and text[k] == ' ') k += 1;
    while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_')) k += 1;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '(') return;
    const close = typing.matching(text, k) orelse return;
    var pos = k + 1;
    while (pos <= close) {
        const rest = text[pos..close];
        const comma = std.mem.findScalar(u8, rest, ',') orelse rest.len;
        const item = std.mem.trim(u8, rest[0..comma], " ");
        const at = pos + (std.mem.find(u8, rest[0..comma], item) orelse 0);
        pos += comma + 1;
        if (!typing.isName(item)) continue;
        const v = for (f.childList()) |ch| {
            if (ch.kind == .variable and std.ascii.eqlIgnoreCase(ch.name, item)) break ch;
        } else continue;
        if (v.varDataConst().is_external or v.hasKeyword(KW.value) or v.hasKeyword(KW.pointer)) continue;
        const intent = if (v.keyword_info.intent) |i| std.mem.trim(u8, i, " ") else null;
        if (intent) |i| {
            if (std.ascii.eqlIgnoreCase(i, "in")) continue;
            // Flang accepts INTENT(OUT) and INTENT(INOUT)
            if (!c.dialect.applies(.initMany(&.{ .gfortran, .ifx }))) continue;
            try c.report(j, s + at, s + at + item.len, .pure_function_argument, "The argument {s} of the PURE function {s} is INTENT({s}), not INTENT(IN)", .{ item, f.name, i });
        } else {
            try c.report(j, s + at, s + at + item.len, .pure_function_argument, "The argument {s} of the PURE function {s} needs INTENT(IN) or VALUE", .{ item, f.name });
        }
    }
}

/// The specifiers of the READ and WRITE statements and of the statements
/// that have others (OPEN, CLOSE, INQUIRE) and the compilers' extensions:
/// a word outside them is no specifier of any
const specifiers = [_][]const u8{
    "unit",     "fmt",       "nml",             "rec",       "iostat",       "iomsg",       "err",    "end",          "eor",
    "advance",  "size",      "pos",             "id",        "asynchronous", "decimal",     "delim",  "pad",          "round",
    "sign",     "blank",     "access",          "action",    "form",         "file",        "status", "position",     "recl",
    "encoding", "newunit",   "exist",           "opened",    "number",       "named",       "name",   "sequential",   "direct",
    "stream",   "formatted", "unformatted",     "nextrec",   "pending",      "read",        "write",  "readwrite",    "iolength",
    "size",     "convert",   "dispose",         "disp",      "readonly",     "buffered",    "keyid",  "keyeq",        "keyge",
    "keygt",    "key",       "carriagecontrol", "blocksize", "buffercount",  "defaultfile", "mode",   "organization", "recordtype",
    "share",    "shared",    "noshared",        "title",     "type",         "useropen",    "maxrec", "iofocus",      "sync",
};

fn ioSpecifiers(c: *Checker, j: Joined, s: usize, text: []const u8, first: Word) !void {
    if (!typing.oneOf(first.str, &.{ "read", "write" })) return;
    var k = first.end;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '(') return;
    const close = typing.matching(text, k) orelse return;
    // an array named read or write
    const after = std.mem.trimStart(u8, text[close + 1 ..], " ");
    if (after.len > 0 and (after[0] == '=' or after[0] == '%' or after[0] == '(')) return;
    var pos = k + 1;
    while (pos <= close) {
        const rest = text[pos..close];
        const comma = typing.topLevel(rest, ',') orelse rest.len;
        const item = rest[0..comma];
        if (typing.keywordOf(item)) |kw| {
            if (!typing.oneOf(kw, &specifiers)) {
                const at = pos + (std.mem.find(u8, item, kw) orelse 0);
                try c.report(j, s + at, s + at + kw.len, .unknown_io_specifier, "{s} is no specifier of a {s} statement", .{ kw, first.str });
            }
        }
        pos += comma + 1;
    }
}
