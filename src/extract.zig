//! Refactoring: extract selected statements into a new internal procedure
//! (#222). The statements move into a subroutine after CONTAINS (of their
//! unit, or of its host when the unit is itself an internal procedure) and
//! a CALL replaces them. The unit's variables they use become its dummy
//! arguments, with INTENT(IN) when the statements only read them, OUT when
//! they only assign them whole and do so first, unconditionally, and INOUT
//! otherwise; other names (a module's, the host's) stay host associated.
//! Refused when the statements return, leave or cycle a construct outside
//! them, jump to a label outside them or are jumped into, or do not make
//! up whole constructs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const objects = @import("objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;
const selection = @import("selection.zig");
const statement = @import("statement.zig");

pub const Intent = enum { in, out, inout };

/// What the statements do with a name
pub const Access = struct {
    read: bool = false,
    /// assigned whole (`x = 1`, `read *, x`, `allocate(x(n))`)
    whole: bool = false,
    /// assigned in part (`x(i) = 1`, `x%a = 1`) or passed to a procedure
    partial: bool = false,
    /// whether the first access assigns it whole, unconditionally
    first_whole: ?bool = null,
};

/// How each name (lowercase) is accessed, in the order of first use; and
/// the labels the statements define and refer to
pub const Uses = struct {
    names: std.array_hash_map.String(Access) = .empty,
    labels: std.ArrayList([]const u8) = .empty,
    refs: std.ArrayList([]const u8) = .empty,
    /// why the statements cannot be extracted, if they cannot
    refusal: ?[]const u8 = null,
    /// the construct names (`outer:`) the statements define
    constructs: std.ArrayList([]const u8) = .empty,
    /// the EXIT and CYCLE statements: their lines and construct names
    leaves: std.ArrayList(Leave) = .empty,
    /// the 0-based line of the statement being analyzed
    line: usize = 0,

    pub const Leave = struct { line: usize, name: ?[]const u8 };

    fn note(u: *Uses, a: Allocator, name: []const u8, kind: enum { read, whole, partial }, conditional: bool) !void {
        const gop = try u.names.getOrPut(a, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const acc = gop.value_ptr;
        if (acc.first_whole == null) acc.first_whole = kind == .whole and !conditional;
        switch (kind) {
            .read => acc.read = true,
            .whole => acc.whole = true,
            .partial => acc.partial = true,
        }
    }

    pub fn intentOf(u: *const Uses, name: []const u8) Intent {
        const acc = u.names.get(name) orelse return .in;
        if (!acc.whole and !acc.partial) return .in;
        if (!acc.read and !acc.partial and acc.first_whole == true) return .out;
        return .inout;
    }
};

/// The specifiers of I/O and allocation statements that assign their
/// variable
const output_specifiers = [_][]const u8{ "iostat", "iomsg", "stat", "errmsg", "size", "newunit" };

/// Notes the accesses of one statement, `t` (lowercase, strings blanked,
/// no comment), on a line where it runs `conditional`ly or not
pub fn analyze(a: Allocator, u: *Uses, t_in: []const u8, conditional: bool) Allocator.Error!void {
    var t = std.mem.trim(u8, t_in, " \t");
    // a label, a construct name
    var d: usize = 0;
    while (d < t.len and std.ascii.isDigit(t[d])) d += 1;
    if (d > 0 and (d == t.len or t[d] == ' ' or t[d] == '\t')) {
        try u.labels.append(a, std.mem.trimStart(u8, t[0..d], "0"));
        t = std.mem.trimStart(u8, t[d..], " \t");
    }
    if (constructName(t)) |c| {
        try u.constructs.append(a, c.name);
        t = std.mem.trimStart(u8, t[c.end..], " \t");
    }
    if (t.len == 0) return;
    const first = firstWord(t);
    const w = first.text;
    const rest = std.mem.trimStart(u8, t[first.end..], " \t");
    if (eql(w, "return") or eql(w, "entry")) {
        u.refusal = "it returns from the procedure";
        return;
    }
    if (eql(w, "exit") or eql(w, "cycle")) {
        // checked against the constructs by the caller
        const name = firstWord(rest).text;
        try u.leaves.append(a, .{ .line = u.line, .name = if (name.len > 0) name else null });
        return;
    }
    if (eql(w, "goto") or eql(w, "go") and std.mem.startsWith(u8, rest, "to")) {
        try labelsIn(a, u, rest);
        return reads(a, u, rest, conditional);
    }
    if ((eql(w, "if") or eql(w, "where") or eql(w, "forall")) and rest.len > 0 and rest[0] == '(') {
        const close = matching(rest, 0) orelse return reads(a, u, rest, conditional);
        try reads(a, u, rest[0 .. close + 1], conditional);
        const after = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        if (after.len == 0 or std.mem.startsWith(u8, after, "then")) return;
        if (eql(w, "if") and std.ascii.isDigit(after[0])) return labelsIn(a, u, after);
        return analyze(a, u, after, true);
    }
    if (eql(w, "do")) {
        var r = rest;
        var n: usize = 0;
        while (n < r.len and std.ascii.isDigit(r[n])) n += 1;
        if (n > 0) {
            try u.refs.append(a, r[0..n]);
            r = std.mem.trimStart(u8, std.mem.trimStart(u8, r[n..], " \t,"), " \t");
        }
        const v = firstWord(r);
        if (v.text.len > 0 and !eql(v.text, "while") and !eql(v.text, "concurrent")) {
            const after = std.mem.trimStart(u8, r[v.end..], " \t");
            if (after.len > 0 and after[0] == '=') {
                try u.note(a, v.text, .whole, conditional);
                return reads(a, u, after[1..], conditional);
            }
        }
        return reads(a, u, r, conditional);
    }
    if (eql(w, "call")) return callArgs(a, u, rest, conditional);
    if (eql(w, "allocate") or eql(w, "deallocate") or eql(w, "nullify")) {
        if (rest.len == 0 or rest[0] != '(') return reads(a, u, rest, conditional);
        const close = matching(rest, 0) orelse return reads(a, u, rest, conditional);
        var items = Items{ .t = rest[1..close] };
        while (items.next()) |item| {
            if (specifier(item)) |sp| {
                if (isOutputSpecifier(sp.key)) try designator(a, u, sp.value, .whole, conditional) else try reads(a, u, sp.value, conditional);
                continue;
            }
            // `allocate(x(n))` allocates x whole; n is read
            try designator(a, u, item, .allocate, conditional);
        }
        return;
    }
    if (eql(w, "read") or eql(w, "write") or eql(w, "print") or eql(w, "open") or eql(w, "close") or eql(w, "inquire") or
        eql(w, "rewind") or eql(w, "backspace") or eql(w, "endfile") or eql(w, "flush") or eql(w, "wait"))
    {
        var list = rest;
        if (rest.len > 0 and rest[0] == '(') {
            const close = matching(rest, 0) orelse return reads(a, u, rest, conditional);
            var items = Items{ .t = rest[1..close] };
            var i: usize = 0;
            while (items.next()) |item| : (i += 1) {
                if (specifier(item)) |sp| {
                    const out = isOutputSpecifier(sp.key) or eql(w, "inquire") and !eql(sp.key, "unit") and !eql(sp.key, "file") and !eql(sp.key, "id");
                    if (eql(sp.key, "fmt") or eql(sp.key, "err") or eql(sp.key, "end") or eql(sp.key, "eor")) try labelsIn(a, u, sp.value);
                    if (out) try designator(a, u, sp.value, .whole, conditional) else try reads(a, u, sp.value, conditional);
                    continue;
                }
                const item_t = std.mem.trim(u8, item, " \t");
                if (i == 1 and item_t.len > 0 and std.ascii.isDigit(item_t[0])) try labelsIn(a, u, item_t);
                // an internal file written to
                if (i == 0 and eql(w, "write")) try designator(a, u, item, .whole, conditional) else try reads(a, u, item, conditional);
            }
            list = rest[close + 1 ..];
        } else if (eql(w, "print") or eql(w, "read")) {
            // `print 10, x` / `read *, x`
            var items = Items{ .t = rest };
            if (items.next()) |fmt| {
                const f = std.mem.trim(u8, fmt, " \t");
                if (f.len > 0 and std.ascii.isDigit(f[0])) try labelsIn(a, u, f) else try reads(a, u, f, conditional);
                // nothing after the format: `print *`
                list = items.t[@min(items.pos, items.t.len)..];
            }
        }
        if (eql(w, "read")) {
            var items = Items{ .t = list };
            while (items.next()) |item| try inputItem(a, u, item, conditional);
            return;
        }
        return reads(a, u, list, conditional);
    }
    // an assignment
    if (assignment(t)) |eq| {
        const op_len: usize = if (eq + 1 < t.len and t[eq + 1] == '>') 2 else 1;
        try designator(a, u, t[0..eq], .whole, conditional);
        return reads(a, u, t[eq + op_len ..], conditional);
    }
    return reads(a, u, t, conditional);
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn firstWord(t: []const u8) struct { text: []const u8, end: usize } {
    var e: usize = 0;
    while (e < t.len and (std.ascii.isAlphanumeric(t[e]) or t[e] == '_')) e += 1;
    return .{ .text = t[0..e], .end = e };
}

/// `name:` at the start of `t` (not `::`)
fn constructName(t: []const u8) ?struct { name: []const u8, end: usize } {
    const w = firstWord(t);
    if (w.text.len == 0 or std.ascii.isDigit(w.text[0])) return null;
    var p = w.end;
    while (p < t.len and (t[p] == ' ' or t[p] == '\t')) p += 1;
    if (p >= t.len or t[p] != ':' or p + 1 < t.len and t[p + 1] == ':') return null;
    return .{ .name = w.text, .end = p + 1 };
}

/// The `)` closing the `(` at `open`
fn matching(t: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (t[open..], open..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

/// The items of a list, between commas outside parentheses
const Items = struct {
    t: []const u8,
    pos: usize = 0,

    fn next(it: *Items) ?[]const u8 {
        if (it.pos > it.t.len) return null;
        var depth: usize = 0;
        var i = it.pos;
        while (i < it.t.len) : (i += 1) switch (it.t[i]) {
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ',' => if (depth == 0) break,
            else => {},
        };
        const item = it.t[it.pos..i];
        it.pos = i + 1;
        if (i >= it.t.len and std.mem.trim(u8, item, " \t").len == 0) return null;
        return item;
    }
};

/// `key = value` of a specifier or keyword argument
fn specifier(item: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const t = std.mem.trimStart(u8, item, " \t");
    const w = firstWord(t);
    if (w.text.len == 0) return null;
    const after = std.mem.trimStart(u8, t[w.end..], " \t");
    if (after.len < 1 or after[0] != '=' or after.len > 1 and (after[1] == '=' or after[1] == '>')) return null;
    return .{ .key = w.text, .value = after[1..] };
}

fn isOutputSpecifier(key: []const u8) bool {
    for (output_specifiers) |s| if (eql(key, s)) return true;
    return false;
}

/// Where the `=` or `=>` of an assignment is: outside parentheses, not a
/// relational operator
fn assignment(t: []const u8) ?usize {
    var depth: usize = 0;
    for (t, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        '=' => {
            if (depth > 0) continue;
            if (i + 1 < t.len and t[i + 1] == '=') return null;
            if (i > 0 and (t[i - 1] == '=' or t[i - 1] == '/' or t[i - 1] == '<' or t[i - 1] == '>')) return null;
            return i;
        },
        else => {},
    };
    return null;
}

/// A variable or part of one that is assigned (`kind`), or passed: its
/// name assigned, the rest (subscripts) read
fn designator(a: Allocator, u: *Uses, d_in: []const u8, kind: enum { whole, partial, allocate }, conditional: bool) !void {
    const d = std.mem.trim(u8, d_in, " \t");
    const w = firstWord(d);
    if (w.text.len == 0 or std.ascii.isDigit(w.text[0])) return reads(a, u, d, conditional);
    const after = std.mem.trimStart(u8, d[w.end..], " \t");
    // only a name with subscripts or components is a designator
    var p: usize = 0;
    var part = false;
    while (p < after.len) {
        if (after[p] == '(') {
            p = (matching(after, p) orelse return reads(a, u, d, conditional)) + 1;
            part = true;
        } else if (after[p] == '%') {
            p += 1;
            while (p < after.len and (std.ascii.isAlphanumeric(after[p]) or after[p] == '_' or after[p] == ' ')) p += 1;
            part = true;
        } else if (after[p] == ' ' or after[p] == '\t') {
            p += 1;
        } else return reads(a, u, d, conditional);
    }
    const whole = switch (kind) {
        .whole => !part,
        .partial => false,
        // `allocate(x(n))` allocates x whole, `allocate(x%a(n))` part of it
        .allocate => std.mem.findScalar(u8, after, '%') == null,
    };
    try u.note(a, w.text, if (whole) .whole else .partial, conditional);
    try reads(a, u, after, conditional);
}

/// The actual arguments of a CALL: a variable passed may be assigned
fn callArgs(a: Allocator, u: *Uses, t: []const u8, conditional: bool) !void {
    const open = std.mem.findScalar(u8, t, '(') orelse return;
    const close = matching(t, open) orelse return reads(a, u, t, conditional);
    var items = Items{ .t = t[open + 1 .. close] };
    while (items.next()) |item| {
        const value = if (specifier(item)) |sp| sp.value else item;
        if (isDesignator(value)) try designator(a, u, value, .partial, conditional) else try reads(a, u, value, conditional);
    }
}

fn isDesignator(t_in: []const u8) bool {
    const t = std.mem.trim(u8, t_in, " \t");
    const w = firstWord(t);
    if (w.text.len == 0 or std.ascii.isDigit(w.text[0])) return false;
    var p = w.end;
    while (p < t.len) {
        if (t[p] == '(') {
            p = (matching(t, p) orelse return false) + 1;
        } else if (t[p] == '%' or t[p] == ' ' or std.ascii.isAlphanumeric(t[p]) or t[p] == '_') {
            p += 1;
        } else return false;
    }
    return true;
}

/// An item of a READ's input list: a variable assigned, or an implied DO
/// `(x(i), i = 1, n)`
fn inputItem(a: Allocator, u: *Uses, item_in: []const u8, conditional: bool) !void {
    const item = std.mem.trim(u8, item_in, " \t");
    if (item.len > 1 and item[0] == '(' and matching(item, 0) == item.len - 1) {
        var items = Items{ .t = item[1 .. item.len - 1] };
        while (items.next()) |i| {
            if (specifier(i)) |sp| {
                try u.note(a, sp.key, .whole, true);
                try reads(a, u, sp.value, conditional);
            } else try inputItem(a, u, i, true);
        }
        return;
    }
    if (isDesignator(item)) return designator(a, u, item, .whole, conditional);
    return reads(a, u, item, conditional);
}

/// Notes each name of `t` read; the variable of an implied DO (`(a(i), i
/// = 1, n)`, a `(` after no name) is assigned, a keyword argument (`f(x
/// = 1)`) is no name of the unit
fn reads(a: Allocator, u: *Uses, t: []const u8, conditional: bool) Allocator.Error!void {
    var opens: std.ArrayList(bool) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (c == '(' or c == '[') {
            var b = i;
            while (b > 0 and (t[b - 1] == ' ' or t[b - 1] == '\t')) b -= 1;
            const after_name = c == '(' and b > 0 and (std.ascii.isAlphanumeric(t[b - 1]) or t[b - 1] == '_' or t[b - 1] == ')');
            try opens.append(a, after_name);
            i += 1;
            continue;
        }
        if (c == ')' or c == ']') {
            _ = opens.pop();
            i += 1;
            continue;
        }
        if (!(std.ascii.isAlphabetic(c) or c == '_')) {
            i += 1;
            continue;
        }
        var e = i;
        while (e < t.len and (std.ascii.isAlphanumeric(t[e]) or t[e] == '_' or t[e] == '$')) e += 1;
        const word = t[i..e];
        const prev: u8 = if (i > 0) t[i - 1] else ' ';
        const prev2: u8 = if (i > 1) t[i - 2] else ' ';
        const next: u8 = if (e < t.len) t[e] else ' ';
        i = e;
        // a number (`1e5`, `2.d0`, `1.0_dp`), an operator (`.and.`), a
        // component (`a%b`)
        if (std.ascii.isDigit(prev) or prev == '.' and (next == '.' or std.ascii.isDigit(prev2)) or prev == '%') continue;
        var q = e;
        while (q < t.len and (t[q] == ' ' or t[q] == '\t')) q += 1;
        const keyword = opens.items.len > 0 and q < t.len and t[q] == '=' and !(q + 1 < t.len and (t[q + 1] == '=' or t[q + 1] == '>'));
        if (keyword) {
            if (!opens.items[opens.items.len - 1]) try u.note(a, word, .whole, true);
            continue;
        }
        try u.note(a, word, .read, conditional);
    }
}

/// The labels `t` refers to: its numbers
fn labelsIn(a: Allocator, u: *Uses, t: []const u8) !void {
    var i: usize = 0;
    while (i < t.len) {
        if (!std.ascii.isDigit(t[i]) or i > 0 and (std.ascii.isAlphanumeric(t[i - 1]) or t[i - 1] == '_')) {
            i += 1;
            continue;
        }
        var e = i;
        while (e < t.len and std.ascii.isDigit(t[e])) e += 1;
        try u.refs.append(a, std.mem.trimStart(u8, t[i..e], "0"));
        i = e;
    }
}

/// The statements on 0-based lines `first`..`last` of `file`: their code
/// (lowercase, strings blanked) and first lines; null when one of them
/// cannot be read (several on a line, a preprocessor directive)
pub fn statements(a: Allocator, file: *const FortranFile, first: usize, last: usize) !?[]const Stmt {
    var out: std.ArrayList(Stmt) = .empty;
    var l = first;
    while (l <= last) {
        const st = selection.statementLines(file, l);
        const raw = file.getLine(l, false) orelse return null;
        if (helpers.isComment(file.fixed, raw) or std.mem.trim(u8, raw, " \t\r").len == 0) {
            l += 1;
            continue;
        }
        if (helpers.isPpDirective(raw)) return null;
        const lines = (try statement.linesOf(a, file, st.first)) orelse return null;
        const code = (try statement.of(a, lines.lines, file.fixed)) orelse return null;
        try out.append(a, .{ .line = st.first, .text = try std.ascii.allocLowerString(a, code.text) });
        l = st.last + 1;
    }
    return out.items;
}

pub const Stmt = struct { line: usize, text: []const u8 };

/// A change of the text: 0-based lines and byte columns, the end exclusive
pub const Edit = struct { sl: usize, sc: usize, el: usize, ec: usize, text: []const u8 };

pub const Plan = union(enum) {
    /// why the statements cannot be extracted
    refused: []const u8,
    extracted: struct { name: []const u8, edits: []const Edit },
};

/// The extraction of the statements on 0-based lines `first_in`..`last_in`
/// of `file` (whole statements, those lines touch) into a new subroutine;
/// null when the lines hold no statement of a procedure or program
pub fn plan(a: Allocator, file: *const FortranFile, ast: *Ast, first_in: usize, last_in: usize) !?Plan {
    if (file.nLines() == 0) return null;
    const first = selection.statementLines(file, @min(first_in, file.nLines() - 1)).first;
    const last = selection.statementLines(file, @min(last_in, file.nLines() - 1)).last;
    // the procedure or program around them
    const scopes = try ast.getScopes(a, first + 1);
    const unit = blk: {
        var i = scopes.len;
        while (i > 0) {
            i -= 1;
            switch (scopes[i].kind) {
                .subroutine, .function, .program => break :blk scopes[i],
                .module, .submodule, .interface, .type => return null,
                else => {},
            }
        }
        return null;
    };
    if (unit.data != .scope or unit.sline == 0 or unit.eline == 0) return null;
    if (file.fixed) return .{ .refused = "fixed-form source is not supported" };
    const sd = unit.scopeDataConst();
    // after the declarations, before CONTAINS
    var spec_end = unit.sline;
    for (unit.childList()) |c| {
        const end = switch (c.kind) {
            .variable => c.sline,
            .interface, .type, .enum_ => c.eline,
            else => continue,
        };
        spec_end = @max(spec_end, end);
    }
    for (sd.use.items) |u| spec_end = @max(spec_end, u.line_number);
    if (sd.implicit_line) |il| spec_end = @max(spec_end, il);
    const stop = sd.contains_start orelse unit.eline;
    if (first + 1 <= spec_end or last + 1 >= stop) return null;
    const stmts = (try statements(a, file, first, last)) orelse return .{ .refused = "the lines hold several statements or a preprocessor directive" };
    if (stmts.len == 0) return null;
    // whole constructs only
    for (ast.scope_list.items) |sc| {
        if (!sc.kind.isBlock() or sc.sline == 0) continue;
        const inside = first + 1 <= sc.sline and sc.eline <= last + 1;
        const apart = sc.eline < first + 1 or sc.sline > last + 1;
        const around = sc.sline < first + 1 and sc.eline > last + 1;
        if (!inside and !apart and !around) return .{ .refused = "the statements do not make up whole constructs" };
    }
    var u: Uses = .{};
    for (stmts) |st| {
        u.line = st.line;
        const inner = ast.getInnerScope(st.line + 1);
        const conditional = if (inner) |sc| sc.kind.isBlock() and sc.sline >= first + 1 and sc.sline != st.line + 1 else false;
        try analyze(a, &u, st.text, conditional);
        if (u.refusal) |r| return .{ .refused = r };
    }
    // labels: jumps out, and in
    for (u.refs.items) |r| if (!contains(u.labels.items, r)) {
        return .{ .refused = try a.print("the statements refer to label {s} outside them", .{r}) };
    };
    if (u.labels.items.len > 0) {
        var outside: Uses = .{};
        for ([2][2]usize{ .{ unit.sline, first }, .{ last + 1, unit.eline -| 1 } }) |range| {
            if (range[0] >= range[1]) continue;
            for ((try statements(a, file, range[0], range[1] - 1)) orelse &.{}) |st| {
                if (ast.getInnerScope(st.line + 1)) |sc| if (sc != unit and !sc.kind.isBlock()) continue;
                try analyze(a, &outside, st.text, false);
            }
        }
        for (outside.refs.items) |r| if (contains(u.labels.items, r)) {
            return .{ .refused = try a.print("label {s} is jumped to from outside the statements", .{r}) };
        };
    }
    // EXIT and CYCLE of constructs in the statements
    for (u.leaves.items) |lv| {
        if (lv.name) |n| {
            if (!contains(u.constructs.items, n)) return .{ .refused = try a.print("the statements leave construct {s} around them", .{n}) };
            continue;
        }
        var loop: ?*Obj = null;
        for (try ast.getScopes(a, lv.line + 1)) |sc| {
            if (sc.kind == .do_ and (loop == null or sc.sline > loop.?.sline)) loop = sc;
        }
        if (loop == null or loop.?.sline < first + 1) return .{ .refused = "the statements EXIT or CYCLE a loop around them" };
    }
    // the variables of the unit they use; not those of a construct around
    // them, which the new procedure cannot see
    for (scopes) |sc| {
        if (!sc.kind.isBlock() or sc.sline >= first + 1) continue;
        for (sc.childList()) |c| if (u.names.contains(try std.ascii.allocLowerString(a, c.name))) {
            return .{ .refused = try a.print("the statements use {s} of the construct around them", .{c.name}) };
        };
    }
    var vars: std.StringHashMapUnmanaged(*Obj) = .empty;
    for (unit.childList()) |c| if (c.kind == .variable) try vars.put(a, try std.ascii.allocLowerString(a, c.name), c);
    // an internal procedure's new sibling sees its host, not the procedure
    const internal = if (unit.parent) |p| p.kind == .subroutine or p.kind == .function or p.kind == .program else false;
    const host = if (internal) unit.parent.? else unit;
    var args: std.ArrayList([]const u8) = .empty;
    var decls: std.ArrayList([]const u8) = .empty;
    for (u.names.keys()) |n| {
        const v = vars.get(n) orelse {
            if (unit.kind == .function and std.ascii.eqlIgnoreCase(n, unit.name)) return .{ .refused = "the statements assign the function's result" };
            continue;
        };
        if (v.varDataConst().is_external) continue;
        if (v.isParameter()) {
            if (internal) return .{ .refused = try a.print("the statements use the named constant {s} of the procedure", .{v.name}) };
            continue;
        }
        const declared_in = if (v.keyword_info.intent) |i| std.ascii.eqlIgnoreCase(std.mem.trim(u8, i, " "), "in") else false;
        const intent: Intent = if (declared_in) .in else u.intentOf(n);
        try decls.append(a, (try dummyDecl(a, v, intent)) orelse return .{ .refused = try a.print("{s} cannot be declared as an argument", .{v.name}) });
        try args.append(a, v.name);
    }
    // the new subroutine
    const name = try freshName(a, file);
    const arg_list = try std.mem.join(a, ", ", args.items);
    const call_indent = indentOf(file.getLine(first, false) orelse "");
    var call: std.ArrayList(u8) = .empty;
    try call.print(a, "{s}call {s}", .{ call_indent, name });
    if (args.items.len > 0) try call.print(a, "({s})", .{arg_list});
    try call.append(a, '\n');
    const hi = indentOf(file.getLine(host.sline - 1, false) orelse "");
    const pi = try std.mem.concat(a, u8, &.{ hi, "  " });
    const bi = try std.mem.concat(a, u8, &.{ pi, "  " });
    var text: std.ArrayList(u8) = .empty;
    if (host.scopeDataConst().contains_start == null) try text.print(a, "{s}contains\n", .{hi}) else try text.append(a, '\n');
    try text.print(a, "{s}subroutine {s}", .{ pi, name });
    if (args.items.len > 0) try text.print(a, "({s})", .{arg_list});
    try text.append(a, '\n');
    for (decls.items) |d| try text.print(a, "{s}{s}\n", .{ bi, d });
    // the statements, indented as the body
    var base: ?usize = null;
    for (first..last + 1) |l| {
        const line = file.getLine(l, false) orelse "";
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const n = indentOf(line).len;
        if (base == null or n < base.?) base = n;
    }
    for (first..last + 1) |l| {
        const line = file.getLine(l, false) orelse "";
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            try text.append(a, '\n');
            continue;
        }
        try text.print(a, "{s}{s}\n", .{ bi, line[@min(base orelse 0, indentOf(line).len)..] });
    }
    try text.print(a, "{s}end subroutine {s}\n", .{ pi, name });
    const end_line = host.eline - 1;
    const edits = try a.dupe(Edit, &.{
        .{ .sl = first, .sc = 0, .el = last + 1, .ec = 0, .text = call.items },
        .{ .sl = end_line, .sc = 0, .el = end_line, .ec = 0, .text = text.items },
    });
    return .{ .extracted = .{ .name = name, .edits = edits } };
}

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.ascii.eqlIgnoreCase(x, y)) return true;
    return false;
}

fn indentOf(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return line[0..n];
}

fn usesWord(file: *const FortranFile, name: []const u8) bool {
    for (0..file.nLines()) |l| {
        var it = helpers.words(file.getLine(l, false) orelse continue);
        while (it.next()) |w| if (std.ascii.eqlIgnoreCase(w.str, name)) return true;
    }
    return false;
}

/// `extracted`, or `extracted_2`, ...: a name the file does not use
fn freshName(a: Allocator, file: *const FortranFile) ![]const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = if (n == 1) "extracted" else try a.print("extracted_{d}", .{n});
        if (!usesWord(file, name)) return name;
    }
}

/// The declaration of `v` as a dummy argument of `intent`: its type and
/// attributes, an array of assumed shape (deferred when allocatable or a
/// pointer), a character of assumed length; null when it cannot be one
/// (a coarray, an assumed-size array of rank 2 or more, a lower bound
/// that is not a number, a procedure)
fn dummyDecl(a: Allocator, v: *const Obj, intent: Intent) !?[]const u8 {
    const desc = try v.getDescNoLink(a);
    var k: usize = 0;
    while (k < desc.len and (std.ascii.isAlphabetic(desc[k]) or desc[k] == ' ')) k += 1;
    const keyword = std.mem.trimEnd(u8, try std.ascii.allocLowerString(a, desc[0..k]), " ");
    k = keyword.len;
    if (std.mem.eql(u8, keyword, "procedure") or keyword.len == 0) return null;
    const deferred = v.hasKeyword(.allocatable) or v.hasKeyword(.pointer);
    var ty: []const u8 = try std.mem.concat(a, u8, &.{ keyword, desc[k..] });
    if (std.mem.eql(u8, keyword, "character") and !deferred) {
        const lower = try std.ascii.allocLowerString(a, desc);
        ty = "character(len=*)";
        if (std.mem.find(u8, lower, "kind=")) |i| {
            var e = i + 5;
            while (e < desc.len and desc[e] != ',' and desc[e] != ')') e += 1;
            ty = try a.print("character(len=*, kind={s})", .{std.mem.trim(u8, desc[i + 5 .. e], " ")});
        }
    }
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(a, ty);
    for (v.keywords.items) |id| switch (id) {
        .allocatable, .pointer, .target, .optional, .contiguous => try parts.append(a, @tagName(id)),
        .codimension => return null,
        else => {},
    };
    if (v.keyword_info.dimension) |dims| {
        var shape: std.ArrayList(u8) = .empty;
        var items = Items{ .t = dims };
        var rank: usize = 0;
        while (items.next()) |dim_in| : (rank += 1) {
            const dim = std.mem.trim(u8, dim_in, " ");
            if (rank > 0) try shape.append(a, ',');
            if (deferred) {
                try shape.append(a, ':');
                continue;
            }
            const colon = std.mem.findScalar(u8, dim, ':');
            const lb = if (colon) |c| std.mem.trim(u8, dim[0..c], " ") else "";
            if (lb.len > 0 and !isInteger(lb)) return null;
            if (std.mem.endsWith(u8, dim, "*")) {
                if (rank > 0 or items.next() != null) return null;
                try shape.print(a, "{s}{s}*", .{ lb, if (lb.len > 0) ":" else "" });
                break;
            }
            try shape.print(a, "{s}:", .{lb});
        }
        try parts.append(a, try a.print("dimension({s})", .{shape.items}));
    }
    try parts.append(a, try a.print("intent({s})", .{@tagName(intent)}));
    return try a.print("{s} :: {s}", .{ try std.mem.join(a, ", ", parts.items), v.name });
}

fn isInteger(t: []const u8) bool {
    const s = if (t.len > 0 and (t[0] == '-' or t[0] == '+')) t[1..] else t;
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "the accesses of statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u: Uses = .{};
    for ([_][]const u8{
        "s = 0",
        "do i = 1, n",
        "s = s + x(i) * 2.0_dp",
        "y(i) = s",
        "end do",
        "if (s > 1.e5) t = 1",
        "call show(s, n + 1, flag=on)",
        "read (unit, *, iostat=ios) (w(k), k = 1, 3)",
        "write (msg, '(a)') 'done'",
    }) |s| try analyze(a, &u, s, false);
    const expectEqual = std.testing.expectEqual;
    try expectEqual(Intent.inout, u.intentOf("s"));
    try expectEqual(Intent.inout, u.intentOf("i"));
    try expectEqual(Intent.in, u.intentOf("n"));
    try expectEqual(Intent.in, u.intentOf("x"));
    try expectEqual(Intent.inout, u.intentOf("y"));
    // conditional: may keep the value it had
    try expectEqual(Intent.inout, u.intentOf("t"));
    // passed to a procedure, which may assign it
    try expectEqual(Intent.inout, u.intentOf("on"));
    try std.testing.expect(u.names.get("flag") == null and u.names.get("dp") == null and u.names.get("e5") == null);
    try expectEqual(Intent.out, u.intentOf("ios"));
    try expectEqual(Intent.inout, u.intentOf("w"));
    try expectEqual(Intent.inout, u.intentOf("k"));
    try expectEqual(Intent.in, u.intentOf("unit"));
    try expectEqual(Intent.out, u.intentOf("msg"));

    var r: Uses = .{};
    try analyze(a, &r, "if (x < 0) return", false);
    try std.testing.expect(r.refusal != null);
    var g: Uses = .{};
    try analyze(a, &g, "10 if (x < 0) go to 20", false);
    try analyze(a, &g, "write (*, 30) x", false);
    try std.testing.expectEqualStrings("10", g.labels.items[0]);
    try std.testing.expectEqualStrings("20", g.refs.items[0]);
    try std.testing.expectEqualStrings("30", g.refs.items[1]);
}
