//! zfls dap with a gdb that takes the Debug Adapter Protocol's requests and
//! answers none, for tests/dap_gdb.zig: `initialize` fails after the time
//! given (ZFLS_DAP_ANSWER_TIMEOUT), rather than leaving the client waiting
//! for ever (#374).

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const contains = dap.contains;
const check = dap.check;

pub fn run(io: Io, gpa: Allocator, zfls: []const u8, dir: []const u8, environ: *const std.process.Environ.Map) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = sysinfo.target.os.tag == .windows;
    const fake = try std.Io.Dir.path.join(a, &.{ dir, if (windows) "silent-gdb.cmd" else "silent-gdb" });
    // gdb 17.2 with Python, as zfls checks; then it reads and says nothing
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fake, .data = if (windows)
        "@echo off\r\nif \"%1\"==\"--version\" (echo GNU gdb 17.2& exit /b 0)\r\nif \"%1\"==\"-nx\" (echo 42& exit /b 0)\r\nmore > nul\r\n"
    else
        "#!/bin/sh\ncase \"$1\" in --version) echo 'GNU gdb 17.2'; exit 0;; -nx) echo 42; exit 0;; esac\ncat > /dev/null\n" });
    if (!windows) try Io.Dir.cwd().setFilePermissions(io, fake, .executable_file, .{});
    var env = try environ.clone(a);
    try env.put("ZFLS_DAP_ANSWER_TIMEOUT", "3");
    const c = try Client.startEnv(io, gpa, &.{ zfls, "dap", "--gdb", fake }, &env);
    defer c.deinit();
    c.timeout = .fromSeconds(30);
    // an adapter that waits for ever is killed, not waited for
    initialize(c) catch |e| {
        if (c.child.id != null) c.child.kill(io);
        return e;
    };
    c.end(true);
}

fn initialize(c: *Client) !void {
    const r = try c.response(try c.send("initialize", .{ .adapterID = "fortran", .pathFormat = "path" }), "initialize");
    const ok = if (get(r, "success")) |v| v == .bool and v.bool else false;
    try check(!ok and contains(str(r, "message"), "gdb gave no answer to initialize in 3 s"), "initialize failed: {s}", .{str(r, "message") orelse "(no message)"});
}
