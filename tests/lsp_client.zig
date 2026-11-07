//! A language server process driven over stdio, for the benchmark
//! (tools/bench_workspace.zig) and the stress test (tests/stress_edit.zig).
//! A thread reads the server's messages, so that the server never blocks on
//! a full pipe while the client is sending, and keeps the responses and the
//! latest diagnostics of each document; another collects its stderr.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const jsonrpc = @import("zfls").jsonrpc;

pub const Client = struct {
    io: Io,
    /// Thread-safe
    gpa: Allocator,
    child: std.process.Child,
    /// Messages received, valid until `deinit` (under `mutex`)
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    responses: std.AutoHashMapUnmanaged(i64, Value) = .empty,
    /// The latest diagnostics published for each URI
    diagnostics: std.StringHashMapUnmanaged(Value) = .empty,
    /// The server's output ended
    closed: bool = false,
    /// What the server wrote to stderr (complete once it exited)
    stderr: std.ArrayList(u8) = .empty,
    /// Every message sent, framed, when set
    log: ?Io.File = null,
    next_id: i64 = 100,
    /// How long a request waits for its response
    timeout: Io.Duration = .fromSeconds(120),
    out_thread: ?std.Thread = null,
    err_thread: ?std.Thread = null,

    /// Starts the server `argv`; `log_path` receives the messages sent
    pub fn start(io: Io, gpa: Allocator, argv: []const []const u8, log_path: ?[]const u8) !*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{
            .io = io,
            .gpa = gpa,
            .arena = .init(gpa),
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
                .create_no_window = true,
            }),
        };
        if (log_path) |p| c.log = try Io.Dir.cwd().createFile(io, p, .{});
        c.out_thread = try std.Thread.spawn(.{}, readOutput, .{c});
        c.err_thread = try std.Thread.spawn(.{}, readStderr, .{c});
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.join();
        if (c.log) |f| f.close(c.io);
        c.stderr.deinit(c.gpa);
        c.responses.deinit(c.gpa);
        c.diagnostics.deinit(c.gpa);
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    fn join(c: *Client) void {
        if (c.out_thread) |t| t.join();
        if (c.err_thread) |t| t.join();
        c.out_thread = null;
        c.err_thread = null;
    }

    fn readOutput(c: *Client) void {
        var buf: [64 * 1024]u8 = undefined;
        var reader = c.child.stdout.?.reader(c.io, &buf);
        while (true) {
            const body = (jsonrpc.readMessage(&reader.interface, c.gpa) catch null) orelse break;
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

    /// Keeps a response or published diagnostics (under `mutex`)
    fn keep(c: *Client, body: []const u8) !void {
        const a = c.arena.allocator();
        const msg = try std.json.parseFromSliceLeaky(Value, a, body, .{});
        if (msg != .object) return;
        const m = msg.object;
        if (m.get("method")) |method| {
            if (method != .string or !std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) return;
            const params = m.get("params") orelse return;
            if (params != .object) return;
            const uri = params.object.get("uri") orelse return;
            if (uri != .string) return;
            try c.diagnostics.put(c.gpa, uri.string, params.object.get("diagnostics") orelse .null);
            return;
        }
        const id = m.get("id") orelse return;
        if (id != .integer or (m.get("result") == null and m.get("error") == null)) return;
        try c.responses.put(c.gpa, id.integer, msg);
    }

    fn readStderr(c: *Client) void {
        var buf: [4096]u8 = undefined;
        var reader = c.child.stderr.?.reader(c.io, &buf);
        reader.interface.appendRemainingUnlimited(c.gpa, &c.stderr) catch {};
    }

    /// A notification (`id` null) or request; `params` null leaves them out
    pub fn send(c: *Client, method: []const u8, params: anytype, id: ?i64) !void {
        const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
        const body = if (@TypeOf(params) == @TypeOf(null))
            try std.json.Stringify.valueAlloc(c.gpa, .{ .jsonrpc = "2.0", .id = id, .method = method }, opts)
        else
            try std.json.Stringify.valueAlloc(c.gpa, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, opts);
        defer c.gpa.free(body);
        const framed = try jsonrpc.frame(c.gpa, body);
        defer c.gpa.free(framed);
        if (c.log) |f| try f.writeStreamingAll(c.io, framed);
        try c.child.stdin.?.writeStreamingAll(c.io, framed);
    }

    /// Sends a request and waits for its response message (valid until
    /// `deinit`)
    pub fn request(c: *Client, method: []const u8, params: anytype) !Value {
        c.next_id += 1;
        const id = c.next_id;
        try c.send(method, params, id);
        const deadline = Io.Clock.awake.now(c.io).addDuration(c.timeout);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            if (c.responses.fetchRemove(id)) |kv| return kv.value;
            if (c.closed) return error.ServerClosedItsOutput;
            c.cond.waitTimeout(c.io, &c.mutex, .{ .deadline = .{ .raw = deadline, .clock = .awake } }) catch |e| switch (e) {
                error.Timeout => return error.RequestTimedOut,
                else => return e,
            };
        }
    }

    /// Waits until everything sent so far has been handled
    pub fn sync(c: *Client) !void {
        _ = try c.request("textDocument/documentSymbol", .{ .textDocument = .{ .uri = "file:///sync.f90" } });
    }

    /// The latest diagnostics published for `uri`, null when none were
    pub fn diagnosticsOf(c: *Client, uri: []const u8) Value {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.diagnostics.get(uri) orelse .null;
    }

    /// Shuts the server down and waits for it to exit
    pub fn close(c: *Client) !std.process.Child.Term {
        _ = try c.request("shutdown", null);
        try c.send("exit", null, null);
        c.child.stdin.?.close(c.io);
        c.child.stdin = null;
        const term = try c.child.wait(c.io);
        c.join();
        return term;
    }

    /// Stops the server (after a failure)
    pub fn kill(c: *Client) void {
        if (c.child.id != null) c.child.kill(c.io);
        c.join();
    }
};

/// A process's exit, as text
pub fn termText(a: Allocator, term: std.process.Child.Term) ![]const u8 {
    return switch (term) {
        .exited => |code| a.print("exit code {d}", .{code}),
        .signal => |s| a.print("signal {d}", .{@backingInt(s)}),
        .stopped => |s| a.print("stopped by signal {d}", .{@backingInt(s)}),
        .unknown => |code| a.print("exit status {x}", .{code}),
    };
}

/// A new directory under the system's temporary directory, named
/// `prefix` and a number
pub fn tempDir(io: Io, a: Allocator, env: *const std.process.Environ.Map, prefix: []const u8) ![]const u8 {
    const tmp = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp";
    const dir = try a.print("{s}{c}{s}{d}", .{ tmp, std.Io.Dir.path.sep, prefix, Io.Clock.real.now(io).nanoseconds });
    try Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// Copies the directory `src` to `dst`, leaving out .git directories
pub fn copyTree(io: Io, a: Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var from = try cwd.openDir(io, src, .{ .iterate = true });
    defer from.close(io);
    try cwd.createDirPath(io, dst);
    var to = try cwd.openDir(io, dst, .{});
    defer to.close(io);
    var walker = try from.walkSelectively(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| switch (e.kind) {
        .directory => {
            if (std.mem.eql(u8, e.basename, ".git")) continue;
            try to.createDirPath(io, e.path);
            try walker.enter(io, e);
        },
        .file => try Io.Dir.copyFile(e.dir, e.basename, to, e.path, io, .{}),
        else => {},
    };
}
