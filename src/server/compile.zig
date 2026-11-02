//! Compiler diagnostics (`compiler_diagnostics`): when a file is opened or
//! saved, a compiler checks it (syntax only) on a thread of its own, after
//! compiling the workspace modules it uses whose .mod files are missing or
//! older than their sources; saving a module's file checks again the open
//! files that use it. With `compiler_on_change`, the unsaved text is checked
//! too, from a copy, after a pause in the edits; with `compiler_fypp`, fypp
//! runs on each file first. Its errors and warnings are published with
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

const is_windows = builtin.target.os.tag == .windows;
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
    self.postMessage(a, try a.print("compiler_diagnostics: unknown compiler \"{s}\"; it is one of gfortran, ifx, ifort, flang, nvfortran, nagfor or lfortran", .{name}), 2);
}

/// What asks for a check
pub const Trigger = enum {
    /// The file was opened
    open,
    /// Saved (unless `compiler_no_save`)
    save,
    /// Edited: its unsaved text, after `compiler_change_delay` (with
    /// `compiler_on_change`)
    change,
    /// `zfls/compilerCheck`, or a module the file uses was saved
    now,
};

/// One compiler run: the modules the file uses first, then the file
const Job = struct {
    arena: std.heap.ArenaAllocator,
    uri: []const u8,
    path: []const u8,
    id: compilers.Id,
    /// The executables to try, in order
    exes: []const []const u8,
    cwd: []const u8,
    /// The files of the modules it uses, in compile order: each one's
    /// arguments (the file last), and whether it is in fixed form
    deps: []const []const []const u8,
    deps_fixed: []const bool,
    /// The arguments, the file last
    args: []const []const u8,
    fixed: bool,
    /// The unsaved text, checked from a copy; null: the file as saved
    text: ?[]const u8 = null,
    /// Not run before this time (the awake clock): a check of edits waits
    /// for a pause in them
    not_before: i96 = 0,
    /// fypp's executable and arguments, when the files go through it first
    fypp: ?[]const []const u8 = null,
    /// Where the copies and fypp's output go
    work_dir: []const u8,
};

/// The thread that runs the compiler, and its queue of jobs
pub const Worker = struct {
    server: *Server,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(*Job) = .empty,
    stopping: bool = false,
    thread: ?std.Thread = null,
    /// A missing compiler, or fypp, is reported once
    reported_missing: bool = false,
    reported_missing_fypp: bool = false,

    fn run(w: *Worker) void {
        const io = w.server.io;
        while (true) {
            w.mutex.lockUncancelable(io);
            // the first job whose time has come, else a wait for one
            const job = while (true) {
                if (w.stopping) {
                    w.mutex.unlock(io);
                    return;
                }
                const now = Io.Clock.awake.now(io).nanoseconds;
                var wake: ?i96 = null;
                const due = for (w.queue.items, 0..) |j, i| {
                    if (j.not_before <= now) break i;
                    wake = if (wake) |t| @min(t, j.not_before) else j.not_before;
                } else null;
                if (due) |i| break w.queue.orderedRemove(i);
                if (wake) |t| {
                    w.cond.waitTimeout(io, &w.mutex, .{ .deadline = .{ .raw = .{ .nanoseconds = t }, .clock = .awake } }) catch {};
                } else w.cond.waitUncancelable(io, &w.mutex);
            };
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

/// The programs whose diagnostics are published with zfls's own
pub const Source = enum { compiler, fortitude, codee };

/// Frees the diagnostics kept for publication
pub fn deinitStore(self: *Server) void {
    for ([_]*std.StringHashMapUnmanaged([]u8){&self.own_diags} ++ ptrs(&self.external_diags)) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        m.deinit(self.gpa);
    }
}

fn ptrs(maps: *[@typeInfo(Source).@"enum".field_names.len]std.StringHashMapUnmanaged([]u8)) [maps.len]*std.StringHashMapUnmanaged([]u8) {
    var out: [maps.len]*std.StringHashMapUnmanaged([]u8) = undefined;
    for (maps, &out) |*m, *p| p.* = m;
    return out;
}

/// Publishes zfls's diagnostics of `uri` with the other sources' last ones
pub fn publish(self: *Server, a: Allocator, uri: []const u8, diags: []const lsp.Diagnostic) !void {
    const own = try json.stringify(a, try json.from(a, diags));
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    try store(self, &self.own_diags, uri, own);
    try send(self, a, uri);
}

/// Publishes the diagnostics of `uri` that `source` found with the others'
/// last ones (on the thread that ran it)
pub fn publishFrom(self: *Server, a: Allocator, source: Source, uri: []const u8, diags: []const lsp.Diagnostic) !void {
    const mine = try json.stringify(a, try json.from(a, diags));
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    try store(self, &self.external_diags[@backingInt(source)], uri, mine);
    try send(self, a, uri);
}

fn publishCompiler(self: *Server, a: Allocator, uri: []const u8, diags: []const lsp.Diagnostic) !void {
    return publishFrom(self, a, .compiler, uri, diags);
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

/// `textDocument/publishDiagnostics` of `uri`: the JSON arrays kept of each
/// source, joined (under `diag_lock`)
fn send(self: *Server, a: Allocator, uri: []const u8) !void {
    var items: std.ArrayList(u8) = .empty;
    for ([_]*std.StringHashMapUnmanaged([]u8){&self.own_diags} ++ ptrs(&self.external_diags)) |m| {
        const x = std.mem.trim(u8, m.get(uri) orelse continue, "[] \n");
        if (x.len == 0) continue;
        if (items.items.len > 0) try items.append(a, ',');
        try items.appendSlice(a, x);
    }
    const body = try a.print("{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":{s},\"diagnostics\":[{s}]}}}}", .{
        try json.stringify(a, .{ .string = uri }),
        items.items,
    });
    self.sendRaw(body);
}

/// `compiler_fypp`, null when it is not set
fn fyppExe(self: *const Server) ?[]const u8 {
    const f = std.mem.trim(u8, self.s.compiler_fypp orelse return null, " ");
    return if (f.len > 0) f else null;
}

/// Queues a compiler run of a workspace file, replacing one of the same
/// file that has not started
pub fn check(self: *Server, a: Allocator, uri: []const u8, path: []const u8, trigger: Trigger) anyerror!void {
    const id = compilerOf(self) orelse return;
    switch (trigger) {
        .save => if (self.s.compiler_no_save) return,
        .change => if (!self.s.compiler_on_change) return,
        .open, .now => {},
    }
    const file = self.workspace.get(path) orelse return;
    // no compiler reads fypp's directives: fypp has to run first
    if (fyppExe(self) == null and std.ascii.eqlIgnoreCase(std.Io.Dir.path.extension(path), ".fypp")) return;
    // the editor's text of an open file (a check of edits, or one asked
    // for); a check of edits waits for the modules to compile on saving
    const unsaved = (trigger == .change or trigger == .now) and self.open_docs.contains(path);
    const job = try makeJob(self, a, id, uri, file, unsaved, trigger != .change);
    errdefer freeJob(self.gpa, job);
    if (trigger == .change) job.not_before = Io.Clock.awake.now(self.io).nanoseconds + @as(i96, @max(0, self.s.compiler_change_delay)) * std.time.ns_per_ms;
    try enqueue(self, job);
    // the open files that use its modules: they have changed
    if (trigger == .save and !self.s.compiler_no_dependencies) try checkUsers(self, a, file);
}

/// Checks again the open files that use a module `file` defines
fn checkUsers(self: *Server, a: Allocator, file: *const FortranFile) !void {
    const ast = file.ast orelse return;
    var defined: std.ArrayList([]const u8) = .empty;
    for (ast.scope_list.items) |sc| if (sc.kind == .module) try defined.append(a, sc.name);
    if (defined.items.len == 0) return;
    var it = self.open_docs.keyIterator();
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.*, file.path)) continue;
        const other = self.workspace.get(p.*) orelse continue;
        if (usesAny(other, defined.items)) try check(self, a, try paths.pathToUri(a, other.path), other.path, .now);
    }
}

/// Whether `file` uses one of the modules `names`
fn usesAny(file: *const FortranFile, names: []const []const u8) bool {
    const ast = file.ast orelse return false;
    for (ast.scope_list.items) |sc| {
        if (sc.data != .scope) continue;
        for (sc.scopeDataConst().use.items) |u| {
            if (u.is_import) continue;
            for (names) |n| if (std.ascii.eqlIgnoreCase(n, u.mod_name)) return true;
        }
    }
    return false;
}

fn enqueue(self: *Server, job: *Job) !void {
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
        if (std.mem.eql(u8, w.queue.items[i].path, job.path)) {
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
        if (d.len > 0) return if (std.Io.Dir.path.isAbsolute(d)) d else paths.join(a, &.{ self.root_path, d });
    }
    return paths.join(a, &.{ try cacheDir(self, a, "mod"), @tagName(id) });
}

/// zfls's directory `kind` (`mod`, `work`) for the root
fn cacheDir(self: *Server, a: Allocator, kind: []const u8) ![]const u8 {
    const base = paths.cacheDir() orelse return paths.join(a, &.{ self.root_path, ".zfls", kind });
    return paths.join(a, &.{ base, kind, try pathKey(a, self.root_path) });
}

/// A short name for a path
fn pathKey(a: Allocator, path: []const u8) ![]const u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(path);
    return a.print("{x:0>16}", .{h.final()});
}

/// The executables to try: those of `compiler_path` (a file, or a directory
/// that holds the compiler), else the compiler's names, found on the PATH
fn executables(self: *Server, a: Allocator, id: compilers.Id) ![]const []const u8 {
    const names = compilers.executables(id);
    const configured = self.s.compiler_path orelse return names;
    if (configured.len == 0) return names;
    const p = if (std.Io.Dir.path.isAbsolute(configured)) configured else try paths.join(a, &.{ self.root_path, configured });
    if (!paths.isDir(self.io, p)) return a.dupe([]const u8, &.{p});
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| try out.append(a, try paths.join(a, &.{ p, if (is_windows) try a.print("{s}.exe", .{n}) else n }));
    return out.items;
}

/// A job for `file`: of the editor's text (`unsaved`) or the file as
/// saved, and compiling the modules it uses first (`with_deps`)
fn makeJob(self: *Server, a: Allocator, id: compilers.Id, uri: []const u8, file: *FortranFile, unsaved: bool, with_deps: bool) !*Job {
    const job = try self.gpa.create(Job);
    job.arena = .init(self.gpa);
    errdefer freeJob(self.gpa, job);
    const ja = job.arena.allocator();
    const mod_dir = try ja.dupe(u8, try modDir(self, a, id));
    Io.Dir.cwd().createDirPath(self.io, mod_dir) catch |e| self.log.warn("compiler_diagnostics: could not create {s}: {s}", .{ mod_dir, @errorName(e) });
    const o: compilers.Options = .{ .windows = is_windows, .mod_dir = mod_dir };
    var dep_args: std.ArrayList([]const []const u8) = .empty;
    var dep_fixed: std.ArrayList(bool) = .empty;
    if (with_deps and !self.s.compiler_no_dependencies) for (try dependencies(self, a, file)) |d| if (stale(self, a, d, mod_dir)) {
        try dep_args.append(ja, try argsOf(self, ja, id, d, o));
        try dep_fixed.append(ja, d.fixed);
    };
    var fypp: ?[]const []const u8 = null;
    if (fyppExe(self)) |exe| {
        var argv: std.ArrayList([]const u8) = .empty;
        // a path relative to the root; a name is looked for on the PATH
        const has_dir = std.mem.findAny(u8, exe, "/\\") != null;
        try argv.append(ja, try ja.dupe(u8, if (has_dir and !std.Io.Dir.path.isAbsolute(exe)) try paths.join(a, &.{ self.root_path, exe }) else exe));
        for (self.s.compiler_fypp_args.slice()) |x| try argv.append(ja, try ja.dupe(u8, x));
        fypp = argv.items;
    }
    job.* = .{
        .arena = job.arena,
        .uri = try ja.dupe(u8, uri),
        .path = try ja.dupe(u8, file.path),
        .id = id,
        .exes = try dupeAll(ja, try executables(self, a, id)),
        .cwd = try ja.dupe(u8, paths.dirname(file.path)),
        .deps = dep_args.items,
        .deps_fixed = dep_fixed.items,
        .args = try argsOf(self, ja, id, file, o),
        .fixed = file.fixed,
        .text = if (unsaved) try editorText(ja, file) else null,
        .fypp = fypp,
        .work_dir = try ja.dupe(u8, try cacheDir(self, a, "work")),
    };
    return job;
}

/// The text as the editor has it
pub fn editorText(a: Allocator, file: *const FortranFile) ![]const u8 {
    const lines = if (file.comment_markers.len > 0) file.raw_lines.items else file.lines.items;
    return std.mem.join(a, "\n", lines);
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
    for (self.s.compiler_include_dirs.slice()) |d| {
        const dir = if (std.Io.Dir.path.isAbsolute(d)) d else try paths.join(a, &.{ self.root_path, d });
        try args.appendSlice(a, try compilers.include(a, id, try a.dupe(u8, dir), o));
    }
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
        if (std.mem.findScalar(*FortranFile, out.items, f) == null) try out.append(a, f);
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
        const name = a.print("{s}.mod", .{sc.name}) catch return true;
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

/// `args` with its last one, the file, replaced by `file`
fn withFile(a: Allocator, args: []const []const u8, file: []const u8) ![]const []const u8 {
    const out = try a.dupe([]const u8, args);
    out[out.len - 1] = file;
    return out;
}

/// Runs fypp on `input` (`origin` or a copy of it) with line markers naming
/// it; returns its output file, or null when fypp failed (its message then
/// published for `origin` when `report`) or is missing (reported once)
fn runFypp(w: *Worker, a: Allocator, job: *const Job, origin: []const u8, input: []const u8, fixed: bool, report: bool) !?[]const u8 {
    const self = w.server;
    const io = self.io;
    const fypp = job.fypp.?;
    const stem = std.Io.Dir.path.stem(origin);
    const out = try paths.join(a, &.{ job.work_dir, "fypp", try pathKey(a, origin), try a.print("{s}{s}", .{ stem, if (fixed) ".f" else ".f90" }) });
    try Io.Dir.cwd().createDirPath(io, paths.dirname(out));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ fypp[0], "--line-numbering", "--line-marker-format=cpp" });
    if (fixed) try argv.append(a, "--fixed-format");
    try argv.appendSlice(a, fypp[1..]);
    // forward slashes: the path goes into the line markers, where a
    // backslash would be an escape
    const fwd = try a.dupe(u8, input);
    std.mem.replaceScalar(u8, fwd, '\\', '/');
    try argv.appendSlice(a, &.{ fwd, out });
    const r = std.process.run(a, io, .{
        .argv = argv.items,
        .cwd = .{ .path = paths.dirname(origin) },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |e| switch (e) {
        error.FileNotFound => {
            if (!w.reported_missing_fypp) {
                w.reported_missing_fypp = true;
                self.postMessage(a, try a.print("compiler_fypp: {s} was not found", .{fypp[0]}), 2);
            }
            return null;
        },
        else => return e,
    };
    if (r.term.success()) return out;
    const output = try std.mem.concat(a, u8, &.{ r.stdout, "\n", r.stderr });
    self.log.debug("compiler_fypp {s}: {s}", .{ origin, output });
    if (report) {
        const m = fyppMessage(output);
        const lines = try splitLines(a, job.text orelse Io.Dir.cwd().readFileAlloc(io, origin, a, .limited(64 * 1024 * 1024)) catch "");
        try publishCompiler(self, a, job.uri, &.{.{
            .range = rangeAt(lines, m.line, null, null, null),
            .message = m.text,
            .severity = compilers.Severity.@"error".lsp(),
            .source = "fypp",
        }});
    }
    return null;
}

/// The line (1-based, 0 when none) and text of fypp's error message
/// (`FILE:LINE[-LINE]: [error: ]TEXT`), else its last line
fn fyppMessage(output: []const u8) struct { line: usize, text: []const u8 } {
    var last: []const u8 = "fypp failed";
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        last = line;
        // the first `:DIGITS[-DIGITS]: ` (not a drive letter's colon)
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, line, i, ':')) |c| : (i = c + 1) {
            var j = c + 1;
            while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
            if (j == c + 1) continue;
            const n = std.fmt.parseInt(usize, line[c + 1 .. j], 10) catch continue;
            if (j < line.len and line[j] == '-') {
                j += 1;
                while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
            }
            if (!std.mem.startsWith(u8, line[j..], ": ")) continue;
            var text = line[j + 2 ..];
            if (std.mem.startsWith(u8, text, "error: ")) text = text["error: ".len..];
            return .{ .line = n, .text = text };
        }
    }
    return .{ .line = 0, .text = last };
}

fn runJob(w: *Worker, job: *Job) !void {
    const self = w.server;
    const io = self.io;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (job.deps, job.deps_fixed) |args, fixed| {
        if (w.stopped()) return;
        var dep_args = args;
        if (job.fypp != null) {
            const src = args[args.len - 1];
            dep_args = try withFile(a, args, (try runFypp(w, a, job, src, src, fixed, false)) orelse continue);
        }
        switch (runCompiler(w, a, job, dep_args)) {
            .ran => {},
            .missing => break,
            .failed => |e| self.log.warn("compiler_diagnostics: compiling {s}: {s}", .{ args[args.len - 1], @errorName(e) }),
        }
    }
    if (w.stopped()) return;
    // the file the compiler reads: the file, a copy of the unsaved text,
    // and either one through fypp; its messages may name any of them
    var aliases: std.ArrayList([]const u8) = .empty;
    try aliases.append(a, job.path);
    var target = job.path;
    if (job.text) |text| {
        target = try paths.join(a, &.{ job.work_dir, "unsaved", try pathKey(a, job.path), std.Io.Dir.path.basename(job.path) });
        try Io.Dir.cwd().createDirPath(io, paths.dirname(target));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = text });
        try aliases.append(a, target);
    }
    if (job.fypp != null) {
        target = (try runFypp(w, a, job, job.path, target, job.fixed, true)) orelse return;
        try aliases.append(a, target);
    }
    const output = switch (runCompiler(w, a, job, try withFile(a, job.args, target))) {
        .ran => |out| out,
        .missing => {
            if (!w.reported_missing) {
                w.reported_missing = true;
                self.postMessage(a, try a.print("compiler_diagnostics: {s} was not found{s}{s}", .{
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
    const text = job.text orelse Io.Dir.cwd().readFileAlloc(io, job.path, a, .limited(64 * 1024 * 1024)) catch "";
    const diags = try toDiagnostics(a, job, text, msgs, aliases.items);
    try publishCompiler(self, a, job.uri, diags);
}

/// The 0-based lines of `text`, without line ends
pub fn splitLines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    return out.items;
}

/// A path for comparing: normalized, and on Windows lowercase with
/// backslashes
pub fn comparable(a: Allocator, cwd: []const u8, p: []const u8) ![]const u8 {
    const abs = if (std.Io.Dir.path.isAbsolute(p)) p else try paths.join(a, &.{ cwd, p });
    const n = try paths.normpath(a, abs);
    if (!is_windows) return n;
    for (n) |*c| c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
    return n;
}

/// The range of a message at 1-based `line` and `column` (or the whole line
/// without one; an LFortran span when it has one)
pub fn rangeAt(lines: []const []const u8, line: usize, column: ?usize, end_line: ?usize, end_column: ?usize) lsp.Range {
    if (line == 0 or line > lines.len) return .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    const ln = line - 1;
    const text = lines[ln];
    const c = column orelse {
        const first = std.mem.findNone(u8, text, " \t") orelse 0;
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

/// The compiler's messages as diagnostics of the file, which they may name
/// as any of `aliases` (the file, its copy, fypp's output)
fn toDiagnostics(a: Allocator, job: *const Job, text: []const u8, msgs: []const compilers.Message, aliases: []const []const u8) ![]const lsp.Diagnostic {
    const lines = try splitLines(a, text);
    var here: std.ArrayList([]const u8) = .empty;
    for (aliases) |p| try here.append(a, try comparable(a, job.cwd, p));
    var out: std.ArrayList(lsp.Diagnostic) = .empty;
    for (msgs) |m| {
        const ours = if (m.file) |f| blk: {
            const named = try comparable(a, job.cwd, f);
            for (here.items) |h| if (std.mem.eql(u8, named, h)) break :blk true;
            break :blk false;
        } else true;
        var related: std.ArrayList(lsp.DiagnosticRelatedInformation) = .empty;
        for (m.related.items) |r| {
            const rpath = if (r.file) |f| (if (std.Io.Dir.path.isAbsolute(f)) f else try paths.join(a, &.{ job.cwd, f })) else job.path;
            const rl = r.line -| 1;
            const rc = (r.column orelse 1) -| 1;
            try related.append(a, .{
                .location = .{ .uri = try paths.pathToUri(a, try paths.normpath(a, rpath)), .range = .{ .start = .{ .line = rl, .character = rc }, .end = .{ .line = rl, .character = rc + 1 } } },
                .message = r.message,
            });
        }
        // a message about another file (an included one): at the top, with
        // its location
        const message = if (ours) m.message else try a.print("{s}:{d}: {s}", .{ m.file.?, m.line, m.message });
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

// --------------------------------------------------------------------------
// Requests

/// `zfls/compilerCheck` `{textDocument: {uri}}`: checks the file now
pub fn serveCheck(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
    const uri = params.textDocument.uri;
    try check(self, a, uri, try self.pathFromUri(a, uri), .now);
    return .null;
}

/// `zfls/compilerClear`: drops the compiler's diagnostics, the checks not
/// started, and zfls's .mod files (not those of `compiler_mod_dir`) and
/// copies, so that the next checks compile every module again
pub fn serveClear(self: *Server, a: Allocator) !Value {
    if (self.compiler) |w| {
        w.mutex.lockUncancelable(self.io);
        for (w.queue.items) |job| freeJob(self.gpa, job);
        w.queue.clearRetainingCapacity();
        w.mutex.unlock(self.io);
    }
    var uris: std.ArrayList([]const u8) = .empty;
    {
        self.diag_lock.lockUncancelable(self.io);
        defer self.diag_lock.unlock(self.io);
        var it = self.external_diags[@backingInt(Source.compiler)].keyIterator();
        while (it.next()) |k| try uris.append(a, try a.dupe(u8, k.*));
    }
    for (uris.items) |uri| try publishCompiler(self, a, uri, &.{});
    const mod = if (self.s.compiler_mod_dir == null) try cacheDir(self, a, "mod") else null;
    for ([_]?[]const u8{ mod, try cacheDir(self, a, "work") }) |dir| if (dir) |d| {
        Io.Dir.cwd().deleteTree(self.io, d) catch |e| self.log.warn("zfls/compilerClear: could not remove {s}: {s}", .{ d, @errorName(e) });
    };
    return .null;
}

test "fypp's message: its line and text" {
    const m = fyppMessage("C:/w/a.fypp:12: error: unknown directive\n");
    try std.testing.expectEqual(@as(usize, 12), m.line);
    try std.testing.expectEqualStrings("unknown directive", m.text);
    const range = fyppMessage("Traceback\n/w/b.fypp:3-5: macro failed\n");
    try std.testing.expectEqual(@as(usize, 3), range.line);
    try std.testing.expectEqualStrings("macro failed", range.text);
    const none = fyppMessage("something went wrong\n");
    try std.testing.expectEqual(@as(usize, 0), none.line);
    try std.testing.expectEqualStrings("something went wrong", none.text);
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
