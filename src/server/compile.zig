//! Compiler diagnostics (`compiler_diagnostics`): when a file is opened or
//! saved, a compiler checks it (syntax only) on a thread of its own, after
//! compiling the workspace modules it uses whose .mod files are missing or
//! older than their sources. Its errors and warnings are published with
//! zfls's own diagnostics of the file: each publication of either sends
//! both, the latest of each.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const str = @import("../str.zig");
const paths = @import("../paths.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const modgraph = @import("../modgraph.zig");
const compilers = @import("../compilers.zig");
const diagnostics = @import("diagnostics.zig");
const definition = @import("definition.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;

const is_windows = builtin.os.tag == .windows;
/// A compiler run that takes longer is stopped
const timeout_s = 120;

/// The compiler of `compiler_diagnostics`, null when it is off or unknown
pub fn compilerOf(self: *const Server) ?compilers.Id {
    const name = self.s.compiler_diagnostics orelse return null;
    return compilers.Id.fromName(std.mem.trim(u8, name, " "));
}

/// Warns about a `compiler_diagnostics` that is no compiler zfls knows
pub fn checkSetting(self: *Server, a: Allocator) !void {
    const name = self.s.compiler_diagnostics orelse return;
    const trimmed = std.mem.trim(u8, name, " ");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none") or compilerOf(self) != null) return;
    self.postMessage(a, try std.fmt.allocPrint(a, "compiler_diagnostics: unknown compiler \"{s}\"; it is one of gfortran, ifx, ifort, flang, nvfortran, nagfor or lfortran", .{name}), 2);
}

/// One compiler run: the modules the file uses first, then the file
const Job = struct {
    arena: std.heap.ArenaAllocator,
    uri: []const u8,
    path: []const u8,
    id: compilers.Id,
    /// The executables to try, in order
    exes: []const []const u8,
    cwd: []const u8,
    /// The arguments of each module's file, in compile order
    deps: []const []const []const u8,
    args: []const []const u8,
};

/// The thread that runs the compiler, and its queue of jobs
pub const Worker = struct {
    server: *Server,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(*Job) = .empty,
    stopping: bool = false,
    thread: ?std.Thread = null,
    /// A missing compiler is reported once
    reported_missing: bool = false,

    fn run(w: *Worker) void {
        const io = w.server.io;
        while (true) {
            w.mutex.lockUncancelable(io);
            while (w.queue.items.len == 0 and !w.stopping) w.cond.waitUncancelable(io, &w.mutex);
            if (w.stopping) {
                w.mutex.unlock(io);
                return;
            }
            const job = w.queue.orderedRemove(0);
            w.mutex.unlock(io);
            runJob(w, job) catch |e| w.server.log.err("compiler diagnostics of {s}: {s}", .{ job.path, @errorName(e) });
            freeJob(w.server.gpa, job);
        }
    }

    fn stopped(w: *Worker) bool {
        const io = w.server.io;
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        return w.stopping;
    }
};

fn freeJob(gpa: Allocator, job: *Job) void {
    job.arena.deinit();
    gpa.destroy(job);
}

/// Stops the compiler thread, after the run it is in (server shutdown)
pub fn stop(self: *Server) void {
    const w = self.compiler orelse return;
    const io = self.io;
    w.mutex.lockUncancelable(io);
    w.stopping = true;
    for (w.queue.items) |job| freeJob(self.gpa, job);
    w.queue.clearRetainingCapacity();
    w.cond.signal(io);
    w.mutex.unlock(io);
    if (w.thread) |t| t.join();
    w.queue.deinit(self.gpa);
    self.gpa.destroy(w);
    self.compiler = null;
}

/// Frees the diagnostics kept for publication
pub fn deinitStore(self: *Server) void {
    inline for (.{ &self.own_diags, &self.compiler_diags }) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        m.deinit(self.gpa);
    }
}

/// Publishes zfls's diagnostics of `uri` with the compiler's last ones
pub fn publish(self: *Server, a: Allocator, uri: []const u8, diags: []const lsp.Diagnostic) !void {
    const own = try json.stringify(a, try json.from(a, diags));
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    try store(self, &self.own_diags, uri, own);
    try send(self, a, uri, own, self.compiler_diags.get(uri) orelse "[]");
}

/// Publishes the compiler's diagnostics of `uri` with zfls's last ones (on
/// the compiler's thread)
fn publishCompiler(self: *Server, a: Allocator, uri: []const u8, diags: []const lsp.Diagnostic) !void {
    const mine = try json.stringify(a, try json.from(a, diags));
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    try store(self, &self.compiler_diags, uri, mine);
    try send(self, a, uri, self.own_diags.get(uri) orelse "[]", mine);
}

fn store(self: *Server, m: *std.StringHashMapUnmanaged([]u8), uri: []const u8, value: []const u8) !void {
    const copy = try self.gpa.dupe(u8, value);
    errdefer self.gpa.free(copy);
    const gop = try m.getOrPut(self.gpa, uri);
    if (gop.found_existing) {
        self.gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = self.gpa.dupe(u8, uri) catch |e| {
            m.removeByPtr(gop.key_ptr);
            return e;
        };
    }
    gop.value_ptr.* = copy;
}

/// `textDocument/publishDiagnostics` of the two JSON arrays, joined
fn send(self: *Server, a: Allocator, uri: []const u8, own: []const u8, compiled: []const u8) !void {
    const x = std.mem.trim(u8, own, "[] \n");
    const y = std.mem.trim(u8, compiled, "[] \n");
    const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":{s},\"diagnostics\":[{s}{s}{s}]}}}}", .{
        try json.stringify(a, .{ .string = uri }),
        x,
        if (x.len > 0 and y.len > 0) "," else "",
        y,
    });
    self.sendRaw(body);
}

/// Queues a compiler run of a workspace file (on opening and saving it),
/// replacing one of the same file that has not started
pub fn check(self: *Server, a: Allocator, uri: []const u8, path: []const u8) !void {
    const id = compilerOf(self) orelse return;
    const file = self.workspace.get(path) orelse return;
    // no compiler reads fypp's directives
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".fypp")) return;
    const job = try makeJob(self, a, id, uri, file);
    errdefer freeJob(self.gpa, job);
    const w = self.compiler orelse blk: {
        const w = try self.gpa.create(Worker);
        w.* = .{ .server = self };
        errdefer self.gpa.destroy(w);
        // a stack like the server's: nothing deep runs there
        w.thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, Worker.run, .{w});
        self.compiler = w;
        break :blk w;
    };
    const io = self.io;
    w.mutex.lockUncancelable(io);
    defer w.mutex.unlock(io);
    var i: usize = 0;
    while (i < w.queue.items.len) {
        if (std.mem.eql(u8, w.queue.items[i].path, path)) {
            freeJob(self.gpa, w.queue.orderedRemove(i));
        } else i += 1;
    }
    try w.queue.append(self.gpa, job);
    w.cond.signal(io);
}

/// The directory of the .mod files: `compiler_mod_dir`, else one per root
/// and compiler in zfls's cache
fn modDir(self: *Server, a: Allocator, id: compilers.Id) ![]const u8 {
    if (self.s.compiler_mod_dir) |d| {
        if (d.len > 0) return if (std.fs.path.isAbsolute(d)) d else paths.join(a, &.{ self.root_path, d });
    }
    var h = std.hash.Wyhash.init(0);
    h.update(self.root_path);
    const key = try std.fmt.allocPrint(a, "{x:0>16}", .{h.final()});
    const base = paths.cacheDir() orelse return paths.join(a, &.{ self.root_path, ".zfls", "mod", @tagName(id) });
    return paths.join(a, &.{ base, "mod", key, @tagName(id) });
}

/// The executables to try: those of `compiler_path` (a file, or a directory
/// that holds the compiler), else the compiler's names, found on the PATH
fn executables(self: *Server, a: Allocator, id: compilers.Id) ![]const []const u8 {
    const names = compilers.executables(id);
    const configured = self.s.compiler_path orelse return names;
    if (configured.len == 0) return names;
    const p = if (std.fs.path.isAbsolute(configured)) configured else try paths.join(a, &.{ self.root_path, configured });
    if (!paths.isDir(self.io, p)) return a.dupe([]const u8, &.{p});
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| try out.append(a, try paths.join(a, &.{ p, if (is_windows) try std.fmt.allocPrint(a, "{s}.exe", .{n}) else n }));
    return out.items;
}

fn makeJob(self: *Server, a: Allocator, id: compilers.Id, uri: []const u8, file: *FortranFile) !*Job {
    const job = try self.gpa.create(Job);
    job.arena = .init(self.gpa);
    errdefer freeJob(self.gpa, job);
    const ja = job.arena.allocator();
    const mod_dir = try ja.dupe(u8, try modDir(self, a, id));
    Io.Dir.cwd().createDirPath(self.io, mod_dir) catch |e| self.log.warn("compiler_diagnostics: could not create {s}: {s}", .{ mod_dir, @errorName(e) });
    const o: compilers.Options = .{ .windows = is_windows, .mod_dir = mod_dir };
    const deps = try dependencies(self, a, file);
    var dep_args: std.ArrayList([]const []const u8) = .empty;
    for (deps) |d| if (stale(self, a, d, mod_dir)) try dep_args.append(ja, try argsOf(self, ja, id, d, o));
    job.* = .{
        .arena = job.arena,
        .uri = try ja.dupe(u8, uri),
        .path = try ja.dupe(u8, file.path),
        .id = id,
        .exes = try dupeAll(ja, try executables(self, a, id)),
        .cwd = try ja.dupe(u8, paths.dirname(file.path)),
        .deps = dep_args.items,
        .args = try argsOf(self, ja, id, file, o),
    };
    return job;
}

fn dupeAll(a: Allocator, xs: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

/// The compiler's arguments for `file`: syntax only, its form, the
/// preprocessor and zfls's definitions when zfls preprocesses it, the .mod
/// directory, the include directories, then `compiler_args` (or the
/// compiler's defaults) and the file
fn argsOf(self: *Server, a: Allocator, id: compilers.Id, file: *const FortranFile, o: compilers.Options) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, try compilers.syntaxOnly(a, id, o));
    try args.appendSlice(a, if (file.fixed) compilers.fixedForm(id, o) else compilers.freeForm(id, o));
    if (file.preproc) {
        try args.appendSlice(a, compilers.preprocess(id, o));
        for (self.s.pp_defs.items) |d| try args.append(a, try compilers.define(a, id, d.name, d.value, o));
    }
    try args.appendSlice(a, try compilers.modOutput(a, id, o.mod_dir, o));
    try args.appendSlice(a, try compilers.include(a, id, try a.dupe(u8, paths.dirname(file.path)), o));
    for (try definition.includeDirs(self, a)) |d| try args.appendSlice(a, try compilers.include(a, id, try a.dupe(u8, d), o));
    if (self.s.compiler_args) |user| {
        for (user.slice()) |x| try args.append(a, try a.dupe(u8, x));
    } else try args.appendSlice(a, compilers.defaultArgs(id, o));
    try args.append(a, try a.dupe(u8, file.path));
    return args.items;
}

/// The workspace files that define the modules `file` uses, and those they
/// use, in compile order (dependencies first), without `file`
fn dependencies(self: *Server, a: Allocator, file: *FortranFile) ![]const *FortranFile {
    const ast = file.ast orelse return &.{};
    const units = try diagnostics.workspaceUnits(self, a);
    const g = try modgraph.build(a, units);
    const need = try a.alloc(bool, units.len);
    @memset(need, false);
    var todo: std.ArrayList(usize) = .empty;
    // the modules USE names in the file, and what its own units depend on
    for (ast.scope_list.items) |sc| {
        if (sc.data != .scope) continue;
        for (sc.scopeDataConst().use.items) |u| {
            if (u.is_import) continue;
            for (units, 0..) |m, j| if (m.kind == .module and m.nameLowerEql(u.mod_name)) try todo.append(a, j);
        }
    }
    for (units, 0..) |u, i| if (u.file_ast == ast) try todo.appendSlice(a, g.deps[i]);
    while (todo.pop()) |j| {
        if (need[j]) continue;
        need[j] = true;
        try todo.appendSlice(a, g.deps[j]);
    }
    var out: std.ArrayList(*FortranFile) = .empty;
    for (g.components) |members| for (members) |i| {
        const u = units[i];
        if (!need[i] or u.file_ast == ast) continue;
        const f = self.workspace.get(u.file_ast.path orelse continue) orelse continue;
        if (std.mem.indexOfScalar(*FortranFile, out.items, f) == null) try out.append(a, f);
    };
    return out.items;
}

/// Whether a module file needs compiling: one of its modules has no .mod
/// file, or an older one; a file of submodules only always does
fn stale(self: *Server, a: Allocator, file: *const FortranFile, mod_dir: []const u8) bool {
    const ast = file.ast orelse return true;
    const src = Io.Dir.cwd().statFile(self.io, file.path, .{}) catch return true;
    var modules: usize = 0;
    for (ast.scope_list.items) |sc| {
        if (sc.kind != .module) continue;
        modules += 1;
        const name = std.fmt.allocPrint(a, "{s}.mod", .{sc.name}) catch return true;
        const mod = paths.join(a, &.{ mod_dir, std.ascii.lowerString(name, name) }) catch return true;
        const st = Io.Dir.cwd().statFile(self.io, mod, .{}) catch return true;
        if (st.mtime.nanoseconds < src.mtime.nanoseconds) return true;
    }
    return modules == 0;
}

// --------------------------------------------------------------------------
// On the compiler's thread

const Output = union(enum) {
    ran: []const u8,
    /// None of the executables was found
    missing,
    failed: anyerror,
};

/// Runs the compiler with `args`, trying each executable
fn runCompiler(w: *Worker, a: Allocator, job: *const Job, args: []const []const u8) Output {
    const io = w.server.io;
    for (job.exes) |exe| {
        const argv = a.alloc([]const u8, args.len + 1) catch |e| return .{ .failed = e };
        argv[0] = exe;
        @memcpy(argv[1..], args);
        const r = std.process.run(a, io, .{
            .argv = argv,
            .cwd = .{ .path = job.cwd },
            .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
        }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return .{ .failed = e },
        };
        return .{ .ran = std.mem.concat(a, u8, &.{ r.stdout, "\n", r.stderr }) catch |e| return .{ .failed = e } };
    }
    return .missing;
}

fn runJob(w: *Worker, job: *Job) !void {
    const self = w.server;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (job.deps) |args| {
        if (w.stopped()) return;
        switch (runCompiler(w, a, job, args)) {
            .ran => {},
            .missing => break,
            .failed => |e| self.log.warn("compiler_diagnostics: compiling {s}: {s}", .{ args[args.len - 1], @errorName(e) }),
        }
    }
    if (w.stopped()) return;
    const output = switch (runCompiler(w, a, job, job.args)) {
        .ran => |out| out,
        .missing => {
            if (!w.reported_missing) {
                w.reported_missing = true;
                self.postMessage(a, try std.fmt.allocPrint(a, "compiler_diagnostics: {s} was not found{s}{s}", .{
                    @tagName(job.id),
                    if (self.s.compiler_path != null) " at " else " on the PATH",
                    self.s.compiler_path orelse "",
                }), 2);
            }
            return;
        },
        .failed => |e| {
            self.log.warn("compiler_diagnostics: running {s} on {s}: {s}", .{ @tagName(job.id), job.path, @errorName(e) });
            return;
        },
    };
    self.log.debug("compiler_diagnostics {s}: {s}", .{ job.path, output });
    const msgs = try compilers.parse(a, job.id, output);
    const text = Io.Dir.cwd().readFileAlloc(self.io, job.path, a, .limited(64 * 1024 * 1024)) catch "";
    const diags = try toDiagnostics(a, job, text, msgs);
    try publishCompiler(self, a, job.uri, diags);
}

/// The 0-based lines of `text`, without line ends
fn splitLines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    return out.items;
}

/// A path for comparing: normalized, and on Windows lowercase with
/// backslashes
fn comparable(a: Allocator, cwd: []const u8, p: []const u8) ![]const u8 {
    const abs = if (std.fs.path.isAbsolute(p)) p else try paths.join(a, &.{ cwd, p });
    const n = try paths.normpath(a, abs);
    if (!is_windows) return n;
    for (n) |*c| c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
    return n;
}

/// The range of a message at 1-based `line` and `column` (or the whole line
/// without one; an LFortran span when it has one)
fn rangeAt(lines: []const []const u8, line: usize, column: ?usize, end_line: ?usize, end_column: ?usize) lsp.Range {
    if (line == 0 or line > lines.len) return .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    const ln = line - 1;
    const text = lines[ln];
    const c = column orelse {
        const first = std.mem.indexOfNone(u8, text, " \t") orelse 0;
        return .{ .start = .{ .line = ln, .character = str.byteToUtf16(text, first) }, .end = .{ .line = ln, .character = str.byteToUtf16(text, text.len) } };
    };
    const start = @min(c -| 1, text.len);
    if (end_line) |el| if (el >= line and el <= lines.len) {
        const end_text = lines[el - 1];
        const ec = @min(end_column orelse end_text.len, end_text.len);
        return .{ .start = .{ .line = ln, .character = str.byteToUtf16(text, start) }, .end = .{ .line = el - 1, .character = str.byteToUtf16(end_text, ec) } };
    };
    // the name at the column, else one character
    var end = start;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    if (end == start) end = @min(start + 1, text.len);
    return .{ .start = .{ .line = ln, .character = str.byteToUtf16(text, start) }, .end = .{ .line = ln, .character = str.byteToUtf16(text, end) } };
}

fn toDiagnostics(a: Allocator, job: *const Job, text: []const u8, msgs: []const compilers.Message) ![]const lsp.Diagnostic {
    const lines = try splitLines(a, text);
    const here = try comparable(a, job.cwd, job.path);
    var out: std.ArrayList(lsp.Diagnostic) = .empty;
    for (msgs) |m| {
        const ours = if (m.file) |f| std.mem.eql(u8, try comparable(a, job.cwd, f), here) else true;
        var related: std.ArrayList(lsp.DiagnosticRelatedInformation) = .empty;
        for (m.related.items) |r| {
            const rpath = if (r.file) |f| (if (std.fs.path.isAbsolute(f)) f else try paths.join(a, &.{ job.cwd, f })) else job.path;
            const rl = r.line -| 1;
            const rc = (r.column orelse 1) -| 1;
            try related.append(a, .{
                .location = .{ .uri = try paths.pathToUri(a, try paths.normpath(a, rpath)), .range = .{ .start = .{ .line = rl, .character = rc }, .end = .{ .line = rl, .character = rc + 1 } } },
                .message = r.message,
            });
        }
        // a message about another file (an included one): at the top, with
        // its location
        const message = if (ours) m.message else try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ m.file.?, m.line, m.message });
        try out.append(a, .{
            .range = if (ours) rangeAt(lines, m.line, m.column, m.end_line, m.end_column) else rangeAt(lines, 0, null, null, null),
            .message = message,
            .severity = m.severity.lsp(),
            .code = m.code,
            .source = @tagName(job.id),
            .relatedInformation = if (related.items.len > 0) related.items else null,
        });
    }
    return out.items;
}

test "ranges: the name at the column, the whole line, a span" {
    const lines = [_][]const u8{ "program p", "  x = 1 + yy", "end" };
    const r = rangeAt(&lines, 2, 11, null, null);
    try std.testing.expectEqual(@as(usize, 10), r.start.character);
    try std.testing.expectEqual(@as(usize, 12), r.end.character);
    const whole = rangeAt(&lines, 2, null, null, null);
    try std.testing.expectEqual(@as(usize, 2), whole.start.character);
    try std.testing.expectEqual(@as(usize, 12), whole.end.character);
    const span = rangeAt(&lines, 1, 1, 3, 3);
    try std.testing.expectEqual(@as(usize, 2), span.end.line);
    try std.testing.expectEqual(@as(usize, 3), span.end.character);
    const none = rangeAt(&lines, 0, null, null, null);
    try std.testing.expectEqual(@as(usize, 0), none.end.character);
}
