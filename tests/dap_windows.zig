//! zfls dap, the debug adapter over Windows's Debugger Engine (the
//! launch's `dbgeng`), on a program of the MSVC ABI with a PDB
//! (tests/dap/hello.c, built by `zig cc` and linked with zfls's ifx kit,
//! not Visual Studio): a breakpoint, the stack, the variables, stepping, an
//! expression, the end (`zig build test-dap`); the engine's capabilities
//! in place of gdb's (GDB, else the PATH's;
//! tests/dap_engine_capabilities.zig); attaching to tests/dap/wait.c's
//! program (tests/dap_engine_attach.zig); and tests/dap/trap.c, whose break
//! instruction is an exception, not a step.
//!
//! With LLVM Flang (`--flang`, or FLANG in the environment), also
//! tests/dap/grid.f90 built with `-g` (linked with zfls's ifx kit: `--kit`,
//! which `zig build` gives, else the one next to zfls): the breakpoints,
//! stopAtEntry, the stack, the variables (dummy arguments: arrays through
//! Flang's descriptors, CHARACTER(*), CLASS with its dynamic type; the main
//! program's, static ones too; module variables), the caller's line,
//! stepping (over Flang's empty line records) and the filter of Fortran
//! runtime errors (at a runtime error; tests/dap/stops.f90: at ERROR STOP,
//! called at its line, not at STOP; at both, the stack goes on past the
//! program's frame to `main` and `mainCRTStartup`).
//!
//! With Intel's ifx (`--ifx`, or IFX in the environment), the same programs
//! built with `/Zi /Od /check:bounds` and linked with the kit
//! (tests/dap_ifx.zig).
//!
//!     dap_windows --zfls ZFLS.EXE [--zig ZIG] [--flang FLANG] [--ifx IFX] [--kit DIR]

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

const source = "tests/dap/hello.c";

const dap = @import("dap_client.zig");
const dap_ifx = @import("dap_ifx.zig");
const dap_engine_capabilities = @import("dap_engine_capabilities.zig");
const dap_engine_attach = @import("dap_engine_attach.zig");
const dap_completions = @import("dap_completions.zig");
const dap_engine_conditions = @import("dap_engine_conditions.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var zig: []const u8 = "zig";
    var flang: ?[]const u8 = init.environ_map.get("FLANG");
    var ifx: ?[]const u8 = init.environ_map.get("IFX");
    var kit: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--zig")) {
            zig = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--flang")) {
            flang = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--ifx")) {
            ifx = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--kit")) {
            kit = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null) {
        std.debug.print("usage: dap_windows --zfls ZFLS.EXE [--zig ZIG] [--flang FLANG] [--ifx IFX] [--kit DIR]\n", .{});
        return 2;
    }
    if (builtin.target.os.tag != .windows) {
        std.debug.print("skipped: Windows only\n", .{});
        return 0;
    }
    const cwd = Io.Dir.cwd();
    const src = try cwd.realPathFileAlloc(io, source, a);
    const src_dir = std.Io.Dir.path.dirname(src).?;
    const exe_zfls = try cwd.realPathFileAlloc(io, zfls_exe.?, a);
    const tmp = try lsp.tempDir(io, a, init.environ_map, "zfls-dap-");
    defer cwd.deleteTree(io, tmp) catch {};
    const kit_dir = try dap.kitDir(io, a, exe_zfls, kit) orelse {
        std.debug.print("FAIL: no ifx kit next to {s} (--kit DIR)\n", .{exe_zfls});
        return 1;
    };
    std.debug.print("linking the C programs with the ifx kit {s}\n", .{kit_dir});
    const exe = (try buildC(io, a, init.environ_map, zig, kit_dir, tmp, src, "hello")) orelse return 1;
    {
        var names: std.ArrayList(u8) = .empty;
        var dir = try cwd.openDir(io, tmp, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| try names.print(a, " {s}", .{e.name});
        std.debug.print("built:{s}; _NT_SYMBOL_PATH={s}\n", .{ names.items, init.environ_map.get("_NT_SYMBOL_PATH") orelse "(unset)" });
    }

    {
        const c = try Client.start(io, init.gpa, &.{ exe_zfls, "dap" });
        defer c.deinit();
        run(c, exe, tmp, src, src_dir) catch |e| {
            std.debug.print("zfls dap: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    dap_engine_capabilities.run(io, init.gpa, a, exe_zfls, init.environ_map.get("GDB") orelse "gdb", exe, tmp, src_dir) catch |e| {
        std.debug.print("zfls dap, the engine's capabilities after gdb's: {s}\n", .{@errorName(e)});
        return 1;
    };
    {
        const wait_c = try cwd.realPathFileAlloc(io, "tests/dap/wait.c", a);
        const waiting = (try buildC(io, a, init.environ_map, zig, kit_dir, tmp, wait_c, "wait")) orelse return 1;
        dap_engine_attach.run(io, init.gpa, exe_zfls, waiting, wait_c, tmp) catch |e| {
            std.debug.print("zfls dap, the engine's attach: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    {
        const trap = (try buildC(io, a, init.environ_map, zig, kit_dir, tmp, try cwd.realPathFileAlloc(io, "tests/dap/trap.c", a), "trap")) orelse return 1;
        const c = try Client.start(io, init.gpa, &.{ exe_zfls, "dap" });
        defer c.deinit();
        runTrap(c, trap, tmp) catch |e| {
            std.debug.print("zfls dap, a break instruction: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    std.debug.print("zfls dap: all good\n", .{});
    var status: u8 = 0;
    if (flang) |fc| status |= try withFlang(io, init.gpa, a, init.environ_map, exe_zfls, fc, tmp, kit);
    if (ifx) |fx| status |= try dap_ifx.run(io, init.gpa, a, init.environ_map, exe_zfls, fx, tmp, kit_dir);
    return status;
}

/// The C program `src` built in `tmp` as NAME.exe with a PDB, for the
/// MSVC ABI, without Visual Studio where it is installed: `zig cc` compiles
/// with a libc file of empty directories (ZIG_LIBC; else it takes Visual
/// Studio's and the Windows SDK's headers), and `zig lld-link` links with
/// the ifx kit's startup object and import libraries, told to look for
/// neither (`-lldignoreenv`, empty `-vctoolsdir` and `-winsdkdir`); null
/// when it does not build, or when the link read a file of Visual Studio's
fn buildC(io: Io, a: Allocator, environ: *const std.process.Environ.Map, zig: []const u8, kit_dir: []const u8, tmp: []const u8, src: []const u8, name: []const u8) !?[]const u8 {
    const cwd = Io.Dir.cwd();
    const empty = try std.Io.Dir.path.join(a, &.{ tmp, "no-visual-studio" });
    try cwd.createDirPath(io, empty);
    const libc = try std.Io.Dir.path.join(a, &.{ tmp, "zig-libc.txt" });
    try cwd.writeFile(io, .{ .sub_path = libc, .data = try a.print(
        "include_dir={0s}\nsys_include_dir={0s}\ncrt_dir={0s}\nmsvc_lib_dir={0s}\nkernel32_lib_dir={0s}\ngcc_dir=\ndarwin_sdk_dir=\n",
        .{empty},
    ) });
    const env = try dap.withoutVisualStudio(a, environ);
    try env.put("ZIG_LIBC", libc);
    const obj = try std.Io.Dir.path.join(a, &.{ tmp, try a.print("{s}.obj", .{name}) });
    const exe = try std.Io.Dir.path.join(a, &.{ tmp, try a.print("{s}.exe", .{name}) });
    const shim = try std.Io.Dir.path.join(a, &.{ kit_dir, "zfls_ifx_shim.obj" });
    const steps = [_][]const []const u8{
        // `-v`: the directories of the headers, for the check below; no
        // sanitizer, whose runtime is not in the kit
        &.{ zig, "cc", "-target", "x86_64-windows-msvc", "-v", "-c", "-g", "-O0", "-fno-sanitize=undefined", src, "-o", obj },
        &.{ zig, "lld-link", "-nologo", "-debug", "-subsystem:console", try a.print("-out:{s}", .{exe}), obj, shim, try a.print("-libpath:{s}", .{kit_dir}), "-nodefaultlib", "msvcrt.lib", "ucrt.lib", "vcruntime.lib", "kernel32.lib", "-lldignoreenv", try a.print("-vctoolsdir:{s}", .{empty}), try a.print("-winsdkdir:{s}", .{empty}), "-verbose" },
    };
    for (steps) |argv| {
        const r = try std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = tmp }, .environ_map = env });
        if (!r.term.success()) {
            std.debug.print("{s} {s} failed:\n{s}{s}\n", .{ argv[0], argv[1], r.stdout, r.stderr });
            return null;
        }
        if (dap.visualStudioRead(r.stderr) orelse dap.visualStudioRead(r.stdout)) |line| {
            std.debug.print("FAIL: building {s} read Visual Studio's files: {s}\n", .{ name, line });
            return null;
        }
    }
    return exe;
}

/// tests/dap/grid.f90 built by LLVM Flang with `-g` (Microsoft's debug
/// information), under the engine
fn withFlang(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, exe_zfls: []const u8, fc: []const u8, tmp: []const u8, kit: ?[]const u8) !u8 {
    const version = std.process.run(a, io, .{ .argv = &.{ fc, "--version" } }) catch {
        std.debug.print("LLVM Flang: skipped: no {s}\n", .{fc});
        return 0;
    };
    std.debug.print("-- {s}", .{version.stdout[0 .. (std.mem.findScalar(u8, version.stdout, '\n') orelse version.stdout.len - 1) + 1]});
    const env = try dap.flangKitEnv(io, a, environ, exe_zfls, kit);
    const grid = (try buildFlang(io, a, fc, env, tmp, "grid")) orelse return 1;
    {
        const c = try Client.start(io, gpa, &.{ exe_zfls, "dap" });
        defer c.deinit();
        runFlang(c, grid.exe, tmp, grid.src, lineOf(grid.text, "stop here: work"), lineOf(grid.text, "stop here: main"), lineOf(grid.text, "call work(")) catch |e| {
            std.debug.print("zfls dap, LLVM Flang's program: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    dap_completions.run(io, gpa, .{ .argv = &.{ exe_zfls, "dap" }, .program = grid.exe, .src = grid.src, .dir = tmp, .work_line = lineOf(grid.text, "stop here: work"), .engine = true }) catch |e| {
        std.debug.print("zfls dap, LLVM Flang's program, completions: {s}\n", .{@errorName(e)});
        return 1;
    };
    dap_engine_conditions.run(io, gpa, .{ .argv = &.{ exe_zfls, "dap" }, .program = grid.exe, .src = grid.src, .dir = tmp, .loop_line = lineOf(grid.text, "m(:, k) = [10*k, 20*k]"), .main_line = lineOf(grid.text, "stop here: main") }) catch |e| {
        std.debug.print("zfls dap, LLVM Flang's program, conditions: {s}\n", .{@errorName(e)});
        return 1;
    };
    // ERROR STOP and STOP: one function of Flang's runtime, told apart by
    // its argument
    const stops = (try buildFlang(io, a, fc, env, tmp, "stops")) orelse return 1;
    for ([_]bool{ false, true }) |plain| {
        const c = try Client.start(io, gpa, &.{ exe_zfls, "dap" });
        defer c.deinit();
        runStops(c, stops.exe, tmp, plain, lineOf(stops.text, "error stop 3")) catch |e| {
            std.debug.print("zfls dap, LLVM Flang's STOP and ERROR STOP: {s}\n", .{@errorName(e)});
            if (c.child.id != null) c.child.kill(io);
            return 1;
        };
    }
    std.debug.print("zfls dap, LLVM Flang's program: all good\n", .{});
    return 0;
}

/// tests/dap/NAME.f90, copied to `tmp` and built there with `-g`: its
/// text, its copy and the program; null when it does not build
fn buildFlang(io: Io, a: Allocator, fc: []const u8, env: ?*const std.process.Environ.Map, tmp: []const u8, name: []const u8) !?struct { text: []const u8, src: []const u8, exe: []const u8 } {
    const cwd = Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, try a.print("tests/dap/{s}.f90", .{name}), a, .limited(1 << 20));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, try a.print("{s}.f90", .{name}) });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    const exe = try std.Io.Dir.path.join(a, &.{ tmp, try a.print("{s}.exe", .{name}) });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ fc, "-g", "-O0" });
    if (env != null) try argv.appendSlice(a, &.{ "-fms-runtime-lib=dll", "-fuse-ld=lld" });
    try argv.appendSlice(a, &.{ "-o", exe, src });
    const built = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = tmp }, .environ_map = env });
    if (!built.term.success()) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ fc, built.stdout, built.stderr });
        return null;
    }
    return .{ .text = text, .src = src, .exe = exe };
}

/// tests/dap/stops.f90 with the filter of Fortran runtime errors: its
/// ERROR STOP stops, called at its line (`error_line`; the call does not
/// return); its plain STOP (`plain`) does not
pub fn runStops(c: *Client, exe: []const u8, tmp: []const u8, plain: bool, error_line: i64) !void {
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    _ = try c.request("launch", .{ .program = exe, .args = if (plain) &[_][]const u8{"plain"} else &[_][]const u8{}, .cwd = tmp, .console = "internalConsole", .sourceRoot = tmp, .dbgeng = true });
    _ = try c.event("initialized");
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} });
    _ = try c.request("configurationDone", .{});
    if (plain) {
        const exited = get(try c.event("exited"), "body").?;
        try check(int(exited, "exitCode") == 0, "STOP: no stop, exit code 0 ({?d})", .{int(exited, "exitCode")});
    } else {
        const stopped = get(try c.event("stopped"), "body").?;
        try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "exception") and std.mem.eql(u8, str(stopped, "description") orelse "", "ERROR STOP"), "ERROR STOP: stopped ({s}: {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "description") orelse "?" });
        const frames = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
        const at = for (frames, 0..) |f, k| {
            if (std.mem.eql(u8, str(f, "name") orelse "", "STOPS")) break k;
        } else null;
        try check(at != null and int(frames[at.?], "line") == error_line, "ERROR STOP: called at line {d} of STOPS ({?d})", .{ error_line, if (at) |k| int(frames[k], "line") else null });
        // the call does not return: the stack goes on past it (#460)
        var buf: [512]u8 = undefined;
        try check(toStart(frames[at.? + 1 ..]), "ERROR STOP: STOPS, then main, mainCRTStartup ({s})", .{frameNames(&buf, frames[at.? + 1 ..])});
        _ = try c.request("continue", .{ .threadId = int(stopped, "threadId").? });
        const exited = get(try c.event("exited"), "body").?;
        try check(int(exited, "exitCode") == 3, "ERROR STOP: then exit code 3 ({?d})", .{int(exited, "exitCode")});
    }
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
}

/// tests/dap/trap.c: the program's own break instruction (the Intel
/// runtime's at a runtime error) stops as an exception, not as a step, and
/// the program goes on from it (#493). Launched without `dbgeng`: its PDB
/// chooses Windows's Debugger Engine (#578).
fn runTrap(c: *Client, exe: []const u8, tmp: []const u8) !void {
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole" });
    var said_buf: [4096]u8 = undefined;
    var said_alloc: std.heap.FixedBufferAllocator = .init(&said_buf);
    const said = try c.outputText(said_alloc.allocator());
    try check(std.mem.find(u8, said, "has Microsoft's debug information (a PDB): debugging with Windows's Debugger Engine") != null, "the engine chosen by the program's PDB: {s}", .{said});
    _ = try c.event("initialized");
    _ = try c.request("configurationDone", .{});
    const stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "exception") and std.mem.eql(u8, str(stopped, "text") orelse "", "0x80000003"), "a break instruction: stopped as an exception ({s}, {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "text") orelse "?" });
    _ = try c.request("continue", .{ .threadId = int(stopped, "threadId").? });
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 5, "a break instruction: then exit code 5 ({?d})", .{int(exited, "exitCode")});
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
}

/// Whether the frames past a Fortran program's go on to the C runtime's:
/// `main`, then `mainCRTStartup`
pub fn toStart(frames: []Value) bool {
    var want: []const []const u8 = &.{ "main", "mainCRTStartup" };
    for (frames) |f| {
        if (want.len > 0 and std.mem.eql(u8, str(f, "name") orelse "", want[0])) want = want[1..];
    }
    return want.len == 0;
}

/// The frames' names, for messages
pub fn frameNames(buf: []u8, frames: []Value) []const u8 {
    var w: Io.Writer = .fixed(buf);
    for (frames, 0..) |f, k| w.print("{s}{s}", .{ if (k > 0) ", " else "", str(f, "name") orelse "?" }) catch break;
    return w.buffered();
}

/// The 1-based line of a marker of the source
pub fn lineOf(text: []const u8, marker: []const u8) i64 {
    const at = std.mem.find(u8, text, marker) orelse unreachable;
    return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
}

pub fn named(vars: []Value, name: []const u8) ?Value {
    for (vars) |v| if (std.mem.eql(u8, str(v, "name") orelse "", name)) return v;
    return null;
}

pub fn scopeVariables(c: *Client, scopes: []Value, name: []const u8) ![]Value {
    const scope = named(scopes, name) orelse return &.{};
    return items(try c.request("variables", .{ .variablesReference = int(scope, "variablesReference").? }), "variables");
}

/// The variables of the module `module` of a frame's "Module variables"
pub fn moduleVariables(c: *Client, scopes: []Value, module: []const u8) ![]Value {
    const node = named(try scopeVariables(c, scopes, "Module variables"), module) orelse return &.{};
    return items(try c.request("variables", .{ .variablesReference = int(node, "variablesReference").? }), "variables");
}

/// The value of the variable `name` of `vars`, or "(none)"
pub fn valueOf(vars: []Value, name: []const u8) []const u8 {
    const v = named(vars, name) orelse return "(none)";
    return str(v, "value") orelse "?";
}

fn runFlang(c: *Client, exe: []const u8, tmp: []const u8, src: []const u8, work_line: i64, main_line: i64, call_line: i64) !void {
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = tmp, .dbgeng = true, .stopAtEntry = true });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{ .{ .line = work_line }, .{ .line = main_line } } }), "breakpoints");
    var verified: usize = 0;
    for (bps) |b| verified += @intFromBool((get(b, "verified") orelse Value{ .bool = false }).bool);
    try check(verified == 2, "two verified breakpoints ({d})", .{verified});
    // the filter of Fortran runtime errors: on Flang's runtime functions
    // (`_FortranAStopStatement`, `Fortran::runtime::Terminator::CrashHeader`)
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} });
    _ = try c.request("configurationDone", .{});

    // stopAtEntry: in the main program (`_QQmain`), before its statements
    var stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    var frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 0 and std.mem.eql(u8, str(frames[0], "name") orelse "", "MAIN") and (int(frames[0], "line") orelse main_line) < call_line, "stopAtEntry: in MAIN ({s}:{?d})", .{ if (frames.len > 0) str(frames[0], "name") orelse "?" else "none", if (frames.len > 0) int(frames[0], "line") else null });
    _ = try c.request("continue", .{ .threadId = thread });

    // in work, called by the main program
    stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint"), "stopped at a breakpoint", .{});
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 1 and contains(str(frames[0], "name"), "work") and int(frames[0], "line") == work_line, "in grid::work at line {d} ({s}:{?d})", .{ work_line, str(frames[0], "name") orelse "?", int(frames[0], "line") });
    // the caller's line: the CALL's (before the return address, which may
    // be the next line's)
    try check(std.mem.eql(u8, str(frames[1], "name") orelse "", "MAIN") and int(frames[1], "line") == call_line, "called by MAIN at line {d} ({s}:{?d})", .{ call_line, str(frames[1], "name") orelse "?", int(frames[1], "line") });
    var scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    // work's dummy arguments: their addresses are in the frame (LLVM's
    // S_DEFRANGE_REGISTER_REL_INDIR)
    const args = try scopeVariables(c, scopes, "Locals");
    try check(std.mem.eql(u8, valueOf(args, "p"), "point(x=9.0, y=-2.0, id=7)"), "p = point(x=9.0, y=-2.0, id=7) ({s})", .{valueOf(args, "p")});
    // CLASS(point) of a tagged: its dynamic type, which its descriptor's
    // addendum names (`_QMgridEXdtXtagged`)
    const t = named(args, "t");
    try check(t != null and std.mem.eql(u8, str(t.?, "type") orelse "", "CLASS(point)") and std.mem.startsWith(u8, valueOf(args, "t"), "tagged("), "t: CLASS(point) = tagged(…) ({s})", .{valueOf(args, "t")});
    const tc = items(try c.request("variables", .{ .variablesReference = int(t.?, "variablesReference").? }), "variables");
    try check(std.mem.eql(u8, valueOf(tc, "tag"), "'hello   '") and std.mem.eql(u8, valueOf(tc, "w"), "[0.25, 0.25]"), "t%tag = 'hello   ', t%w = [0.25, 0.25] ({s}, {s})", .{ valueOf(tc, "tag"), valueOf(tc, "w") });
    const tid = try c.request("evaluate", .{ .expression = "t%point%id", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(tid, "result") orelse "", "7"), "t%point%id = 7 ({s})", .{str(tid, "result") orelse "?"});
    // CHARACTER(LEN=*): its length, a hidden local (`._QMgridFworkEs1`)
    try check(std.mem.eql(u8, valueOf(args, "s"), "'abcdef'"), "s = 'abcdef' ({s})", .{valueOf(args, "s")});
    // assumed-shape arrays: Flang's descriptors (ISO_Fortran_binding's)
    try check(std.mem.eql(u8, valueOf(args, "a"), "[6.0, 2.0, 3.0]"), "a = [6.0, 2.0, 3.0] ({s})", .{valueOf(args, "a")});
    try check(std.mem.eql(u8, valueOf(args, "b"), "[2×3]"), "b = [2×3] ({s})", .{valueOf(args, "b")});
    const b_cols = items(try c.request("variables", .{ .variablesReference = int(named(args, "b").?, "variablesReference").? }), "variables");
    try check(std.mem.eql(u8, valueOf(b_cols, "(:,1)"), "[-10, -20]"), "b(:,1) = [-10, -20] ({s})", .{valueOf(b_cols, "(:,1)")});
    const b21 = try c.request("evaluate", .{ .expression = "b(2,1)", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(b21, "result") orelse "", "-20"), "b(2,1) = -20 ({s})", .{str(b21, "result") orelse "?"});
    // CLASS(point) array of labeled: its elements by the descriptor's
    // stride, as their dynamic type
    try check(std.mem.eql(u8, valueOf(args, "ts"), "[labeled(…), labeled(…)]"), "ts = [labeled(…), labeled(…)] ({s})", .{valueOf(args, "ts")});
    const ts2 = try c.request("evaluate", .{ .expression = "ts(2)%label", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(ts2, "result") orelse "", "5"), "ts(2)%label = 5 ({s})", .{str(ts2, "result") orelse "?"});
    // the module variables, by Flang's public names (`_QMgridEncells`)
    // with the types of CodeView's own (`ncells`)
    const grid = try moduleVariables(c, scopes, "grid");
    try check(std.mem.eql(u8, valueOf(grid, "ncells"), "42"), "grid::ncells = 42 ({s})", .{valueOf(grid, "ncells")});
    try check(std.mem.eql(u8, valueOf(grid, "secret"), "99"), "grid::secret = 99 ({s})", .{valueOf(grid, "secret")});
    try check(std.mem.eql(u8, valueOf(grid, "origin"), "point(x=9.0, y=-2.0, id=7)"), "grid::origin = point(x=9.0, y=-2.0, id=7) ({s})", .{valueOf(grid, "origin")});

    // next to END SUBROUTINE (Flang's line table has empty records of the
    // declarations at its address), then back to the main program's next
    // line
    for ([_]struct { []const u8, i64 }{ .{ "work", work_line + 1 }, .{ "MAIN", call_line + 1 } }) |want| {
        _ = try c.request("next", .{ .threadId = thread });
        stopped = get(try c.event("stopped"), "body").?;
        frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
        try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and contains(str(frames[0], "name"), want[0]) and int(frames[0], "line") == want[1], "next: {s}:{d} ({s}:{?d})", .{ want[0], want[1], str(frames[0], "name") orelse "?", int(frames[0], "line") });
    }

    // in the main program: a variable of it, a step
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(frames[0], "name") orelse "", "MAIN") and int(frames[0], "line") == main_line, "in MAIN at line {d} ({s}:{?d})", .{ main_line, str(frames[0], "name") orelse "?", int(frames[0], "line") });
    scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    const locals = try scopeVariables(c, scopes, "Locals");
    // k, after the loop `do k = -1, 1`
    const k = named(locals, "k");
    try check(k != null and std.mem.eql(u8, str(k.?, "value") orelse "", "2"), "k = 2 ({s})", .{if (k) |x| str(x, "value") orelse "?" else "none"});
    // a POINTER scalar (`ip => goal`): its target's value
    try check(std.mem.eql(u8, valueOf(locals, "ip"), "5"), "ip = 5 ({s})", .{valueOf(locals, "ip")});
    try check(std.mem.eql(u8, valueOf(locals, "m"), "[2×3]"), "m = [2×3] ({s})", .{valueOf(locals, "m")});
    // the main program's variables that Flang makes static: globals of
    // their own names, not the frame's
    const statics = [_][2][]const u8{
        .{ "v", "[6.0, 2.0, 3.0]" },
        .{ "big", "[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, …]" },
        .{ "none", "not allocated" },
        .{ "nothing", "not associated" },
        .{ "goal", "5" },
        .{ "tg", "tagged(point=…, tag='hello   ', w=…)" },
        .{ "pts", "[labeled(…), labeled(…)]" },
    };
    for (statics) |x| try check(std.mem.eql(u8, valueOf(locals, x[0]), x[1]), "{s} = {s} ({s})", .{ x[0], x[1], valueOf(locals, x[0]) });
    const big = items(try c.request("variables", .{ .variablesReference = int(named(locals, "big").?, "variablesReference").? }), "variables");
    try check(big.len == 10 and std.mem.eql(u8, str(big[9], "name") orelse "", "(901:1000)"), "big in 10 sections, the last (901:1000) ({d})", .{big.len});
    const tgw = try c.request("evaluate", .{ .expression = "tg%w", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(tgw, "result") orelse "", "[0.25, 0.25]"), "tg%w = [0.25, 0.25] ({s})", .{str(tgw, "result") orelse "?"});
    // a module variable by its local name (`use counters, only: nhits => hits`)
    const counters = try moduleVariables(c, scopes, "counters");
    try check(std.mem.eql(u8, valueOf(counters, "nhits => hits"), "3"), "nhits => hits = 3 ({s})", .{valueOf(counters, "nhits => hits")});
    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and int(frames[0], "line") == main_line + 1, "next: line {d} ({?d})", .{ main_line + 1, int(frames[0], "line") });

    // the OPEN of a missing file: the filter stops where Flang's runtime
    // reports the error, before it aborts
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "exception") and std.mem.eql(u8, str(stopped, "description") orelse "", "Fortran runtime error"), "stopped by the filter: a Fortran runtime error ({s}: {s})", .{ str(stopped, "reason") orelse "?", str(stopped, "description") orelse "?" });
    const info = try c.request("exceptionInfo", .{ .threadId = thread });
    try check(contains(str(info, "exceptionId"), "CrashHeader"), "at Flang's CrashHeader ({s})", .{str(info, "exceptionId") orelse "?"});
    frames = items(try c.request("stackTrace", .{ .threadId = thread, .levels = 40 }), "stackFrames");
    const at_open = for (frames, 0..) |f, j| {
        if (std.mem.eql(u8, str(f, "name") orelse "", "MAIN") and int(f, "line") == main_line + 2) break j;
    } else null;
    try check(contains(str(frames[0], "name"), "Fortran::runtime::Terminator::CrashHeader") and at_open != null, "in Flang's runtime ({s}), called at line {d} of MAIN", .{ str(frames[0], "name") orelse "?", main_line + 2 });
    var buf: [512]u8 = undefined;
    try check(toStart(frames[at_open.? + 1 ..]), "MAIN, then main, mainCRTStartup ({s})", .{frameNames(&buf, frames[at_open.? + 1 ..])});
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
}

fn run(c: *Client, exe: []const u8, tmp: []const u8, src: []const u8, src_dir: []const u8) !void {
    const caps = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .linesStartAt1 = true });
    var filter = false;
    for (items(caps, "exceptionBreakpointFilters")) |f| filter = filter or std.mem.eql(u8, str(f, "filter") orelse "", "fortranRuntimeErrors");
    try check(filter, "the filter of Fortran runtime errors", .{});
    // the engine, not gdb (which `initialize` may have started)
    _ = try c.request("launch", .{ .program = exe, .cwd = tmp, .console = "internalConsole", .sourceRoot = src_dir, .dbgeng = true });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = 8 }} }), "breakpoints");
    const verified = bps.len > 0 and (get(bps[0], "verified") orelse Value{ .bool = false }).bool;
    try check(verified, "a verified breakpoint ({f})", .{std.json.fmt(if (bps.len > 0) bps[0] else Value.null, .{})});
    _ = try c.request("setExceptionBreakpoints", .{ .filters = .{} });
    _ = try c.request("configurationDone", .{});

    var stopped = get(try c.event("stopped"), "body").?;
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "breakpoint"), "stopped at the breakpoint", .{});
    const thread = int(stopped, "threadId").?;
    var frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(frames.len > 1 and contains(str(frames[0], "name"), "twice") and int(frames[0], "line") == 8, "in twice at line 8 ({s}:{?d})", .{ str(frames[0], "name") orelse "?", int(frames[0], "line") });
    try check(contains(str(frames[1], "name"), "main"), "called by main", .{});
    const scopes = items(try c.request("scopes", .{ .frameId = int(frames[0], "id").? }), "scopes");
    const local = items(try c.request("variables", .{ .variablesReference = int(scopes[0], "variablesReference").? }), "variables");
    const n = for (local) |v| {
        if (std.mem.eql(u8, str(v, "name") orelse "", "n")) break str(v, "value") orelse "?";
    } else "(none)";
    try check(std.mem.eql(u8, n, "21"), "n = 21 ({s})", .{n});
    // arrays, not empty strings (#726)
    const unknown = try c.request("variables", .{ .variablesReference = 999999 });
    try check(dap.isArray(unknown, "variables", 0), "an unknown reference: no variables ({f})", .{std.json.fmt(unknown, .{})});
    const functions = try c.request("setFunctionBreakpoints", .{ .breakpoints = .{.{ .name = "twice" }} });
    const none = items(functions, "breakpoints");
    try check(dap.isArray(functions, "breakpoints", 1) and get(none[0], "verified").?.bool == false, "a function breakpoint: unverified ({f})", .{std.json.fmt(functions, .{})});

    _ = try c.request("next", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and int(frames[0], "line") == 9, "next: line 9 ({?d})", .{int(frames[0], "line")});
    const r = try c.request("evaluate", .{ .expression = "doubled", .frameId = int(frames[0], "id").?, .context = "watch" });
    try check(std.mem.eql(u8, str(r, "result") orelse "", "42"), "doubled = 42 ({s})", .{str(r, "result") orelse "?"});

    _ = try c.request("stepOut", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    frames = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(std.mem.eql(u8, str(stopped, "reason") orelse "", "step") and contains(str(frames[0], "name"), "main"), "stepOut: back in main ({s})", .{str(frames[0], "name") orelse "?"});

    _ = try c.request("continue", .{ .threadId = thread });
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 3, "exit code 3 ({?d})", .{int(exited, "exitCode")});
    _ = try c.event("terminated");
    _ = try c.request("disconnect", .{ .terminateDebuggee = true });
    _ = try c.child.wait(c.io);
}
