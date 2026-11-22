//! The parts of the tests of `zfls dap` (tests/dap_gdb.zig with gdb,
//! tests/dap_lldb.zig with lldb-dap) that are LFortran's, as far as its
//! debug information goes (DWARF of language C, integer and real scalars
//! only: arrays, derived types, CHARACTER and module variables are #366):
//! building with `lfortran -g`, a session on tests/dap/grid.f90 (line
//! breakpoints, the stack, a step, its integer variables without the
//! compiler's temporaries, no module variables scope, the runtime error of
//! a bound exceeded), and the stop at ERROR STOP, not at STOP, which both
//! tests run for every compiler.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

/// The environment of `lfortran -g`, which runs `llvm-dwarfdump`: this
/// one's with LFortran's own directory first on the PATH (conda-forge's
/// environment has it there, beside `lfortran`, which CI links to from
/// another directory)
pub fn buildEnv(io: Io, a: Allocator, environ: *const std.process.Environ.Map, fc: []const u8) !*const std.process.Environ.Map {
    const exe = try onPath(io, a, environ, fc);
    const real = Io.Dir.cwd().realPathFileAlloc(io, exe, a) catch exe;
    const env = try a.create(std.process.Environ.Map);
    env.* = try environ.clone(a);
    const dir = std.Io.Dir.path.dirname(real) orelse return env;
    const path = environ.get("PATH") orelse "";
    try env.put("PATH", try a.print("{s}{c}{s}", .{ dir, std.Io.Dir.path.delimiter, path }));
    return env;
}

/// `name`, or where the PATH has it when it names no directory
fn onPath(io: Io, a: Allocator, environ: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    if (std.mem.findAny(u8, name, "/\\") != null) return name;
    var it = std.mem.tokenizeScalar(u8, environ.get("PATH") orelse "", std.Io.Dir.path.delimiter);
    while (it.next()) |dir| {
        const p = try std.Io.Dir.path.join(a, &.{ dir, name });
        Io.Dir.cwd().access(io, p, .{}) catch continue;
        return p;
    }
    return name;
}

/// Builds `src` into `out` with `lfortran -g` (its checks of bounds are
/// on by default), in `dir`, where LFortran also writes the files of its
/// stack traces (`out_lines.dat`, ...)
pub fn build(io: Io, a: Allocator, fc: []const u8, env: *const std.process.Environ.Map, dir: []const u8, src: []const u8, out: []const u8) !void {
    const built = try std.process.run(a, io, .{ .argv = &.{ fc, "-g", "-o", out, src }, .cwd = .{ .path = dir }, .environ_map = env });
    if (!built.term.success()) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ fc, built.stdout, built.stderr });
        return error.BuildFailed;
    }
}

/// The places of a session on tests/dap/grid.f90
pub const Session = struct {
    /// The adapter's command line
    argv: []const []const u8,
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    /// The line in `work` (LFortran's PRINT has no line of its own)
    work_line: i64,
    /// The call of `work` in the main program
    call_line: i64,
    main_line: i64,
};

fn eql(x: ?[]const u8, y: []const u8) bool {
    return std.mem.eql(u8, x orelse return false, y);
}

fn inSource(frame: Value, file: []const u8) bool {
    return contains(str(get(frame, "source") orelse Value.null, "path"), file);
}

fn isTemporary(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__libasr") or std.mem.startsWith(u8, name, "__1_") or std.mem.startsWith(u8, name, "lfortran_implied_do_");
}

/// The variables of a frame's scope named `name` (none without it)
fn scopeVariables(c: *Client, frame: i64, name: []const u8) ![]Value {
    const scopes = items(try c.request("scopes", .{ .frameId = frame }), "scopes");
    for (scopes) |sc| if (eql(str(sc, "name"), name))
        return items(try c.request("variables", .{ .variablesReference = int(sc, "variablesReference") orelse 0 }), "variables");
    return &.{};
}

fn show(what: []const u8, vars: []Value) void {
    std.debug.print("   {s}: {d} variables", .{ what, vars.len });
    for (vars) |x| std.debug.print(" {s}={s} ({s})", .{ str(x, "name") orelse "?", str(x, "value") orelse "?", str(x, "type") orelse "-" });
    std.debug.print("\n", .{});
}

/// A session on tests/dap/grid.f90 built by LFortran: line breakpoints,
/// the stack, the main program's variables (integers, without LFortran's
/// temporaries), a step, no module variables scope, and the bound exceeded
/// as a Fortran runtime error
pub fn walkThrough(io: Io, gpa: Allocator, s: Session) !void {
    const c = try Client.start(io, gpa, s.argv);
    defer c.deinit();
    defer c.end(true);

    const caps = try c.request("initialize", .{ .adapterID = "fortran", .clientID = "test", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path", .supportsVariableType = true });
    const filters = items(caps, "exceptionBreakpointFilters");
    try check(filters.len > 0 and eql(str(filters[0], "filter"), "fortranRuntimeErrors"), "the filter of Fortran runtime errors first", .{});
    const launched = try c.send("launch", .{ .program = s.program, .args = [_][]const u8{}, .cwd = s.dir, .sourceRoot = s.dir });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = s.src }, .breakpoints = .{ .{ .line = s.work_line }, .{ .line = s.main_line } } }), "breakpoints");
    try check(bps.len == 2, "two breakpoints", .{});
    for (bps) |b| std.debug.print("   breakpoint: line {?d}, verified {any}\n", .{ int(b, "line"), get(b, "verified") });
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");

    // in work, called from the main program
    var stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    var stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(stack.len >= 2 and inSource(stack[0], "grid.f90") and int(stack[0], "line") == s.work_line, "stopped in work, line {?d} ({s})", .{ int(stack[0], "line"), str(stack[0], "name") orelse "?" });
    try check(inSource(stack[1], "grid.f90") and int(stack[1], "line") == s.call_line, "called at line {?d} ({s})", .{ int(stack[1], "line"), str(stack[1], "name") orelse "?" });
    const scopes = items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes");
    var modvars = false;
    for (scopes) |sc| modvars = modvars or eql(str(sc, "name"), "Module variables");
    try check(!modvars, "no Module variables scope (#366)", .{});
    for (scopes) |sc| {
        if (eql(str(sc, "name"), "Registers") or eql(str(sc, "name"), "Globals")) continue;
        show(str(sc, "name") orelse "?", items(try c.request("variables", .{ .variablesReference = int(sc, "variablesReference") orelse 0 }), "variables"));
    }

    // in the main program: its integers, not the compiler's temporaries
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(stack[0], "line") == s.main_line, "stopped in main ({?d})", .{int(stack[0], "line")});
    var locals = try scopeVariables(c, int(stack[0], "id").?, "Locals");
    show("Locals", locals);
    const temporary: ?Value = for (locals) |x| {
        if (isTemporary(str(x, "name") orelse "")) break x;
    } else null;
    try check(temporary == null, "no temporaries of LFortran's among the locals ({s})", .{if (temporary) |x| str(x, "name") orelse "?" else "none"});
    var k: ?Value = null;
    for (locals) |x| if (eql(str(x, "name"), "k")) {
        k = x;
    };
    try check(k != null, "k among the locals", .{});

    // a step: k = 4
    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(eql(str(stopped, "reason"), "step") and int(stack[0], "line") == s.main_line + 1, "a step to line {?d}", .{int(stack[0], "line")});
    locals = try scopeVariables(c, int(stack[0], "id").?, "Locals");
    k = null;
    for (locals) |x| if (eql(str(x, "name"), "k")) {
        k = x;
    };
    try check(k != null and eql(str(k.?, "value"), "4"), "k = {s} ({s})", .{ if (k) |x| str(x, "value") orelse "?" else "-", if (k) |x| str(x, "type") orelse "-" else "-" });

    // the bound exceeded: a Fortran runtime error
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    try check(eql(str(stopped, "reason"), "exception") and eql(str(stopped, "description"), "Fortran runtime error"), "stopped by a Fortran runtime error ({s}: {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "description") orelse "?" });
    const info = try c.request("exceptionInfo", .{ .threadId = thread });
    try check(eql(str(info, "exceptionId"), "_lcompilers_runtime_error_exit"), "exception info: {s}", .{str(info, "exceptionId") orelse "?"});
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const ours = for (stack) |f| {
        if (!eql(str(f, "presentationHint"), "subtle")) break f;
    } else Value.null;
    try check(ours != .null and inSource(ours, "grid.f90") and int(ours, "line") == s.main_line + 1, "the program's frame first: line {?d}", .{int(ours, "line")});
    _ = try c.request("continue", .{ .threadId = thread });
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 1, "the program exited with 1 ({?d})", .{int(exited, "exitCode")});
}

/// tests/dap/stops.f90, built: the filter of Fortran runtime errors stops
/// at its ERROR STOP 3, which the stop calls so, and not at its STOP 0
/// (`stops plain`)
pub fn errorStop(io: Io, gpa: Allocator, argv: []const []const u8, program: []const u8, dir: []const u8) !void {
    for ([_]bool{ true, false }) |plain| {
        const c = try Client.start(io, gpa, argv);
        defer c.deinit();
        defer c.end(true);
        _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path" });
        const launched = try c.send("launch", .{ .program = program, .args = if (plain) &[_][]const u8{"plain"} else &[_][]const u8{}, .cwd = dir });
        _ = try c.event("initialized");
        _ = try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} });
        _ = try c.request("configurationDone", .{});
        _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
        const e = try c.eventOf(&.{ "stopped", "exited" });
        const body = get(e, "body").?;
        if (plain) {
            try check(eql(str(e, "event"), "exited") and int(body, "exitCode") == 0, "STOP 0: no stop, exited with 0 ({s} {?d})", .{ str(e, "event").?, int(body, "exitCode") });
            continue;
        }
        try check(eql(str(e, "event"), "stopped") and eql(str(body, "reason"), "exception") and eql(str(body, "description"), "ERROR STOP"), "ERROR STOP 3: stopped ({s}: {s}, {s})", .{ str(e, "event").?, str(body, "reason") orelse "-", str(body, "description") orelse "-" });
        const stack = items(try c.request("stackTrace", .{ .threadId = int(body, "threadId").? }), "stackFrames");
        const ours = for (stack) |f| {
            if (!eql(str(f, "presentationHint"), "subtle")) break f;
        } else Value.null;
        try check(ours != .null and inSource(ours, "stops.f90"), "the program's frame first: {s}:{?d}", .{ str(get(ours, "source") orelse Value.null, "path") orelse "?", int(ours, "line") });
        _ = try c.request("continue", .{ .threadId = int(body, "threadId").? });
        const exited = get(try c.event("exited"), "body").?;
        try check(int(exited, "exitCode") == 3, "the program exited with 3 ({?d})", .{int(exited, "exitCode")});
    }
}
