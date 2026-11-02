//! Namelist files (`.nml`): the groups they hold and the variables each
//! sets, for their outline (Modern Fortran #1296). A namelist document is
//! not Fortran: the server keeps its text apart and never parses it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp.zig");
const str = @import("str.zig");

/// LSP `SymbolKind`s
const Kind = struct {
    const namespace: i64 = 3;
    const variable: i64 = 13;
};

/// File extensions of namelist files, whatever the editor says they are
const extensions = [_][]const u8{ ".nml", ".namelist" };

pub const Variable = struct {
    /// without the blanks of `a % b`
    name: []const u8,
    line: usize,
    /// the byte offset of the name on its line
    column: usize,
};

pub const Group = struct {
    name: []const u8,
    /// the line of `&name`
    line: usize,
    /// the byte offset of the name (after `&` or `$`)
    column: usize,
    /// the line of the `/` (or `&end`) that ends it; the last line when none
    end_line: usize,
    variables: []const Variable,
};

/// Whether a document is a namelist file: opened as one (`languageId`), or
/// named like one
pub fn isNamelist(language: ?[]const u8, path: []const u8) bool {
    if (language) |l| if (std.ascii.eqlIgnoreCase(l, "FortranNamelist") or std.ascii.eqlIgnoreCase(l, "namelist")) return true;
    const ext = std.Io.Dir.path.extension(path);
    for (extensions) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The end of the name (`[A-Za-z]\w*`) at `i`
fn wordEnd(t: []const u8, i: usize) usize {
    var j = i + 1;
    while (j < t.len and isWord(t[j])) j += 1;
    return j;
}

fn skipSpace(t: []const u8, i: usize) usize {
    var j = i;
    while (j < t.len and std.ascii.isWhitespace(t[j])) j += 1;
    return j;
}

/// `line` without its comment, and its strings blanked so that offsets stay
fn code(buf: *std.ArrayList(u8), a: Allocator, line: []const u8) ![]const u8 {
    buf.clearRetainingCapacity();
    var quote: u8 = 0;
    for (line) |c| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            try buf.append(a, ' ');
        } else if (c == '\'' or c == '"') {
            quote = c;
            try buf.append(a, ' ');
        } else if (c == '!') {
            break;
        } else try buf.append(a, c);
    }
    return buf.items;
}

/// The group a line starts (`&name`, `$name`, not `&end`): the offset of
/// its name, and the name's end
fn groupStart(t: []const u8) ?struct { column: usize, end: usize } {
    const i = skipSpace(t, 0);
    if (i + 1 >= t.len or (t[i] != '&' and t[i] != '$') or !std.ascii.isAlphabetic(t[i + 1])) return null;
    const end = wordEnd(t, i + 1);
    if (std.ascii.eqlIgnoreCase(t[i + 1 .. end], "end")) return null;
    return .{ .column = i + 1, .end = end };
}

/// Whether a line is `&end` (or `$end`)
fn groupEnd(t: []const u8) bool {
    const i = skipSpace(t, 0);
    if (i + 4 > t.len or (t[i] != '&' and t[i] != '$') or !std.ascii.eqlIgnoreCase(t[i + 1 .. i + 4], "end")) return false;
    return i + 4 == t.len or !isWord(t[i + 4]);
}

/// The variable a value is assigned to at `p` (`x =`, `a(1:2) =`,
/// `grid%nx =`): the end of its name, and of the `=`
fn assignmentAt(t: []const u8, p: usize) ?struct { name_end: usize, end: usize } {
    var name_end = wordEnd(t, p);
    // components
    while (true) {
        var j = skipSpace(t, name_end);
        if (j >= t.len or t[j] != '%') break;
        j = skipSpace(t, j + 1);
        if (j >= t.len or !std.ascii.isAlphabetic(t[j])) break;
        name_end = wordEnd(t, j);
    }
    var j = skipSpace(t, name_end);
    // a subscript or substring
    if (j < t.len and t[j] == '(') {
        const close = std.mem.findAnyPos(u8, t, j + 1, ")=") orelse return null;
        if (t[close] != ')') return null;
        j = skipSpace(t, close + 1);
    }
    if (j >= t.len or t[j] != '=') return null;
    return .{ .name_end = name_end, .end = j + 1 };
}

/// `name` without its blanks (`a % b` is `a%b`)
fn withoutBlanks(a: Allocator, name: []const u8) ![]const u8 {
    if (std.mem.findAny(u8, name, str.whitespace) == null) return name;
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| if (!std.ascii.isWhitespace(c)) try out.append(a, c);
    return out.items;
}

/// The groups of a namelist file and the variables they set; names are
/// slices of `lines` unless written with blanks (`a % b`)
pub fn groups(a: Allocator, lines: []const []const u8) ![]const Group {
    var out: std.ArrayList(Group) = .empty;
    var vars: std.ArrayList(Variable) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var open: ?Group = null;
    for (lines, 0..) |raw, ln| {
        var t = try code(&buf, a, raw);
        var from: usize = 0;
        if (open == null) {
            const s = groupStart(t) orelse continue;
            open = .{ .name = raw[s.column..s.end], .line = ln, .column = s.column, .end_line = lines.len - 1, .variables = &.{} };
            from = s.end;
        }
        // the group ends at `/` or `&end`
        const end: ?usize = if (groupEnd(t)) 0 else std.mem.findScalarPos(u8, t, from, '/');
        if (end) |e| t = t[0..e];
        var p = from;
        while (p < t.len) {
            if (std.ascii.isAlphabetic(t[p]) and (p == 0 or !isWord(t[p - 1]))) if (assignmentAt(t, p)) |m| {
                try vars.append(a, .{
                    .name = try withoutBlanks(a, raw[p..m.name_end]),
                    .line = ln,
                    .column = p,
                });
                p = m.end;
                continue;
            };
            p += 1;
        }
        if (end != null) {
            var g = open.?;
            g.end_line = ln;
            g.variables = try vars.toOwnedSlice(a);
            try out.append(a, g);
            open = null;
        }
    }
    if (open) |g| {
        var last = g;
        last.variables = try vars.toOwnedSlice(a);
        try out.append(a, last);
    }
    return out.items;
}

/// The range of `len` bytes at `col` on line `ln`, in UTF-16 characters
fn rangeOn(lines: []const []const u8, ln: usize, col: usize, len: usize) lsp.Range {
    return .{
        .start = .{ .line = ln, .character = str.byteToUtf16(lines[ln], col) },
        .end = .{ .line = ln, .character = str.byteToUtf16(lines[ln], col + len) },
    };
}

/// The whole of a group, from its first line to the end of its last
fn groupRange(lines: []const []const u8, g: Group) lsp.Range {
    const last = lines[g.end_line];
    return .{ .start = .{ .line = g.line, .character = 0 }, .end = .{ .line = g.end_line, .character = str.byteToUtf16(last, last.len) } };
}

/// The outline of a namelist file: its groups, each with the variables it
/// sets
pub fn documentSymbols(a: Allocator, lines: []const []const u8) ![]const lsp.DocumentSymbol {
    const gs = try groups(a, lines);
    const out = try a.alloc(lsp.DocumentSymbol, gs.len);
    for (gs, out) |g, *sym| {
        const children = try a.alloc(lsp.DocumentSymbol, g.variables.len);
        for (g.variables, children) |v, *c| {
            const r = rangeOn(lines, v.line, v.column, v.name.len);
            c.* = .{ .name = v.name, .kind = Kind.variable, .range = r, .selectionRange = r };
        }
        sym.* = .{
            .name = g.name,
            .detail = "namelist group",
            .kind = Kind.namespace,
            .range = groupRange(lines, g),
            .selectionRange = rangeOn(lines, g.line, g.column, g.name.len),
            .children = children,
        };
    }
    return out;
}

/// The same for clients without an outline tree: the groups, and their
/// variables with the group as container
pub fn flatSymbols(a: Allocator, uri: []const u8, lines: []const []const u8) ![]const lsp.SymbolInformation {
    var out: std.ArrayList(lsp.SymbolInformation) = .empty;
    for (try groups(a, lines)) |g| {
        try out.append(a, .{ .name = g.name, .kind = Kind.namespace, .location = .{ .uri = uri, .range = groupRange(lines, g) } });
        for (g.variables) |v| try out.append(a, .{
            .name = v.name,
            .kind = Kind.variable,
            .location = .{ .uri = uri, .range = rangeOn(lines, v.line, v.column, v.name.len) },
            .containerName = g.name,
        });
    }
    return out.items;
}

test "groups and their variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gs = try groups(arena.allocator(), &.{
        "! the run",
        "&run_params",
        "  steps = 100, dt = 1.0d-3 ! seconds",
        "  title = 'a = b / c', flags(1:2) = .true., .false.",
        "  grid%nx = 3*0",
        "/",
        "",
        "$output",
        "  path = \"out/\"",
        "$end",
    });
    try std.testing.expectEqual(@as(usize, 2), gs.len);
    try std.testing.expectEqualStrings("run_params", gs[0].name);
    try std.testing.expectEqual([3]usize{ 1, 1, 5 }, [3]usize{ gs[0].line, gs[0].column, gs[0].end_line });
    try std.testing.expectEqualStrings("output", gs[1].name);
    try std.testing.expectEqual([3]usize{ 7, 1, 9 }, [3]usize{ gs[1].line, gs[1].column, gs[1].end_line });
    const expected = [_]struct { []const u8, usize, usize }{
        .{ "steps", 2, 2 },
        .{ "dt", 2, 15 },
        .{ "title", 3, 2 },
        .{ "flags", 3, 23 },
        .{ "grid%nx", 4, 2 },
    };
    try std.testing.expectEqual(expected.len, gs[0].variables.len);
    for (expected, gs[0].variables) |e, v| {
        try std.testing.expectEqualStrings(e[0], v.name);
        try std.testing.expectEqual([2]usize{ e[1], e[2] }, [2]usize{ v.line, v.column });
    }
    try std.testing.expectEqual(@as(usize, 1), gs[1].variables.len);
    try std.testing.expectEqualStrings("path", gs[1].variables[0].name);
}

test "a group on one line, and one never ended" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gs = try groups(arena.allocator(), &.{ "&a x = 1, y = 2 /", "&b", "  z = 3" });
    try std.testing.expectEqual(@as(usize, 2), gs.len);
    try std.testing.expectEqualStrings("a", gs[0].name);
    try std.testing.expectEqual(@as(usize, 0), gs[0].end_line);
    try std.testing.expectEqualStrings("x", gs[0].variables[0].name);
    try std.testing.expectEqualStrings("y", gs[0].variables[1].name);
    try std.testing.expectEqualStrings("b", gs[1].name);
    try std.testing.expectEqual(@as(usize, 2), gs[1].end_line);
    try std.testing.expectEqual(@as(usize, 1), gs[1].variables.len);
    try std.testing.expectEqualStrings("z", gs[1].variables[0].name);
}

test "components written with blanks, and what is not an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gs = try groups(arena.allocator(), &.{ "&g grid % nx = 1, s(1:2)= 'x', &END_run = 2, q(1=2", "&end" });
    try std.testing.expectEqual(@as(usize, 1), gs.len);
    try std.testing.expectEqual(@as(usize, 1), gs[0].end_line);
    const names = [_][]const u8{ "grid%nx", "s", "END_run" };
    try std.testing.expectEqual(names.len, gs[0].variables.len);
    for (names, gs[0].variables) |n, v| try std.testing.expectEqualStrings(n, v.name);
    try std.testing.expectEqual(@as(usize, 3), gs[0].variables[0].column);
}

test "document symbols: ranges in UTF-16 characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = try documentSymbols(a, &.{ "&run", "  s = 'é', n = 1", "/ ! done" });
    try std.testing.expectEqual(@as(usize, 1), syms.len);
    try std.testing.expectEqual(Kind.namespace, syms[0].kind);
    try std.testing.expectEqual(lsp.Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 2, .character = 8 } }, syms[0].range);
    try std.testing.expectEqual(lsp.Range{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 4 } }, syms[0].selectionRange);
    try std.testing.expectEqual(@as(usize, 2), syms[0].children.len);
    try std.testing.expectEqualStrings("n", syms[0].children[1].name);
    try std.testing.expectEqual(lsp.Range{ .start = .{ .line = 1, .character = 11 }, .end = .{ .line = 1, .character = 12 } }, syms[0].children[1].range);
    const flat = try flatSymbols(a, "file:///x.nml", &.{ "&run", "  s = 'é', n = 1", "/ ! done" });
    try std.testing.expectEqual(@as(usize, 3), flat.len);
    try std.testing.expectEqualStrings("run", flat[2].containerName.?);
}

test "namelist documents by language and by name" {
    try std.testing.expect(isNamelist("FortranNamelist", "/x/input.txt"));
    try std.testing.expect(isNamelist(null, "/x/input.NML"));
    try std.testing.expect(isNamelist("FortranFreeForm", "/x/run.namelist"));
    try std.testing.expect(!isNamelist("FortranFreeForm", "/x/run.f90"));
    try std.testing.expect(!isNamelist(null, "/x/run.f90"));
}
