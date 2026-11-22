//! zfls dap's Debug Console completions of Fortran names (#744), for
//! tests/dap_gdb.zig (gdb, whose console takes its commands: `p origin%`)
//! and tests/dap_windows.zig (the engine, whose console takes expressions:
//! `origin%`), stopped in tests/dap/grid.f90's `work`: after `%` a
//! component's names, else the frame's variables and the module variables
//! its line sees; with gdb, its own completion of commands still.

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
const check = dap.check;

pub const Program = struct {
    /// `zfls dap` with its debugger, and its environment
    argv: []const []const u8,
    env: ?*const std.process.Environ.Map = null,
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    work_line: i64,
    /// Windows's Debugger Engine, not gdb
    engine: bool,
};

pub fn run(io: Io, gpa: Allocator, p: Program) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try Client.startEnv(io, gpa, p.argv, p.env);
    defer c.deinit();
    defer c.end(true);
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path" });
    var pct = false;
    for (items(caps, "completionTriggerCharacters")) |t| pct = pct or std.mem.eql(u8, t.string, "%");
    try check(pct and (get(caps, "supportsCompletionsRequest") orelse Value{ .bool = false }).bool, "completions, `%` a trigger character", .{});
    const launched = try c.send("launch", .{ .program = p.program, .cwd = p.dir, .sourceRoot = p.dir, .console = "internalConsole", .dbgeng = p.engine });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = p.src }, .breakpoints = .{.{ .line = p.work_line }} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const stopped = get(try c.event("stopped"), "body").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    const frame = int(frames[0], "id").?;
    // gdb's console takes commands: the expression after `p `
    const cmd: []const u8 = if (p.engine) "" else "p ";
    const cases = [_]struct { []const u8, []const u8, i64 }{
        // a module variable's components
        .{ "origin%", "id,x,y", 0 },
        .{ "origin%i", "id", 1 },
        // a dummy argument's of a derived type, a CLASS one's
        .{ "p%", "id,x,y", 0 },
        .{ "t%ta", "tag", 2 },
        // the frame's variables and module variables
        .{ "nc", "ncells", 2 },
        .{ "se", "secret", 2 },
    };
    for (cases) |x| {
        const text = try a.print("{s}{s}", .{ cmd, x[0] });
        const r = try c.request("completions", .{ .text = text, .column = text.len + 1, .frameId = frame });
        const got = try labels(a, items(r, "targets"));
        try check(std.mem.eql(u8, got, x[1]), "{s}: {s} ({s})", .{ text, x[1], got });
        const t = items(r, "targets")[0];
        try check(int(t, "length") == x[2] and int(t, "start") == @as(i64, @intCast(text.len + 1)) - x[2], "{s}: replaces {d} characters from column {d} ({?d}, {?d})", .{ text, x[2], @as(i64, @intCast(text.len + 1)) - x[2], int(t, "length"), int(t, "start") });
    }
    if (!p.engine) {
        // gdb's own: its commands
        const r = try c.request("completions", .{ .text = "inf", .column = 4, .frameId = frame });
        const got = try labels(a, items(r, "targets"));
        try check(std.mem.find(u8, got, "info") != null, "inf: gdb's commands ({s})", .{got});
    }
}

/// The targets' labels, sorted, in one text
fn labels(a: Allocator, targets: []Value) ![]const u8 {
    const names = try a.alloc([]const u8, targets.len);
    for (targets, names) |t, *n| n.* = str(t, "label") orelse "?";
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.join(a, ",", names);
}
