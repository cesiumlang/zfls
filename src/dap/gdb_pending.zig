//! The runtime-error breakpoints of `zfls dap`'s gdb backend that have a
//! condition and are pending (in a shared library not yet loaded, as
//! `_gfortran_generate_error` in Linux's libgfortran.so): gdb disables a
//! pending breakpoint whose condition was set apart from it (gdb's DAP
//! sets it so) at the first re-set that does not find its function, at
//! the load of a library before that one, so that it never stops (gdb
//! 15.1, Ubuntu 24.04, #665). gdb's Python enables such a breakpoint again
//! as gdb finds its function, before the program goes on.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");
const Value = json.Value;

/// The Python of `command`: once, a handler of gdb's `breakpoint_modified`
/// that enables a breakpoint of `zfls_keep` that has a location and is
/// disabled; then `zfls_keep` set to `IDS`
const python =
    \\import gdb
    \\try:
    \\    zfls_keep
    \\except NameError:
    \\    zfls_keep = set()
    \\    def zfls_keep_enabled(bp):
    \\        try:
    \\            if bp.number in zfls_keep and not bp.enabled and not bp.pending:
    \\                bp.enabled = True
    \\        except RuntimeError:
    \\            pass
    \\    gdb.events.breakpoint_modified.connect(zfls_keep_enabled)
    \\zfls_keep.clear()
    \\zfls_keep.update(IDS)
    \\
;

/// gdb's command that keeps the breakpoints `ids` enabled
pub fn command(a: Allocator, ids: []const i64) ![]const u8 {
    var set: std.ArrayList(u8) = .empty;
    try set.append(a, '[');
    for (ids, 0..) |id, i| try set.print(a, "{s}{d}", .{ if (i > 0) ", " else "", id });
    try set.append(a, ']');
    const program = try std.mem.replaceOwned(u8, a, python, "IDS", set.items);
    return a.print("python exec({f})", .{std.json.fmt(program, .{})});
}

test "the command that keeps pending conditional breakpoints enabled" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try command(a, &.{ 3, 12 });
    try std.testing.expect(std.mem.startsWith(u8, c, "python exec(\"import gdb\\n"));
    try std.testing.expect(std.mem.endsWith(u8, c, "zfls_keep.update([3, 12])\\n\")"));
    try std.testing.expect(std.mem.find(u8, c, "breakpoint_modified.connect") != null);
    try std.testing.expect(std.mem.endsWith(u8, try command(a, &.{}), "zfls_keep.update([])\\n\")"));
}

/// After gdb's answer to the function breakpoints (`bps`, of which
/// `conditional` says which have a condition): those with a condition that
/// are pending kept enabled (gdb told when there are any, or were)
pub fn keep(s: *Session, a: Allocator, bps: []const Value, conditional: []const bool) !void {
    var ids: std.ArrayList(i64) = .empty;
    for (bps, conditional) |b, c| {
        if (!c) continue;
        const verified = json.get(b, "verified");
        if (verified != null and verified.? == .bool and verified.?.bool) continue;
        try ids.append(a, json.int(json.get(b, "id")) orelse continue);
    }
    if (ids.items.len == 0 and !s.g.keeps_pending) return;
    s.g.keeps_pending = ids.items.len > 0;
    const r = try gdb.request(s, a, "evaluate", .{ .expression = try command(a, ids.items), .context = "repl" });
    if (!gdb.isSuccess(r)) s.log.warn("zfls dap: pending breakpoints not kept: {s}", .{json.str(json.get(r, "message")) orelse "?"});
}
