//! `zfls dap`: a debug adapter (Debug Adapter Protocol, on standard input
//! and output) over the Debugger Engine of Windows (dbgeng.zig), for
//! programs with Microsoft's debug information: Intel's ifx and LLVM
//! Flang's on Windows. Their variables are shown as Fortran: zfls indexes
//! the program's sources (the launch configuration's `sourceRoot`, else
//! `cwd`), and each variable's declaration says its type, kind and rank,
//! while dbghelp says where it is; arrays are read through Intel's
//! descriptors. The program runs in a console of its own.
//!
//! One thread reads the client's messages (and interrupts a running program
//! for `pause`); the engine's thread, this one, handles them in order and
//! waits for the program between them, as the engine wants all calls from
//! the thread that made it.
//!
//! Here the session's state, its requests' dispatch and its stops; the
//! requests' parts are in breakpoints.zig, declarations.zig (zfls's index
//! of the sources), memory.zig (values in the program's memory) and
//! variables.zig (the protocol's variables).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const jsonrpc = @import("../jsonrpc.zig");
const Settings = @import("../settings.zig").Settings;
const server_mod = @import("../server.zig");
const Logger = @import("../logger.zig");
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const paths = @import("../paths.zig");
const values = @import("values.zig");
const dbgeng = @import("dbgeng.zig");
const Engine = dbgeng.Engine;
const Value = json.Value;

const breakpoints = @import("breakpoints.zig");
const runtime_errors_filter = breakpoints.runtime_errors_filter;
const errorFunction = breakpoints.errorFunction;
const isUserBreakpoint = breakpoints.isUserBreakpoint;
const declarations = @import("declarations.zig");
const index = declarations.index;
const memory = @import("memory.zig");
const evaluate = memory.evaluate;
const variables = @import("variables.zig");
const children = variables.children;
const show = variables.show;

const Queue = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    items: std.ArrayList([]u8) = .empty,
    closed: bool = false,
};

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    engine: Engine,
    queue: Queue = .{},
    out_mutex: Io.Mutex = .init,
    seq: i64 = 1,
    /// The program runs (between a resume and its stop)
    running: bool = false,
    launched: bool = false,
    done: bool = false,
    stop_at_entry: bool = false,
    /// The breakpoints on the Fortran runtime's errors, and the function of
    /// the last one hit
    error_breakpoints: std.ArrayList(u32) = .empty,
    /// The breakpoints whose lines had no code yet (a module not loaded):
    /// their lines, until they have
    unverified: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    last_error: []const u8 = "",
    attached: bool = false,
    /// Breakpoints by source file: the engine's ids
    breakpoints: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// zfls's index of the sources, for the declarations
    server: ?*server_mod.Server = null,
    log: Logger,
    /// What variable references stand for, until the program goes on
    nodes: std.ArrayList(Node) = .empty,
    nodes_arena: std.heap.ArenaAllocator,

    fn send(s: *Session, a: Allocator, msg: anytype) void {
        var v = json.from(a, msg) catch return;
        if (v == .object) v.object.put(a, "seq", .{ .integer = 0 }) catch return;
        s.out_mutex.lockUncancelable(s.io);
        defer s.out_mutex.unlock(s.io);
        if (v == .object) v.object.put(a, "seq", .{ .integer = s.seq }) catch return;
        s.seq += 1;
        const body = json.stringify(a, v) catch return;
        const framed = jsonrpc.frame(a, body) catch return;
        Io.File.stdout().writeStreamingAll(s.io, framed) catch {};
    }

    pub fn respond(s: *Session, a: Allocator, req: Value, body: anytype) void {
        s.send(a, .{
            .type = "response",
            .request_seq = json.int(json.get(req, "seq")) orelse 0,
            .command = json.str(json.get(req, "command")) orelse "",
            .success = true,
            .body = body,
        });
    }

    pub fn fail(s: *Session, a: Allocator, req: Value, message: []const u8) void {
        s.send(a, .{
            .type = "response",
            .request_seq = json.int(json.get(req, "seq")) orelse 0,
            .command = json.str(json.get(req, "command")) orelse "",
            .success = false,
            .message = message,
        });
    }

    fn event(s: *Session, a: Allocator, name: []const u8, body: anytype) void {
        s.send(a, .{ .type = "event", .event = name, .body = body });
    }

    fn output(s: *Session, a: Allocator, text: []const u8) void {
        s.event(a, "output", .{ .category = "console", .output = text });
    }
};

/// What a variable reference stands for
pub const Node = union(enum) {
    locals: Frame,
    modules: Frame,
    module: struct { frame: Frame, name: []const u8 },
    value: Val,
};

pub const Frame = struct { thread: u32, index: u32 };

/// A Fortran value in the program's memory
pub const Val = struct {
    address: u64,
    t: values.Type,
    /// The node's dimensions, outermost last; none for a scalar
    extents: []const values.Extent = &.{},
    /// Subscripts chosen of the array's last dimensions
    chosen: []const i64 = &.{},
    rank: usize = 0,
    /// For an array of the node, which elements of its last dimension
    first: u64 = 0,
    count: u64 = 0,
    expr: []const u8 = "",
    /// For an element or a section: the whole array's expression
    base: []const u8 = "",
    /// dbghelp's type, for a derived type's members
    type_index: u32 = 0,
    mod_base: u64 = 0,
    /// The derived type's declaration, for its components' types
    decl: ?*const Obj = null,
    /// Not allocated, not associated
    empty: bool = false,
};

/// Runs `zfls dap`: its exit code
pub fn run(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    _ = args;
    var s: Session = .{
        .gpa = gpa,
        .io = io,
        .engine = Engine.init() catch {
            try Io.File.stderr().writeStreamingAll(io, "zfls dap: the Debugger Engine of Windows (dbgeng.dll) is not available\n");
            return 1;
        },
        .log = Logger.init(io),
        .nodes_arena = .init(gpa),
    };
    s.log.stderr_level = .off;
    defer s.engine.deinit();
    defer s.nodes_arena.deinit();
    defer if (s.server) |srv| srv.destroy();
    defer {
        var it = s.breakpoints.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            kv.value_ptr.deinit(gpa);
        }
        s.breakpoints.deinit(gpa);
        s.error_breakpoints.deinit(gpa);
        s.unverified.deinit(gpa);
        s.nodes.deinit(gpa);
        for (s.queue.items.items) |b| gpa.free(b);
        s.queue.items.deinit(gpa);
    }

    const reader = try std.Thread.spawn(.{}, readRequests, .{&s});
    reader.detach();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    while (!s.done) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        if (takeRequest(&s, if (s.running) 0 else 200)) |body| {
            defer gpa.free(body);
            const req = json.parse(a, body) catch continue;
            handle(&s, a, req) catch |e| s.fail(a, req, @errorName(e));
            continue;
        }
        if (s.queue.closed and s.queue.items.items.len == 0) break;
        if (s.running) {
            const stop = s.engine.wait(a, 100) catch continue;
            if (stop != .running) stopped(&s, a, stop);
        }
    }
    return 0;
}

fn readRequests(s: *Session) void {
    var buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(s.io, &buf);
    while (true) {
        const body = (jsonrpc.readMessage(&reader.interface, s.gpa) catch null) orelse break;
        // a pause cannot wait for the engine's thread, which waits for the program
        if (std.mem.find(u8, body, "\"pause\"") != null) s.engine.interrupt();
        s.queue.mutex.lockUncancelable(s.io);
        s.queue.items.append(s.gpa, body) catch {};
        s.queue.cond.broadcast(s.io);
        s.queue.mutex.unlock(s.io);
    }
    s.queue.mutex.lockUncancelable(s.io);
    s.queue.closed = true;
    s.queue.cond.broadcast(s.io);
    s.queue.mutex.unlock(s.io);
}

fn takeRequest(s: *Session, ms: i64) ?[]u8 {
    s.queue.mutex.lockUncancelable(s.io);
    defer s.queue.mutex.unlock(s.io);
    if (s.queue.items.items.len == 0 and ms > 0 and !s.queue.closed) {
        const t: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
        s.queue.cond.waitTimeout(s.io, &s.queue.mutex, t.toDeadline(s.io)) catch {};
    }
    if (s.queue.items.items.len == 0) return null;
    return s.queue.items.orderedRemove(0);
}

fn handle(s: *Session, a: Allocator, req: Value) !void {
    const command = json.str(json.get(req, "command")) orelse return;
    const args = json.get(req, "arguments");
    const Cmd = enum { initialize, launch, attach, setBreakpoints, setExceptionBreakpoints, setFunctionBreakpoints, exceptionInfo, configurationDone, threads, stackTrace, scopes, variables, evaluate, @"continue", next, stepIn, stepOut, pause, disconnect, terminate };
    const cmd = std.meta.stringToEnum(Cmd, command) orelse return s.fail(a, req, "not supported");
    switch (cmd) {
        .initialize => s.respond(a, req, .{
            .supportsConfigurationDoneRequest = true,
            .supportsTerminateRequest = true,
            .supportsEvaluateForHovers = true,
            .supportsDelayedStackTraceLoading = false,
            .supportsExceptionInfoRequest = true,
            .exceptionBreakpointFilters = &[_]struct { filter: []const u8, label: []const u8, description: []const u8, default: bool }{.{
                .filter = runtime_errors_filter,
                .label = "Fortran runtime errors",
                .description = "Stop where the Fortran runtime reports an error (bounds checking, allocation, I/O) or ERROR STOP",
                .default = true,
            }},
        }),
        .launch => {
            const program = json.str(json.get(args, "program")) orelse return s.fail(a, req, "no program");
            var cmdline: std.ArrayList(u8) = .empty;
            try quoteArg(a, &cmdline, program);
            for (json.items(json.get(args, "args"))) |arg| {
                try cmdline.append(a, ' ');
                try quoteArg(a, &cmdline, json.str(arg) orelse "");
            }
            const cwd = json.str(json.get(args, "cwd"));
            try setEnv(a, json.get(args, "env"));
            // a console of its own, unless the configuration wants none (its output is then lost)
            const window = !std.mem.eql(u8, json.str(json.get(args, "console")) orelse "", "internalConsole");
            s.engine.launch(a, program, cmdline.items, cwd, window) catch |e| return s.fail(a, req, try a.print("could not start the program: {s} at {s} (0x{x})", .{ @errorName(e), dbgeng.last_step, dbgeng.last_failure }));
            s.stop_at_entry = flag(args, "stopAtEntry");
            s.launched = true;
            index(s, a, json.str(json.get(args, "sourceRoot")) orelse cwd orelse std.Io.Dir.path.dirname(program) orelse ".");
            s.respond(a, req, null);
            s.event(a, "initialized", null);
        },
        .attach => {
            const pid = json.int(json.get(args, "processId")) orelse return s.fail(a, req, "no processId");
            s.engine.attach(@intCast(pid)) catch return s.fail(a, req, "could not attach");
            s.launched = true;
            s.attached = true;
            if (json.str(json.get(args, "sourceRoot"))) |root| index(s, a, root);
            s.respond(a, req, null);
            s.event(a, "initialized", null);
        },
        .setBreakpoints => try breakpoints.set(s, a, req, args),
        .setExceptionBreakpoints => try breakpoints.setExceptions(s, a, req, args),
        .setFunctionBreakpoints => s.respond(a, req, .{ .breakpoints = &[_]u8{} }),
        .exceptionInfo => s.respond(a, req, .{
            .exceptionId = s.last_error,
            .description = if (std.mem.find(u8, s.last_error, "error_stop") != null) "ERROR STOP" else "Fortran runtime error",
            .breakMode = "always",
        }),
        .configurationDone => {
            s.respond(a, req, null);
            // the main program: Intel's, LLVM Flang's
            if (s.stop_at_entry) for ([_][]const u8{ "MAIN__", "_QQmain" }) |m| {
                _ = s.engine.addSymbolBreakpoint(a, m, true) catch {};
            };
            try go(s, .go, null);
        },
        .threads => {
            var out: std.ArrayList(Value) = .empty;
            for (try s.engine.threads(a)) |t| {
                try out.append(a, try json.from(a, .{ .id = t.id, .name = try a.print("Thread {d}", .{t.system_id}) }));
            }
            s.respond(a, req, .{ .threads = out.items });
        },
        .stackTrace => {
            const thread: u32 = @intCast(json.int(json.get(args, "threadId")) orelse 0);
            const frames = try s.engine.stack(a, thread, 64);
            var out: std.ArrayList(Value) = .empty;
            for (frames, 0..) |f, i| {
                const name = displayName(f.name);
                const id: i64 = @as(i64, thread) * 1000 + @as(i64, @intCast(i));
                if (f.file) |file| {
                    const exists = paths.isFile(s.io, file);
                    try out.append(a, try json.from(a, .{
                        .id = id,
                        .name = name,
                        .source = .{ .path = file, .presentationHint = if (exists) "normal" else "deemphasize" },
                        .line = f.line,
                        .column = 1,
                        .presentationHint = if (exists) "normal" else "subtle",
                    }));
                } else {
                    try out.append(a, try json.from(a, .{ .id = id, .name = name, .line = 0, .column = 0, .presentationHint = "subtle" }));
                }
            }
            s.respond(a, req, .{ .stackFrames = out.items, .totalFrames = out.items.len });
        },
        .scopes => {
            const frame = frameOf(json.int(json.get(args, "frameId")) orelse 0);
            var scopes: std.ArrayList(Value) = .empty;
            try scopes.append(a, try json.from(a, .{ .name = "Locals", .presentationHint = "locals", .variablesReference = try addNode(s, .{ .locals = frame }), .expensive = false }));
            try scopes.append(a, try json.from(a, .{ .name = "Module variables", .variablesReference = try addNode(s, .{ .modules = frame }), .expensive = false }));
            s.respond(a, req, .{ .scopes = scopes.items });
        },
        .variables => {
            const ref = json.int(json.get(args, "variablesReference")) orelse 0;
            if (ref <= 0 or ref > s.nodes.items.len) return s.respond(a, req, .{ .variables = &[_]u8{} });
            const node = s.nodes.items[@intCast(ref - 1)];
            s.respond(a, req, .{ .variables = try children(s, a, node) });
        },
        .evaluate => {
            const expr = json.str(json.get(args, "expression")) orelse return s.fail(a, req, "no expression");
            const frame = frameOf(json.int(json.get(args, "frameId")) orelse 0);
            const v = (try evaluate(s, a, frame, expr)) orelse return s.fail(a, req, "not available");
            const shown = try show(s, a, expr, v);
            s.respond(a, req, .{ .result = json.str(json.get(shown, "value")) orelse "", .type = json.get(shown, "type"), .variablesReference = json.get(shown, "variablesReference") orelse Value{ .integer = 0 } });
        },
        .@"continue" => {
            s.respond(a, req, .{ .allThreadsContinued = true });
            try go(s, .go, null);
        },
        .next, .stepIn, .stepOut => {
            const thread: ?u32 = if (json.int(json.get(args, "threadId"))) |t| @intCast(t) else null;
            s.respond(a, req, null);
            try go(s, switch (cmd) {
                .next => .over,
                .stepIn => .into,
                else => .out,
            }, thread);
        },
        .pause => s.respond(a, req, null),
        .disconnect, .terminate => {
            const keep = s.attached and !flag(args, "terminateDebuggee");
            if (keep) s.engine.detach() else s.engine.terminate();
            s.respond(a, req, null);
            if (cmd == .terminate) s.event(a, "terminated", null);
            s.done = true;
        },
    }
}

fn go(s: *Session, how: Engine.Resume, thread: ?u32) !void {
    s.nodes.clearRetainingCapacity();
    _ = s.nodes_arena.reset(.retain_capacity);
    try s.engine.resumeThread(how, thread);
    s.running = true;
}

fn stopped(s: *Session, a: Allocator, stop: dbgeng.Stop) void {
    s.running = false;
    // breakpoints resolved since (a module loaded): the client is told
    var it = s.unverified.iterator();
    var resolved: std.ArrayList(u32) = .empty;
    while (it.next()) |kv| if (s.engine.breakpointOffset(kv.key_ptr.*) != null) {
        s.event(a, "breakpoint", .{ .reason = "changed", .breakpoint = .{ .id = kv.key_ptr.*, .verified = true, .line = kv.value_ptr.* } });
        resolved.append(a, kv.key_ptr.*) catch {};
    };
    for (resolved.items) |id| _ = s.unverified.remove(id);
    switch (stop) {
        .running => s.running = true,
        .exited => |code| {
            s.event(a, "exited", .{ .exitCode = code });
            s.event(a, "terminated", null);
        },
        .breakpoint => |b| if (errorFunction(s, b.id)) |f| {
            s.last_error = f;
            s.event(a, "stopped", .{
                .reason = "exception",
                .threadId = b.thread,
                .allThreadsStopped = true,
                .description = if (std.mem.find(u8, f, "error_stop") != null) "ERROR STOP" else "Fortran runtime error",
            });
        } else if (isUserBreakpoint(s, b.id))
            s.event(a, "stopped", .{ .reason = "breakpoint", .threadId = b.thread, .allThreadsStopped = true, .hitBreakpointIds = &[_]u32{b.id} })
        else
            // the engine's own (step out, stop at entry)
            s.event(a, "stopped", .{ .reason = "step", .threadId = b.thread, .allThreadsStopped = true }),
        .step => |t| s.event(a, "stopped", .{ .reason = "step", .threadId = t, .allThreadsStopped = true }),
        .pause => |t| s.event(a, "stopped", .{ .reason = "pause", .threadId = t, .allThreadsStopped = true }),
        .exception => |e| s.event(a, "stopped", .{
            .reason = "exception",
            .threadId = e.thread,
            .allThreadsStopped = true,
            .description = e.description,
            .text = a.print("0x{x}", .{e.code}) catch "",
        }),
    }
}

fn frameOf(id: i64) Frame {
    return .{ .thread = @intCast(@divTrunc(id, 1000)), .index = @intCast(@mod(id, 1000)) };
}

/// A value kept as a node: its slices copied from the request's memory
/// to the nodes', which last until the program goes on
pub fn persist(s: *Session, v: Val) !Val {
    const na = s.nodes_arena.allocator();
    var out = v;
    out.extents = try na.dupe(values.Extent, v.extents);
    out.chosen = try na.dupe(i64, v.chosen);
    out.expr = try na.dupe(u8, v.expr);
    out.base = try na.dupe(u8, v.base);
    out.t.name = try na.dupe(u8, v.t.name);
    return out;
}

pub fn addNode(s: *Session, n: Node) !i64 {
    try s.nodes.append(s.gpa, n);
    return @intCast(s.nodes.items.len);
}

/// `min1!GRID::WORK` -> `grid::work`
fn displayName(name: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, name, '!')) |i| name[i + 1 ..] else name;
}

/// A command line's argument, quoted as Windows's programs read them
fn quoteArg(a: Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.findAny(u8, arg, " \t\"") == null) return out.appendSlice(a, arg);
    try out.append(a, '"');
    var slashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            slashes += 1;
            continue;
        }
        try out.appendNTimes(a, '\\', if (c == '"') slashes * 2 + 1 else slashes);
        slashes = 0;
        try out.append(a, c);
    }
    try out.appendNTimes(a, '\\', slashes * 2);
    try out.append(a, '"');
}

/// The configuration's environment variables, for the program: set in
/// zfls's own environment, which the program inherits (the engine's
/// CreateProcess2Wide has no environment of its own on every Windows)
fn setEnv(a: Allocator, extra: ?Value) !void {
    const e = extra orelse return;
    if (e != .object) return;
    var it = e.object.iterator();
    while (it.next()) |kv| {
        const value = json.str(kv.value_ptr.*) orelse continue;
        const name = try std.unicode.utf8ToUtf16LeAllocZ(a, kv.key_ptr.*);
        const v = try std.unicode.utf8ToUtf16LeAllocZ(a, value);
        _ = SetEnvironmentVariableW(name.ptr, v.ptr);
    }
}

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;

fn flag(args: ?Value, name: []const u8) bool {
    const v = json.get(args, name) orelse return false;
    return v == .bool and v.bool;
}
