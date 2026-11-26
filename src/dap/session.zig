//! `zfls dap`: a debug adapter (Debug Adapter Protocol, on standard input
//! and output) of Fortran programs, over one of three debuggers, chosen at
//! `launch` or `attach`:
//!
//! - gdb (gdb.zig, gdb_requests.zig, gdb_variables.zig): `gdb -i=dap`,
//!   gdb 14 or later built with Python, whose own protocol zfls passes
//!   through and reshapes for Fortran (fortran.zig): the programs of
//!   gfortran, LLVM Flang and the others of DWARF's debug information. The
//!   gdb is the configuration's `gdb`, else `--gdb PATH`'s, else the
//!   PATH's. The default, but on macOS.
//! - lldb-dap (lldb.zig), LLVM's adapter, passed through as gdb's is, when
//!   the configuration says `lldb: true` or `lldb: PATH` (or `--lldb
//!   [PATH]`); the default on macOS. lldb reads no Fortran: the variables
//!   and expressions are lldb's own.
//! - Windows's Debugger Engine (dbgeng.zig), when the configuration says
//!   `dbgeng: true` (or `--dbgeng`), for programs with Microsoft's debug
//!   information: Intel's ifx and LLVM Flang's on Windows. Their variables
//!   are shown as Fortran: zfls indexes the program's sources (the launch
//!   configuration's `sourceRoot`, else `cwd`), and each variable's
//!   declaration says its type, kind and rank, while dbghelp says where it
//!   is; arrays are read through Intel's or LLVM Flang's descriptors. The
//!   program runs in a
//!   console of its own.
//!
//! gdb and the engine show a "Module variables" scope (the module variables that a
//! frame's line sees, by zfls's index of the sources) and a "Fortran
//! runtime errors" exception filter. `--text JSON` translates the words
//! they show (`Text`).
//!
//! One thread reads the client's messages (and interrupts a running program
//! for `pause`); this one handles them in order, with gdb's messages (which
//! threads of gdb.zig read), or waits for the engine's program between
//! them, as the engine wants all calls from the thread that made it.
//!
//! Here the session's state, its requests' dispatch and the engine's stops;
//! the engine's requests' parts are in breakpoints.zig, declarations.zig
//! (zfls's index of the sources), memory.zig (values in the program's
//! memory) and variables.zig (the protocol's variables).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const stdio = @import("../stdio.zig");
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
const Value = json.Value;

const is_windows = builtin.target.os.tag == .windows;
const Engine = if (is_windows) dbgeng.Engine else void;

const breakpoints = @import("breakpoints.zig");
const runtime_errors = @import("runtime_errors.zig");
const runtime_errors_filter = breakpoints.runtime_errors_filter;
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
const gdb_requests = @import("gdb_requests.zig");
const choice = @import("choice.zig");
const capabilities = @import("capabilities.zig");
const engine_conditions = @import("engine_conditions.zig");
const engine_data = @import("engine_data.zig");
const engine_completions = @import("engine_completions.zig");
const engine_set = @import("engine_set.zig");
const engine_functions = @import("engine_functions.zig");
const engine_inspect = @import("engine_inspect.zig");
const coarrays = @import("coarrays.zig");
const gdb_variables = @import("gdb_variables.zig");
const lldb = @import("lldb.zig");

/// The words the adapter shows, which `--text` translates (its keys:
/// `moduleVariables`, `notAllocated`, ...)
pub const Text = struct {
    module_variables: []const u8 = "Module variables",
    not_allocated: []const u8 = "not allocated",
    not_associated: []const u8 = "not associated",
    not_available: []const u8 = "not available",
    runtime_errors: []const u8 = "Fortran runtime errors",
    runtime_errors_description: []const u8 = "Stop where the Fortran runtime reports an error (bounds checking, allocation, I/O) or ERROR STOP",
    runtime_error: []const u8 = "Fortran runtime error",
    error_stop: []const u8 = "ERROR STOP",
    gdb_exited: []const u8 = "gdb exited",
    lldb_exited: []const u8 = "lldb-dap exited",
    ended_by_signal: []const u8 = "The program was ended by a signal",

    /// `--text`'s JSON object: its strings over the English ones
    fn parse(a: Allocator, text: []const u8) !Text {
        const v = try json.parse(a, text);
        var out: Text = .{};
        inline for (@typeInfo(Text).@"struct".field_names) |field| {
            const key = comptime camel(field);
            if (json.str(json.get(v, key))) |s| if (s.len > 0) {
                @field(out, field) = s;
            };
        }
        return out;
    }

    fn camel(comptime name: []const u8) []const u8 {
        comptime {
            var out: []const u8 = "";
            var upper = false;
            for (name) |c| {
                if (c == '_') {
                    upper = true;
                    continue;
                }
                out = out ++ &[_]u8{if (upper) std.ascii.toUpper(c) else c};
                upper = false;
            }
            return out;
        }
    }
};

const Queue = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// The client's requests and events
    items: std.ArrayList([]u8) = .empty,
    closed: bool = false,
    /// The client's answers to the adapter's requests (`runInTerminal`)
    responses: std.ArrayList([]u8) = .empty,
    /// gdb's messages (gdb.zig)
    gdb: std.ArrayList(gdb.Item) = .empty,
};

pub const Backend = enum { none, dbgeng, gdb, lldb };

/// The debugger unless the configuration names one: lldb-dap on macOS,
/// where gdb does not run on Apple silicon and must be code-signed on
/// Intel; gdb elsewhere
const default_backend: Backend = if (builtin.target.os.tag == .macos) .lldb else .gdb;

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    backend: Backend = .none,
    text: Text = .{},
    /// `--gdb`: the gdb unless the configuration names one
    gdb_path: []const u8 = "gdb",
    /// `--lldb PATH`: the lldb-dap unless the configuration names one
    lldb_path: ?[]const u8 = null,
    /// The debugger unless the configuration names one: `--gdb`'s or
    /// `--lldb`'s, else the platform's
    default: Backend = default_backend,
    /// `--dbgeng`: Windows's Debugger Engine whatever the configuration
    want_dbgeng: bool = false,
    /// The client's `initialize` arguments (JSON, `gpa`'s), for a gdb
    /// started at `launch`
    client_init: []u8 = "",
    /// Why the default debugger did not start at `initialize` (`gpa`'s)
    gdb_error: ?[]u8 = null,
    /// The capabilities another debugger gave the client at `initialize`
    /// (JSON, `gpa`'s), until the engine's replace them (capabilities.zig)
    given_capabilities: []u8 = "",
    /// The gdb backend's state (gdb.zig)
    g: gdb.State = .{},
    /// Windows's Debugger Engine, once `engine_ready`
    engine: Engine = undefined,
    engine_ready: std.atomic.Value(bool) = .init(false),
    queue: Queue = .{},
    out_mutex: Io.Mutex = .init,
    seq: i64 = 1,
    /// The program runs (between a resume and its stop)
    running: bool = false,
    launched: bool = false,
    done: bool = false,
    stop_at_entry: bool = false,
    /// The engine's step under way from a line it takes for another
    step_from: ?StepFrom = null,
    /// The breakpoints on the Fortran runtime's errors, each with its
    /// function
    error_breakpoints: std.ArrayList(runtime_errors.EngineBreakpoint) = .empty,
    /// The breakpoints whose lines had no code yet (a module not loaded):
    /// their lines, until they have
    unverified: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The client's function breakpoints: the engine's ids
    function_breakpoints: std.ArrayList(u32) = .empty,
    /// The client's data breakpoints: the engine's ids
    data_breakpoints: std.ArrayList(u32) = .empty,
    /// The breakpoints' conditions, hits ignored and log messages, by id
    /// (engine_conditions.zig)
    conditions: std.AutoHashMapUnmanaged(u32, engine_conditions.Condition) = .empty,
    last_error: []const u8 = "",
    /// The last stop was the filter's at a runtime error: the Intel
    /// runtime's break instruction that follows it is no stop of its own
    after_runtime_error: bool = false,
    attached: bool = false,
    /// Breakpoints by source file: the engine's ids
    breakpoints: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// zfls's index of the sources, for the declarations
    server: ?*server_mod.Server = null,
    log: Logger,
    /// What variable references stand for, until the program goes on
    nodes: std.ArrayList(Node) = .empty,
    nodes_arena: std.heap.ArenaAllocator,

    pub fn send(s: *Session, a: Allocator, msg: anytype) void {
        _ = s.sendSeq(a, msg);
    }

    /// Sends a message to the client: its seq
    pub fn sendSeq(s: *Session, a: Allocator, msg: anytype) i64 {
        var v = json.from(a, msg) catch return 0;
        if (v == .object) v.object.put(a, "seq", .{ .integer = 0 }) catch return 0;
        // a response's message is a string, or none (#737)
        if (v == .object) if (v.object.get("message")) |m| if (m == .null) {
            _ = v.object.orderedRemove("message");
        };
        s.out_mutex.lockUncancelable(s.io);
        defer s.out_mutex.unlock(s.io);
        const seq = s.seq;
        if (v == .object) v.object.put(a, "seq", .{ .integer = seq }) catch return 0;
        s.seq += 1;
        const body = json.stringify(a, v) catch return 0;
        const framed = jsonrpc.frame(a, body) catch return 0;
        stdio.stdout().writeStreamingAll(s.io, framed) catch {};
        return seq;
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

    pub fn event(s: *Session, a: Allocator, name: []const u8, body: anytype) void {
        s.send(a, .{ .type = "event", .event = name, .body = body });
    }

    pub fn output(s: *Session, a: Allocator, text: []const u8) void {
        s.event(a, "output", .{ .category = "console", .output = text });
    }

    /// The client's answer to the adapter's request `seq`, waiting for it
    /// up to `timeout`
    pub fn clientResponse(s: *Session, a: Allocator, seq: i64, timeout: Io.Duration) ?Value {
        const deadline = Io.Clock.awake.now(s.io).addDuration(timeout);
        s.queue.mutex.lockUncancelable(s.io);
        defer s.queue.mutex.unlock(s.io);
        while (true) {
            for (s.queue.responses.items, 0..) |body, i| {
                const r = json.parse(a, a.dupe(u8, body) catch return null) catch continue;
                if (json.int(json.get(r, "request_seq")) != seq) continue;
                s.gpa.free(s.queue.responses.orderedRemove(i));
                return r;
            }
            if (s.queue.closed) return null;
            s.queue.cond.waitTimeout(s.io, &s.queue.mutex, .{ .deadline = .{ .raw = deadline, .clock = .awake } }) catch return null;
        }
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
    /// A CLASS object's dynamic type's definition (LLVM Flang's), for its
    /// components' types in place of the declared type's
    dynamic: ?*const Obj = null,
    /// Not allocated, not associated
    empty: bool = false,
    /// The frame whose expression it is, for its children's (engine_set.zig)
    frame: Frame = .{ .thread = 0, .index = 0 },
};

/// Runs `zfls dap [--gdb PATH | --lldb [PATH]] [--dbgeng] [--text JSON]`:
/// its exit code
pub fn run(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var s: Session = .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .log = Logger.init(io),
        .nodes_arena = .init(gpa),
    };
    // the options' text lasts the session
    var options_arena: std.heap.ArenaAllocator = .init(gpa);
    defer options_arena.deinit();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dbgeng")) {
            s.want_dbgeng = true;
        } else if (std.mem.eql(u8, arg, "--gdb") and i + 1 < args.len) {
            i += 1;
            s.gdb_path = args[i];
            s.default = .gdb;
        } else if (std.mem.eql(u8, arg, "--lldb")) {
            s.default = .lldb;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                s.lldb_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--text") and i + 1 < args.len) {
            i += 1;
            s.text = Text.parse(options_arena.allocator(), args[i]) catch {
                try stdio.stderr().writeStreamingAll(io, "zfls dap: --text needs a JSON object\n");
                return 2;
            };
        } else {
            try stdio.stderr().writeStreamingAll(io, "usage: zfls dap [--gdb PATH | --lldb [PATH]] [--dbgeng] [--text JSON]\n");
            return 2;
        }
    }
    s.log.stderr_level = .off;
    defer if (is_windows) if (s.engine_ready.load(.acquire)) s.engine.deinit();
    defer s.nodes_arena.deinit();
    defer if (s.server) |srv| srv.destroy();
    defer {
        gdb_requests.deinit(&s);
        gdb.deinit(&s);
        if (s.client_init.len > 0) gpa.free(s.client_init);
        if (s.gdb_error) |e| gpa.free(e);
        if (s.given_capabilities.len > 0) gpa.free(s.given_capabilities);
        var it = s.breakpoints.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            kv.value_ptr.deinit(gpa);
        }
        s.breakpoints.deinit(gpa);
        s.error_breakpoints.deinit(gpa);
        s.unverified.deinit(gpa);
        s.function_breakpoints.deinit(gpa);
        s.data_breakpoints.deinit(gpa);
        var cit = s.conditions.valueIterator();
        while (cit.next()) |c| c.deinit(gpa);
        s.conditions.deinit(gpa);
        s.nodes.deinit(gpa);
        s.queue.mutex.lockUncancelable(io);
        for (s.queue.items.items) |b| gpa.free(b);
        s.queue.items.deinit(gpa);
        for (s.queue.responses.items) |b| gpa.free(b);
        s.queue.responses.deinit(gpa);
        for (s.queue.gdb.items) |item| if (item.body) |b| gpa.free(b);
        s.queue.gdb.deinit(gpa);
        s.queue.mutex.unlock(io);
    }

    const reader = try std.Thread.spawn(.{}, readRequests, .{&s});
    reader.detach();

    while (!s.done) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        switch (take(&s, if (s.running) 0 else 200)) {
            .client => |body| {
                defer gpa.free(body);
                gdb_variables.freeRetired(&s);
                const req = json.parse(a, body) catch continue;
                if (!std.mem.eql(u8, json.str(json.get(req, "type")) orelse "", "request")) continue;
                handle(&s, a, req) catch |e| s.fail(a, req, @errorName(e));
            },
            .gdb => |item| gdb.received(&s, a, item),
            .none => {
                if (s.queue.closed and s.queue.items.items.len == 0) break;
                // a `launch` the debugger does not answer (#374)
                if (s.backend == .gdb or s.backend == .lldb) gdb.expireRelays(&s, a);
                if (is_windows and s.running) {
                    const stop = s.engine.wait(a, 100) catch continue;
                    if (stop != .running) stopped(&s, a, stop);
                }
            },
        }
    }
    if (s.backend == .gdb or s.backend == .lldb) {
        _ = arena.reset(.retain_capacity);
        gdb.finish(&s, arena.allocator());
    }
    return 0;
}

fn readRequests(s: *Session) void {
    var buf: [64 * 1024]u8 = undefined;
    var reader = stdio.stdin().readerStreaming(s.io, &buf);
    // the session may end while this thread still waits for the client:
    // not `gpa`'s, whose leaks are counted at the end
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const body = (jsonrpc.readMessage(&reader.interface, s.gpa) catch null) orelse break;
        // a pause cannot wait for the engine's thread, which waits for the program
        if (is_windows and s.engine_ready.load(.acquire) and std.mem.find(u8, body, "\"pause\"") != null) s.engine.interrupt();
        const msg = json.parse(arena.allocator(), body) catch Value.null;
        const response = std.mem.eql(u8, json.str(json.get(msg, "type")) orelse "", "response");
        s.queue.mutex.lockUncancelable(s.io);
        (if (response) &s.queue.responses else &s.queue.items).append(s.gpa, body) catch {};
        s.queue.cond.broadcast(s.io);
        s.queue.mutex.unlock(s.io);
    }
    s.queue.mutex.lockUncancelable(s.io);
    s.queue.closed = true;
    s.queue.cond.broadcast(s.io);
    s.queue.mutex.unlock(s.io);
}

const Incoming = union(enum) { none, client: []u8, gdb: gdb.Item };

/// The next message: gdb's first, then the client's; waiting up to `ms`
fn take(s: *Session, ms: i64) Incoming {
    s.queue.mutex.lockUncancelable(s.io);
    defer s.queue.mutex.unlock(s.io);
    if (s.queue.items.items.len == 0 and s.queue.gdb.items.len == 0 and ms > 0 and !s.queue.closed) {
        const t: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
        s.queue.cond.waitTimeout(s.io, &s.queue.mutex, t.toDeadline(s.io)) catch {};
    }
    while (s.queue.gdb.items.len > 0) {
        const item = s.queue.gdb.orderedRemove(0);
        if (item.gen == s.g.gen) return .{ .gdb = item };
        if (item.body) |b| s.gpa.free(b);
    }
    if (s.queue.items.items.len == 0) return .none;
    return .{ .client = s.queue.items.orderedRemove(0) };
}

fn handle(s: *Session, a: Allocator, req: Value) !void {
    const command = json.str(json.get(req, "command")) orelse return;
    const args = json.get(req, "arguments");
    if (std.mem.eql(u8, command, "initialize")) return initialize(s, a, req, args);
    if (std.mem.eql(u8, command, "launch") or std.mem.eql(u8, command, "attach")) {
        if (s.want_dbgeng or flag(args, "dbgeng") or choice.engineFits(s, a, args)) {
            if (!is_windows) return s.fail(a, req, "dbgeng: Windows's Debugger Engine is only on Windows");
            gdb.stop(s);
            if (!s.engine_ready.load(.acquire)) {
                s.engine = Engine.init() catch return s.fail(a, req, "zfls dap: the Debugger Engine of Windows (dbgeng.dll) is not available");
                s.engine_ready.store(true, .release);
            }
            s.backend = .dbgeng;
            try capabilities.toEngine(s, a);
            return handleEngine(s, a, req);
        }
        // the configuration's debugger, when another than the one started
        const want = chosen(s, args);
        const lldb_wanted = want.backend == .lldb;
        const other = if (want.path) |p| !std.mem.eql(u8, p, s.g.path) else false;
        if (s.g.child == null or s.g.exit_message != null or s.g.lldb != lldb_wanted or other) {
            if (want.path == null and want.backend == s.default) if (s.gdb_error) |why| return s.fail(a, req, why);
            const why = if (lldb_wanted) try lldb.start(s, a, want.path orelse s.lldb_path) else try gdb.start(s, a, want.path orelse s.gdb_path);
            if (why) |w| return s.fail(a, req, w);
            try gdb_requests.initializeAgain(s, a);
        }
        s.backend = want.backend;
        if (std.mem.eql(u8, command, "launch")) coarrays.noteImages(s, a, args);
        return if (lldb_wanted) lldb.launch(s, a, req, args) else gdb_requests.launch(s, a, req, args);
    }
    switch (s.backend) {
        .gdb, .lldb => return gdb_requests.handle(s, a, req),
        .dbgeng => if (is_windows) return handleEngine(s, a, req),
        .none => {},
    }
    if (std.mem.eql(u8, command, "disconnect")) {
        s.respond(a, req, null);
        s.done = true;
    } else s.fail(a, req, "not supported before launch or attach");
}

/// The debugger of a configuration: `lldb: true` or `lldb: PATH`, `gdb:
/// PATH`, else the default; `lldb: false` is gdb
fn chosen(s: *Session, args: ?Value) struct { backend: Backend, path: ?[]const u8 = null } {
    if (json.get(args, "lldb")) |v| switch (v) {
        .bool => |b| if (b) return .{ .backend = .lldb } else if (json.str(json.get(args, "gdb")) == null) return .{ .backend = .gdb },
        .string => |p| return .{ .backend = .lldb, .path = if (p.len > 0) p else null },
        else => {},
    };
    if (json.str(json.get(args, "gdb"))) |g| if (g.len > 0) return .{ .backend = .gdb, .path = g };
    return .{ .backend = s.default };
}

/// `initialize`: the default debugger's capabilities, its own (gdb's,
/// lldb-dap's), unless the engine is to be used; else the engine's, on
/// Windows, where the configuration may still want it
fn initialize(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    if (s.client_init.len > 0) s.gpa.free(s.client_init);
    s.client_init = try s.gpa.dupe(u8, try json.stringify(a, args orelse Value.null));
    s.g.run_in_terminal = flag(args, "supportsRunInTerminalRequest");
    if (!(is_windows and s.want_dbgeng)) {
        const started = if (s.default == .lldb) try lldb.start(s, a, s.lldb_path) else try gdb.start(s, a, s.gdb_path);
        const why = started orelse {
            s.backend = s.default;
            return gdb_requests.initialize(s, a, req, args);
        };
        if (!is_windows) return s.fail(a, req, why);
        s.gdb_error = try s.gpa.dupe(u8, why);
    }
    s.respond(a, req, capabilities.engine(s));
}

/// The engine's requests
fn handleEngine(s: *Session, a: Allocator, req: Value) !void {
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
            const pid = json.int(json.get(args, "processId")) orelse return s.fail(a, req, "no processId");
            s.engine.attach(@intCast(pid)) catch return s.fail(a, req, "could not attach");
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
            try go(s, .go, null);
        },
        .next, .stepIn, .stepOut => {
            const thread: ?u32 = if (json.int(json.get(args, "threadId"))) |t| @intCast(t) else null;
            s.respond(a, req, null);
            s.step_from = if (cmd == .stepOut) null else stepFrom(s, a, cmd == .stepIn, thread);
            try go(s, switch (cmd) {
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

fn go(s: *Session, how: Engine.Resume, thread: ?u32) !void {
    if (how == .go or how == .out) s.step_from = null;
    s.nodes.clearRetainingCapacity();
    _ = s.nodes_arena.reset(.retain_capacity);
    try s.engine.resumeThread(how, thread);
    s.running = true;
}

fn stopped(s: *Session, a: Allocator, stop: dbgeng.Stop) void {
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
