//! The client's side of the Debug Adapter Protocol for the tests of
//! `zfls dap` (tests/dap_windows.zig, tests/dap_gdb.zig): the adapter's
//! process, whose messages a thread reads, keeping the responses by the
//! request they answer, and the events and the adapter's own requests
//! (`runInTerminal`) in order.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");

pub const Client = struct {
    io: Io,
    gpa: Allocator,
    child: std.process.Child,
    /// Messages received (under `mutex`)
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    responses: std.AutoHashMapUnmanaged(i64, Value) = .empty,
    events: std.ArrayList(Value) = .empty,
    /// The adapter's requests
    requests: std.ArrayList(Value) = .empty,
    /// The events `event` has gone past
    seen: usize = 0,
    closed: bool = false,
    seq: i64 = 1,
    thread: ?std.Thread = null,
    timeout: Io.Duration = .fromSeconds(60),
    /// What the program wrote (`output` events)
    output: std.ArrayList(u8) = .empty,

    pub fn start(io: Io, gpa: Allocator, argv: []const []const u8) !*Client {
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

    pub fn deinit(c: *Client) void {
        if (c.thread) |t| t.join();
        c.responses.deinit(c.gpa);
        c.events.deinit(c.gpa);
        c.requests.deinit(c.gpa);
        c.output.deinit(c.gpa);
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
        } else if (std.mem.eql(u8, kind, "event")) {
            try c.events.append(c.gpa, msg);
            if (std.mem.eql(u8, str(msg, "event") orelse "", "output")) {
                if (get(msg, "body")) |b| try c.output.appendSlice(c.gpa, str(b, "output") orelse "");
            }
        } else if (std.mem.eql(u8, kind, "request")) try c.requests.append(c.gpa, msg);
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

    fn write(c: *Client, msg: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(c.gpa, msg, .{});
        defer c.gpa.free(body);
        const framed = try c.gpa.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        defer c.gpa.free(framed);
        try c.child.stdin.?.writeStreamingAll(c.io, framed);
    }

    /// Sends a request: its seq, for `response`
    pub fn send(c: *Client, command: []const u8, args: anytype) !i64 {
        const seq = c.seq;
        c.seq += 1;
        try c.write(.{ .seq = seq, .type = "request", .command = command, .arguments = args });
        return seq;
    }

    /// The response to request `seq`, whether it succeeded or not
    pub fn response(c: *Client, seq: i64, what: []const u8) !Value {
        const deadline = Io.Clock.awake.now(c.io).addDuration(c.timeout);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            if (c.responses.fetchRemove(seq)) |kv| return kv.value;
            try c.wait(deadline, what);
        }
    }

    /// The body of a response, which must have succeeded
    pub fn bodyOf(r: Value, what: []const u8) !Value {
        if (get(r, "success")) |ok| if (ok == .bool and ok.bool) return get(r, "body") orelse .{ .object = .empty };
        std.debug.print("{s} failed: {s}\n", .{ what, str(r, "message") orelse "(no message)" });
        return error.RequestFailed;
    }

    /// Sends a request and returns the body of its response, which must
    /// succeed
    pub fn request(c: *Client, command: []const u8, args: anytype) !Value {
        return bodyOf(try c.response(try c.send(command, args), command), command);
    }

    /// Answers the adapter's request
    pub fn answer(c: *Client, req: Value, success: bool, body: anytype) !void {
        const seq = c.seq;
        c.seq += 1;
        try c.write(.{ .seq = seq, .type = "response", .request_seq = int(req, "seq") orelse 0, .command = str(req, "command") orelse "", .success = success, .body = body });
    }

    /// The adapter's next request
    pub fn adapterRequest(c: *Client) !Value {
        const deadline = Io.Clock.awake.now(c.io).addDuration(c.timeout);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            if (c.requests.items.len > 0) return c.requests.orderedRemove(0);
            try c.wait(deadline, "the adapter's request");
        }
    }

    /// The next event named `name` (the events before it are dropped)
    pub fn event(c: *Client, name: []const u8) !Value {
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

    /// The output so far (a copy)
    pub fn outputText(c: *Client, a: Allocator) ![]const u8 {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return a.dupe(u8, c.output.items);
    }
};

pub fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

pub fn str(v: Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn int(v: Value, key: []const u8) ?i64 {
    const x = get(v, key) orelse return null;
    return if (x == .integer) x.integer else null;
}

pub fn items(v: Value, key: []const u8) []Value {
    const x = get(v, key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

pub fn contains(s: ?[]const u8, part: []const u8) bool {
    return std.mem.find(u8, s orelse return false, part) != null;
}

pub fn check(ok: bool, comptime what: []const u8, args: anytype) !void {
    if (!ok) {
        std.debug.print("FAIL: " ++ what ++ "\n", args);
        return error.CheckFailed;
    }
    std.debug.print("ok: " ++ what ++ "\n", args);
}
