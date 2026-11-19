//! zfls dap, the debug adapter over Windows's Debugger Engine (the
//! launch's `dbgeng`), on a program of the MSVC ABI with a PDB
//! (tests/dap/hello.c, built by `zig cc`): a breakpoint, the stack, the
//! variables, stepping, an expression, the end (`zig build test-dap`). The
//! Fortran values (of ifx's programs) need ifx, which CI has not.
//!
//! With LLVM Flang (`--flang`, or FLANG in the environment), also
//! tests/dap/grid.f90 built with `-g` (linked with zfls's ifx kit when it
//! is next to zfls): what the engine does with Flang's programs today, the
//! breakpoints, the stack, a main program's variable, stepping and the stop
//! at Flang's runtime error. What it does not do yet is printed as known
//! gaps and not checked: the dummy arguments (#381, #382, #384), most of
//! the main program's variables (#383), the module variables and the
//! filter of Fortran runtime errors (#380).
//!
//!     dap_windows --zfls ZFLS.EXE [--zig ZIG] [--flang FLANG]

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
    var flang: ?[]const u8 = init.environ_map.get("FLANG");
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--zig")) {
            zig = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--flang")) {
            flang = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null) {
        std.debug.print("usage: dap_windows --zfls ZFLS.EXE [--zig ZIG] [--flang FLANG]\n", .{});
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

    {
        const c = try Client.start(io, init.gpa, &.{ exe_zfls, "dap" });
        defer c.deinit();
        run(c, exe, tmp, src, src_dir) catch |e| {
            std.debug.print("zfls dap: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    std.debug.print("zfls dap: all good\n", .{});
    if (flang) |fc| return withFlang(io, init.gpa, a, init.environ_map, exe_zfls, fc, tmp);
    return 0;
}

/// tests/dap/grid.f90 built by LLVM Flang with `-g` (Microsoft's debug
/// information), under the engine
fn withFlang(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, exe_zfls: []const u8, fc: []const u8, tmp: []const u8) !u8 {
    const version = std.process.run(a, io, .{ .argv = &.{ fc, "--version" } }) catch {
        std.debug.print("LLVM Flang: skipped: no {s}\n", .{fc});
        return 0;
    };
    std.debug.print("-- {s}", .{version.stdout[0 .. (std.mem.findScalar(u8, version.stdout, '\n') orelse version.stdout.len - 1) + 1]});
    const cwd = Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, grid_source, a, .limited(1 << 20));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, "grid.f90" });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    const exe = try std.Io.Dir.path.join(a, &.{ tmp, "grid.exe" });
    const env = try dap.flangKitEnv(io, a, environ, exe_zfls);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ fc, "-g", "-O0" });
    if (env != null) try argv.appendSlice(a, &.{ "-fms-runtime-lib=dll", "-fuse-ld=lld" });
    try argv.appendSlice(a, &.{ "-o", exe, src });
    const built = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = tmp }, .environ_map = env });
    if (!built.term.success()) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ fc, built.stdout, built.stderr });
        return 1;
    }
    const c = try Client.start(io, gpa, &.{ exe_zfls, "dap" });
    defer c.deinit();
    runFlang(c, exe, tmp, src, lineOf(text, "stop here: work"), lineOf(text, "stop here: main"), lineOf(text, "call work(")) catch |e| {
        std.debug.print("zfls dap, LLVM Flang's program: {s}\n", .{@errorName(e)});
        if (c.child.id != null) c.child.kill(io);
        return 1;
    };
    std.debug.print("zfls dap, LLVM Flang's program: all good (but the known gaps)\n", .{});
    return 0;
}

const grid_source = "tests/dap/grid.f90";

/// The 1-based line of a marker of the source
fn lineOf(text: []const u8, marker: []const u8) i64 {
    const at = std.mem.find(u8, text, marker) orelse unreachable;
    return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
}

fn named(vars: []Value, name: []const u8) ?Value {
    for (vars) |v| if (std.mem.eql(u8, str(v, "name") orelse "", name)) return v;
    return null;
}

/// Prints what the engine shows of `vars`, as a known gap
fn gap(what: []const u8, vars: []Value) void {
    std.debug.print("known gap: {s}:", .{what});
    for (vars) |v| std.debug.print(" {s} = {s};", .{ str(v, "name") orelse "?", str(v, "value") orelse "?" });
    std.debug.print("\n", .{});
}

fn scopeVariables(c: *Client, scopes: []Value, name: []const u8) ![]Value {
    const scope = named(scopes, name) orelse return &.{};
    return items(try c.request("variables", .{ .variablesReference = int(scope, "variablesReference").? }), "variables");
}

fn runFlang(c: *Client, exe: []const u8, tmp: []const u8, src: []const u8, work_line: i64, main_line: i64, call_line: i64) !void {
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = tmp, .dbgeng = true });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{ .{ .line = work_line }, .{ .line = main_line } } }), "breakpoints");
    var verified: usize = 0;
    for (bps) |b| verified += @intFromBool((get(b, "verified") orelse Value{ .bool = false }).bool);
    try check(verified == 2, "two verified breakpoints ({d})", .{verified});
    // (the filter of Fortran runtime errors does not find Flang's runtime
    // functions yet, #380: the stop at the error is the engine's own)
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{} });
    _ = try c.request("configurationDone", .{});

    // in work, called by the main program
    var stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint"), "stopped at a breakpoint", .{});
    const thread = int(stopped, "threadId").?;
    var frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 1 and contains(str(frames[0], "name"), "work") and int(frames[0], "line") == work_line, "in grid::work at line {d} ({s}:{?d})", .{ work_line, str(frames[0], "name") orelse "?", int(frames[0], "line") });
    // the caller's line: that of its return address, the line after the
    // CALL when the call is the line's last instruction
    const caller_line = int(frames[1], "line") orelse 0;
    try check(std.mem.eql(u8, str(frames[1], "name") orelse "", "MAIN") and (caller_line == call_line or caller_line == call_line + 1), "called by MAIN at line {d} ({s}:{d})", .{ call_line, str(frames[1], "name") orelse "?", caller_line });
    if (caller_line != call_line) std.debug.print("known gap: the caller's line is that of the return address ({d}), not the CALL's ({d})\n", .{ caller_line, call_line });
    var scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    gap("work's arguments (#381, #382, #384)", try scopeVariables(c, scopes, "Locals"));
    gap("work's module variables (#380)", try scopeVariables(c, scopes, "Module variables"));

    // in the main program: a variable of it, a step
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(frames[0], "name") orelse "", "MAIN") and int(frames[0], "line") == main_line, "in MAIN at line {d} ({s}:{?d})", .{ main_line, str(frames[0], "name") orelse "?", int(frames[0], "line") });
    scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    const locals = try scopeVariables(c, scopes, "Locals");
    // k, after the loop `do k = -1, 1`
    const k = named(locals, "k");
    try check(k != null and std.mem.eql(u8, str(k.?, "value") orelse "", "2"), "k = 2 ({s})", .{if (k) |x| str(x, "value") orelse "?" else "none"});
    gap("the main program's variables, v, big, tg, goal, none, nothing among them (#383)", locals);
    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and int(frames[0], "line") == main_line + 1, "next: line {d} ({?d})", .{ main_line + 1, int(frames[0], "line") });

    // the OPEN of a missing file: Flang's runtime aborts, where the engine
    // stops (0xc0000409, a fast fail)
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "exception"), "stopped by an exception ({s}: {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "text") orelse "?" });
    frames = items(try c.request("stackTrace", .{ .threadId = thread, .levels = 40 }), "stackFrames");
    var in_runtime = false;
    var at_open = false;
    for (frames) |f| {
        in_runtime = in_runtime or contains(str(f, "name"), "Fortran::runtime::");
        at_open = at_open or (std.mem.eql(u8, str(f, "name") orelse "", "MAIN") and int(f, "line") == main_line + 2);
    }
    try check(in_runtime and at_open, "in Flang's runtime, called at line {d} of MAIN", .{main_line + 2});
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
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
