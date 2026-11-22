//! The external tools zfls runs, for the tests: stand-ins, scripts that
//! append their arguments to a log beside them and print a fixed text,
//! and what the tests read of the log; and the real tools, on the PATH.
//! The stand-ins are not named as the tools, so that no search for a tool
//! by its name (Windows looks in the current directory first) finds them.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in `fake-NAME.cmd` (Windows) or `fake-NAME.sh` that logs its
/// arguments to `fake-NAME.log` and prints `out` (no `'`, `%`, `&`, `|`,
/// `<`, `>` or `^` in it) on stdout, or on stderr and fails with `fails`
pub fn logging(comptime name: []const u8, comptime out: []const u8, comptime fails: bool) h.File {
    return if (is_windows) .{
        .name = "fake-" ++ name ++ ".cmd",
        .text = "@echo off\r\necho %* >> \"%~dp0fake-" ++ name ++ ".log\"\r\necho " ++ out ++ (if (fails) " 1>&2\r\nexit /b 1" else "") ++ "\r\n",
    } else .{
        .name = "fake-" ++ name ++ ".sh",
        .text = "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/fake-" ++ name ++ ".log\"\necho '" ++ out ++ "'" ++ (if (fails) " >&2\nexit 1" else "") ++ "\n",
    };
}

/// Makes the stand-ins executable (POSIX)
pub fn makeExecutable(w: *h.Workspace, files: []const h.File) !void {
    if (is_windows) return;
    for (files) |f| try w.tmp.dir.setFilePermissions(io, f.name, .executable_file, .{});
}

/// The logged runs of stand-in `name` whose arguments contain `needle`,
/// their arguments without quotes
pub fn runs(w: *h.Workspace, comptime name: []const u8, needle: []const u8) ![]const []const u8 {
    const log = w.tmp.dir.readFileAlloc(io, "fake-" ++ name ++ ".log", w.a(), .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, log, "\r\n");
    while (it.next()) |raw| {
        // without the quotes cmd.exe's arguments can have (`"-DX=1"`)
        const line = try std.mem.replaceOwned(u8, w.a(), raw, "\"", "");
        if (std.mem.find(u8, line, needle) != null) try out.append(w.a(), line);
    }
    return out.items;
}

/// Waits up to `timeout_s` seconds for `n` logged runs of `name` with
/// `needle`; the runs then logged
pub fn waitForRuns(w: *h.Workspace, comptime name: []const u8, needle: []const u8, n: usize, timeout_s: u32) ![]const []const u8 {
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        const got = try runs(w, name, needle);
        if (got.len >= n or waited >= timeout_s * 10) return got;
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

/// `text` contains `needle` (both printed when not)
pub fn expectIn(text: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, text, needle) != null) return;
    std.debug.print("\nno '{s}' in: {s}\n", .{ needle, text });
    return error.TestExpectedText;
}

/// Skips the test when tool `name` is not on the PATH
pub fn need(name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try std.testing.environ.createMap(a);
    if (try h.zfls.executables.onPath(a, io, &env, name) == null) return error.SkipZigTest;
}
