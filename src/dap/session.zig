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
const C = @import("../constants.zig");
const paths = @import("../paths.zig");
const values = @import("values.zig");
const dbgeng = @import("dbgeng.zig");
const Engine = dbgeng.Engine;
const Value = json.Value;

/// Arrays of more elements are shown in sections
const chunk = 100;

const Queue = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    items: std.ArrayList([]u8) = .empty,
    closed: bool = false,
};

const Session = struct {
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

    fn respond(s: *Session, a: Allocator, req: Value, body: anytype) void {
        s.send(a, .{
            .type = "response",
            .request_seq = json.int(json.get(req, "seq")) orelse 0,
            .command = json.str(json.get(req, "command")) orelse "",
            .success = true,
            .body = body,
        });
    }

    fn fail(s: *Session, a: Allocator, req: Value, message: []const u8) void {
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
const Node = union(enum) {
    locals: Frame,
    modules: Frame,
    module: struct { frame: Frame, name: []const u8 },
    value: Val,
};

const Frame = struct { thread: u32, index: u32 };

/// A Fortran value in the program's memory
const Val = struct {
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
        if (std.mem.indexOf(u8, body, "\"pause\"") != null) s.engine.interrupt();
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
            s.engine.launch(a, cmdline.items, cwd, window) catch |e| return s.fail(a, req, try a.print("could not start the program: {s} at {s} (0x{x})", .{ @errorName(e), dbgeng.last_step, dbgeng.last_failure }));
            s.stop_at_entry = flag(args, "stopAtEntry");
            s.launched = true;
            index(s, a, json.str(json.get(args, "sourceRoot")) orelse cwd orelse std.fs.path.dirname(program) orelse ".");
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
        .setBreakpoints => {
            const file = json.str(json.path(args, &.{ "source", "path" })) orelse return s.fail(a, req, "no source");
            const key = try std.ascii.allocLowerString(s.gpa, file);
            const gop = try s.breakpoints.getOrPut(s.gpa, key);
            if (gop.found_existing) {
                s.gpa.free(key);
                for (gop.value_ptr.items) |id| s.engine.removeBreakpoint(id);
                gop.value_ptr.clearRetainingCapacity();
            } else gop.value_ptr.* = .empty;
            var out: std.ArrayList(Value) = .empty;
            for (json.items(json.get(args, "breakpoints"))) |b| {
                const line: u32 = @intCast(json.int(json.get(b, "line")) orelse continue);
                const bp = s.engine.addBreakpoint(a, file, line, json.str(json.get(b, "condition"))) catch {
                    try out.append(a, try json.from(a, .{ .verified = false, .line = line }));
                    continue;
                };
                try gop.value_ptr.append(s.gpa, bp.id);
                try out.append(a, try json.from(a, .{ .id = bp.id, .verified = bp.offset != null, .line = line }));
            }
            s.respond(a, req, .{ .breakpoints = out.items });
        },
        .setExceptionBreakpoints => {
            var wanted = false;
            for (json.items(json.get(args, "filters"))) |f| {
                if (std.mem.eql(u8, json.str(f) orelse "", runtime_errors_filter)) wanted = true;
            }
            for (s.error_breakpoints.items) |id| s.engine.removeBreakpoint(id);
            s.error_breakpoints.clearRetainingCapacity();
            if (wanted) for (runtime_error_functions) |f| {
                const bp = s.engine.addSymbolBreakpoint(a, f, false) catch continue;
                try s.error_breakpoints.append(s.gpa, bp.id);
            };
            s.respond(a, req, .{ .breakpoints = &[_]struct { verified: bool }{.{ .verified = true }} });
        },
        .setFunctionBreakpoints => s.respond(a, req, .{ .breakpoints = &[_]u8{} }),
        .exceptionInfo => s.respond(a, req, .{
            .exceptionId = s.last_error,
            .description = if (std.mem.indexOf(u8, s.last_error, "error_stop") != null) "ERROR STOP" else "Fortran runtime error",
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
                .description = if (std.mem.indexOf(u8, f, "error_stop") != null) "ERROR STOP" else "Fortran runtime error",
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

/// The exception filter of the Fortran runtime's errors
const runtime_errors_filter = "fortranRuntimeErrors";

/// What Intel's runtime calls on a severe error (an array bound exceeded
/// under /check:bounds, a failed allocation, an I/O error without iostat=)
/// and on ERROR STOP; LLVM Flang's
const runtime_error_functions = [_][]const u8{
    "for__issue_diagnostic",
    "for_error_stop",
    "for_error_stop8",
    "for_error_stop_int",
    "for_error_stop_int8",
    "_FortranAReportFatalUserError",
    "_FortranAStopStatement",
};

fn errorFunction(s: *Session, id: u32) ?[]const u8 {
    for (s.error_breakpoints.items, 0..) |x, i| if (x == id) return runtime_error_functions[i];
    return null;
}

fn isUserBreakpoint(s: *Session, id: u32) bool {
    var it = s.breakpoints.valueIterator();
    while (it.next()) |ids| for (ids.items) |x| if (x == id) return true;
    return false;
}

fn frameOf(id: i64) Frame {
    return .{ .thread = @intCast(@divTrunc(id, 1000)), .index = @intCast(@mod(id, 1000)) };
}

/// A value kept as a node: its slices copied from the request's memory
/// to the nodes', which last until the program goes on
fn persist(s: *Session, v: Val) !Val {
    const na = s.nodes_arena.allocator();
    var out = v;
    out.extents = try na.dupe(values.Extent, v.extents);
    out.chosen = try na.dupe(i64, v.chosen);
    out.expr = try na.dupe(u8, v.expr);
    out.base = try na.dupe(u8, v.base);
    out.t.name = try na.dupe(u8, v.t.name);
    return out;
}

fn addNode(s: *Session, n: Node) !i64 {
    try s.nodes.append(s.gpa, n);
    return @intCast(s.nodes.items.len);
}

/// `min1!GRID::WORK` -> `grid::work`
fn displayName(name: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, name, '!')) |i| name[i + 1 ..] else name;
}

/// A command line's argument, quoted as Windows's programs read them
fn quoteArg(a: Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null) return out.appendSlice(a, arg);
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

// The declarations: zfls's index of the program's sources

fn index(s: *Session, a: Allocator, root: []const u8) void {
    const srv = server_mod.Server.create(s.gpa, s.io, .{}, &s.log) catch return;
    _ = srv.dispatchPublic(a, "initialize", json.from(a, .{ .rootPath = root }) catch return) catch {};
    s.server = srv;
}

/// The scope of a frame's line, innermost first, and its file's AST
fn scopeOf(s: *Session, a: Allocator, frame: Frame) ?struct { scope: *Obj, file: []const u8, line: u32 } {
    const srv = s.server orelse return null;
    const frames = s.engine.stack(a, frame.thread, frame.index + 1) catch return null;
    if (frame.index >= frames.len) return null;
    const f = frames[frame.index];
    const file = f.file orelse return null;
    const uri = paths.pathToUri(a, file) catch return null;
    const ff = (srv.fileFromUri(a, uri) catch return null) orelse return null;
    const ast = ff.ast orelse return null;
    const scope = ast.getInnerScope(f.line) orelse return null;
    return .{ .scope = scope, .file = file, .line = f.line };
}

const FrameVariable = struct { v: dbgeng.Variable, decl: ?Decl };

/// A frame's variables with their declarations: Intel's own left out (the
/// hidden lengths of CHARACTER(LEN=*) arguments, `_.t6_`, which go, in
/// order, to those arguments; its temporaries)
fn frameVariables(s: *Session, a: Allocator, frame: Frame) ![]FrameVariable {
    const vars = try s.engine.variables(a, frame.thread, frame.index);
    const where = scopeOf(s, a, frame);
    var lengths: std.ArrayList(u32) = .empty;
    for (vars) |v| {
        if (!v.parameter or !std.mem.startsWith(u8, v.name, "_.t") or !std.mem.endsWith(u8, v.name, "_")) continue;
        var b: [8]u8 = undefined;
        try lengths.append(a, if (s.engine.read(v.address, &b) == 8) @intCast(@min(std.mem.readInt(u64, &b, .little), 1 << 20)) else 0);
    }
    var next_length: usize = 0;
    var out: std.ArrayList(FrameVariable) = .empty;
    for (vars) |v| {
        if (std.mem.indexOfScalar(u8, v.name, '.') != null or std.mem.startsWith(u8, v.name, "_")) continue;
        var decl: ?Decl = if (where) |w| if (declaration(w.scope, v.name)) |o| declOf(a, o) else null else null;
        // a module's variable seen by a USE statement
        if (decl == null and !v.parameter) if (where) |w| if (useDeclaration(s, a, w.file, w.line, v.name)) |o| {
            decl = declOf(a, o);
        };
        if (decl) |*d| if (v.parameter and d.t.kind == .character and d.t.size == 0 and next_length < lengths.items.len) {
            d.t.size = lengths.items[next_length];
            next_length += 1;
        };
        try out.append(a, .{ .v = v, .decl = decl });
    }
    return out.items;
}

/// The declaration of a module variable that a line sees by its local
/// name (`zfls/moduleVariables`)
fn useDeclaration(s: *Session, a: Allocator, file: []const u8, line: u32, name: []const u8) ?*const Obj {
    const srv = s.server orelse return null;
    const uri = paths.pathToUri(a, file) catch return null;
    const items = srv.dispatchPublic(a, "zfls/moduleVariables", json.from(a, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = line - 1, .character = 0 },
    }) catch return null) catch return null;
    const ff = (srv.fileFromUri(a, uri) catch return null) orelse return null;
    const ast = ff.ast orelse return null;
    for (json.items(items)) |it| {
        const local = json.str(json.get(it, "local")) orelse continue;
        if (!std.ascii.eqlIgnoreCase(local, name)) continue;
        const mod = srv.env(a).global(ast, json.str(json.get(it, "module")) orelse continue) orelse continue;
        const real = json.str(json.get(it, "name")) orelse local;
        for (mod.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, real)) return c;
    }
    return null;
}

/// The declaration of `name` seen from `scope`: its scopes' variables
fn declaration(scope: *Obj, name: []const u8) ?*const Obj {
    var sc: ?*Obj = scope;
    while (sc) |o| : (sc = o.parent) {
        for (o.childList()) |c| {
            if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, name)) return c;
        }
    }
    return null;
}

const Decl = struct {
    t: values.Type,
    dims: []const values.Dim = &.{},
    allocatable: bool = false,
    pointer: bool = false,
    obj: ?*const Obj = null,
};

/// A declaration's type as written: `REAL(8)`, `TYPE(point)` (zfls keeps
/// the kind or the type's name apart)
fn declaredType(a: Allocator, o: *const Obj) []const u8 {
    const v = o.varDataConst();
    const k = v.vkind orelse return v.desc;
    // zfls keeps it as written: `(8)`, `(len=*)`, `*8`
    if (k.len > 0 and (k[0] == '(' or k[0] == '*')) return a.print("{s}{s}", .{ v.desc, k }) catch v.desc;
    return a.print("{s}({s})", .{ v.desc, k }) catch v.desc;
}

fn declOf(a: Allocator, o: *const Obj) Decl {
    var d: Decl = .{ .t = values.parseType(declaredType(a, o)), .obj = o };
    for (o.keywords.items) |k| switch (k) {
        .allocatable => d.allocatable = true,
        .pointer => d.pointer = true,
        else => {},
    };
    if (o.keyword_info.dimension) |dims| d.dims = values.parseDims(a, dims) catch &.{};
    return d;
}

/// A derived type's definition, by name, from `scope` or the modules
fn typeDefinition(s: *Session, scope: *Obj, name: []const u8) ?*const Obj {
    var sc: ?*Obj = scope;
    while (sc) |o| : (sc = o.parent) {
        for (o.childList()) |c| if (c.kind == .type and std.ascii.eqlIgnoreCase(c.name, name)) return c;
    }
    const srv = s.server orelse return null;
    var it = srv.workspace.iterator();
    while (it.next()) |kv| {
        const ast = kv.value_ptr.*.ast orelse continue;
        for (ast.scope_list.items) |o| if (o.kind == .type and std.ascii.eqlIgnoreCase(o.name, name)) return o;
    }
    return null;
}

// Values

/// The value of a variable of the program, as Fortran declares it
fn valueOf(s: *Session, a: Allocator, v: dbgeng.Variable, decl: ?Decl, frame: Frame, expr: []const u8) !Val {
    var address = v.address;
    var type_index = v.type_index;
    // arguments: Intel passes their addresses
    const tag = s.engine.typeInfo(u32, v.mod_base, type_index, .symtag) orelse 0;
    if (v.parameter and tag == @backingInt(dbgeng.SymTag.pointer)) {
        var p: [8]u8 = undefined;
        if (s.engine.read(address, &p) == 8) address = std.mem.readInt(u64, &p, .little);
        type_index = s.engine.typeInfo(u32, v.mod_base, type_index, .type) orelse type_index;
    }
    // a scalar of a derived type: to the structure (a CLASS dummy is a
    // pointer to a pointer to it)
    if (decl != null and decl.?.t.kind == .derived and decl.?.dims.len == 0) {
        for (0..2) |_| {
            if (s.engine.typeInfo(u32, v.mod_base, type_index, .symtag) != @backingInt(dbgeng.SymTag.pointer)) break;
            var p: [8]u8 = undefined;
            if (s.engine.read(address, &p) != 8) break;
            address = std.mem.readInt(u64, &p, .little);
            type_index = s.engine.typeInfo(u32, v.mod_base, type_index, .type) orelse break;
        }
    }
    const d = decl orelse return .{ .address = address, .t = rawType(s, v.mod_base, type_index), .expr = expr, .type_index = type_index, .mod_base = v.mod_base };
    var val: Val = .{ .address = address, .t = d.t, .expr = expr, .type_index = type_index, .mod_base = v.mod_base, .decl = d.obj };
    if (d.t.kind == .derived) val.type_index = elementType(s, v.mod_base, type_index);
    if (d.dims.len == 0) {
        if (d.t.kind == .character and d.t.size == 0) val.t.size = s.engine.typeInfo(u32, v.mod_base, type_index, .length) orelse 0;
        return val;
    }
    // arrays: Intel's descriptor for those of deferred or assumed shape
    if (d.allocatable or d.pointer or (!values.constantShape(d.dims) and dimsDeferred(d.dims))) {
        var words: [6 + 3 * 7]u64 = undefined;
        const got = s.engine.read(address, std.mem.sliceAsBytes(words[0..]));
        const desc = values.Descriptor.parse(words[0 .. got / 8]) orelse return error.Unreadable;
        if (desc.empty()) {
            val.empty = true;
            val.rank = d.dims.len;
            return val;
        }
        val.address = desc.base;
        if (val.t.kind == .character) val.t.size = @intCast(desc.elem_len);
        val.extents = try a.dupe(values.Extent, desc.dims[0..desc.rank]);
        val.rank = desc.rank;
        val.count = val.extents[val.rank - 1].count;
        return val;
    }
    // explicit shape: contiguous, its bounds numbers or the frame's integers
    const elem: u64 = if (val.t.kind == .derived) (s.engine.typeInfo(u64, v.mod_base, val.type_index, .length) orelse 0) else val.t.size;
    const dims = try a.dupe(values.Dim, d.dims);
    for (dims, d.dims) |*x, orig| {
        if (orig.hi == null) x.hi = try boundOf(s, a, frame, orig, true);
        if (orig.lo == null) x.lo = try boundOf(s, a, frame, orig, false);
    }
    if (!values.constantShape(dims)) return error.Unreadable;
    const ext = try a.alloc(values.Extent, dims.len);
    val.extents = values.contiguous(dims, elem, ext);
    val.rank = dims.len;
    val.count = val.extents[val.rank - 1].count;
    return val;
}

fn dimsDeferred(dims: []const values.Dim) bool {
    for (dims) |d| if (d.lo == null and d.hi == null) return true;
    return false;
}

/// A bound that is a variable of the frame (`a(n)`): its value
fn boundOf(s: *Session, a: Allocator, frame: Frame, d: values.Dim, hi: bool) !?i64 {
    _ = d;
    _ = hi;
    _ = s;
    _ = a;
    _ = frame;
    return null;
}

/// The type of an element (an array's) or the pointee
fn elementType(s: *Session, mod_base: u64, type_index: u32) u32 {
    var t = type_index;
    for (0..4) |_| {
        const tag = s.engine.typeInfo(u32, mod_base, t, .symtag) orelse return t;
        if (tag != @backingInt(dbgeng.SymTag.array) and tag != @backingInt(dbgeng.SymTag.pointer) and tag != @backingInt(dbgeng.SymTag.typedef)) return t;
        t = s.engine.typeInfo(u32, mod_base, t, .type) orelse return t;
    }
    return t;
}

/// The Fortran type of dbghelp's (without a declaration)
fn rawType(s: *Session, mod_base: u64, type_index: u32) values.Type {
    const tag = s.engine.typeInfo(u32, mod_base, type_index, .symtag) orelse return .{ .kind = .unknown };
    const len: u32 = @intCast(s.engine.typeInfo(u64, mod_base, type_index, .length) orelse 0);
    if (tag == @backingInt(dbgeng.SymTag.udt)) return .{ .kind = .derived, .size = len };
    if (tag != @backingInt(dbgeng.SymTag.base)) return .{ .kind = .unknown, .size = len };
    return switch (s.engine.typeInfo(u32, mod_base, type_index, .basetype) orelse 0) {
        8 => .{ .kind = .real, .size = len },
        10 => .{ .kind = .logical, .size = len },
        2 => .{ .kind = .character, .size = len },
        else => .{ .kind = .integer, .size = len },
    };
}

/// A value as a variable of the protocol: its value text, its type, and a
/// reference to its children
fn show(s: *Session, a: Allocator, name: []const u8, v: Val) !Value {
    var text: []const u8 = undefined;
    var ref: i64 = 0;
    const type_name = try typeText(a, v);
    if (v.empty) {
        text = if (v.decl != null and hasKeyword(v.decl.?, .allocatable)) "not allocated" else "not associated";
    } else if (v.rank > v.chosen.len) {
        ref = try addNode(s, .{ .value = try persist(s, v) });
        text = try arrayPreview(s, a, v);
    } else if (v.t.kind == .derived) {
        ref = try addNode(s, .{ .value = try persist(s, v) });
        text = try derivedPreview(s, a, v);
    } else {
        text = try scalarText(s, a, v);
    }
    return json.from(a, .{ .name = name, .value = text, .type = type_name, .variablesReference = ref, .evaluateName = v.expr });
}

fn hasKeyword(o: *const Obj, k: C.Kw) bool {
    for (o.keywords.items) |x| if (x == k) return true;
    return false;
}

fn typeText(a: Allocator, v: Val) ![]const u8 {
    if (v.decl) |o| {
        if (o.kind == .variable) return declaredType(a, o);
    }
    return switch (v.t.kind) {
        .integer => a.print("INTEGER({d})", .{v.t.size}),
        .real => a.print("REAL({d})", .{v.t.size}),
        .complex => a.print("COMPLEX({d})", .{v.t.size / 2}),
        .logical => a.print("LOGICAL({d})", .{v.t.size}),
        .character => a.print("CHARACTER(LEN={d})", .{v.t.size}),
        .derived => a.print("TYPE({s})", .{v.t.name}),
        .unknown => "",
    };
}

fn scalarText(s: *Session, a: Allocator, v: Val) ![]const u8 {
    const size: usize = if (v.t.size == 0) 8 else @min(v.t.size, 4096);
    const b = try a.alloc(u8, size);
    if (s.engine.read(v.address, b) != size) return "<unreadable>";
    if (v.t.kind == .unknown) return values.scalar(a, .{ .kind = .integer, .size = @intCast(size) }, b);
    return values.scalar(a, v.t, b);
}

/// The element `i` (0-based) of the node's last dimension
fn elementOf(v: Val, i: u64) Val {
    const e = v.extents[v.rank - v.chosen.len - 1];
    var out = v;
    out.address = @bitCast(@as(i64, @bitCast(v.address)) + @as(i64, @intCast(i)) * e.stride);
    return out;
}

fn arrayPreview(s: *Session, a: Allocator, v: Val) ![]const u8 {
    const left = v.rank - v.chosen.len;
    if (left > 1) return values.shape(a, v.extents[0..left]);
    const e = v.extents[0];
    var shown: std.ArrayList([]const u8) = .empty;
    var i: u64 = 0;
    while (i < @min(e.count, 6)) : (i += 1) {
        const el = elementOf(v, i);
        var scalar = el;
        scalar.rank = 0;
        scalar.chosen = &.{};
        scalar.extents = &.{};
        try shown.append(a, if (v.t.kind == .derived) try a.print("{s}(…)", .{v.t.name}) else try scalarText(s, a, scalar));
    }
    return values.preview(a, shown.items, e.count);
}

fn derivedPreview(s: *Session, a: Allocator, v: Val) ![]const u8 {
    const comps = try components(s, a, v);
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}(", .{v.t.name});
    for (comps[0..@min(comps.len, 4)], 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        const text = if (c.rank > 0 or c.t.kind == .derived or c.empty) "…" else try scalarText(s, a, c);
        try out.print(a, "{s}={s}", .{ c.expr[std.mem.lastIndexOfScalar(u8, c.expr, '%').? + 1 ..], text });
    }
    if (comps.len > 4) try out.appendSlice(a, ", …");
    try out.append(a, ')');
    return out.items;
}

/// A derived type's components: dbghelp's members (their places), the
/// type's declaration (their Fortran types)
fn components(s: *Session, a: Allocator, v: Val) ![]Val {
    const members = try s.engine.members(a, v.mod_base, v.type_index);
    const def: ?*const Obj = blk: {
        const d = v.decl orelse break :blk null;
        if (d.kind == .variable) if (d.varDataConst().type_obj) |t| break :blk t;
        break :blk if (d.parent) |scope| typeDefinition(s, scope, v.t.name) else null;
    };
    var out: std.ArrayList(Val) = .empty;
    for (members) |m| {
        const expr = try a.print("{s}%{s}", .{ v.expr, try std.ascii.allocLowerString(a, m.name) });
        const comp_decl: ?Decl = if (def) |t| blk: {
            for (t.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, m.name)) break :blk declOf(a, c);
            break :blk null;
        } else null;
        const mv: dbgeng.Variable = .{ .name = m.name, .address = v.address + m.offset, .size = 0, .type_index = m.type_index, .mod_base = v.mod_base, .parameter = false };
        const cv = valueOf(s, a, mv, comp_decl, .{ .thread = 0, .index = 0 }, expr) catch continue;
        var c = cv;
        if (comp_decl == null) {
            c.t = rawType(s, v.mod_base, m.type_index);
            // the parent of an extended type (`extends(point)`): a component
            // of its name, which the type does not declare; its type's
            // definition is found by that name from the extended type's
            if (c.t.kind == .derived and def != null) {
                c.t.name = try std.ascii.allocLowerString(a, m.name);
                c.decl = def;
            }
        }
        if (c.t.kind == .derived and c.t.name.len == 0) c.t.name = s.engine.typeName(a, v.mod_base, m.type_index) orelse "";
        try out.append(a, c);
    }
    return out.items;
}

fn children(s: *Session, a: Allocator, node: Node) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    switch (node) {
        .locals => |frame| {
            for (try frameVariables(s, a, frame)) |fv| {
                const name = try std.ascii.allocLowerString(a, fv.v.name);
                const val = valueOf(s, a, fv.v, fv.decl, frame, name) catch {
                    try out.append(a, try json.from(a, .{ .name = name, .value = "not available", .variablesReference = 0 }));
                    continue;
                };
                try out.append(a, try show(s, a, name, val));
            }
        },
        .modules => |frame| {
            const where = scopeOf(s, a, frame) orelse return out.items;
            const srv = s.server orelse return out.items;
            const uri = try paths.pathToUri(a, where.file);
            const items = srv.dispatchPublic(a, "zfls/moduleVariables", try json.from(a, .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = where.line - 1, .character = 0 },
            })) catch return out.items;
            var seen: std.ArrayList([]const u8) = .empty;
            for (json.items(items)) |it| {
                const module = json.str(json.get(it, "module")) orelse continue;
                const listed = for (seen.items) |m| {
                    if (std.ascii.eqlIgnoreCase(m, module)) break true;
                } else false;
                if (listed) continue;
                try seen.append(a, module);
                try out.append(a, try json.from(a, .{ .name = module, .value = "", .variablesReference = try addNode(s, .{ .module = .{ .frame = frame, .name = try s.nodes_arena.allocator().dupe(u8, module) } }) }));
            }
        },
        .module => |m| {
            const where = scopeOf(s, a, m.frame) orelse return out.items;
            const srv = s.server orelse return out.items;
            const uri = try paths.pathToUri(a, where.file);
            const items = srv.dispatchPublic(a, "zfls/moduleVariables", try json.from(a, .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = where.line - 1, .character = 0 },
            })) catch return out.items;
            const env = srv.env(a);
            const ff = (srv.fileFromUri(a, uri) catch null) orelse return out.items;
            const ast = ff.ast orelse return out.items;
            const mod = env.global(ast, m.name);
            for (json.items(items)) |it| {
                const module = json.str(json.get(it, "module")) orelse continue;
                if (!std.ascii.eqlIgnoreCase(module, m.name)) continue;
                const name = json.str(json.get(it, "name")) orelse continue;
                const local = json.str(json.get(it, "local")) orelse name;
                const label = if (std.ascii.eqlIgnoreCase(local, name)) try std.ascii.allocLowerString(a, local) else try a.print("{s} => {s}", .{ local, name });
                const v = (try moduleGlobal(s, a, module, name)) orelse {
                    try out.append(a, try json.from(a, .{ .name = label, .value = "not available", .variablesReference = 0 }));
                    continue;
                };
                const decl: ?Decl = if (mod) |mo| blk: {
                    for (mo.childList()) |c| if (c.kind == .variable and std.ascii.eqlIgnoreCase(c.name, name)) break :blk declOf(a, c);
                    break :blk null;
                } else null;
                const expr = try a.print("{s}::{s}", .{ try std.ascii.allocLowerString(a, module), try std.ascii.allocLowerString(a, name) });
                const val = valueOf(s, a, v, decl, m.frame, expr) catch continue;
                try out.append(a, try show(s, a, label, val));
            }
        },
        .value => |v| {
            if (v.t.kind == .derived and v.rank == v.chosen.len) {
                for (try components(s, a, v)) |c| try out.append(a, try show(s, a, c.expr[std.mem.lastIndexOfScalar(u8, c.expr, '%').? + 1 ..], c));
                return out.items;
            }
            const left = v.rank - v.chosen.len;
            const e = v.extents[left - 1];
            const base = if (v.base.len > 0) v.base else v.expr;
            const total = if (v.count > 0) v.count else e.count;
            if (total > chunk) {
                // in sections of 100 (of 10000, ...)
                var per: u64 = chunk;
                while (total > per * chunk) per *= chunk;
                var start: u64 = 0;
                while (start < total) : (start += per) {
                    var sec = v;
                    sec.base = base;
                    sec.first = v.first + start;
                    sec.count = @min(per, total - start);
                    const lo = e.lo + @as(i64, @intCast(sec.first));
                    const label = try sectionLabel(a, left, v.chosen, lo, lo + @as(i64, @intCast(sec.count)) - 1);
                    try out.append(a, try json.from(a, .{ .name = label, .value = "", .variablesReference = try addNode(s, .{ .value = try persist(s, sec) }), .evaluateName = try a.print("{s}{s}", .{ base, label }) }));
                }
                return out.items;
            }
            var i: u64 = 0;
            while (i < total) : (i += 1) {
                const at = v.first + i;
                const sub = e.lo + @as(i64, @intCast(at));
                var el = elementOf(v, at);
                const chosen = try a.alloc(i64, v.chosen.len + 1);
                chosen[0] = sub;
                @memcpy(chosen[1..], v.chosen);
                el.chosen = try s.nodes_arena.allocator().dupe(i64, chosen);
                el.first = 0;
                el.count = 0;
                const label = try values.subscripts(a, v.rank, chosen);
                el.expr = try s.nodes_arena.allocator().dupe(u8, try a.print("{s}{s}", .{ base, label }));
                el.base = base;
                el.extents = try s.nodes_arena.allocator().dupe(values.Extent, v.extents);
                if (el.rank == el.chosen.len) {
                    var scalar = el;
                    if (el.t.kind != .derived) {
                        scalar.rank = 0;
                        scalar.chosen = &.{};
                        scalar.extents = &.{};
                    }
                    try out.append(a, try show(s, a, label, scalar));
                } else try out.append(a, try show(s, a, label, el));
            }
        },
    }
    return out.items;
}

fn sectionLabel(a: Allocator, rank: usize, chosen: []const i64, lo: i64, hi: i64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '(');
    for (0..rank - 1) |_| try out.appendSlice(a, ":,");
    try out.print(a, "{d}:{d}", .{ lo, hi });
    for (chosen) |c| try out.print(a, ",{d}", .{c});
    try out.append(a, ')');
    return out.items;
}

/// A module variable's place: by the names Intel and LLVM Flang give it
fn moduleGlobal(s: *Session, a: Allocator, module: []const u8, name: []const u8) !?dbgeng.Variable {
    const intel = try a.print("{s}_mp_{s}", .{ try std.ascii.allocUpperString(a, module), try std.ascii.allocUpperString(a, name) });
    if (try s.engine.global(a, intel)) |v| return v;
    const flang = try a.print("_QM{s}E{s}", .{ try std.ascii.allocLowerString(a, module), try std.ascii.allocLowerString(a, name) });
    return s.engine.global(a, flang);
}

/// An expression of a frame: a variable, its components and elements
/// (`p%x`, `a(2)`, `t%w(1)`), or a module's (`grid::cells`)
fn evaluate(s: *Session, a: Allocator, frame: Frame, expr: []const u8) !?Val {
    const text = std.mem.trim(u8, expr, " ");
    var parts = std.mem.splitScalar(u8, text, '%');
    const head = parts.first();
    const name_end = std.mem.indexOfScalar(u8, head, '(') orelse head.len;
    const name = std.mem.trim(u8, head[0..name_end], " ");
    var v: Val = undefined;
    if (std.mem.indexOf(u8, name, "::")) |sep| {
        const g = (try moduleGlobal(s, a, name[0..sep], name[sep + 2 ..])) orelse return null;
        v = try valueOf(s, a, g, null, frame, try std.ascii.allocLowerString(a, name));
    } else {
        const found = for (try frameVariables(s, a, frame)) |x| {
            if (std.ascii.eqlIgnoreCase(x.v.name, name)) break x;
        } else return null;
        v = try valueOf(s, a, found.v, found.decl, frame, try std.ascii.allocLowerString(a, name));
    }
    v = (try subscript(a, v, head[name_end..])) orelse return null;
    while (parts.next()) |p| {
        const pe = std.mem.indexOfScalar(u8, p, '(') orelse p.len;
        const comp = std.mem.trim(u8, p[0..pe], " ");
        const comps = try components(s, a, v);
        v = for (comps) |c| {
            if (std.ascii.eqlIgnoreCase(c.expr[std.mem.lastIndexOfScalar(u8, c.expr, '%').? + 1 ..], comp)) break c;
        } else return null;
        v = (try subscript(a, v, p[pe..])) orelse return null;
    }
    v.expr = text;
    return v;
}

/// An element by its subscripts (`(2,-1)`), all of them integers
fn subscript(a: Allocator, v: Val, text: []const u8) !?Val {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return v;
    if (t[0] != '(' or t[t.len - 1] != ')' or v.rank == 0) return null;
    var subs: std.ArrayList(i64) = .empty;
    var it = std.mem.splitScalar(u8, t[1 .. t.len - 1], ',');
    while (it.next()) |x| try subs.append(a, std.fmt.parseInt(i64, std.mem.trim(u8, x, " "), 10) catch return null);
    if (subs.items.len != v.rank) return null;
    var out = v;
    var offset: i64 = 0;
    for (subs.items, v.extents[0..v.rank]) |sub, e| {
        if (sub < e.lo or sub >= e.lo + @as(i64, @intCast(e.count))) return null;
        offset += (sub - e.lo) * e.stride;
    }
    out.address = @bitCast(@as(i64, @bitCast(v.address)) + offset);
    out.rank = 0;
    out.chosen = &.{};
    out.extents = &.{};
    return out;
}
