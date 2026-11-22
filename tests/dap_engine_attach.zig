//! zfls dap attaching with Windows's Debugger Engine, for
//! tests/dap_windows.zig: to tests/dap/wait.c's program by its process id
//! while it waits for its input; a breakpoint, a variable, then detached,
//! the program's own end (#738).

const std = @import("std");
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

extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) u32;

pub fn run(io: Io, gpa: Allocator, zfls: []const u8, exe: []const u8, src: []const u8, tmp: []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = &.{exe}, .cwd = .{ .path = tmp }, .stdin = .pipe, .stdout = .pipe, .create_no_window = true });
    var waited = false;
    defer if (!waited) child.kill(io);
    const c = try Client.start(io, gpa, &.{ zfls, "dap" });
    defer c.deinit();
    session(c, &child, GetProcessId(child.id.?), src) catch |e| {
        if (c.child.id != null) c.child.kill(io);
        return e;
    };
    _ = try c.child.wait(c.io);
    var buf: [256]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &buf);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    while (r.interface.takeByte()) |ch| try out.append(gpa, ch) else |_| {}
    const term = try child.wait(io);
    waited = true;
    try check(contains(out.items, "6") and term == .exited and term.exited == 4, "the engine's attach: detached, the program ends by itself ({s}, {any})", .{ std.mem.trim(u8, out.items, "\r\n"), term });
}

fn session(c: *Client, child: *std.process.Child, pid: u32, src: []const u8) !void {
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    _ = try c.request("attach", .{ .processId = pid, .dbgeng = true });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = 8 }} }), "breakpoints");
    try check(bps.len == 1 and get(bps[0], "verified").?.bool, "the engine's attach: a verified breakpoint", .{});
    _ = try c.request("configurationDone", .{});
    try child.stdin.?.writeStreamingAll(c.io, "3\n");
    const stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint") and contains(str(frames[0], "name"), "twice") and int(frames[0], "line") == 8, "the engine's attach: in twice at line 8 ({s}:{?d})", .{ str(frames[0], "name") orelse "?", int(frames[0], "line") });
    const n = try c.request("evaluate", .{ .expression = "n", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(n, "result") orelse "", "3"), "the engine's attach: n = 3 ({s})", .{str(n, "result") orelse "?"});
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{} });
    _ = try c.request("disconnect", .{ .terminateDebuggee = false });
}
