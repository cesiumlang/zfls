//! The edits that turn a text into a formatter's output: the blocks of
//! changed lines (Myers's diff), and the smallest edit within each, so that
//! the lines a formatter did not change keep their exact text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");
const str = @import("../str.zig");

pub const Diff = struct { start: usize, end: usize, text: []const u8 };

/// The smallest replacement that turns `before` into `after`: the bytes
/// from `start` up to `end` of `before` are replaced by `text`. Null when
/// nothing changes. Text the formatter left alone is not touched, so the
/// cursor, folding and markers there stay put.
pub fn textDiff(before: []const u8, after: []const u8) ?Diff {
    if (std.mem.eql(u8, before, after)) return null;
    var start: usize = 0;
    const shorter = @min(before.len, after.len);
    while (start < shorter and before[start] == after[start]) start += 1;
    var end_before = before.len;
    var end_after = after.len;
    while (end_before > start and end_after > start and before[end_before - 1] == after[end_after - 1]) {
        end_before -= 1;
        end_after -= 1;
    }
    // not inside a UTF-8 sequence (the bytes before `start` and from
    // `end_before` on are the same in both)
    while (start > 0 and (isContinuation(before, start) or isContinuation(after, start))) start -= 1;
    while (end_before < before.len and isContinuation(before, end_before)) {
        end_before += 1;
        end_after += 1;
    }
    return .{ .start = start, .end = end_before, .text = after[start..end_after] };
}

fn isContinuation(s: []const u8, i: usize) bool {
    return i < s.len and s[i] & 0xc0 == 0x80;
}

/// Lines `old_start..old_end` of the old lines that become lines
/// `new_start..new_end` of the new ones (either range may be empty)
pub const Block = struct { old_start: usize, old_end: usize, new_start: usize, new_end: usize };

/// The blocks of changed lines between `old` and `new`, in order: the lines
/// between them are the same in both (a longest common subsequence, by
/// Myers's diff)
pub fn lineBlocks(a: Allocator, old: []const []const u8, new: []const []const u8) ![]const Block {
    // the common head and tail first: most of a file, often
    var head: usize = 0;
    while (head < old.len and head < new.len and std.mem.eql(u8, old[head], new[head])) head += 1;
    var tail: usize = 0;
    while (tail < old.len - head and tail < new.len - head and std.mem.eql(u8, old[old.len - 1 - tail], new[new.len - 1 - tail])) tail += 1;
    const e = old[head .. old.len - tail];
    const f = new[head .. new.len - tail];
    const e_changed = try a.alloc(bool, e.len);
    const f_changed = try a.alloc(bool, f.len);
    // a line that the other side does not have is changed: only the others
    // go to the diff, whose longest common subsequence is the same (a
    // reindented file has few lines left)
    const e_hash = try hashes(a, e);
    const f_hash = try hashes(a, f);
    const e_keep = try sharedLines(a, e_hash, f_hash);
    const f_keep = try sharedLines(a, f_hash, e_hash);
    var m: Myers = .{
        .e = try pick([]const u8, a, e, e_keep),
        .f = try pick([]const u8, a, f, f_keep),
        .e_hash = try pick(u64, a, e_hash, e_keep),
        .f_hash = try pick(u64, a, f_hash, f_keep),
        .e_changed = try a.alloc(bool, e_keep.len),
        .f_changed = try a.alloc(bool, f_keep.len),
        .g = try a.alloc(isize, 2 * @min(e_keep.len, f_keep.len) + 2),
        .p = try a.alloc(isize, 2 * @min(e_keep.len, f_keep.len) + 2),
    };
    @memset(m.e_changed, false);
    @memset(m.f_changed, false);
    m.diff(0, m.e.len, 0, m.f.len);
    @memset(e_changed, true);
    @memset(f_changed, true);
    for (e_keep, m.e_changed) |k, c| e_changed[k] = c;
    for (f_keep, m.f_changed) |k, c| f_changed[k] = c;

    // the unchanged lines of both pair up in order; the changed ones
    // between two pairs make a block
    var blocks: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < e.len or j < f.len) {
        if (i < e.len and j < f.len and !e_changed[i] and !f_changed[j]) {
            i += 1;
            j += 1;
            continue;
        }
        const old_from = i;
        const new_from = j;
        while (i < e.len and e_changed[i]) i += 1;
        while (j < f.len and f_changed[j]) j += 1;
        try blocks.append(a, .{ .old_start = head + old_from, .old_end = head + i, .new_start = head + new_from, .new_end = head + j });
    }
    return blocks.items;
}

/// The indices of the lines (by their hashes) that `other` may have
fn sharedLines(a: Allocator, mine: []const u64, other: []const u64) ![]const usize {
    var set: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (other) |h| try set.put(a, h, {});
    var out: std.ArrayList(usize) = .empty;
    for (mine, 0..) |h, i| if (set.contains(h)) try out.append(a, i);
    return out.items;
}

fn pick(comptime T: type, a: Allocator, xs: []const T, indices: []const usize) ![]const T {
    const out = try a.alloc(T, indices.len);
    for (indices, out) |i, *o| o.* = xs[i];
    return out;
}

fn hashes(a: Allocator, lines: []const []const u8) ![]const u64 {
    const out = try a.alloc(u64, lines.len);
    for (lines, out) |l, *h| h.* = std.hash.Wyhash.hash(0, l);
    return out;
}

/// Myers's O((N+M)D) diff in linear space (the middle snake, recursively),
/// marking the lines of `e` deleted and those of `f` inserted
const Myers = struct {
    e: []const []const u8,
    f: []const []const u8,
    /// The hash of each line, compared first
    e_hash: []const u64,
    f_hash: []const u64,
    e_changed: []bool,
    f_changed: []bool,
    /// The furthest x of each diagonal, forward and backward; each call
    /// uses the start of them (no call needs them after its own ones)
    g: []isize,
    p: []isize,

    /// Marks the changes between `e[i..][0..n]` and `f[j..][0..mm]`
    fn diff(m: *Myers, i: usize, n: usize, j: usize, mm: usize) void {
        if (n == 0) return @memset(m.f_changed[j..][0..mm], true);
        if (mm == 0) return @memset(m.e_changed[i..][0..n], true);
        const N: isize = @intCast(n);
        const M: isize = @intCast(mm);
        const L = N + M;
        const z: usize = 2 * @min(n, mm) + 2;
        const Z: isize = @intCast(z);
        const w = N - M;
        @memset(m.g[0..z], 0);
        @memset(m.p[0..z], 0);
        var h: isize = 0;
        while (h <= @divFloor(L, 2) + @mod(L, 2)) : (h += 1) {
            for (0..2) |r| {
                // forward on the lines as they are, then backward from the
                // ends
                const c = if (r == 0) m.g else m.p;
                const d = if (r == 0) m.p else m.g;
                const o: isize = if (r == 0) 1 else 0;
                var k = -(h - 2 * @max(0, h - M));
                while (k <= h - 2 * @max(0, h - N)) : (k += 2) {
                    var x = if (k == -h or (k != h and c[at(k - 1, Z)] < c[at(k + 1, Z)])) c[at(k + 1, Z)] else c[at(k - 1, Z)] + 1;
                    var y = x - k;
                    const s = x;
                    const t = y;
                    while (x < N and y < M and m.same(i, N, x, j, M, y, o == 1)) {
                        x += 1;
                        y += 1;
                    }
                    c[at(k, Z)] = x;
                    const zk = w - k;
                    if (@mod(L, 2) == o and zk >= -(h - o) and zk <= h - o and c[at(k, Z)] + d[at(zk, Z)] >= N) {
                        // the middle snake, from (x0, y0) to (u, v)
                        const D = if (o == 1) 2 * h - 1 else 2 * h;
                        const x0: usize = @intCast(if (o == 1) s else N - x);
                        const y0: usize = @intCast(if (o == 1) t else M - y);
                        const u: usize = @intCast(if (o == 1) x else N - s);
                        const v: usize = @intCast(if (o == 1) y else M - t);
                        if (D > 1 or (x0 != u and y0 != v)) {
                            m.diff(i, x0, j, y0);
                            m.diff(i + u, n - u, j + v, mm - v);
                        } else if (mm > n) {
                            m.diff(i + n, 0, j + n, mm - n);
                        } else if (mm < n) {
                            m.diff(i + mm, n - mm, j + mm, 0);
                        }
                        return;
                    }
                }
            }
        }
        // not reached: the paths meet by h = ceil((N + M) / 2)
        @memset(m.e_changed[i..][0..n], true);
        @memset(m.f_changed[j..][0..mm], true);
    }

    /// Whether line `x` of `e[i..][0..N]` and line `y` of `f[j..][0..M]`
    /// are the same, counted from the starts or (backward) from the ends
    fn same(m: *const Myers, i: usize, N: isize, x: isize, j: usize, M: isize, y: isize, forward: bool) bool {
        const xe: usize = @intCast(if (forward) x else N - x - 1);
        const yf: usize = @intCast(if (forward) y else M - y - 1);
        return m.e_hash[i + xe] == m.f_hash[j + yf] and std.mem.eql(u8, m.e[i + xe], m.f[j + yf]);
    }

    fn at(k: isize, Z: isize) usize {
        return @intCast(@mod(k, Z));
    }
};

/// The edits that turn `old` (the lines from line `first` on) into `new`:
/// one for each block of changed lines, the smallest within it. Lines the
/// formatter did not change are in no edit, so they keep their exact text
/// (a tab that zfls reads as a space, too).
pub fn lineEdits(a: Allocator, old: []const []const u8, new: []const []const u8, first: usize) ![]const lsp.TextEdit {
    const before = try std.mem.join(a, "\n", old);
    const after = try std.mem.join(a, "\n", new);
    const old_starts = try lineStarts(a, old);
    const new_starts = try lineStarts(a, new);
    var edits: std.ArrayList(lsp.TextEdit) = .empty;
    for (try lineBlocks(a, old, new)) |b| {
        // the lines of the block with their line breaks: the one after
        // each, or for a block at the end, the one before it
        var base_line = b.old_start;
        var old_from = old_starts[b.old_start];
        var old_to = old_starts[b.old_end];
        var new_from = new_starts[b.new_start];
        var new_to = new_starts[b.new_end];
        if (b.old_end == old.len) {
            old_to = before.len;
            new_to = after.len;
            if (b.old_start > 0) {
                base_line -= 1;
                old_from -= 1;
                new_from -= 1;
            }
        }
        const d = textDiff(before[old_from..old_to], after[new_from..new_to]) orelse continue;
        // positions counted from the start of the block's first line
        const line_start = old_starts[base_line];
        const text = before[line_start..];
        try edits.append(a, .{
            .range = .{
                .start = positionAt(text, first + base_line, old_from - line_start + d.start),
                .end = positionAt(text, first + base_line, old_from - line_start + d.end),
            },
            .newText = d.text,
        });
    }
    return edits.items;
}

/// `old` with the formatter's changes `new` taken in lines `first` to `last`
/// only (a selection's whole lines, of a tool that formats whole files):
/// a block of changed lines that has as many lines in both is taken line by
/// line; another one when it lies in the selection
pub fn takeWithin(a: Allocator, old: []const []const u8, new: []const []const u8, first: usize, last: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    for (try lineBlocks(a, old, new)) |b| {
        try out.appendSlice(a, old[at..b.old_start]);
        at = b.old_end;
        if (b.old_end - b.old_start == b.new_end - b.new_start) {
            for (b.old_start..b.old_end, b.new_start..) |i, j| try out.append(a, if (i >= first and i <= last) new[j] else old[i]);
        } else if (b.old_start >= first and b.old_end <= last + 1) {
            try out.appendSlice(a, new[b.new_start..b.new_end]);
        } else try out.appendSlice(a, old[b.old_start..b.old_end]);
    }
    try out.appendSlice(a, old[at..]);
    return out.items;
}

/// The offset of each line in the lines joined by `\n`, and one past the
/// last line (its end and a line break)
fn lineStarts(a: Allocator, lines: []const []const u8) ![]const usize {
    const starts = try a.alloc(usize, lines.len + 1);
    var at: usize = 0;
    for (lines, 0..) |l, i| {
        starts[i] = at;
        at += l.len + 1;
    }
    starts[lines.len] = at;
    return starts;
}

/// The LSP position of byte `offset` of `text` (lines joined by `\n`, the
/// first being line `first`)
fn positionAt(text: []const u8, first: usize, offset: usize) lsp.Position {
    const head = text[0..offset];
    const line_start = if (std.mem.findScalarLast(u8, head, '\n')) |i| i + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
    return .{
        .line = first + std.mem.count(u8, head, "\n"),
        .character = str.byteToUtf16(text[line_start..line_end], offset - line_start),
    };
}

// --------------------------------------------------------------------------

const testing = std.testing;

fn expectDiff(start: usize, end: usize, text: []const u8, diff: ?Diff) !void {
    const d = diff orelse return error.TestExpectedDiff;
    try testing.expectEqual(start, d.start);
    try testing.expectEqual(end, d.end);
    try testing.expectEqualStrings(text, d.text);
}

test "the edit is the changed part only" {
    try testing.expectEqual(@as(?Diff, null), textDiff("abc", "abc"));
    try expectDiff(4, 6, "   y = ", textDiff("x=1\ny=2\nz=3", "x=1\n   y = 2\nz=3"));
    try expectDiff(3, 3, "\nc", textDiff("a\nb", "a\nb\nc"));
    try expectDiff(2, 4, "", textDiff("a\nb\nc", "a\nc"));
    try expectDiff(2, 3, "", textDiff("aaa", "aa"));
}

test "the edit does not split a UTF-8 sequence" {
    // U+1F600 and U+1F601 share their first three bytes
    try expectDiff(2, 6, "\u{1F601}", textDiff("! \u{1F600}", "! \u{1F601}"));
    // é (C3 A9) and è (C3 A8) differ in their last byte; both are followed
    // by the same bytes
    try expectDiff(2, 4, "\u{E8}", textDiff("! \u{E9}x", "! \u{E8}x"));
    // é (C3 A9) and © (C2 A9) share their last byte
    try expectDiff(0, 2, "\u{A9}", textDiff("\u{E9}", "\u{A9}"));
}

/// `old` (lines from line 0) with `edits` applied, joined by `\n`
fn applyEdits(a: Allocator, old: []const []const u8, edits: []const lsp.TextEdit) ![]const u8 {
    const text = try std.mem.join(a, "\n", old);
    const starts = try lineStarts(a, old);
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (edits) |e| {
        const from = starts[e.range.start.line] + str.utf16ToByte(old[e.range.start.line], e.range.start.character);
        const to = starts[e.range.end.line] + str.utf16ToByte(old[e.range.end.line], e.range.end.character);
        // in order, without overlaps
        try testing.expect(from >= at and to >= from);
        try out.appendSlice(a, text[at..from]);
        try out.appendSlice(a, e.newText);
        at = to;
    }
    try out.appendSlice(a, text[at..]);
    return out.items;
}

test "an unchanged line between changed ones is in no edit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the formatter changes the lines around one that it leaves alone, a
    // tab in a string in it
    const old = [_][]const u8{ "program p", "x=1", "s = 'a\tb'", "y=2", "end" };
    const new = [_][]const u8{ "program p", "  x = 1", "s = 'a\tb'", "  y = 2", "end" };
    const edits = try lineEdits(a, &old, &new, 0);
    try testing.expectEqual(@as(usize, 2), edits.len);
    for (edits) |e| {
        // line 2 is neither in an edit nor at its edges
        try testing.expect(e.range.end.line < 2 or e.range.start.line > 2);
    }
    // the smallest edit of the line: `x=` becomes `  x = `
    try testing.expectEqual(lsp.Range{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 2 } }, edits[0].range);
    try testing.expectEqualStrings("  x = ", edits[0].newText);
    try testing.expectEqualStrings(try std.mem.join(a, "\n", &new), try applyEdits(a, &old, edits));
}

test "line edits: insertions, deletions, the first and last lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const []const u8{
        .{ &.{ "a", "b" }, &.{ "a", "b", "c" } },
        .{ &.{ "a", "b", "c" }, &.{ "a", "b" } },
        .{ &.{ "a", "b" }, &.{ "z", "a", "b" } },
        .{ &.{ "z", "a", "b" }, &.{ "a", "b" } },
        .{ &.{ "a", "b", "c" }, &.{ "a", "x", "y", "c" } },
        .{ &.{ "a", "b", "c" }, &.{"q"} },
        .{ &.{"a"}, &.{""} },
        .{ &.{""}, &.{ "a", "b" } },
        .{ &.{ "a", "b", "a", "b" }, &.{ "b", "a", "b", "a" } },
    };
    for (cases) |c| {
        const edits = try lineEdits(a, c[0], c[1], 0);
        try testing.expectEqualStrings(try std.mem.join(a, "\n", c[1]), try applyEdits(a, c[0], edits));
    }
    // a selection: positions from its first line
    const edits = try lineEdits(a, &.{ "a", "b" }, &.{ "a", " b" }, 7);
    try testing.expectEqual(lsp.Position{ .line = 8, .character = 0 }, edits[0].range.start);
}

/// The length of a longest common subsequence of `x` and `y`
fn lcsLength(a: Allocator, x: []const []const u8, y: []const []const u8) !usize {
    const row = try a.alloc(usize, (x.len + 1) * (y.len + 1));
    @memset(row, 0);
    const w = y.len + 1;
    for (x, 0..) |xi, i| for (y, 0..) |yj, j| {
        row[(i + 1) * w + j + 1] = if (std.mem.eql(u8, xi, yj)) row[i * w + j] + 1 else @max(row[i * w + j + 1], row[(i + 1) * w + j]);
    };
    return row[x.len * w + y.len];
}

test "line blocks keep a longest common subsequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    const words = [_][]const u8{ "a", "b", "c", "d" };
    for (0..2000) |_| {
        const old = try a.alloc([]const u8, r.intRangeAtMost(usize, 1, 12));
        const new = try a.alloc([]const u8, r.intRangeAtMost(usize, 1, 12));
        for (old) |*l| l.* = words[r.uintLessThan(usize, words.len)];
        for (new) |*l| l.* = words[r.uintLessThan(usize, words.len)];
        var kept = old.len;
        for (try lineBlocks(a, old, new)) |b| kept -= b.old_end - b.old_start;
        try testing.expectEqual(try lcsLength(a, old, new), kept);
        try testing.expectEqualStrings(try std.mem.join(a, "\n", new), try applyEdits(a, old, try lineEdits(a, old, new, 0)));
    }
}

test "edit positions are LSP positions" {
    const text = "x=1\n  \u{E9}=2";
    const p = positionAt(text, 10, 8);
    try testing.expectEqual(@as(usize, 11), p.line);
    // two spaces and é: 3 UTF-16 units for 4 bytes
    try testing.expectEqual(@as(usize, 3), p.character);
    try testing.expectEqual(lsp.Position{ .line = 10, .character = 0 }, positionAt(text, 10, 0));
}

test "a whole file's changes, taken in a selection's lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{ "a", "b", "c", "d", "e" };
    const new = [_][]const u8{ "A", "B", "C", "D", "E" };
    const merged = try takeWithin(a, &old, &new, 1, 2);
    try testing.expectEqualStrings("a,B,C,d,e", try std.mem.join(a, ",", merged));
    // a block of another length: only inside the selection
    const grown = [_][]const u8{ "a", "b", "x", "y", "c", "d", "e" };
    try testing.expectEqualStrings("a,b,c,d,e", try std.mem.join(a, ",", try takeWithin(a, &old, &grown, 0, 0)));
    try testing.expectEqualStrings("a,b,x,y,c,d,e", try std.mem.join(a, ",", try takeWithin(a, &old, &grown, 1, 2)));
}
