//! zfls dap on Windows's Debugger Engine, for tests/dap_windows.zig and
//! tests/dap_ifx.zig: `setVariable` and `setExpression` (#745), stopped
//! in tests/dap/grid.f90's `work` (LLVM Flang's and ifx's programs): an
//! element of an assumed-shape array, a module variable, a component of a
//! CLASS argument (a CHARACTER), a value of an expression; what is not set
//! (a whole array, a value of the wrong type) says why.

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
    work_line: i64,
};

pub fn run(io: Io, gpa: Allocator, p: Program) !void {
    const c = try Client.startEnv(io, gpa, p.argv, p.env);
    defer c.deinit();
    defer c.end(true);
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    for ([_][]const u8{ "supportsSetVariable", "supportsSetExpression" }) |name| {
        const v = get(caps, name) orelse Value{ .bool = false };
        try check(v == .bool and v.bool, "the engine's {s}", .{name});
    }
    _ = try c.request("launch", .{ .program = p.program, .cwd = p.dir, .sourceRoot = p.dir, .console = "internalConsole", .dbgeng = true });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = .{.{ .line = p.work_line }} });
    _ = try c.request("configurationDone", .{});
    const stopped = get(try c.event("stopped"), "body").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    const frame = int(frames[0], "id").?;
    const scopes = items(try c.request("scopes", .{ .frameId = frame }), "scopes");
    const locals = items(try c.request("variables", .{ .variablesReference = int(scopes[0], "variablesReference").? }), "variables");
    // a(2) by its array's node
    const a_ref = for (locals) |v| {
        if (std.mem.eql(u8, str(v, "name") orelse "", "a")) break int(v, "variablesReference").?;
    } else return check(false, "a among the locals", .{});
    const set = try c.request("setVariable", .{ .variablesReference = a_ref, .name = "(2)", .value = "100" });
    try check(std.mem.eql(u8, str(set, "value") orelse "", "100.0"), "a(2) set to 100: {s}", .{str(set, "value") orelse "?"});
    try expect(c, frame, "a", "[6.0, 100.0, 3.0]");
    // a module variable by the frame's module node
    const mods = items(try c.request("variables", .{ .variablesReference = int(scopes[1], "variablesReference").? }), "variables");
    const grid = for (mods) |m| {
        if (std.mem.eql(u8, str(m, "name") orelse "", "grid")) break int(m, "variablesReference").?;
    } else return check(false, "module grid", .{});
    const n = try c.request("setVariable", .{ .variablesReference = grid, .name = "ncells", .value = "ncells + 1" });
    try check(std.mem.eql(u8, str(n, "value") orelse "", "43"), "grid::ncells set to ncells + 1: {s}", .{str(n, "value") orelse "?"});
    // components by expressions: a CHARACTER blank-padded, an INTEGER
    const tag = try c.request("setExpression", .{ .expression = "t%tag", .value = "'bye'", .frameId = frame });
    try check(std.mem.eql(u8, str(tag, "value") orelse "", "'bye     '"), "t%tag set to 'bye': {s}", .{str(tag, "value") orelse "?"});
    _ = try c.request("setExpression", .{ .expression = "t%point%id", .value = "2*21", .frameId = frame });
    try expect(c, frame, "t%point%id", "42");
    // not set: a whole array, a LOGICAL for an INTEGER
    for ([_][2][]const u8{ .{ "a", "1" }, .{ "ncells", ".true." } }) |x| {
        const r = try c.response(try c.send("setExpression", .{ .expression = x[0], .value = x[1], .frameId = frame }), "setExpression");
        const ok = (get(r, "success") orelse Value{ .bool = true }).bool;
        const message: []const u8 = str(r, "message") orelse "";
        try check(!ok and message.len > 0, "{s} = {s}: refused ({s})", .{ x[0], x[1], message });
    }
}

fn expect(c: *Client, frame: i64, expr: []const u8, want: []const u8) !void {
    const r = try c.request("evaluate", .{ .expression = expr, .frameId = frame, .context = "watch" });
    try check(std.mem.eql(u8, str(r, "result") orelse "", want), "{s} = {s} ({s})", .{ expr, want, str(r, "result") orelse "?" });
}
