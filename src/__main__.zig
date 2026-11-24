const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const root = @import("root");
const json = @import("json.zig");
const patterns = @import("patterns.zig");
const paths = @import("paths.zig");
const executables = @import("executables.zig");
const settings = @import("settings.zig");
const jsonrpc = @import("jsonrpc.zig");
const server_mod = @import("server.zig");
const debug = @import("debug.zig");
const version_info = @import("version.zig");
const Logger = @import("logger.zig");
const stdio = @import("stdio.zig");

const app_name = if (@hasDecl(root, "app_name")) root.app_name else "zfls";
const version = if (@hasDecl(root, "version")) root.version else @import("build_options").version;

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    s: settings.Settings,
    environ: *const std.process.Environ.Map,
    exit_code: u8 = 0,
};

/// The client's end of the server: standard output
const Client = struct {
    io: Io,
    out: Io.File,
    server: *server_mod.Server,
    log: *Logger,
    ctx: *Ctx,
    failed: bool = false,

    /// A message the client does not get is not dropped silently: the
    /// server reports it and stops, since the client would wait for the
    /// answer forever.
    fn send(ctx: ?*anyopaque, body: []const u8) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        if (self.failed) return;
        self.write(body) catch |e| {
            self.failed = true;
            self.log.err("cannot write to the client ({s}): stopping", .{@errorName(e)});
            self.server.running = false;
            self.ctx.exit_code = 1;
        };
    }

    fn write(self: *Client, body: []const u8) !void {
        var buf: [128]u8 = undefined;
        const header = try std.mem.print(&buf, "Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf8\r\n\r\n", .{body.len});
        try self.out.writeStreamingAll(self.io, header);
        try self.out.writeStreamingAll(self.io, body);
    }
};

/// The client's messages, read by a task of its own (`read`, an `Io`
/// task), so that the server can wait for one only until the diagnostics
/// of a changed document are due (`Server.nextDiagnosticsTime`). When the
/// server ends, the input can still be open and the task in a read of it:
/// the server cancels the task and waits for it to end (`runServer`), so
/// that nothing the task uses is gone while it runs, nor the body of a
/// message it was reading left allocated.
const Inbox = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// The messages read and not taken yet, owned by `gpa`
    queue: std.ArrayList([]u8) = .empty,
    /// The input has ended or failed (`failure`): no message follows
    ended: bool = false,
    failure: ?jsonrpc.ReadError = null,

    /// Reads messages until the input ends or fails, or the task is
    /// canceled (a failure of the read)
    fn read(inbox: *Inbox) void {
        const io = inbox.io;
        var read_buf: [64 * 1024]u8 = undefined;
        // (overlapped or not: stdio.zig)
        var reader = stdio.stdin().readerStreaming(io, &read_buf);
        while (true) {
            const message = jsonrpc.readMessage(&reader.interface, inbox.gpa);
            inbox.mutex.lockUncancelable(io);
            defer inbox.mutex.unlock(io);
            defer inbox.cond.signal(io);
            const body = (message catch |e| {
                inbox.failure = e;
                inbox.ended = true;
                return;
            }) orelse {
                inbox.ended = true;
                return;
            };
            inbox.queue.append(inbox.gpa, body) catch {
                inbox.gpa.free(body);
                inbox.failure = error.OutOfMemory;
                inbox.ended = true;
                return;
            };
        }
    }

    /// Moves the messages that have arrived to `into`. With `wait`, waits
    /// for one first, or for the end of the input, at most until `deadline`
    /// (the awake clock's nanoseconds). Returns whether more can follow;
    /// the failure of the input once its messages are taken.
    fn take(inbox: *Inbox, into: *std.ArrayList([]u8), wait: bool, deadline: ?i96) !bool {
        const io = inbox.io;
        inbox.mutex.lockUncancelable(io);
        defer inbox.mutex.unlock(io);
        while (wait and inbox.queue.items.len == 0 and !inbox.ended) {
            const t = deadline orelse {
                inbox.cond.waitUncancelable(io, &inbox.mutex);
                continue;
            };
            if (Io.Clock.awake.now(io).nanoseconds >= t) break;
            inbox.cond.waitTimeout(io, &inbox.mutex, .{ .deadline = .{ .raw = .{ .nanoseconds = t }, .clock = .awake } }) catch {};
        }
        try into.appendSlice(inbox.gpa, inbox.queue.items);
        inbox.queue.clearRetainingCapacity();
        if (into.items.len == 0) if (inbox.failure) |e| return e;
        return !inbox.ended;
    }

    /// Once the task has ended
    fn deinit(inbox: *Inbox) void {
        for (inbox.queue.items) |b| inbox.gpa.free(b);
        inbox.queue.deinit(inbox.gpa);
    }
};

fn runServer(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const io = ctx.io;
    var log = Logger.init(io);
    defer log.deinit();
    const server = server_mod.Server.create(gpa, io, ctx.s, &log) catch |e| {
        log.err("failed to start server: {s}", .{@errorName(e)});
        ctx.exit_code = 1;
        return;
    };
    defer server.destroy();
    server.setEnviron(ctx.environ) catch |e| log.warn("the tools' environment: {s}", .{@errorName(e)});
    var client: Client = .{ .io = io, .out = stdio.stdout(), .server = server, .log = &log, .ctx = ctx };
    server.sink = .{ .ctx = @ptrCast(&client), .sendFn = Client.send };

    var inbox_storage: Inbox = .{ .gpa = gpa, .io = io };
    const inbox = &inbox_storage;
    var reader = io.concurrent(Inbox.read, .{inbox}) catch |e| {
        log.err("failed to start server: {s}", .{@errorName(e)});
        ctx.exit_code = 1;
        return;
    };
    // the input can still be open after `exit`: the read is canceled
    defer {
        reader.cancel(io);
        inbox.deinit();
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // messages read but not handled yet, so that a request the client
    // cancels while it waits is not worked on ($/cancelRequest)
    var queue: std.ArrayList([]u8) = .empty;
    defer {
        for (queue.items) |b| gpa.free(b);
        queue.deinit(gpa);
    }
    while (server.running) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        // without a message to handle, a wait for one, at most until the
        // diagnostics of a changed document are due
        const more = inbox.take(&queue, queue.items.len == 0, server.nextDiagnosticsTime()) catch |e| {
            server.postMessage(a, a.print("Unexpected error: {s}", .{@errorName(e)}) catch "Unexpected error", 1);
            break;
        };
        if (queue.items.len == 0) {
            if (!more) break;
            server.publishPendingDiagnostics(a, Io.Clock.awake.now(io).nanoseconds);
            continue;
        }
        const body = queue.orderedRemove(0);
        defer gpa.free(body);
        const request = json.parse(a, body) catch {
            server.postMessage(a, "Unexpected error: invalid JSON message", 1);
            break;
        };
        if (log.enabled(.debug)) log.debug("RECV {s}", .{json.pretty(a, request) catch ""});
        if (json.get(request, "id")) |id| if (canceledLater(a, queue.items, id)) {
            server.canceled(a, id);
            continue;
        };
        server.handle(a, request);
        server.flushPostMessages(a);
    }
}

/// Whether one of the messages waiting cancels request `id`
fn canceledLater(a: std.mem.Allocator, waiting: []const []u8, id: json.Value) bool {
    for (waiting) |body| {
        if (std.mem.find(u8, body, "$/cancelRequest") == null) continue;
        const msg = json.parse(a, body) catch continue;
        const method = json.str(json.get(msg, "method")) orelse continue;
        if (!std.mem.eql(u8, method, "$/cancelRequest")) continue;
        const cid = json.path(msg, &.{ "params", "id" }) orelse continue;
        if (sameId(cid, id)) return true;
    }
    return false;
}

/// Request ids are integers or strings
fn sameId(x: json.Value, y: json.Value) bool {
    if (json.int(x)) |i| return if (json.int(y)) |j| i == j else false;
    if (json.str(x)) |s| return if (json.str(y)) |t| std.mem.eql(u8, s, t) else false;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    patterns.init();
    paths.init(io);
    paths.initCache(init.arena.allocator(), init.environ_map);
    paths.initUserConfig(init.arena.allocator(), init.environ_map);
    executables.initProcessEnv(init.environ_map);

    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var args: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |arg| try args.append(arena, arg);

    // ifx without Intel's installer or Visual Studio (Windows)
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "setup-ifx")) {
        const code = try @import("ifxsetup.zig").run(gpa, io, init.environ_map, args.items[1..]);
        if (code != 0) std.process.exit(code);
        return;
    }

    // the command that builds a Fortran file to run or debug, as JSON
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "build-command")) {
        const code = try @import("run/cli.zig").run(gpa, io, init.environ_map, args.items[1..]);
        if (code != 0) std.process.exit(code);
        return;
    }

    // a debug adapter over gdb or Windows's Debugger Engine
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "dap")) {
        const code = try @import("dap/session.zig").run(gpa, io, init.environ_map, args.items[1..]);
        if (code != 0) std.process.exit(code);
        return;
    }

    version_info.reported = version_info.get(io, version);
    const parsed = try settings.parseArgs(arena, args.items, version_info.reported);
    const s = switch (parsed) {
        .run => |s| s,
        .exit_ok => |text| {
            try stdio.stdout().writeStreamingAll(io, text);
            return;
        },
        .exit_err => |text| {
            try stdio.stderr().writeStreamingAll(io, text);
            std.process.exit(2);
        },
    };

    if (s.debug_parser or s.debug_preproc or s.isDebugMode()) {
        const code = debug.run(gpa, io, s) catch |e| blk: {
            const msg = try arena.print("ERROR: {s}\n", .{@errorName(e)});
            try stdio.stdout().writeStreamingAll(io, msg);
            break :blk 255;
        };
        if (code != 0) std.process.exit(code);
        return;
    }

    var ctx: Ctx = .{ .gpa = gpa, .io = io, .s = s, .environ = init.environ_map };
    // Run on a thread with a large stack: Fortran code can nest deeply and
    // name resolution is recursive.
    const th = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, runServer, .{&ctx});
    th.join();
    if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
}
