//! The program's end as gdb reports it: gdb's Debug Adapter Protocol gives
//! a program that a signal ended (Flang's runtime aborts, a segmentation
//! fault) the exit code 0, which the client shows as a successful run. gdb
//! has the signal in `$_exitsignal`: the program's `exited` event gets the
//! code 128 + the signal's number, as shells give it, after an `output`
//! event that names the signal.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;

const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");

/// gdb's `exited` event (`body`, changed in place) for the client. gdb's
/// `terminated`, which comes right after it, waits until it has gone
/// (`held`).
pub fn programExited(s: *Session, a: Allocator, body: *Value) void {
    // lldb-dap gives the signal's code itself; the program the adapter
    // stops at `disconnect` or `terminate` (gdb kills it) is not news
    if (s.g.lldb or s.g.stopping) return;
    if ((json.int(json.get(body.*, "exitCode")) orelse 0) != 0) return;
    s.g.exit_pending = true;
    defer s.g.exit_pending = false;
    const r = gdb.request(s, a, "evaluate", .{ .expression = "$_exitsignal", .context = "watch" }) catch return;
    if (!gdb.isSuccess(r)) return;
    // `void` when the program exited by itself
    const n = parseSignal(json.str(json.path(r, &.{ "body", "result" })) orelse return) orelse return;
    if (body.* != .object) body.* = .{ .object = .empty };
    body.object.put(a, "exitCode", .{ .integer = 128 + @as(i64, n) }) catch return;
    s.event(a, "output", .{ .category = "stderr", .output = message(a, s.text.ended_by_signal, n) catch return });
}

/// gdb's `terminated`: held while the `exited` before it is made (true)
pub fn holdTerminated(s: *Session) bool {
    if (!s.g.exit_pending) return false;
    s.g.terminated_held = true;
    return true;
}

/// The `terminated` held, after the `exited` it followed
pub fn releaseTerminated(s: *Session, a: Allocator) void {
    if (!s.g.terminated_held) return;
    s.g.terminated_held = false;
    s.event(a, "terminated", null);
}

/// `$_exitsignal`'s value: the signal's number, or null (`void`)
fn parseSignal(text: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t\r\n"), 10) catch return null;
    return if (n > 0 and n < 128) n else null;
}

/// "The program was ended by a signal: SIGABRT (6)"
fn message(a: Allocator, text: []const u8, n: u8) ![]const u8 {
    return if (signalName(n)) |name|
        a.print("{s}: {s} ({d})\n", .{ text, name, n })
    else
        a.print("{s}: {d}\n", .{ text, n });
}

/// The name of a signal's number: Linux's numbers there (gdb gives the
/// target's), else gdb's own (Windows), which differ at 7, 10 and 12
fn signalName(n: u8) ?[]const u8 {
    const linux = builtin.target.os.tag == .linux;
    return switch (n) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        7 => if (linux) "SIGBUS" else "SIGEMT",
        8 => "SIGFPE",
        9 => "SIGKILL",
        10 => if (linux) "SIGUSR1" else "SIGBUS",
        11 => "SIGSEGV",
        12 => if (linux) "SIGUSR2" else "SIGSYS",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        else => null,
    };
}

test "the signal that ended the program, from gdb's $_exitsignal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?u8, 6), parseSignal("6"));
    try std.testing.expectEqual(@as(?u8, 11), parseSignal(" 11\n"));
    try std.testing.expectEqual(@as(?u8, null), parseSignal("void"));
    try std.testing.expectEqual(@as(?u8, null), parseSignal("0"));
    try std.testing.expectEqual(@as(?u8, null), parseSignal(""));
    try std.testing.expectEqualStrings("ended: SIGABRT (6)\n", try message(a, "ended", 6));
    try std.testing.expectEqualStrings("ended: 40\n", try message(a, "ended", 40));
    try std.testing.expectEqualStrings("SIGSEGV", signalName(11).?);
}
