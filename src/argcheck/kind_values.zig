//! A kind that no compiler of the dialect has (#850): `real(kind=3)`.
//! gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 differ: a compiler's
//! dialect applies its kinds (those of x86-64, widened where the compiler
//! has more on other targets), neutral the kinds that no compiler rejects.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const Dialect = @import("../dialect.zig").Dialect;

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;

const Type = enum { integer, real, complex, logical, character };

/// The kinds of each type that a dialect accepts
fn accepted(d: Dialect, t: Type) []const i64 {
    return switch (d) {
        .gfortran => switch (t) {
            .integer, .logical => &.{ 1, 2, 4, 8, 16 },
            .real, .complex => &.{ 2, 4, 8, 10, 16 },
            .character => &.{ 1, 4 },
        },
        .ifx => switch (t) {
            .integer, .logical => &.{ 1, 2, 4, 8 },
            .real, .complex => &.{ 4, 8, 16 },
            .character => &.{1},
        },
        .flang => switch (t) {
            .integer => &.{ 1, 2, 4, 8, 16 },
            .logical => &.{ 1, 2, 4, 8 },
            .real, .complex => &.{ 2, 3, 4, 8, 10, 16 },
            .character => &.{ 1, 2, 4 },
        },
        .neutral => switch (t) {
            .integer, .logical => &.{ 1, 2, 4, 8, 16 },
            .real, .complex => &.{ 2, 3, 4, 8, 10, 16 },
            .character => &.{ 1, 2, 4 },
        },
    };
}

fn typeOf(word: []const u8) ?Type {
    var buf: [9]u8 = undefined;
    if (word.len > buf.len) return null;
    return std.meta.stringToEnum(Type, std.ascii.lowerString(&buf, word));
}

pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, first: helpers.Word) !void {
    const t = typeOf(first.str) orelse return;
    var k = first.end;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '(') return;
    const close = typing.matching(text, k) orelse return;
    var pos = k + 1;
    var index: usize = 0;
    while (pos <= close) : (index += 1) {
        const rest = text[pos..close];
        const comma = typing.topLevel(rest, ',') orelse rest.len;
        const raw = rest[0..comma];
        defer pos += comma + 1;
        const item = std.mem.trim(u8, raw, " ");
        const value: []const u8 = if (typing.keywordOf(item)) |kw| blk: {
            if (!std.ascii.eqlIgnoreCase(kw, "kind")) continue;
            break :blk std.mem.trim(u8, item[std.mem.findScalar(u8, item, '=').? + 1 ..], " ");
        } else if (t != .character and index == 0) item else continue;
        if (value.len == 0 or std.mem.findNone(u8, value, "0123456789") != null) continue;
        const n = std.fmt.parseInt(i64, value, 10) catch continue;
        if (std.mem.findScalar(i64, accepted(c.dialect, t), n) != null) continue;
        const at = pos + (std.mem.find(u8, raw, value) orelse 0);
        try c.report(j, s + at, s + at + value.len, .bad_kind, "{s}(KIND={d}) is not a supported type", .{ try std.ascii.allocUpperString(c.a, @tagName(t)), n });
    }
}
