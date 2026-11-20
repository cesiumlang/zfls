//! The stop at the start of `zfls dap`'s gdb backend (gdb_requests.zig)
//! for LLVM Flang's programs. gdb's own (`stopAtBeginningOfMainSubprogram`,
//! its `start`) stops in C's `main`, which Flang writes for the program
//! (the line of END PROGRAM), not in the main program, `_QQmain`, though
//! the DWARF marks that one as the main subprogram (gdb 17.2, Flang 23 on
//! Windows). So for a program with a `_QQmain` the adapter stops there by
//! a function breakpoint of its own, which the stop calls the entry and
//! which goes once it has stopped the program; for the others gdb's stays.
//! LFortran's main program is C's `main`, whose line table begins with rows
//! of line 0: gdb's `start`, and a breakpoint on `main`, stop there, at no
//! line (gdb 15.1, LFortran 0.69.0, Linux). For its programs the adapter's
//! stop is a temporary breakpoint at the first line of `main`, which gdb's
//! Python finds in the line table and sets before the program runs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const Value = json.Value;
const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");
const gdb_requests = @import("gdb_requests.zig");

/// LLVM Flang's main program
pub const flang_main = "_QQmain";

/// LFortran's main program (C's)
pub const lfortran_main = "main";

/// gdb's Python that sets a temporary breakpoint at the first line of
/// `main` (of the rows of its line table in its block, the one of the
/// lowest address that has a line; else on `main`) and prints its number:
/// `zfls-entry 3`
const lfortran_entry_python = "python import gdb;s=gdb.lookup_global_symbol('main');b=gdb.block_for_pc(int(s.value().address));l=[e for e in s.symtab.linetable() if b.start<=e.pc<b.end and e.line>0];f=s.symtab.fullname();f=\"'%s'\"%f if ' ' in f else f;p='%s:%d'%(f,min(l,key=lambda e:e.pc).line) if l else 'main';print('zfls-entry %d'%gdb.Breakpoint(p,temporary=True).number)";

/// At `launch` with `stopAtEntry`: the adapter's own stop at the start,
/// when `program` (relative to `cwd`) is LLVM Flang's or LFortran's (as
/// `s.g.lfortran` says). True when it is, and gdb's stop at the start is
/// not wanted.
pub fn atLaunch(s: *Session, a: Allocator, program: ?[]const u8, cwd: ?[]const u8) bool {
    s.g.entry_function = null;
    s.g.entry_breakpoint = null;
    s.g.entry_hit = false;
    const p = program orelse return false;
    const path = if (cwd) |c| (if (std.Io.Dir.path.isAbsolute(p)) p else std.Io.Dir.path.join(a, &.{ c, p }) catch p) else p;
    if (programHas(s.io, path, flang_main)) {
        s.g.entry_function = flang_main;
        return true;
    }
    if (!s.g.lfortran) return false;
    s.g.entry_function = lfortran_main;
    return true;
}

/// At `configurationDone`, before the program runs: the breakpoint of the
/// stop at the start, with the function breakpoints
pub fn beforeRun(s: *Session, a: Allocator) !void {
    const f = s.g.entry_function orelse return;
    // LFortran's: gdb's breakpoint, not a function breakpoint
    if (std.mem.eql(u8, f, lfortran_main)) {
        s.g.entry_function = null;
        const r = try gdb.request(s, a, "evaluate", .{ .expression = lfortran_entry_python, .context = "repl" });
        const id = entryResult(json.str(json.path(r, &.{ "body", "result" })) orelse "");
        if (id == null) s.log.warn("zfls dap: no stop at the start of LFortran's main: {s}", .{json.str(json.path(r, &.{ "body", "result" })) orelse json.str(json.get(r, "message")) orelse "?"});
        s.g.entry_breakpoint = id;
        return;
    }
    _ = try gdb_requests.syncFunctions(s, a);
}

/// The breakpoint that `lfortran_entry_python` set, as it printed it
pub fn entryResult(output: []const u8) ?i64 {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, l, "zfls-entry ")) return std.fmt.parseInt(i64, l["zfls-entry ".len..], 10) catch null;
    }
    return null;
}

test "the breakpoint at the first line of LFortran's main, as gdb's Python prints it" {
    try std.testing.expectEqual(@as(?i64, 3), entryResult("zfls-entry 3\n"));
    try std.testing.expectEqual(@as(?i64, 12), entryResult("Temporary breakpoint 12 at 0x401136: file /tmp/a b/grid.f90, line 41.\r\nzfls-entry 12\r\n"));
    try std.testing.expect(entryResult("Traceback (most recent call last):\nAttributeError: 'NoneType' object has no attribute 'value'\n") == null);
    try std.testing.expect(entryResult("") == null);
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
