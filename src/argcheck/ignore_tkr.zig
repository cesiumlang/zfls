//! Part of the argument checks (argcheck.zig): LLVM Flang's and
//! nvfortran's `!dir$ ignore_tkr [[(tkrdmac)] name], ...` in a
//! procedure's specification part, which exempts the dummy arguments it
//! names (all of them when it names none) from the checks of type (`t`),
//! kind (`k`) and rank (`r`) of their actual arguments; `a` is all of
//! them, and no letters are all of them too. `d`, `m` and `c` (CUDA's
//! device and managed, contiguity) are no checks of zfls's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const FortranFile = @import("../parser.zig").FortranFile;

/// The checks that a directive leaves out for a dummy argument
pub const Ignored = struct {
    type: bool = false,
    kind: bool = false,
    rank: bool = false,

    pub const all: Ignored = .{ .type = true, .kind = true, .rank = true };

    fn merge(x: Ignored, y: Ignored) Ignored {
        return .{ .type = x.type or y.type, .kind = x.kind or y.kind, .rank = x.rank or y.rank };
    }
};

/// A dummy argument a directive names (null: every one), and what it
/// leaves out for it
pub const Entry = struct {
    name: ?[]const u8,
    ignored: Ignored,
};

/// The entries of line `line` if it is an `ignore_tkr` directive: `!dir$`
/// (also `!pgi$`, nvfortran's older sentinel) in any case; in fixed form
/// also `c` or `*` in column 1. Appended to `out`; false if it is none.
pub fn parse(a: Allocator, fixed: bool, line: []const u8, out: *std.ArrayList(Entry)) !bool {
    var rest = std.mem.trimStart(u8, line, " \t");
    if (rest.len == 0) return false;
    const marker_ok = rest[0] == '!' or (fixed and rest.len == line.len and (rest[0] == 'c' or rest[0] == 'C' or rest[0] == '*'));
    if (!marker_ok) return false;
    rest = rest[1..];
    if (rest.len < 4 or !(std.ascii.startsWithIgnoreCase(rest, "dir$") or std.ascii.startsWithIgnoreCase(rest, "pgi$"))) return false;
    rest = std.mem.trimStart(u8, rest[4..], " \t");
    const word = "ignore_tkr";
    if (!std.ascii.startsWithIgnoreCase(rest, word)) return false;
    rest = rest[word.len..];
    if (rest.len > 0 and (std.ascii.isAlphanumeric(rest[0]) or rest[0] == '_')) return false;
    // a comment after it
    if (std.mem.findScalar(u8, rest, '!')) |i| rest = rest[0..i];
    rest = std.mem.trim(u8, rest, " \t\r");
    if (rest.len == 0) {
        try out.append(a, .{ .name = null, .ignored = .all });
        return true;
    }
    var items = std.mem.splitScalar(u8, rest, ',');
    while (items.next()) |raw| {
        var item = std.mem.trim(u8, raw, " \t");
        var ignored: Ignored = .all;
        if (item.len > 0 and item[0] == '(') {
            const close = std.mem.findScalar(u8, item, ')') orelse return true;
            ignored = letters(item[1..close]);
            item = std.mem.trim(u8, item[close + 1 ..], " \t");
        }
        try out.append(a, .{ .name = if (item.len > 0) item else null, .ignored = ignored });
    }
    return true;
}

/// The checks of the letters of a directive (`tkr`); none: all of them
fn letters(text: []const u8) Ignored {
    var out: Ignored = .{};
    var seen = false;
    for (text) |ch| switch (std.ascii.toLower(ch)) {
        't' => out.type = true,
        'k' => out.kind = true,
        'r' => out.rank = true,
        'a' => return .all,
        'd', 'm', 'c' => seen = true,
        else => {},
    };
    if (out.type or out.kind or out.rank) return out;
    return if (seen) out else .all;
}

/// The directives of a procedure whose first line is `sline` and last
/// `eline` (1-based) in `f`: those of its own specification part, not of
/// the interface bodies in it, nor of the procedures after its CONTAINS
pub fn ofProcedure(a: Allocator, f: *const FortranFile, sline: usize, eline: usize) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    if (sline == 0) return out.items;
    var depth: usize = 0;
    var ln = sline;
    const end = @min(if (eline > sline) eline else f.nLines(), f.nLines());
    while (ln < end) : (ln += 1) {
        const text = f.getLine(ln, false) orelse break;
        const before = out.items.len;
        if (try parse(a, f.fixed, text, &out)) {
            // of an interface body in it: not its own
            if (depth > 0) out.shrinkRetainingCapacity(before);
            continue;
        }
        const code = std.mem.trim(u8, if (f.fixed and text.len > 6) text[6..] else text, " \t\r");
        if (startsWord(code, "contains") and depth == 0) break;
        if (startsWord(code, "interface") or startsWord(code, "abstract")) depth += 1;
        if (startsWord(code, "endinterface") or (startsWord(code, "end") and startsWord(std.mem.trimStart(u8, code[3..], " \t"), "interface"))) depth -|= 1;
    }
    return out.items;
}

fn startsWord(code: []const u8, word: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(code, word)) return false;
    return code.len == word.len or !(std.ascii.isAlphanumeric(code[word.len]) or code[word.len] == '_');
}

/// What `entries` leave out for dummy argument `name`
pub fn of(entries: []const Entry, name: []const u8) Ignored {
    var out: Ignored = .{};
    for (entries) |e| {
        if (e.name == null or std.ascii.eqlIgnoreCase(e.name.?, name)) out = out.merge(e.ignored);
    }
    return out;
}

test "the directive's dummy arguments and checks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Entry) = .empty;
    try std.testing.expect(try parse(a, false, "  !dir$ ignore_tkr a", &out));
    try std.testing.expectEqualStrings("a", out.items[0].name.?);
    try std.testing.expectEqual(Ignored.all, out.items[0].ignored);
    out.clearRetainingCapacity();
    try std.testing.expect(try parse(a, false, "!DIR$ IGNORE_TKR (TK) b, (r) c, d ! why", &out));
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(Ignored{ .type = true, .kind = true }, of(out.items, "B"));
    try std.testing.expectEqual(Ignored{ .rank = true }, of(out.items, "c"));
    try std.testing.expectEqual(Ignored.all, of(out.items, "d"));
    try std.testing.expectEqual(Ignored{}, of(out.items, "e"));
    out.clearRetainingCapacity();
    // CUDA's device and managed only: none of zfls's checks
    try std.testing.expect(try parse(a, false, "!dir$ ignore_tkr (dm) x", &out));
    try std.testing.expectEqual(Ignored{}, of(out.items, "x"));
    out.clearRetainingCapacity();
    try std.testing.expect(try parse(a, false, "!dir$ ignore_tkr (a) x", &out));
    try std.testing.expectEqual(Ignored.all, of(out.items, "x"));
    out.clearRetainingCapacity();
    // no names: every dummy argument
    try std.testing.expect(try parse(a, false, "!pgi$ ignore_tkr", &out));
    try std.testing.expectEqual(Ignored.all, of(out.items, "anything"));
    out.clearRetainingCapacity();
    // fixed form
    try std.testing.expect(try parse(a, true, "cdir$ ignore_tkr q", &out));
    try std.testing.expect(try parse(a, true, "*DIR$ IGNORE_TKR r", &out));
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // none
    try std.testing.expect(!try parse(a, true, "  cdir$ ignore_tkr q", &out));
    try std.testing.expect(!try parse(a, false, "cdir$ ignore_tkr q", &out));
    try std.testing.expect(!try parse(a, false, "! dir$ ignore_tkr q", &out));
    try std.testing.expect(!try parse(a, false, "!dir$ ignore_tkrx q", &out));
    try std.testing.expect(!try parse(a, false, "!dir$ ivdep", &out));
    try std.testing.expect(!try parse(a, false, "call s(a) ! ignore_tkr", &out));
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}
