//! A named constant with no value (#850): `integer, parameter :: n`.
//! gfortran, Flang and ifx all report it.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;

/// The offset of the first `::` of `text` outside parentheses
fn doubleColon(text: []const u8) ?usize {
    var depth: usize = 0;
    for (text, 0..) |ch, i| switch (ch) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        ':' => if (depth == 0 and i + 1 < text.len and text[i + 1] == ':') return i,
        else => {},
    };
    return null;
}

/// Whether the attributes in `text` (the declaration before its `::`)
/// include PARAMETER
fn hasParameter(text: []const u8) bool {
    var rest = text;
    while (true) {
        const comma = typing.topLevel(rest, ',');
        const part = std.mem.trim(u8, rest[0 .. comma orelse rest.len], " ");
        if (std.ascii.eqlIgnoreCase(part, "parameter")) return true;
        rest = rest[(comma orelse return false) + 1 ..];
    }
}

/// Reports the entities of the type declaration `text` (at offset `s` of
/// the joined statement) that are named constants with no value
pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, first: helpers.Word) !void {
    if (!typing.oneOf(first.str, &.{ "integer", "real", "double", "complex", "logical", "character", "type", "class", "byte" })) return;
    const dc = doubleColon(text) orelse return;
    if (!hasParameter(text[0..dc])) return;
    var pos = dc + 2;
    while (pos <= text.len) {
        const rest = text[pos..];
        const comma = typing.topLevel(rest, ',') orelse rest.len;
        const entity = rest[0..comma];
        const name_at = std.mem.findNone(u8, entity, " ") orelse break;
        var name_end = name_at;
        while (name_end < entity.len and (std.ascii.isAlphanumeric(entity[name_end]) or entity[name_end] == '_')) name_end += 1;
        if (name_end > name_at and typing.topLevel(entity, '=') == null) {
            try c.report(j, s + pos + name_at, s + pos + name_end, .parameter_without_value, "Named constant {s} has no value", .{entity[name_at..name_end]});
        }
        pos += comma + 1;
    }
}
