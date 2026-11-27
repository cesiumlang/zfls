//! zfls dap over Windows's Debugger Engine on LFortran's programs, for
//! tests/dap_windows.zig (`--lfortran LFORTRAN`): tests/dap/count.f90 built
//! as `zfls build-command` answers, with `zfls lfortran-ir` (CodeView
//! through LFortran's IR, clang and lld-link with the ifx kit, #176), and a
//! session on it (#185): a breakpoint on a line, the stack, the program's
//! integer scalars. clang and lld-link are the PATH's.

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
const w = @import("dap_windows.zig");

pub fn run(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, exe_zfls: []const u8, lfortran: []const u8, tmp: []const u8, kit: []const u8) !u8 {
    const count = (build(io, a, environ, exe_zfls, lfortran, tmp, kit, "count") catch return 1) orelse return 0;
    {
        const c = try Client.start(io, gpa, &.{ exe_zfls, "dap" });
        defer c.deinit();
        session(c, count.exe, tmp, count.src, count.text) catch |e| {
            std.debug.print("zfls dap, LFortran's program: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    // arrays, derived types, strings, arguments, module variables (#366)
    const grid = (build(io, a, environ, exe_zfls, lfortran, tmp, kit, "grid") catch return 1) orelse return 0;
    {
        const c = try Client.start(io, gpa, &.{ exe_zfls, "dap" });
        defer c.deinit();
        gridSession(c, grid.exe, tmp, grid.src, grid.text) catch |e| {
            std.debug.print("zfls dap, LFortran's grid.f90: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    std.debug.print("zfls dap on LFortran's program: all good\n", .{});
    return 0;
}

const Built = struct { exe: []const u8, src: []const u8, text: []const u8 };

/// tests/dap/NAME.f90 built as `zfls build-command` answers; null when it
/// answers no CodeView build (skipped)
fn build(io: Io, a: Allocator, environ: *const std.process.Environ.Map, exe_zfls: []const u8, lfortran: []const u8, tmp: []const u8, kit: []const u8, name: []const u8) !?Built {
    const cwd = Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, try a.print("tests/dap/{s}.f90", .{name}), a, .limited(1 << 16));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, try a.print("{s}.f90", .{name}) });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    // the build zfls answers
    const asked = try std.process.run(a, io, .{ .argv = &.{ exe_zfls, "build-command", src, "--compiler", lfortran, "--output-dir", tmp, "--kit", kit }, .environ_map = environ });
    const answer = std.json.parseFromSliceLeaky(Value, a, asked.stdout, .{}) catch {
        std.debug.print("FAIL: zfls build-command: {s}{s}\n", .{ asked.stdout, asked.stderr });
        return error.Build;
    };
    const args = items(answer, "args");
    if (args.len == 0 or !std.mem.eql(u8, args[0].string, "lfortran-ir")) {
        std.debug.print("skipped: LFortran's CodeView build ({s})\n", .{str(answer, "note") orelse "no note"});
        return null;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, str(answer, "compiler").?);
    for (args) |x| try argv.append(a, x.string);
    var env = try environ.clone(a);
    if (get(answer, "env")) |e| {
        var it = e.object.iterator();
        while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.string);
    }
    const built = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = str(answer, "cwd").? }, .environ_map = &env });
    const exe = str(answer, "program").?;
    if (built.term != .exited or built.term.exited != 0 or (cwd.access(io, exe, .{}) catch null) == null) {
        std.debug.print("FAIL: LFortran's CodeView build of {s}: {s}{s}\n", .{ name, built.stdout, built.stderr });
        return error.Build;
    }
    const pdb = try a.print("{s}.pdb", .{exe[0 .. exe.len - 4]});
    if ((cwd.access(io, pdb, .{}) catch null) == null) {
        std.debug.print("FAIL: no {s}\n", .{pdb});
        return error.Build;
    }
    return .{ .exe = exe, .src = src, .text = text };
}

/// tests/dap/grid.f90: the variables at its two stops, as ifx's
/// (tests/dap_ifx.zig), from the types zfls writes (#366)
fn gridSession(c: *Client, exe: []const u8, tmp: []const u8, src: []const u8, text: []const u8) !void {
    const work_line = w.lineOf(text, "stop here: work");
    const main_line = w.lineOf(text, "stop here: main");
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = tmp });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{ .{ .line = work_line }, .{ .line = main_line } } }), "breakpoints");
    for (bps, [_]i64{ work_line, main_line }) |bp, l| try check((get(bp, "verified") orelse Value{ .bool = false }).bool, "a verified breakpoint at line {d}", .{l});
    _ = try c.request("configurationDone", .{});
    // in work: the dummy arguments, the module's variables
    {
        const at = try stopAt(c, work_line);
        const args = try w.scopeVariables(c, at.scopes, "Locals");
        try expect(args, "a", "[6.0, 2.0, 3.0]");
        try expect(args, "b", "[2×3]");
        try expect(try kids(c, args, "b"), "(:,1)", "[-10, -20]");
        try expect(args, "s", "'abcdef'");
        try expect(args, "p", "point(x=9.0, y=-2.0, id=7)");
        try expect(args, "t", "tagged(point=…, tag='hello   ', w=…)");
        const tc = try kids(c, args, "t");
        try expect(tc, "tag", "'hello   '");
        try expect(tc, "w", "[0.25, 0.25]");
        try expect(args, "ts", "[labeled(…), labeled(…)]");
        try expect(try kids(c, args, "ts"), "(2)", "labeled(point=…, label=5)");
        const grid = try w.moduleVariables(c, at.scopes, "grid");
        for ([_][2][]const u8{ .{ "ncells", "42" }, .{ "secret", "99" }, .{ "origin", "point(x=9.0, y=-2.0, id=7)" }, .{ "gname", "'grid name'" }, .{ "cx", "1.5" }, .{ "cy", "2.5" } }) |x| try expect(grid, x[0], x[1]);
        _ = try c.request("continue", .{ .threadId = at.thread });
    }
    // in the main program: its locals, saved ones, a module's by USE
    {
        const at = try stopAt(c, main_line);
        const locals = try w.scopeVariables(c, at.scopes, "Locals");
        for ([_][2][]const u8{ .{ "dl", "'deferred'" }, .{ "ip", "5" }, .{ "lb", "labeled(point=…, label=5)" }, .{ "none", "not allocated" }, .{ "nothing", "not associated" }, .{ "pts", "[labeled(…), labeled(…)]" }, .{ "v", "[6.0, 2.0, 3.0]" }, .{ "goal", "5" } }) |x| try expect(locals, x[0], x[1]);
        try check(std.mem.startsWith(u8, w.valueOf(locals, "big"), "[1.0, 2.0, 3.0"), "big = [1.0, 2.0, 3.0, …] ({s})", .{w.valueOf(locals, "big")});
        try expect(try kids(c, locals, "m"), "(:,-1)", "[-10, -20]");
        try expect(try kids(c, locals, "tg"), "w", "[0.25, 0.25]");
        try check(w.named(locals, "lfortran_implied_do_k") == null, "no LFortran's temporaries", .{});
        try expect(try w.moduleVariables(c, at.scopes, "counters"), "nhits => hits", "3");
        _ = try c.request("continue", .{ .threadId = at.thread });
    }
    _ = try c.event("terminated");
    _ = try c.request("disconnect", .{});
}

fn stopAt(c: *Client, line: i64) !struct { thread: i64, scopes: []Value } {
    const stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 0 and int(frames[0], "line") == line, "at line {d} ({?d})", .{ line, if (frames.len > 0) int(frames[0], "line") else null });
    return .{ .thread = thread, .scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes") };
}

fn expect(vars: []Value, name: []const u8, want: []const u8) !void {
    try check(std.mem.eql(u8, w.valueOf(vars, name), want), "{s} = {s} ({s})", .{ name, want, w.valueOf(vars, name) });
}

/// The children of the variable `name` of `vars`
fn kids(c: *Client, vars: []Value, name: []const u8) ![]Value {
    const v = w.named(vars, name) orelse return &.{};
    return items(try c.request("variables", .{ .variablesReference = int(v, "variablesReference") orelse return &.{} }), "variables");
}

fn session(c: *Client, exe: []const u8, tmp: []const u8, src: []const u8, text: []const u8) !void {
    const line = w.lineOf(text, "stop here");
    const print_line = w.lineOf(text, "and here");
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    // the engine, chosen by the program's PDB
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = tmp });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{ .{ .line = line }, .{ .line = print_line } } }), "breakpoints");
    for (bps, [_]i64{ line, print_line }) |bp, l| try check((get(bp, "verified") orelse Value{ .bool = false }).bool, "a verified breakpoint at line {d}", .{l});
    try check(bps.len == 2, "{d} breakpoints", .{bps.len});
    _ = try c.request("configurationDone", .{});
    const stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint"), "stopped at the breakpoint ({s})", .{str(stopped, "reason") orelse "?"});
    const thread = int(stopped, "threadId").?;
    const frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 0 and int(frames[0], "line") == line, "at line {d} ({?d})", .{ line, if (frames.len > 0) int(frames[0], "line") else null });
    const locals = try w.scopeVariables(c, items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes"), "Locals");
    try check(std.mem.eql(u8, w.valueOf(locals, "i"), "4"), "i = 4 ({s})", .{w.valueOf(locals, "i")});
    try check(std.mem.eql(u8, w.valueOf(locals, "s"), "6"), "s = 6 ({s})", .{w.valueOf(locals, "s")});
    // the PRINT's own line (#470)
    _ = try c.request("continue", .{ .threadId = thread });
    const at_print = get(try c.event("stopped"), "body").?;
    const print_frames = items(try c.request("stackTrace", .{ .threadId = int(at_print, "threadId").? }), "stackFrames");
    try check(print_frames.len > 0 and int(print_frames[0], "line") == print_line, "at the PRINT, line {d} ({?d})", .{ print_line, if (print_frames.len > 0) int(print_frames[0], "line") else null });
    _ = try c.request("continue", .{ .threadId = thread });
    _ = try c.event("terminated");
    _ = try c.request("disconnect", .{});
}
