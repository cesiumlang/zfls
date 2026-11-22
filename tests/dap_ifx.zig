//! zfls dap over Windows's Debugger Engine on Intel ifx's programs, for
//! tests/dap_windows.zig (`--ifx IFX`): tests/dap/grid.f90 and stops.f90
//! built with `/Zi /Od /check:bounds` (CodeView) and linked with zfls's
//! ifx kit, Visual Studio hidden (`-lldignoreenv`, empty `-vctoolsdir` and
//! `-winsdkdir`, and a check of what lld-link read). The breakpoints,
//! stopAtEntry, the stack, the variables (dummy arguments through Intel's
//! descriptors, CHARACTER(*), the main program's, module variables),
//! stepping, a runtime error that stops once (the runtime's own `int 3`
//! after it is not a second stop), and ERROR STOP (`for_error_stop_quiet`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const zfls = @import("zfls");
const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const check = dap.check;
const w = @import("dap_windows.zig");
const dap_completions = @import("dap_completions.zig");
const dap_engine_conditions = @import("dap_engine_conditions.zig");
const dap_data = @import("dap_data.zig");
const named = w.named;
const valueOf = w.valueOf;
const scopeVariables = w.scopeVariables;
const moduleVariables = w.moduleVariables;
const lineOf = w.lineOf;

/// The ifx leg: its exit code (0 when ifx is not there)
pub fn run(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, exe_zfls: []const u8, ifx: []const u8, tmp_given: []const u8, kit: []const u8) !u8 {
    const version = std.process.run(a, io, .{ .argv = &.{ ifx, "/QV" } }) catch {
        std.debug.print("ifx: skipped: no {s}\n", .{ifx});
        return 0;
    };
    const banner = if (version.stderr.len > 0) version.stderr else version.stdout;
    std.debug.print("-- {s}\n", .{std.mem.trimEnd(u8, banner[0 .. std.mem.findScalar(u8, banner, '\n') orelse banner.len], "\r")});
    // built by the long path, so that the PDB names it; the source root as
    // given, also by its short path (`EMANSP~1`, as `%TEMP%` gives it),
    // which zfls indexes by the long one (#614)
    const tmp = tmp_given;
    const long = try zfls.paths.longName(a, try a.dupe(u8, tmp_given));
    const env = try environment(io, a, environ, ifx);
    const grid = (try build(io, a, ifx, env, kit, long, "grid")) orelse return 1;
    {
        const c = try Client.startEnv(io, gpa, &.{ exe_zfls, "dap" }, env);
        defer c.deinit();
        runGrid(c, grid.exe, tmp, grid.src, grid.text) catch |e| {
            std.debug.print("zfls dap, ifx's program: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    dap_completions.run(io, gpa, .{ .argv = &.{ exe_zfls, "dap" }, .env = env, .program = grid.exe, .src = grid.src, .dir = tmp, .work_line = lineOf(grid.text, "stop here: work"), .engine = true }) catch |e| {
        std.debug.print("zfls dap, ifx's program, completions: {s}\n", .{@errorName(e)});
        return 1;
    };
    dap_engine_conditions.run(io, gpa, .{ .argv = &.{ exe_zfls, "dap" }, .env = env, .program = grid.exe, .src = grid.src, .dir = tmp, .loop_line = lineOf(grid.text, "m(:, k) = [10*k, 20*k]"), .main_line = lineOf(grid.text, "stop here: main") }) catch |e| {
        std.debug.print("zfls dap, ifx's program, conditions: {s}\n", .{@errorName(e)});
        return 1;
    };
    dap_data.run(io, gpa, .{ .argv = &.{ exe_zfls, "dap" }, .env = env, .program = grid.exe, .src = grid.src, .dir = tmp, .engine = true }) catch |e| {
        std.debug.print("zfls dap, ifx's program, data breakpoints: {s}\n", .{@errorName(e)});
        return 1;
    };
    const stops = (try build(io, a, ifx, env, kit, tmp, "stops")) orelse return 1;
    for ([_]bool{ false, true }) |plain| {
        const c = try Client.startEnv(io, gpa, &.{ exe_zfls, "dap" }, env);
        defer c.deinit();
        w.runStops(c, stops.exe, tmp, plain, lineOf(stops.text, "error stop 3")) catch |e| {
            std.debug.print("zfls dap, ifx's STOP and ERROR STOP: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    std.debug.print("zfls dap, ifx's program: all good\n", .{});
    return 0;
}

/// The environment of ifx and of its programs: without Visual Studio's
/// variables, nor LIB and LINK; ifx's directory first on the PATH (its
/// runtime's DLLs)
fn environment(io: Io, a: Allocator, environ: *const std.process.Environ.Map, ifx: []const u8) !*const std.process.Environ.Map {
    const env = try dap.withoutVisualStudio(a, environ);
    for ([_][]const u8{ "LIB", "LINK" }) |v| _ = env.swapRemove(v);
    const exe = Io.Dir.cwd().realPathFileAlloc(io, ifx, a) catch ifx;
    if (std.Io.Dir.path.dirname(exe)) |dir| {
        try env.put("PATH", try a.print("{s}{c}{s}", .{ dir, std.Io.Dir.path.delimiter, environ.get("PATH") orelse "" }));
    }
    return env;
}

/// tests/dap/NAME.f90, copied to `tmp` and built there with `/Zi`: its
/// text, its copy and the program; null when it does not build or when the
/// link read a file of Visual Studio's
fn build(io: Io, a: Allocator, ifx: []const u8, env: *const std.process.Environ.Map, kit: []const u8, tmp: []const u8, name: []const u8) !?struct { text: []const u8, src: []const u8, exe: []const u8 } {
    const cwd = Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, try a.print("tests/dap/{s}.f90", .{name}), a, .limited(1 << 20));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, try a.print("{s}.f90", .{name}) });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    const exe = try std.Io.Dir.path.join(a, &.{ tmp, try a.print("{s}.exe", .{name}) });
    const empty = try std.Io.Dir.path.join(a, &.{ tmp, "no-visual-studio" });
    try cwd.createDirPath(io, empty);
    // its runtime's import libraries: <prefix>\Library\lib beside
    // <prefix>\Library\bin\ifx.exe (conda-forge's)
    const real = cwd.realPathFileAlloc(io, ifx, a) catch ifx;
    const lib = try std.Io.Dir.path.join(a, &.{ std.Io.Dir.path.dirname(real) orelse ".", "..", "lib" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ ifx, "/nologo", "/Zi", "/Od", "/check:bounds", "/MD", "/fuse-ld=lld" });
    for ([_][]const u8{
        "-lldignoreenv",
        try a.print("-vctoolsdir:{s}", .{empty}),
        try a.print("-winsdkdir:{s}", .{empty}),
        try a.print("/LIBPATH:{s}", .{lib}),
        try a.print("/LIBPATH:{s}", .{kit}),
        try std.Io.Dir.path.join(a, &.{ kit, "zfls_ifx_shim.obj" }),
        "-verbose",
    }) |o| try argv.append(a, try a.print("/Qoption,link,{s}", .{o}));
    try argv.appendSlice(a, &.{ try a.print("/exe:{s}", .{exe}), src });
    const built = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = tmp }, .environ_map = env });
    if (!built.term.success()) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ ifx, built.stdout, built.stderr });
        return null;
    }
    if (dap.visualStudioRead(built.stderr) orelse dap.visualStudioRead(built.stdout)) |line| {
        std.debug.print("FAIL: the link of {s} with the ifx kit read Visual Studio's files: {s}\n", .{ name, line });
        return null;
    }
    return .{ .text = text, .src = src, .exe = exe };
}

fn evaluate(c: *Client, frame: Value, expr: []const u8) ![]const u8 {
    const r = try c.request("evaluate", .{ .expression = expr, .frameId = int(frame, "id").?, .context = "watch" });
    return str(r, "result") orelse "?";
}

fn runGrid(c: *Client, exe: []const u8, tmp: []const u8, src: []const u8, text: []const u8) !void {
    const work_line = lineOf(text, "stop here: work");
    const main_line = lineOf(text, "stop here: main");
    const call_line = lineOf(text, "call work(");
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = tmp, .dbgeng = true, .stopAtEntry = true });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{ .{ .line = work_line }, .{ .line = main_line } } }), "breakpoints");
    var verified: usize = 0;
    for (bps) |b| verified += @intFromBool((get(b, "verified") orelse Value{ .bool = false }).bool);
    try check(verified == 2, "two verified breakpoints ({d})", .{verified});
    // the filter of Fortran runtime errors: on Intel's runtime functions
    // (`for__issue_diagnostic`, `for_error_stop_quiet`)
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} });
    _ = try c.request("configurationDone", .{});

    // stopAtEntry: in the main program (`MAIN__`), at its PROGRAM statement
    var stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    var frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const program_line = lineOf(text, "program main");
    try check(frames.len > 0 and std.mem.eql(u8, str(frames[0], "name") orelse "", "MAIN") and int(frames[0], "line") == program_line, "stopAtEntry: in MAIN at line {d} ({s}:{?d})", .{ program_line, if (frames.len > 0) str(frames[0], "name") orelse "?" else "none", if (frames.len > 0) int(frames[0], "line") else null });
    // a deferred-length CHARACTER not yet allocated: its descriptor's
    // address is 0
    const at_entry = try scopeVariables(c, items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes"), "Locals");
    try check(std.mem.eql(u8, valueOf(at_entry, "dl"), "not allocated"), "at the start, dl = not allocated ({s})", .{valueOf(at_entry, "dl")});
    _ = try c.request("continue", .{ .threadId = thread });

    // in work, called by the main program
    stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint"), "stopped at a breakpoint", .{});
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 1 and std.mem.eql(u8, str(frames[0], "name") orelse "", "GRID::WORK") and int(frames[0], "line") == work_line, "in GRID::WORK at line {d} ({s}:{?d})", .{ work_line, str(frames[0], "name") orelse "?", int(frames[0], "line") });
    try check(std.mem.eql(u8, str(frames[1], "name") orelse "", "MAIN") and int(frames[1], "line") == call_line, "called by MAIN at line {d} ({s}:{?d})", .{ call_line, str(frames[1], "name") orelse "?", int(frames[1], "line") });
    var scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    // work's dummy arguments: Intel passes their addresses; arrays by
    // Intel's descriptors; CHARACTER(*) with its hidden length (`_.t6_`)
    const args = try scopeVariables(c, scopes, "Locals");
    try check(std.mem.eql(u8, valueOf(args, "p"), "point(x=9.0, y=-2.0, id=7)"), "p = point(x=9.0, y=-2.0, id=7) ({s})", .{valueOf(args, "p")});
    try check(std.mem.eql(u8, valueOf(args, "s"), "'abcdef'"), "s = 'abcdef' ({s})", .{valueOf(args, "s")});
    try check(std.mem.eql(u8, valueOf(args, "a"), "[6.0, 2.0, 3.0]"), "a = [6.0, 2.0, 3.0] ({s})", .{valueOf(args, "a")});
    try check(std.mem.eql(u8, valueOf(args, "b"), "[2×3]"), "b = [2×3] ({s})", .{valueOf(args, "b")});
    // CLASS(point) of a tagged: its dynamic type, whose description
    // Intel's descriptor points at (`GRID#TAGGED`)
    const t = named(args, "t");
    try check(t != null and std.mem.eql(u8, str(t.?, "type") orelse "", "CLASS(point)") and std.mem.startsWith(u8, valueOf(args, "t"), "tagged("), "t: CLASS(point) = tagged(…) ({s})", .{valueOf(args, "t")});
    const tc = items(try c.request("variables", .{ .variablesReference = int(t.?, "variablesReference").? }), "variables");
    try check(std.mem.eql(u8, valueOf(tc, "tag"), "'hello   '") and std.mem.eql(u8, valueOf(tc, "w"), "[0.25, 0.25]"), "t%tag = 'hello   ', t%w = [0.25, 0.25] ({s}, {s})", .{ valueOf(tc, "tag"), valueOf(tc, "w") });
    const tid = try evaluate(c, frames[0], "t%point%id");
    try check(std.mem.eql(u8, tid, "7"), "t%point%id = 7 ({s})", .{tid});
    // CLASS(point) array of labeled
    try check(std.mem.eql(u8, valueOf(args, "ts"), "[labeled(…), labeled(…)]"), "ts = [labeled(…), labeled(…)] ({s})", .{valueOf(args, "ts")});
    const ts2 = try evaluate(c, frames[0], "ts(2)%label");
    try check(std.mem.eql(u8, ts2, "5"), "ts(2)%label = 5 ({s})", .{ts2});
    const b_cols = items(try c.request("variables", .{ .variablesReference = int(named(args, "b").?, "variablesReference").? }), "variables");
    try check(std.mem.eql(u8, valueOf(b_cols, "(:,1)"), "[-10, -20]"), "b(:,1) = [-10, -20] ({s})", .{valueOf(b_cols, "(:,1)")});
    const b21 = try evaluate(c, frames[0], "b(2,1)");
    try check(std.mem.eql(u8, b21, "-20"), "b(2,1) = -20 ({s})", .{b21});
    // the module variables, by Intel's names (`GRID_mp_NCELLS`)
    const grid = try moduleVariables(c, scopes, "grid");
    try check(std.mem.eql(u8, valueOf(grid, "ncells"), "42"), "grid::ncells = 42 ({s})", .{valueOf(grid, "ncells")});
    const ncells = try evaluate(c, frames[0], "grid::ncells");
    try check(std.mem.eql(u8, ncells, "42"), "evaluate grid::ncells = 42 ({s})", .{ncells});
    // module variables by their own names (host association), which the
    // frame does not have: a variable, a component, a COMMON variable of
    // the module (at the block's symbol `BLK` plus its offset)
    for ([_][2][]const u8{ .{ "ncells", "42" }, .{ "origin%x", "9.0" }, .{ "cy", "2.5" } }) |x| {
        const r = try evaluate(c, frames[0], x[0]);
        try check(std.mem.eql(u8, r, x[1]), "evaluate {s} = {s} ({s})", .{ x[0], x[1], r });
    }
    try check(std.mem.eql(u8, valueOf(grid, "cx"), "1.5") and std.mem.eql(u8, valueOf(grid, "cy"), "2.5"), "grid::cx = 1.5, grid::cy = 2.5 ({s}, {s})", .{ valueOf(grid, "cx"), valueOf(grid, "cy") });

    // next to END SUBROUTINE, then back to the main program: in its CALL
    // line (the rest of the CALL statement's code), or the next
    _ = try c.request("next", .{ .threadId = thread });
    _ = try c.event("stopped");
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(frames[0], "name") orelse "", "GRID::WORK") and int(frames[0], "line") == work_line + 1, "next: GRID::WORK:{d} ({s}:{?d})", .{ work_line + 1, str(frames[0], "name") orelse "?", int(frames[0], "line") });
    _ = try c.request("next", .{ .threadId = thread });
    _ = try c.event("stopped");
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const back = int(frames[0], "line") orelse 0;
    try check(std.mem.eql(u8, str(frames[0], "name") orelse "", "MAIN") and (back == call_line or back == call_line + 1), "next: back in MAIN at line {d} or {d} ({s}:{d})", .{ call_line, call_line + 1, str(frames[0], "name") orelse "?", back });

    // in the main program: its variables, a step
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(frames[0], "name") orelse "", "MAIN") and int(frames[0], "line") == main_line, "in MAIN at line {d} ({s}:{?d})", .{ main_line, str(frames[0], "name") orelse "?", int(frames[0], "line") });
    scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    const locals = try scopeVariables(c, scopes, "Locals");
    const want = [_][2][]const u8{
        .{ "k", "2" },
        .{ "ip", "5" },
        .{ "m", "[2×3]" },
        .{ "v", "[6.0, 2.0, 3.0]" },
        .{ "big", "[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, …]" },
        .{ "none", "not allocated" },
        .{ "nothing", "not associated" },
        .{ "goal", "5" },
        .{ "tg", "tagged(point=…, tag='hello   ', w=…)" },
        .{ "lb", "labeled(point=…, label=5)" },
        // Intel's frame has its USE'd module variable by its local name
        .{ "nhits", "3" },
        // a deferred-length CHARACTER: a descriptor of rank 0 (its
        // address and length)
        .{ "dl", "'deferred'" },
    };
    for (want) |x| try check(std.mem.eql(u8, valueOf(locals, x[0]), x[1]), "{s} = {s} ({s})", .{ x[0], x[1], valueOf(locals, x[0]) });
    const big = items(try c.request("variables", .{ .variablesReference = int(named(locals, "big").?, "variablesReference").? }), "variables");
    try check(big.len == 10 and std.mem.eql(u8, str(big[9], "name") orelse "", "(901:1000)"), "big in 10 sections, the last (901:1000) ({d})", .{big.len});
    const tgw = try evaluate(c, frames[0], "tg%w");
    try check(std.mem.eql(u8, tgw, "[0.25, 0.25]"), "tg%w = [0.25, 0.25] ({s})", .{tgw});
    // an allocatable CLASS(point) array of labeled: its descriptor's
    // elements are the type's forward reference in CodeView (#499), and
    // their dynamic type's description follows the dimensions
    try check(std.mem.eql(u8, valueOf(locals, "pts"), "[labeled(…), labeled(…)]"), "pts = [labeled(…), labeled(…)] ({s})", .{valueOf(locals, "pts")});
    const pts = items(try c.request("variables", .{ .variablesReference = int(named(locals, "pts").?, "variablesReference").? }), "variables");
    try check(pts.len == 2 and std.mem.eql(u8, valueOf(pts, "(1)"), "labeled(point=…, label=5)"), "pts(1) = labeled(point=…, label=5) ({s})", .{valueOf(pts, "(1)")});
    const pts2 = try evaluate(c, frames[0], "pts(2)%point%id");
    try check(std.mem.eql(u8, pts2, "7"), "pts(2)%point%id = 7 ({s})", .{pts2});
    // a substring, and a module's deferred-length CHARACTER
    const dl = try evaluate(c, frames[0], "dl(2:4)");
    try check(std.mem.eql(u8, dl, "'efe'"), "dl(2:4) = 'efe' ({s})", .{dl});
    const main_grid = try moduleVariables(c, scopes, "grid");
    try check(std.mem.eql(u8, valueOf(main_grid, "gname"), "'grid name'"), "grid::gname = 'grid name' ({s})", .{valueOf(main_grid, "gname")});
    // by use association; a module's deferred-length CHARACTER by `::`,
    // with its declaration
    for ([_][2][]const u8{ .{ "ncells", "42" }, .{ "grid::gname", "'grid name'" }, .{ "grid::cy", "2.5" } }) |x| {
        const r = try evaluate(c, frames[0], x[0]);
        try check(std.mem.eql(u8, r, x[1]), "evaluate {s} = {s} ({s})", .{ x[0], x[1], r });
    }
    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and int(frames[0], "line") == main_line + 1, "next: line {d} ({?d})", .{ main_line + 1, int(frames[0], "line") });

    // `m(k, -1) = 0` with k = 4, out of m's bounds (`/check:bounds`): the
    // filter stops where Intel's runtime reports it, once (#493)
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "exception") and std.mem.eql(u8, str(stopped, "description") orelse "", "Fortran runtime error"), "stopped by the filter: a Fortran runtime error ({s}: {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "description") orelse "?" });
    const info = try c.request("exceptionInfo", .{ .threadId = thread });
    try check(std.mem.eql(u8, str(info, "exceptionId") orelse "", "for__issue_diagnostic"), "at Intel's for__issue_diagnostic ({s})", .{str(info, "exceptionId") orelse "?"});
    frames = items(try c.request("stackTrace", .{ .threadId = thread, .levels = 40 }), "stackFrames");
    const at = for (frames, 0..) |f, j| {
        if (std.mem.eql(u8, str(f, "name") orelse "", "MAIN") and int(f, "line") == main_line + 1) break j;
    } else null;
    try check(at != null, "called at line {d} of MAIN", .{main_line + 1});
    var buf: [512]u8 = undefined;
    try check(w.toStart(frames[at.? + 1 ..]), "MAIN, then main, mainCRTStartup ({s})", .{w.frameNames(&buf, frames[at.? + 1 ..])});
    _ = try c.request("continue", .{ .threadId = thread });
    const end = try c.eventOf(&.{ "stopped", "exited" });
    try check(std.mem.eql(u8, str(end, "event") orelse "", "exited"), "then no second stop: the program exits ({s})", .{str(end, "event") orelse "?"});
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
}
