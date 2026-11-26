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
const tools = @import("tools.zig");
const compiler_version = @import("compiler_version.zig");
const args_mod = @import("compile_args.zig");
const compilerOf = args_mod.compilerOf;
const userArgs = args_mod.userArgs;
const compilerPath = args_mod.compilerPath;
const executables = args_mod.executables;
const commandOf = args_mod.commandOf;
const argsOf = args_mod.argsOf;
const diagnostics = @import("diagnostics.zig");
const pending = @import("pending.zig");
const definition = @import("definition.zig");
const messages = @import("compile_messages.zig");
pub const rangeAt = messages.rangeAt;
const toDiagnostics = messages.toDiagnostics;
const include_site = @import("include_site.zig");

const Obj = objects.Obj;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const fsio = @import("../fsio.zig");

const is_windows = builtin.target.os.tag == .windows;
/// A compiler run that takes longer is stopped
const timeout_s = 120;

pub const anyCompiler = args_mod.anyCompiler;
pub const checkSetting = args_mod.checkSetting;

/// What asks for a check
pub const Trigger = enum {
    /// The file was opened
    open,
    /// Opened with a text that is not the file's (unsaved changes that the
    /// editor restored, a new file): the editor's text, from a copy
    open_unsaved,
    /// Saved (unless `compiler_no_save`)
    save,
    /// Edited: its unsaved text, after `compiler_change_delay` (with
    /// `compiler_on_change`)
    change,
    /// `zfls/compilerCheck`, or a module the file uses was saved
    now,
};

/// One compiler run: the modules the file uses first, then the file
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    uri: []const u8,
    path: []const u8,
    id: compilers.Id,
    /// The executables to try, in order
    exes: []const []const u8,
    /// `compiler_path` (settings can change while the job runs)
    compiler_path: ?[]const u8,
    /// Where the compiler runs: the directory of the file's command in
    /// compile_commands.json, else the file's; one of zfls's for a compiler
    /// that writes files there and on Windows (`compilers.runsInWorkDir`)
    cwd: []const u8,
    /// The files of the modules it uses, in compile order: each one's
    /// arguments (the file last), whether it is in fixed form, and where
    /// it is compiled
    deps: []const []const []const u8,
    deps_fixed: []const bool,
    deps_cwd: []const []const u8,
    /// The modules each of them defines, in lower case
    deps_modules: []const []const []const u8 = &.{},
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
    /// A missing compiler, or fypp, is reported once, and so is output
    /// that is not understood
    reported_missing: bool = false,
    reported_missing_fypp: bool = false,
    reported_unparsed: bool = false,
    reported_silent: bool = false,
    /// The compiler (or fypp) running, stopped at a shutdown
    running: tools.Running = .{},

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

/// Stops the compiler thread, and the program it is running (server
/// shutdown)
pub fn stop(self: *Server) void {
    const w = self.compiler orelse return;
    const io = self.io;
    w.running.stop(io);
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
    const own = try json.stringifyAll(a, diags);
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    try store(self, &self.own_diags, uri, own);
    _ = pending.settled(self, uri);
    try send(self, a, uri);
}

/// Publishes what is kept of `uri` if it still waits for zfls's diagnostics
/// of a changed text, which could not be computed
pub fn publishKept(self: *Server, a: Allocator, uri: []const u8) void {
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    if (pending.settled(self, uri)) send(self, a, uri) catch |e| self.logSendFailure(e);
}

/// Publishes the diagnostics of `uri` that `source` found with the others'
/// last ones (on the thread that ran it). While zfls's own of a changed
/// text wait to be computed, they are kept for that publication.
pub fn publishFrom(self: *Server, a: Allocator, source: Source, uri: []const u8, diags: []const lsp.Diagnostic) !void {
    const mine = try json.stringifyAll(a, diags);
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    try store(self, &self.external_diags[@backingInt(source)], uri, mine);
    if (pending.waiting(self, uri)) return;
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
    if (!anyCompiler(self)) return;
    switch (trigger) {
        .save => if (self.s.compiler_no_save) return,
        .change => if (!self.s.compiler_on_change) return,
        .open, .open_unsaved, .now => {},
    }
    const file = self.workspace.get(path) orelse return;
    // the compiler of the file's form; the modules it uses are compiled
    // with it too (.mod files of two compilers do not mix)
    const id = compilerOf(self, file.declared_fixed) orelse return;
    // no compiler reads fypp's directives: fypp has to run first
    if (fyppExe(self) == null and std.ascii.eqlIgnoreCase(std.Io.Dir.path.extension(path), ".fypp")) return;
    // the editor's text of an open file (a check of edits, or one asked
    // for); a check of edits waits for the modules to compile on saving
    const unsaved = (trigger == .change or trigger == .now or trigger == .open_unsaved) and self.open_docs.contains(path);
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

/// The directory of the .mod files: `compiler_mod_dir`, else one per root,
/// compiler and major version (when it is known: gfortran's, Flang's) in
/// zfls's cache. Two releases of a compiler do not always read each
/// other's: gfortran 15 and 16 write module version 16, which gfortran 9 to
/// 14 cannot read ("created by a different version of GNU Fortran", #526).
fn modDir(self: *Server, a: Allocator, id: compilers.Id, version: ?u32) ![]const u8 {
    if (self.s.compiler_mod_dir) |d| {
        if (d.len > 0) return if (std.Io.Dir.path.isAbsolute(d)) d else paths.join(a, &.{ self.root_path, d });
    }
    const name = if (version) |v| try a.print("{s}-{d}", .{ @tagName(id), v }) else @tagName(id);
    return paths.join(a, &.{ try cacheDir(self, a, "mod"), name });
}

/// Where a compiler's probe (its version, its predefined macros) runs: in
/// the workspace, as a compiler (or a script standing for one) may write
/// files where it runs; on Windows in zfls's work directory instead, where
/// no DLL of the workspace's is loaded (`compilers.runsInWorkDir`). Null:
/// zfls's own directory
pub fn probeDir(self: *Server, a: Allocator) ?[]const u8 {
    if (is_windows) {
        const dir = cacheDir(self, a, "work") catch return null;
        if (!std.Io.Dir.path.isAbsolute(dir)) return null;
        fsio.createDirPath(self.io, dir) catch return null;
        return dir;
    }
    return if (self.root_path.len > 0) self.root_path else null;
}

/// zfls's directory `kind` (`mod`, `work`) for the root
pub fn cacheDir(self: *Server, a: Allocator, kind: []const u8) ![]const u8 {
    const base = paths.cacheDir() orelse return paths.join(a, &.{ self.root_path, ".zfls", kind });
    return paths.join(a, &.{ base, kind, try pathKey(a, self.root_path) });
}

/// A short name for a path
fn pathKey(a: Allocator, path: []const u8) ![]const u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(path);
    return a.print("{x:0>16}", .{h.final()});
}

/// A job for `file`: of the editor's text (`unsaved`) or the file as
/// saved, and compiling the modules it uses first (`with_deps`)
fn makeJob(self: *Server, a: Allocator, id: compilers.Id, uri: []const u8, file: *FortranFile, unsaved: bool, with_deps: bool) !*Job {
    const job = try self.gpa.create(Job);
    job.arena = .init(self.gpa);
    errdefer freeJob(self.gpa, job);
    const ja = job.arena.allocator();
    // the settings of the file's form, for the modules it uses too
    const user = userArgs(self, file.declared_fixed);
    const cmd = try commandOf(self, a, file, user);
    const exes = try executables(self, a, id, compilerPath(self, file.declared_fixed));
    const known = compiler_version.of(self, a, id, exes);
    const mod_dir = try ja.dupe(u8, try modDir(self, a, id, known.version));
    fsio.createDirPath(self.io, mod_dir) catch |e| self.log.warn("compiler_diagnostics: could not create {s}: {s}", .{ mod_dir, @errorName(e) });
    const o: compilers.Options = .{ .windows = is_windows, .mod_dir = mod_dir, .version = known.version, .intrinsic_modules = known.intrinsic_modules, .openmp = !self.s.disable_openmp_conditional };
    const work_dir = try ja.dupe(u8, try cacheDir(self, a, "work"));
    // a directory of zfls's per file, not the source tree: Intel's
    // preprocessor output goes into it, and on Windows a DLL there would be
    // loaded (`compilers.runsInWorkDir`)
    const run_dir: ?[]const u8 = if (compilers.runsInWorkDir(id, is_windows)) try paths.join(ja, &.{ work_dir, "run", try pathKey(a, file.path) }) else null;
    var dep_args: std.ArrayList([]const []const u8) = .empty;
    var dep_fixed: std.ArrayList(bool) = .empty;
    var dep_cwd: std.ArrayList([]const u8) = .empty;
    var dep_modules: std.ArrayList([]const []const u8) = .empty;
    if (with_deps and !self.s.compiler_no_dependencies) for (try dependencies(self, a, file)) |d| if (stale(self, a, d, mod_dir)) {
        var names: std.ArrayList([]const u8) = .empty;
        if (d.ast) |ast| for (ast.scope_list.items) |sc| if (sc.kind == .module) {
            const n = try ja.dupe(u8, sc.name);
            try names.append(ja, std.ascii.lowerString(n, n));
        };
        try dep_modules.append(ja, names.items);
        const dep_cmd = try commandOf(self, a, d, user);
        try dep_args.append(ja, try argsOf(self, ja, id, .dependency, d, user, dep_cmd, paths.dirname(file.path), o));
        try dep_fixed.append(ja, d.declared_fixed);
        try dep_cwd.append(ja, try ja.dupe(u8, run_dir orelse if (dep_cmd) |c| c.dir else paths.dirname(file.path)));
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
        .exes = try dupeAll(ja, exes),
        .compiler_path = if (compilerPath(self, file.declared_fixed)) |p| try ja.dupe(u8, p) else null,
        .cwd = try ja.dupe(u8, run_dir orelse if (cmd) |c| c.dir else paths.dirname(file.path)),
        .deps = dep_args.items,
        .deps_fixed = dep_fixed.items,
        .deps_cwd = dep_cwd.items,
        .deps_modules = dep_modules.items,
        .args = try argsOf(self, ja, id, .check, file, user, cmd, paths.dirname(file.path), o),
        .fixed = file.declared_fixed,
        .text = if (unsaved) try editorText(ja, file) else null,
        .fypp = fypp,
        .work_dir = work_dir,
    };
    return job;
}

/// The text as the editor has it
pub fn editorText(a: Allocator, file: *const FortranFile) ![]const u8 {
    return std.mem.join(a, "\n", file.editLines());
}

fn dupeAll(a: Allocator, xs: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
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
    const src = fsio.statFile(self.io, file.path) catch return true;
    var modules: usize = 0;
    for (ast.scope_list.items) |sc| {
        if (sc.kind != .module) continue;
        modules += 1;
        const name = a.print("{s}.mod", .{sc.name}) catch return true;
        const mod = paths.join(a, &.{ mod_dir, std.ascii.lowerString(name, name) }) catch return true;
        const st = fsio.statFile(self.io, mod) catch return true;
        if (st.mtime.nanoseconds < src.mtime.nanoseconds) return true;
    }
    return modules == 0;
}

// --------------------------------------------------------------------------
// On the compiler's thread

const Output = union(enum) {
    ran: struct {
        /// stdout and stderr
        text: []const u8,
        /// It exited with 0
        ok: bool,
        /// The executable run, and how it ended when not `ok`
        exe: []const u8,
        exit: []const u8,
    },
    /// None of the executables was found
    missing,
    failed: anyerror,
};

/// Runs the compiler with `args` in `cwd`, trying each executable
fn runCompiler(w: *Worker, a: Allocator, job: *const Job, cwd: []const u8, args: []const []const u8) Output {
    const io = w.server.io;
    for (job.exes) |exe| {
        const argv = a.alloc([]const u8, args.len + 1) catch |e| return .{ .failed = e };
        argv[0] = exe;
        @memcpy(argv[1..], args);
        const r = tools.run(a, io, .{
            .argv = argv,
            .cwd = cwd,
            // a compiler found by its path finds its DLLs (#528)
            .environ_map = tools.withExeDir(a, w.server.toolEnv(), exe) catch |e| return .{ .failed = e },
            .timeout = tools.seconds(timeout_s),
            .running = &w.running,
        }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return .{ .failed = e },
        };
        const text = std.mem.concat(a, u8, &.{ r.stdout, "\n", r.stderr }) catch |e| return .{ .failed = e };
        const exit = if (r.term.success()) "" else tools.describeExit(a, r) catch |e| return .{ .failed = e };
        return .{ .ran = .{ .text = text, .ok = r.term.success(), .exe = exe, .exit = exit } };
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
    try fsio.createDirPath(io, paths.dirname(out));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ fypp[0], "--line-numbering", "--line-marker-format=cpp" });
    if (fixed) try argv.append(a, "--fixed-format");
    try argv.appendSlice(a, fypp[1..]);
    // forward slashes: the path goes into the line markers, where a
    // backslash would be an escape
    const fwd = try a.dupe(u8, input);
    std.mem.replaceScalar(u8, fwd, '\\', '/');
    try argv.appendSlice(a, &.{ fwd, out });
    const r = tools.run(a, io, .{
        .argv = argv.items,
        .cwd = paths.dirname(origin),
        .environ_map = self.toolEnv(),
        .timeout = tools.seconds(timeout_s),
        .running = &w.running,
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
        const lines = try splitLines(a, job.text orelse fsio.readFile(io, a, origin, .limited(64 * 1024 * 1024)) catch "");
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
    if (compilers.runsInWorkDir(job.id, is_windows)) try fsio.createDirPath(io, job.cwd);
    // the module files that did not compile, with their first error
    var failed: std.ArrayList(messages.FailedDependency) = .empty;
    for (job.deps, job.deps_fixed, job.deps_cwd, 0..) |args, fixed, cwd, i| {
        if (w.stopped()) return;
        var dep_args = args;
        if (job.fypp != null) {
            const src = args[args.len - 1];
            dep_args = try withFile(a, args, (try runFypp(w, a, job, src, src, fixed, false)) orelse continue);
        }
        switch (runCompiler(w, a, job, cwd, dep_args)) {
            .ran => |r| if (!r.ok) {
                const ms = compilers.parse(a, job.id, r.text) catch &.{};
                for (ms) |m| if (m.severity == .@"error") {
                    try failed.append(a, .{ .path = args[args.len - 1], .cwd = cwd, .modules = if (i < job.deps_modules.len) job.deps_modules[i] else &.{}, .first = m });
                    break;
                };
            },
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
        try fsio.createDirPath(io, paths.dirname(target));
        try fsio.writeFile(io, target, text);
        try aliases.append(a, target);
    }
    if (job.fypp != null) {
        target = (try runFypp(w, a, job, job.path, target, job.fixed, true)) orelse return;
        try aliases.append(a, target);
    }
    const ran = switch (runCompiler(w, a, job, job.cwd, try withFile(a, job.args, target))) {
        .ran => |r| r,
        .missing => {
            if (!w.reported_missing) {
                w.reported_missing = true;
                self.postMessage(a, try a.print("compiler_diagnostics: {s} was not found{s}{s}", .{
                    @tagName(job.id),
                    if (job.compiler_path != null) " at " else " on the PATH",
                    job.compiler_path orelse "",
                }), 2);
            }
            return;
        },
        .failed => |e| {
            if (e != error.Stopped) self.log.warn("compiler_diagnostics: running {s} on {s}: {s}", .{ @tagName(job.id), job.path, @errorName(e) });
            return;
        },
    };
    const output = ran.text;
    self.log.debug("compiler_diagnostics {s}: {s}", .{ job.path, output });
    const msgs = try compilers.parse(a, job.id, output);
    // a failure without a message zfls understands (a format it does not
    // know), or without any output (a compiler that cannot start: a DLL
    // not found), is said, so that it is not silent
    if (msgs.len == 0 and !ran.ok) if (std.mem.trim(u8, output, " \t\r\n").len > 0) {
        self.log.warn("compiler_diagnostics: {s} failed on {s} with output zfls does not understand: {s}", .{ @tagName(job.id), job.path, output });
        if (!w.reported_unparsed) {
            w.reported_unparsed = true;
            self.postMessage(a, try a.print("compiler_diagnostics: {s} failed on {s}, and zfls did not understand its output (see zfls's log)", .{ @tagName(job.id), std.Io.Dir.path.basename(job.path) }), 2);
        }
    } else {
        const said = try a.print("compiler_diagnostics: {s} ({s}) failed on {s} without any output: {s}", .{ @tagName(job.id), ran.exe, std.Io.Dir.path.basename(job.path), ran.exit });
        self.log.warn("{s}", .{said});
        if (!w.reported_silent) {
            w.reported_silent = true;
            self.postMessage(a, said, 2);
        }
    };
    const text = job.text orelse fsio.readFile(io, a, job.path, .limited(64 * 1024 * 1024)) catch "";
    // a message in an included file, at the line that includes it (#496)
    try include_site.fill(a, io, job, try splitLines(a, text), aliases.items, msgs);
    // the error of a module file that did not compile, with the messages
    // about its module (#546)
    const diags = try messages.relateFailed(a, try toDiagnostics(a, job, text, msgs, aliases.items), failed.items);
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
    // a short name (`EMANSP~1`) as the long one, which the index has
    const n = try paths.longName(a, try paths.normpath(a, abs));
    if (!is_windows) return n;
    for (n) |*c| c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
    return n;
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
