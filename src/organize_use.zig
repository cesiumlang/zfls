//! Organizing a scope's USE statements (#985): sorted by module (intrinsic
//! ones first), and those of one module merged into one. Lines of text in,
//! lines out; what is not a plain one-line USE statement of the forms below
//! is left as it is (the caller then offers nothing).
//!
//! `use m`, `use :: m`, `use, intrinsic :: m`, `use m, only: a, b => c`,
//! `use m, x => y` (renames without ONLY, which are not merged).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A USE statement, read
pub const Use = struct {
    /// `, intrinsic` or `, non_intrinsic` as written, or empty
    nature: []const u8,
    module: []const u8,
    /// the items of an ONLY list; null without ONLY
    only: ?[]const []const u8,
    /// the rename list without ONLY, as written (empty: none)
    renames: []const u8,

    fn key(u: Use, a: Allocator) ![]const u8 {
        const intrinsic = std.ascii.findIgnoreCase(u.nature, "non") == null and u.nature.len > 0;
        return std.mem.concat(a, u8, &.{ if (intrinsic) "0" else "1", try std.ascii.allocLowerString(a, u.module) });
    }
};

/// `line` as a USE statement, or null when it is none zfls rewrites (a
/// comment after it, a continuation, a preprocessor's line)
pub fn parse(a: Allocator, line: []const u8) !?Use {
    var s = std.mem.trim(u8, line, " \t\r");
    if (s.len < 4 or !std.ascii.startsWithIgnoreCase(s, "use") or std.mem.findAny(u8, s, "!&;\"'") != null) return null;
    s = s[3..];
    if (s.len > 0 and (std.ascii.isAlphanumeric(s[0]) or s[0] == '_')) return null; // `user = 1`
    s = std.mem.trimStart(u8, s, " \t");
    var nature: []const u8 = "";
    if (s.len > 0 and s[0] == ',') {
        const colons = std.mem.find(u8, s, "::") orelse return null;
        nature = std.mem.trim(u8, s[0..colons], " \t");
        const word = std.mem.trim(u8, nature[1..], " \t");
        if (!std.ascii.eqlIgnoreCase(word, "intrinsic") and !std.ascii.eqlIgnoreCase(word, "non_intrinsic")) return null;
        s = std.mem.trimStart(u8, s[colons + 2 ..], " \t");
    } else if (std.mem.startsWith(u8, s, "::")) s = std.mem.trimStart(u8, s[2..], " \t");
    var e: usize = 0;
    while (e < s.len and (std.ascii.isAlphanumeric(s[e]) or s[e] == '_')) e += 1;
    if (e == 0) return null;
    const module = s[0..e];
    var rest = std.mem.trim(u8, s[e..], " \t");
    if (rest.len == 0) return .{ .nature = nature, .module = module, .only = null, .renames = "" };
    if (rest[0] != ',') return null;
    rest = std.mem.trim(u8, rest[1..], " \t");
    if (std.ascii.startsWithIgnoreCase(rest, "only")) {
        const after = std.mem.trimStart(u8, rest[4..], " \t");
        if (after.len == 0 or after[0] != ':') return null;
        var items: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, after[1..], ',');
        while (it.next()) |item| {
            const t = std.mem.trim(u8, item, " \t");
            if (t.len > 0) try items.append(a, t);
        }
        return .{ .nature = nature, .module = module, .only = items.items, .renames = "" };
    }
    return .{ .nature = nature, .module = module, .only = null, .renames = rest };
}

/// The USE statements `uses` as `indent`ed lines: sorted, merged where
/// merging keeps every name (a plain `use m` takes in its ONLY lists; ONLY
/// lists of a module join, without repeats; renames without ONLY stay as
/// they are)
pub fn organize(a: Allocator, uses: []const Use, indent: []const u8) ![]const []const u8 {
    const Group = struct { key: []const u8, first: usize, merged: ?Use, apart: std.ArrayList(Use) };
    var groups: std.ArrayList(Group) = .empty;
    for (uses, 0..) |u, i| {
        const k = try u.key(a);
        const g = for (groups.items) |*g| {
            if (std.mem.eql(u8, g.key, k)) break g;
        } else blk: {
            try groups.append(a, .{ .key = k, .first = i, .merged = null, .apart = .empty });
            break :blk &groups.items[groups.items.len - 1];
        };
        if (u.renames.len > 0) {
            try g.apart.append(a, u);
            continue;
        }
        const m = g.merged orelse {
            g.merged = u;
            continue;
        };
        // a plain USE makes every name visible: it stays alone
        if (m.only == null) continue;
        if (u.only == null) {
            g.merged = u;
            continue;
        }
        var items: std.ArrayList([]const u8) = .empty;
        try items.appendSlice(a, m.only.?);
        for (u.only.?) |x| {
            const seen = for (items.items) |y| {
                if (std.ascii.eqlIgnoreCase(x, y)) break true;
            } else false;
            if (!seen) try items.append(a, x);
        }
        g.merged = .{ .nature = m.nature, .module = m.module, .only = items.items, .renames = "" };
    }
    std.mem.sort(Group, groups.items, {}, struct {
        fn less(_: void, x: Group, y: Group) bool {
            return std.mem.order(u8, x.key, y.key) == .lt;
        }
    }.less);
    var out: std.ArrayList([]const u8) = .empty;
    for (groups.items) |g| {
        if (g.merged) |m| try out.append(a, try text(a, m, indent));
        for (g.apart.items) |u| try out.append(a, try text(a, u, indent));
    }
    return out.items;
}

/// A USE statement as written by `organize`
fn text(a: Allocator, u: Use, indent: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}use", .{indent});
    if (u.nature.len > 0) try out.print(a, "{s} ::", .{u.nature});
    try out.print(a, " {s}", .{u.module});
    if (u.only) |items| {
        try out.appendSlice(a, ", only: ");
        for (items, 0..) |x, i| try out.print(a, "{s}{s}", .{ if (i > 0) ", " else "", x });
    } else if (u.renames.len > 0) try out.print(a, ", {s}", .{u.renames});
    return out.items;
}

const testing = std.testing;

fn expectOrganized(lines: []const []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var uses: std.ArrayList(Use) = .empty;
    for (lines) |l| try uses.append(a, (try parse(a, l)).?);
    const got = try organize(a, uses.items, "  ");
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "USE statements sorted, intrinsic modules first, duplicates merged (#985)" {
    try expectOrganized(&.{ "  use zeta", "  use alpha, only: b", "use, intrinsic :: iso_fortran_env", "  USE alpha, only: a, B" }, &.{
        "  use, intrinsic :: iso_fortran_env",
        "  use alpha, only: b, a",
        "  use zeta",
    });
    // a plain USE takes in the ONLY lists; renames without ONLY stay apart
    try expectOrganized(&.{ "use m, only: x", "use m", "use m, y => z" }, &.{ "  use m", "  use m, y => z" });
}

test "lines that are no plain USE statement are not read (#985)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "use m ! why", "use m, only: a, &", "user = 1", "use, foo :: m", "use m only" }) |l| {
        try testing.expectEqual(null, try parse(a, l));
    }
    const u = (try parse(a, "use :: m, only: a => b, c")).?;
    try testing.expectEqualStrings("m", u.module);
    try testing.expectEqual(2, u.only.?.len);
}
