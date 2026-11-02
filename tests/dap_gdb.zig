//! zfls dap with gdb, on a program of gfortran's (tests/dap/grid.f90, built
//! with -fcheck=bounds): breakpoints, the stack, the variables as Fortran
//! (subscripts, sections, previews, not allocated, pointers, a polymorphic
//! argument, hidden lengths left out), the module variables of a line,
//! setting values, expressions, a Fortran runtime error, stopping at the
//! start with gdb commands, the program's exit, and (on Linux, with
//! script(1)) the program in a terminal (`zig build test-dap-gdb`). Skipped
//! without gfortran or a gdb of the Debug Adapter Protocol (gdb 14 or
//! later).
//!
//!     dap_gdb --zfls ZFLS [--gfortran GFORTRAN] [--gdb GDB]
//!
//! GFORTRAN and GDB in the environment name them too.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

const dap = @import("dap_client.zig");
const Client = dap.Client;
const get = dap.get;
const str = dap.str;
const int = dap.int;
const items = dap.items;
const contains = dap.contains;
const check = dap.check;

const source = "tests/dap/grid.f90";

const Setup = struct {
    zfls: []const u8,
    gdb: []const u8,
    gfortran: []const u8,
    dir: []const u8,
    src: []const u8,
    program: []const u8,
    work_line: i64,
    main_line: i64,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var zfls_exe: ?[]const u8 = null;
    var gdb: []const u8 = init.environ_map.get("GDB") orelse "gdb";
    var gfortran: []const u8 = init.environ_map.get("GFORTRAN") orelse "gfortran";
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--zfls")) {
            zfls_exe = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--gdb")) {
            gdb = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--gfortran")) {
            gfortran = argv[i + 1];
        } else break;
    }
    if (i != argv.len or zfls_exe == null) {
        std.debug.print("usage: dap_gdb --zfls ZFLS [--gfortran GFORTRAN] [--gdb GDB]\n", .{});
        return 2;
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
    _ = std.process.run(a, io, .{ .argv = &.{ gfortran, "--version" } }) catch {
        std.debug.print("skipped: no {s}\n", .{gfortran});
        return 0;
    };

    const cwd = Io.Dir.cwd();
    const tmp = try lsp.tempDir(io, a, init.environ_map, "zfls-dap-gdb-");
    defer cwd.deleteTree(io, tmp) catch {};
    const text = try cwd.readFileAlloc(io, source, a, .limited(1 << 20));
    const src = try std.Io.Dir.path.join(a, &.{ tmp, "grid.f90" });
    try cwd.writeFile(io, .{ .sub_path = src, .data = text });
    const program = try std.Io.Dir.path.join(a, &.{ tmp, if (builtin.target.os.tag == .windows) "grid.exe" else "grid" });
    const built = try std.process.run(a, io, .{
        .argv = &.{ gfortran, "-g", "-O0", "-fcheck=bounds", "-o", program, src },
        .cwd = .{ .path = tmp },
    });
    if (!built.term.success()) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ gfortran, built.stdout, built.stderr });
        return 1;
    }
    const setup: Setup = .{
        .zfls = try cwd.realPathFileAlloc(io, zfls_exe.?, a),
        .gdb = gdb,
        .gfortran = gfortran,
        .dir = tmp,
        .src = src,
        .program = program,
        .work_line = lineOf(text, "stop here: work"),
        .main_line = lineOf(text, "stop here: main"),
    };
    std.debug.print("{s}, gdb {d}.{d}\n", .{ program, v[0], v[1] });

    var failed = false;
    inline for (.{ .{ "a session", walkThrough }, .{ "stopping at the start", atEntry }, .{ "a terminal", terminal } }) |t| {
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

    // in work: its arguments
    var stopped = get(try c.event("stopped"), "body").?;
    const thread = int(stopped, "threadId").?;
    var stack = items(try c.request("stackTrace", .{ .threadId = thread }), "stackFrames");
    try check(int(stack[0], "line") == setup.work_line, "stopped in work ({?d})", .{int(stack[0], "line")});
    var scopes = items(try c.request("scopes", .{ .frameId = int(stack[0], "id").? }), "scopes");
    _ = try named(scopes, "Module variables");

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
    try check(eql(str(try named(args, "s"), "value"), "'abcdef'"), "s = {s}", .{str(try named(args, "s"), "value").?});
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
    // without the filter, the bound exceeded ends the program
    _ = try c.request("continue", .{ .threadId = int(stopped, "threadId").? });
    const exited = get(try c.event("exited"), "body").?;
    try check((int(exited, "exitCode") orelse 0) != 0, "the program exited with {?d}", .{int(exited, "exitCode")});
    _ = try c.event("terminated");
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
    const built = try std.process.run(a, io, .{ .argv = &.{ setup.gfortran, "-g", "-o", reader_exe, reader_src } });
    try check(built.term.success(), "reader built", .{});

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
