//! zfls dap over Windows's Debugger Engine on LFortran's programs, for
//! tests/dap_windows.zig (`--lfortran LFORTRAN`): tests/dap/count.f90 built
//! as `zfls build-command` answers, with `zfls lfortran-codeview` (CodeView
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
    const cwd = Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, "tests/dap/count.f90", a, .limited(1 << 16));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, "count.f90" });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    // the build zfls answers
    const asked = try std.process.run(a, io, .{ .argv = &.{ exe_zfls, "build-command", src, "--compiler", lfortran, "--output-dir", tmp, "--kit", kit }, .environ_map = environ });
    const answer = std.json.parseFromSliceLeaky(Value, a, asked.stdout, .{}) catch {
        std.debug.print("FAIL: zfls build-command: {s}{s}\n", .{ asked.stdout, asked.stderr });
        return 1;
    };
    const args = items(answer, "args");
    if (args.len == 0 or !std.mem.eql(u8, args[0].string, "lfortran-codeview")) {
        std.debug.print("skipped: LFortran's CodeView build ({s})\n", .{str(answer, "note") orelse "no note"});
        return 0;
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
        std.debug.print("FAIL: LFortran's CodeView build: {s}{s}\n", .{ built.stdout, built.stderr });
        return 1;
    }
    const pdb = try a.print("{s}.pdb", .{exe[0 .. exe.len - 4]});
    if ((cwd.access(io, pdb, .{}) catch null) == null) {
        std.debug.print("FAIL: no {s}\n", .{pdb});
        return 1;
    }
    const c = try Client.start(io, gpa, &.{ exe_zfls, "dap" });
    defer c.deinit();
    session(c, exe, tmp, src, text) catch |e| {
        std.debug.print("zfls dap, LFortran's program: {s}\n", .{@errorName(e)});
        if (c.child.id != null) c.child.kill(io);
        return 1;
    };
    std.debug.print("zfls dap on LFortran's program: all good\n", .{});
    return 0;
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
