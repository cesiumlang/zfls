//! zfls dap on Windows's Debugger Engine, for tests/dap_windows.zig and
//! tests/dap_ifx.zig: function breakpoints (#745) on tests/dap/grid.f90's
//! program (LLVM Flang's and ifx's): a module procedure by its name and
//! by its module's (`work`, `grid::work`), one with a condition, the main
//! program (`main`), and a name of none.

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
    dir: []const u8,
};

const Function = struct { name: []const u8, condition: ?[]const u8 = null };

pub fn run(io: Io, gpa: Allocator, p: Program) !void {
    try stopsIn(io, gpa, p, &.{ .{ .name = "work" }, .{ .name = "nosuch" } }, "work", &.{ true, false });
    try stopsIn(io, gpa, p, &.{.{ .name = "grid::work", .condition = "p%id == 7" }}, "work", &.{true});
    try stopsIn(io, gpa, p, &.{.{ .name = "main" }}, "MAIN", &.{true});
}

/// The program stops first in `frame` (in any case: ifx names it `GRID::WORK`), at a function breakpoint
fn stopsIn(io: Io, gpa: Allocator, p: Program, functions: []const Function, frame: []const u8, verified: []const bool) !void {
    const c = try Client.startEnv(io, gpa, p.argv, p.env);
    defer c.deinit();
    defer c.end(true);
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    const supported = get(caps, "supportsFunctionBreakpoints") orelse Value{ .bool = false };
    try check(supported == .bool and supported.bool, "the engine's supportsFunctionBreakpoints", .{});
    _ = try c.request("launch", .{ .program = p.program, .cwd = p.dir, .sourceRoot = p.dir, .console = "internalConsole", .dbgeng = true });
    _ = try c.event("initialized");
    const bps = items(try c.request("setFunctionBreakpoints", .{ .breakpoints = functions }), "breakpoints");
    for (functions, verified, 0..) |f, want, i| {
        const got = i < bps.len and get(bps[i], "verified").?.bool;
        try check(got == want, "function breakpoint {s}: {s} ({s})", .{ f.name, if (want) "verified" else "unverified", if (i < bps.len) str(bps[i], "message") orelse "-" else "none" });
    }
    _ = try c.request("configurationDone", .{});
    const stopped = get(try c.event("stopped"), "body").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint") and std.ascii.findIgnoreCase(str(frames[0], "name") orelse "", frame) != null, "{s}: stopped in {s} ({s}, {s})", .{ functions[0].name, frame, str(stopped, "reason") orelse "?", str(frames[0], "name") orelse "?" });
}
