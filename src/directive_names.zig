//! The names in the clauses of an OpenMP or OpenACC directive line, such as
//! `i` and `total` of `!$omp parallel do private(i) reduction(+:total)`:
//! the words inside parentheses. The directive's own words and its clauses'
//! names (`parallel`, `private`) are outside them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");

pub const Names = struct {
    /// the words, at their columns of the line
    words: []const helpers.Word,
    /// the depth of the parentheses left open at the line's end, for the
    /// line that continues it
    depth: usize,
};

/// Where the text after the sentinel (and the continuation mark) starts
fn bodyStart(fixed: bool, line: []const u8) usize {
    // `c$omp` and the mark column of fixed form
    if (fixed) return @min(line.len, 6);
    const bang = std.mem.findScalar(u8, line, '!') orelse return line.len;
    const after = @min(line.len, bang + 5);
    return if (after < line.len and line[after] == '&') after + 1 else after;
}

/// The names inside the parentheses of directive line `line`, `depth_in`
/// being the depth the line before it left open
pub fn inClauses(a: Allocator, fixed: bool, line: []const u8, depth_in: usize) Allocator.Error!Names {
    const body = bodyStart(fixed, line);
    var out: std.ArrayList(helpers.Word) = .empty;
    var depth = depth_in;
    var scanned = body;
    var it = helpers.words(line[body..]);
    while (it.next()) |found| {
        const w: helpers.Word = .{ .start = found.start + body, .end = found.end + body, .str = found.str };
        if (scan(line[scanned..w.start], &depth)) return .{ .words = out.items, .depth = depth };
        scanned = w.end;
        if (depth == 0) continue;
        // a component, or the name of an operator written between dots
        if (w.start > 0 and (line[w.start - 1] == '%' or line[w.start - 1] == '.')) continue;
        try out.append(a, w);
    }
    _ = scan(line[scanned..], &depth);
    return .{ .words = out.items, .depth = depth };
}

/// Counts the parentheses of `text` into `depth`; whether a comment ends it
fn scan(text: []const u8, depth: *usize) bool {
    for (text) |c| switch (c) {
        '(' => depth.* += 1,
        ')' => depth.* -|= 1,
        '!' => return true,
        else => {},
    };
    return false;
}

fn expectWords(line: []const u8, depth_in: usize, want: []const []const u8, depth_out: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try inClauses(arena.allocator(), false, line, depth_in);
    try std.testing.expectEqual(want.len, got.words.len);
    for (want, got.words) |w, g| try std.testing.expectEqualStrings(w, g.str);
    try std.testing.expectEqual(depth_out, got.depth);
}

test "the names of the clauses of a directive line" {
    try expectWords("  !$omp parallel do private(i, j) reduction(+:total)", 0, &.{ "i", "j", "total" }, 0);
    try expectWords("!$acc parallel loop copyin(a(1:n)) ! copy(z)", 0, &.{ "a", "n" }, 0);
    try expectWords("  !$omp parallel do private(a, &", 0, &.{"a"}, 1);
    try expectWords("  !$omp& b) shared(c)", 1, &.{ "b", "c" }, 0);
    try expectWords("  !$omp do schedule(static, chunk) collapse(2)", 0, &.{ "static", "chunk" }, 0);
}
