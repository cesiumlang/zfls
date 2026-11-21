//! The S-expressions of a gfortran module file (gfortran_mod.zig): lists,
//! integers, `'strings'` (a quote doubled inside) and bare words.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Node = union(enum) {
    list: []const Node,
    /// an integer or a bare word (`REAL`, `UNKNOWN-INTENT`)
    word: []const u8,
    string: []const u8,

    pub fn items(n: Node) []const Node {
        return if (n == .list) n.list else &.{};
    }

    /// The `i`th item of a list, null past its end or for an atom
    pub fn at(n: Node, i: usize) ?Node {
        const l = n.items();
        return if (i < l.len) l[i] else null;
    }

    pub fn int(n: Node) ?i64 {
        return if (n == .word) std.fmt.parseInt(i64, n.word, 10) catch null else null;
    }

    pub fn isWord(n: Node, w: []const u8) bool {
        return n == .word and std.mem.eql(u8, n.word, w);
    }

    /// Whether a list has bare word `w`
    pub fn hasWord(n: Node, w: []const u8) bool {
        for (n.items()) |x| if (x.isWord(w)) return true;
        return false;
    }
};

pub const Error = error{ OutOfMemory, Malformed };

/// The top-level expressions of `text`
pub fn parseAll(a: Allocator, text: []const u8) Error![]const Node {
    var p: Parser = .{ .a = a, .text = text };
    var out: std.ArrayList(Node) = .empty;
    while (true) {
        p.skip();
        if (p.i >= text.len) break;
        try out.append(a, try p.node());
    }
    return out.items;
}

const Parser = struct {
    a: Allocator,
    text: []const u8,
    i: usize = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.text.len and std.ascii.isWhitespace(p.text[p.i])) p.i += 1;
    }

    fn node(p: *Parser) Error!Node {
        p.skip();
        if (p.i >= p.text.len) return error.Malformed;
        switch (p.text[p.i]) {
            '(' => {
                p.i += 1;
                var items: std.ArrayList(Node) = .empty;
                while (true) {
                    p.skip();
                    if (p.i >= p.text.len) return error.Malformed;
                    if (p.text[p.i] == ')') {
                        p.i += 1;
                        return .{ .list = items.items };
                    }
                    try items.append(p.a, try p.node());
                }
            },
            ')' => return error.Malformed,
            '\'' => {
                p.i += 1;
                var s: std.ArrayList(u8) = .empty;
                while (p.i < p.text.len) : (p.i += 1) {
                    if (p.text[p.i] != '\'') {
                        try s.append(p.a, p.text[p.i]);
                    } else if (p.i + 1 < p.text.len and p.text[p.i + 1] == '\'') {
                        try s.append(p.a, '\'');
                        p.i += 1;
                    } else {
                        p.i += 1;
                        return .{ .string = s.items };
                    }
                }
                return error.Malformed;
            },
            else => {
                const start = p.i;
                while (p.i < p.text.len and !std.ascii.isWhitespace(p.text[p.i]) and p.text[p.i] != '(' and p.text[p.i] != ')') p.i += 1;
                return .{ .word = p.text[start..p.i] };
            },
        }
    }
};

test "a module file's S-expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try parseAll(arena.allocator(), "(('gen' 'lib' 2 3)) ()\n(25 'n' 'it''s' (PARAMETER UNKNOWN-INTENT) ())");
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expectEqualStrings("gen", nodes[0].at(0).?.at(0).?.string);
    try std.testing.expectEqual(@as(?i64, 3), nodes[0].at(0).?.at(3).?.int());
    try std.testing.expectEqual(@as(usize, 0), nodes[1].items().len);
    try std.testing.expectEqualStrings("it's", nodes[2].at(2).?.string);
    try std.testing.expect(nodes[2].at(3).?.hasWord("PARAMETER"));
    try std.testing.expectError(error.Malformed, parseAll(arena.allocator(), "(a"));
}
