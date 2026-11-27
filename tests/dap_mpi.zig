//! zfls dap on an MPI program (#988), as VS Code drives it: the launch
//! with `mpi` asks the client to run the launcher in a terminal (this
//! driver runs it) and then to start a session per rank (this driver
//! starts each, a `zfls dap` attaching to its rank's gdbserver); each rank
//! stops at its breakpoint with its own rank (tests/dap/mpi.f90). Linux
//! only (gdbserver); skipped without MPICH's mpif90 and mpiexec, or
//! gdbserver.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp_client");

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const check = dap.check;

const source = "tests/dap/mpi.f90";
const ranks = 2;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var mpif90: []const u8 = init.environ_map.get("MPIF90") orelse "mpif90";
    var mpiexec: []const u8 = init.environ_map.get("MPIEXEC") orelse "mpiexec";
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--mpif90")) {
            mpif90 = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--mpiexec")) {
            mpiexec = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null) {
        std.debug.print("usage: dap_mpi --zfls ZFLS [--mpif90 MPIF90] [--mpiexec MPIEXEC]\n", .{});
        return 2;
    }
    if (builtin.target.os.tag != .linux) {
        std.debug.print("skipped: MPI programs are debugged on Linux, under gdbserver\n", .{});
        return 0;
    }
    for ([_][]const u8{ mpif90, "gdbserver" }) |tool| {
        _ = std.process.run(a, io, .{ .argv = &.{ tool, "--version" } }) catch {
            std.debug.print("skipped: no {s}\n", .{tool});
            return 0;
        };
    }
    const cwd = Io.Dir.cwd();
    const tmp = try lsp.tempDir(io, a, init.environ_map, "zfls-dap-mpi-");
    defer cwd.deleteTree(io, tmp) catch {};
    const text = try cwd.readFileAlloc(io, source, a, .limited(1 << 20));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, "mpi.f90" });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    const program = try std.Io.Dir.path.join(a, &.{ tmp, "ranks" });
    const built = try std.process.run(a, io, .{ .argv = &.{ mpif90, "-g", "-O0", "-o", program, src }, .cwd = .{ .path = tmp } });
    if (built.term != .exited or built.term.exited != 0) {
        std.debug.print("{s} failed: {s}{s}\n", .{ mpif90, built.stdout, built.stderr });
        return 1;
    }
    const zfls_path = try cwd.realPathFileAlloc(io, zfls_exe.?, a);
    session(io, init.gpa, a, init.environ_map, zfls_path, mpiexec, program, src, lineOf(text, "stop here")) catch |e| {
        std.debug.print("an MPI program: {s}\n", .{@errorName(e)});
        return 1;
    };
    std.debug.print("zfls dap on an MPI program: all good\n", .{});
    return 0;
}

fn session(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, zfls_path: []const u8, mpiexec: []const u8, program: []const u8, src: []const u8, line: i64) !void {
    const c = try Client.start(io, gpa, &.{ zfls_path, "dap" });
    defer c.deinit();
    defer c.end(false);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path", .supportsRunInTerminalRequest = true, .supportsStartDebuggingRequest = true });
    const launched = try c.send("launch", .{ .program = program, .cwd = std.Io.Dir.path.dirname(program).?, .mpi = .{ .ranks = ranks, .launcher = mpiexec, .port = 23000 } });
    // the launcher, as the client's terminal would run it
    const rit = c.adapterRequest() catch |e| {
        c.timeout = .fromSeconds(1);
        if (c.response(launched, "launch")) |r| std.debug.print("the launch's answer: {s}\n", .{str(r, "message") orelse "(no message)"}) else |_| {}
        return e;
    };
    try check(std.mem.eql(u8, str(rit, "command") orelse "", "runInTerminal"), "the adapter's request: {s}", .{str(rit, "command") orelse "?"});
    const rargs = get(rit, "arguments").?;
    var cmd: std.ArrayList([]const u8) = .empty;
    for (items(rargs, "args")) |x| try cmd.append(a, x.string);
    var env = try environ.clone(a);
    if (get(rargs, "env")) |e| if (e == .object) {
        var it = e.object.iterator();
        while (it.next()) |kv| if (kv.value_ptr.* == .string) try env.put(kv.key_ptr.*, kv.value_ptr.string);
    };
    // its output in a file, and in a process group of its own, which ends
    // with the test: no rank left holding the test's output open
    const log = try std.Io.Dir.path.join(a, &.{ std.Io.Dir.path.dirname(program).?, "launcher.log" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "/bin/sh", "-c", "exec \"$@\" > \"$0\" 2>&1", log });
    try argv.appendSlice(a, cmd.items);
    var launcher = try std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = str(rargs, "cwd") orelse "." }, .environ_map = &env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    defer {
        std.posix.kill(-launcher.id.?, .KILL) catch {};
        _ = launcher.wait(io) catch {};
        const said = Io.Dir.cwd().readFileAlloc(io, log, a, .limited(1 << 20)) catch "";
        std.debug.print("the launcher said:\n{s}\n", .{said});
    }
    try c.answer(rit, true, .{ .processId = dap.processId(launcher) });
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    _ = try c.event("initialized");
    _ = try c.request("configurationDone", .{});
    // a session per rank
    var sessions: [ranks]*Client = undefined;
    var started: usize = 0;
    defer for (sessions[0..started]) |r| {
        r.end(false);
        r.deinit();
    };
    for (0..ranks) |_| {
        const sd = try c.adapterRequest();
        try check(std.mem.eql(u8, str(sd, "command") orelse "", "startDebugging"), "the adapter's request: {s}", .{str(sd, "command") orelse "?"});
        const config = get(get(sd, "arguments").?, "configuration").?;
        try c.answer(sd, true, .{});
        const r = try Client.start(io, gpa, &.{ zfls_path, "dap" });
        sessions[started] = r;
        started += 1;
        _ = try r.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
        const attached = try r.send("attach", config);
        _ = try r.event("initialized");
        _ = try r.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = line }} });
        _ = try r.request("configurationDone", .{});
        _ = try Client.bodyOf(try r.response(attached, "attach"), "attach");
        std.debug.print("{s}: attached to {s}\n", .{ str(config, "name") orelse "?", str(config, "target") orelse "?" });
    }
    // on, all of them: MPI_Init waits for every rank
    for (sessions) |r| {
        const threads = items(try r.request("threads", .{}), "threads");
        try check(threads.len > 0, "{d} threads", .{threads.len});
        _ = try r.request("continue", .{ .threadId = int(threads[0], "id").? });
    }
    var seen: [ranks]bool = @splat(false);
    for (sessions) |r| {
        const stopped = while (true) {
            const e = try r.event("stopped");
            const b = get(e, "body").?;
            if (std.mem.eql(u8, str(b, "reason") orelse "", "breakpoint")) break b;
        };
        const frames = items(try r.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
        try check(int(frames[0], "line") == line, "at the breakpoint, line {d} ({?d})", .{ line, int(frames[0], "line") });
        const v = try r.request("evaluate", .{ .expression = "rank", .frameId = int(frames[0], "id").?, .context = "watch" });
        const rank = std.fmt.parseInt(usize, str(v, "result") orelse "", 10) catch ranks;
        try check(rank < ranks and !seen[rank], "rank = {s}", .{str(v, "result") orelse "?"});
        seen[rank] = true;
        const t = try r.request("evaluate", .{ .expression = "total", .frameId = int(frames[0], "id").?, .context = "watch" });
        const want = try a.print("{d}", .{rank + 10});
        try check(std.mem.eql(u8, str(t, "result") orelse "", want), "rank {d}: total = {s} ({s})", .{ rank, want, str(t, "result") orelse "?" });
        std.debug.print("rank {d} stopped at line {d}\n", .{ rank, line });
    }
}

/// The 1-based line of `text` holding `mark`
fn lineOf(text: []const u8, mark: []const u8) i64 {
    const at = std.mem.find(u8, text, mark) orelse unreachable;
    return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
}
