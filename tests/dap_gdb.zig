//! zfls dap with gdb, on a program of gfortran's (tests/dap/grid.f90, built
//! with -fcheck=bounds), of LLVM Flang's (`--compiler flang`; on Windows
//! with DWARF, `-gdwarf-4 -Wl,-debug:dwarf`, and linked with zfls's ifx kit
//! when it is next to zfls) or of LFortran's (`--compiler lfortran`, not
//! on Windows, where LFortran refuses `-g`; its own session is
//! tests/dap_lfortran.zig's) or of Intel ifx's (`--compiler ifx`, Linux;
//! its own session is tests/dap_ifx_gdb.zig's): breakpoints, the stack, the variables as
//! Fortran (subscripts, sections, previews, not allocated, pointers, a
//! polymorphic argument, hidden lengths left out), the module variables of
//! a line, setting values, expressions, a Fortran runtime error, stopping
//! at the start with gdb commands, the program's exit, a stop at ERROR STOP
//! and none at STOP (tests/dap/stops.f90), a program that a
//! signal ends (its exit code and the signal named), gdb's own end told,
//! breakpoints of conditions, hit conditions and log messages, a
//! variable that gdb fails to show beside the others (Flang), and (on
//! Linux, with script(1)) the program in a terminal (`zig build
//! test-dap-gdb`). Skipped without the compiler or a gdb of the Debug
//! Adapter Protocol (gdb 14 or later).
//!
//!     dap_gdb --zfls ZFLS [--compiler gfortran|flang|lfortran|ifx] [--fc FC] [--gdb GDB] [--kit DIR]
//!
//! GFORTRAN (or FLANG, LFORTRAN, IFX) and GDB in the environment name them too. `--kit`
//! names the ifx kit for Flang on Windows (`zig build` gives its own, #442);
//! a link with it must read nothing of Visual Studio's.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

const dap = @import("dap_client.zig");
const dap_lfortran = @import("dap_lfortran.zig");
const dap_ifx_gdb = @import("dap_ifx_gdb.zig");
const dap_gfortran = @import("dap_gfortran.zig");
const dap_gdb_conditions = @import("dap_gdb_conditions.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

const source = "tests/dap/grid.f90";

const Compiler = enum { gfortran, flang, lfortran, ifx };

const Setup = struct {
    zfls: []const u8,
    gdb: []const u8,
    compiler: Compiler,
    /// The compiler's executable
    fc: []const u8,
    /// The build's environment (Flang's link with the ifx kit on Windows,
    /// LFortran's directory on the PATH)
    build_env: ?*const std.process.Environ.Map,
    /// This process's environment
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    src: []const u8,
    program: []const u8,
    work_line: i64,
    main_line: i64,
    call_line: i64,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var gdb: []const u8 = init.environ_map.get("GDB") orelse "gdb";
    var compiler: ?Compiler = .gfortran;
    var fc_arg: ?[]const u8 = null;
    var kit: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--gdb")) {
            gdb = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--compiler")) {
            compiler = std.meta.stringToEnum(Compiler, argv[i + 1]);
        } else if (std.mem.eql(u8, argv[i], "--fc") or std.mem.eql(u8, argv[i], "--gfortran")) {
            fc_arg = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--kit")) {
            kit = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null or compiler == null) {
        std.debug.print("usage: dap_gdb --zfls ZFLS [--compiler gfortran|flang|lfortran|ifx] [--fc FC] [--gdb GDB] [--kit DIR]\n", .{});
        return 2;
    }
    const fc = fc_arg orelse switch (compiler.?) {
        .gfortran => init.environ_map.get("GFORTRAN") orelse "gfortran",
        .flang => init.environ_map.get("FLANG") orelse "flang",
        .lfortran => init.environ_map.get("LFORTRAN") orelse "lfortran",
        .ifx => init.environ_map.get("IFX") orelse "ifx",
    };
    if (compiler.? == .ifx and builtin.target.os.tag == .windows) {
        std.debug.print("skipped: ifx's programs on Windows have Microsoft's debug information, the Debugger Engine's (tests/dap_windows.zig)\n", .{});
        return 0;
    }
    if (compiler.? == .lfortran and builtin.target.os.tag == .windows) {
        std.debug.print("skipped: LFortran for Windows refuses -g (#176)\n", .{});
        return 0;
    }
    const version = std.process.run(a, io, .{ .argv = &.{ gdb, "--version" } }) catch {
        std.debug.print("skipped: no {s}\n", .{gdb});
        return 0;
    };
    const v = zfls.dap_fortran.gdbVersion(version.stdout) orelse [2]u32{ 0, 0 };
    if (v[0] < 14) {
        std.debug.print("skipped: {s} is gdb {d}.{d}; the Debug Adapter Protocol needs gdb 14 or later\n", .{ gdb, v[0], v[1] });
        return 0;
    }
    const fc_version = std.process.run(a, io, .{ .argv = &.{ fc, "--version" } }) catch {
        std.debug.print("skipped: no {s}\n", .{fc});
        return 0;
    };
    std.debug.print("{s}\n", .{firstLine(fc_version.stdout)});

    const cwd = Io.Dir.cwd();
    const tmp = try lsp.tempDir(io, a, init.environ_map, "zfls-dap-gdb-");
    defer cwd.deleteTree(io, tmp) catch {};
    const text = try cwd.readFileAlloc(io, source, a, .limited(1 << 20));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, "grid.f90" });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    const program = try std.Io.Dir.path.join(a, &.{ tmp, if (builtin.target.os.tag == .windows) "grid.exe" else "grid" });
    const zfls_path = try cwd.realPathFileAlloc(io, zfls_exe.?, a);
    const setup: Setup = .{
        .zfls = zfls_path,
        .gdb = gdb,
        .compiler = compiler.?,
        .fc = fc,
        .environ = init.environ_map,
        .build_env = switch (compiler.?) {
            .flang => if (builtin.target.os.tag == .windows) try dap.flangKitEnv(io, a, init.environ_map, zfls_path, kit) else null,
            .lfortran => try dap_lfortran.buildEnv(io, a, init.environ_map, fc),
            .gfortran, .ifx => null,
        },
        .dir = tmp,
        .src = src,
        .program = program,
        // LFortran's PRINT has no line: its stop in work is a line before
        .work_line = lineOf(text, if (compiler.? == .lfortran) "LFortran stops here" else "stop here: work"),
        .main_line = lineOf(text, "stop here: main"),
        .call_line = lineOf(text, "call work("),
    };
    build(io, a, setup, src, program, &.{"-fcheck=bounds"}) catch return 1;
    std.debug.print("{s}, gdb {d}.{d}\n", .{ program, v[0], v[1] });

    var failed = false;
    inline for (.{ .{ "a session", walkThrough }, .{ "stopping at the start", atEntry }, .{ "ERROR STOP, not STOP", errorStop }, .{ "a crash", crash }, .{ "gdb's end", gdbEnds }, .{ "an associate name gdb cannot show", associated }, .{ "CHARACTER of kind 4", wideCharacters }, .{ "a module's COMMON blocks", commonBlocks }, .{ "gfortran's runtime errors and stops", gfortranRuntime }, .{ "conditions, hit conditions, logpoints", conditions }, .{ "a gdb that does not answer", silentGdb }, .{ "a terminal", terminal } }) |t| {
        std.debug.print("-- {s}\n", .{t[0]});
        t[1](io, init.gpa, setup) catch |e| {
            std.debug.print("{s}: {s}\n", .{ t[0], @errorName(e) });
            failed = true;
        };
    }
    if (failed) return 1;
    std.debug.print("zfls dap with gdb: all good\n", .{});
    return 0;
}

/// Builds `src` into `out` with the setup's compiler, for gdb: gfortran
/// with `gfortran_args` too; LLVM Flang with DWARF (on Windows also kept in
/// the program by lld-link, with the C runtime in DLLs and the ifx kit when
/// there is `build_env`), and elsewhere with its runtime's directory as the
/// program's run path (conda-forge's libflang-rt is a shared library)
fn build(io: Io, a: Allocator, setup: Setup, src: []const u8, out: []const u8, gfortran_args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, setup.fc);
    switch (setup.compiler) {
        .gfortran => {
            try argv.appendSlice(a, &.{ "-g", "-O0" });
            try argv.appendSlice(a, gfortran_args);
        },
        // its checks of bounds are on by default
        .lfortran => try argv.append(a, "-g"),
        // conda-forge's: its runtime's directory the program's run path
        .ifx => {
            try argv.appendSlice(a, &.{ "-g", "-O0", "-check", "bounds" });
            const exe = Io.Dir.cwd().realPathFileAlloc(io, setup.fc, a) catch setup.fc;
            try argv.append(a, try a.print("-Wl,-rpath,{s}", .{try std.Io.Dir.path.join(a, &.{ std.Io.Dir.path.dirname(exe) orelse ".", "..", "lib" })}));
        },
        .flang => if (builtin.target.os.tag == .windows) {
            try argv.appendSlice(a, &.{ "-gdwarf-4", "-O0", "-Wl,-debug:dwarf" });
            // lld-link's list of what it read, for the check below
            if (setup.build_env != null) try argv.appendSlice(a, &.{ "-fms-runtime-lib=dll", "-fuse-ld=lld", "-Wl,-verbose" });
        } else {
            try argv.appendSlice(a, &.{ "-g", "-O0" });
            // <prefix>/bin/flang: <prefix>/lib
            const exe = Io.Dir.cwd().realPathFileAlloc(io, setup.fc, a) catch setup.fc;
            const lib = try std.Io.Dir.path.join(a, &.{ std.Io.Dir.path.dirname(exe) orelse ".", "..", "lib" });
            try argv.append(a, try a.print("-Wl,-rpath,{s}", .{lib}));
            // conda-forge's Flang 23.1.5 for Linux looks for its intrinsic
            // modules under its driver's triple (x86_64-conda-linux-gnu),
            // but has them under x86_64-unknown-linux-gnu: without them,
            // passing an object to a CLASS dummy stops the compiler
            // ("runtime derived type info descriptor was not generated")
            if (try intrinsicModules(io, a, lib)) |dir| try argv.appendSlice(a, &.{ "-fintrinsic-modules-path", dir });
        },
    }
    try argv.appendSlice(a, &.{ "-o", out, src });
    const built = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = setup.dir }, .environ_map = setup.build_env });
    if (!built.term.success()) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ setup.fc, built.stdout, built.stderr });
        return error.BuildFailed;
    }
    // with the kit, nothing of Visual Studio's, where it is installed too
    if (setup.compiler == .flang and setup.build_env != null) {
        if (dap.visualStudioRead(built.stderr) orelse dap.visualStudioRead(built.stdout)) |line| {
            std.debug.print("FAIL: the link with the ifx kit read Visual Studio's files: {s}\n", .{line});
            return error.BuildFailed;
        }
    }
}

/// The directory of Flang's intrinsic modules under `lib` (the one with
/// `__fortran_type_info.mod` of `lib/clang/<version>/finclude/flang/<triple>`),
/// or null
fn intrinsicModules(io: Io, a: Allocator, lib: []const u8) !?[]const u8 {
    const clang = try std.Io.Dir.path.join(a, &.{ lib, "clang" });
    var versions = Io.Dir.cwd().openDir(io, clang, .{ .iterate = true }) catch return null;
    defer versions.close(io);
    var vit = versions.iterate();
    while (try vit.next(io)) |v| {
        const flang = try std.Io.Dir.path.join(a, &.{ clang, v.name, "finclude", "flang" });
        var triples = Io.Dir.cwd().openDir(io, flang, .{ .iterate = true }) catch continue;
        defer triples.close(io);
        var tit = triples.iterate();
        while (try tit.next(io)) |t| {
            const dir = try std.Io.Dir.path.join(a, &.{ flang, t.name });
            const mod = try std.Io.Dir.path.join(a, &.{ dir, "__fortran_type_info.mod" });
            Io.Dir.cwd().access(io, mod, .{}) catch continue;
            std.debug.print("intrinsic modules: {s}\n", .{dir});
            return dir;
        }
    }
    return null;
}

fn firstLine(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s[0 .. std.mem.findScalar(u8, s, '\n') orelse s.len], "\r");
}

/// The 1-based line of a marker of the source
fn lineOf(text: []const u8, marker: []const u8) i64 {
    const at = std.mem.find(u8, text, marker) orelse unreachable;
    return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
}

fn start(io: Io, gpa: Allocator, setup: Setup) !*Client {
    return Client.start(io, gpa, &.{ setup.zfls, "dap", "--gdb", setup.gdb });
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

fn named(vars: []Value, name: []const u8) !Value {
    for (vars) |x| if (std.mem.eql(u8, str(x, "name") orelse "", name)) return x;
    std.debug.print("FAIL: no {s} among", .{name});
    for (vars) |x| std.debug.print(" {s}", .{str(x, "name") orelse "?"});
    std.debug.print("\n", .{});
    return error.CheckFailed;
}

fn variables(c: *Client, v: Value) ![]Value {
    return items(try c.request("variables", .{ .variablesReference = int(v, "variablesReference") orelse 0 }), "variables");
}

fn eql(x: ?[]const u8, y: []const u8) bool {
    return std.mem.eql(u8, x orelse return false, y);
}

/// The elements' names, values and expressions: `(1)=6.0:a(1) ...`
fn listed(a: Allocator, vars: []Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (vars, 0..) |x, k| try out.print(a, "{s}{s}={s}:{s}", .{ if (k > 0) " " else "", str(x, "name") orelse "?", str(x, "value") orelse "?", str(x, "evaluateName") orelse "-" });
    return out.items;
}

fn walkThrough(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler == .ifx) return dap_ifx_gdb.walkThrough(io, gpa, .{
        .argv = &.{ setup.zfls, "dap", "--gdb", setup.gdb },
        .program = setup.program,
        .src = setup.src,
        .dir = setup.dir,
        .work_line = setup.work_line,
        .call_line = setup.call_line,
        .main_line = setup.main_line,
    });
    if (setup.compiler == .lfortran) return dap_lfortran.walkThrough(io, gpa, .{
        .argv = &.{ setup.zfls, "dap", "--gdb", setup.gdb },
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
    defer end(c);

    const caps = try c.request("initialize", .{ .adapterID = "fortran", .clientID = "test", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path", .supportsVariableType = true });
    const filters = items(caps, "exceptionBreakpointFilters");
    try check(filters.len > 0 and eql(str(filters[0], "filter"), "fortranRuntimeErrors"), "the filter of Fortran runtime errors first", .{});
    var ada = false;
    for (filters) |f| ada = ada or eql(str(f, "filter"), "assert");
    try check(!ada, "no Ada filters", .{});
    try check(get(caps, "supportsExceptionInfoRequest") != null, "exception info", .{});

    const launched = try c.send("launch", .{ .program = setup.program, .args = [_][]const u8{}, .cwd = setup.dir, .env = .{ .ZFLS_TEST = "1" }, .sourceRoot = setup.dir });
    _ = try c.event("initialized");
    const bps = items(try c.request("setBreakpoints", .{ .source = .{ .path = setup.src }, .breakpoints = .{ .{ .line = setup.work_line }, .{ .line = setup.main_line } } }), "breakpoints");
    try check(bps.len == 2, "two breakpoints", .{});
    const exc = items(try c.request("setExceptionBreakpoints", .{ .filters = .{"fortranRuntimeErrors"} }), "breakpoints");
    try check(exc.len == 1, "one exception filter", .{});
    _ = try c.request("setFunctionBreakpoints", .{ .breakpoints = [_]u8{} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    // no `gdb` in the configuration: the program's DWARF chose gdb, and zfls dap said so (#578)
    const said = try c.outputText(a);
    try check(std.mem.find(u8, said, "has DWARF debug information: debugging with gdb") != null, "the choice of gdb said: {s}", .{said});

    // in work: its arguments
    var stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    var stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(stack[0], "line") == setup.work_line, "stopped in work ({?d})", .{int(stack[0], "line")});
    var scopes = items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes");
    _ = try named(scopes, "Module variables");
    const unknown = try c.request("variables", .{ .variablesReference = 999999 });
    try check(dap.isArray(unknown, "variables", 0), "an unknown reference: no variables ({f})", .{std.json.fmt(unknown, .{})});

    const args = try variables(c, try named(scopes, "Arguments"));
    for (args) |x| try check(!eql(str(x, "name"), "_s"), "no hidden length ({s})", .{str(x, "name").?});
    const av = try named(args, "a");
    try check(eql(str(av, "value"), "[6.0, 2.0, 3.0]") and eql(str(av, "evaluateName"), "a"), "a = {s}", .{str(av, "value").?});
    const elements = try variables(c, av);
    try check(eql(try listed(a, elements), "(1)=6.0:a(1) (2)=2.0:a(2) (3)=3.0:a(3)"), "a's elements: {s}", .{try listed(a, elements)});
    // b: m(2:3,-1:1), assumed shape: from 1
    const b = try named(args, "b");
    try check(eql(str(b, "value"), "[2×3]"), "b = {s}", .{str(b, "value").?});
    const columns = try variables(c, b);
    try check(eql(try listed(a, columns), "(:,1)=[-10, -20]:b(:,1) (:,2)=[0, 0]:b(:,2) (:,3)=[10, 20]:b(:,3)"), "b's columns: {s}", .{try listed(a, columns)});
    const first = try variables(c, columns[0]);
    try check(eql(try listed(a, first), "(1,1)=-10:b(1,1) (2,1)=-20:b(2,1)"), "b's first column: {s}", .{try listed(a, first)});
    const sv = try named(args, "s");
    try check(eql(str(sv, "value"), "'abcdef'"), "s = {s} ({s})", .{ str(sv, "value").?, str(sv, "type") orelse "?" });
    const p = try named(args, "p");
    try check(eql(str(p, "value"), "point(x=9.0, y=-2.0, id=7)"), "p = {s}", .{str(p, "value").?});
    try check(eql(str(try named(try variables(c, p), "x"), "evaluateName"), "p%x"), "p%x", .{});
    // t: class(point), a tagged
    const t = try named(args, "t");
    try check(eql(str(t, "type"), "class(point)") and std.mem.startsWith(u8, str(t, "value") orelse "", "tagged("), "t: {s} = {s}", .{ str(t, "type") orelse "?", str(t, "value").? });
    const tc = try variables(c, t);
    try check(eql(str(try named(tc, "tag"), "value"), "'hello   '"), "t%tag = {s}", .{str(try named(tc, "tag"), "value").?});
    try check(eql(str(try named(tc, "w"), "value"), "[0.25, 0.25]"), "t%w = {s}", .{str(try named(tc, "w"), "value").?});
    const parent = try variables(c, try named(tc, "point"));
    try check(eql(str(try named(parent, "id"), "value"), "7"), "t%point%id = 7", .{});
    // ts: class(point) :: ts(:), of labeled: Flang's as its dynamic type
    // (#429); gfortran's are a class wrapper's
    if (setup.compiler == .flang) {
        const ts = try named(args, "ts");
        try check(eql(str(ts, "type"), "class(point) (2)") and eql(str(ts, "value"), "[labeled(…), labeled(…)]"), "ts: {s} = {s}", .{ str(ts, "type") orelse "?", str(ts, "value").? });
        const te = try variables(c, ts);
        try check(te.len == 2 and eql(str(te[1], "name"), "(2)"), "ts's elements: {s}", .{try listed(a, te)});
        try check(eql(str(try named(try variables(c, te[1]), "label"), "value"), "5"), "ts(2)%label = 5", .{});
    }

    // the module variables of the line: those of grid, its private one too
    var mv = try variables(c, try named(scopes, "Module variables"));
    try check(mv.len == 1 and eql(str(mv[0], "name"), "grid"), "module grid", .{});
    var grid = try variables(c, mv[0]);
    try check(eql(str(try named(grid, "ncells"), "value"), "42") and eql(str(try named(grid, "ncells"), "evaluateName"), "grid::ncells"), "grid::ncells = 42", .{});
    try check(eql(str(try named(grid, "secret"), "value"), "99"), "grid::secret = 99", .{});
    try check(eql(str(try named(grid, "origin"), "value"), "point(x=9.0, y=-2.0, id=7)"), "grid::origin = {s}", .{str(try named(grid, "origin"), "value").?});

    // setting a value, then an expression
    const set = try c.request("setVariable", .{ .variablesReference = int(av, "variablesReference").?, .name = "(2)", .value = "100" });
    try check(eql(str(set, "value"), "100.0"), "a(2) set to {s}", .{str(set, "value") orelse "?"});
    const frame = int(stack[0], "id").?;
    const hover = try c.request("evaluate", .{ .expression = "a", .frameId = frame, .context = "hover" });
    try check(eql(str(hover, "result"), "[6.0, 100.0, 3.0]"), "hover a = {s}", .{str(hover, "result") orelse "?"});
    const sum = try c.request("evaluate", .{ .expression = "a(2) + 1", .frameId = frame, .context = "watch" });
    try check(eql(str(sum, "result"), "101.0") and eql(str(sum, "type"), "real(kind=8)"), "a(2) + 1 = {s} ({s})", .{ str(sum, "result") orelse "?", str(sum, "type") orelse "?" });

    // in the main program: lower bounds, a large array, not allocated,
    // pointers, a module variable renamed
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(stack[0], "line") == setup.main_line, "stopped in main ({?d})", .{int(stack[0], "line")});
    scopes = items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes");
    const locals = try variables(c, try named(scopes, "Locals"));
    const none = try named(locals, "none");
    try check(eql(str(none, "value"), "not allocated") and int(none, "variablesReference") == 0, "none: {s}", .{str(none, "value").?});
    try check(eql(str(try named(locals, "nothing"), "value"), "not associated"), "nothing: {s}", .{str(try named(locals, "nothing"), "value").?});
    try check(eql(str(try named(locals, "ip"), "value"), "5"), "ip => goal: {s}", .{str(try named(locals, "ip"), "value").?});
    const m = try named(locals, "m");
    const mc = try variables(c, m);
    try check(eql(try listed(a, mc), "(:,-1)=[-10, -20]:m(:,-1) (:,0)=[0, 0]:m(:,0) (:,1)=[10, 20]:m(:,1)"), "m's columns: {s}", .{try listed(a, mc)});
    const m1 = try variables(c, mc[0]);
    try check(eql(try listed(a, m1), "(2,-1)=-10:m(2,-1) (3,-1)=-20:m(3,-1)"), "m's first column: {s}", .{try listed(a, m1)});
    const big = try named(locals, "big");
    try check(eql(str(big, "value"), "[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, …]"), "big = {s}", .{str(big, "value").?});
    const sections = try variables(c, big);
    try check(sections.len == 10 and eql(str(sections[5], "name"), "(501:600)") and eql(str(sections[5], "evaluateName"), "big(501:600)"), "big in 10 sections", .{});
    const s5 = try variables(c, sections[5]);
    try check(s5.len == 100 and eql(str(s5[0], "name"), "(501)") and eql(str(s5[0], "value"), "501.0") and eql(str(s5[0], "evaluateName"), "big(501)"), "big(501:600): {s}", .{try listed(a, s5[0..@min(s5.len, 2)])});

    mv = try variables(c, try named(scopes, "Module variables"));
    try check(mv.len == 2, "modules grid and counters ({d})", .{mv.len});
    grid = try variables(c, try named(mv, "grid"));
    for (grid) |x| try check(!eql(str(x, "name"), "secret"), "no private secret in main", .{});
    // a module's deferred-length CHARACTER: gfortran keeps its length apart
    try check(eql(str(try named(grid, "gname"), "value"), "'grid name'"), "grid::gname = {s}", .{str(try named(grid, "gname"), "value").?});
    const gname = try c.request("evaluate", .{ .expression = "gname", .frameId = int(stack[0], "id").?, .context = "watch" });
    try check(eql(str(gname, "result"), "'grid name'"), "evaluate gname = {s}", .{str(gname, "result") orelse "?"});
    // the module's COMMON block (`common /blk/ cx, cy`), of which gfortran's
    // DWARF has nothing
    try check(eql(str(try named(grid, "cx"), "value"), "1.5") and eql(str(try named(grid, "cy"), "value"), "2.5"), "grid::cx, cy = {s}, {s}", .{ str(try named(grid, "cx"), "value").?, str(try named(grid, "cy"), "value").? });
    const cy = try c.request("evaluate", .{ .expression = "cy", .frameId = int(stack[0], "id").?, .context = "watch" });
    try check(eql(str(cy, "result"), "2.5"), "evaluate cy = {s}", .{str(cy, "result") orelse "?"});
    const counters = try named(mv, "counters");
    const hits = try named(try variables(c, counters), "nhits => hits");
    try check(eql(str(hits, "value"), "3") and eql(str(hits, "evaluateName"), "counters::hits"), "nhits => hits = 3", .{});
    const set_hits = try c.request("setVariable", .{ .variablesReference = int(counters, "variablesReference").?, .name = "nhits => hits", .value = "4" });
    try check(eql(str(set_hits, "value"), "4"), "counters::hits set to {s}", .{str(set_hits, "value") orelse "?"});
    const nhits = try c.request("evaluate", .{ .expression = "nhits", .frameId = int(stack[0], "id").?, .context = "watch" });
    try check(eql(str(nhits, "result"), "4"), "nhits = {s}", .{str(nhits, "result") orelse "?"});

    // an array bound exceeded: a Fortran runtime error
    _ = try c.request("continue", .{ .threadId = thread });
    stopped = get(try c.event("stopped"), "body").?;
    try check(eql(str(stopped, "reason"), "exception"), "stopped by an exception ({s})", .{str(stopped, "reason") orelse "?"});
    const info = try c.request("exceptionInfo", .{ .threadId = thread });
    try check(eql(str(info, "description"), "Fortran runtime error"), "a Fortran runtime error ({s})", .{str(info, "exceptionId") orelse "?"});
    stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const ours = for (stack) |f| {
        if (!eql(str(f, "presentationHint"), "subtle")) break f;
    } else Value.null;
    try check(ours != .null and contains(str(get(ours, "source") orelse Value.null, "path"), "grid.f90"), "the program's frame first", .{});
}

fn atEntry(io: Io, gpa: Allocator, setup: Setup) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .columnsStartAt1 = true, .pathFormat = "path" });
    const launched = try c.send("launch", .{
        .program = setup.program,
        .cwd = setup.dir,
        .stopAtEntry = true,
        // a cppdbg configuration's MI command is left out
        .setupCommands = .{ Value{ .object = blk: {
            var o: std.json.ObjectMap = .empty;
            try o.put(arena.allocator(), "text", .{ .string = "-enable-pretty-printing" });
            break :blk o;
        } }, Value{ .string = "set print elements 2" } },
    });
    _ = try c.event("initialized");
    _ = try c.request("setExceptionBreakpoints", .{ .filters = [_][]const u8{} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const stopped = get(try c.event("stopped"), "body").?;
    const stack = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    try check(contains(str(get(stack[0], "source") orelse Value.null, "path"), "grid.f90") and int(stack[0], "line").? < setup.main_line, "stopped at the start ({?d})", .{int(stack[0], "line")});
    const shown = try c.request("evaluate", .{ .expression = "show print elements", .context = "repl", .frameId = int(stack[0], "id").? });
    try check(contains(str(shown, "result"), "2"), "set print elements 2 ({s})", .{str(shown, "result") orelse "?"});
    // without the filter, the runtime error ends the program: gfortran's
    // runtime exits, Flang's aborts, where gdb stops first (a signal)
    _ = try c.request("continue", .{ .threadId = int(stopped, "threadId").? });
    if (setup.compiler == .flang) {
        const aborted = get(try c.event("stopped"), "body").?;
        try check(!eql(str(aborted, "reason"), "exception") and !eql(str(aborted, "reason"), "breakpoint"), "stopped at the abort, not by the filter ({s})", .{str(aborted, "reason") orelse "?"});
        _ = try c.request("continue", .{ .threadId = int(stopped, "threadId").? });
    }
    const exited = get(try c.event("exited"), "body").?;
    try check((int(exited, "exitCode") orelse 0) != 0, "the program exited with {?d}", .{int(exited, "exitCode")});
    // SIGABRT ends Flang's on Linux: gdb's exitCode is 0, zfls's 128 + 6,
    // and the signal is named (#440)
    if (setup.compiler == .flang and builtin.target.os.tag == .linux) {
        const said = try c.outputText(arena.allocator());
        try check(int(exited, "exitCode") == 134 and contains(said, "SIGABRT (6)"), "ended by SIGABRT: {?d}, said: {s}", .{ int(exited, "exitCode"), said[said.len -| 200..] });
    }
    _ = try c.event("terminated");
}

/// tests/dap/stops.f90: the filter of Fortran runtime errors stops at its
/// ERROR STOP, not at its STOP
fn errorStop(io: Io, gpa: Allocator, setup: Setup) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.path.join(a, &.{ setup.dir, "stops.f90" });
    const exe = try std.Io.Dir.path.join(a, &.{ setup.dir, if (builtin.target.os.tag == .windows) "stops.exe" else "stops" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = try Io.Dir.cwd().readFileAlloc(io, "tests/dap/stops.f90", a, .limited(1 << 16)) });
    try build(io, a, setup, src, exe, &.{});
    try dap_lfortran.errorStop(io, gpa, &.{ setup.zfls, "dap", "--gdb", setup.gdb }, exe, setup.dir);
}

/// Breakpoints of a condition, a hit condition, a log message
/// (tests/dap_gdb_conditions.zig)
fn conditions(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler == .lfortran or setup.compiler == .ifx) return std.debug.print("skipped: gfortran's and Flang's\n", .{});
    const text = try Io.Dir.cwd().readFileAlloc(io, source, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try dap_gdb_conditions.run(io, gpa, .{
        .argv = &.{ setup.zfls, "dap", "--gdb", setup.gdb },
        .program = setup.program,
        .src = setup.src,
        .dir = setup.dir,
        .loop_line = lineOf(text, "m(:, k) = [10*k, 20*k]"),
        .main_line = setup.main_line,
    });
}

/// gfortran's runtime errors and stops beyond grid.f90's
/// (tests/dap_gfortran.zig)
fn gfortranRuntime(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler != .gfortran) return std.debug.print("skipped: gfortran only\n", .{});
    try dap_gfortran.run(io, gpa, &.{ setup.zfls, "dap", "--gdb", setup.gdb }, setup.fc, setup.dir, true);
}

/// A program that a signal ends (SIGSEGV): its exit code is 128 + 11, and
/// the signal is named (#440). gfortran's runtime on Windows catches the
/// signal and exits with 3 (MinGW's C runtime).
fn crash(io: Io, gpa: Allocator, setup: Setup) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.path.join(a, &.{ setup.dir, "crash.f90" });
    const exe = try std.Io.Dir.path.join(a, &.{ setup.dir, if (builtin.target.os.tag == .windows) "crash.exe" else "crash" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = "program crash\n  integer, pointer :: p => null()\n  p = 1\n  print *, p\nend program\n" });
    try build(io, a, setup, src, exe, &.{});

    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path" });
    const launched = try c.send("launch", .{ .program = exe, .cwd = setup.dir });
    _ = try c.event("initialized");
    _ = try c.request("setExceptionBreakpoints", .{ .filters = [_][]const u8{} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    // gdb stops at the signal (on Windows at its first and second chance,
    // and gfortran's runtime raises it again): on to the end
    const exited = for (0..6) |_| {
        const e = try c.eventOf(&.{ "stopped", "exited" });
        const body = get(e, "body").?;
        if (eql(str(e, "event"), "exited")) break body;
        _ = try c.request("continue", .{ .threadId = int(body, "threadId").? });
    } else return check(false, "the program ended", .{});
    const code = int(exited, "exitCode") orelse 0;
    const said = try c.outputText(a);
    if (setup.compiler == .gfortran and builtin.target.os.tag == .windows) {
        try check(code == 3, "the program exited with 3 ({d})", .{code});
    } else if (setup.compiler == .ifx) {
        // Intel's runtime catches the signal: "forrtl: severe (174): SIGSEGV"
        try check(code == 174, "the program exited with 174 ({d})", .{code});
    } else try check(code == 128 + 11 and contains(said, "SIGSEGV (11)"), "ended by SIGSEGV: {d}, said: {s}", .{ code, said[said.len -| 200..] });
    _ = try c.event("terminated");
}

/// gdb's own end while it debugs the program: the user is told, with
/// gdb's exit code, before the session's end (#439)
fn gdbEnds(io: Io, gpa: Allocator, setup: Setup) !void {
    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path" });
    const launched = try c.send("launch", .{ .program = setup.program, .cwd = setup.dir, .stopAtEntry = true });
    _ = try c.event("initialized");
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const stopped = get(try c.event("stopped"), "body").?;
    const stack = items(try c.request("stackTrace", .{ .threadId = int(stopped, "threadId").? }), "stackFrames");
    _ = try c.response(try c.send("evaluate", .{ .expression = "python import os; os._exit(7)", .context = "repl", .frameId = int(stack[0], "id").? }), "evaluate");
    const said = while (true) {
        const body = get(try c.event("output"), "body").?;
        if (eql(str(body, "category"), "important")) break body;
    };
    try check(contains(str(said, "output"), "gdb exited (7)"), "told that gdb exited: {s}", .{str(said, "output") orelse "?"});
    _ = try c.event("terminated");
}

/// A SELECT TYPE's associate name of an array of a type with allocatable
/// components (Flang's): gdb 17.2 has an internal error showing it, which
/// gdb survives, and the frame's other variables are shown (#439)
fn associated(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler != .flang) return std.debug.print("skipped: Flang only\n", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.path.join(a, &.{ setup.dir, "assoc.f90" });
    const exe = try std.Io.Dir.path.join(a, &.{ setup.dir, if (builtin.target.os.tag == .windows) "assoc.exe" else "assoc" });
    const text =
        \\module shapes
        \\  implicit none
        \\  type :: point
        \\    real :: x = 1.5
        \\  end type
        \\  type, extends(point) :: tagged
        \\    real, allocatable :: w(:)
        \\  end type
        \\end module
        \\program assoc
        \\  use shapes
        \\  implicit none
        \\  class(point), allocatable :: ts(:)
        \\  integer :: k
        \\  allocate(tagged :: ts(3))
        \\  select type (q => ts)
        \\  type is (tagged)
        \\    do k = 1, 3
        \\      allocate(q(k)%w(2)); q(k)%w = k
        \\    end do
        \\    print *, q(2)%w ! stop here
        \\  end select
        \\end program
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = text });
    try build(io, a, setup, src, exe, &.{});

    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path", .supportsVariableType = true });
    const launched = try c.send("launch", .{ .program = exe, .cwd = setup.dir });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = lineOf(text, "stop here") }} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    const stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const scopes = items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes");
    const locals = try variables(c, try named(scopes, "Locals"));
    try check(eql(str(try named(locals, "k"), "value"), "4"), "k = {s}, beside q = {s}", .{ str(try named(locals, "k"), "value").?, str(try named(locals, "q"), "value").? });
    try check(std.mem.startsWith(u8, str(try named(locals, "ts"), "value") orelse "", "["), "ts = {s}", .{str(try named(locals, "ts"), "value").?});
    _ = try c.request("continue", .{ .threadId = thread });
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 0, "the program exited with 0 ({?d})", .{int(exited, "exitCode")});
}

/// A gdb that takes the Debug Adapter Protocol's requests and answers
/// none: `initialize` fails after the time given (ZFLS_DAP_ANSWER_TIMEOUT),
/// rather than leaving the client waiting for ever (#374)
fn silentGdb(io: Io, gpa: Allocator, setup: Setup) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = builtin.target.os.tag == .windows;
    const fake = try std.Io.Dir.path.join(a, &.{ setup.dir, if (windows) "silent-gdb.cmd" else "silent-gdb" });
    // gdb 17.2 with Python, as zfls checks; then it reads and says nothing
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fake, .data = if (windows)
        "@echo off\r\nif \"%1\"==\"--version\" (echo GNU gdb 17.2& exit /b 0)\r\nif \"%1\"==\"-nx\" (echo 42& exit /b 0)\r\nmore > nul\r\n"
    else
        "#!/bin/sh\ncase \"$1\" in --version) echo 'GNU gdb 17.2'; exit 0;; -nx) echo 42; exit 0;; esac\ncat > /dev/null\n" });
    if (!windows) try Io.Dir.cwd().setFilePermissions(io, fake, .executable_file, .{});
    var env = try setup.environ.clone(a);
    try env.put("ZFLS_DAP_ANSWER_TIMEOUT", "3");
    const c = try Client.startEnv(io, gpa, &.{ setup.zfls, "dap", "--gdb", fake }, &env);
    defer c.deinit();
    c.timeout = .fromSeconds(30);
    // an adapter that waits for ever is killed, not waited for
    silentInitialize(c) catch |e| {
        if (c.child.id != null) c.child.kill(io);
        return e;
    };
    end(c);
}

fn silentInitialize(c: *Client) !void {
    const r = try c.response(try c.send("initialize", .{ .adapterID = "fortran", .pathFormat = "path" }), "initialize");
    const ok = if (get(r, "success")) |v| v == .bool and v.bool else false;
    try check(!ok and contains(str(r, "message"), "gdb gave no answer to initialize in 3 s"), "initialize failed: {s}", .{str(r, "message") orelse "(no message)"});
}

/// The program's input and output in a terminal, which script(1) gives a
/// command (Linux)
fn terminal(io: Io, gpa: Allocator, setup: Setup) !void {
    if (builtin.target.os.tag != .linux) return std.debug.print("skipped: Linux only\n", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    _ = std.process.run(a, io, .{ .argv = &.{ "script", "--version" } }) catch return std.debug.print("skipped: no script(1)\n", .{});
    const reader_src = try std.Io.Dir.path.join(a, &.{ setup.dir, "reader.f90" });
    const reader_exe = try std.Io.Dir.path.join(a, &.{ setup.dir, "reader" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = reader_src, .data = "program reader\n  integer :: n\n  read(*, *) n\n  print '(a,i0)', 'read ', n\nend program\n" });
    try build(io, a, setup, reader_src, reader_exe, &.{});

    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .pathFormat = "path", .supportsRunInTerminalRequest = true });
    const launched = try c.send("launch", .{ .program = reader_exe, .cwd = setup.dir, .console = "integratedTerminal" });
    const asked = try c.adapterRequest();
    try check(eql(str(asked, "command"), "runInTerminal"), "a terminal asked for", .{});
    const cmd_args = items(get(asked, "arguments").?, "args");
    var command: std.ArrayList(u8) = .empty;
    for (cmd_args, 0..) |x, k| {
        if (k > 0) try command.append(a, ' ');
        try command.append(a, '\'');
        for (x.string) |ch| if (ch == '\'') try command.appendSlice(a, "'\\''") else try command.append(a, ch);
        try command.append(a, '\'');
    }
    var term = try std.process.spawn(io, .{ .argv = &.{ "script", "-qfec", command.items, "/dev/null" }, .cwd = .{ .path = setup.dir }, .stdin = .pipe, .stdout = .pipe });
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

/// CHARACTER of kind 4 (gfortran's `selected_char_kind('ISO_10646')`): a
/// scalar, and arrays of them, whose type gdb gives with the length as a
/// first dimension, as Fortran strings with their subscripts (#533, #617)
fn wideCharacters(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler != .gfortran) return std.debug.print("skipped: gfortran only\n", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.path.join(a, &.{ setup.dir, "wide.f90" });
    const exe = try std.Io.Dir.path.join(a, &.{ setup.dir, if (builtin.target.os.tag == .windows) "wide.exe" else "wide" });
    const text =
        \\program wide
        \\  implicit none
        \\  integer, parameter :: ucs4 = selected_char_kind('ISO_10646')
        \\  character(kind=ucs4, len=3) :: grid(3,2)
        \\  character(kind=ucs4, len=4) :: row(2)
        \\  character(kind=ucs4, len=5) :: word
        \\  grid = ucs4_'abc'
        \\  grid(2,1) = ucs4_'x' // char(int(z'EB'), ucs4) // ucs4_'y'
        \\  row = [ucs4_'wxyz', ucs4_'1234']
        \\  word = ucs4_'h' // char(int(z'EB'), ucs4) // ucs4_'llo'
        \\  print *, len(grid), size(row), len(word) ! stop here
        \\end program wide
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = text });
    try build(io, a, setup, src, exe, &.{});

    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path", .supportsVariableType = true });
    const launched = try c.send("launch", .{ .program = exe, .cwd = setup.dir });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = lineOf(text, "stop here") }} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    const stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const frame = int(stack[0], "id").?;
    const scopes = items(try c.request("scopes", .{ .frameId = frame }), "scopes");
    const locals = try variables(c, try named(scopes, "Locals"));
    const word = try named(locals, "word");
    try check(eql(str(word, "value"), "4_'h\u{EB}llo'"), "word = {s}", .{str(word, "value").?});
    const row = try named(locals, "row");
    try check(eql(str(row, "value"), "[4_'wxyz', 4_'1234']") and eql(str(row, "type"), "character(kind=4,len=4) (2)"), "row = {s} ({s})", .{ str(row, "value").?, str(row, "type") orelse "?" });
    const row2 = try named(try variables(c, row), "(2)");
    try check(eql(str(row2, "value"), "4_'1234'"), "row(2) = {s}", .{str(row2, "value").?});
    const grid = try named(locals, "grid");
    try check(eql(str(grid, "value"), "[3\u{D7}2]") and eql(str(grid, "type"), "character(kind=4,len=3) (3,2)"), "grid = {s} ({s})", .{ str(grid, "value").?, str(grid, "type") orelse "?" });
    const elements = try variables(c, grid);
    try check(elements.len == 6, "grid has 6 elements ({d})", .{elements.len});
    const g21 = try named(elements, "(2,1)");
    try check(eql(str(g21, "value"), "4_'x\u{EB}y'") and eql(str(try named(elements, "(3,2)"), "value"), "4_'abc'"), "grid(2,1) = {s}", .{str(g21, "value").?});
    // an element by its Fortran subscripts, which gdb takes without the length's
    const e21 = try c.request("evaluate", .{ .expression = "grid(2,1)", .frameId = frame, .context = "watch" });
    try check(eql(str(e21, "result"), "4_'x\u{EB}y'"), "evaluate grid(2,1) = {s}", .{str(e21, "result") orelse "?"});
    const by_name = try c.request("evaluate", .{ .expression = str(g21, "evaluateName").?, .frameId = frame, .context = "watch" });
    try check(eql(str(by_name, "result"), "4_'x\u{EB}y'"), "evaluate {s} = {s}", .{ str(g21, "evaluateName").?, str(by_name, "result") orelse "?" });
    _ = try c.request("continue", .{ .threadId = thread });
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 0, "the program exited with 0 ({?d})", .{int(exited, "exitCode")});
}

/// A module's COMMON block, of which gfortran's DWARF has only the block's
/// symbol: its variables of every type and shape in the module's scope,
/// and in expressions with operators (#547, #618)
fn commonBlocks(io: Io, gpa: Allocator, setup: Setup) !void {
    if (setup.compiler != .gfortran) return std.debug.print("skipped: gfortran only\n", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try std.Io.Dir.path.join(a, &.{ setup.dir, "blocks.f90" });
    const exe = try std.Io.Dir.path.join(a, &.{ setup.dir, if (builtin.target.os.tag == .windows) "blocks.exe" else "blocks" });
    const text =
        \\module blocks
        \\  implicit none
        \\  type :: point
        \\    sequence
        \\    real :: x
        \\    integer :: id
        \\  end type
        \\  real :: cx
        \\  integer :: cm(2,3)
        \\  logical :: cl
        \\  character(len=4) :: cs
        \\  complex :: cz
        \\  type(point) :: cp
        \\  common /blk/ cx, cm, cl, cs, cz
        \\  common /pts/ cp
        \\end module
        \\program main
        \\  use blocks
        \\  implicit none
        \\  integer :: i, j
        \\  type(point) :: lp
        \\  cx = 1.5
        \\  do j = 1, 3
        \\    do i = 1, 2
        \\      cm(i,j) = 10*i + j
        \\    end do
        \\  end do
        \\  cl = .true.
        \\  cs = 'abcd'
        \\  cz = (1.0, -2.0)
        \\  cp = point(9.0, 7)
        \\  lp = cp
        \\  print *, cx, cm, cl, cs, cz, lp%id ! stop here
        \\end program
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = text });
    try build(io, a, setup, src, exe, &.{});

    const c = try start(io, gpa, setup);
    defer c.deinit();
    defer end(c);
    _ = try c.request("initialize", .{ .adapterID = "fortran", .linesStartAt1 = true, .pathFormat = "path", .supportsVariableType = true });
    const launched = try c.send("launch", .{ .program = exe, .cwd = setup.dir, .sourceRoot = setup.dir });
    _ = try c.event("initialized");
    _ = try c.request("setBreakpoints", .{ .source = .{ .path = src }, .breakpoints = .{.{ .line = lineOf(text, "stop here") }} });
    _ = try c.request("configurationDone", .{});
    _ = try Client.bodyOf(try c.response(launched, "launch"), "launch");
    const stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    const stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    const frame = int(stack[0], "id").?;
    const scopes = items(try c.request("scopes", .{ .frameId = frame }), "scopes");
    const blocks = try variables(c, try named(try variables(c, try named(scopes, "Module variables")), "blocks"));
    const want = [_][2][]const u8{ .{ "cx", "1.5" }, .{ "cl", ".TRUE." }, .{ "cs", "'abcd'" }, .{ "cz", "(1.0, -2.0)" }, .{ "cp", "point(x=9.0, id=7)" } };
    for (want) |w| try check(eql(str(try named(blocks, w[0]), "value"), w[1]), "blocks::{s} = {s} ({s})", .{ w[0], str(try named(blocks, w[0]), "value").?, w[1] });
    const cm = try named(blocks, "cm");
    try check(eql(str(cm, "value"), "[2\u{D7}3]"), "blocks::cm = {s}", .{str(cm, "value").?});
    const column = try named(try variables(c, cm), "(:,3)");
    try check(eql(str(column, "value"), "[13, 23]"), "cm(:,3) = {s}", .{str(column, "value").?});
    const exprs = [_][2][]const u8{ .{ "cm(2,3)", "23" }, .{ "cx + 1", "2.5" }, .{ "cm(2,3) + cx", "24.5" }, .{ "cl .and. .true.", ".TRUE." }, .{ "cp%x", "9.0" }, .{ "blocks::cm(1,2)", "12" } };
    for (exprs) |e| {
        const r = try c.request("evaluate", .{ .expression = e[0], .frameId = frame, .context = "watch" });
        try check(eql(str(r, "result"), e[1]), "evaluate {s} = {s} ({s})", .{ e[0], str(r, "result") orelse "?", e[1] });
    }
    _ = try c.request("continue", .{ .threadId = thread });
    const exited = get(try c.event("exited"), "body").?;
    try check(int(exited, "exitCode") == 0, "the program exited with 0 ({?d})", .{int(exited, "exitCode")});
}
