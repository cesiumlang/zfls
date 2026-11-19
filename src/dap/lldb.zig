//! lldb-dap for `zfls dap`: LLVM's debug adapter, which Xcode's command
//! line tools have, signed; the backend by default on macOS, where gdb does
//! not run on Apple silicon and must be code-signed on Intel. Its protocol
//! is passed through as gdb's is, over the same process (gdb.zig) and the
//! same requests (gdb_requests.zig): the "Fortran runtime errors" filter,
//! ERROR STOP, the runtime's frames de-emphasized, the program in a
//! terminal. lldb reads no Fortran ("no plugin for the language
//! fortran95"): the variables and expressions are lldb's own, passed
//! through as it gives them (for gfortran's and LLVM Flang's frames, none),
//! and there is no "Module variables" scope.
//!
//! Here finding lldb-dap and starting it, `launch` and `attach` in
//! lldb-dap's words, and the breakpoints of the runtime's errors and of the
//! main program. Those are lldb's own, set by commands (lldb-dap's REPL),
//! so that their ids are known: the answer of Apple's lldb-dap (lldb-1700)
//! to `setFunctionBreakpoints` lists them in no particular order, and
//! breakpoints without its label "dap" make no `breakpoint` events.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const paths = @import("../paths.zig");
const fortran = @import("fortran.zig");
const runtime_errors = @import("runtime_errors.zig");
const Value = json.Value;

const session = @import("session.zig");
const Session = session.Session;
const gdb = @import("gdb.zig");
const gdb_requests = @import("gdb_requests.zig");

/// lldb-dap's exception breakpoint filters of Objective-C and Swift, of no
/// use to Fortran (C++'s stay, for programs of both)
pub const foreign_filters = [_][]const u8{ "objc_catch", "objc_throw", "swift_catch", "swift_throw" };

/// lldb-dap's executable: `configured`, else on macOS `xcrun --find
/// lldb-dap` (Xcode's or its command line tools'), else the PATH's
/// `lldb-dap`, else its `lldb-vscode` (its name before LLVM 18)
pub fn find(a: Allocator, io: Io, environ: *const std.process.Environ.Map, configured: ?[]const u8) !?[]const u8 {
    if (configured) |c| if (c.len > 0) return c;
    if (builtin.target.os.tag == .macos) {
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };
        if (std.process.run(a, io, .{ .argv = &.{ "xcrun", "--find", "lldb-dap" }, .environ_map = environ, .timeout = timeout })) |r| {
            const p = std.mem.trim(u8, r.stdout, " \t\r\n");
            if (r.term.success() and p.len > 0 and paths.isFile(io, p)) return p;
        } else |_| {}
    }
    for ([_][]const u8{ "lldb-dap", "lldb-vscode" }) |name| {
        if (try onPath(a, io, environ, name)) |p| return p;
    }
    return null;
}

fn onPath(a: Allocator, io: Io, environ: *const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const exe = if (builtin.target.os.tag == .windows) try a.print("{s}.exe", .{name}) else name;
    var it = std.mem.tokenizeScalar(u8, environ.get("PATH") orelse "", std.Io.Dir.path.delimiter);
    while (it.next()) |dir| {
        const p = try std.Io.Dir.path.join(a, &.{ dir, exe });
        if (paths.isFile(io, p)) return p;
    }
    return null;
}

/// Starts lldb-dap (`configured`, else the one `find` finds): null, or why
/// it did not start
pub fn start(s: *Session, a: Allocator, configured: ?[]const u8) !?[]const u8 {
    gdb.stop(s);
    const exe = try find(a, s.io, s.environ, configured) orelse return if (builtin.target.os.tag == .macos)
        "zfls dap: no lldb-dap; Xcode's command line tools have it (xcode-select --install). Or name one: `lldb` in the launch configuration (--lldb PATH), or debug with gdb: `gdb` in the launch configuration (--gdb PATH)"
    else
        "zfls dap: no lldb-dap or lldb-vscode (LLVM's) on the PATH; name one with `lldb` in the launch configuration (--lldb PATH)";
    const env = try a.create(std.process.Environ.Map);
    env.* = try s.environ.clone(a);
    return gdb.spawn(s, a, &.{exe}, env, true);
}

/// `launch`, `attach`: the program's terminal, the configuration in
/// lldb-dap's words, then lldb-dap's request
pub fn launch(s: *Session, a: Allocator, req: Value, args: ?Value) !void {
    const command = json.str(json.get(req, "command")) orelse "launch";
    if (!std.mem.eql(u8, command, "launch")) {
        if (json.str(json.get(args, "target"))) |t| if (t.len > 0)
            return s.fail(a, req, "zfls dap: lldb-dap attaches to a processId; a gdbserver's target needs gdb (`gdb` in the configuration)");
        s.stop_at_entry = false;
        const o = attachArguments(a, args) catch return s.fail(a, req, "processId is not a number");
        return gdb.forward(s, a, req, o);
    }
    s.stop_at_entry = flag(args, "stopAtEntry");
    var tty: ?[]const u8 = null;
    const console = json.str(json.get(args, "console")) orelse "internalConsole";
    if (!std.mem.eql(u8, console, "internalConsole") and builtin.target.os.tag != .windows and s.g.run_in_terminal) {
        const kind = if (std.mem.eql(u8, console, "externalTerminal")) "external" else "integrated";
        tty = try gdb_requests.terminalTty(s, a, kind, json.str(json.get(args, "cwd")));
    }
    try gdb.forward(s, a, req, try launchArguments(a, args, tty));
}

/// lldb-dap's keys of a configuration that go to it as they are
const own_keys = [_][]const u8{ "initCommands", "postRunCommands", "stopCommands", "exitCommands", "terminateCommands", "sourceMap" };

/// A `launch` configuration in lldb-dap's words: its environment as
/// `NAME=VALUE` (over lldb-dap's own, which the program inherits), the
/// program's input and output in the terminal `tty`, the configuration's
/// `setupCommands` (lldb commands) before the program runs. The stop at the
/// start is a breakpoint on the main program (`configurationDone`), not
/// lldb-dap's `stopOnEntry`, which stops in the loader.
pub fn launchArguments(a: Allocator, args: ?Value, tty: ?[]const u8) !Value {
    var o: json.ObjectMap = .empty;
    if (json.str(json.get(args, "program"))) |p| try o.put(a, "program", .{ .string = p });
    if (json.str(json.get(args, "cwd"))) |c| try o.put(a, "cwd", .{ .string = c });
    var list: json.Array = .init(a);
    for (json.items(json.get(args, "args"))) |x| try list.append(.{ .string = try gdb_requests.text(a, x) });
    try o.put(a, "args", .{ .array = list });
    var env: json.Array = .init(a);
    if (json.get(args, "env")) |e| if (e == .object) {
        var it = e.object.iterator();
        while (it.next()) |kv| try env.append(.{ .string = try a.print("{s}={s}", .{ kv.key_ptr.*, try gdb_requests.text(a, kv.value_ptr.*) }) });
    };
    try o.put(a, "env", .{ .array = env });
    try o.put(a, "stopOnEntry", .{ .bool = false });
    var pre: json.Array = .init(a);
    if (tty) |t| for ([_][]const u8{ "input", "output", "error" }) |which| {
        try pre.append(.{ .string = try a.print("settings set target.{s}-path {s}", .{ which, t }) });
    };
    for (json.items(json.get(args, "setupCommands"))) |c| {
        const cmd = json.str(c) orelse json.str(json.get(c, "text")) orelse continue;
        const t = std.mem.trim(u8, cmd, " \t\r\n");
        // cppdbg's are MI commands (`-enable-pretty-printing`)
        if (t.len == 0 or t[0] == '-') continue;
        try pre.append(.{ .string = t });
    }
    for (json.items(json.get(args, "preRunCommands"))) |c| try pre.append(c);
    if (pre.items.len > 0) try o.put(a, "preRunCommands", .{ .array = pre });
    for (own_keys) |k| if (json.get(args, k)) |v| try o.put(a, k, v);
    return .{ .object = o };
}

/// An `attach` configuration in lldb-dap's words: the process `pid`
fn attachArguments(a: Allocator, args: ?Value) !Value {
    var o: json.ObjectMap = .empty;
    if (json.get(args, "processId")) |p| switch (p) {
        .integer => |n| try o.put(a, "pid", .{ .integer = n }),
        .string => |t| if (t.len > 0) try o.put(a, "pid", .{ .integer = try std.fmt.parseInt(i64, std.mem.trim(u8, t, " "), 10) }),
        else => {},
    };
    if (json.str(json.get(args, "program"))) |p| if (p.len > 0) try o.put(a, "program", .{ .string = p });
    if (json.get(args, "waitFor")) |w| try o.put(a, "waitFor", w);
    var pre: json.Array = .init(a);
    for (json.items(json.get(args, "setupCommands"))) |c| {
        const cmd = json.str(c) orelse json.str(json.get(c, "text")) orelse continue;
        const t = std.mem.trim(u8, cmd, " \t\r\n");
        if (t.len == 0 or t[0] == '-') continue;
        try pre.append(.{ .string = t });
    }
    if (pre.items.len > 0) try o.put(a, "initCommands", .{ .array = pre });
    for (own_keys) |k| if (json.get(args, k)) |v| try o.put(a, k, v);
    return .{ .object = o };
}

/// Before `configurationDone` runs the program: the stop at the start, a
/// breakpoint on the main program of gfortran's, LLVM Flang's and Intel's
/// programs, deleted once it has stopped it (`afterEntry`; one of lldb's
/// `--one-shot` is gone before lldb-dap tells its id)
pub fn beforeRun(s: *Session, a: Allocator) !void {
    s.g.entry_breakpoint = null;
    s.g.entry_hit = false;
    if (!s.stop_at_entry) return;
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(a, "breakpoint set");
    for (fortran.main_program_functions) |name| try cmd.print(a, " --name {s}", .{name});
    s.g.entry_breakpoint = try run(s, a, cmd.items);
}

/// After the stop at the start: its breakpoint deleted
pub fn afterEntry(s: *Session, a: Allocator) !void {
    if (!s.g.entry_hit) return;
    const id = s.g.entry_breakpoint orelse return;
    s.g.entry_breakpoint = null;
    s.g.entry_hit = false;
    _ = try run(s, a, try a.print("breakpoint delete {d}", .{id}));
}

/// The breakpoints on the runtime's error functions, when that filter is
/// on: lldb's, by commands, each its function's
pub fn syncErrors(s: *Session, a: Allocator) !void {
    var ids: std.ArrayList(u8) = .empty;
    var it = s.g.error_breakpoints.keyIterator();
    while (it.next()) |id| try ids.print(a, " {d}", .{id.*});
    if (ids.items.len > 0) _ = try run(s, a, try a.print("breakpoint delete{s}", .{ids.items}));
    s.g.error_breakpoints.clearRetainingCapacity();
    if (!s.g.runtime_errors) return;
    for (runtime_errors.gdb_breakpoints) |b| {
        // Flang's STOP functions: only at ERROR STOP
        const command = if (b.condition) |c|
            try a.print("breakpoint set --name {s} --condition '{s}'", .{ b.name, c })
        else
            try a.print("breakpoint set --name {s}", .{b.name});
        const id = try run(s, a, command) orelse continue;
        try s.g.error_breakpoints.put(s.gpa, id, b.name);
    }
}

/// Runs an lldb command in lldb-dap's REPL (its prefix "`" makes it a
/// command whatever the REPL's mode): the id of the breakpoint it set, if
/// it set one
fn run(s: *Session, a: Allocator, command: []const u8) !?i64 {
    const r = try gdb.request(s, a, "evaluate", .{ .expression = try a.print("`{s}", .{command}), .context = "repl" });
    return breakpointId(json.str(json.path(r, &.{ "body", "result" })) orelse "");
}

/// The id of the breakpoint that lldb's `breakpoint set` reports:
/// `Breakpoint 4: no locations (pending).` -> 4
pub fn breakpointId(output: []const u8) ?i64 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const head = "Breakpoint ";
        if (!std.mem.startsWith(u8, line, head)) continue;
        const rest = line[head.len..];
        const colon = std.mem.findScalar(u8, rest, ':') orelse continue;
        return std.fmt.parseInt(i64, rest[0..colon], 10) catch continue;
    }
    return null;
}

fn flag(args: ?Value, name: []const u8) bool {
    const v = json.get(args, name) orelse return false;
    return v == .bool and v.bool;
}

test "the ids of lldb's breakpoints" {
    try std.testing.expectEqual(@as(?i64, 4), breakpointId("(lldb) breakpoint set -n _gfortran_runtime_error_at\nBreakpoint 4: no locations (pending).\nWARNING:  Unable to resolve breakpoint to any actual locations.\n"));
    try std.testing.expectEqual(@as(?i64, 12), breakpointId("Breakpoint 12: where = libgfortran.5.dylib`_gfortran_runtime_error_at, address = 0x0000000100372c20\n"));
    try std.testing.expectEqual(@as(?i64, null), breakpointId("error: invalid combination of options for the given command\n"));
    try std.testing.expectEqual(@as(?i64, null), breakpointId(""));
}

test "a launch in lldb-dap's words" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try json.parse(a,
        \\{"program": "/w/grid", "cwd": "/w", "args": ["x", 3], "env": {"OMP_NUM_THREADS": "2"},
        \\ "stopAtEntry": true, "console": "integratedTerminal", "gdb": "gdb",
        \\ "setupCommands": [{"text": "-enable-pretty-printing"}, "settings set target.max-children-count 10"],
        \\ "initCommands": ["log enable lldb process"]}
    );
    const out = try launchArguments(a, config, "/dev/ttys003");
    const eq = std.testing.expectEqualStrings;
    try eq(
        \\{"program":"/w/grid","cwd":"/w","args":["x","3"],"env":["OMP_NUM_THREADS=2"],"stopOnEntry":false,"preRunCommands":["settings set target.input-path /dev/ttys003","settings set target.output-path /dev/ttys003","settings set target.error-path /dev/ttys003","settings set target.max-children-count 10"],"initCommands":["log enable lldb process"]}
    , try json.stringify(a, out));
    // no terminal, no commands
    try eq(
        \\{"program":"/w/grid","args":[],"env":[],"stopOnEntry":false}
    , try json.stringify(a, try launchArguments(a, try json.parse(a, "{\"program\": \"/w/grid\"}"), null)));
    const attached = try attachArguments(a, try json.parse(a, "{\"processId\": \"123 \", \"program\": \"/w/grid\"}"));
    try eq("{\"pid\":123,\"program\":\"/w/grid\"}", try json.stringify(a, attached));
    try std.testing.expectError(error.InvalidCharacter, attachArguments(a, try json.parse(a, "{\"processId\": \"x\"}")));
}

test "finding lldb-dap: the configured one first, else the PATH's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    try std.testing.expectEqualStrings("/opt/llvm/bin/lldb-dap", (try find(a, std.testing.io, &env, "/opt/llvm/bin/lldb-dap")).?);
    // no PATH: none, unless xcrun knows one (macOS)
    if (builtin.target.os.tag != .macos) try std.testing.expect(try find(a, std.testing.io, &env, null) == null);
}
