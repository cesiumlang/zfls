//! zfls dap with gdb, for tests/dap_gdb.zig: gdb's C++ exception filters
//! (`throw`, `rethrow`, `catch`) only for a program that links a C++
//! runtime (#747): none for a Fortran program, given back in a
//! `capabilities` event at the launch of one of Fortran and C++ (g++'s,
//! linked with libstdc++), and for the Fortran one too with
//! `cppExceptionFilters: true`.

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

pub const Programs = struct {
    /// `zfls dap` with its gdb
    argv: []const []const u8,
    dir: []const u8,
    /// gfortran
    fc: []const u8,
    /// gfortran's program of Fortran alone
    fortran: []const u8,
};

pub fn run(io: Io, gpa: Allocator, p: Programs) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const mixed = try build(io, arena.allocator(), p) orelse return;
    try session(io, gpa, p, p.fortran, false, false, "a Fortran program");
    try session(io, gpa, p, mixed, false, true, "a program of Fortran and C++");
    try session(io, gpa, p, p.fortran, true, true, "a Fortran program, cppExceptionFilters: true");
}

/// tests/dap/mixed.f90 with tests/dap/twice.cpp, by g++ (the one next to
/// gfortran, else the PATH's) and gfortran with libstdc++; null without g++
fn build(io: Io, a: Allocator, p: Programs) !?[]const u8 {
    const ext = if (sysinfo.target.os.tag == .windows) ".exe" else "";
    const gxx = if (std.Io.Dir.path.dirname(p.fc)) |d| try std.Io.Dir.path.join(a, &.{ d, try a.print("g++{s}", .{ext}) }) else "g++";
    const cpp = try std.Io.Dir.path.join(a, &.{ p.dir, "twice.cpp" });
    const obj = try std.Io.Dir.path.join(a, &.{ p.dir, "twice.o" });
    const f90 = try std.Io.Dir.path.join(a, &.{ p.dir, "mixed.f90" });
    const mixed = try std.Io.Dir.path.join(a, &.{ p.dir, try a.print("mixed{s}", .{ext}) });
    for ([_][2][]const u8{ .{ "tests/dap/twice.cpp", cpp }, .{ "tests/dap/mixed.f90", f90 } }) |x|
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = x[1], .data = try Io.Dir.cwd().readFileAlloc(io, x[0], a, .limited(1 << 16)) });
    for ([_][]const []const u8{ &.{ gxx, "-g", "-c", cpp, "-o", obj }, &.{ p.fc, "-g", f90, obj, "-lstdc++", "-o", mixed } }) |argv| {
        const r = std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = p.dir } }) catch {
            std.debug.print("skipped: no {s}\n", .{argv[0]});
            return null;
        };
        if (!r.term.success()) {
            std.debug.print("{s} failed:\n{s}{s}\n", .{ argv[0], r.stdout, r.stderr });
            return error.BuildFailed;
        }
    }
    return mixed;
}

fn session(io: Io, gpa: Allocator, p: Programs, program: []const u8, forced: bool, want: bool, what: []const u8) !void {
    const c = try Client.start(io, gpa, p.argv);
    defer c.deinit();
    defer c.end(true);
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
    try check(!hasCpp(items(caps, "exceptionBreakpointFilters")), "{s}: no C++ filters at initialize", .{what});
    const launched = try c.send("launch", .{ .program = program, .cwd = p.dir, .cppExceptionFilters = if (forced) true else null });
    _ = try c.event("initialized");
    _ = try c.request("configurationDone", .{});
    const r = try c.response(launched, "launch");
    _ = try Client.bodyOf(r, "launch");
    _ = try c.event("exited");
    // the capabilities event, if any, came before the launch's answer
    var shown = false;
    var filters: usize = 0;
    c.mutex.lockUncancelable(c.io);
    for (c.events.items) |e| {
        if (!std.mem.eql(u8, str(e, "event") orelse "", "capabilities")) continue;
        const f = items(get(get(e, "body").?, "capabilities").?, "exceptionBreakpointFilters");
        shown = hasCpp(f);
        filters = f.len;
    }
    c.mutex.unlock(c.io);
    try check(shown == want, "{s}: C++ filters {s} ({d} filters)", .{ what, if (want) "given at the launch" else "not given", filters });
}

fn hasCpp(filters: []Value) bool {
    for (filters) |f| for ([_][]const u8{ "throw", "rethrow", "catch" }) |n| {
        if (std.mem.eql(u8, str(f, "filter") orelse "", n)) return true;
    };
    return false;
}
