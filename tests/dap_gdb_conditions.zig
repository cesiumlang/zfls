//! zfls dap with gdb, for tests/dap_gdb.zig: breakpoints of a condition, of
//! a hit condition and of a log message (tests/dap/grid.f90's loop `do k =
//! -1, 1`), each as gdb takes it: the condition in Fortran, the hit
//! condition the number of hits ignored, the message's `{k}` the value of
//! `k`, without a stop (#737).

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

pub const Program = struct {
    /// `zfls dap` with its gdb
    argv: []const []const u8,
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    /// The line in the loop, and one after it
    loop_line: i64,
    main_line: i64,
};

const Breakpoint = struct { line: i64, condition: ?[]const u8 = null, hitCondition: ?[]const u8 = null, logMessage: ?[]const u8 = null };

pub fn run(io: Io, gpa: Allocator, p: Program) !void {
    // the condition: the loop's last pass alone
    try stopsAt(io, gpa, p, .{ .line = p.loop_line, .condition = "k == 1" }, &.{"1"});
    // gdb's ignore count: the first two passes ignored
    try stopsAt(io, gpa, p, .{ .line = p.loop_line, .hitCondition = "2" }, &.{"1"});
    // a condition of Fortran's operators
    try stopsAt(io, gpa, p, .{ .line = p.loop_line, .condition = "k .ne. 0 .and. k < 1" }, &.{"-1"});
    try logs(io, gpa, p);
}

/// The program stops at `bp` with `k` of each of `values`, then at the
/// main program's line
fn stopsAt(io: Io, gpa: Allocator, p: Program, bp: Breakpoint, values: []const []const u8) !void {
    const c = try Client.start(io, gpa, p.argv);
    defer c.deinit();
    defer end(c);
    const thread = try launch(c, p, &.{ bp, .{ .line = p.main_line } });
    for (values, 0..) |want, i| {
        if (i > 0) _ = try c.event("stopped");
        const k = try kAt(c, thread, p.loop_line);
        try check(std.mem.eql(u8, k, want), "{s}{s}: stopped with k = {s} ({s})", .{ bp.condition orelse "", bp.hitCondition orelse "", want, k });
        _ = try c.request("continue", .{ .threadId = thread });
    }
    const stopped = get(try c.event("stopped"), "body").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    try check(int(frames[0], "line") == p.main_line, "{s}{s}: then no stop in the loop (line {?d})", .{ bp.condition orelse "", bp.hitCondition orelse "", int(frames[0], "line") });
}

/// A logpoint: its message at each pass, one line each, and no stop
fn logs(io: Io, gpa: Allocator, p: Program) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c = try Client.start(io, gpa, p.argv);
    defer c.deinit();
    defer end(c);
    const thread = try launch(c, p, &.{ .{ .line = p.loop_line, .logMessage = "k is {k}" }, .{ .line = p.main_line } });
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(frames[0], "line") == p.main_line, "a logpoint: no stop in the loop (line {?d})", .{int(frames[0], "line")});
    const said = try c.outputText(arena.allocator());
    try check(contains(said, "k is -1\n") and contains(said, "k is 0\n") and contains(said, "k is 1\n"), "a logpoint: its message at each pass, one line each ({s})", .{said[std.mem.find(u8, said, "k is") orelse said.len ..]});
}

/// Launches the program with `bps`: the thread of its first stop
fn launch(c: *Client, p: Program, bps: []const Breakpoint) !i64 {
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    const launched = try c.send("launch", .{ .program = p.program, .cwd = p.dir, .sourceRoot = p.dir });
    _ = try c.event("initialized");
    const set = items(try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = bps }), "breakpoints");
    // gdb's, pending until the program is loaded at configurationDone
    try check(set.len == bps.len, "{d} breakpoints", .{set.len});
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    return int(get(try c.event("stopped"), "body").?, "threadId").?;
}

/// The value of `k` at a stop at `line`
fn kAt(c: *Client, thread: i64, line: i64) ![]const u8 {
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(frames[0], "line") == line, "stopped at line {d} ({?d})", .{ line, int(frames[0], "line") });
    const k = try c.request("evaluate", .{ .expression = "k", .frameId = int(frames[0], "id").?, .context = "watch" });
    return str(k, "result") orelse "?";
}

fn end(c: *Client) void {
    if (c.send("disconnect", .{ .terminateDebuggee = true })) |seq| {
        _ = c.response(seq, "disconnect") catch {};
    } else |_| {}
    c.child.stdin.?.close(c.io);
    c.child.stdin = null;
    _ = c.child.wait(c.io) catch {};
}
