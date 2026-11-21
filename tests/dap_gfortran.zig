//! zfls dap with gdb or lldb-dap on gfortran's runtime errors and stops
//! beyond tests/dap/grid.f90's (tests/dap/runtime.f90, by its argument):
//! an I/O error without `iostat=` stops and one with it does not (#530),
//! an error raised inside libgfortran stops (`RANDOM_SEED`; on Windows the
//! program links libgfortran statically, as Debug Fortran File does, #531,
//! and with its DLL, #615),
//! ERROR STOP with a text and with `quiet=` stops, as with `-fcoarray=lib`
//! (#532, when libcaf_single links), with gdb a CHARACTER of kind 4
//! (#533), and a program linked with libcaf_shmem, whose images the
//! launch says are not followed (#616). For tests/dap_gdb.zig and tests/dap_lldb.zig.

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const check = dap.check;

const source = "tests/dap/runtime.f90";

/// A run of the program: its argument, the stop (its description) or
/// none, the line of the program's frame there, and its exit code
const Case = struct {
    arg: []const u8,
    stop: ?[]const u8,
    marker: ?[]const u8 = null,
    exit: i64,
    /// In the messages, when not the argument
    label: ?[]const u8 = null,
};

const cases = [_]Case{
    .{ .arg = "open", .stop = "Fortran runtime error", .marker = "the I/O error", .exit = 2 },
    .{ .arg = "iostat", .stop = null, .exit = 0 },
    .{ .arg = "seed", .stop = "Fortran runtime error", .marker = "raised inside libgfortran", .exit = 2 },
    .{ .arg = "text", .stop = "ERROR STOP", .marker = "error stop 'text'", .exit = 1 },
    .{ .arg = "quiet", .stop = "ERROR STOP", .marker = "quiet=.true.", .exit = 4 },
};

/// The cases with the adapter `argv` (`zfls dap --gdb GDB` or `--lldb
/// LLDB`) and gfortran `fc`, in `dir`; `gdb`: also the variables
pub fn run(io: Io, gpa: Allocator, argv: []const []const u8, fc: []const u8, dir: []const u8, gdb: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try Io.Dir.cwd().readFileAlloc(io, source, a, .limited(1 << 16));
    const src = try std.Io.Dir.path.join(a, &.{ dir, "runtime.f90" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = text });
    const exe = (try build(io, a, fc, dir, src, "runtime", &.{})) orelse return error.BuildFailed;
    for (cases) |c| try runCase(io, gpa, argv, exe, dir, c, if (c.marker) |m| lineOf(text, m) else 0);
    // on Windows also linked with libgfortran-5.dll, whose functions gdb
    // has no symbols of: the errors raised inside it stop at zfls's
    // breakpoints on its exports (#615), and an I/O error with iostat= not
    if (sysinfo.target.os.tag == .windows) {
        const with_dll = (try build(io, a, fc, dir, src, "runtime_dll", &.{"-shared-libgfortran"})) orelse return error.BuildFailed;
        for (cases) |c| {
            if (!std.mem.eql(u8, c.arg, "seed") and !std.mem.eql(u8, c.arg, "open") and !std.mem.eql(u8, c.arg, "iostat")) continue;
            var dc = c;
            dc.label = try a.print("{s} (DLL)", .{c.arg});
            try runCase(io, gpa, argv, with_dll, dir, dc, if (c.marker) |m| lineOf(text, m) else 0);
        }
    }
    if (gdb) try wide(io, gpa, argv, exe, dir, src, lineOf(text, "stop here: wide"));
    // images as processes of their own (-lcaf_shmem): said at the launch
    try imagesApart(io, gpa, argv, fc, dir);
    // ERROR STOP with -fcoarray=lib, where libcaf_single is there
    const caf_src = try std.Io.Dir.path.join(a, &.{ dir, "caf.f90" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = caf_src, .data = "program caf\n  integer :: x[*]\n  x = 1\n  error stop 'caf'\nend program caf\n" });
    const caf = (try build(io, a, fc, dir, caf_src, "caf", &.{ "-fcoarray=lib", "-lcaf_single" })) orelse {
        std.debug.print("skipped: ERROR STOP with -fcoarray=lib (no libcaf_single)\n", .{});
        return;
    };
    try runCase(io, gpa, argv, caf, dir, .{ .arg = "", .stop = "ERROR STOP", .exit = 1, .label = "-fcoarray=lib" }, 4);
}

/// `src` built into `name` in `dir` with `-g -O0` (compiled, then linked:
/// on macOS `dsymutil` then keeps the debug information); on Windows with
/// libgfortran and libquadmath linked in, as Debug Fortran File builds; null
/// when it does not build
fn build(io: Io, a: Allocator, fc: []const u8, dir: []const u8, src: []const u8, name: []const u8, flags: []const []const u8) !?[]const u8 {
    const windows = sysinfo.target.os.tag == .windows;
    const obj = try std.Io.Dir.path.join(a, &.{ dir, try a.print("{s}.o", .{name}) });
    const exe = try std.Io.Dir.path.join(a, &.{ dir, if (windows) try a.print("{s}.exe", .{name}) else name });
    var compile: std.ArrayList([]const u8) = .empty;
    try compile.appendSlice(a, &.{ fc, "-g", "-O0", "-c", src, "-o", obj });
    // `-shared-libgfortran` (this driver's, not gfortran's): the runtime's
    // DLL (#615)
    for (flags) |f| if (!std.mem.startsWith(u8, f, "-l") and !std.mem.eql(u8, f, "-shared-libgfortran")) try compile.append(a, f);
    var link: std.ArrayList([]const u8) = .empty;
    try link.appendSlice(a, &.{ fc, "-g", obj, "-o", exe });
    for (flags) |f| if (!std.mem.eql(u8, f, "-shared-libgfortran")) try link.append(a, f);
    const dll = for (flags) |f| {
        if (std.mem.eql(u8, f, "-shared-libgfortran")) break true;
    } else false;
    if (windows and !dll) try link.appendSlice(a, &.{ "-static-libgfortran", "-static-libquadmath" });
    for ([_][]const []const u8{ compile.items, link.items }) |cmd| {
        const r = try std.process.run(a, io, .{ .argv = cmd, .cwd = .{ .path = dir } });
        if (!r.term.success()) {
            std.debug.print("{s} failed:\n{s}{s}\n", .{ cmd[0], r.stdout, r.stderr });
            return null;
        }
    }
    if (sysinfo.target.os.tag == .macos) _ = std.process.run(a, io, .{ .argv = &.{ "dsymutil", exe }, .cwd = .{ .path = dir } }) catch {};
    return exe;
}

/// A program of coarrays linked with libcaf_shmem (GCC 16), whose images
/// are child processes: the launch says that the debugger does not follow
/// them, and names `-lcaf_single`; one linked with libcaf_single is not
/// told so (#616). Skipped where there is no libcaf_shmem.
fn imagesApart(io: Io, gpa: Allocator, argv: []const []const u8, fc: []const u8, dir: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.path.join(a, &.{ dir, "images.f90" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = "program images\n  integer :: x[*]\n  x = this_image()\n  print *, x\nend program images\n" });
    for ([_][]const u8{ "shmem", "single" }) |lib| {
        const exe = (try build(io, a, fc, dir, src, try a.print("images_{s}", .{lib}), &.{ "-fcoarray=lib", try a.print("-lcaf_{s}", .{lib}) })) orelse {
            if (std.mem.eql(u8, lib, "shmem")) return std.debug.print("skipped: -lcaf_shmem (GCC 16)\n", .{});
            return error.BuildFailed;
        };
        const c = try Client.start(io, gpa, argv);
        defer c.deinit();
        defer end(c);
        _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
        const launched = try c.send("launch", .{ .program = exe, .cwd = dir });
        _ = try c.event("initialized");
        _ = try c.request("configurationDone", .{});
        _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
        _ = try c.event("exited");
        const said = try c.outputText(a);
        const told = std.mem.find(u8, said, "processes of their own") != null and std.mem.find(u8, said, "-lcaf_single") != null;
        try check(told == std.mem.eql(u8, lib, "shmem"), "-lcaf_{s}: the launch {s} that the images are not followed", .{ lib, if (told) "said" else "did not say" });
    }
}

fn runCase(io: Io, gpa: Allocator, argv: []const []const u8, exe: []const u8, dir: []const u8, case: Case, line: i64) !void {
    const name = case.label orelse case.arg;
    const c = try Client.start(io, gpa, argv);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    const launched = try c.send("launch", .{ .program = exe, .args = if (case.arg.len > 0) &[_][]const u8{case.arg} else &[_][]const u8{}, .cwd = dir });
    _ = try c.event("initialized");
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    var e = try c.eventOf(&.{ "stopped", "exited" });
    var body = get(e, "body").?;
    if (case.stop) |want| {
        try check(eql(str(e, "event"), "stopped") and eql(str(body, "reason"), "exception") and eql(str(body, "description"), want), "{s}: stopped, {s} ({s}: {s})", .{ name, want, str(e, "event").?, str(body, "description") orelse "-" });
        const stack = items(try c.request("stackTrace", .{ .threadId = int(body, "threadId").?, .levels = 20 }), "stackFrames");
        const ours = for (stack) |f| {
            if (int(f, "line") == line and std.mem.endsWith(u8, str(get(f, "source") orelse Value.null, "path") orelse "", ".f90")) break true;
        } else false;
        try check(ours, "{s}: the program's frame at line {d}", .{ name, line });
        _ = try c.request("continue", .{ .threadId = int(body, "threadId").? });
        e = try c.eventOf(&.{ "stopped", "exited" });
        body = get(e, "body").?;
    }
    try check(eql(str(e, "event"), "exited") and int(body, "exitCode") == case.exit, "{s}: then exited with {d} ({s} {?d})", .{ name, case.exit, str(e, "event").?, int(body, "exitCode") });
}

/// gdb: `wide`, a CHARACTER of kind 4 with a character beyond ASCII
fn wide(io: Io, gpa: Allocator, argv: []const []const u8, exe: []const u8, dir: []const u8, src: []const u8, line: i64) !void {
    const c = try Client.start(io, gpa, argv);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    const launched = try c.send("launch", .{ .program = exe, .cwd = dir });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = line }} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const body = get(try c.event("stopped"), "body").?;
    const stack = items(try c.request("stackTrace", .{ .threadId = int(body, "threadId").? }), "stackFrames");
    const scopes = items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes");
    const locals = items(try c.request("variables", .{ .variablesReference = int(scopes[0], "variablesReference").? }), "variables");
    const w = for (locals) |v| {
        if (eql(str(v, "name"), "wide")) break str(v, "value") orelse "?";
    } else "(none)";
    try check(eql(w, "4_'h\u{eb}llo'"), "wide = {s}", .{w});
    const part = try c.request("evaluate", .{ .expression = "wide(2:3)", .frameId = int(stack[0], "id").?, .context = "watch" });
    try check(eql(str(part, "result"), "4_'\u{eb}l'"), "wide(2:3) = {s}", .{str(part, "result") orelse "?"});
}

fn eql(s: ?[]const u8, t: []const u8) bool {
    return std.mem.eql(u8, s orelse return false, t);
}

/// The 1-based line of a marker of the source
fn lineOf(text: []const u8, marker: []const u8) i64 {
    const at = std.mem.find(u8, text, marker) orelse unreachable;
    return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
}

/// Ends the session and the adapter
fn end(c: *Client) void {
    if (c.send("disconnect", .{ .terminateDebuggee = true })) |seq| {
        _ = c.response(seq, "disconnect") catch {};
    } else |_| {}
    c.child.stdin.?.close(c.io);
    c.child.stdin = null;
    _ = c.child.wait(c.io) catch {};
}
