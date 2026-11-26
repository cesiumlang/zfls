//! zfls dap's capabilities when a launch chooses Windows's Debugger Engine
//! after `initialize` gave the client gdb's, for tests/dap_windows.zig
//! (tests/dap/hello.c): a `capabilities` event before the launch's
//! response takes back what the engine lacks (#731).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const int = dap.int;
const items = dap.items;
const str = dap.str;
const check = dap.check;

/// gdb's capabilities that the engine has not
const lacking = [_][]const u8{ "supportsFunctionBreakpoints", "supportsDisassembleRequest", "supportsReadMemoryRequest" };

/// The leg (skipped without `gdb`)
pub fn run(io: Io, gpa: Allocator, a: Allocator, zfls: []const u8, gdb: []const u8, exe: []const u8, tmp: []const u8, src_dir: []const u8) !void {
    _ = std.process.run(a, io, .{ .argv = &.{ gdb, "--version" } }) catch
        return std.debug.print("the engine's capabilities after gdb's: skipped: no {s}\n", .{gdb});
    const c = try Client.start(io, gpa, &.{ zfls, "dap", "--gdb", gdb });
    defer c.deinit();
    walk(c, exe, tmp, src_dir) catch |e| {
        if (c.child.id != null) c.child.kill(io);
        return e;
    };
}

fn walk(c: *Client, exe: []const u8, tmp: []const u8, src_dir: []const u8) !void {
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    for (lacking) |name| try check(isTrue(caps, name), "gdb's capabilities at initialize: {s}", .{name});
    const launched = try c.send("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = src_dir, .dbgeng = true });
    const r = try c.response(launched, "launch");
    _ = try Client.bodyOf(r, "launch");
    const e = try c.event("capabilities");
    try check(int(e, "seq").? < int(r, "seq").?, "the capabilities event before the launch's response ({?d}, {?d})", .{ int(e, "seq"), int(r, "seq") });
    const changed = get(get(e, "body").?, "capabilities").?;
    for (lacking) |name| try check(isFalse(changed, name), "the engine's: no {s}", .{name});
    const filters = items(changed, "exceptionBreakpointFilters");
    try check(filters.len == 1 and std.mem.eql(u8, str(filters[0], "filter") orelse "", "fortranRuntimeErrors"), "the engine's filters: the Fortran runtime errors' alone ({d})", .{filters.len});
    const chars = items(changed, "completionTriggerCharacters");
    try check(chars.len == 1 and std.mem.eql(u8, chars[0].string, "%"), "the engine's completion characters: `%` alone ({d})", .{chars.len});
    _ = try c.request("configurationDone", .{});
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 3, "the engine's run: exit code 3 ({?d})", .{int(exited, "exitCode")});
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
}

fn isTrue(v: Value, key: []const u8) bool {
    const x = get(v, key) orelse return false;
    return x == .bool and x.bool;
}

fn isFalse(v: Value, key: []const u8) bool {
    const x = get(v, key) orelse return false;
    return x == .bool and !x.bool;
}
