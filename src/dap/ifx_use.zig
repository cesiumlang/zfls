//! Intel ifx's use-associated module variables in `zfls dap`'s gdb backend
//! (Linux): ifx's DWARF declares the module variables that a program unit
//! uses again in its scope (`origin`, `cx` in the main program of
//! tests/dap/grid.f90, at the module's addresses), so gdb lists them among
//! its locals; they show under "Module variables" already. A local of the
//! name of a module variable the line sees is left out when it is at that
//! variable's address (`info address`), which keeps a genuine local of
//! that name. ifx 2026.2, gdb 15.1, Ubuntu 24.04 (#683).

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const gdb = @import("gdb.zig");
const gdb_variables = @import("gdb_variables.zig");
const Session = @import("session.zig").Session;
const ModuleVariable = gdb_variables.ModuleVariable;
const Variable = gdb_variables.Variable;

const script =
    \\import gdb, re
    \\def zfls_ifx_at(e):
    \\    try:
    \\        m = re.search(r'static storage at address (0x[0-9a-fA-F]+)', gdb.execute('info address ' + e, to_string=True))
    \\        if m:
    \\            return int(m.group(1), 16)
    \\        v = gdb.parse_and_eval(e).address
    \\        return int(v) if v is not None else None
    \\    except (gdb.error, gdb.MemoryError, RuntimeError, ValueError):
    \\        return None
    \\for local, full in P:
    \\    at = zfls_ifx_at(local)
    \\    if at is not None and at == zfls_ifx_at(full):
    \\        print('zfls-use ' + local)
    \\
;

/// A local that may be a module variable: its name, and the variable's
/// expression (`grid::origin`)
const Pair = struct { local: []const u8, full: []const u8 };

/// `kids` (a frame's locals) without the module variables of `used`
/// (those its line sees) that ifx's DWARF repeats among them
pub fn withoutUsed(s: *Session, a: Allocator, kids: []Variable, used: []const ModuleVariable, frame: ?i64) ![]Variable {
    const pairs = try candidates(a, kids, used);
    if (pairs.len == 0) return kids;
    const r = try gdb.request(s, a, "evaluate", try gdb_variables.evalArgs(a, try command(a, pairs), frame, "repl"));
    if (!gdb.isSuccess(r)) return kids;
    const output = json.str(json.path(r, &.{ "body", "result" })) orelse return kids;
    var out: std.ArrayList(Variable) = .empty;
    for (kids) |k| if (!isListed(output, k.name)) try out.append(a, k);
    return out.items;
}

/// The locals named as a module variable of `used`, with its expression
fn candidates(a: Allocator, kids: []const Variable, used: []const ModuleVariable) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    for (kids) |k| for (used) |u| if (std.ascii.eqlIgnoreCase(k.name, u.local)) {
        try out.append(a, .{ .local = k.name, .full = try std.ascii.allocLowerString(a, try a.print("{s}::{s}", .{ u.module, u.name })) });
        break;
    };
    return out.items;
}

/// The gdb command that prints `zfls-use NAME` for each pair's local at
/// its module variable's address
fn command(a: Allocator, pairs: []const Pair) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(a, '[');
    for (pairs, 0..) |p, i| {
        if (i > 0) try list.append(a, ',');
        try list.print(a, "[{f},{f}]", .{ std.json.fmt(p.local, .{}), std.json.fmt(p.full, .{}) });
    }
    try list.append(a, ']');
    return a.print("python exec({f}, {{'P': {s}}})", .{ std.json.fmt(script, .{}), list.items });
}

/// Whether `command`'s output lists `name`
fn isListed(output: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, l, "zfls-use ") and std.mem.eql(u8, l["zfls-use ".len..], name)) return true;
    }
    return false;
}

test "ifx's use-associated module variables among the locals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // main's locals and the module variables its line sees (tests/dap/grid.f90)
    const kids = [_]Variable{ .{ .name = "k", .value = "2" }, .{ .name = "cx", .value = "1.5" }, .{ .name = "origin", .value = "" } };
    const used = [_]ModuleVariable{
        .{ .module = "grid", .name = "ncells", .local = "ncells", .type = "INTEGER" },
        .{ .module = "Grid", .name = "Origin", .local = "origin", .type = "TYPE(point)" },
        .{ .module = "grid", .name = "cx", .local = "CX", .type = "REAL" },
        .{ .module = "counters", .name = "hits", .local = "nhits", .type = "INTEGER" },
    };
    const pairs = try candidates(a, &kids, &used);
    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expectEqualStrings("cx", pairs[0].local);
    try std.testing.expectEqualStrings("grid::cx", pairs[0].full);
    try std.testing.expectEqualStrings("origin", pairs[1].local);
    try std.testing.expectEqualStrings("grid::origin", pairs[1].full);
    const c = try command(a, pairs);
    try std.testing.expect(std.mem.startsWith(u8, c, "python exec(\"import gdb, re\\n"));
    try std.testing.expect(std.mem.endsWith(u8, c, ", {'P': [[\"cx\",\"grid::cx\"],[\"origin\",\"grid::origin\"]]})"));
    try std.testing.expect(isListed("zfls-use cx\r\nzfls-use origin\n", "origin"));
    try std.testing.expect(!isListed("zfls-use cx\n", "c"));
    try std.testing.expect(!isListed("", "cx"));
}
