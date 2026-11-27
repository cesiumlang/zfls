//! zfls dap on an MPI program (#988): a `launch` with `mpi: { ranks: N }`
//! makes this session the ranks' coordinator. It runs the launcher
//! (`mpiexec -n N`, in the client's terminal: `runInTerminal`) with each
//! rank under a gdbserver on a port of its own (`port`, 20000, plus the
//! rank), then asks the client to start a session per rank
//! (`startDebugging`), each a `zfls dap` that attaches gdb to its rank's
//! gdbserver (`target`). Breakpoints, stepping and the variables are the
//! ranks' sessions'; this one has no threads, and its end ends the ranks.
//!
//! The launch's `mpi`: `ranks`, `launcher` (`mpiexec`), `launcherArgs`
//! (before `-n`), `gdbserver` (`gdbserver`), `port`; Linux only (gdbserver),
//! and a client that takes `runInTerminal` and `startDebugging`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;

/// The launch's `mpi`
pub const Options = struct {
    ranks: u32,
    launcher: []const u8 = "mpiexec",
    launcher_args: []const []const u8 = &.{},
    gdbserver: []const u8 = "gdbserver",
    port: u16 = 20000,
};

/// The state of a coordinating session
pub const State = struct {
    /// The terminal's shell that runs the launcher (`runInTerminal`)
    shell_pid: ?i64 = null,
    port: u16 = 20000,
    ranks: u32 = 0,
    /// What each rank's session is started with: the launch's arguments
    /// (`gpa`'s JSON text)
    launch: []const u8 = "",
};

/// The `mpi` of a launch's arguments, or null without one
pub fn options(a: Allocator, args: ?Value) !?Options {
    const m = json.get(args, "mpi") orelse return null;
    if (m != .object) return null;
    const ranks = json.int(json.get(m, "ranks")) orelse return null;
    if (ranks < 1 or ranks > 1024) return null;
    var o: Options = .{ .ranks = @intCast(ranks) };
    if (json.str(json.get(m, "launcher"))) |l| if (l.len > 0) {
        o.launcher = l;
    };
    if (json.str(json.get(m, "gdbserver"))) |g| if (g.len > 0) {
        o.gdbserver = g;
    };
    if (json.int(json.get(m, "port"))) |p| o.port = std.math.cast(u16, p) orelse o.port;
    var extra: std.ArrayList([]const u8) = .empty;
    for (json.items(json.get(m, "launcherArgs"))) |x| if (json.str(x)) |s| try extra.append(a, s);
    o.launcher_args = extra.items;
    return o;
}

/// The shell's script that runs a rank under gdbserver: the rank from the
/// launcher's variable (Open MPI's, MPICH's and Intel MPI's PMI, PMIx,
/// Slurm), the program and its arguments after it
const rank_script = "r=${OMPI_COMM_WORLD_RANK:-${PMI_RANK:-${PMIX_RANK:-${SLURM_PROCID:-0}}}}; exec \"$ZFLS_GDBSERVER\" \":$((ZFLS_PORT + r))\" \"$@\"";

/// The launcher's command line for `program` with `program_args`
pub fn commandLine(a: Allocator, o: Options, program: []const u8, program_args: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, o.launcher);
    try argv.appendSlice(a, o.launcher_args);
    try argv.appendSlice(a, &.{ "-n", try a.print("{d}", .{o.ranks}), "/bin/sh", "-c", rank_script, "zfls-rank", program });
    try argv.appendSlice(a, program_args);
    return argv.items;
}

/// `launch` with `mpi`: the launcher in the client's terminal, then the
/// launch answered and `initialized`; the ranks' sessions at
/// `configurationDone`
pub fn launch(s: *Session, a: Allocator, req: Value, args: ?Value, o: Options) !void {
    if (builtin.target.os.tag != .linux) return s.fail(a, req, "zfls dap: MPI programs are debugged on Linux, where each rank runs under gdbserver");
    if (!clientTakes(s, a, "supportsRunInTerminalRequest") or !clientTakes(s, a, "supportsStartDebuggingRequest"))
        return s.fail(a, req, "zfls dap: an MPI program needs a client that runs commands in a terminal and starts sessions (runInTerminal, startDebugging), as VS Code does");
    const program = json.str(json.get(args, "program")) orelse return s.fail(a, req, "zfls dap: no program to launch");
    var program_args: std.ArrayList([]const u8) = .empty;
    for (json.items(json.get(args, "args"))) |x| if (json.str(x)) |t| try program_args.append(a, t);
    const cwd = json.str(json.get(args, "cwd")) orelse std.Io.Dir.path.dirname(program) orelse ".";
    const argv = try commandLine(a, o, program, program_args.items);
    const seq = s.sendSeq(a, .{
        .type = "request",
        .command = "runInTerminal",
        .arguments = .{
            .kind = "integrated",
            .title = "MPI ranks",
            .cwd = cwd,
            .args = argv,
            .env = .{ .ZFLS_GDBSERVER = o.gdbserver, .ZFLS_PORT = try a.print("{d}", .{o.port}) },
        },
    });
    const r = s.clientResponse(a, seq, .fromSeconds(60)) orelse return s.fail(a, req, "zfls dap: the client did not run the MPI launcher");
    if (!(json.get(r, "success") orelse Value{ .bool = false }).bool) return s.fail(a, req, try a.print("zfls dap: the client did not run {s}: {s}", .{ o.launcher, json.str(json.get(r, "message")) orelse "" }));
    s.mpi = .{
        .shell_pid = json.int(json.path(r, &.{ "body", "shellProcessId" })) orelse json.int(json.path(r, &.{ "body", "processId" })),
        .port = o.port,
        .ranks = o.ranks,
        .launch = try s.gpa.dupe(u8, try json.stringify(a, args orelse Value.null)),
    };
    s.backend = .mpi;
    s.respond(a, req, null);
    s.event(a, "initialized", null);
}

fn clientTakes(s: *Session, a: Allocator, capability: []const u8) bool {
    const init = json.parse(a, s.client_init) catch return false;
    const v = json.get(init, capability) orelse return false;
    return v == .bool and v.bool;
}

/// The requests of a coordinating session
pub fn handle(s: *Session, a: Allocator, req: Value) !void {
    const command = json.str(json.get(req, "command")) orelse return;
    const args = json.get(req, "arguments");
    if (std.mem.eql(u8, command, "configurationDone")) {
        s.respond(a, req, null);
        return startRanks(s, a);
    }
    if (std.mem.eql(u8, command, "threads")) return s.respond(a, req, .{ .threads = &[_]Value{} });
    if (std.mem.eql(u8, command, "setBreakpoints")) {
        // the ranks' sessions set them; here none is verified
        var out: std.ArrayList(Value) = .empty;
        for (json.items(json.get(args, "breakpoints"))) |b| try out.append(a, try json.from(a, .{ .verified = false, .line = json.int(json.get(b, "line")) orelse 0, .message = "set in the ranks' sessions" }));
        return s.respond(a, req, .{ .breakpoints = out.items });
    }
    if (std.mem.eql(u8, command, "disconnect") or std.mem.eql(u8, command, "terminate")) {
        end(s);
        s.respond(a, req, null);
        if (std.mem.eql(u8, command, "terminate")) s.event(a, "terminated", null);
        s.done = true;
        return;
    }
    s.respond(a, req, null);
}

/// Each rank's session, once its gdbserver listens (up to 30 seconds)
fn startRanks(s: *Session, a: Allocator) !void {
    const st = s.mpi orelse return;
    const launch_args = try json.parse(a, st.launch);
    for (0..st.ranks) |rank| {
        const port = st.port + @as(u16, @intCast(rank));
        if (!listens(s.io, port)) {
            s.output(a, try a.print("zfls dap: rank {d}'s gdbserver does not listen on port {d}\n", .{ rank, port }));
            continue;
        }
        var config = try json.from(a, .{ .type = "fortran", .request = "attach", .name = try a.print("rank {d}", .{rank}), .target = try a.print("localhost:{d}", .{port}) });
        // the launch's own settings: the program, its sources, the gdb
        if (launch_args == .object) for ([_][]const u8{ "program", "cwd", "sourceRoot", "gdb", "setupCommands" }) |key| {
            if (launch_args.object.get(key)) |v| try config.object.put(a, key, v);
        };
        _ = s.sendSeq(a, .{ .type = "request", .command = "startDebugging", .arguments = .{ .configuration = config, .request = "attach" } });
    }
}

/// Whether something listens on `port` of this machine, waiting for it up
/// to 30 seconds; the connection is closed at once, which a gdbserver
/// without `--once` takes for a client gone, and waits for the next
fn listens(io: Io, port: u16) bool {
    const address = Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    for (0..300) |_| {
        if (address.connect(io, .{ .mode = .stream })) |conn| {
            conn.close(io);
            return true;
        } else |_| io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return false;
}

/// The end of the session: a hangup to the launcher's terminal shell, which
/// passes it to the launcher, and so to the ranks (an interactive shell
/// ignores TERM)
pub fn end(s: *Session) void {
    const pid = (s.mpi orelse return).shell_pid orelse return;
    s.mpi.?.shell_pid = null;
    // the client's number: 0 or -1 would signal a process group (#972)
    if (builtin.target.os.tag == .windows or pid <= 0) return;
    std.posix.kill(std.math.cast(std.posix.pid_t, pid) orelse return, .HUP) catch {};
}

pub fn deinit(s: *Session) void {
    if (s.mpi) |st| if (st.launch.len > 0) s.gpa.free(st.launch);
    s.mpi = null;
}

test "the launcher's command line runs each rank under gdbserver (#988)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try commandLine(a, .{ .ranks = 4, .launcher_args = &.{"--oversubscribe"} }, "/w/prog", &.{"x"});
    try std.testing.expectEqualStrings("mpiexec", argv[0]);
    try std.testing.expectEqualStrings("--oversubscribe", argv[1]);
    try std.testing.expectEqualStrings("4", argv[3]);
    try std.testing.expectEqualStrings("/w/prog", argv[argv.len - 2]);
    try std.testing.expectEqualStrings("x", argv[argv.len - 1]);
    const o = (try options(a, try json.parse(a, "{\"mpi\": {\"ranks\": 2, \"launcher\": \"mpirun\", \"port\": 7000}}"))).?;
    try std.testing.expectEqual(2, o.ranks);
    try std.testing.expectEqualStrings("mpirun", o.launcher);
    try std.testing.expectEqual(7000, o.port);
    try std.testing.expectEqual(null, try options(a, try json.parse(a, "{\"mpi\": {\"ranks\": 0}}")));
}
