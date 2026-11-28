//! Fenced code in a page: a fence opens with three or more backquotes or
//! tildes and closes with at least as many of the same, so a ```` block can
//! show ``` inside it.

const std = @import("std");

pub const Line = enum { outside, open, inside, close };

pub const Fence = struct {
    char: u8 = 0,
    len: usize = 0,

    pub fn in(self: Fence) bool {
        return self.len > 0;
    }

    /// What `text` (a line without its quote marks and indent) is, and the
    /// fence's state after it.
    pub fn step(self: *Fence, text: []const u8) Line {
        const run = marker(text);
        if (!self.in()) {
            if (run.len < 3) return .outside;
            self.* = .{ .char = run.char, .len = run.len };
            return .open;
        }
        if (run.char == self.char and run.len >= self.len and
            std.mem.trim(u8, text[run.len..], " ").len == 0)
        {
            self.* = .{};
            return .close;
        }
        return .inside;
    }
};

const Run = struct { char: u8 = 0, len: usize = 0 };

fn marker(text: []const u8) Run {
    if (text.len == 0 or (text[0] != '`' and text[0] != '~')) return .{};
    var n: usize = 0;
    while (n < text.len and text[n] == text[0]) n += 1;
    return .{ .char = text[0], .len = n };
}
