//! ALLOCATE and DEALLOCATE of what cannot be (#850): an object that is
//! neither ALLOCATABLE nor a POINTER, an array allocated with no shape
//! (and no SOURCE or MOLD), a shape of another rank than the array's.
//! gfortran, Flang and ifx all report each. Only plain variable names are
//! checked, not components.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const dimensions = @import("../objects/dimensions.zig");
const objects = @import("../objects.zig");
const KW = @import("../constants.zig").KW;

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;
const Obj = objects.Obj;

/// The object an ALLOCATE item names and its shape: `a(3, 4)` is `a` with
/// 2 subscripts; null for an item that is no plain name
const Item = struct { name: []const u8, at: usize, subscripts: ?usize };

fn itemOf(text: []const u8, base: usize) ?Item {
    const lead = std.mem.findNone(u8, text, " ") orelse return null;
    var k = lead;
    while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_')) k += 1;
    if (k == lead or !std.ascii.isAlphabetic(text[lead])) return null;
    const name = text[lead..k];
    var rest = std.mem.trimStart(u8, text[k..], " ");
    if (rest.len == 0) return .{ .name = name, .at = base + lead, .subscripts = null };
    if (rest[0] != '(') return null;
    const close = typing.matching(rest, 0) orelse return null;
    if (std.mem.trim(u8, rest[close + 1 ..], " ").len != 0) return null;
    rest = rest[1..close];
    var n: usize = 1;
    while (typing.topLevel(rest, ',')) |i| : (rest = rest[i + 1 ..]) n += 1;
    return .{ .name = name, .at = base + lead, .subscripts = n };
}

pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, first: helpers.Word, scope: ?*Obj, line_no: usize) !void {
    const is_allocate = std.ascii.eqlIgnoreCase(first.str, "allocate");
    if (!is_allocate and !std.ascii.eqlIgnoreCase(first.str, "deallocate")) return;
    var k = first.end;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '(') return;
    const close = typing.matching(text, k) orelse return;
    if (std.mem.trim(u8, text[close + 1 ..], " ").len != 0) return;
    // a shape is given by a SOURCE or MOLD
    var has_source = false;
    var pos = k + 1;
    var items: std.ArrayList(struct { text: []const u8, at: usize }) = .empty;
    while (pos <= close) {
        const rest = text[pos..close];
        const comma = typing.topLevel(rest, ',') orelse rest.len;
        var item = rest[0..comma];
        var at = pos;
        if (typing.keywordOf(item)) |kw| {
            if (typing.oneOf(kw, &.{ "source", "mold" })) has_source = true;
        } else {
            // `real :: x(3)`: the type of the objects
            if (std.mem.find(u8, item, "::")) |dc| {
                item = item[dc + 2 ..];
                at += dc + 2;
            }
            try items.append(c.a, .{ .text = item, .at = at });
        }
        pos += comma + 1;
    }
    for (items.items) |it| {
        const item = itemOf(it.text, it.at) orelse continue;
        const v = (try c.lookup(scope, item.name, line_no)) orelse continue;
        if (v.kind != .variable or dimensions.isAssociateName(v) or v.linkObj() != null) continue;
        const end = item.at + item.name.len;
        if (!v.hasKeyword(KW.allocatable) and !v.hasKeyword(KW.pointer)) {
            try c.report(j, s + item.at, s + end, .allocate_object, "{s} has neither the ALLOCATABLE nor the POINTER attribute", .{v.name});
            continue;
        }
        if (!is_allocate or !dimensions.known(v)) continue;
        const rank = argcheck.rankOf(dimensions.of(v)) orelse continue;
        if (item.subscripts) |n| {
            if (n != rank) try c.report(j, s + item.at, s + end, .allocate_shape, "{s} has rank {d} and {d} bounds are given", .{ v.name, rank, n });
        } else if (!has_source) {
            try c.report(j, s + item.at, s + end, .allocate_shape, "{s} is an array: ALLOCATE needs its shape, a SOURCE or a MOLD", .{v.name});
        }
    }
}
