//! zfls dap's data breakpoints (#746), for tests/dap_gdb.zig (gdb's
//! watchpoints), tests/dap_windows.zig and tests/dap_ifx.zig (the engine's
//! processor breakpoints), on tests/dap/grid.f90's main program: an
//! array's element (`m(2,1)`, written in the loop when `k` is 1) and a
//! component (`origin%x`, set to 9.0 after it) stop where they are
//! written; a whole array and a whole derived type (12 bytes) have none.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

pub const Program = struct {
    argv: []const []const u8,
    env: ?*const std.process.Environ.Map = null,
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    /// Windows's Debugger Engine, not gdb
    engine: bool,
};

pub fn run(io: Io, gpa: Allocator, p: Program) !void {
    // the line before the loop
    const text = try Io.Dir.cwd().readFileAlloc(io, p.src, gpa, .limited(1 << 20));
    defer gpa.free(text);
    const before_line: i64 = @intCast(std.mem.count(u8, text[0 .. std.mem.find(u8, text, "nullify(nothing)") orelse return error.NoMarker], "\n") + 1);
    const c = try Client.startEnv(io, gpa, p.argv, p.env);
    defer c.deinit();
    defer c.end(true);
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    const supported = get(caps, "supportsDataBreakpoints") orelse Value{ .bool = false };
    try check(supported == .bool and supported.bool, "supportsDataBreakpoints", .{});
    const launched = try c.send("launch", .{ .program = p.program, .cwd = p.dir, .sourceRoot = p.dir, .console = "internalConsole", .dbgeng = p.engine });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = .{.{ .line = before_line }} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    var stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    var frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const frame = int(frames[0], "id").?;
    // none for a whole array, nor for 12 bytes
    for ([_][2][]const u8{ .{ "m", "whole array" }, .{ "origin", "origin" } }) |x| {
        const r = try c.request("dataBreakpointInfo", .{ .name = x[0], .frameId = frame });
        const id = get(r, "dataId") orelse Value.null;
        try check(id == .null and contains(str(r, "description"), x[1]), "{s}: no data breakpoint ({s})", .{ x[0], str(r, "description") orelse "?" });
    }
    var ids: [2][]const u8 = undefined;
    for ([_][]const u8{ "m(2,1)", "origin%x" }, &ids) |name, *id| {
        const r = try c.request("dataBreakpointInfo", .{ .name = name, .frameId = frame });
        id.* = str(r, "dataId") orelse return check(false, "{s}: a dataId ({s})", .{ name, str(r, "description") orelse "?" });
    }
    const set = items(try c.request("setDataBreakpoints", .{ .breakpoints = .{ .{ .dataId = ids[0] }, .{ .dataId = ids[1] } } }), "breakpoints");
    try check(set.len == 2 and get(set[0], "verified").?.bool and get(set[1], "verified").?.bool, "two data breakpoints set", .{});
    // m(2,1): written when k is 1
    for ([_][2][]const u8{ .{ "k", "1" }, .{ "origin%x", "9.0" } }) |want| {
        _ = try c.request("continue", .{ .threadId = thread });
        stopped = get(try c.event("stopped"), "body").?;
        frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
        const at = for (frames) |f| {
            if (std.ascii.endsWithIgnoreCase(str(get(f, "source") orelse Value.null, "path") orelse "", "grid.f90")) break int(f, "id").?;
        } else int(frames[0], "id").?;
        const v = try c.request("evaluate", .{ .expression = want[0], .frameId = at, .context = "watch" });
        try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "data breakpoint") and std.mem.eql(u8, str(v, "result") orelse "", want[1]), "a data breakpoint's stop, {s} = {s} ({s}, {s})", .{ want[0], want[1], str(stopped, "reason") orelse "?", str(v, "result") orelse "?" });
    }
}
