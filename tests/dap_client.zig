//! The client's side of the Debug Adapter Protocol for the tests of
//! `zfls dap` (tests/dap_windows.zig, tests/dap_gdb.zig): the adapter's
//! process, whose messages a thread reads, keeping the responses by the
//! request they answer, and the events and the adapter's own requests
//! (`runInTerminal`) in order, each message checked against the protocol's
//! shapes (dap_schema.zig): a test fails at its next wait after one that is
//! not. And how the tests build programs on Windows without Visual Studio,
//! with zfls's ifx kit (`kitDir`, `flangKitEnv`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const schema = @import("dap_schema.zig");

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
    /// The requests sent, by seq (under `mutex`), for their responses' checks
    sent: std.AutoHashMapUnmanaged(i64, Value) = .empty,
    /// What was wrong with the adapter's messages, not yet told (under `mutex`)
    violations: std.ArrayList([]const u8) = .empty,

    pub fn start(io: Io, gpa: Allocator, argv: []const []const u8) !*Client {
        return startEnv(io, gpa, argv, null);
    }

    /// `start`, with the adapter's environment `env` (else this one's)
    pub fn startEnv(io: Io, gpa: Allocator, argv: []const []const u8, env: ?*const std.process.Environ.Map) !*Client {
        const c = try gpa.create(Client);
        c.* = .{
            .io = io,
            .gpa = gpa,
            .arena = .init(gpa),
            .child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .create_no_window = true, .environ_map = env }),
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
        c.sent.deinit(c.gpa);
        c.violations.deinit(c.gpa);
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
        const answered = if (int(msg, "request_seq")) |seq| c.sent.get(seq) else null;
        if (try schema.violation(c.arena.allocator(), msg, answered)) |w| try c.violations.append(c.gpa, try c.arena.allocator().print("{s} (in {s})", .{ w, body[0..@min(body.len, 300)] }));
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
        try c.conforms();
        if (c.closed) {
            std.debug.print("zfls dap ended while waiting for {s}\n", .{what});
            return error.AdapterEnded;
        }
        c.cond.waitTimeout(c.io, &c.mutex, .{ .deadline = .{ .raw = deadline, .clock = .awake } }) catch |e| switch (e) {
            error.Timeout => {
                std.debug.print("timed out waiting for {s}; the last events:", .{what});
                for (c.events.items[c.events.items.len -| 8..]) |ev| std.debug.print(" {s}", .{str(ev, "event") orelse "?"});
                std.debug.print("\n", .{});
                return error.Timeout;
            },
            else => return e,
        };
    }

    /// Fails when a message received was not of the protocol's shapes
    /// (under `mutex`)
    fn conforms(c: *Client) !void {
        if (c.violations.items.len == 0) return;
        for (c.violations.items) |w| std.debug.print("FAIL: the protocol: {s}\n", .{w});
        c.violations.clearRetainingCapacity();
        return error.ProtocolViolation;
    }

    fn write(c: *Client, msg: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(c.gpa, msg, .{ .emit_null_optional_fields = false });
        defer c.gpa.free(body);
        const framed = try c.gpa.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        defer c.gpa.free(framed);
        try c.child.stdin.?.writeStreamingAll(c.io, framed);
    }

    /// Sends a request: its seq, for `response`
    pub fn send(c: *Client, command: []const u8, args: anytype) !i64 {
        const seq = c.seq;
        c.seq += 1;
        const msg = .{ .seq = seq, .type = "request", .command = command, .arguments = args };
        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            const text = try std.json.Stringify.valueAlloc(c.arena.allocator(), msg, .{ .emit_null_optional_fields = false });
            try c.sent.put(c.gpa, seq, try std.json.parseFromSliceLeaky(Value, c.arena.allocator(), text, .{}));
        }
        try c.write(msg);
        return seq;
    }

    /// The response to request `seq`, whether it succeeded or not
    pub fn response(c: *Client, seq: i64, what: []const u8) !Value {
        const deadline = Io.Clock.awake.now(c.io).addDuration(c.timeout);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            if (c.responses.fetchRemove(seq)) |kv| {
                try c.conforms();
                return kv.value;
            }
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
        return c.eventOf(&.{name});
    }

    /// The next event named one of `names` (the events before it are
    /// dropped)
    pub fn eventOf(c: *Client, names: []const []const u8) !Value {
        const deadline = Io.Clock.awake.now(c.io).addDuration(c.timeout);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            while (c.seen < c.events.items.len) {
                const e = c.events.items[c.seen];
                c.seen += 1;
                for (names) |name| if (std.mem.eql(u8, str(e, "event") orelse "", name)) {
                    try c.conforms();
                    return e;
                };
            }
            try c.wait(deadline, names[0]);
        }
    }

    /// Ends the session (`disconnect`, the program terminated or not) and
    /// the adapter; again, nothing
    pub fn end(c: *Client, terminate: bool) void {
        if (c.child.stdin == null) return;
        if (c.send("disconnect", .{ .terminateDebuggee = terminate })) |seq| {
            _ = c.response(seq, "disconnect") catch {};
        } else |_| {}
        c.child.stdin.?.close(c.io);
        c.child.stdin = null;
        _ = c.child.wait(c.io) catch {};
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

/// Whether `v`'s `key` is an array of `len` elements
pub fn isArray(v: Value, key: []const u8, len: usize) bool {
    const x = get(v, key) orelse return false;
    return x == .array and x.array.items.len == len;
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

/// Flang's build environment on Windows that links with lld-link and
/// zfls's ifx kit (`kit`, given by `zig build`; else `ifx-kit` next to
/// zfls, or `../lib/ifx`), as Run Fortran File links without Visual
/// Studio: Visual Studio's variables left out, as CI's check of the kit
/// does; null without the kit (an error when `kit` has none)
pub fn flangKitEnv(io: Io, a: Allocator, environ: *const std.process.Environ.Map, zfls_path: []const u8, kit: ?[]const u8) !?*const std.process.Environ.Map {
    const dir = try kitDir(io, a, zfls_path, kit) orelse return null;
    const env = try withoutVisualStudio(a, environ);
    try env.put("LIB", dir);
    try env.put("LINK", try a.print("\"{s}\" msvcrt.lib ucrt.lib vcruntime.lib kernel32.lib", .{try std.Io.Dir.path.join(a, &.{ dir, "zfls_ifx_shim.obj" })}));
    std.debug.print("linking with the ifx kit {s}\n", .{dir});
    return env;
}

/// The directory of zfls's ifx kit (absolute): `kit`, given by `zig
/// build`; else `ifx-kit` next to zfls, or `../lib/ifx`; null when there is
/// none (an error when `kit` has none)
pub fn kitDir(io: Io, a: Allocator, zfls_path: []const u8, kit: ?[]const u8) !?[]const u8 {
    const exe_dir = std.Io.Dir.path.dirname(zfls_path) orelse return null;
    // absolute: the compiler runs elsewhere (`zig build` gives a relative one)
    const given: ?[]const u8 = if (kit) |k| Io.Dir.cwd().realPathFileAlloc(io, k, a) catch k else null;
    const places: []const []const []const u8 = if (given) |k| &.{&.{k}} else &.{ &.{ exe_dir, "ifx-kit" }, &.{ exe_dir, "..", "lib", "ifx" } };
    for (places) |parts| {
        const dir = try std.Io.Dir.path.join(a, parts);
        const shim = try std.Io.Dir.path.join(a, &.{ dir, "zfls_ifx_shim.obj" });
        Io.Dir.cwd().access(io, shim, .{}) catch continue;
        return dir;
    }
    if (kit) |k| {
        std.debug.print("no ifx kit in {s}\n", .{k});
        return error.NoKit;
    }
    return null;
}

/// A copy of `environ` without Visual Studio's variables, as CI's check of
/// the kit does
pub fn withoutVisualStudio(a: Allocator, environ: *const std.process.Environ.Map) !*std.process.Environ.Map {
    const env = try a.create(std.process.Environ.Map);
    env.* = try environ.clone(a);
    for (visual_studio_variables) |v| _ = env.swapRemove(v);
    return env;
}

/// The variables of a Visual Studio developer prompt, by which LLVM's
/// driver and lld-link find its libraries
const visual_studio_variables = [_][]const u8{ "VCToolsInstallDir", "VCINSTALLDIR", "VSINSTALLDIR", "WindowsSdkDir", "UniversalCRTSdkDir", "INCLUDE", "LIBPATH" };

/// Whether lld-link's list of what it read (`-Wl,-verbose`) names a file of
/// Visual Studio's or of the Windows SDK's: what it read, or null
pub fn visualStudioRead(output: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        for ([_][]const u8{ "Microsoft Visual Studio", "Windows Kits" }) |mark| {
            if (std.ascii.findIgnoreCase(line, mark) != null) return std.mem.trimEnd(u8, line, "\r");
        }
    }
    return null;
}

test "lld-link's reading of Visual Studio's files" {
    try std.testing.expect(visualStudioRead("lld-link: Reading C:\\kit\\msvcrt.lib\r\nlld-link: Reading p.o\r\n") == null);
    try std.testing.expectEqualStrings("lld-link: Reading C:\\Program Files (x86)\\Windows Kits\\10\\Lib\\ucrt.lib", visualStudioRead("lld-link: Reading C:\\kit\\a.lib\nlld-link: Reading C:\\Program Files (x86)\\Windows Kits\\10\\Lib\\ucrt.lib\r\n").?);
}

test {
    _ = schema;
}
