//! lldb-dap on Windows (#452): LLVM's from 23.1.6 on. Before LLVM 23
//! (21.1, the Swift toolchain's) lldb-dap stopped the program but told the
//! stop only when the next request came, so a session waited for ever.
//!
//! LLVM 23's lldb can report a stop at a breakpoint twice: after a stop at
//! one of zfls's breakpoints on the runtime's functions that do not return
//! (runtime errors, ERROR STOP), `continue` reports the same breakpoint on
//! the same thread again, and the program never exits. `repeatsStop` tells
//! that second stop, which is continued. LLVM 24 should not need it (#947).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The oldest lldb-dap that works on Windows
pub const oldest: std.SemanticVersion = .{ .major = 23, .minor = 1, .patch = 6 };

/// Why an older lldb-dap is refused
pub const too_old = "zfls dap: lldb-dap before LLVM 23.1.6 does not tell when a Windows program stops, so a session would wait for ever. Use LLVM 23.1.6's or later (`lldb` in the launch configuration, or --lldb PATH), or debug with gdb (`gdb`, or --gdb PATH) or with Windows's Debugger Engine (`dbgeng: true`)";

/// The LLVM version in `lldb-dap --version`'s text ("LLVM version 23.1.6")
pub fn parseVersion(text: []const u8) ?std.SemanticVersion {
    const head = "LLVM version ";
    const at = std.mem.find(u8, text, head) orelse return null;
    const rest = text[at + head.len ..];
    const end = std.mem.findNone(u8, rest, "0123456789.") orelse rest.len;
    var it = std.mem.splitScalar(u8, rest[0..end], '.');
    var parts: [3]usize = .{ 0, 0, 0 };
    for (&parts) |*p| p.* = std.fmt.parseInt(usize, it.next() orelse break, 10) catch return null;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

/// Why lldb-dap `exe` cannot debug here, or null: it does not start, or
/// runs and fails (LLVM's needs a `python3.dll` on the PATH, #974), or is
/// before LLVM 23.1.6
pub fn refusal(a: Allocator, io: Io, environ: *const std.process.Environ.Map, exe: []const u8) !?[]const u8 {
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };
    const r = std.process.run(a, io, .{ .argv = &.{ exe, "--version" }, .environ_map = environ, .timeout = timeout }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try a.print("zfls dap: lldb-dap ({s}) did not start: {s}", .{ exe, @errorName(e) }),
    };
    if (parseVersion(r.stdout)) |v| return if (v.order(oldest) == .lt) too_old else null;
    const said = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \t\r\n");
    const ran = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ran and said.len > 0) return too_old;
    const status = switch (r.term) {
        .exited => |code| try a.print("exit code {d}", .{code}),
        .unknown => |code| try a.print("status 0x{x}", .{code}),
        else => "stopped by a signal",
    };
    return try a.print("zfls dap: lldb-dap ({s}) did not run ({s}{s}{s}); LLVM's lldb-dap on Windows needs a python3.dll on the PATH (Python 3's)", .{ exe, status, if (said.len > 0) ": " else "", said[0..@min(said.len, 400)] });
}

/// Whether a stop at the runtime's function `hit` on `thread` is lldb's
/// second report of the previous stop: the same function on the same thread
pub fn repeatsStop(hit: ?[]const u8, thread: ?i64, last: ?[]const u8, last_thread: ?i64) bool {
    const f = hit orelse return false;
    const l = last orelse return false;
    return thread != null and thread == last_thread and std.mem.eql(u8, f, l);
}

test "the LLVM version of lldb-dap --version" {
    const v = parseVersion("lldb-dap: LLVM (http://llvm.org/):\n  LLVM version 23.1.6\n  Optimized build.\n").?;
    try std.testing.expectEqual(std.SemanticVersion{ .major = 23, .minor = 1, .patch = 6 }, v);
    try std.testing.expectEqual(std.math.Order.lt, parseVersion("  LLVM version 21.1.6\n").?.order(oldest));
    try std.testing.expectEqual(std.math.Order.gt, parseVersion("LLVM version 24.1.0git\n").?.order(oldest));
    try std.testing.expectEqual(@as(?std.SemanticVersion, null), parseVersion("lldb-dap 1.0"));
}

test "a stop repeats the previous one: the same function on the same thread" {
    const f = "_gfortran_runtime_error_at";
    try std.testing.expect(repeatsStop(f, 7, f, 7));
    try std.testing.expect(!repeatsStop(f, 7, f, 8));
    try std.testing.expect(!repeatsStop(f, 7, null, 7));
    try std.testing.expect(!repeatsStop(null, 7, f, 7));
    try std.testing.expect(!repeatsStop(f, 7, "_gfortran_error_stop_numeric", 7));
    try std.testing.expect(!repeatsStop(f, null, f, null));
}
