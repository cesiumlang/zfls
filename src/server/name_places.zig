//! The places of a name in a line as a whole word, ignoring case: what the
//! pattern `(?:\W|^)(NAME)(?=\W|$)` finds, without running a regex at
//! every position of every line (references search a whole workspace).

const std = @import("std");
const regex = @import("../regex.zig");
const str = @import("../str.zig");

pub const Place = struct { start: usize, end: usize };

pub const NamePlaces = struct {
    line: []const u8,
    name: []const u8,
    pos: usize = 0,

    pub fn next(self: *NamePlaces) ?Place {
        if (self.name.len == 0) return null;
        while (str.findIgnoreCasePos(self.line, self.pos, self.name)) |at| {
            const end = at + self.name.len;
            self.pos = at + 1;
            if (at > 0 and regex.isWordChar(self.line[at - 1])) continue;
            if (end < self.line.len and regex.isWordChar(self.line[end])) continue;
            self.pos = end;
            return .{ .start = at, .end = end };
        }
        self.pos = self.line.len + 1;
        return null;
    }
};

pub fn places(line: []const u8, name: []const u8) NamePlaces {
    return .{ .line = line, .name = name };
}

test "the places match the whole-word pattern" {
    const lines = [_][]const u8{
        "call foo(a, foo)", "FOO foo_bar xfoo foo", "foofoo", "a=foo", "foo", "", "x foo,foo,foo", "my_foo foo$ foo", "foo foo",
    };
    var re = try regex.Regex.compile(std.testing.allocator, "(?:\\W|^)(foo)(?=\\W|$)", regex.I);
    defer re.deinit();
    for (lines) |line| {
        var it = re.iterator(line);
        var mine = places(line, "foo");
        while (it.next()) |m| {
            const p = mine.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(m.start(1), p.start);
            try std.testing.expectEqual(m.end(1), p.end);
        }
        try std.testing.expect(mine.next() == null);
    }
}

test "a name with a dollar sign" {
    var it = places("integer :: SIG$ERR = -1, sig$err2", "sig$err");
    const p = it.next().?;
    try std.testing.expectEqual(@as(usize, 11), p.start);
    try std.testing.expect(it.next() == null);
}
