//! Intel Fortran's conditional compilation directives: `!DEC$ IF DEFINED
//! (sym)`, `!DIR$ IF (expr)`, `ELSEIF`, `ELSE`, `ENDIF`, and `DEFINE sym
//! [= value]` and `UNDEFINE sym`, which change the symbols for the rest of
//! the file. The compiler honors them in every Fortran file, without
//! `-fpp`, so they apply to every file, after the C preprocessor's
//! conditionals: the lines of the branches not taken become skips, as those
//! of `#if` are.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pp = @import("../preprocessor.zig");

pub const Kind = enum { if_, elseif, else_, endif, define, undefine };

/// A directive and the text after its keyword
pub const Directive = struct { kind: Kind, rest: []const u8 };

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn skipBlanks(line: []const u8, from: usize) usize {
    var i = from;
    while (i < line.len and isBlank(line[i])) i += 1;
    return i;
}

/// The end of the word (letters) at `from`
fn wordEnd(line: []const u8, from: usize) usize {
    var i = from;
    while (i < line.len and std.ascii.isAlphabetic(line[i])) i += 1;
    return i;
}

/// The conditional compilation directive of `line`, or null. The prefix is
/// `!DEC$` or `!DIR$` in any case; in fixed form `!`, `C`, `c` or `*` in
/// column 1 (`CDEC$`), in free form `!` after blanks.
pub fn directive(fixed: bool, line: []const u8) ?Directive {
    var i: usize = 0;
    if (fixed) {
        if (line.len == 0 or std.mem.findScalar(u8, "!cC*", line[0]) == null) return null;
        i = 1;
    } else {
        i = skipBlanks(line, 0);
        if (i >= line.len or line[i] != '!') return null;
        i += 1;
    }
    if (line.len < i + 4) return null;
    const prefix = line[i .. i + 4];
    if (!std.ascii.eqlIgnoreCase(prefix, "dec$") and !std.ascii.eqlIgnoreCase(prefix, "dir$")) return null;
    i = skipBlanks(line, i + 4);
    const kw_end = wordEnd(line, i);
    const kw = line[i..kw_end];
    var rest_at = kw_end;
    const kind: Kind = blk: {
        if (std.ascii.eqlIgnoreCase(kw, "if")) break :blk .if_;
        if (std.ascii.eqlIgnoreCase(kw, "elseif")) break :blk .elseif;
        if (std.ascii.eqlIgnoreCase(kw, "endif")) break :blk .endif;
        if (std.ascii.eqlIgnoreCase(kw, "define")) break :blk .define;
        if (std.ascii.eqlIgnoreCase(kw, "undefine")) break :blk .undefine;
        // `ELSE IF` and `END IF` in two words
        const next = skipBlanks(line, kw_end);
        const next_end = wordEnd(line, next);
        const two = std.ascii.eqlIgnoreCase(line[next..next_end], "if");
        if (std.ascii.eqlIgnoreCase(kw, "else")) {
            if (two) {
                rest_at = next_end;
                break :blk .elseif;
            }
            break :blk .else_;
        }
        if (std.ascii.eqlIgnoreCase(kw, "end") and two) {
            rest_at = next_end;
            break :blk .endif;
        }
        return null;
    };
    const rest = std.mem.trim(u8, line[rest_at..], " \t\r");
    // IF and ELSEIF have a condition: `DEFINED (sym)` or `(expr)`
    if ((kind == .if_ or kind == .elseif) and rest.len == 0) return null;
    // a word right after the keyword is another directive (`!DIR$ IFX`)
    if (rest_at < line.len and (std.ascii.isAlphanumeric(line[rest_at]) or line[rest_at] == '_')) return null;
    return .{ .kind = kind, .rest = rest };
}

/// A symbol's name as the table keeps it: in upper case, as the compiler
/// does not tell cases apart
fn upper(a: Allocator, name: []const u8) ![]u8 {
    return std.ascii.allocUpperString(a, name);
}

/// The Fortran operators (`.AND.`, `.EQ.`, `/=`, ...) of a condition written
/// as `evalPpIf` takes them (`&&`, `==`, `!=`), its names in upper case
pub fn cCondition(a: Allocator, expr: []const u8) ![]const u8 {
    const ops = [_][2][]const u8{
        .{ "AND", "&&" },  .{ "OR", "||" }, .{ "NOT", "!" }, .{ "EQV", "==" },
        .{ "NEQV", "!=" }, .{ "EQ", "==" }, .{ "NE", "!=" }, .{ "LT", "<" },
        .{ "LE", "<=" },   .{ "GT", ">" },  .{ "GE", ">=" }, .{ "TRUE", "1" },
        .{ "FALSE", "0" },
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < expr.len) {
        const c = expr[i];
        if (c == '!') break; // a comment
        if (c == '/' and i + 1 < expr.len and expr[i + 1] == '=') {
            try out.appendSlice(a, " != ");
            i += 2;
            continue;
        }
        if (c == '.') {
            const end = wordEnd(expr, i + 1);
            if (end > i + 1 and end < expr.len and expr[end] == '.') {
                for (ops) |op| if (std.ascii.eqlIgnoreCase(expr[i + 1 .. end], op[0])) {
                    try out.print(a, " {s} ", .{op[1]});
                    i = end + 1;
                    continue :outer;
                };
            }
        }
        try out.append(a, std.ascii.toUpper(c));
        i += 1;
    }
    return out.items;
}

/// Whether the condition of an IF or ELSEIF holds: `DEFINED (sym)` or
/// `(expr)`
fn holds(a: Allocator, cond: []const u8, symbols: *const pp.Defs) !bool {
    return pp.evalPpIf(a, try cCondition(a, cond), symbols);
}

/// A DEFINE's or UNDEFINE's symbol and value (`sym`, `sym = 2`)
fn symbolOf(rest: []const u8) ?struct { name: []const u8, value: []const u8 } {
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_' or rest[end] == '$')) end += 1;
    if (end == 0) return null;
    var tail = std.mem.trim(u8, rest[end..], " \t");
    if (std.mem.findScalar(u8, tail, '!')) |c| tail = std.mem.trim(u8, tail[0..c], " \t");
    const value = if (tail.len > 0 and tail[0] == '=') std.mem.trim(u8, tail[1..], " \t") else "";
    return .{ .name = rest[0..end], .value = if (value.len > 0) value else "1" };
}

/// An open IF: whether the lines around it are read (`outer`), whether one
/// of its branches was taken, and the line (0-based) of the directive that
/// starts the branch left out now (null: the branch is read)
const Frame = struct { outer: bool, taken: bool, start: ?usize };

/// Whether line `ln` (0-based) is in a branch that `skips` leave out, or is
/// the directive that ends one
fn skipped(skips: []const pp.Skip, ln: usize) bool {
    for (skips) |s| if (ln + 1 > s.start and ln + 1 <= s.end) return true;
    return false;
}

/// The branches that the Intel conditionals of `lines` leave out, as skips
/// (1-based, from the directive that starts a branch to the one that ends
/// it, as `pp.Skip`s are). `defs`: the symbols defined outside the file
/// (`pp_defs`, `-D`); `skips`: the C preprocessor's, whose lines are not
/// read. Null when the file has no such directive.
pub fn branchSkips(a: Allocator, lines: []const []const u8, fixed: bool, defs: ?*const pp.Defs, skips: []const pp.Skip) !?[]pp.Skip {
    var symbols: pp.Defs = .empty;
    var any = false;
    var stack: std.ArrayList(Frame) = .empty;
    var out: std.ArrayList(pp.Skip) = .empty;
    for (lines, 0..) |line, ln| {
        if (skipped(skips, ln)) continue;
        const d = directive(fixed, line) orelse continue;
        if (!any) {
            any = true;
            if (defs) |ds| {
                var it = ds.iterator();
                while (it.next()) |e| if (e.value_ptr.args == null) {
                    try symbols.put(a, try upper(a, e.key_ptr.*), .{ .value = e.value_ptr.value });
                };
            }
        }
        const reading = stack.items.len == 0 or (stack.items[stack.items.len - 1].outer and stack.items[stack.items.len - 1].start == null);
        switch (d.kind) {
            .if_ => {
                const yes = reading and try holds(a, d.rest, &symbols);
                try stack.append(a, .{ .outer = reading, .taken = yes, .start = if (reading and !yes) ln else null });
            },
            .elseif, .else_ => {
                if (stack.items.len == 0) continue;
                const top = &stack.items[stack.items.len - 1];
                if (!top.outer) continue;
                if (top.start == null) {
                    // the branch read so far ends
                    top.start = ln;
                } else if (!top.taken and (d.kind == .else_ or try holds(a, d.rest, &symbols))) {
                    try out.append(a, .{ .start = top.start.? + 1, .end = ln + 1 });
                    top.start = null;
                    top.taken = true;
                }
            },
            .endif => {
                const top = stack.pop() orelse continue;
                if (top.start) |s| try out.append(a, .{ .start = s + 1, .end = ln + 1 });
            },
            .define, .undefine => if (reading) {
                const sym = symbolOf(d.rest) orelse continue;
                const name = try upper(a, sym.name);
                if (d.kind == .define) {
                    try symbols.put(a, name, .{ .value = sym.value });
                } else {
                    _ = symbols.orderedRemove(name);
                }
            },
        }
    }
    if (!any) return null;
    // an IF left open leaves out the rest of the file
    while (stack.pop()) |top| if (top.start) |s| try out.append(a, .{ .start = s + 1, .end = lines.len });
    return out.items;
}

const testing = std.testing;

test "the directives, in either form" {
    const D = struct {
        fn kind(fixed: bool, line: []const u8) ?Kind {
            return if (directive(fixed, line)) |d| d.kind else null;
        }
    };
    try testing.expectEqual(Kind.if_, D.kind(false, "!DEC$ IF DEFINED (_UNICODE)").?);
    try testing.expectEqual(Kind.if_, D.kind(false, "   !dir$ if (VER .GE. 2)").?);
    try testing.expectEqual(Kind.elseif, D.kind(false, "!DIR$ ELSEIF (X)").?);
    try testing.expectEqual(Kind.elseif, D.kind(false, "!DIR$ ELSE IF (X)").?);
    try testing.expectEqual(Kind.else_, D.kind(false, "!DEC$ ELSE").?);
    try testing.expectEqual(Kind.endif, D.kind(false, "!DEC$ ENDIF").?);
    try testing.expectEqual(Kind.endif, D.kind(false, "!DEC$ END IF").?);
    try testing.expectEqual(Kind.define, D.kind(false, "!DEC$ DEFINE X = 2").?);
    try testing.expectEqual(Kind.undefine, D.kind(false, "!DEC$ UNDEFINE X").?);
    try testing.expectEqual(Kind.if_, D.kind(true, "CDEC$ IF DEFINED(X)").?);
    try testing.expectEqual(Kind.endif, D.kind(true, "*DIR$ ENDIF").?);
    try testing.expectEqual(Kind.else_, D.kind(true, "!DEC$ ELSE").?);
    // other directives and comments
    try testing.expectEqual(@as(?Kind, null), D.kind(false, "!DIR$ ATTRIBUTES DLLEXPORT :: f"));
    try testing.expectEqual(@as(?Kind, null), D.kind(false, "!DIR$ IVDEP"));
    try testing.expectEqual(@as(?Kind, null), D.kind(false, "!DEC$ IF"));
    try testing.expectEqual(@as(?Kind, null), D.kind(false, "! DEC$ IF DEFINED(X)"));
    try testing.expectEqual(@as(?Kind, null), D.kind(false, "x = 1 !DEC$ IF DEFINED(X)"));
    try testing.expectEqual(@as(?Kind, null), D.kind(true, "   !DEC$ IF DEFINED(X)"));
    try testing.expectEqual(@as(?Kind, null), D.kind(false, "!$omp parallel"));
}

test "Fortran operators in conditions" {
    @import("../patterns.zig").init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var symbols: pp.Defs = .empty;
    try symbols.put(a, "VER", .{ .value = "3" });
    try symbols.put(a, "NEW", .{ .value = "1" });
    try testing.expect(try holds(a, "(ver .ge. 2 .and. .not. defined(OLD))", &symbols));
    try testing.expect(!try holds(a, "(VER .GE. 2 .AND. .NOT. DEFINED(NEW))", &symbols));
    try testing.expect(try holds(a, "(VER /= 1 .OR. VER .EQ. .FALSE.)", &symbols));
    try testing.expect(try holds(a, "(VER == 3) ! a comment", &symbols));
    try testing.expect(!try holds(a, "(VER .LT. 3)", &symbols));
    try testing.expect(try holds(a, "DEFINED (new)", &symbols));
    try testing.expect(!try holds(a, "DEFINED (OLD)", &symbols));
}

fn testSkips(a: Allocator, lines: []const []const u8, fixed: bool, defs: ?*const pp.Defs) ![]const pp.Skip {
    @import("../patterns.zig").init();
    return (try branchSkips(a, lines, fixed, defs, &.{})) orelse &.{};
}

fn expectSkips(got: []const pp.Skip, want: []const [2]usize) !void {
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| {
        try testing.expectEqual(w[0], g.start);
        try testing.expectEqual(w[1], g.end);
    }
}

test "branches left out" {
    const lines = [_][]const u8{
        "module m", // 0
        "!DEC$ IF DEFINED (_UNICODE)", // 1
        "   integer, parameter :: utf16 = 1",
        "!DEC$ ELSE", // 3
        "   integer, parameter :: utf16 = 0",
        "!DEC$ ENDIF", // 5
        "!DIR$ IF DEFINED (DBG)", // 6
        "   integer :: lvl",
        "!DIR$ ELSE", // 8
        "   real :: lvl",
        "!DIR$ ENDIF", // 10
        "end module",
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectSkips(try testSkips(a, &lines, false, null), &.{ .{ 2, 4 }, .{ 7, 9 } });
    var defs: pp.Defs = .empty;
    try defs.put(a, "dbg", .{ .value = "" });
    try expectSkips(try testSkips(a, &lines, false, &defs), &.{ .{ 2, 4 }, .{ 9, 11 } });
    try testing.expect((try branchSkips(a, lines[11..], false, null, &.{})) == null);
}

test "DEFINE, UNDEFINE, nesting and ELSEIF" {
    const lines = [_][]const u8{
        "!DEC$ DEFINE X", // 0
        "!DEC$ IF DEFINED(X)", // 1
        "  a = 1",
        "!DEC$ ENDIF", // 3
        "!DEC$ UNDEFINE X", // 4
        "!DEC$ IF DEFINED(X)", // 5
        "  !DEC$ DEFINE Y", // 6: left out, defines nothing
        "!DEC$ ENDIF", // 7
        "!DEC$ DEFINE VER = 3", // 8
        "!DIR$ IF (VER .GE. 2 .AND. .NOT. DEFINED(OLD))", // 9
        "!DIR$   IF DEFINED(Y)", // 10
        "  b = 1",
        "!DIR$   ELSEIF (VER == 3)", // 12
        "  b = 2",
        "!DIR$   ELSE", // 14
        "  b = 3",
        "!DIR$   ENDIF", // 16
        "!DIR$ ELSE", // 17
        "  c = 1",
        "!DIR$ ENDIF", // 19
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectSkips(try testSkips(arena.allocator(), &lines, false, null), &.{ .{ 6, 8 }, .{ 11, 13 }, .{ 15, 17 }, .{ 18, 20 } });
}

test "fixed form, and lines the C preprocessor leaves out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{
        "CDEC$ IF DEFINED(X)", // 0
        "      a = 1",
        "CDEC$ ELSE", // 2
        "      a = 2",
        "CDEC$ ENDIF", // 4
    };
    try expectSkips(try testSkips(a, &lines, true, null), &.{.{ 1, 3 }});
    const in_cpp = [_][]const u8{ "#if 0", lines[0], lines[1], lines[2], lines[3], lines[4], "#endif" };
    const cpp = [_]pp.Skip{.{ .start = 1, .end = 7 }};
    try testing.expect((try branchSkips(a, &in_cpp, true, null, &cpp)) == null);
}
