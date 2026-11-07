//! gdb for `zfls dap`: `gdb -i=dap` (gdb 14 or later, built with Python),
//! whose Debug Adapter Protocol the gdb backend (gdb_requests.zig) passes
//! through and reshapes. Here gdb's process: whether a gdb has the
//! protocol, its environment, starting and stopping it, and its messages.
//! Two threads read gdb's output and its errors; gdb's messages wait in
//! the session's queue for the session's thread, which handles them in
//! order: while a request waits for gdb's answer (`request`), the events
//! and the answers to other requests that come first are handled too, and
//! the client's next requests wait.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const jsonrpc = @import("../jsonrpc.zig");
const fortran = @import("fortran.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const gdb_requests = @import("gdb_requests.zig");
const gdb_variables = @import("gdb_variables.zig");

/// The state of the gdb backend
pub const State = struct {
    child: ?std.process.Child = null,
    /// The gdb running (`gpa`'s)
    path: []u8 = "",
    /// Its messages' generation in the queue: those of a gdb stopped are
    /// left out
    gen: u32 = 0,
    seq: i64 = 1,
    /// gdb has exited, or did not start: why (`gpa`'s)
    exit_message: ?[]u8 = null,
    /// The end of what gdb wrote to its standard error (under the queue's
    /// mutex)
    stderr: std.ArrayList(u8) = .empty,
    stderr_done: bool = false,
    /// The client's requests that gdb answers when it will (`launch` waits
    /// for `configurationDone`): its answer goes to the client as it comes
    relays: std.AutoHashMapUnmanaged(i64, Relay) = .empty,
    /// gdb's `initialized` event went to the client (a second gdb's is
    /// left out)
    initialized_sent: bool = false,
    /// gdb runs the program at `launch` (before gdb 16), where the client's
    /// breakpoints are still to come: the adapter holds the `launch` back
    /// until `configurationDone`, as gdb 16 does
    runs_at_launch: bool = false,
    /// The `launch` held: the client's request (JSON text, `gpa`'s)
    held_launch: ?[]u8 = null,
    /// The session is ending (`disconnect`): gdb's exit is not news
    ended: bool = false,
    /// In place of gdb, for tests: its answers to requests
    fake: ?Fake = null,
    /// gdb's message of the last request that failed (the request's)
    failure: []const u8 = "",

    /// The variable references, until the program goes on
    nodes: std.ArrayList(gdb_variables.Node) = .empty,
    /// The reference of `nodes[0]`, less one
    node_base: i64 = 0,
    nodes_arena: ?std.heap.ArenaAllocator = null,
    /// Arenas of nodes cleared while a request still used them: freed
    /// before the next request
    retired: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    /// The frames of the last stack traces: their file and line
    frames: std.AutoHashMapUnmanaged(i64, gdb_variables.FrameInfo) = .empty,
    /// The convenience variables made (`$zfls_1`)
    convenience: u32 = 0,

    /// The client's function breakpoints (its `breakpoints`, JSON text,
    /// `gpa`'s), and whether the runtime's errors stop the program
    user_functions: []u8 = "",
    runtime_errors: bool = false,
    /// gdb's ids of the breakpoints on the runtime's error functions
    error_breakpoints: std.AutoHashMapUnmanaged(i64, []const u8) = .empty,
    last_error: ?[]const u8 = null,
    /// The client supports `runInTerminal`
    run_in_terminal: bool = false,
    /// The shell of the program's terminal (not Windows)
    terminal_pid: ?i64 = null,
    /// The sources to index for the module variables (`gpa`'s), and
    /// whether that is done
    source_root: ?[]u8 = null,
    indexed: bool = false,
};

const Relay = struct { seq: i64, command: []u8 };

pub const Fake = struct {
    ctx: *anyopaque,
    answer: *const fn (ctx: *anyopaque, a: Allocator, command: []const u8, args: Value) anyerror!Value,
};

/// Whether a gdb has the Debug Adapter Protocol (gdb 14 or later, built
/// with Python): null when it has, else why not. Notes whether it runs the
/// program at `launch`.
pub fn checkDap(s: *Session, a: Allocator, gdb: []const u8) !?[]const u8 {
    const env = try gdbEnv(a, s.environ, gdb);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };
    const version = std.process.run(a, s.io, .{ .argv = &.{ gdb, "--version" }, .environ_map = env, .timeout = timeout }) catch |e|
        return try a.print("{s}: {s}; zfls dap debugs with gdb 14 or later, built with Python (--gdb PATH, or `gdb` in the launch configuration)", .{ gdb, @errorName(e) });
    const first = std.mem.trimEnd(u8, version.stdout[0 .. std.mem.findScalar(u8, version.stdout, '\n') orelse version.stdout.len], "\r");
    const v = fortran.gdbVersion(version.stdout) orelse [2]u32{ 0, 0 };
    if (v[0] < 14) return try a.print("{s} ({s}) has no Debug Adapter Protocol: zfls dap needs gdb 14 or later, built with Python", .{ gdb, first });
    // the modules its DAP needs, which another Python's library lacks
    const check = std.process.run(a, s.io, .{
        .argv = &.{ gdb, "-nx", "-q", "-batch", "-ex", "python import json, struct, threading; print(6*7)" },
        .environ_map = env,
        .timeout = timeout,
    }) catch |e| return try a.print("{s}: {s}", .{ gdb, @errorName(e) });
    if (!std.mem.eql(u8, std.mem.trim(u8, check.stdout, " \t\r\n"), "42"))
        return try a.print("{s} ({s}) has no working Python, which its Debug Adapter Protocol needs: {s}", .{ gdb, first, std.mem.trim(u8, check.stderr, " \t\r\n") });
    s.g.runs_at_launch = v[0] < 16;
    return null;
}

/// gdb's environment: its own directory first on the PATH. gdb's Python
/// finds its library by the `python3` on the PATH, and another one there
/// first (a virtual environment, conda, pyenv, CI's) breaks it ("No module
/// named '_struct'"); next to gdb is the one it was built with.
pub fn gdbEnv(a: Allocator, base: *const std.process.Environ.Map, gdb: []const u8) !*std.process.Environ.Map {
    const env = try a.create(std.process.Environ.Map);
    env.* = try base.clone(a);
    if (!std.Io.Dir.path.isAbsolute(gdb)) return env;
    const dir = std.Io.Dir.path.dirname(gdb) orelse return env;
    const current = env.get("PATH") orelse "";
    try env.put("PATH", if (current.len > 0) try a.print("{s}{c}{s}", .{ dir, std.Io.Dir.path.delimiter, current }) else dir);
    return env;
}

/// Starts gdb: null, or why it did not start
pub fn start(s: *Session, a: Allocator, gdb: []const u8) !?[]const u8 {
    stop(s);
    if (try checkDap(s, a, gdb)) |why| return why;
    var child = std.process.spawn(s.io, .{
        .argv = &.{ gdb, "-q", "-i=dap" },
        .environ_map = try gdbEnv(a, s.environ, gdb),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |e| return try a.print("{s}: {s}", .{ gdb, @errorName(e) });
    // the readers own gdb's output: a program that gdb started may keep it
    // open after gdb has gone
    const out = child.stdout.?;
    const err = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    s.queue.mutex.lockUncancelable(s.io);
    s.g.gen += 1;
    const gen = s.g.gen;
    s.g.stderr.clearRetainingCapacity();
    s.g.stderr_done = false;
    s.queue.mutex.unlock(s.io);
    s.g.child = child;
    s.g.path = try s.gpa.dupe(u8, gdb);
    if (s.g.exit_message) |m| s.gpa.free(m);
    s.g.exit_message = null;
    (try std.Thread.spawn(.{}, readOutput, .{ s, out, gen })).detach();
    (try std.Thread.spawn(.{}, readErrors, .{ s, err, gen })).detach();
    return null;
}

/// Stops gdb, if it runs
pub fn stop(s: *Session) void {
    if (s.g.child) |*c| {
        c.kill(s.io);
        s.g.child = null;
    }
    if (s.g.path.len > 0) s.gpa.free(s.g.path);
    s.g.path = "";
    s.queue.mutex.lockUncancelable(s.io);
    s.g.gen += 1;
    s.queue.mutex.unlock(s.io);
    var it = s.g.relays.valueIterator();
    while (it.next()) |r| s.gpa.free(r.command);
    s.g.relays.clearRetainingCapacity();
    if (s.g.held_launch) |h| s.gpa.free(h);
    s.g.held_launch = null;
}

/// After `disconnect`: gdb's own end, for a moment, then its stop
pub fn finish(s: *Session, a: Allocator) void {
    if (s.g.child == null) return stop(s);
    const deadline = Io.Clock.awake.now(s.io).addDuration(.fromSeconds(2));
    while (s.g.exit_message == null) {
        const item = takeGdb(s, deadline) orelse break;
        received(s, a, item);
    }
    stop(s);
}

fn readOutput(s: *Session, file: Io.File, gen: u32) void {
    defer file.close(s.io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(s.io, &buf);
    while (true) {
        const body = (jsonrpc.readMessage(&reader.interface, s.gpa) catch null) orelse break;
        push(s, gen, body);
    }
    push(s, gen, null);
}

fn push(s: *Session, gen: u32, body: ?[]u8) void {
    s.queue.mutex.lockUncancelable(s.io);
    defer s.queue.mutex.unlock(s.io);
    if (gen != s.g.gen) {
        if (body) |b| s.gpa.free(b);
        return;
    }
    s.queue.gdb.append(s.gpa, .{ .gen = gen, .body = body }) catch {};
    s.queue.cond.broadcast(s.io);
}

fn readErrors(s: *Session, file: Io.File, gen: u32) void {
    defer file.close(s.io);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(s.io, &.{&buf}) catch break;
        if (n == 0) continue;
        Io.File.stderr().writeStreamingAll(s.io, buf[0..n]) catch {};
        s.queue.mutex.lockUncancelable(s.io);
        defer s.queue.mutex.unlock(s.io);
        if (gen != s.g.gen) continue;
        s.g.stderr.appendSlice(s.gpa, buf[0..n]) catch {};
        // its end only
        if (s.g.stderr.items.len > 4000) {
            const drop = s.g.stderr.items.len - 4000;
            @memmove(s.g.stderr.items[0..4000], s.g.stderr.items[drop..]);
            s.g.stderr.shrinkRetainingCapacity(4000);
        }
    }
    s.queue.mutex.lockUncancelable(s.io);
    defer s.queue.mutex.unlock(s.io);
    if (gen == s.g.gen) s.g.stderr_done = true;
    s.queue.cond.broadcast(s.io);
}

pub const Item = struct {
    gen: u32,
    /// null: gdb's output ended
    body: ?[]u8,
};

/// gdb's next message, waiting until `deadline` (or for ever); null at
/// the deadline
fn takeGdb(s: *Session, deadline: ?Io.Timestamp) ?Item {
    s.queue.mutex.lockUncancelable(s.io);
    defer s.queue.mutex.unlock(s.io);
    while (true) {
        while (s.queue.gdb.items.len > 0) {
            const item = s.queue.gdb.orderedRemove(0);
            if (item.gen == s.g.gen) return item;
            if (item.body) |b| s.gpa.free(b);
        }
        if (deadline) |d| {
            s.queue.cond.waitTimeout(s.io, &s.queue.mutex, .{ .deadline = .{ .raw = d, .clock = .awake } }) catch return null;
        } else s.queue.cond.waitUncancelable(s.io, &s.queue.mutex);
    }
}

/// A message of gdb that no request waits for: an event, an answer to
/// relay, or gdb's end
pub fn received(s: *Session, a: Allocator, item: Item) void {
    const body = item.body orelse return exited(s, a);
    const msg = parseOwned(s, a, body) orelse return;
    handleMessage(s, a, msg);
}

fn handleMessage(s: *Session, a: Allocator, msg: Value) void {
    const kind = json.str(json.get(msg, "type")) orelse return;
    if (std.mem.eql(u8, kind, "event")) return gdb_requests.event(s, a, msg);
    if (std.mem.eql(u8, kind, "response")) relay(s, a, msg);
}

/// A message of gdb (`gpa`'s, freed) parsed into `a`
fn parseOwned(s: *Session, a: Allocator, body: []u8) ?Value {
    defer s.gpa.free(body);
    return json.parse(a, a.dupe(u8, body) catch return null) catch null;
}

fn relay(s: *Session, a: Allocator, msg: Value) void {
    const kv = s.g.relays.fetchRemove(json.int(json.get(msg, "request_seq")) orelse return) orelse return;
    defer s.gpa.free(kv.value.command);
    s.send(a, .{
        .type = "response",
        .request_seq = kv.value.seq,
        .command = kv.value.command,
        .success = isSuccess(msg),
        .message = json.get(msg, "message") orelse Value.null,
        .body = json.get(msg, "body") orelse Value.null,
    });
}

/// gdb has exited: why, and the end of the session unless it was ending
fn exited(s: *Session, a: Allocator) void {
    if (s.g.exit_message != null) return;
    // what gdb said before it ended
    const deadline = Io.Clock.awake.now(s.io).addDuration(.fromSeconds(1));
    s.queue.mutex.lockUncancelable(s.io);
    while (!s.g.stderr_done) s.queue.cond.waitTimeout(s.io, &s.queue.mutex, .{ .deadline = .{ .raw = deadline, .clock = .awake } }) catch break;
    const said = a.dupe(u8, std.mem.trim(u8, s.g.stderr.items, " \t\r\n")) catch "";
    s.queue.mutex.unlock(s.io);
    var code: []const u8 = "?";
    if (s.g.child) |*c| {
        if (c.wait(s.io)) |term| switch (term) {
            .exited => |n| code = a.print("{d}", .{n}) catch "?",
            else => {},
        } else |_| {}
        s.g.child = null;
    }
    const tail = said[said.len -| 1000..];
    const message = (if (tail.len > 0)
        a.print("{s} ({s}): {s}", .{ s.text.gdb_exited, code, tail })
    else
        a.print("{s} ({s})", .{ s.text.gdb_exited, code })) catch return;
    s.g.exit_message = s.gpa.dupe(u8, message) catch return;
    // the answers awaited: none will come
    var it = s.g.relays.iterator();
    while (it.next()) |kv| {
        s.send(a, .{ .type = "response", .request_seq = kv.value_ptr.seq, .command = kv.value_ptr.command, .success = false, .message = message });
        s.gpa.free(kv.value_ptr.command);
    }
    s.g.relays.clearRetainingCapacity();
    if (!s.g.ended) {
        s.g.ended = true;
        if (!std.mem.eql(u8, code, "0")) s.event(a, "output", .{ .category = "stderr", .output = a.print("{s}\n", .{message}) catch message });
        s.event(a, "terminated", null);
    }
}

/// A failed answer, as gdb would give it
fn failure(a: Allocator, command: []const u8, message: []const u8) !Value {
    return json.from(a, .{ .type = "response", .request_seq = 0, .command = command, .success = false, .message = message });
}

fn write(s: *Session, a: Allocator, seq: i64, command: []const u8, args: ?Value) bool {
    const c = if (s.g.child) |*c| c else return false;
    // gdb takes its arguments as Python's keyword arguments: an object
    const arguments: Value = if (args) |v| if (v == .object) v else .{ .object = .empty } else .{ .object = .empty };
    const body = json.stringify(a, json.from(a, .{ .seq = seq, .type = "request", .command = command, .arguments = arguments }) catch return false) catch return false;
    const framed = a.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch return false;
    c.stdin.?.writeStreamingAll(s.io, framed) catch return false;
    return true;
}

/// Sends a request to gdb: its answer (a failed one when gdb is gone)
pub fn request(s: *Session, a: Allocator, command: []const u8, args: anytype) !Value {
    const v: Value = if (@TypeOf(args) == Value) args else try json.from(a, args);
    if (s.g.fake) |f| return f.answer(f.ctx, a, command, v);
    if (s.g.exit_message) |m| return failure(a, command, m);
    const seq = s.g.seq;
    s.g.seq += 1;
    if (!write(s, a, seq, command, v)) return failure(a, command, s.text.gdb_exited);
    while (true) {
        const item = takeGdb(s, null).?;
        const body = item.body orelse {
            exited(s, a);
            return failure(a, command, s.g.exit_message orelse s.text.gdb_exited);
        };
        const msg = parseOwned(s, a, body) orelse continue;
        if (std.mem.eql(u8, json.str(json.get(msg, "type")) orelse "", "response") and json.int(json.get(msg, "request_seq")) == seq) return msg;
        handleMessage(s, a, msg);
    }
}

/// Passes the client's request to gdb, whose answer goes back to the
/// client when it comes
pub fn forward(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const command = json.str(json.get(req, "command")) orelse return;
    if (s.g.fake != null or s.g.exit_message != null) {
        const r = try request(s, a, command, args orelse Value{ .object = .empty });
        return respondWith(s, a, req, r);
    }
    const seq = s.g.seq;
    s.g.seq += 1;
    try s.g.relays.put(s.gpa, seq, .{ .seq = json.int(json.get(req, "seq")) orelse 0, .command = try s.gpa.dupe(u8, command) });
    if (!write(s, a, seq, command, args)) {
        const kv = s.g.relays.fetchRemove(seq).?;
        s.gpa.free(kv.value.command);
        s.fail(a, req, s.text.gdb_exited);
    }
}

/// Answers the client's request with gdb's answer
pub fn respondWith(s: *Session, a: Allocator, req: Value, r: Value) void {
    s.send(a, .{
        .type = "response",
        .request_seq = json.int(json.get(req, "seq")) orelse 0,
        .command = json.str(json.get(req, "command")) orelse "",
        .success = isSuccess(r),
        .message = json.get(r, "message") orelse Value.null,
        .body = json.get(r, "body") orelse Value.null,
    });
}

pub fn isSuccess(r: Value) bool {
    const v = json.get(r, "success") orelse return false;
    return v == .bool and v.bool;
}

pub fn deinit(s: *Session) void {
    stop(s);
    s.g.relays.deinit(s.gpa);
    s.g.stderr.deinit(s.gpa);
    if (s.g.exit_message) |m| s.gpa.free(m);
    if (s.g.user_functions.len > 0) s.gpa.free(s.g.user_functions);
    if (s.g.source_root) |r| s.gpa.free(r);
    if (s.g.held_launch) |h| s.gpa.free(h);
    s.g.error_breakpoints.deinit(s.gpa);
    s.g.frames.deinit(s.gpa);
    s.g.nodes.deinit(s.gpa);
    if (s.g.nodes_arena) |*n| n.deinit();
    for (s.g.retired.items) |*r| r.deinit();
    s.g.retired.deinit(s.gpa);
}

test "gdb's environment: its own directory first on its PATH, for its Python" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base: std.process.Environ.Map = .init(a);
    try base.put("PATH", "x");
    try base.put("HOME", "h");
    const gdb = if (builtin.target.os.tag == .windows) "C:\\gdb\\bin\\gdb.exe" else "/opt/gdb/bin/gdb";
    const env = try gdbEnv(a, &base, gdb);
    try std.testing.expectEqualStrings(try a.print("{s}{c}x", .{ std.Io.Dir.path.dirname(gdb).?, std.Io.Dir.path.delimiter }), env.get("PATH").?);
    try std.testing.expectEqualStrings("h", env.get("HOME").?);
    // a bare name: the PATH as it is
    try std.testing.expectEqualStrings("x", (try gdbEnv(a, &base, "gdb")).get("PATH").?);
}
