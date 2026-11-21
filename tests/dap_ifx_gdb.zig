//! The parts of tests/dap_gdb.zig that are Intel ifx's on Linux (`--compiler
//! ifx`): building with `ifx -g -O0 -check bounds`, and a session on
//! tests/dap/grid.f90 as far as Intel's DWARF goes in gdb: line
//! breakpoints, the stack, a step, an integer variable, and the stop at the
//! runtime error of a bound exceeded (`for__issue_diagnostic`, #492), and
//! polymorphic objects and arrays by their dynamic type (#667), without
//! the hidden length of a CHARACTER argument (#679), and the module
//! variables (#680). The variables of each stop are shown, for what
//! Intel's DWARF gives gdb.

const std = @import("std");
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

/// Builds `src` into `out` with ifx, its runtime's directory (conda-forge's
/// `<prefix>/lib`) the program's run path
pub fn build(io: Io, a: Allocator, fc: []const u8, dir: []const u8, src: []const u8, out: []const u8) !void {
    const exe = Io.Dir.cwd().realPathFileAlloc(io, fc, a) catch fc;
    const lib = try std.Io.Dir.path.join(a, &.{ std.Io.Dir.path.dirname(exe) orelse ".", "..", "lib" });
    const argv = &.{ fc, "-g", "-O0", "-check", "bounds", try a.print("-Wl,-rpath,{s}", .{lib}), "-o", out, src };
    const built = try std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = dir } });
    if (!built.term.success()) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ fc, built.stdout, built.stderr });
        return error.BuildFailed;
    }
}

pub const Session = struct {
    argv: []const []const u8,
    program: []const u8,
    src: []const u8,
    dir: []const u8,
    work_line: i64,
    call_line: i64,
    main_line: i64,
};

fn eql(s: ?[]const u8, t: []const u8) bool {
    return std.mem.eql(u8, s orelse return false, t);
}

fn inSource(frame: Value, name: []const u8) bool {
    return std.mem.endsWith(u8, str(get(frame, "source") orelse Value.null, "path") orelse "", name);
}

fn end(c: *Client) void {
    if (c.send("disconnect", .{ .terminateDebuggee = true })) |seq| {
        _ = c.response(seq, "disconnect") catch {};
    } else |_| {}
    c.child.stdin.?.close(c.io);
    c.child.stdin = null;
    _ = c.child.wait(c.io) catch {};
}

fn show(name: []const u8, vars: []Value) void {
    std.debug.print("   {s}:", .{name});
    for (vars) |x| std.debug.print(" {s}={s}", .{ str(x, "name") orelse "?", str(x, "value") orelse "?" });
    std.debug.print("\n", .{});
}

fn scopeVariables(c: *Client, frame: i64, name: []const u8) ![]Value {
    for (items(try c.request("scopes", .{ .frameId = frame }), "scopes")) |sc| {
        if (eql(str(sc, "name"), name)) return items(try c.request("variables", .{ .variablesReference = int(sc, "variablesReference") orelse 0 }), "variables");
    }
    return &.{};
}

fn named(vars: []Value, name: []const u8) ?Value {
    for (vars) |x| if (std.ascii.eqlIgnoreCase(str(x, "name") orelse "", name)) return x;
    return null;
}

/// The variables of `module` in the frame's "Module variables" scope
fn moduleVariables(c: *Client, frame: i64, module: []const u8) ![]Value {
    const m = named(try scopeVariables(c, frame, "Module variables"), module) orelse return &.{};
    return items(try c.request("variables", .{ .variablesReference = int(m, "variablesReference") orelse 0 }), "variables");
}

fn checkVariable(vars: []Value, name: []const u8, value: []const u8, evaluate_name: []const u8) !void {
    const v = named(vars, name) orelse Value.null;
    try check(eql(str(v, "value"), value) and eql(str(v, "evaluateName"), evaluate_name), "{s} = {s} ({s})", .{ name, str(v, "value") orelse "?", str(v, "evaluateName") orelse "?" });
}

pub fn walkThrough(io: Io, gpa: Allocator, s: Session) !void {
    const c = try Client.start(io, gpa, s.argv);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .clientID = "test", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path", .supportsVariableType = true });
    const launched = try c.send("launch", .{ .program = s.program, .args = [_][]const u8{}, .cwd = s.dir, .sourceRoot = s.dir });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = s.src }, .breakpoints = .{ .{ .line = s.work_line }, .{ .line = s.main_line } } }), "breakpoints");
    for (bps) |b| std.debug.print("   breakpoint: line {?d}, verified {any}\n", .{ int(b, "line"), get(b, "verified") });
    try check(bps.len == 2, "two breakpoints", .{});
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");

    // in work, called from the main program
    var stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    var stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    for (stack) |f| std.debug.print("   frame {s} {?d}\n", .{ str(f, "name") orelse "?", int(f, "line") });
    try check(stack.len >= 2 and inSource(stack[0], "grid.f90") and int(stack[0], "line") == s.work_line, "stopped in work, line {?d} ({s})", .{ int(stack[0], "line"), str(stack[0], "name") orelse "?" });
    try check(inSource(stack[1], "grid.f90") and int(stack[1], "line") == s.call_line, "called at line {?d} ({s})", .{ int(stack[1], "line"), str(stack[1], "name") orelse "?" });
    for (items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes")) |sc| {
        if (eql(str(sc, "name"), "Registers")) continue;
        show(str(sc, "name") orelse "?", items(try c.request("variables", .{ .variablesReference = int(sc, "variablesReference") orelse 0 }), "variables"));
    }
    const args = try scopeVariables(c, int(stack[0], "id").?, "Arguments");
    // s's hidden length, a local `S.len` of ifx's, left out (#679)
    const s_arg = named(args, "s") orelse Value.null;
    try check(eql(str(s_arg, "value"), "'abcdef'"), "s = {s} ({s})", .{ str(s_arg, "value") orelse "?", str(s_arg, "type") orelse "?" });
    for (try scopeVariables(c, int(stack[0], "id").?, "Locals")) |x| {
        try check(std.mem.findScalar(u8, str(x, "name") orelse "", '.') == null, "no hidden length in Locals: {s}", .{str(x, "name") orelse "?"});
    }
    // polymorphic: t a tagged, ts(:) of labeled, by their descriptors (#667)
    const t = named(args, "t") orelse Value.null;
    try check(eql(str(t, "type"), "class(point)") and std.mem.startsWith(u8, str(t, "value") orelse "", "tagged("), "t: {s} = {s}", .{ str(t, "type") orelse "?", str(t, "value") orelse "?" });
    const tc = items(try c.request("variables", .{ .variablesReference = int(t, "variablesReference") orelse 0 }), "variables");
    const tag = named(tc, "tag") orelse Value.null;
    try check(eql(str(tag, "value"), "'hello   '"), "t%tag = {s}", .{str(tag, "value") orelse "?"});
    const ts = named(args, "ts") orelse Value.null;
    try check(eql(str(ts, "type"), "class(point) (2)") and eql(str(ts, "value"), "[labeled(…), labeled(…)]"), "ts: {s} = {s}", .{ str(ts, "type") orelse "?", str(ts, "value") orelse "?" });
    // module grid's variables, its private one and COMMON block's too (#680)
    const grid = try moduleVariables(c, int(stack[0], "id").?, "grid");
    show("grid", grid);
    try checkVariable(grid, "ncells", "42", "grid::ncells");
    try checkVariable(grid, "secret", "99", "grid::secret");
    try checkVariable(grid, "origin", "point(x=9.0, y=-2.0, id=7)", "grid::origin");
    try checkVariable(grid, "gname", "'grid name'", "grid::gname");
    try checkVariable(grid, "cx", "1.5", "grid::cx");
    try checkVariable(grid, "cy", "2.5", "grid::cy");

    // in the main program
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(stack[0], "line") == s.main_line, "stopped in main ({?d})", .{int(stack[0], "line")});
    const main_locals = try scopeVariables(c, int(stack[0], "id").?, "Locals");
    show("Locals", main_locals);
    // class(point), allocatable :: pts(:), of labeled (#667)
    const pts = named(main_locals, "pts") orelse Value.null;
    try check(eql(str(pts, "type"), "class(point) (2)") and eql(str(pts, "value"), "[labeled(…), labeled(…)]"), "pts: {s} = {s}", .{ str(pts, "type") orelse "?", str(pts, "value") orelse "?" });
    // the modules it uses: grid's public variables, and counters' renamed (#680)
    const main_grid = try moduleVariables(c, int(stack[0], "id").?, "grid");
    show("grid", main_grid);
    try checkVariable(main_grid, "ncells", "42", "grid::ncells");
    try check(named(main_grid, "secret") == null, "no private secret in main", .{});
    try checkVariable(try moduleVariables(c, int(stack[0], "id").?, "counters"), "nhits => hits", "3", "counters::hits");

    // a step: k = 4
    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(eql(str(stopped, "reason"), "step") and int(stack[0], "line") == s.main_line + 1, "a step to line {?d}", .{int(stack[0], "line")});
    const locals = try scopeVariables(c, int(stack[0], "id").?, "Locals");
    const k = named(locals, "k");
    try check(k != null and eql(str(k.?, "value"), "4"), "k = {s} ({s})", .{ if (k) |x| str(x, "value") orelse "?" else "-", if (k) |x| str(x, "type") orelse "-" else "-" });

    // the bound exceeded: a Fortran runtime error, in Intel's runtime
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    try check(eql(str(stopped, "reason"), "exception") and eql(str(stopped, "description"), "Fortran runtime error"), "stopped by a Fortran runtime error ({s}: {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "description") orelse "?" });
    const info = try c.request("exceptionInfo", .{ .threadId = thread });
    try check(eql(str(info, "exceptionId"), "for__issue_diagnostic"), "exception info: {s}", .{str(info, "exceptionId") orelse "?"});
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const ours = for (stack) |f| {
        if (inSource(f, "grid.f90")) break f;
    } else Value.null;
    try check(ours != .null and int(ours, "line") == s.main_line + 1, "the program's frame: line {?d}", .{int(ours, "line")});
    _ = try c.request("continue", .{ .threadId = thread });
    const e = try c.eventOf(&.{ "stopped", "exited" });
    std.debug.print("   then: {s} {?d}\n", .{ str(e, "event") orelse "?", int(get(e, "body") orelse Value.null, "exitCode") });
}
