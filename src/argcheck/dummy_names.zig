//! A dummy argument named twice in a SUBROUTINE or FUNCTION statement
//! (#850): `subroutine s(a, b, a)`. gfortran, Flang and ifx all report it.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;

const prefix_words = [_][]const u8{
    "pure",    "impure", "elemental", "recursive", "non_recursive", "simple",  "module",
    "integer", "real",   "double",    "precision", "complex",       "logical", "character",
    "type",    "class",  "byte",
};

/// Whether `prefix`, the text of a statement before its SUBROUTINE or
/// FUNCTION word, holds only what a procedure statement starts with: the
/// words of prefixes and a type with its parenthesized specification
fn isHeaderPrefix(prefix: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        const ch = prefix[i];
        switch (ch) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            else => if (depth == 0) {
                if (ch == ' ' or ch == '\t' or ch == '*') continue;
                if (!(std.ascii.isAlphabetic(ch) or ch == '_')) return false;
                const start = i;
                while (i + 1 < prefix.len and (std.ascii.isAlphanumeric(prefix[i + 1]) or prefix[i + 1] == '_')) i += 1;
                if (!typing.oneOf(prefix[start .. i + 1], &prefix_words)) return false;
            },
        }
    }
    return true;
}

pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8) !void {
    var it = helpers.words(text);
    while (it.next()) |w| {
        if (!typing.oneOf(w.str, &.{ "subroutine", "function" })) continue;
        if (!isHeaderPrefix(text[0..w.start])) return;
        var k = w.end;
        while (k < text.len and text[k] == ' ') k += 1;
        const name_start = k;
        while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_')) k += 1;
        if (k == name_start) return;
        while (k < text.len and text[k] == ' ') k += 1;
        if (k >= text.len or text[k] != '(') return;
        const close = typing.matching(text, k) orelse return;
        var seen: std.ArrayList([]const u8) = .empty;
        var pos = k + 1;
        while (pos <= close) {
            const rest = text[pos..close];
            const comma = std.mem.findScalar(u8, rest, ',') orelse rest.len;
            const raw = rest[0..comma];
            const arg = std.mem.trim(u8, raw, " ");
            if (arg.len > 0 and typing.isName(arg)) {
                const lower = try std.ascii.allocLowerString(c.a, arg);
                for (seen.items) |p| if (std.mem.eql(u8, p, lower)) {
                    const at = pos + (std.mem.find(u8, raw, arg) orelse 0);
                    try c.report(j, s + at, s + at + arg.len, .duplicate_dummy, "Dummy argument {s} is named twice", .{arg});
                    break;
                };
                try seen.append(c.a, lower);
            }
            pos += comma + 1;
        }
        return;
    }
}
