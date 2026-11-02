//! zfls dap, the debug adapter over Windows's Debugger Engine, on a program
//! of the MSVC ABI with a PDB (tests/dap/hello.c, built by `zig cc`): a
//! breakpoint, the stack, the variables, stepping, an expression, the end
//! (`zig build test-dap`). The Fortran values (of ifx's programs) need ifx,
//! which CI has not.
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

/// The adapter's process: a thread reads its messages, keeping the
/// responses by the request they answer and the events in order
const Client = struct {
    io: Io,
    gpa: Allocator,
    child: std.process.Child,
    /// Messages received (under `mutex`)
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    responses: std.AutoHashMapUnmanaged(i64, Value) = .empty,
    events: std.ArrayList(Value) = .empty,
    /// The events `event` has gone past
    seen: usize = 0,
    closed: bool = false,
    seq: i64 = 1,
    thread: ?std.Thread = null,
    timeout: Io.Duration = .fromSeconds(60),

    fn start(io: Io, gpa: Allocator, argv: []const []const u8) !*Client {
        const c = try gpa.create(Client);
        c.* = .{
            .io = io,
            .gpa = gpa,
            .arena = .init(gpa),
            .child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .create_no_window = true }),
        };
        c.thread = try std.Thread.spawn(.{}, read, .{c});
        return c;
    }

    fn deinit(c: *Client) void {
        if (c.thread) |t| t.join();
        c.responses.deinit(c.gpa);
        c.events.deinit(c.gpa);
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    fn read(c: *Client) void {
        var buf: [64 * 1024]u8 = undefined;
        var reader = c.child.stdout.?.reader(c.io, &buf);
        while (true) {
            const body = (zfls.jsonrpc.readMessage(&reader.interface, c.gpa) catch null) orelse break;
            defer c.gpa.free(body);
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            c.keep(body) catch {};
            c.cond.broadcast(c.io);
        }
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.closed = true;
        c.cond.broadcast(c.io);
    }

    fn keep(c: *Client, body: []const u8) !void {
        const msg = try std.json.parseFromSliceLeaky(Value, c.arena.allocator(), body, .{});
        const kind = str(msg, "type") orelse return;
        if (std.mem.eql(u8, kind, "response")) {
            const seq = get(msg, "request_seq") orelse return;
            if (seq == .integer) try c.responses.put(c.gpa, seq.integer, msg);
        } else if (std.mem.eql(u8, kind, "event")) try c.events.append(c.gpa, msg);
    }

    /// Waits on `cond` until `deadline` (under `mutex`)
    fn wait(c: *Client, deadline: Io.Timestamp, what: []const u8) !void {
        if (c.closed) {
            std.debug.print("zfls dap ended while waiting for {s}\n", .{what});
            return error.AdapterEnded;
        }
        c.cond.waitTimeout(c.io, &c.mutex, .{ .deadline = .{ .raw = deadline, .clock = .awake } }) catch |e| switch (e) {
            error.Timeout => {
                std.debug.print("timed out waiting for {s}\n", .{what});
                return error.Timeout;
            },
            else => return e,
        };
    }

    /// Sends a request and returns the body of its response, which must
    /// succeed
    fn request(c: *Client, command: []const u8, args: anytype) !Value {
        const seq = c.seq;
        c.seq += 1;
        const body = try std.json.Stringify.valueAlloc(c.gpa, .{ .seq = seq, .type = "request", .command = command, .arguments = args }, .{});
        defer c.gpa.free(body);
        const framed = try c.gpa.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        defer c.gpa.free(framed);
        try c.child.stdin.?.writeStreamingAll(c.io, framed);
        const deadline = Io.Clock.awake.now(c.io).addDuration(c.timeout);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const r = while (true) {
            if (c.responses.fetchRemove(seq)) |kv| break kv.value;
            try c.wait(deadline, command);
        };
        if (get(r, "success")) |ok| if (ok == .bool and ok.bool) return get(r, "body") orelse .{ .object = .empty };
        std.debug.print("{s} failed: {s}\n", .{ command, str(r, "message") orelse "(no message)" });
        return error.RequestFailed;
    }

    /// The next event named `name` (the events before it are dropped)
    fn event(c: *Client, name: []const u8) !Value {
        const deadline = Io.Clock.awake.now(c.io).addDuration(c.timeout);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            while (c.seen < c.events.items.len) {
                const e = c.events.items[c.seen];
                c.seen += 1;
                if (std.mem.eql(u8, str(e, "event") orelse "", name)) return e;
            }
            try c.wait(deadline, name);
        }
    }
};

fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

fn str(v: Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: Value, key: []const u8) ?i64 {
    const x = get(v, key) orelse return null;
    return if (x == .integer) x.integer else null;
}

fn items(v: Value, key: []const u8) []Value {
    const x = get(v, key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn contains(s: ?[]const u8, part: []const u8) bool {
    return std.mem.find(u8, s orelse return false, part) != null;
}

fn check(ok: bool, comptime what: []const u8, args: anytype) !void {
    if (!ok) {
        std.debug.print("FAIL: " ++ what ++ "\n", args);
        return error.CheckFailed;
    }
    std.debug.print("ok: " ++ what ++ "\n", args);
}

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
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = src_dir });
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
