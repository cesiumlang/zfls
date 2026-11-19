//! The stop at the start of `zfls dap`'s gdb backend (gdb_requests.zig)
//! for LLVM Flang's programs. gdb's own (`stopAtBeginningOfMainSubprogram`,
//! its `start`) stops in C's `main`, which Flang writes for the program
//! (the line of END PROGRAM), not in the main program, `_QQmain`, though
//! the DWARF marks that one as the main subprogram (gdb 17.2, Flang 23 on
//! Windows). So for a program with a `_QQmain` the adapter stops there by
//! a function breakpoint of its own, which the stop calls the entry and
//! which goes once it has stopped the program; for the others gdb's stays.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;
const Session = @import("session.zig").Session;
const gdb_requests = @import("gdb_requests.zig");

/// LLVM Flang's main program
pub const flang_main = "_QQmain";

/// At `launch` with `stopAtEntry`: the adapter's own stop at the start,
/// when `program` (relative to `cwd`) is LLVM Flang's. True when it is,
/// and gdb's stop at the start is not wanted.
pub fn atLaunch(s: *Session, a: Allocator, program: ?[]const u8, cwd: ?[]const u8) bool {
    s.g.entry_function = null;
    s.g.entry_breakpoint = null;
    s.g.entry_hit = false;
    const p = program orelse return false;
    const path = if (cwd) |c| (if (std.Io.Dir.path.isAbsolute(p)) p else std.Io.Dir.path.join(a, &.{ c, p }) catch p) else p;
    if (!programHas(s.io, path, flang_main)) return false;
    s.g.entry_function = flang_main;
    return true;
}

/// At `configurationDone`, before the program runs: the breakpoint of the
/// stop at the start, with the function breakpoints
pub fn beforeRun(s: *Session, a: Allocator) !void {
    if (s.g.entry_function == null) return;
    _ = try gdb_requests.syncFunctions(s, a);
}

/// After the stop at the start: its breakpoint gone
pub fn afterEntry(s: *Session, a: Allocator) !void {
    if (!s.g.entry_hit) return;
    s.g.entry_function = null;
    s.g.entry_breakpoint = null;
    s.g.entry_hit = false;
    _ = try gdb_requests.syncFunctions(s, a);
}

/// Whether the file at `path` has the bytes of `name` followed by a 0 (a
/// symbol's name in the program's string tables), read a piece at a time
pub fn programHas(io: Io, path: []const u8, name: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    // the end of the piece before, in case the name spans two
    var kept: usize = 0;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositionalAll(io, buf[kept..], offset) catch return false;
        if (n == 0) return false;
        offset += n;
        const have = buf[0 .. kept + n];
        var at: usize = 0;
        while (std.mem.findPos(u8, have, at, name)) |i| : (at = i + 1) {
            if (i + name.len < have.len and have[i + name.len] == 0) return true;
        }
        kept = @min(have.len, name.len);
        @memmove(buf[0..kept], have[have.len - kept ..]);
        if (n < buf.len - kept) {
            // the file's end: the name at the end has no 0 after it
            return false;
        }
    }
}

test "a program's symbol, also across two pieces of the file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { usize, bool }{ .{ 10, true }, .{ (1 << 16) - 3, true }, .{ (1 << 16) - 7, true }, .{ 3 << 16, true } };
    for (cases) |c| {
        const at, const want = c;
        const bytes = try std.testing.allocator.alloc(u8, at + 64);
        defer std.testing.allocator.free(bytes);
        @memset(bytes, 'x');
        @memcpy(bytes[at..][0 .. flang_main.len + 1], flang_main ++ "\x00");
        try tmp.dir.writeFile(io, .{ .sub_path = "p.exe", .data = bytes });
        const path = try tmp.dir.realPathFileAlloc(io, "p.exe", std.testing.allocator);
        defer std.testing.allocator.free(path);
        try std.testing.expectEqual(want, programHas(io, path, flang_main));
    }
    // a longer name, or one at the end without its 0, is not the symbol
    try tmp.dir.writeFile(io, .{ .sub_path = "q.exe", .data = "abc\x00_QQmainx\x00 _QQmain" });
    const q = try tmp.dir.realPathFileAlloc(io, "q.exe", std.testing.allocator);
    defer std.testing.allocator.free(q);
    try std.testing.expect(!programHas(io, q, flang_main));
    try std.testing.expect(!programHas(io, "no such program", flang_main));
}
