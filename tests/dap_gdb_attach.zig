//! zfls dap with gdb attaching, for tests/dap_gdb.zig: to a running
//! program by its process id, and to one under gdbserver (`target`), each
//! waiting for its input (tests/dap/attach.f90): a breakpoint, a variable,
//! and the program's own end after the session's (#738).

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

pub const Program = struct {
    /// `zfls dap` with its gdb
    argv: []const []const u8,
    /// tests/dap/attach.f90's
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    /// The line marked `stop here`
    line: i64,
};

/// Attaching by the program's process id; detached, it ends by itself
pub fn byProcessId(io: Io, gpa: Allocator, p: Program) !void {
    // Yama's ptrace_scope 1 (Ubuntu's default) lets gdb attach to its own
    // children only
    if (sysinfo.target.os.tag == .linux) {
        var buf: [8]u8 = undefined;
        const scope = Io.Dir.cwd().readFile(io, "/proc/sys/kernel/yama/ptrace_scope", &buf) catch "0";
        if (!std.mem.eql(u8, std.mem.trim(u8, scope, " \n"), "0")) return std.debug.print("attach by process id: skipped: kernel.yama.ptrace_scope is {s}\n", .{std.mem.trim(u8, scope, " \n")});
    }
    var child = try std.process.spawn(io, .{ .argv = &.{p.program}, .cwd = .{ .path = p.dir }, .stdin = .pipe, .stdout = .pipe, .create_no_window = true });
    var waited = false;
    defer if (!waited) child.kill(io);
    const c = try Client.start(io, gpa, p.argv);
    defer c.deinit();
    defer c.end(false);
    try session(c, p, &child, .{ .processId = processId(child), .program = p.program }, "attach by process id");
    c.end(false);
    try check(try finished(io, gpa, &child), "attach by process id: detached, the program ends by itself", .{});
    waited = true;
}

/// Attaching to gdbserver's program (`target`), which it starts stopped
pub fn byTarget(io: Io, gpa: Allocator, p: Program, gdbserver: []const u8) !void {
    const version = std.process.run(gpa, io, .{ .argv = &.{ gdbserver, "--version" } }) catch
        return std.debug.print("attach to gdbserver: skipped: no {s}\n", .{gdbserver});
    defer gpa.free(version.stdout);
    defer gpa.free(version.stderr);
    if (endsAtResume(io, version.stdout)) return std.debug.print("attach to gdbserver: skipped: gdbserver before 16.3 fails at the first resume on AArch64 with SVE\n", .{});
    // a port of the system's choice, which gdbserver tells
    var server = try std.process.spawn(io, .{ .argv = &.{ gdbserver, "--once", "localhost:0", p.program }, .cwd = .{ .path = p.dir }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
    var waited = false;
    defer if (!waited) server.kill(io);
    const port = try listening(io, &server) orelse return check(false, "gdbserver's port", .{});
    var target_buf: [32]u8 = undefined;
    const target = try std.mem.print(&target_buf, "localhost:{d}", .{port});
    const c = try Client.start(io, gpa, p.argv);
    defer c.deinit();
    defer c.end(true);
    try session(c, p, &server, .{ .target = target, .program = p.program }, "attach to gdbserver");
    c.end(true);
    _ = try server.wait(io);
    waited = true;
}

/// gdbserver 15.1 to 16.2 on Linux AArch64 with SVE fails an assertion
/// (`raw_compare: Assertion 'offset < regbuf.size ()' failed`) at the
/// program's first resume, which then runs to its end, also under gdb's
/// own commands (CI run 45030774745, Ubuntu 24.04's 15.1; fixed in gdb
/// 16.3, its commit 5c89e55): by `said` of `--version`
fn endsAtResume(io: Io, said: []const u8) bool {
    if (sysinfo.target.os.tag != .linux or sysinfo.target.cpu.arch != .aarch64) return false;
    const first = std.mem.trimEnd(u8, std.mem.sliceTo(said, '\n'), " \r");
    var it = std.mem.splitScalar(u8, first[(std.mem.findScalarLast(u8, first, ' ') orelse return false) + 1 ..], '.');
    const major = leading(it.next() orelse "") orelse return false;
    const minor = leading(it.next() orelse "") orelse 0;
    if (major > 16 or (major == 16 and minor >= 3)) return false;
    var buf: [8192]u8 = undefined;
    const info = Io.Dir.cwd().readFile(io, "/proc/cpuinfo", &buf) catch return true;
    return std.mem.find(u8, info, " sve") != null;
}

/// The number that `text` begins with
fn leading(text: []const u8) ?u32 {
    const end = std.mem.findNone(u8, text, "0123456789") orelse text.len;
    return std.fmt.parseInt(u32, text[0..end], 10) catch null;
}

/// The session: attached, the program given its input, stopped at its
/// breakpoint, then on
fn session(c: *Client, p: Program, child: *std.process.Child, args: anytype, what: []const u8) !void {
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    const attached = try c.send("attach", args);
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = .{.{ .line = p.line }} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(attached, "attach"), "attach");
    // gdb stops the program it attaches to (gdb 15 tells no stop of a
    // target's): on, to its input
    const threads = items(try c.request("threads", .{}), "threads");
    try check(threads.len > 0, "{s}: {d} threads", .{ what, threads.len });
    _ = try c.request("continue", .{ .threadId = int(threads[0], "id").? });
    try child.stdin.?.writeStreamingAll(c.io, "3\n");
    const stopped = while (true) {
        const e = c.event("stopped") catch |err| {
            const said = c.outputText(c.gpa) catch "";
            defer if (said.len > 0) c.gpa.free(said);
            std.debug.print("{s}: no stop at the breakpoint; the adapter said: {s}\n", .{ what, said[said.len -| 2000..] });
            return err;
        };
        const b = get(e, "body").?;
        if (std.mem.eql(u8, str(b, "reason") orelse "", "breakpoint")) break b;
    };
    const thread = int(stopped, "threadId").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint") and int(frames[0], "line") == p.line, "{s}: at the breakpoint, line {d} ({s}, {?d})", .{ what, p.line, str(stopped, "reason") orelse "?", int(frames[0], "line") });
    const n = try c.request("evaluate", .{ .expression = "n", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(n, "result") orelse "", "3"), "{s}: n = 3 ({s})", .{ what, str(n, "result") orelse "?" });
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = .{} });
}

/// The program's end of its own: `total 6`, exit code 0
fn finished(io: Io, gpa: Allocator, child: *std.process.Child) !bool {
    var buf: [256]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &buf);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    while (r.interface.takeByte()) |ch| try out.append(gpa, ch) else |_| {}
    const term = try child.wait(io);
    std.debug.print("the program said {s}", .{out.items});
    return contains(out.items, "total 6") and term == .exited and term.exited == 0;
}

/// gdbserver's port (`Listening on port N`), from its first lines
fn listening(io: Io, server: *std.process.Child) !?u16 {
    var buf: [1024]u8 = undefined;
    var r = server.stderr.?.readerStreaming(io, &buf);
    for (0..10) |_| {
        const line = r.interface.takeDelimiterExclusive('\n') catch return null;
        r.interface.toss(1);
        std.debug.print("gdbserver: {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
        const mark = "Listening on port ";
        const at = std.mem.find(u8, line, mark) orelse continue;
        return std.fmt.parseInt(u16, std.mem.trim(u8, line[at + mark.len ..], " \r"), 10) catch null;
    }
    return null;
}

extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) u32;

fn processId(child: std.process.Child) i64 {
    return if (sysinfo.target.os.tag == .windows) GetProcessId(child.id.?) else child.id.?;
}
