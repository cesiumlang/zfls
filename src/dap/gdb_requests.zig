//! The gdb backend of `zfls dap`: the client's requests passed to gdb
//! (gdb.zig) in order, and gdb's answers and events reshaped for Fortran:
//! the variables (gdb_variables.zig), a "Module variables" scope, the
//! "Fortran runtime errors" exception filter (breakpoints on the runtime's
//! error functions, whose stops are exceptions), the runtime's frames
//! de-emphasized, the program in a terminal (`console`), the
//! configuration's gdb commands (`setupCommands`), and values set by
//! Fortran expressions.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const paths = @import("../paths.zig");
const fortran = @import("fortran.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const runtime_errors_filter = @import("breakpoints.zig").runtime_errors_filter;
const declarations = @import("declarations.zig");
const gdb = @import("gdb.zig");
const vars = @import("gdb_variables.zig");
const Variable = vars.Variable;

/// gdb's exception breakpoint filters of Ada, of no use to Fortran
const ada_filters = [_][]const u8{ "assert", "exception" };

/// Requests that go on running the program: the variables of the last
/// stop are gone
const resuming = [_][]const u8{ "continue", "next", "stepIn", "stepOut", "stepBack", "reverseContinue", "goto" };

/// `initialize`: gdb's, its capabilities with the runtime's errors
pub fn initialize(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const r = try gdb.request(s, a, "initialize", try forGdbInitialize(s, a, args));
    if (gdb.isSuccess(r)) if (json.get(r, "body")) |body| if (body == .object) {
        var filters: json.Array = .init(a);
        try filters.append(try json.from(a, .{
            .filter = runtime_errors_filter,
            .label = s.text.runtime_errors,
            .description = s.text.runtime_errors_description,
            .default = true,
        }));
        for (json.items(json.get(body, "exceptionBreakpointFilters"))) |f| {
            const name = json.str(json.get(f, "filter")) orelse "";
            const ada = for (ada_filters) |x| {
                if (std.mem.eql(u8, x, name)) break true;
            } else false;
            if (!ada) try filters.append(f);
        }
        var o = body.object;
        try o.put(a, "supportsExceptionInfoRequest", .{ .bool = true });
        try o.put(a, "supportsSetVariable", .{ .bool = true });
        try o.put(a, "exceptionBreakpointFilters", .{ .array = filters });
        r.object.getPtr("body").?.* = .{ .object = o };
    };
    gdb.respondWith(s, a, req, r);
}

/// A second gdb's `initialize` (another gdb at `launch`): its answer is
/// not the client's
pub fn initializeAgain(s: *Session, a: Allocator) !void {
    const args = if (s.client_init.len > 0) json.parse(a, s.client_init) catch null else null;
    _ = try gdb.request(s, a, "initialize", try forGdbInitialize(s, a, args));
}

/// The client's arguments of `initialize`: the adapter, not gdb, runs the
/// program's terminal
fn forGdbInitialize(s: *Session, a: Allocator, args: ?Value) !Value {
    _ = s;
    var o: json.ObjectMap = .empty;
    if (args) |v| if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |kv| try o.put(a, kv.key_ptr.*, kv.value_ptr.*);
    };
    try o.put(a, "supportsRunInTerminalRequest", .{ .bool = false });
    return .{ .object = o };
}

/// `launch`, `attach`: the program's terminal and the configuration's gdb
/// commands, then gdb's request
pub fn launch(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const command = json.str(json.get(req, "command")) orelse "launch";
    try prepare(s, a, args);
    const program = json.str(json.get(args, "program"));
    const cwd = json.str(json.get(args, "cwd"));
    if (s.g.source_root) |r| s.gpa.free(r);
    const root = json.str(json.get(args, "sourceRoot")) orelse cwd orelse if (program) |p| std.Io.Dir.path.dirname(p) else null;
    s.g.source_root = if (root) |r| try s.gpa.dupe(u8, r) else null;
    var o: json.ObjectMap = .empty;
    const hold = std.mem.eql(u8, command, "launch") and s.g.runs_at_launch;
    if (std.mem.eql(u8, command, "launch")) {
        if (hold) {
            // as gdb 16 does: the directory and the program now, so that
            // the breakpoints find it, and the run at `configurationDone`
            for ([_]struct { []const u8, ?[]const u8 }{ .{ "cd", cwd }, .{ "file", program } }) |c| {
                const r = try gdb.request(s, a, "evaluate", .{ .expression = try a.print("{s} {s}", .{ c[0], c[1] orelse continue }), .context = "repl" });
                if (!gdb.isSuccess(r)) return gdb.respondWith(s, a, req, r);
            }
        } else {
            if (program) |p| try o.put(a, "program", .{ .string = p });
            if (cwd) |c| try o.put(a, "cwd", .{ .string = c });
        }
        var list: json.Array = .init(a);
        for (json.items(json.get(args, "args"))) |x| try list.append(.{ .string = try text(a, x) });
        try o.put(a, "args", .{ .array = list });
        try o.put(a, "env", try environment(s, a, json.get(args, "env")));
        const at_entry = json.get(args, "stopAtEntry");
        try o.put(a, "stopAtBeginningOfMainSubprogram", .{ .bool = at_entry != null and at_entry.? == .bool and at_entry.?.bool });
    } else {
        if (json.get(args, "processId")) |p| switch (p) {
            .integer => |n| try o.put(a, "pid", .{ .integer = n }),
            .string => |t| if (t.len > 0) try o.put(a, "pid", .{ .integer = std.fmt.parseInt(i64, std.mem.trim(u8, t, " "), 10) catch return s.fail(a, req, "processId is not a number") }),
            else => {},
        };
        if (program) |p| if (p.len > 0) try o.put(a, "program", .{ .string = p });
        if (json.get(args, "target")) |t| if (t != .null) try o.put(a, "target", .{ .string = try text(a, t) });
    }
    if (hold) {
        if (s.g.held_launch) |h| s.gpa.free(h);
        s.g.held_launch = try s.gpa.dupe(u8, try json.stringify(a, try json.from(a, .{
            .seq = json.int(json.get(req, "seq")) orelse 0,
            .command = command,
            .arguments = Value{ .object = o },
        })));
        return;
    }
    try gdb.forward(s, a, req, .{ .object = o });
}

/// A JSON value as text: a string's own
fn text(a: Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .string => |t| t,
        .integer => |n| a.print("{d}", .{n}),
        .bool => |b| if (b) "true" else "false",
        else => json.stringify(a, v),
    };
}

/// The program's environment: zfls's with the configuration's over it
/// (gdb gives the program exactly the environment it is given)
fn environment(s: *Session, a: Allocator, extra: ?Value) !Value {
    var env = try s.environ.clone(a);
    if (extra) |e| if (e == .object) {
        var it = e.object.iterator();
        while (it.next()) |kv| try env.put(kv.key_ptr.*, try text(a, kv.value_ptr.*));
    };
    var o: json.ObjectMap = .empty;
    var it = env.iterator();
    while (it.next()) |kv| try o.put(a, kv.key_ptr.*, .{ .string = kv.value_ptr.* });
    return .{ .object = o };
}

/// Before launch or attach: the program's terminal, and the
/// configuration's gdb commands
fn prepare(s: *Session, a: Allocator, args: ?Value) !void {
    const console = json.str(json.get(args, "console")) orelse "internalConsole";
    if (!std.mem.eql(u8, console, "internalConsole")) {
        if (builtin.target.os.tag == .windows) {
            _ = try gdb.request(s, a, "evaluate", .{ .expression = "set new-console on", .context = "repl" });
        } else if (s.g.run_in_terminal) {
            const kind = if (std.mem.eql(u8, console, "externalTerminal")) "external" else "integrated";
            if (try terminalTty(s, a, kind, json.str(json.get(args, "cwd")))) |tty| {
                _ = try gdb.request(s, a, "evaluate", .{ .expression = try a.print("set inferior-tty {s}", .{tty}), .context = "repl" });
            }
        }
    }
    for (json.items(json.get(args, "setupCommands"))) |c| {
        const command = json.str(c) orelse json.str(json.get(c, "text")) orelse continue;
        const t = std.mem.trim(u8, command, " \t\r\n");
        // cppdbg's are MI commands (`-enable-pretty-printing`)
        if (t.len == 0 or t[0] == '-') continue;
        const r = try gdb.request(s, a, "evaluate", .{ .expression = command, .context = "repl" });
        if (!gdb.isSuccess(r)) s.event(a, "output", .{ .category = "stderr", .output = try a.print("{s}: {s}\n", .{ command, json.str(json.get(r, "message")) orelse "" }) });
    }
}

/// A terminal of the client for the program: its tty, which a shell in it
/// writes to a file and then waits
fn terminalTty(s: *Session, a: Allocator, kind: []const u8, cwd: ?[]const u8) !?[]const u8 {
    const tmp = s.environ.get("TMPDIR") orelse "/tmp";
    const file = try a.print("{s}/zfls-tty-{d}", .{ std.mem.trimEnd(u8, tmp, "/"), Io.Clock.real.now(s.io).nanoseconds });
    const seq = s.sendSeq(a, .{
        .type = "request",
        .command = "runInTerminal",
        .arguments = .{
            .kind = kind,
            .title = "Fortran",
            .cwd = cwd orelse s.environ.get("HOME") orelse "/",
            .args = &[_][]const u8{ "/bin/sh", "-c", try a.print("tty > '{s}'; trap 'exit 0' HUP INT TERM; while :; do sleep 3600; done", .{file}) },
        },
    });
    const r = s.clientResponse(a, seq, .fromSeconds(60)) orelse return null;
    if (!gdb.isSuccess(r)) return null;
    s.g.terminal_pid = json.int(json.path(r, &.{ "body", "shellProcessId" })) orelse json.int(json.path(r, &.{ "body", "processId" }));
    for (0..100) |_| {
        if (Io.Dir.cwd().readFileAlloc(s.io, file, a, .limited(4096))) |content| {
            const tty = std.mem.trim(u8, content, " \t\r\n");
            if (tty.len > 0 and tty[0] == '/') {
                Io.Dir.cwd().deleteFile(s.io, file) catch {};
                return tty;
            }
        } else |_| {}
        s.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return null;
}

fn killTerminal(s: *Session) void {
    const pid = s.g.terminal_pid orelse return;
    s.g.terminal_pid = null;
    if (builtin.target.os.tag != .windows) std.posix.kill(@intCast(pid), .TERM) catch {};
}

/// The client's other requests
pub fn handle(s: *Session, a: Allocator, req: Value) !void {
    const command = json.str(json.get(req, "command")) orelse return;
    const args = json.get(req, "arguments");
    const Cmd = enum { configurationDone, setFunctionBreakpoints, setExceptionBreakpoints, exceptionInfo, stackTrace, scopes, variables, evaluate, setVariable, disconnect, terminate };
    const cmd = std.meta.stringToEnum(Cmd, command) orelse {
        for (resuming) |r| if (std.mem.eql(u8, r, command)) vars.clear(s);
        return gdb.forward(s, a, req, args);
    };
    switch (cmd) {
        .configurationDone => {
            const held = s.g.held_launch orelse return gdb.forward(s, a, req, args);
            s.g.held_launch = null;
            defer s.gpa.free(held);
            // gdb's own does nothing, and would find the program running
            s.respond(a, req, null);
            const launched = try json.parse(a, held);
            try gdb.forward(s, a, launched, json.get(launched, "arguments"));
        },
        .setFunctionBreakpoints => {
            if (s.g.user_functions.len > 0) s.gpa.free(s.g.user_functions);
            s.g.user_functions = try s.gpa.dupe(u8, try json.stringify(a, json.get(args, "breakpoints") orelse Value{ .array = .init(a) }));
            const r = try syncFunctions(s, a);
            const bps = json.items(json.path(r, &.{ "body", "breakpoints" }));
            const n = json.items(json.get(args, "breakpoints")).len;
            s.send(a, .{
                .type = "response",
                .request_seq = json.int(json.get(req, "seq")) orelse 0,
                .command = command,
                .success = gdb.isSuccess(r),
                .message = json.get(r, "message") orelse Value.null,
                .body = .{ .breakpoints = bps[0..@min(n, bps.len)] },
            });
        },
        .setExceptionBreakpoints => try setExceptions(s, a, req, args),
        .exceptionInfo => if (s.g.last_error) |f| s.respond(a, req, .{
            .exceptionId = f,
            .description = if (fortran.isErrorStop(f)) s.text.error_stop else s.text.runtime_error,
            .breakMode = "always",
        }) else s.fail(a, req, ""),
        .stackTrace => {
            const r = try gdb.request(s, a, command, args orelse Value.null);
            for (json.items(json.path(r, &.{ "body", "stackFrames" }))) |*f| {
                const file = json.str(json.path(f.*, &.{ "source", "path" }));
                try vars.keepFrame(s, json.int(json.get(f.*, "id")) orelse continue, file, json.int(json.get(f.*, "line")) orelse 0);
                // the runtime's frames: the client shows the first frame of
                // the program's sources
                if (file == null or !paths.isFile(s.io, file.?)) {
                    if (f.* == .object) try f.object.put(a, "presentationHint", .{ .string = "subtle" });
                    if (f.object.getPtr("source")) |src| if (src.* == .object) try src.object.put(a, "presentationHint", .{ .string = "deemphasize" });
                }
            }
            gdb.respondWith(s, a, req, r);
        },
        .scopes => {
            const r = try gdb.request(s, a, command, args orelse Value.null);
            if (gdb.isSuccess(r)) try scopes(s, a, json.int(json.get(args, "frameId")), r);
            gdb.respondWith(s, a, req, r);
        },
        .variables => {
            const ref = json.int(json.get(args, "variablesReference")) orelse 0;
            const node = vars.get(s, ref) orelse return s.respond(a, req, .{ .variables = &[_]u8{} });
            const shown = vars.children(s, a, ref, node) catch |e| return s.fail(a, req, if (e == error.GdbFailed) s.g.failure else @errorName(e));
            s.respond(a, req, .{ .variables = shown });
        },
        .evaluate => try evaluate(s, a, req, args),
        .setVariable => try setVariable(s, a, req, args),
        .disconnect, .terminate => {
            const r = try gdb.request(s, a, command, args orelse Value.null);
            gdb.respondWith(s, a, req, r);
            if (cmd == .disconnect) {
                s.g.ended = true;
                s.done = true;
            }
        },
    }
}

/// gdb's function breakpoints: the client's, then the runtime's error
/// functions when that filter is on
fn syncFunctions(s: *Session, a: Allocator) !Value {
    var list: json.Array = .init(a);
    const user = if (s.g.user_functions.len > 0) json.items(json.parse(a, s.g.user_functions) catch Value.null) else &.{};
    try list.appendSlice(user);
    const ours: []const []const u8 = if (s.g.runtime_errors) &fortran.runtime_error_functions else &.{};
    for (ours) |name| try list.append(try json.from(a, .{ .name = name }));
    const r = try gdb.request(s, a, "setFunctionBreakpoints", .{ .breakpoints = Value{ .array = list } });
    s.g.error_breakpoints.clearRetainingCapacity();
    const bps = json.items(json.path(r, &.{ "body", "breakpoints" }));
    for (ours, 0..) |name, i| {
        if (user.len + i >= bps.len) break;
        const id = json.int(json.get(bps[user.len + i], "id")) orelse continue;
        try s.g.error_breakpoints.put(s.gpa, id, name);
    }
    return r;
}

fn setExceptions(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    var all: std.ArrayList([]const u8) = .empty;
    var filters: json.Array = .init(a);
    var options: json.Array = .init(a);
    var wanted = false;
    for (json.items(json.get(args, "filters"))) |f| {
        const name = json.str(f) orelse continue;
        try all.append(a, name);
        if (std.mem.eql(u8, name, runtime_errors_filter)) wanted = true else try filters.append(f);
    }
    for (json.items(json.get(args, "filterOptions"))) |o| {
        const name = json.str(json.get(o, "filterId")) orelse "";
        try all.append(a, name);
        if (std.mem.eql(u8, name, runtime_errors_filter)) wanted = true else try options.append(o);
    }
    const r = try gdb.request(s, a, "setExceptionBreakpoints", .{ .filters = Value{ .array = filters }, .filterOptions = Value{ .array = options } });
    if (wanted != s.g.runtime_errors) {
        s.g.runtime_errors = wanted;
        _ = try syncFunctions(s, a);
    }
    if (!gdb.isSuccess(r)) return gdb.respondWith(s, a, req, r);
    const theirs = json.items(json.path(r, &.{ "body", "breakpoints" }));
    var next: usize = 0;
    var out: json.Array = .init(a);
    for (all.items) |f| {
        if (!std.mem.eql(u8, f, runtime_errors_filter) and next < theirs.len) {
            try out.append(theirs[next]);
            next += 1;
        } else try out.append(try json.from(a, .{ .verified = true }));
    }
    s.respond(a, req, .{ .breakpoints = Value{ .array = out } });
}

/// gdb's scopes of a frame, and the module variables its line sees
fn scopes(s: *Session, a: Allocator, frame: ?i64, r: Value) !void {
    const list = &(r.object.getPtr("body") orelse return).object.getPtr("scopes").?.array;
    for (list.items) |*sc| {
        if (sc.* != .object) continue;
        const ref = json.int(json.get(sc.*, "variablesReference")) orelse 0;
        if (ref != 0) {
            const registers = std.mem.eql(u8, json.str(json.get(sc.*, "presentationHint")) orelse "", "registers") or std.mem.eql(u8, json.str(json.get(sc.*, "name")) orelse "", "Registers");
            try sc.object.put(a, "variablesReference", .{ .integer = try vars.add(s, .{ .kind = .{ .gdb = ref }, .frame = frame, .ctx = .{ .registers = registers } }) });
        }
        _ = sc.object.orderedRemove("namedVariables");
        _ = sc.object.orderedRemove("indexedVariables");
    }
    const f = s.g.frames.get(frame orelse return) orelse return;
    const modvars = try moduleVariablesAt(s, a, f.file orelse return, f.line);
    if (modvars.len == 0) return;
    // after the frame's own: its locals, or its arguments when it has none
    var at: ?usize = null;
    for (list.items, 0..) |sc, i| {
        const hint = json.str(json.get(sc, "presentationHint")) orelse "";
        const name = json.str(json.get(sc, "name")) orelse "";
        if (std.mem.eql(u8, hint, "locals") or std.mem.eql(u8, name, "Locals") or std.mem.eql(u8, hint, "arguments") or std.mem.eql(u8, name, "Arguments")) at = i + 1;
    }
    try list.insert(at orelse @min(list.items.len, 2), try json.from(a, .{
        .name = s.text.module_variables,
        .variablesReference = try vars.add(s, .{ .kind = .{ .modules = modvars }, .frame = frame }),
        .expensive = false,
    }));
    // gdb's globals are those of the frame's file, the module variables among them
    for (list.items) |*sc| if (std.mem.eql(u8, json.str(json.get(sc.*, "name")) orelse "", "Globals")) try sc.object.put(a, "expensive", .{ .bool = true });
}

/// The module variables a line of a file sees, from zfls's index of the
/// sources (the launch's `sourceRoot`, else its `cwd`)
fn moduleVariablesAt(s: *Session, a: Allocator, file: []const u8, line: i64) ![]vars.ModuleVariable {
    if (!s.g.indexed) {
        s.g.indexed = true;
        if (s.g.source_root) |root| declarations.index(s, a, root);
    }
    const srv = s.server orelse return &.{};
    const items = srv.dispatchPublic(a, "zfls/moduleVariables", try json.from(a, .{
        .textDocument = .{ .uri = try paths.pathToUri(a, file) },
        .position = .{ .line = @max(line - 1, 0), .character = 0 },
    })) catch return &.{};
    var out: std.ArrayList(vars.ModuleVariable) = .empty;
    for (json.items(items)) |it| try out.append(a, .{
        .module = json.str(json.get(it, "module")) orelse continue,
        .name = json.str(json.get(it, "name")) orelse continue,
        .local = json.str(json.get(it, "local")) orelse json.str(json.get(it, "name")).?,
        .type = json.str(json.get(it, "type")) orelse "",
    });
    return out.items;
}

fn evaluate(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const expr = json.str(json.get(args, "expression")) orelse "";
    const frame = json.int(json.get(args, "frameId"));
    const context = json.str(json.get(args, "context")) orelse "";
    if (std.mem.eql(u8, context, "repl")) {
        const r = try gdb.request(s, a, "evaluate", args orelse Value.null);
        if (json.int(json.path(r, &.{ "body", "variablesReference" }))) |ref| if (ref != 0) {
            try r.object.getPtr("body").?.object.put(a, "variablesReference", .{ .integer = try vars.add(s, .{ .kind = .{ .gdb = ref }, .frame = frame }) });
        };
        return gdb.respondWith(s, a, req, r);
    }
    var forwarded: json.ObjectMap = .empty;
    if (args) |v| if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |kv| try forwarded.put(a, kv.key_ptr.*, kv.value_ptr.*);
    };
    const known = for ([_][]const u8{ "watch", "hover", "variables" }) |c| {
        if (std.mem.eql(u8, c, context)) break true;
    } else false;
    try forwarded.put(a, "context", .{ .string = if (known) context else "watch" });
    const r = try gdb.request(s, a, "evaluate", Value{ .object = forwarded });
    if (gdb.isSuccess(r)) if (r.object.getPtr("body")) |body| if (body.* == .object) {
        const shown = vars.present(s, a, .{
            .name = expr,
            .value = json.str(json.get(body.*, "result")) orelse "",
            .type = json.str(json.get(body.*, "type")),
            .ref = json.int(json.get(body.*, "variablesReference")) orelse 0,
            .memory_reference = json.str(json.get(body.*, "memoryReference")),
        }, expr, expr, frame, null, null) catch null;
        if (shown) |v| {
            try body.object.put(a, "result", .{ .string = v.value });
            if (v.type) |t| try body.object.put(a, "type", .{ .string = t }) else _ = body.object.orderedRemove("type");
            try body.object.put(a, "variablesReference", .{ .integer = v.ref });
        }
    };
    gdb.respondWith(s, a, req, r);
}

/// `setVariable`: by the variable's Fortran expression when it has one
/// (`a(2)`, `p%x`, `grid::ncells`), else by gdb's own
fn setVariable(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const ref = json.int(json.get(args, "variablesReference")) orelse 0;
    const name = json.str(json.get(args, "name")) orelse "";
    const node = vars.get(s, ref);
    const named: ?vars.Named = if (node) |n| for (n.names) |x| {
        if (std.mem.eql(u8, x.shown, name)) break x;
    } else null else null;
    const frame = if (node) |n| n.frame else null;
    if (named) |n| if (n.evaluate_name) |e| if (!std.mem.startsWith(u8, e, "$zfls_")) {
        var o: json.ObjectMap = .empty;
        try o.put(a, "expression", .{ .string = e });
        try o.put(a, "value", json.get(args, "value") orelse Value{ .string = "" });
        if (frame) |f| try o.put(a, "frameId", .{ .integer = f });
        const r = try gdb.request(s, a, "setExpression", Value{ .object = o });
        if (!gdb.isSuccess(r)) return s.fail(a, req, json.str(json.get(r, "message")) orelse "");
        const v = try vars.present(s, a, .{
            .name = name,
            .value = json.str(json.path(r, &.{ "body", "value" })) orelse "",
            .type = json.str(json.path(r, &.{ "body", "type" })),
            .ref = json.int(json.path(r, &.{ "body", "variablesReference" })) orelse 0,
        }, name, e, frame, null, null);
        return s.respond(a, req, .{ .value = v.value, .type = v.type, .variablesReference = v.ref });
    };
    if (node) |n| if (n.kind == .gdb) {
        var o: json.ObjectMap = .empty;
        if (args) |v| if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |kv| try o.put(a, kv.key_ptr.*, kv.value_ptr.*);
        };
        try o.put(a, "variablesReference", .{ .integer = n.kind.gdb });
        try o.put(a, "name", .{ .string = if (named) |x| x.gdb_name else name });
        return gdb.respondWith(s, a, req, try gdb.request(s, a, "setVariable", Value{ .object = o }));
    };
    s.fail(a, req, s.text.not_available);
}

/// An event of gdb, for the client
pub fn event(s: *Session, a: Allocator, msg: Value) void {
    const name = json.str(json.get(msg, "event")) orelse return;
    var body = json.get(msg, "body") orelse Value.null;
    if (std.mem.eql(u8, name, "stopped")) {
        vars.clear(s);
        var hit: ?[]const u8 = null;
        for (json.items(json.get(body, "hitBreakpointIds"))) |id| {
            if (s.g.error_breakpoints.get(json.int(id) orelse continue)) |f| {
                hit = f;
                break;
            }
        }
        s.g.last_error = hit;
        if (hit) |f| if (body == .object) {
            body.object.put(a, "reason", .{ .string = "exception" }) catch {};
            body.object.put(a, "description", .{ .string = if (fortran.isErrorStop(f)) s.text.error_stop else s.text.runtime_error }) catch {};
            body.object.put(a, "text", .{ .string = f }) catch {};
        };
    } else if (std.mem.eql(u8, name, "continued")) {
        vars.clear(s);
    } else if (std.mem.eql(u8, name, "breakpoint")) {
        // those of the runtime's errors are the adapter's own
        if (json.int(json.path(body, &.{ "breakpoint", "id" }))) |id| if (s.g.error_breakpoints.contains(id)) return;
    } else if (std.mem.eql(u8, name, "terminated") or std.mem.eql(u8, name, "exited")) {
        killTerminal(s);
    } else if (std.mem.eql(u8, name, "initialized")) {
        if (s.g.initialized_sent) return;
        s.g.initialized_sent = true;
    }
    s.event(a, name, body);
}

pub fn deinit(s: *Session) void {
    killTerminal(s);
}
