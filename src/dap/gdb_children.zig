//! A variable's children (a scope's variables) one at a time, when gdb
//! fails to give them all: those it cannot show are "not available", and
//! the others are shown. gdb 17.2 has an internal error on some of LLVM
//! Flang's polymorphic arrays (a SELECT TYPE's associate name of a type
//! with allocatable components), which gdb survives (gdb.zig) but which
//! fails the request of the whole scope (#439).
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");
const Variable = @import("gdb_variables.zig").Variable;

/// The children of gdb's variable reference `ref`, those gdb fails to show
/// as not available; null when gdb does not say how many there are (its
/// Python's `child_count`) or has gone
pub fn oneByOne(s: *Session, a: Allocator, ref: i64) ?[]Variable {
    if (s.g.exit_message != null) return null;
    const listed = gdb.request(s, a, "evaluate", .{ .expression = command(a, ref) catch return null, .context = "repl" }) catch return null;
    if (!gdb.isSuccess(listed)) return null;
    const known = parse(a, json.str(json.path(listed, &.{ "body", "result" })) orelse "") catch return null;
    const n = known.count orelse return null;
    var out: std.ArrayList(Variable) = .empty;
    for (0..n) |i| {
        const r = gdb.request(s, a, "variables", .{ .variablesReference = ref, .start = i, .count = 1 }) catch return null;
        const got = json.items(json.path(r, &.{ "body", "variables" }));
        if (gdb.isSuccess(r) and got.len == 1) {
            out.append(a, .fromGdb(got[0])) catch return null;
            continue;
        }
        if (s.g.exit_message != null) return null;
        out.append(a, .{
            .name = if (i < known.names.len) known.names[i] else a.print("({d})", .{i + 1}) catch return null,
            .value = s.text.not_available,
        }) catch return null;
    }
    return out.items;
}

/// gdb's Python's own record of the reference (gdb's DAP, `gdb.dap.varref`):
/// its number of children, and a scope's names of its variables
const python =
    \\try:
    \\    import gdb.dap.varref as zv
    \\    r = zv.find_variable(R)
    \\    print('zfls-children %d' % r.child_count())
    \\    for v in getattr(r, '_var_list', ()):
    \\        print('zfls-child ' + str(v.symbol()))
    \\except Exception:
    \\    pass
    \\
;

/// The gdb command that prints the children of reference `ref`
fn command(a: Allocator, ref: i64) ![]const u8 {
    return a.print("python exec({f}, {{'R': {d}}})", .{ std.json.fmt(python, .{}), ref });
}

const Children = struct { count: ?usize = null, names: []const []const u8 = &.{} };

/// The output of `command`
fn parse(a: Allocator, output: []const u8) !Children {
    var out: Children = .{};
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "zfls-children ")) {
            out.count = std.fmt.parseInt(usize, line["zfls-children ".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, line, "zfls-child ")) try names.append(a, line["zfls-child ".len..]);
    }
    out.names = names.items;
    return out;
}

test "the children that gdb's Python counts and names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try command(a, 12);
    try std.testing.expect(std.mem.startsWith(u8, c, "python exec(\"try:\\n"));
    try std.testing.expect(std.mem.endsWith(u8, c, "{'R': 12})"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, c, "\n") + 1);
    const got = try parse(a, "zfls-children 3\r\nzfls-child k\nzfls-child q\nzfls-child ts\n");
    try std.testing.expectEqual(@as(?usize, 3), got.count);
    try std.testing.expectEqual(@as(usize, 3), got.names.len);
    try std.testing.expectEqualStrings("q", got.names[1]);
    // a value's children: a number, no names
    const value = try parse(a, "zfls-children 2\n");
    try std.testing.expectEqual(@as(?usize, 2), value.count);
    try std.testing.expectEqual(@as(usize, 0), value.names.len);
    // gdb's Python without it
    try std.testing.expectEqual(@as(?usize, null), (try parse(a, "")).count);
}
