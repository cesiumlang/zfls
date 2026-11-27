//! zfls dap with lldb-dap, on a program of gfortran's (tests/dap/grid.f90,
//! built with -fcheck=bounds): line breakpoints, function breakpoints'
//! verified states in their order, a step, the stack, the
//! program's output, a Fortran runtime error, stopping at the start, the
//! program's exit, a stop at ERROR STOP and none at STOP
//! (tests/dap/stops.f90), attaching to a running program and (with
//! script(1)) the program in a terminal (`zig build test-dap-lldb`). lldb
//! reads no Fortran: the test shows what lldb gives as variables and checks
//! nothing of them. Or on LFortran's (`--compiler lfortran`), whose
//! session is tests/dap_lfortran.zig's, with its integer variables. Skipped
//! without the compiler or lldb-dap. On Windows, lldb-dap before LLVM
//! 23.1.6, which tells no stop (#374, #452), only that zfls refuses it.
//!
//!     dap_lldb --zfls ZFLS [--compiler gfortran|lfortran] [--fc FC] [--lldb LLDB_DAP]
//!
//! GFORTRAN (or LFORTRAN) and LLDB_DAP in the environment name them too
//! (`--gfortran FC` is `--fc FC`); else lldb-dap is found as zfls dap finds
//! it (xcrun on macOS, then the PATH).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

const dap = @import("dap_client.zig");
const dap_lfortran = @import("dap_lfortran.zig");
const dap_gfortran = @import("dap_gfortran.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

const source = "tests/dap/grid.f90";

const Compiler = enum { gfortran, lfortran };

const Setup = struct {
    zfls: []const u8,
    lldb: []const u8,
    compiler: Compiler,
    /// The compiler's executable
    fc: []const u8,
    /// LFortran's build environment (its directory on the PATH)
    build_env: ?*const std.process.Environ.Map,
    dir: []const u8,
    src: []const u8,
    program: []const u8,
    work_line: i64,
    call_line: i64,
    main_line: i64,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var lldb: ?[]const u8 = init.environ_map.get("LLDB_DAP");
    var compiler: ?Compiler = .gfortran;
    var fc_arg: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--lldb")) {
            lldb = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--compiler")) {
            compiler = std.meta.stringToEnum(Compiler, argv[i + 1]);
        } else if (std.mem.eql(u8, argv[i], "--fc") or std.mem.eql(u8, argv[i], "--gfortran")) {
            fc_arg = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null or compiler == null) {
        std.debug.print("usage: dap_lldb --zfls ZFLS [--compiler gfortran|lfortran] [--fc FC] [--lldb LLDB_DAP]\n", .{});
        return 2;
    }
    const fc = fc_arg orelse switch (compiler.?) {
        .gfortran => init.environ_map.get("GFORTRAN") orelse "gfortran",
        .lfortran => init.environ_map.get("LFORTRAN") orelse "lfortran",
    };
    const lldb_dap = try zfls.dap_lldb.find(a, io, init.environ_map, lldb) orelse {
        std.debug.print("skipped: no lldb-dap (xcrun --find lldb-dap, or lldb-dap or lldb-vscode on the PATH)\n", .{});
        return 0;
    };
    // an older lldb-dap on Windows is refused, with a word of gdb and the
    // Debugger Engine, and no session waits (#374)
    if (builtin.target.os.tag == .windows and try zfls.dap_lldb_windows.refusal(a, io, init.environ_map, lldb_dap) != null)
        return refusedOnWindows(io, init.gpa, try Io.Dir.cwd().realPathFileAlloc(io, zfls_exe.?, a), lldb_dap);
    const fc_version = std.process.run(a, io, .{ .argv = &.{ fc, "--version" } }) catch {
        std.debug.print("skipped: no {s}\n", .{fc});
        return 0;
    };
    std.debug.print("{s}\n", .{std.mem.trimEnd(u8, fc_version.stdout[0 .. std.mem.findScalar(u8, fc_version.stdout, '\n') orelse fc_version.stdout.len], "\r")});

    const cwd = Io.Dir.cwd();
    const tmp = try lsp.tempDir(io, a, init.environ_map, "zfls-dap-lldb-");
    defer cwd.deleteTree(io, tmp) catch {};
    const text = try cwd.readFileAlloc(io, source, a, .limited(1 << 20));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, "grid.f90" });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    var setup: Setup = .{
        .zfls = try cwd.realPathFileAlloc(io, zfls_exe.?, a),
        .lldb = lldb_dap,
        .compiler = compiler.?,
        .fc = fc,
        .build_env = if (compiler.? == .lfortran) try dap_lfortran.buildEnv(io, a, init.environ_map, fc) else null,
        .dir = tmp,
        .src = src,
        .program = "",
        // LFortran's PRINT has no line: its stop in work is a line before
        .work_line = lineOf(text, if (compiler.? == .lfortran) "LFortran stops here" else "stop here: work"),
        .call_line = lineOf(text, "call work("),
        .main_line = lineOf(text, "stop here: main"),
    };
    setup.program = try build(io, a, setup, "grid", &.{ "-O0", "-fcheck=bounds" }) orelse return 1;
    std.debug.print("{s}, {s}\n", .{ setup.program, lldb_dap });

    var failed = false;
    inline for (.{ .{ "a session", walkThrough }, .{ "stopping at the start", atEntry }, .{ "ERROR STOP, not STOP", errorStop }, .{ "gfortran's runtime errors and stops", gfortranRuntime }, .{ "attaching", attach }, .{ "a terminal", terminal } }) |t| {
        std.debug.print("-- {s}\n", .{t[0]});
        t[1](io, init.gpa, setup) catch |e| {
            std.debug.print("{s}: {s}\n", .{ t[0], @errorName(e) });
            failed = true;
        };
    }
    if (failed) return 1;
    std.debug.print("zfls dap with lldb-dap: all good\n", .{});
    return 0;
}

/// On Windows, a launch with lldb-dap before LLVM 23.1.6 fails at once,
/// naming gdb and the Debugger Engine: that lldb-dap tells no stop until it
/// is asked something else (#374)
fn refusedOnWindows(io: Io, gpa: Allocator, zfls_exe: []const u8, lldb_dap: []const u8) !u8 {
    const c = try Client.start(io, gpa, &.{ zfls_exe, "dap" });
    defer c.deinit();
    defer {
        if (c.send("disconnect", .{})) |seq| {
            _ = c.response(seq, "disconnect") catch {};
        } else |_| {}
        c.child.stdin.?.close(io);
        c.child.stdin = null;
        _ = c.child.wait(io) catch {};
    }
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path" });
    const r = try c.response(try c.send("launch", .{ .program = "C:\\no\\such.exe", .lldb = lldb_dap }), "launch");
    const ok = if (get(r, "success")) |v| v == .bool and v.bool else false;
    const message = str(r, "message") orelse "";
    check(!ok and contains(message, "23.1.6") and contains(message, "gdb") and contains(message, "dbgeng"), "an older lldb-dap refused on Windows: {s}", .{message}) catch return 1;
    std.debug.print("zfls dap with lldb-dap: one before LLVM 23.1.6 refused on Windows, as it should be\n", .{});
    return 0;
}

/// Builds `dir/name.f90` with debug information. gfortran's (with `flags`):
/// compiled, then linked (a compiler of Nix's finds no dsymutil when it
/// links), then on macOS the debug information gathered into `name.dSYM`
/// (lldb also reads it from the object file, which stays). LFortran's:
/// `lfortran -g`, which writes the `.dSYM` itself. The program, or null
fn build(io: Io, a: Allocator, setup: Setup, name: []const u8, flags: []const []const u8) !?[]const u8 {
    const dir = setup.dir;
    const gfortran = setup.fc;
    const src = try std.Io.Dir.path.join(a, &.{ dir, try a.print("{s}.f90", .{name}) });
    const obj = try std.Io.Dir.path.join(a, &.{ dir, try a.print("{s}.o", .{name}) });
    const exe = try std.Io.Dir.path.join(a, &.{ dir, if (builtin.target.os.tag == .windows) try a.print("{s}.exe", .{name}) else name });
    if (setup.compiler == .lfortran) {
        dap_lfortran.build(io, a, setup.fc, setup.build_env.?, dir, src, exe) catch return null;
        return exe;
    }
    var compile: std.ArrayList([]const u8) = .empty;
    try compile.appendSlice(a, &.{ gfortran, "-g" });
    try compile.appendSlice(a, flags);
    try compile.appendSlice(a, &.{ "-c", src, "-o", obj });
    for ([_][]const []const u8{ compile.items, &.{ gfortran, "-g", obj, "-o", exe } }) |cmd| {
        const r = try std.process.run(a, io, .{ .argv = cmd, .cwd = .{ .path = dir } });
        if (!r.term.success()) {
            std.debug.print("{s} failed:\n{s}{s}\n", .{ cmd[0], r.stdout, r.stderr });
            return null;
        }
    }
    if (builtin.target.os.tag == .macos) _ = std.process.run(a, io, .{ .argv = &.{ "dsymutil", exe }, .cwd = .{ .path = dir } }) catch {};
    return exe;
}

/// The 1-based line of a marker of the source
fn lineOf(text: []const u8, marker: []const u8) i64 {
    const at = std.mem.find(u8, text, marker) orelse unreachable;
    return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
}

fn start(io: Io, gpa: Allocator, setup: Setup) !*Client {
    return Client.start(io, gpa, &.{ setup.zfls, "dap", "--lldb", setup.lldb });
}

fn eql(x: ?[]const u8, y: []const u8) bool {
    return std.mem.eql(u8, x orelse return false, y);
}

fn named(vars: []Value, name: []const u8) ?Value {
    for (vars) |x| if (eql(str(x, "name"), name)) return x;
    return null;
}

fn inSource(frame: Value, file: []const u8) bool {
    return contains(str(get(frame, "source") orelse Value.null, "path"), file);
}

fn walkThrough(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler == .lfortran) return dap_lfortran.walkThrough(io, gpa, .{
        .argv = &.{ setup.zfls, "dap", "--lldb", setup.lldb },
        .program = setup.program,
        .src = setup.src,
        .dir = setup.dir,
        .work_line = setup.work_line,
        .call_line = setup.call_line,
        .main_line = setup.main_line,
    });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer c.end(true);

    const caps = try c.request("initialize", .{ .adapterID = "fortran", .clientID = "test", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path", .supportsVariableType = true });
    const filters = items(caps, "exceptionBreakpointFilters");
    try check(filters.len > 0 and eql(str(filters[0], "filter"), "fortranRuntimeErrors"), "the filter of Fortran runtime errors first", .{});
    var foreign = false;
    for (filters) |f| foreign = foreign or eql(str(f, "filter"), "objc_throw") or eql(str(f, "filter"), "swift_throw");
    try check(!foreign, "no Objective-C or Swift filters", .{});

    const launched = try c.send("launch", .{ .program = setup.program, .args = [_][]const u8{}, .cwd = setup.dir, .env = .{ .ZFLS_TEST = "1" } });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = setup.src }, .breakpoints = .{ .{ .line = setup.work_line }, .{ .line = setup.main_line } } }), "breakpoints");
    try check(bps.len == 2, "two breakpoints", .{});
    const exc = items(try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} }), "breakpoints");
    try check(exc.len == 1, "one exception filter", .{});
    // function breakpoints, of which two do not exist: each with its own
    // verified state (#373); then none, for the rest of the session
    const functions = items(try c.request("setFunctionBreakpoints", .{ .breakpoints = .{ .{ .name = "zfls_no_such_function" }, .{ .name = "MAIN__" }, .{ .name = "zfls_nor_this_one" }, .{ .name = "main" } } }), "breakpoints");
    var states: [4]bool = undefined;
    for (functions[0..@min(4, functions.len)], 0..) |b, k| states[k] = if (get(b, "verified")) |v| v == .bool and v.bool else false;
    try check(functions.len == 4 and !states[0] and states[1] and !states[2] and states[3], "function breakpoints verified in their order: {any}", .{states[0..@min(4, functions.len)]});
    _ = try c.request("setFunctionBreakpoints", .{ .breakpoints = [_]u8{} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");

    // in work, called from the main program
    var stopped = get(try c.event("stopped"), "body").?;
    try check(eql(str(stopped, "reason"), "breakpoint"), "stopped at a breakpoint ({s})", .{str(stopped, "reason") orelse "?"});
    const thread = int(stopped, "threadId").?;
    var stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(stack.len >= 2 and inSource(stack[0], "grid.f90") and int(stack[0], "line") == setup.work_line, "stopped in work, line {?d} ({s})", .{ int(stack[0], "line"), str(stack[0], "name") orelse "?" });
    try check(inSource(stack[1], "grid.f90") and int(stack[1], "line") == setup.call_line, "called at line {?d} ({s})", .{ int(stack[1], "line"), str(stack[1], "name") orelse "?" });

    // the variables: lldb's, as it gives them
    const scopes = items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes");
    try check(named(scopes, "Module variables") == null, "no Module variables scope", .{});
    for (scopes) |sc| {
        const vars = items(try c.request("variables", .{ .variablesReference = int(sc, "variablesReference") orelse 0 }), "variables");
        std.debug.print("   lldb's {s}: {d} variables", .{ str(sc, "name") orelse "?", vars.len });
        for (vars[0..@min(vars.len, 3)]) |x| std.debug.print(" {s}={s}", .{ str(x, "name") orelse "?", str(x, "value") orelse "?" });
        std.debug.print("\n", .{});
    }

    // a step, past the print
    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(eql(str(stopped, "reason"), "step") and int(stack[0], "line") == setup.work_line + 1, "a step to line {?d}", .{int(stack[0], "line")});
    try check(contains(try c.outputText(a), "abcdef"), "the program's output", .{});

    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(stack[0], "line") == setup.main_line, "stopped in main ({?d})", .{int(stack[0], "line")});

    // an array bound exceeded: a Fortran runtime error
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    try check(eql(str(stopped, "reason"), "exception") and eql(str(stopped, "description"), "Fortran runtime error"), "stopped by a Fortran runtime error ({s}: {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "description") orelse "?" });
    const info = try c.request("exceptionInfo", .{ .threadId = thread });
    try check(eql(str(info, "description"), "Fortran runtime error") and contains(str(info, "exceptionId"), "_gfortran_runtime_error"), "exception info: {s}", .{str(info, "exceptionId") orelse "?"});
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(eql(str(stack[0], "presentationHint"), "subtle"), "the runtime's frame de-emphasized ({s})", .{str(stack[0], "name") orelse "?"});
    const ours = for (stack) |f| {
        if (!eql(str(f, "presentationHint"), "subtle")) break f;
    } else Value.null;
    try check(ours != .null and inSource(ours, "grid.f90") and int(ours, "line") == setup.main_line + 1, "the program's frame first: line {?d}", .{int(ours, "line")});

    _ = try c.request("continue", .{ .threadId = thread });
    const exited = get(try c.event("exited"), "body").?;
    try check((int(exited, "exitCode") orelse 0) != 0, "the program exited with {?d}", .{int(exited, "exitCode")});
}

/// The stop at the start, with lldb-dap named by the configuration
fn atEntry(io: Io, gpa: Allocator, setup: Setup) !void {
    const c = try Client.start(io, gpa, &.{ setup.zfls, "dap", "--lldb" });
    defer c.deinit();
    defer c.end(true);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path" });
    const launched = try c.send("launch", .{ .program = setup.program, .cwd = setup.dir, .stopAtEntry = true, .lldb = setup.lldb });
    _ = try c.event("initialized");
    _ = try c.request("setExceptionBreakpoints", .{ .filters = [_][]const u8{} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const stopped = get(try c.event("stopped"), "body").?;
    try check(eql(str(stopped, "reason"), "entry"), "stopped at the entry ({s})", .{str(stopped, "reason") orelse "?"});
    const stack = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    try check(inSource(stack[0], "grid.f90") and int(stack[0], "line").? < setup.main_line, "stopped at the start ({?d})", .{int(stack[0], "line")});
    // without the filter, the bound exceeded ends the program
    _ = try c.request("continue", .{ .threadId = int(stopped, "threadId").? });
    const exited = get(try c.event("exited"), "body").?;
    try check((int(exited, "exitCode") orelse 0) != 0, "the program exited with {?d}", .{int(exited, "exitCode")});
}

/// tests/dap/stops.f90: the filter of Fortran runtime errors stops at its
/// ERROR STOP, not at its STOP. Not LFortran's on macOS: LFortran 0.69.0's
/// ERROR STOP in a program built with `-g` aborts there before it calls
/// its runtime's function ("The stack address was not found in any shared
/// library or the main program")
/// gfortran's runtime errors and stops beyond grid.f90's
/// (tests/dap_gfortran.zig)
fn gfortranRuntime(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler != .gfortran) return std.debug.print("skipped: gfortran only\n", .{});
    try dap_gfortran.run(io, gpa, &.{ setup.zfls, "dap", "--lldb", setup.lldb }, setup.fc, setup.dir, false);
}

fn errorStop(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler == .lfortran and builtin.target.os.tag == .macos) return std.debug.print("skipped: LFortran's ERROR STOP aborts in a -g program on macOS\n", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ setup.dir, "stops.f90" }), .data = try Io.Dir.cwd().readFileAlloc(io, "tests/dap/stops.f90", a, .limited(1 << 16)) });
    const exe = try build(io, a, setup, "stops", &.{}) orelse return error.CheckFailed;
    try dap_lfortran.errorStop(io, gpa, &.{ setup.zfls, "dap", "--lldb", setup.lldb }, exe, setup.dir);
}

/// Attaching to a running program, pausing it and ending it (gfortran's:
/// the debugger's part, which LFortran's would not change)
fn attach(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler != .gfortran) return std.debug.print("skipped: gfortran's only\n", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ setup.dir, "sleeper.f90" }), .data = "program sleeper\n  integer :: i\n  do i = 1, 120\n    call sleep(1)\n  end do\nend program\n" });
    const exe = try build(io, a, setup, "sleeper", &.{}) orelse return error.CheckFailed;
    var child = try std.process.spawn(io, .{ .argv = &.{exe}, .stdin = .ignore, .stdout = .ignore });
    // after its wait, nothing to kill
    defer child.kill(io);

    const c = try start(io, gpa, setup);
    defer c.deinit();
    var ended = false;
    defer if (!ended) c.end(true);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path" });
    const attached = try c.send("attach", .{ .processId = dap.processId(child), .program = exe });
    _ = try c.event("initialized");
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(attached, "attach"), "attach");
    const threads = items(try c.request("threads", .{}), "threads");
    try check(threads.len > 0, "{d} threads", .{threads.len});
    const thread = int(threads[0], "id").?;
    _ = try c.request("pause", .{ .threadId = thread });
    const stopped = get(try c.event("stopped"), "body").?;
    var stack = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId") orelse thread }), "stackFrames");
    var ours = programFrame(stack);
    // on Windows the thread that stops is the debugger's, made for the
    // pause: the program's frame is in one of the others
    if (ours == .null and builtin.target.os.tag == .windows) for (threads) |t| {
        const other = items(try c.request("stackTrace", .{ .threadId = int(t, "id").? }), "stackFrames");
        ours = programFrame(other);
        if (ours != .null) {
            stack = other;
            break;
        }
    };
    try check(eql(str(stopped, "reason"), "pause"), "paused ({s})", .{str(stopped, "reason") orelse "?"});
    try check(ours != .null, "in the program, the runtime's frames de-emphasized: {s}", .{str(stack[0], "presentationHint") orelse "-"});
    const t0 = Io.Clock.awake.now(io);
    c.end(true);
    ended = true;
    _ = try child.wait(io);
    // it sleeps two minutes: ended sooner, it was ended (on Windows with
    // exit code 0, by TerminateProcess)
    const ms = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try check(ms < 60_000, "the program ended with the session ({d} ms)", .{ms});
}

fn programFrame(stack: []const Value) Value {
    return for (stack) |f| {
        if (inSource(f, "sleeper.f90")) break f;
    } else Value.null;
}

/// The program's input and output in a terminal, which script(1) gives a
/// command
fn terminal(io: Io, gpa: Allocator, setup: Setup) !void {
    if (builtin.target.os.tag == .windows) return std.debug.print("skipped: not on Windows\n", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ setup.dir, "reader.f90" }), .data = "program reader\n  integer :: n\n  read(*, *) n\n  print '(a,i0)', 'read ', n\nend program\n" });
    const reader_exe = try build(io, a, setup, "reader", &.{}) orelse return error.CheckFailed;

    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer c.end(true);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .supportsRunInTerminalRequest = true });
    const launched = try c.send("launch", .{ .program = reader_exe, .cwd = setup.dir, .console = "integratedTerminal" });
    const asked = try c.adapterRequest();
    try check(eql(str(asked, "command"), "runInTerminal"), "a terminal asked for", .{});
    const cmd_args = items(get(asked, "arguments").?, "args");
    var argv: std.ArrayList([]const u8) = .empty;
    if (builtin.target.os.tag == .linux) {
        var command: std.ArrayList(u8) = .empty;
        for (cmd_args, 0..) |x, k| {
            if (k > 0) try command.append(a, ' ');
            try command.append(a, '\'');
            for (x.string) |ch| if (ch == '\'') try command.appendSlice(a, "'\\''") else try command.append(a, ch);
            try command.append(a, '\'');
        }
        try argv.appendSlice(a, &.{ "script", "-qfec", command.items, "/dev/null" });
    } else {
        // BSD's: script [-q] file command...
        try argv.appendSlice(a, &.{ "script", "-q", "/dev/null" });
        for (cmd_args) |x| try argv.append(a, x.string);
    }
    var term = std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = setup.dir }, .stdin = .pipe, .stdout = .pipe }) catch
        return std.debug.print("skipped: no script(1)\n", .{});
    defer term.kill(io);
    try c.answer(asked, true, .{ .shellProcessId = term.id.? });
    _ = try c.event("initialized");
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    try term.stdin.?.writeStreamingAll(io, "42\n");
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 0, "the reader exited with 0 ({?d})", .{int(exited, "exitCode")});
    // the adapter ends the terminal: its screen
    var buf: [4096]u8 = undefined;
    var screen: std.ArrayList(u8) = .empty;
    var r = term.stdout.?.readerStreaming(io, &buf);
    while (r.interface.takeByte()) |ch| try screen.append(a, ch) else |_| {}
    try check(contains(screen.items, "read 42"), "the program read 42 in its terminal", .{});
}
