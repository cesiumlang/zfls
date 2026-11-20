//! Damaged source: what an editor sends while code is half typed. The
//! Fortran files of the test corpus (tests/fortran, tests/compiler,
//! tests/dap) are damaged in many ways, and an in-process server answers
//! the main requests on each version:
//!
//! - cut at the end of a line and at a column inside it;
//! - a line deleted or duplicated, two lines swapped;
//! - an END statement dropped (each one, then all of them);
//! - unbalanced parentheses, brackets and quotes inserted or removed;
//! - random bytes inserted, replaced or deleted (and, on disk, bytes that
//!   are not UTF-8, as in a Latin-1 file);
//! - mixed line endings (CRLF, lone CR, a byte order mark);
//! - fixed and free form mixed: lines of the other form inserted, and each
//!   file under a name of the other form.
//!
//! The requests (damaged_source/session.zig): diagnostics, document
//! symbols, folding ranges, semantic tokens, inlay hints, document links,
//! code lenses, code actions, inline values, form conversion and workspace
//! symbols on the document; hover, completion, signature help, definition,
//! references, highlights, selection ranges and code actions at the damage,
//! at the end of the text and at random places, with the rarer position
//! requests (rename, hierarchies, ...) by turns. Formatting is left out: it
//! runs an external formatter.
//!
//! A version fails on a crash (a Debug build traps overflows and
//! out-of-bounds accesses), an error answer, a leak (the testing allocator
//! reports it), a request that takes longer than `hang_s` (the watchdog
//! stops the run and says which), a result that cannot be written as JSON,
//! and a range or position in a result that is not inside its document.
//! What it found is under Regressions below, on fixed inputs.
//!
//! `zig build test` runs a seeded sample of the damage (every 20th line);
//! `zig build test-damaged` (`ZFLS_DAMAGE=long`) damages every line of every
//! file, at more places and with every request at each, in minutes.

const std = @import("std");
const zfls = @import("zfls");
const session = @import("damaged_source/session.zig");
const Allocator = std.mem.Allocator;
const gpa = std.testing.allocator;
const Session = session.Session;
const Pos = session.Pos;
const posAt = session.posAt;
const corpus = session.corpus;
const file_names = session.file_names;
const as_fixed = session.as_fixed;
const as_free = session.as_free;
const on_disk = session.on_disk;

// --------------------------------------------------------------------------
// Damage

/// Byte offsets of the starts of the lines of `text`, and its length
fn lineStarts(a: Allocator, text: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    try out.append(a, 0);
    for (text, 0..) |c, i| if (c == '\n') try out.append(a, i + 1);
    if (out.items[out.items.len - 1] != text.len) try out.append(a, text.len);
    return out.toOwnedSlice(a);
}

fn concat(a: Allocator, parts: []const []const u8) ![]const u8 {
    return std.mem.concat(a, u8, parts);
}

/// The lines damaged in a round: every `stride`-th, from a random first one
fn damagedLines(s: *Session, n: usize) struct { first: usize, stride: usize } {
    const stride = @min(s.b.stride, @max(n, 1));
    return .{ .first = s.rng.uintLessThan(usize, stride), .stride = stride };
}

/// Run `damage` on each corpus file in each round of the budget
fn eachFile(seed: u64, hierarchical: bool, comptime damage: anytype) !void {
    var prng: std.Random.DefaultPrng = undefined;
    var s = try Session.init(seed, &prng, hierarchical);
    defer s.deinit();
    for (0..s.b.rounds) |round| {
        prng = .init(seed +% round *% 0x9e3779b97f4a7c15);
        for (corpus, 0..) |c, i| {
            try damage(&s, i, c.text);
            try s.restore(i);
        }
    }
}

fn reset(s: *Session) Allocator {
    _ = s.arena.reset(.retain_capacity);
    return s.arena.allocator();
}

fn cut(s: *Session, i: usize, text: []const u8) !void {
    const starts = try lineStarts(gpa, text);
    defer gpa.free(starts);
    const d = damagedLines(s, starts.len - 1);
    var k = d.first;
    while (k + 1 < starts.len) : (k += d.stride) {
        // after the line, its end of line included
        _ = reset(s);
        try s.version(i, "cut after a line", text[0..starts[k + 1]], starts[k + 1]);
        // inside it
        const at = starts[k] + s.rng.uintLessThan(usize, starts[k + 1] - starts[k]);
        _ = reset(s);
        try s.version(i, "cut inside a line", text[0..at], at);
    }
}

fn lineEdits(s: *Session, i: usize, text: []const u8) !void {
    const starts = try lineStarts(gpa, text);
    defer gpa.free(starts);
    const n = starts.len - 1;
    const d = damagedLines(s, n);
    var k = d.first;
    while (k < n) : (k += d.stride) {
        const line = text[starts[k]..starts[k + 1]];
        var a = reset(s);
        try s.version(i, "a line deleted", try concat(a, &.{ text[0..starts[k]], text[starts[k + 1]..] }), starts[k]);
        a = reset(s);
        try s.version(i, "a line duplicated", try concat(a, &.{ text[0..starts[k + 1]], line, text[starts[k + 1]..] }), starts[k + 1]);
        const j = s.rng.uintLessThan(usize, n);
        if (j == k) continue;
        const lo = @min(j, k);
        const hi = @max(j, k);
        a = reset(s);
        try s.version(i, "two lines swapped", try concat(a, &.{
            text[0..starts[lo]],
            text[starts[hi]..starts[hi + 1]],
            text[starts[lo + 1]..starts[hi]],
            text[starts[lo]..starts[lo + 1]],
            text[starts[hi + 1]..],
        }), starts[lo]);
    }
}

/// Whether a line is an END statement (`end`, `end do`, `endif`, ...),
/// after a fixed-form label
fn isEnd(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t0123456789");
    if (t.len < 3 or !std.ascii.eqlIgnoreCase(t[0..3], "end")) return false;
    return t.len == 3 or !std.ascii.isAlphanumeric(t[3]) or std.ascii.isAlphabetic(t[3]);
}

fn dropEnds(s: *Session, i: usize, text: []const u8) !void {
    const starts = try lineStarts(gpa, text);
    defer gpa.free(starts);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    // every few of them (each one in the long run)
    const every = @max(s.b.stride / 4, 1);
    var n: usize = s.rng.uintLessThan(usize, every);
    for (0..starts.len - 1) |k| {
        const line = text[starts[k]..starts[k + 1]];
        if (!isEnd(line)) {
            try all.appendSlice(gpa, line);
            continue;
        }
        n += 1;
        if (n % every != 0) continue;
        const a = reset(s);
        try s.version(i, "an END statement dropped", try concat(a, &.{ text[0..starts[k]], text[starts[k + 1]..] }), starts[k]);
    }
    const a = reset(s);
    try s.version(i, "every END statement dropped", try a.dupe(u8, all.items), all.items.len);
}

const unbalanced = [_][]const u8{ "(", ")", "'", "\"", "[", "]", "(/", "/)", "&", "%", "=>", "::", ",", "!", ";", "&\n" };

fn unbalance(s: *Session, i: usize, text: []const u8) !void {
    const starts = try lineStarts(gpa, text);
    defer gpa.free(starts);
    const n = starts.len - 1;
    const d = damagedLines(s, n);
    var k = d.first;
    while (k < n) : (k += d.stride) {
        const at = starts[k] + s.rng.uintLessThan(usize, starts[k + 1] - starts[k]);
        const bit = unbalanced[s.rng.uintLessThan(usize, unbalanced.len)];
        var a = reset(s);
        try s.version(i, "a parenthesis or quote inserted", try concat(a, &.{ text[0..at], bit, text[at..] }), at);
        // one of the line's own taken out
        const line = text[starts[k]..starts[k + 1]];
        if (std.mem.findAny(u8, line, "()[]'\"")) |first| {
            var off = first;
            var tries: usize = 0;
            while (tries < 4) : (tries += 1) {
                const o = s.rng.uintLessThan(usize, line.len);
                if (std.mem.findScalar(u8, "()[]'\"", line[o]) != null) {
                    off = o;
                    break;
                }
            }
            a = reset(s);
            const p = starts[k] + off;
            try s.version(i, "a parenthesis or quote removed", try concat(a, &.{ text[0..p], text[p + 1 ..] }), p);
        }
    }
}

/// Bytes a random edit uses more often than others
const special_bytes = "\x00\r\n\t&!;#'\"()%\xff\xc3\xa9\xe2\x82\xac\xf0\x9f";

fn randomBytes(s: *Session, i: usize, text: []const u8) !void {
    for (0..s.b.byte_versions) |_| {
        const a = reset(s);
        var cur: std.ArrayList(u8) = .empty;
        try cur.appendSlice(a, text);
        var site: usize = 0;
        for (0..s.rng.intRangeAtMost(usize, 1, 4)) |_| {
            const at = s.rng.uintAtMost(usize, cur.items.len);
            const byte = if (s.rng.boolean()) special_bytes[s.rng.uintLessThan(usize, special_bytes.len)] else s.rng.int(u8);
            switch (s.rng.uintLessThan(u8, 3)) {
                0 => try cur.insert(a, at, byte),
                1 => if (at < cur.items.len) {
                    cur.items[at] = byte;
                },
                else => if (at < cur.items.len) {
                    _ = cur.orderedRemove(at);
                },
            }
            site = at;
        }
        try s.version(i, "random bytes", cur.items, site);
    }
    // a file on disk in Latin-1, é and ü as single bytes in a comment
    try s.restore(i);
    const a = reset(s);
    var latin: std.ArrayList(u8) = .empty;
    const starts = try lineStarts(a, text);
    const k = s.rng.uintLessThan(usize, starts.len - 1);
    try latin.appendSlice(a, text[0..starts[k]]);
    try latin.appendSlice(a, "! caf\xe9 \xfcber\n");
    try latin.appendSlice(a, text[starts[k]..]);
    try s.version(on_disk, "Latin-1 bytes on disk", latin.items, starts[k]);
    try s.restore(on_disk);
}

fn lineEndings(s: *Session, i: usize, text: []const u8) !void {
    const Kind = enum { crlf, cr, mixed, stray_cr, bom, no_final_newline };
    for ([_]Kind{ .crlf, .cr, .mixed, .stray_cr, .bom, .no_final_newline }, 0..) |kind, k| {
        // half of them in the sample, by turns
        if (!s.b.all_requests and (k + i) % 2 == 0) continue;
        const a = reset(s);
        var out: std.ArrayList(u8) = .empty;
        if (kind == .bom) try out.appendSlice(a, "\xef\xbb\xbf");
        var site: usize = 0;
        for (text, 0..) |c, at| {
            if (c != '\n') {
                if (kind == .stray_cr and s.rng.uintLessThan(u8, 40) == 0) {
                    try out.append(a, '\r');
                    site = out.items.len;
                }
                try out.append(a, c);
                continue;
            }
            switch (kind) {
                .crlf => try out.appendSlice(a, "\r\n"),
                .cr => try out.append(a, '\r'),
                .mixed => try out.appendSlice(a, switch (s.rng.uintLessThan(u8, 3)) {
                    0 => "\n",
                    1 => "\r\n",
                    else => "\r",
                }),
                .no_final_newline => if (at + 1 < text.len) try out.append(a, '\n'),
                else => try out.append(a, '\n'),
            }
        }
        try s.version(i, @tagName(kind), out.items, site);
    }
}

/// Lines of fixed form put into free-form files, and the other way round
const fixed_lines = [_][]const u8{
    "C     a comment in column 1\n",
    "*     another one\n",
    "     &  continued, x)\n",
    "   10 CONTINUE\n",
    "\tX = 1\n",
    "      X = 1                                                             IGNORED PAST COLUMN 72\n",
    "     $   CALL FOO(N)\n",
    "D     PRINT *, X\n",
};
/// A line longer than free form's 132 columns
const long_line = blk: {
    var line: []const u8 = "y = 'a long string ";
    for (0..150) |_| line = line ++ "x";
    break :blk line ++ "'\n";
};
const free_lines = [_][]const u8{
    "x = 1 &\n",
    "  if (x > 0) then ! free form\n",
    "      call foo(a, &\n",
    "   & b)\n",
    "!$omp parallel\n",
    long_line,
    "end subroutine saxpy\n",
    "  integer :: i; real :: r ! two statements\n",
};

fn mixForms(s: *Session, i: usize, text: []const u8) !void {
    const fixed = zfls.suffixes.formOf(file_names[i]) == .fixed;
    // the whole file under a name of the other form
    var a = reset(s);
    const other: usize = if (fixed) as_free else as_fixed;
    try s.version(other, "under a name of the other form", try a.dupe(u8, text), 0);
    try s.restore(other);
    // lines of the other form inserted
    const starts = try lineStarts(gpa, text);
    defer gpa.free(starts);
    const n = starts.len - 1;
    const d = damagedLines(s, n);
    var k = d.first;
    while (k <= n) : (k += d.stride) {
        const pool: []const []const u8 = if (fixed) &free_lines else &fixed_lines;
        a = reset(s);
        try s.version(i, "a line of the other form", try concat(a, &.{ text[0..starts[k]], pool[s.rng.uintLessThan(usize, pool.len)], text[starts[k]..] }), starts[k]);
    }
}

// --------------------------------------------------------------------------
// Tests

test "damaged source: cut at the end of a line and inside it" {
    try eachFile(0x224_01, false, cut);
}

test "damaged source: lines deleted, duplicated and swapped" {
    try eachFile(0x224_02, true, lineEdits);
}

test "damaged source: END statements dropped" {
    try eachFile(0x224_03, false, dropEnds);
}

test "damaged source: unbalanced parentheses, brackets and quotes" {
    try eachFile(0x224_04, true, unbalance);
}

test "damaged source: random bytes" {
    try eachFile(0x224_05, false, randomBytes);
}

test "damaged source: mixed line endings and a byte order mark" {
    try eachFile(0x224_06, true, lineEndings);
}

test "damaged source: fixed and free form mixed" {
    try eachFile(0x224_07, false, mixForms);
}

// --------------------------------------------------------------------------
// Regressions: what the damage found, each on a fixed input

/// Every request on `text` as a free-form file, at the end of the first
/// `at` in it, the end of the text and one more place
fn regression(text: []const u8, at: []const u8) !void {
    var prng: std.Random.DefaultPrng = undefined;
    var s = try Session.init(0x224, &prng, false);
    defer s.deinit();
    s.b.all_requests = true;
    const site = (std.mem.find(u8, text, at) orelse return error.TestBug) + at.len;
    try s.version(as_free, "a regression", text, site);
}

test "regression: selection ranges of a scope that ends on an empty last line" {
    // the end of the scope on the empty line took the column of its start
    try regression("module m\ncontains\n  subroutine s\n", "subroutine s\n");
}

test "regression: selection range in a comment with a parenthesis" {
    // the parentheses of the comment were searched past the end of the code
    try regression("program p\n  x = 1 ! see (a, the comment\nend program p\n", "the com");
}

test "regression: references to an intrinsic procedure" {
    // an error answer (fortls's AttributeError); none now
    try regression("program p\n  real :: x\n  x = sqrt(2.0)\nend program p\n", "sqr");
}

test "regression: a new submodule after the last line, which has no line break" {
    try regression("module m\n  interface\n    module subroutine foo()\n    end subroutine foo\n  end interface\nend module m", "module subroutine foo");
}

test "regression: IMPLICIT NONE after a unit's first line, the last of the file" {
    try regression("! c\nmodule s", "module s");
}

test "regression: removing an unused declaration on the last line" {
    try regression("subroutine s\n  integer :: sel", ":: sel");
}

test "regression: go to definition on the file name of an INCLUDE statement" {
    // it was the included file at the line of the INCLUDE statement, which
    // the included file may not have
    try regression("program p\n  implicit none\n  include 'consts.inc'\n  print *, included_n\nend program p\n", "'cons");
}

test "regression: extracting a PRINT statement without its output list" {
    // the list after the format was sliced past the end of the statement
    try regression("program p\n  integer :: x\n  print *\n  x = 1\nend program p\n", "print *");
}

test posAt {
    try std.testing.expectEqual(Pos{ .line = 0, .character = 0 }, posAt("ab\ncd", 0));
    try std.testing.expectEqual(Pos{ .line = 1, .character = 1 }, posAt("ab\ncd", 4));
    try std.testing.expectEqual(Pos{ .line = 1, .character = 0 }, posAt("ab\r\ncd", 4));
    try std.testing.expectEqual(Pos{ .line = 0, .character = 2 }, posAt("ab\r\ncd", 3));
    try std.testing.expectEqual(Pos{ .line = 2, .character = 0 }, posAt("a\rb\r", 4));
    try std.testing.expectEqual(Pos{ .line = 0, .character = 3 }, posAt("\xc3\xa9\xf0\x9f\x98\x80", 6));
}

test isEnd {
    try std.testing.expect(isEnd("  end subroutine run\n"));
    try std.testing.expect(isEnd("   10 END\n"));
    try std.testing.expect(isEnd("enddo"));
    try std.testing.expect(!isEnd("  x = end_value\n"));
}
