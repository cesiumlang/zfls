//! Unused names: the local variables of procedures and programs, and the
//! names of USE ONLY lists, that their scope never uses. Found by counting
//! the words of the scope's lines (contained procedures and inactive
//! preprocessor branches included): a name used once besides its
//! declaration is used. Dummy arguments, function results and the names of
//! modules (which other units may use) are not reported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const objects = @import("objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;
const selection = @import("selection.zig");
const statement = @import("statement.zig");

pub const Unused = struct {
    /// 0-based line and byte columns of the name in its declaration
    line: usize,
    start: usize,
    end: usize,
    name: []const u8,
    kind: enum { variable, use_name },
    /// 0-based line of the statement that declares it
    decl_line: usize,
};

pub fn find(a: Allocator, file: *const FortranFile, ast: *Ast) ![]const Unused {
    var out: std.ArrayList(Unused) = .empty;
    if (file.nLines() == 0) return out.items;
    for (ast.scope_list.items) |scope| {
        switch (scope.kind) {
            .subroutine, .function, .program => {},
            else => continue,
        }
        if (scope.file_ast != ast or scope.sline == 0) continue;
        // an interface body declares, it uses nothing
        if (scope.parent) |p| if (p.kind == .interface) continue;
        const first = scope.sline - 1;
        const last = @min(@max(scope.eline, scope.sline) - 1, file.nLines() - 1);
        const counts = (try wordCounts(a, file, first, last)) orelse continue;
        for (scope.childList()) |c| {
            if (c.kind != .variable or c.file_ast != ast or c.sline == 0) continue;
            if (isArgOrResult(scope, c)) continue;
            const lower = try std.ascii.allocLowerString(a, c.name);
            if ((counts.get(lower) orelse 0) > 1) continue;
            const at = findName(file, c.sline - 1, c.name) orelse continue;
            try out.append(a, .{
                .line = at.line,
                .start = at.start,
                .end = at.end,
                .name = c.name,
                .kind = .variable,
                .decl_line = c.sline - 1,
            });
        }
        if (scope.data != .scope) continue;
        for (scope.scopeDataConst().use.items) |u| {
            if (u.is_import or u.line_number == 0 or u.only_list.len() == 0 or u.included) continue;
            for (u.only_list.items.items) |name| {
                if (!isName(name)) continue;
                if ((counts.get(name) orelse 0) > 1) continue;
                const at = findName(file, u.line_number - 1, name) orelse continue;
                try out.append(a, .{
                    .line = at.line,
                    .start = at.start,
                    .end = at.end,
                    .name = at.text,
                    .kind = .use_name,
                    .decl_line = u.line_number - 1,
                });
            }
        }
    }
    return out.items;
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn isArgOrResult(scope: *const Obj, c: *const Obj) bool {
    if (scope.procDataOptConst()) |proc| {
        for (proc.arg_objs.items) |arg| if (arg == c) return true;
        if (proc.result_obj == c) return true;
        if (proc.result_name) |r| if (c.nameLowerEql(r)) return true;
    }
    return scope.kind == .function and c.nameLowerEql(scope.name);
}

/// How many times each word (lowercase) occurs in the code of 0-based lines
/// `first`..`last`, with their macros expanded (a name in a macro's value is
/// used where the macro is); null when they include a file, whose code may
/// use names
fn wordCounts(a: Allocator, file: *const FortranFile, first: usize, last: usize) !?std.StringHashMapUnmanaged(usize) {
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    var ln = first;
    while (ln <= last) : (ln += 1) {
        const raw = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        const t = std.mem.trimStart(u8, raw, " \t");
        if (std.ascii.startsWithIgnoreCase(t, "include") or std.mem.startsWith(u8, t, "#") and std.mem.find(u8, t, "include") != null) return null;
        var code = try helpers.stripStrings(a, file.getLine(ln, true) orelse raw, true);
        if (std.mem.findScalar(u8, code, '!')) |i| code = code[0..i];
        var it = helpers.words(code);
        while (it.next()) |w| {
            const gop = try counts.getOrPut(a, try std.ascii.allocLowerString(a, w.str));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    return counts;
}

/// Where `name` is written on the statement that starts on 0-based line
/// `line`
fn findName(file: *const FortranFile, line: usize, name: []const u8) ?struct { line: usize, start: usize, end: usize, text: []const u8 } {
    const st = selection.statementLines(file, line);
    var ln = st.first;
    while (ln <= st.last) : (ln += 1) {
        const text = file.getLine(ln, false) orelse continue;
        var it = helpers.words(text);
        while (it.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w.str, name)) return .{ .line = ln, .start = w.start, .end = w.end, .text = w.str };
        }
    }
    return null;
}

/// Text to delete: 0-based lines and byte columns, the end exclusive
pub const Cut = struct { sl: usize, sc: usize, el: usize, ec: usize };

/// The cuts that remove `names` from the type declaration, EXTERNAL
/// statement or USE ONLY list on 0-based line `line`: the whole statement
/// when it declares nothing else, otherwise each name with its dimensions
/// and initialization and a comma (continuation lines included). Null when
/// the statement is not one
/// of those, declares none of `names`, or is not one zfls can take apart
/// (several statements on a line, a string continued on the next line).
pub fn removal(a: Allocator, file: *const FortranFile, line: usize, names: []const []const u8) !?[]const Cut {
    const st = (try statement.linesOf(a, file, line)) orelse return null;
    const cuts = (try removeFrom(a, st.lines, file.fixed, names)) orelse return null;
    for (cuts) |*c| {
        c.sl += st.first;
        c.el += st.first;
    }
    return cuts;
}

/// `removal` on the lines of one statement
fn removeFrom(a: Allocator, lines: []const []const u8, fixed: bool, names: []const []const u8) !?[]Cut {
    const code = (try statement.of(a, lines, fixed)) orelse return null;
    const t = code.text;
    var p = code.skipBlanks(0);
    const kw = try std.ascii.allocLowerString(a, code.word(p));
    p += kw.len;
    const list_start = if (std.mem.eql(u8, kw, "use")) blk: {
        // after `only:`
        while (p < t.len) : (p += 1) {
            const w = code.word(p);
            if (w.len == 0) continue;
            p += w.len - 1;
            if (!std.ascii.eqlIgnoreCase(w, "only")) continue;
            const q = code.skipBlanks(p + 1);
            if (q < t.len and t[q] == ':') break :blk q + 1;
        }
        return null;
    } else if (typeKeyword(kw)) blk: {
        if (findDoubleColon(t, p)) |dc| break :blk dc + 2;
        break :blk (try typeSpecEnd(a, code, p, kw)) orelse return null;
    } else if (std.mem.eql(u8, kw, "external")) blk: {
        if (findDoubleColon(t, p)) |dc| break :blk dc + 2;
        break :blk p;
    } else return null;
    // the entities, between commas outside parentheses
    const Entity = struct { start: usize, end: usize, remove: bool };
    var entities: std.ArrayList(Entity) = .empty;
    var depth: usize = 0;
    var s = list_start;
    var k = list_start;
    while (k <= t.len) : (k += 1) {
        if (k < t.len) {
            switch (t[k]) {
                '(', '[' => depth += 1,
                ')', ']' => depth -|= 1,
                else => {},
            }
            if (t[k] != ',' or depth > 0) continue;
        }
        const b = code.skipBlanks(s);
        var e = k;
        while (e > b and statement.isBlank(t[e - 1])) e -= 1;
        if (e == b) return null;
        const name = code.word(b);
        var remove = false;
        for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) {
            remove = true;
        };
        try entities.append(a, .{ .start = b, .end = e, .remove = remove });
        s = k + 1;
    }
    const ents = entities.items;
    var kept: usize = 0;
    for (ents) |e| {
        if (!e.remove) kept += 1;
    }
    if (kept == ents.len) return null;
    var cuts: std.ArrayList(Cut) = .empty;
    if (kept == 0) {
        try cuts.append(a, .{ .sl = 0, .sc = 0, .el = lines.len, .ec = 0 });
        return cuts.items;
    }
    // each run of entities to remove: up to the entity after it, or from
    // the one before it when it ends the list
    var i: usize = 0;
    while (i < ents.len) {
        if (!ents[i].remove) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < ents.len and ents[j].remove) j += 1;
        if (j < ents.len) {
            const from = code.at[ents[i].start];
            const to = code.at[ents[j].start];
            try cuts.append(a, .{ .sl = from.line, .sc = from.col, .el = to.line, .ec = to.col });
        } else {
            const from = code.at[ents[i - 1].end - 1];
            const to = code.at[ents[j - 1].end - 1];
            try cuts.append(a, .{ .sl = from.line, .sc = from.col + 1, .el = to.line, .ec = to.col + 1 });
        }
        i = j;
    }
    return cuts.items;
}

fn typeKeyword(w: []const u8) bool {
    for ([_][]const u8{ "integer", "real", "complex", "logical", "character", "double", "doubleprecision", "doublecomplex", "type", "class", "procedure" }) |k| {
        if (std.mem.eql(u8, w, k)) return true;
    }
    return false;
}

/// Where the first `::` outside parentheses is in `t`, from `from`
fn findDoubleColon(t: []const u8, from: usize) ?usize {
    var depth: usize = 0;
    var i = from;
    while (i + 1 < t.len) : (i += 1) switch (t[i]) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        ':' => if (depth == 0 and t[i + 1] == ':') return i,
        else => {},
    };
    return null;
}

/// Where the names of a declaration without `::` start: after its type
/// keyword `kw` (ending at `from`) and the kind or length after it
/// (`double precision`, `real(8)`, `real*8`, `character*(*)`, `type(t)`)
fn typeSpecEnd(a: Allocator, code: statement.Code, from: usize, kw: []const u8) !?usize {
    const t = code.text;
    var p = from;
    if (std.mem.eql(u8, kw, "double")) {
        p = code.skipBlanks(p);
        const w = try std.ascii.allocLowerString(a, code.word(p));
        if (!std.mem.eql(u8, w, "precision") and !std.mem.eql(u8, w, "complex")) return null;
        p += w.len;
    }
    p = code.skipBlanks(p);
    if (p < t.len and t[p] == '(') {
        p = (code.closing(p) orelse return null) + 1;
    } else if (std.mem.eql(u8, kw, "type") or std.mem.eql(u8, kw, "class") or std.mem.eql(u8, kw, "procedure")) return null;
    p = code.skipBlanks(p);
    if (p < t.len and t[p] == '*') {
        p = code.skipBlanks(p + 1);
        if (p < t.len and t[p] == '(') {
            p = (code.closing(p) orelse return null) + 1;
        } else {
            while (p < t.len and std.ascii.isDigit(t[p])) p += 1;
        }
    }
    return p;
}

/// `lines` with `names` removed by `removeFrom`, a newline after each line
fn removedText(a: Allocator, lines: []const []const u8, fixed: bool, names: []const []const u8) ![]const u8 {
    const cuts = (try removeFrom(a, lines, fixed, names)) orelse return "(none)";
    var text: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(usize) = .empty;
    for (lines) |l| {
        try offsets.append(a, text.items.len);
        try text.appendSlice(a, l);
        try text.append(a, '\n');
    }
    try offsets.append(a, text.items.len);
    var i = cuts.len;
    while (i > 0) {
        i -= 1;
        const c = cuts[i];
        const from = offsets.items[c.sl] + c.sc;
        try text.replaceRange(a, from, offsets.items[c.el] + c.ec - from, "");
    }
    return text.items;
}

test "removing names from declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const eq = std.testing.expectEqualStrings;
    // the only name: the whole statement
    try eq("", try removedText(a, &.{"  real :: x"}, false, &.{"x"}));
    try eq("", try removedText(a, &.{ "  real, dimension(3) :: x = &", "    [1., 2., 3.]" }, false, &.{"x"}));
    // one of several, with its dimensions and initialization
    try eq("  integer :: a, c ! note\n", try removedText(a, &.{"  integer :: a, b(2, 3) = reshape([1, 2, 3, 4, 5, 6], [2, 3]), c ! note"}, false, &.{"b"}));
    try eq("  integer :: b\n", try removedText(a, &.{"  integer :: a = 1, b"}, false, &.{"a"}));
    try eq("  integer :: a\n", try removedText(a, &.{"  integer :: a, b, c"}, false, &.{ "b", "c" }));
    try eq("  integer :: b\n", try removedText(a, &.{"  integer :: a, b, c"}, false, &.{ "a", "c" }));
    try eq("  character(len=3) :: t = 'b,c'\n", try removedText(a, &.{"  character(len=3) :: s = 'a,b', t = 'b,c'"}, false, &.{"s"}));
    // continuation lines
    try eq("  integer :: a, &\n             c\n", try removedText(a, &.{ "  integer :: a, &", "             b, &", "             c" }, false, &.{"b"}));
    try eq("  integer :: a\n", try removedText(a, &.{ "  integer :: a, &", "             b" }, false, &.{"b"}));
    try eq("      real x\n", try removedText(a, &.{ "      real x,", "     &  y" }, true, &.{"y"}));
    // without `::`
    try eq("      double precision b\n", try removedText(a, &.{"      double precision a(3), b"}, true, &.{"a"}));
    try eq("      character*(*) b\n", try removedText(a, &.{"      character*(*) a, b"}, true, &.{"a"}));
    try eq("      real*8 b\n", try removedText(a, &.{"      real*8 a, b"}, true, &.{"a"}));
    // USE ONLY lists
    try eq("  use m, only: a, c\n", try removedText(a, &.{"  use m, only: a, b => x, c"}, false, &.{"b"}));
    try eq("", try removedText(a, &.{"  use m, only: b"}, false, &.{"b"}));
    // not taken apart
    try eq("(none)", try removedText(a, &.{"  real :: x; real :: y"}, false, &.{"x"}));
    try eq("(none)", try removedText(a, &.{"  common /c/ x, y"}, false, &.{"x"}));
    // EXTERNAL statements
    try eq("  external g\n", try removedText(a, &.{"  external f, g"}, false, &.{"f"}));
    try eq("", try removedText(a, &.{"  external :: f"}, false, &.{"f"}));
    try eq("(none)", try removedText(a, &.{"  real :: x, y"}, false, &.{"z"}));
}
