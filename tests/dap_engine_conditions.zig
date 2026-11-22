//! zfls dap on Windows's Debugger Engine, for tests/dap_windows.zig and
//! tests/dap_ifx.zig: breakpoints of a condition, a hit condition and a log
//! message on tests/dap/grid.f90's loop `do k = -1, 1` (LLVM Flang's and
//! ifx's programs), as gdb's are (tests/dap_gdb_conditions.zig): the
//! condition in Fortran, the hit condition the hits ignored, the message's
//! `{k}` the value of `k`, without a stop (#734).

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
    /// `zfls dap`, and its environment (ifx's runtime on the PATH)
    argv: []const []const u8,
    env: ?*const std.process.Environ.Map = null,
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    /// The line in the loop, and the main program's after it
    loop_line: i64,
    main_line: i64,
};

const Breakpoint = struct { line: i64, condition: ?[]const u8 = null, hitCondition: ?[]const u8 = null, logMessage: ?[]const u8 = null };

pub fn run(io: Io, gpa: Allocator, p: Program) !void {
    try stopsAt(io, gpa, p, .{ .line = p.loop_line, .condition = "k == 1" }, "1");
    try stopsAt(io, gpa, p, .{ .line = p.loop_line, .hitCondition = "2" }, "1");
    try stopsAt(io, gpa, p, .{ .line = p.loop_line, .condition = "k .ne. 0 .and. k < 1" }, "-1");
    try stopsAt(io, gpa, p, .{ .line = p.loop_line, .condition = "origin%id == 7 .and. ncells > 41 .and. k == 0" }, "0");
    try logs(io, gpa, p);
    try badCondition(io, gpa, p);
}

fn start(io: Io, gpa: Allocator, p: Program) !*Client {
    return Client.startEnv(io, gpa, p.argv, p.env);
}

/// The program stops once at `bp`, with `k` = `want`, then at the main
/// program's line
fn stopsAt(io: Io, gpa: Allocator, p: Program, bp: Breakpoint, want: []const u8) !void {
    const c = try start(io, gpa, p);
    defer c.deinit();
    defer end(c);
    const what = bp.condition orelse bp.hitCondition.?;
    const thread = try launch(c, p, &.{ bp, .{ .line = p.main_line } });
    const k = try kAt(c, thread, p.loop_line);
    try check(std.mem.eql(u8, k, want), "the engine, {s}: stopped with k = {s} ({s})", .{ what, want, k });
    _ = try c.request("continue", .{ .threadId = thread });
    _ = try c.event("stopped");
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(frames[0], "line") == p.main_line, "the engine, {s}: then no stop in the loop (line {?d})", .{ what, int(frames[0], "line") });
}

/// A logpoint: its message at each pass, one line each, and no stop
fn logs(io: Io, gpa: Allocator, p: Program) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c = try start(io, gpa, p);
    defer c.deinit();
    defer end(c);
    const thread = try launch(c, p, &.{ .{ .line = p.loop_line, .logMessage = "k is {k}, ncells {ncells}" }, .{ .line = p.main_line } });
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(frames[0], "line") == p.main_line, "the engine, a logpoint: no stop in the loop (line {?d})", .{int(frames[0], "line")});
    const said = try c.outputText(arena.allocator());
    try check(contains(said, "k is -1, ncells 42\n") and contains(said, "k is 0, ncells 42\n") and contains(said, "k is 1, ncells 42\n"), "the engine, a logpoint: its message at each pass, one line each ({s})", .{said[std.mem.find(u8, said, "k is") orelse said.len ..]});
}

/// A condition that cannot be evaluated: the stop, and the reason said
fn badCondition(io: Io, gpa: Allocator, p: Program) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c = try start(io, gpa, p);
    defer c.deinit();
    defer end(c);
    const thread = try launch(c, p, &.{.{ .line = p.loop_line, .condition = "nosuch == 1" }});
    _ = try kAt(c, thread, p.loop_line);
    const said = try c.outputText(arena.allocator());
    try check(contains(said, "Error in testing the condition") and contains(said, "nosuch == 1"), "the engine, an unknown name: a stop, the error said ({s})", .{said[std.mem.find(u8, said, "Error") orelse said.len ..]});
}

/// Launches the program with `bps`: the thread of its first stop
fn launch(c: *Client, p: Program, bps: []const Breakpoint) !i64 {
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    for ([_][]const u8{ "supportsConditionalBreakpoints", "supportsHitConditionalBreakpoints", "supportsLogPoints" }) |name| {
        const v = get(caps, name) orelse Value.null;
        try check(v == .bool and v.bool, "the engine's {s}", .{name});
    }
    _ = try c.request("launch", .{ .program = p.program, .cwd = p.dir, .console = "internalConsole", .sourceRoot = p.dir, .dbgeng = true });
    _ = try c.event("initialized");
    const set = items(try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = bps }), "breakpoints");
    for (set) |b| try check(get(b, "verified").?.bool, "a verified breakpoint at line {?d}", .{int(b, "line")});
    _ = try c.request("configurationDone", .{});
    return int(get(try c.event("stopped"), "body").?, "threadId").?;
}

const Value = std.json.Value;

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
