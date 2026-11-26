//! Part of reading definitions (definitions.zig): the statements that open
//! a construct, BLOCK, DO, WHERE, IF, ASSOCIATE, CHANGE TEAM, and SELECT
//! with its type guards and the cases of SELECT RANK.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const definitions = @import("definitions.zig");
const DefResult = definitions.DefResult;
const E = definitions.E;

fn R() *const patterns.Patterns {
    return patterns.get();
}

const parseKind = definitions.parseKind;

pub fn readBlockDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().BLOCK.match(line) orelse return null;
    var name = m.group(1);
    if (name) |n| if (n.len > 0) {
        name = str.strip(try std.mem.replaceOwned(u8, a, n, ":", " "));
    };
    return .{ .block = name };
}

pub fn stripNoComment(a: Allocator, line: []const u8) E![]const u8 {
    const stripped = try helpers.stripStrings(a, line, true);
    return str.rstrip(str.beforeFirst(stripped, "!"));
}

pub fn readDoDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    const m = R().DO.match(nc) orelse return null;
    return .{ .do_ = str.strip(m.group(1).?) };
}

pub fn readWhereDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    const m = R().WHERE.match(nc) orelse return null;
    const trailing = str.from(line, m.end(0));
    const close_paren = helpers.findParenMatch(trailing);
    if (close_paren < 0) return .{ .where = true };
    const after = str.strip(str.from(trailing, @as(usize, @intCast(close_paren)) + 1));
    if (R().WORD.match(after) != null) return .{ .where = true };
    return .{ .where = false };
}

pub fn readIfDef(a: Allocator, line: []const u8) E!?DefResult {
    const nc = try stripNoComment(a, line);
    if (R().IF.match(nc) != null and R().THEN.search(nc) != null) return .if_;
    return null;
}

pub fn readAssociateDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().ASSOCIATE.match(line) orelse return null;
    const trailing = line[m.end(0)..];
    const mc = helpers.findParenMatch(trailing);
    if (mc < 0) return .{ .assoc = &.{} };
    // split at the commas outside parentheses and strings, the strings kept
    // (`s => 'abc'` is typed by its literal)
    return .{ .assoc = try splitList(a, trailing[0..@intCast(mc)]) };
}

/// CHANGE TEAM (#720): its coarray associations, `x[*] => y` as `x => y`
pub fn readChangeTeamDef(a: Allocator, line: []const u8) E!?DefResult {
    const m = R().CHANGE_TEAM.match(line) orelse return null;
    const trailing = line[m.end(0)..];
    const mc = helpers.findParenMatch(trailing);
    if (mc < 0) return .{ .team = &.{} };
    // not an assignment to an array named `changeteam`
    const after = str.strip(trailing[@as(usize, @intCast(mc)) + 1 ..]);
    if (after.len > 0 and after[0] != '!') return null;
    var out: std.ArrayList([]const u8) = .empty;
    // the team value first, then the associations and the sync-stat list
    const items = try splitList(a, trailing[0..@intCast(mc)]);
    for (items[@min(1, items.len)..]) |item| {
        const arrow = std.mem.find(u8, item, "=>") orelse continue;
        const name = str.strip(item[0 .. std.mem.findScalar(u8, item[0..arrow], '[') orelse arrow]);
        try out.append(a, try a.print("{s} => {s}", .{ name, str.strip(item[arrow + 2 ..]) }));
    }
    return .{ .team = out.items };
}

/// The items of a list split at the commas outside parentheses, brackets
/// and strings, the strings kept
fn splitList(a: Allocator, list_in: []const u8) E![]const []const u8 {
    const list = str.strip(list_in);
    const blanked = try helpers.stripStrings(a, list, true);
    var words: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (blanked, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        ',' => if (depth == 0) {
            const w = str.strip(list[start..i]);
            if (w.len > 0) try words.append(a, w);
            start = i + 1;
        },
        else => {},
    };
    const last = str.strip(list[start..]);
    if (last.len > 0) try words.append(a, last);
    return words.items;
}

pub fn readSelectDef(a: Allocator, line: []const u8) E!?DefResult {
    if (R().SELECT.match(line)) |m| {
        const word = m.group(1).?;
        var st: i32 = -1;
        if (std.ascii.startsWithIgnoreCase(word, "case")) {
            st = 1;
        } else if (std.ascii.startsWithIgnoreCase(word, "type") or std.ascii.startsWithIgnoreCase(word, "rank")) {
            st = 2;
        }
        // the whole selector, with its subscripts: `it => items(i)`
        var binding = m.group(2);
        const open = m.end(0) - binding.?.len - 1;
        const close = helpers.findParenMatch(line[open + 1 ..]);
        if (close >= 0) binding = line[open + 1 .. open + 1 + @as(usize, @intCast(close))];
        return .{ .select = .{ .type = st, .binding = binding, .desc = null } };
    }
    if (R().SELECT_TYPE.match(line)) |m| {
        var buf: [5]u8 = undefined;
        const d = m.group(1).?;
        const up = std.ascii.upperString(buf[0..d.len], d);
        const desc: []const u8 = if (std.mem.eql(u8, up, "TYPE")) "TYPE" else "CLASS";
        // the guard's type: an intrinsic one, `type is (real(8))` (#701)
        if (std.mem.eql(u8, desc, "TYPE")) if (try intrinsicGuard(a, m.group(2) orelse "")) |name| {
            // (none while `real(8` is being written)
            const kind = if (try parseKind(a, line[m.end(0)..])) |kr| kr.kind else null;
            return .{ .select = .{ .type = 3, .binding = m.group(2), .desc = name, .kind = kind } };
        };
        return .{ .select = .{ .type = 3, .binding = m.group(2), .desc = try a.print("{s}({s})", .{ desc, m.group(2) orelse "None" }) } };
    }
    if (R().SELECT_DEFAULT.match(line) != null) return .{ .select = .{ .type = 4, .binding = null, .desc = null } };
    // a case of SELECT RANK: its associate name is the selector, of the
    // case's rank (#706)
    if (R().SELECT_RANK.match(line) != null) {
        const rest = std.mem.trimStart(u8, std.mem.trimStart(u8, line, " ")["rank".len..], " ");
        const close = helpers.findParenMatch(rest[1..]);
        const rank = if (rest[0] == '(' and close >= 0) str.strip(rest[1 .. 1 + @as(usize, @intCast(close))]) else null;
        return .{ .select = .{ .type = 5, .binding = null, .desc = null, .rank = rank } };
    }
    return null;
}

/// The intrinsic type type guard `spec` names, uppercase, or null
fn intrinsicGuard(a: Allocator, spec: []const u8) E!?[]const u8 {
    const up = try std.ascii.allocUpperString(a, str.strip(spec));
    const m = R().VAR.match(up) orelse return null;
    if (m.end(0) != up.len) return null;
    for ([_][]const u8{ "PROCEDURE", "EXTERNAL", "CLASS", "TYPE" }) |w| if (std.mem.eql(u8, up, w)) return null;
    return up;
}
