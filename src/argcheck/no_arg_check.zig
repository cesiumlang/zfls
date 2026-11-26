//! Part of the argument checks (argcheck.zig): `!GCC$ ATTRIBUTES
//! NO_ARG_CHECK :: name, ...` (gfortran's) and `!DIR$ ATTRIBUTES
//! NO_ARG_CHECK :: name, ...` (Intel's, also `!DEC$`), which exempt the
//! dummy arguments they name from the checks of type, kind and rank of
//! their actual arguments, as `!dir$ ignore_tkr` does (ignore_tkr.zig,
//! which collects both from a procedure's lines).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ignore_tkr = @import("ignore_tkr.zig");
const Entry = ignore_tkr.Entry;

/// The entries of line `line` if it is a `NO_ARG_CHECK` directive: the
/// sentinel `!gcc$`, `!dir$` or `!dec$` in any case (in fixed form also
/// with `c` or `*` in column 1), `ATTRIBUTES`, a list of attributes that
/// has `NO_ARG_CHECK`, `::` and the names. Appended to `out`; false if it
/// is none.
pub fn parse(a: Allocator, fixed: bool, line: []const u8, out: *std.ArrayList(Entry)) !bool {
    var rest = std.mem.trimStart(u8, line, " \t");
    if (rest.len == 0) return false;
    const marker_ok = rest[0] == '!' or (fixed and rest.len == line.len and (rest[0] == 'c' or rest[0] == 'C' or rest[0] == '*'));
    if (!marker_ok) return false;
    rest = rest[1..];
    if (rest.len < 4) return false;
    const sentinel_ok = for ([_][]const u8{ "gcc$", "dir$", "dec$" }) |s| {
        if (std.ascii.startsWithIgnoreCase(rest, s)) break true;
    } else false;
    if (!sentinel_ok) return false;
    rest = std.mem.trimStart(u8, rest[4..], " \t");
    const word = "attributes";
    if (!std.ascii.startsWithIgnoreCase(rest, word)) return false;
    rest = rest[word.len..];
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return false;
    // a comment after it
    if (std.mem.findScalar(u8, rest, '!')) |i| rest = rest[0..i];
    const colons = std.mem.find(u8, rest, "::") orelse return false;
    const wanted = for (try splitList(a, rest[0..colons])) |attr| {
        if (std.ascii.eqlIgnoreCase(attr, "no_arg_check")) break true;
    } else false;
    if (!wanted) return false;
    const names = try splitList(a, rest[colons + 2 ..]);
    if (names.len == 0) return false;
    for (names) |n| try out.append(a, .{ .name = n, .ignored = .all });
    return true;
}

/// The items of a comma-separated list, trimmed, without empty ones
fn splitList(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r");
        if (item.len > 0) try out.append(a, item);
    }
    return out.items;
}

test "NO_ARG_CHECK: the dummy arguments it names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Entry) = .empty;
    try std.testing.expect(try parse(a, false, "  !GCC$ ATTRIBUTES NO_ARG_CHECK :: buf", &out));
    try std.testing.expectEqualStrings("buf", out.items[0].name.?);
    try std.testing.expectEqual(ignore_tkr.Ignored.all, out.items[0].ignored);
    out.clearRetainingCapacity();
    try std.testing.expect(try parse(a, false, "!dir$ attributes no_arg_check :: x, y ! why", &out));
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(ignore_tkr.Ignored.all, ignore_tkr.of(out.items, "Y"));
    out.clearRetainingCapacity();
    // Intel's list of attributes, its older sentinel
    try std.testing.expect(try parse(a, false, "!DEC$ ATTRIBUTES REFERENCE, NO_ARG_CHECK :: z", &out));
    try std.testing.expectEqualStrings("z", out.items[0].name.?);
    out.clearRetainingCapacity();
    // fixed form
    try std.testing.expect(try parse(a, true, "CDEC$ ATTRIBUTES NO_ARG_CHECK :: q", &out));
    try std.testing.expect(try parse(a, true, "*DIR$ ATTRIBUTES NO_ARG_CHECK :: r", &out));
    try std.testing.expect(try parse(a, true, "cgcc$ attributes no_arg_check :: s", &out));
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    out.clearRetainingCapacity();
    // none
    try std.testing.expect(!try parse(a, false, "!DIR$ ATTRIBUTES DLLEXPORT :: f", &out));
    try std.testing.expect(!try parse(a, false, "!GCC$ ATTRIBUTES NO_ARG_CHECK buf", &out));
    try std.testing.expect(!try parse(a, false, "!GCC$ ATTRIBUTES NO_ARG_CHECK ::", &out));
    try std.testing.expect(!try parse(a, false, "!pgi$ attributes no_arg_check :: x", &out));
    try std.testing.expect(!try parse(a, false, "!dir$ attributesx no_arg_check :: x", &out));
    try std.testing.expect(!try parse(a, false, "!dir$ ignore_tkr x", &out));
    try std.testing.expect(!try parse(a, true, "  cdec$ attributes no_arg_check :: x", &out));
    try std.testing.expect(!try parse(a, false, "cdec$ attributes no_arg_check :: x", &out));
    try std.testing.expect(!try parse(a, false, "call s(x) ! no_arg_check :: x", &out));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
