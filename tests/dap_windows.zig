//! zfls dap, the debug adapter over Windows's Debugger Engine (the
//! launch's `dbgeng`), on a program of the MSVC ABI with a PDB
//! (tests/dap/hello.c, built by `zig cc`): a breakpoint, the stack, the
//! variables, stepping, an expression, the end (`zig build test-dap`). The
//! Fortran values (of ifx's programs) need ifx, which CI has not.
//!
//!     dap_windows --zfls ZFLS.EXE [--zig ZIG]

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

const source = "tests/dap/hello.c";

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var zig: []const u8 = "zig";
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--zig")) {
            zig = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null) {
        std.debug.print("usage: dap_windows --zfls ZFLS.EXE [--zig ZIG]\n", .{});
        return 2;
    }
    if (builtin.target.os.tag != .windows) {
        std.debug.print("skipped: Windows only\n", .{});
        return 0;
    }
    const cwd = Io.Dir.cwd();
    const src = try cwd.realPathFileAlloc(io, source, a);
    const src_dir = std.Io.Dir.path.dirname(src).?;
    const exe_zfls = try cwd.realPathFileAlloc(io, zfls_exe.?, a);
    const tmp = try lsp.tempDir(io, a, init.environ_map, "zfls-dap-");
    defer cwd.deleteTree(io, tmp) catch {};
    const exe = try std.Io.Dir.path.join(a, &.{ tmp, "hello.exe" });
    const built = try std.process.run(a, io, .{
        .argv = &.{ zig, "cc", "-target", "x86_64-windows-msvc", "-g", "-O0", src, "-o", exe },
        .cwd = .{ .path = tmp },
    });
    if (!built.term.success()) {
        std.debug.print("zig cc failed:\n{s}{s}\n", .{ built.stdout, built.stderr });
        return 1;
    }
    {
        var names: std.ArrayList(u8) = .empty;
        var dir = try cwd.openDir(io, tmp, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| try names.print(a, " {s}", .{e.name});
        std.debug.print("built:{s}; _NT_SYMBOL_PATH={s}\n", .{ names.items, init.environ_map.get("_NT_SYMBOL_PATH") orelse "(unset)" });
    }

    const c = try Client.start(io, init.gpa, &.{ exe_zfls, "dap" });
    defer c.deinit();
    run(c, exe, tmp, src, src_dir) catch |e| {
        std.debug.print("zfls dap: {s}\n", .{@errorName(e)});
        if (c.child.id != null) c.child.kill(io);
        return 1;
    };
    std.debug.print("zfls dap: all good\n", .{});
    return 0;
}

fn run(c: *Client, exe: []const u8, tmp: []const u8, src: []const u8, src_dir: []const u8) !void {
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    var filter = false;
    for (items(caps, "exceptionBreakpointFilters")) |f| filter = filter or std.mem.eql(u8, str(f, "filter") orelse "", "fortranRuntimeErrors");
    try check(filter, "the filter of Fortran runtime errors", .{});
    // the engine, not gdb (which `initialize` may have started)
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = src_dir, .dbgeng = true });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = 8 }} }), "breakpoints");
    const verified = bps.len > 0 and (get(bps[0], "verified") orelse Value{ .bool = false }).bool;
    try check(verified, "a verified breakpoint ({f})", .{std.json.fmt(if (bps.len > 0) bps[0] else Value.null, .{})});
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{} });
    _ = try c.request("configurationDone", .{});

    var stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint"), "stopped at the breakpoint", .{});
    const thread = int(stopped, "threadId").?;
    var frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 1 and contains(str(frames[0], "name"), "twice") and int(frames[0], "line") == 8, "in twice at line 8 ({s}:{?d})", .{ str(frames[0], "name") orelse "?", int(frames[0], "line") });
    try check(contains(str(frames[1], "name"), "main"), "called by main", .{});
    const scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    const local = items(try c.request("variables", .{ .variablesReference = int(scopes[0], "variablesReference").? }), "variables");
    const n = for (local) |v| {
        if (std.mem.eql(u8, str(v, "name") orelse "", "n")) break str(v, "value") orelse "?";
    } else "(none)";
    try check(std.mem.eql(u8, n, "21"), "n = 21 ({s})", .{n});

    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and int(frames[0], "line") == 9, "next: line 9 ({?d})", .{int(frames[0], "line")});
    const r = try c.request("evaluate", .{ .expression = "doubled", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(r, "result") orelse "", "42"), "doubled = 42 ({s})", .{str(r, "result") orelse "?"});

    _ = try c.request("stepOut", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and contains(str(frames[0], "name"), "main"), "stepOut: back in main ({s})", .{str(frames[0], "name") orelse "?"});

    _ = try c.request("continue", .{ .threadId = thread });
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 3, "exit code 3 ({?d})", .{int(exited, "exitCode")});
    _ = try c.event("terminated");
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
}
