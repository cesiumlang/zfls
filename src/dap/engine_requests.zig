//! The requests of a session on Windows's Debugger Engine (dbgeng.zig),
//! and the program's stops; the session's state and dispatch are
//! session.zig's.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const paths = @import("../paths.zig");
const dbgeng = @import("dbgeng.zig");
const Value = json.Value;

const is_windows = builtin.target.os.tag == .windows;
const Engine = if (is_windows) dbgeng.Engine else void;

const breakpoints = @import("breakpoints.zig");
const runtime_errors = @import("runtime_errors.zig");
const errorFunction = breakpoints.errorFunction;
const isUserBreakpoint = breakpoints.isUserBreakpoint;
const isPlainStop = breakpoints.isPlainStop;
const declarations = @import("declarations.zig");
const index = declarations.index;
const memory = @import("memory.zig");
const evaluate = memory.evaluate;
const variables = @import("variables.zig");
const children = variables.children;
const show = variables.show;
const gdb = @import("gdb.zig");
const engine_conditions = @import("engine_conditions.zig");
const process_id = @import("process_id.zig");
const engine_data = @import("engine_data.zig");
const engine_completions = @import("engine_completions.zig");
const engine_set = @import("engine_set.zig");
const engine_functions = @import("engine_functions.zig");
const engine_inspect = @import("engine_inspect.zig");

const session = @import("session.zig");
const Session = session.Session;
const Frame = session.Frame;
const addNode = session.addNode;
const flag = session.flag;

/// The engine's requests
pub fn handle(s: *Session, a: Allocator, req: Value) !void {
    const command = json.str(json.get(req, "command")) orelse return;
    const args = json.get(req, "arguments");
    const Cmd = enum { launch, attach, setBreakpoints, setExceptionBreakpoints, setFunctionBreakpoints, exceptionInfo, configurationDone, threads, stackTrace, scopes, variables, evaluate, completions, setVariable, setExpression, readMemory, disassemble, modules, loadedSources, dataBreakpointInfo, setDataBreakpoints, @"continue", next, stepIn, stepOut, pause, disconnect, terminate };
    const cmd = std.meta.stringToEnum(Cmd, command) orelse return s.fail(a, req, "not supported");
    switch (cmd) {
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
            initialized(s, a);
        },
        .attach => {
            const pid = (process_id.parse(json.get(args, "processId")) catch return s.fail(a, req, "processId is not a process id")) orelse return s.fail(a, req, "no processId");
            s.engine.attach(pid) catch return s.fail(a, req, "could not attach");
            s.launched = true;
            s.attached = true;
            if (json.str(json.get(args, "sourceRoot"))) |root| index(s, a, root);
            s.respond(a, req, null);
            initialized(s, a);
        },
        .setBreakpoints => try breakpoints.set(s, a, req, args),
        .setExceptionBreakpoints => try breakpoints.setExceptions(s, a, req, args),
        .setFunctionBreakpoints => try engine_functions.set(s, a, req, args),
        .exceptionInfo => s.respond(a, req, .{
            .exceptionId = s.last_error,
            .description = if (runtime_errors.isErrorStop(s.last_error)) s.text.error_stop else s.text.runtime_error,
            .breakMode = "always",
        }),
        .configurationDone => {
            s.respond(a, req, null);
            // the main program: Intel's, LLVM Flang's
            if (s.stop_at_entry) for ([_][]const u8{ "MAIN__", "_QQmain" }) |m| {
                _ = s.engine.addSymbolBreakpoint(a, m, true) catch {};
            };
            goOn(s, a, .go, null);
        },
        .threads => {
            var out: std.ArrayList(Value) = .empty;
            for (try s.engine.threads(a)) |t| {
                try out.append(a, try json.from(a, .{ .id = t.id, .name = try a.print("Thread {d}", .{t.system_id}) }));
            }
            s.respond(a, req, .{ .threads = out.items });
        },
        .stackTrace => {
            const thread = std.math.cast(u32, json.int(json.get(args, "threadId")) orelse 0) orelse return s.fail(a, req, "no such thread");
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
                        .instructionPointerReference = try engine_inspect.reference(a, f.instruction),
                    }));
                } else {
                    try out.append(a, try json.from(a, .{ .id = id, .name = name, .line = 0, .column = 0, .presentationHint = "subtle", .instructionPointerReference = try engine_inspect.reference(a, f.instruction) }));
                }
            }
            s.respond(a, req, .{ .stackFrames = out.items, .totalFrames = out.items.len });
        },
        .scopes => {
            const frame = frameOf(json.int(json.get(args, "frameId")) orelse 0);
            var scopes: std.ArrayList(Value) = .empty;
            try scopes.append(a, try json.from(a, .{ .name = "Locals", .presentationHint = "locals", .variablesReference = try addNode(s, .{ .locals = frame }), .expensive = false }));
            try scopes.append(a, try json.from(a, .{ .name = s.text.module_variables, .variablesReference = try addNode(s, .{ .modules = frame }), .expensive = false }));
            s.respond(a, req, .{ .scopes = scopes.items });
        },
        .variables => {
            const ref = json.int(json.get(args, "variablesReference")) orelse 0;
            if (ref <= 0 or ref > s.nodes.items.len) return s.respond(a, req, .{ .variables = &[_]Value{} });
            const node = s.nodes.items[@intCast(ref - 1)];
            s.respond(a, req, .{ .variables = try children(s, a, node) });
        },
        .evaluate => {
            const expr = json.str(json.get(args, "expression")) orelse return s.fail(a, req, "no expression");
            const frame = frameOf(json.int(json.get(args, "frameId")) orelse 0);
            const v = (try evaluate(s, a, frame, expr)) orelse return s.fail(a, req, s.text.not_available);
            const shown = try show(s, a, expr, v);
            s.respond(a, req, .{ .result = json.str(json.get(shown, "value")) orelse "", .type = json.get(shown, "type"), .variablesReference = json.get(shown, "variablesReference") orelse Value{ .integer = 0 } });
        },
        .@"continue" => {
            s.respond(a, req, .{ .allThreadsContinued = true });
            goOn(s, a, .go, null);
        },
        .next, .stepIn, .stepOut => {
            const thread: ?u32 = if (json.int(json.get(args, "threadId"))) |t| std.math.cast(u32, t) else null;
            s.respond(a, req, null);
            s.step_from = if (cmd == .stepOut) null else stepFrom(s, a, cmd == .stepIn, thread);
            goOn(s, a, switch (cmd) {
                .next => .over,
                .stepIn => .into,
                else => .out,
            }, thread);
        },
        .pause => s.respond(a, req, null),
        .completions => try engine_completions.complete(s, a, req, args, frameOf(json.int(json.get(args, "frameId")) orelse 0)),
        .setVariable => try engine_set.setVariable(s, a, req, args),
        .readMemory => try engine_inspect.readMemory(s, a, req, args),
        .disassemble => try engine_inspect.disassemble(s, a, req, args),
        .modules => try engine_inspect.modules(s, a, req),
        .loadedSources => try engine_inspect.loadedSources(s, a, req),
        .setExpression => try engine_set.setExpression(s, a, req, args, frameOf(json.int(json.get(args, "frameId")) orelse 0)),
        .dataBreakpointInfo => try engine_data.info(s, a, req, args, frameOf(json.int(json.get(args, "frameId")) orelse 0)),
        .setDataBreakpoints => try engine_data.set(s, a, req, args),
        .disconnect, .terminate => {
            const keep = s.attached and !flag(args, "terminateDebuggee");
            if (keep) s.engine.detach() else s.engine.terminate();
            s.respond(a, req, null);
            if (cmd == .terminate) s.event(a, "terminated", null);
            s.done = true;
        },
    }
}

/// The engine's `initialized`, unless gdb's went first
fn initialized(s: *Session, a: Allocator) void {
    if (s.g.initialized_sent) return;
    s.g.initialized_sent = true;
    s.event(a, "initialized", null);
}

/// Where a step starts, when the engine's line there is not the one shown:
/// LLVM Flang's line tables have empty records before a statement's (an
/// END statement after the declarations'), the first of which the engine
/// steps by, so that it stops again on the line shown (#441)
pub const StepFrom = struct { into: bool, thread: u32, line: u32, function: u64, again: u8 = 0 };

fn stepFrom(s: *Session, a: Allocator, into: bool, thread: ?u32) ?StepFrom {
    const t = thread orelse return null;
    const frames = s.engine.stack(a, t, 1) catch return null;
    if (frames.len == 0 or frames[0].engine_line == frames[0].line) return null;
    return .{ .into = into, .thread = t, .line = frames[0].line, .function = std.hash.Wyhash.hash(0, frames[0].name) };
}

/// A step's stop on the line it started from, in the same function, from
/// where the engine's line was another (`StepFrom`): the step goes on
fn stepAgain(s: *Session, a: Allocator, thread: u32) bool {
    if (s.step_from == null) return false;
    const from = &s.step_from.?;
    if (from.again >= 4 or from.thread != thread) return false;
    const frames = s.engine.stack(a, thread, 1) catch return false;
    if (frames.len == 0 or frames[0].line != from.line or std.hash.Wyhash.hash(0, frames[0].name) != from.function) return false;
    from.again += 1;
    s.engine.resumeThread(if (from.into) .into else .over, thread) catch return false;
    s.running = true;
    return true;
}

/// `go` after the request's answer: a failure is told in the Debug Console,
/// with the program stopped where it was, not as a second answer (#972)
fn goOn(s: *Session, a: Allocator, how: Engine.Resume, thread: ?u32) void {
    go(s, how, thread) catch |e| {
        s.event(a, "output", .{ .category = "stderr", .output = a.print("zfls dap: the program could not go on: {s}\n", .{@errorName(e)}) catch "zfls dap: the program could not go on\n" });
        const t = thread orelse if (s.engine.threads(a)) |ts| (if (ts.len > 0) ts[0].id else 0) else |_| 0;
        s.event(a, "stopped", .{ .reason = "pause", .threadId = t, .allThreadsStopped = true });
    };
}

fn go(s: *Session, how: Engine.Resume, thread: ?u32) !void {
    if (how == .go or how == .out) s.step_from = null;
    s.nodes.clearRetainingCapacity();
    _ = s.nodes_arena.reset(.retain_capacity);
    try s.engine.resumeThread(how, thread);
    s.running = true;
}

pub fn stopped(s: *Session, a: Allocator, stop: dbgeng.Stop) void {
    s.running = false;
    const after_runtime_error = s.after_runtime_error;
    s.after_runtime_error = false;
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
            // LLVM Flang's plain STOP: the program goes on to its end
            if (isPlainStop(s, f)) return go(s, .go, null) catch {};
            s.last_error = f.name;
            s.after_runtime_error = !f.error_stop;
            s.event(a, "stopped", .{
                .reason = "exception",
                .threadId = b.thread,
                .allThreadsStopped = true,
                .description = if (f.error_stop) s.text.error_stop else s.text.runtime_error,
            });
        } else if (isUserBreakpoint(s, b.id)) {
            // a condition false, a hit ignored, a log message: on
            if (!engine_conditions.stops(s, a, b.id, b.thread)) return go(s, .go, null) catch {};
            s.event(a, "stopped", .{ .reason = "breakpoint", .threadId = b.thread, .allThreadsStopped = true, .hitBreakpointIds = &[_]u32{b.id} });
        } else if (engine_data.isDataBreakpoint(s, b.id)) {
            if (!engine_conditions.stops(s, a, b.id, b.thread)) return go(s, .go, null) catch {};
            s.event(a, "stopped", .{ .reason = "data breakpoint", .threadId = b.thread, .allThreadsStopped = true, .hitBreakpointIds = &[_]u32{b.id} });
        } else {
            // the engine's own (step out, stop at entry)
            s.event(a, "stopped", .{ .reason = "step", .threadId = b.thread, .allThreadsStopped = true });
        },
        .step => |t| if (!stepAgain(s, a, t)) {
            s.step_from = null;
            s.event(a, "stopped", .{ .reason = "step", .threadId = t, .allThreadsStopped = true });
        },
        .pause => |t| s.event(a, "stopped", .{ .reason = "pause", .threadId = t, .allThreadsStopped = true }),
        .trap => |t| {
            // the Intel runtime's `int 3` in `for__issue_diagnostic`, after
            // the filter's stop there: the program goes on (#493)
            if (after_runtime_error) return go(s, .go, null) catch {};
            // without the filter: the runtime error, as the filter says it
            const intel = inIntelDiagnostic(s, a, t.thread);
            if (intel) s.last_error = intel_diagnostic;
            s.event(a, "stopped", .{
                .reason = "exception",
                .threadId = t.thread,
                .allThreadsStopped = true,
                .description = if (intel) s.text.runtime_error else t.description,
                .text = "0x80000003",
            });
        },
        .exception => |e| s.event(a, "stopped", .{
            .reason = "exception",
            .threadId = e.thread,
            .allThreadsStopped = true,
            .description = e.description,
            .text = a.print("0x{x}", .{e.code}) catch "",
        }),
    }
}

/// The function of the Intel runtime that reports a runtime error
const intel_diagnostic = "for__issue_diagnostic";

/// Whether thread `thread` stopped in `for__issue_diagnostic` (the engine
/// names it `libifcoremd!for__issue_diagnostic+0x8a3`)
fn inIntelDiagnostic(s: *Session, a: Allocator, thread: u32) bool {
    const frames = s.engine.stack(a, thread, 1) catch return false;
    return frames.len > 0 and isIntelDiagnostic(frames[0].name);
}

fn isIntelDiagnostic(name: []const u8) bool {
    const at = std.mem.find(u8, name, intel_diagnostic) orelse return false;
    const end = at + intel_diagnostic.len;
    return (at == 0 or name[at - 1] == '!') and (end == name.len or name[end] == '+');
}

test "the Intel runtime's function of runtime errors, as the engine names a place in it" {
    try std.testing.expect(isIntelDiagnostic("libifcoremd!for__issue_diagnostic+0x8a3"));
    try std.testing.expect(isIntelDiagnostic("for__issue_diagnostic"));
    try std.testing.expect(!isIntelDiagnostic("libifcoremd!for__issue_diagnostic_x+0x10"));
    try std.testing.expect(!isIntelDiagnostic("hello!main+0x20"));
}

fn frameOf(id: i64) Frame {
    // a client's number: none that is out of range panics (#972)
    return .{ .thread = std.math.cast(u32, @divTrunc(id, 1000)) orelse 0, .index = std.math.cast(u32, @mod(id, 1000)) orelse 0 };
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
