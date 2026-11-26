//! The places of a name in a line, as the regex `(?:\W|^)(name)(?=\W|$)`
//! (ignoring case) finds them: a plain identifier is searched for
//! directly, the regex runs only for a name with other characters.

const std = @import("std");
const regex = @import("../regex.zig");

/// Group 1 of the regex
pub const Hit = struct {
    start: usize,
    end: usize,
};

pub fn isPlain(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub const Iterator = struct {
    line: []const u8,
    name: []const u8,
    pos: usize = 0,
    /// For a name that is not plain
    re: ?regex.Iterator = null,

    pub fn init(line: []const u8, name: []const u8, re: *const regex.Regex) Iterator {
        if (isPlain(name)) return .{ .line = line, .name = name };
        return .{ .line = line, .name = name, .re = re.iterator(line) };
    }

    pub fn next(self: *Iterator) ?Hit {
        if (self.re) |*it| {
            const m = it.next() orelse return null;
            return .{ .start = m.start(1), .end = m.end(1) };
        }
        while (self.pos <= self.line.len) {
            const at = self.pos + (std.ascii.findIgnoreCase(self.line[self.pos..], self.name) orelse return null);
            const end = at + self.name.len;
            self.pos = at + 1;
            if (at > 0 and regex.isWordChar(self.line[at - 1])) continue;
            if (end < self.line.len and regex.isWordChar(self.line[end])) continue;
            self.pos = end;
            return .{ .start = at, .end = end };
        }
        return null;
    }
};

test "plain names are found like the regex finds them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{ "x x,X(1)+xy+_x", "call Foo(foo, afoo)", "n", "", "a = n*n" };
    const names = [_][]const u8{ "x", "foo", "n", "x", "N" };
    for (lines, names) |line, name| {
        var re = try regex.Regex.compile(a, try a.print("(?:\\W|^)({s})(?=\\W|$)", .{name}), regex.I);
        defer re.deinit();
        var by_re = re.iterator(line);
        var hits = Iterator.init(line, name, &re);
        while (by_re.next()) |m| {
            const h = hits.next().?;
            try std.testing.expectEqual(m.start(1), h.start);
            try std.testing.expectEqual(m.end(1), h.end);
        }
        try std.testing.expect(hits.next() == null);
    }
}
