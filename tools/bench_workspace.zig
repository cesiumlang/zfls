//! Benchmarks zfls, and optionally fortls, on a large Fortran workspace
//! (`zig build bench`).
//!
//! Copies the workspace to a temporary directory and drives each server
//! through the same LSP session, measuring:
//!
//! - workspace initialization (`initialize`, which parses every file);
//! - opening the largest file until its diagnostics arrive;
//! - latency of hover, definition, references, completion and signature help
//!   at positions sampled across that file;
//! - incremental edits to that file, each followed by a hover, and saves,
//!   each followed by a request (a save re-links the workspace);
//! - peak memory of the server process (Windows and Linux).
//!
//!     zig build bench -Doptimize=ReleaseSafe -- PATH/TO/json-fortran \
//!         [--fortls fortls] [--requests 200] [--edits 20] [--saves 5]
//!
//! `--fortls CMD` also runs fortls, started by CMD (split at spaces, such as
//! `fortls` or `python -m fortls`). Debug builds of zfls are much slower.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zfls = @import("zfls");
const lsp = @import("lsp_client");

const fortran_exts = [_][]const u8{ ".f", ".f90", ".f95", ".f03", ".f08", ".for", ".fpp" };
const Kind = enum { hover, definition, references, completion, signature };

fn method(kind: Kind) []const u8 {
    return switch (kind) {
        .hover => "textDocument/hover",
        .definition => "textDocument/definition",
        .references => "textDocument/references",
        .completion => "textDocument/completion",
        .signature => "textDocument/signatureHelp",
    };
}

const Args = struct {
    workspace: []const u8,
    zfls: []const u8,
    fortls: ?[]const u8 = null,
    requests: usize = 200,
    edits: usize = 20,
    saves: usize = 5,
};

const usage =
    \\usage: zig build bench [-Doptimize=ReleaseSafe] -- WORKSPACE [--fortls CMD]
    \\       [--requests N (200)] [--edits N (20)] [--saves N (5)]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var args: Args = .{ .workspace = "", .zfls = "" };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            args.workspace = arg;
            continue;
        }
        if (i + 1 >= argv.len) break;
        i += 1;
        const v = argv[i];
        if (std.mem.eql(u8, arg, "--zfls")) {
            args.zfls = v;
        } else if (std.mem.eql(u8, arg, "--fortls")) {
            args.fortls = v;
        } else if (std.mem.eql(u8, arg, "--requests")) {
            args.requests = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--edits")) {
            args.edits = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--saves")) {
            args.saves = try std.fmt.parseInt(usize, v, 10);
        } else {
            std.debug.print("unknown option {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    if (args.workspace.len == 0 or args.zfls.len == 0) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const cwd = Io.Dir.cwd();
    const src = try cwd.realPathFileAlloc(io, args.workspace, a);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;

    const zfls_exe = try cwd.realPathFileAlloc(io, args.zfls, a);
    try report(out, "zfls", try run(io, init.gpa, a, init.environ_map, "zfls", &.{zfls_exe}, src, args));
    try out.flush();
    if (args.fortls) |cmd| {
        var fortls: std.ArrayList([]const u8) = .empty;
        var words = std.mem.tokenizeScalar(u8, cmd, ' ');
        while (words.next()) |w| try fortls.append(a, w);
        try fortls.append(a, "--disable_autoupdate");
        try report(out, "fortls", try run(io, init.gpa, a, init.environ_map, "fortls", fortls.items, src, args));
        try out.flush();
    }
    return 0;
}

/// Peak resident memory of the process, in bytes
fn peakMemory(server: *lsp.Client, io: Io, a: Allocator) ?u64 {
    const id = server.child.id orelse return null;
    switch (builtin.target.os.tag) {
        .windows => {
            var c: ProcessMemoryCounters = undefined;
            c.cb = @sizeOf(ProcessMemoryCounters);
            if (K32GetProcessMemoryInfo(id, &c, c.cb) == .FALSE) return null;
            return c.PeakWorkingSetSize;
        },
        .linux => {
            const path = a.print("/proc/{d}/status", .{id}) catch return null;
            const status = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return null;
            var lines = std.mem.splitScalar(u8, status, '\n');
            while (lines.next()) |line| {
                if (!std.mem.startsWith(u8, line, "VmHWM:")) continue;
                var words = std.mem.tokenizeAny(u8, line["VmHWM:".len..], " \t");
                const kb = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
                return kb * 1024;
            }
            return null;
        },
        else => return null,
    }
}

const ProcessMemoryCounters = extern struct {
    cb: u32,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};

extern "kernel32" fn K32GetProcessMemoryInfo(
    process: std.os.windows.HANDLE,
    counters: *ProcessMemoryCounters,
    cb: u32,
) callconv(.winapi) std.os.windows.BOOL;

const Result = struct {
    file: []const u8,
    lines: usize,
    init: f64,
    open: f64,
    requests: std.EnumArray(Kind, std.ArrayList(f64)),
    edit: []f64,
    save: []f64,
    memory: ?u64,
};

fn seconds(io: Io, since: i96) f64 {
    return @as(f64, @floatFromInt(Io.Clock.awake.now(io).nanoseconds - since)) / 1e9;
}

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn isFortran(name: []const u8) bool {
    const ext = std.Io.Dir.path.extension(name);
    for (fortran_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Copies `src` to `dst` (leaving out .git directories), reads each copy
/// once, and returns the path of the largest Fortran file in it
fn copyWorkspace(io: Io, a: Allocator, src: []const u8, dst: []const u8) ![]const u8 {
    const cwd = Io.Dir.cwd();
    var from = try cwd.openDir(io, src, .{ .iterate = true });
    defer from.close(io);
    try cwd.createDirPath(io, dst);
    var to = try cwd.openDir(io, dst, .{});
    defer to.close(io);
    var walker = try from.walkSelectively(a);
    defer walker.deinit();
    var largest: []const u8 = "";
    var largest_size: u64 = 0;
    while (try walker.next(io)) |e| {
        switch (e.kind) {
            .directory => {
                if (std.mem.eql(u8, e.basename, ".git")) continue;
                try to.createDirPath(io, e.path);
                try walker.enter(io, e);
            },
            .file => {
                try Io.Dir.copyFile(e.dir, e.basename, to, e.path, io, .{});
                // The first read of a file that was just written can be far
                // slower than later ones (on Windows, the antivirus scans
                // it), which would otherwise be measured as part of
                // `initialize`
                const data = try to.readFileAlloc(io, e.path, a, .unlimited);
                defer a.free(data);
                if (isFortran(e.basename) and data.len > largest_size) {
                    largest_size = data.len;
                    largest = try a.dupe(u8, e.path);
                }
            },
            else => {},
        }
    }
    if (largest.len == 0) return error.NoFortranFiles;
    return largest;
}

const Pos = struct { kind: Kind, line: usize, character: usize };

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Request kinds and positions spread evenly over the file
fn positions(a: Allocator, text: []const u8, count: usize) ![]Pos {
    const Word = struct { line: usize, inside: usize, end: usize };
    var words: std.ArrayList(Word) = .empty;
    var calls: std.ArrayList(Pos) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var ln: usize = 0;
    while (lines.next()) |line| : (ln += 1) {
        const code = line[0 .. std.mem.findScalar(u8, line, '!') orelse line.len];
        var i: usize = 0;
        while (i < code.len) {
            if (!isWord(code[i])) {
                if (code[i] == '(' and i > 0 and isWord(code[i - 1]))
                    try calls.append(a, .{ .kind = .signature, .line = ln, .character = i + 1 });
                i += 1;
                continue;
            }
            const start = i;
            while (i < code.len and isWord(code[i])) i += 1;
            if (!std.ascii.isDigit(code[start])) try words.append(a, .{ .line = ln, .inside = start + 1, .end = i });
        }
    }
    var out: std.ArrayList(Pos) = .empty;
    const kinds = [_]Kind{ .hover, .definition, .references, .completion };
    const step = @max(1, words.items.len / @max(1, count));
    var i: usize = 0;
    var n: usize = 0;
    while (i < words.items.len and n < count) : ({
        i += step;
        n += 1;
    }) {
        const w = words.items[i];
        const kind = kinds[n % kinds.len];
        try out.append(a, .{ .kind = kind, .line = w.line, .character = if (kind == .completion) w.end else w.inside });
    }
    const signatures = count / 4;
    const call_step = @max(1, calls.items.len / @max(1, signatures));
    i = 0;
    n = 0;
    while (i < calls.items.len and n < signatures) : ({
        i += call_step;
        n += 1;
    }) try out.append(a, calls.items[i]);
    return out.items;
}

fn run(io: Io, gpa: Allocator, a: Allocator, env: *const std.process.Environ.Map, name: []const u8, cmd: []const []const u8, src: []const u8, args: Args) !Result {
    const dir = try lsp.tempDir(io, a, env, try a.print("zfls_bench_{s}_", .{name}));
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const work = try std.Io.Dir.path.join(a, &.{ dir, "ws" });
    const rel = try copyWorkspace(io, a, src, work);
    const big = try std.Io.Dir.path.join(a, &.{ work, rel });
    const uri = try zfls.paths.pathToUri(a, big);
    const text = try Io.Dir.cwd().readFileAlloc(io, big, a, .unlimited);
    const file = try a.dupe(u8, rel);
    std.mem.replaceScalar(u8, file, '\\', '/');
    var result: Result = .{
        .file = file,
        .lines = std.mem.countScalar(u8, text, '\n') + 1,
        .init = 0,
        .open = 0,
        .requests = .initFill(.empty),
        .edit = &.{},
        .save = &.{},
        .memory = null,
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, cmd);
    try argv.append(a, "--incremental_sync");
    const server = try lsp.Client.start(io, gpa, argv.items, null);
    defer server.deinit();
    errdefer server.kill();

    var start = now(io);
    _ = try server.request("initialize", .{
        .rootUri = try zfls.paths.pathToUri(a, work),
        .rootPath = work,
        .capabilities = .{},
    });
    result.init = seconds(io, start);
    try server.send("initialized", .{}, null);

    start = now(io);
    try server.send("textDocument/didOpen", .{ .textDocument = .{
        .uri = uri,
        .languageId = "fortran",
        .version = 1,
        .text = text,
    } }, null);
    try server.sync();
    result.open = seconds(io, start);

    const td = .{ .uri = uri };
    const LspPos = struct { line: usize, character: usize };
    for (try positions(a, text, args.requests)) |p| {
        const pos: LspPos = .{ .line = p.line, .character = p.character };
        start = now(io);
        if (p.kind == .references) {
            _ = try server.request(method(p.kind), .{ .textDocument = td, .position = pos, .context = .{ .includeDeclaration = true } });
        } else {
            _ = try server.request(method(p.kind), .{ .textDocument = td, .position = pos });
        }
        try result.requests.getPtr(p.kind).append(a, seconds(io, start));
    }

    // edits: a declaration after each of the first `implicit none`s of
    // procedures, then a hover there
    var targets: std.ArrayList(usize) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var ln: usize = 0;
    var seen: usize = 0;
    while (lines.next()) |line| : (ln += 1) {
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line, " \t\r\x0b\x0c"), "implicit none")) continue;
        seen += 1;
        if (seen == 1) continue;
        if (targets.items.len == args.edits) break;
        try targets.append(a, ln);
    }
    var edits: std.ArrayList(f64) = .empty;
    var version: i64 = 1;
    for (targets.items, 0..) |target, n| {
        const line = target + 1 + n; // earlier insertions moved it down
        version += 1;
        const at: LspPos = .{ .line = line, .character = 0 };
        start = now(io);
        try server.send("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = .{.{
                .range = .{ .start = at, .end = at },
                .text = try a.print("    integer :: zz_bench_{d}\n", .{n}),
            }},
        }, null);
        _ = try server.request("textDocument/hover", .{
            .textDocument = td,
            .position = LspPos{ .line = line, .character = 16 },
        });
        try edits.append(a, seconds(io, start));
    }
    result.edit = edits.items;

    var saves: std.ArrayList(f64) = .empty;
    for (0..args.saves) |_| {
        start = now(io);
        try server.send("textDocument/didSave", .{ .textDocument = td }, null);
        try server.sync();
        try saves.append(a, seconds(io, start));
    }
    result.save = saves.items;
    result.memory = peakMemory(server, io, a);
    _ = try server.close();
    return result;
}

fn lessThan(_: void, x: f64, y: f64) bool {
    return x < y;
}

/// `x` rounded to the nearest integer, halves to the even one
fn roundHalfEven(x: f64) usize {
    const f = @floor(x);
    const d = x - f;
    const n: usize = @intFromFloat(f);
    if (d > 0.5 or (d == 0.5 and n % 2 == 1)) return n + 1;
    return n;
}

fn summary(w: *Io.Writer, values: []f64) !void {
    if (values.len == 0) return w.writeAll("n/a");
    std.mem.sort(f64, values, {}, lessThan);
    const mid = values.len / 2;
    const median = if (values.len % 2 == 1) values[mid] else (values[mid - 1] + values[mid]) / 2;
    const p95 = values[@min(values.len - 1, roundHalfEven(0.95 * @as(f64, @floatFromInt(values.len - 1))))];
    try w.print("median {d:>8.1} ms  p95 {d:>8.1} ms  max {d:>8.1} ms  (n={d})", .{
        median * 1000, p95 * 1000, values[values.len - 1] * 1000, values.len,
    });
}

fn report(w: *Io.Writer, name: []const u8, r: Result) !void {
    var res = r;
    try w.print("\n== {s}: {s} ({d} lines)\n", .{ name, r.file, r.lines });
    try w.print("  initialize       {d:>8.1} ms\n", .{r.init * 1000});
    try w.print("  open             {d:>8.1} ms\n", .{r.open * 1000});
    for (std.enums.values(Kind)) |kind| {
        try w.print("  {s:<16} ", .{@tagName(kind)});
        try summary(w, res.requests.getPtr(kind).items);
        try w.writeByte('\n');
    }
    try w.writeAll("  edit + hover     ");
    try summary(w, r.edit);
    try w.writeAll("\n  save + request   ");
    try summary(w, r.save);
    try w.writeAll("\n  peak memory      ");
    if (r.memory) |m| {
        try w.print("{d:>8.1} MiB\n", .{@as(f64, @floatFromInt(m)) / (1 << 20)});
    } else try w.writeAll("n/a\n");
}

test "positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ps = try positions(arena.allocator(),
        \\call foo(x, 1e5) ! bar(y)
        \\y = f(z)
    , 8);
    // the words call, foo, x (1e5 is a number), y, f, z; the calls foo(, f(
    try std.testing.expectEqual(6 + 2, ps.len);
    try std.testing.expectEqual(Kind.hover, ps[0].kind);
    try std.testing.expectEqual(1, ps[0].character); // inside `call`
    try std.testing.expectEqual(Kind.completion, ps[3].kind);
    try std.testing.expectEqual(1, ps[3].line);
    try std.testing.expectEqual(1, ps[3].character); // after `y`
    try std.testing.expectEqual(Kind.signature, ps[6].kind);
    try std.testing.expectEqual(9, ps[6].character); // after `foo(`
    try std.testing.expectEqual(1, ps[7].line);
}

test "roundHalfEven" {
    try std.testing.expectEqual(10, roundHalfEven(9.5));
    try std.testing.expectEqual(28, roundHalfEven(28.5));
    try std.testing.expectEqual(3, roundHalfEven(2.6));
}
