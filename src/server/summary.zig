//! The workspace's files that are not open are kept as summaries (#219,
//! objects/summary.zig): their scopes as other files see them, without the
//! local variables and constructs of their procedures, which are most of a
//! large workspace's memory. A file is parsed in full again from the text
//! it keeps (`wake`) before a request reads more of it: any request on the
//! file itself, the requests that search the workspace for a name (find
//! references, rename, document highlight, reference lenses, incoming
//! calls) for the files whose text has the name, and the diagnostics of the
//! whole workspace. It rests again as a summary (`sleepAll`) at the next
//! save, open, close or change of files outside the editor; a closed file
//! rests once its diagnostics are published.
//!
//! Files that include others or are included are kept in full, as are all
//! files with `workspace_diagnostics`, whose diagnostics need them.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const workspace = @import("workspace.zig");
const linking = @import("linking.zig");
const definition = @import("definition.zig");
const references = @import("references.zig");
const bindc = @import("bindc.zig");
const calls = @import("calls.zig");
const compiler_macros = @import("compiler_macros.zig");

/// Whether the workspace keeps summaries at all
pub fn wanted(self: *const Server) bool {
    return self.summaries and !self.s.workspace_diagnostics;
}

/// Whether `f` may be a summary: a workspace file not open in the editor,
/// nor read for another's include (that it is included by none is
/// `included`'s)
pub fn mayRest(self: *const Server, f: *const FortranFile) bool {
    return wanted(self) and !f.included and !self.open_docs.contains(f.path) and !paths.isVirtualUri(f.path);
}

/// Whether the AST of `f` is a summary
pub fn dormant(f: *const FortranFile) bool {
    const ast = f.ast orelse return false;
    return ast.summary != null;
}

/// `full`, the AST just parsed of `f`, or its summary when `f` may rest:
/// the AST to keep (owned by `gpa`; `full` is freed when it is not that),
/// and the summary's bytes for the index cache, if any (owned by `gpa`)
pub fn ofParsed(self: *Server, f: *const FortranFile, full: *Ast) Allocator.Error!struct { ast: *Ast, bytes: ?[]u8 = null } {
    if (!mayRest(self, f)) return .{ .ast = full };
    const s = (objects.summary.summarize(self.gpa, full) catch |e| {
        full.destroy();
        return e;
    }) orelse return .{ .ast = full };
    full.destroy();
    return .{ .ast = s.ast, .bytes = s.bytes };
}

/// The AST of `f`'s text again, in full, from what its last parse read
/// (`FortranFile.prepared`): so the same AST as that parse's
fn parseFull(self: *Server, f: *FortranFile) parser.FileError!*Ast {
    const opts = workspace.parseOptions(self);
    const out = blk: {
        if (f.prepared) |p| if (p.hash == f.hash) {
            var o = p.out;
            // the lines it read are the file's, as they are now
            if (o) |*x| if (!f.preproc) {
                x.lines = f.lines.items;
            };
            break :blk o;
        };
        var defs_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer defs_arena.deinit();
        const defs = compiler_macros.defsFor(self, defs_arena.allocator(), f) catch return error.OutOfMemory;
        break :blk f.prepare(self.io, defs, self.s.include_dirs.slice(), opts) catch |e| return failed(e);
    };
    return f.parsePrepared(out, opts) catch |e| failed(e);
}

fn failed(e: anyerror) parser.FileError {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.ParseFailed;
}

const Job = struct {
    server: *Server,
    files: []const *FortranFile,
    /// what each file's AST becomes: its full AST, or its summary when
    /// `rest`; null when it stays as it is
    results: []?*Ast,
    rest: bool,
    next: std.atomic.Value(usize) = .init(0),
};

fn worker(job: *Job) void {
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.files.len) return;
        job.results[i] = reparse(job.server, job.files[i], job.rest);
    }
}

fn reparse(self: *Server, f: *FortranFile, rest: bool) ?*Ast {
    const full = parseFull(self, f) catch |e| {
        self.log.err("parsing {s} again: {s}", .{ f.path, parser.describeFileError(e) });
        return null;
    };
    if (!rest) return full;
    const s = (objects.summary.summarize(self.gpa, full) catch null) orelse {
        full.destroy();
        return null;
    };
    full.destroy();
    self.gpa.free(s.bytes);
    return s.ast;
}

/// Parses `files` again (on the threads of `nthreads`) and installs what
/// they become; whether any changed. The caller links the workspace again.
fn reparseAll(self: *Server, a: Allocator, files: []const *FortranFile, rest: bool) !bool {
    if (files.len == 0) return false;
    const results = try a.alloc(?*Ast, files.len);
    @memset(results, null);
    var job: Job = .{ .server = self, .files = files, .results = results, .rest = rest };
    const nthreads: usize = @intCast(std.math.clamp(self.s.nthreads, 1, 64));
    var threads: std.ArrayList(std.Thread) = .empty;
    var t: usize = 1;
    while (t < @min(nthreads, files.len)) : (t += 1) {
        const th = std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, worker, .{&job}) catch break;
        threads.append(a, th) catch {
            th.join();
            break;
        };
    }
    worker(&job);
    for (threads.items) |th| th.join();
    var changed = false;
    for (files, results, 0..) |f, r, i| {
        const ast = r orelse continue;
        install(self, f, ast) catch |e| {
            for (results[i..]) |x| if (x) |y| if (y != ast) y.destroy();
            return e;
        };
        changed = true;
    }
    return changed;
}

/// Makes `ast` the AST of `f`: the one it replaces is freed after the next
/// full relink
fn install(self: *Server, f: *FortranFile, ast: *Ast) !void {
    {
        errdefer ast.destroy();
        try linking.retireFileAst(self, f);
    }
    f.ast = ast;
    try linking.addToTree(self, f);
}

/// Parses in full those of `files` that are summaries, and then links the
/// workspace again (which frees the summaries)
pub fn wake(self: *Server, a: Allocator, files: []const *FortranFile) !void {
    var seen: std.AutoHashMapUnmanaged(*const FortranFile, void) = .empty;
    var todo: std.ArrayList(*FortranFile) = .empty;
    for (files) |f| if (dormant(f) and !(try seen.getOrPut(a, f)).found_existing) try todo.append(a, f);
    if (todo.items.len == 0) return;
    // when, for `sleepAll`
    for (todo.items) |f| {
        self.wake_clock += 1;
        try self.woken.put(self.gpa, f, self.wake_clock);
    }
    if (try reparseAll(self, a, todo.items, false)) try linking.fullRelink(self, a);
}

/// Parses in full every summary
pub fn wakeAll(self: *Server, a: Allocator) !void {
    try wake(self, a, self.workspace.values());
}

/// Makes summaries again of the files parsed in full that may rest, but for
/// the `keep_awake` that requests parsed in full last (which the next
/// requests, such as those of the reference lenses of a file, are likely to
/// read again); whether any changed, after which the caller links the
/// workspace again
pub fn sleepAll(self: *Server, a: Allocator) !bool {
    if (!wanted(self)) return false;
    const inc = try included(self, a);
    const Candidate = struct { file: *FortranFile, woken: u64 };
    var todo: std.ArrayList(Candidate) = .empty;
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        if (!objects.summary.summarizable(ast) or !mayRest(self, f) or inc.contains(f)) continue;
        try todo.append(a, .{ .file = f, .woken = self.woken.get(f) orelse 0 });
    }
    // the latest last
    std.mem.sort(Candidate, todo.items, {}, struct {
        fn lessThan(_: void, x: Candidate, y: Candidate) bool {
            return x.woken < y.woken;
        }
    }.lessThan);
    var n = todo.items.len;
    var kept: usize = 0;
    while (n > 0 and kept < self.keep_awake and todo.items[n - 1].woken > 0) : (kept += 1) n -= 1;
    const files = try a.alloc(*FortranFile, n);
    for (todo.items[0..n], files) |c, *f| {
        f.* = c.file;
        _ = self.woken.remove(c.file);
    }
    return reparseAll(self, a, files, true);
}

/// A file that rests at once: one just closed
pub fn forget(self: *Server, f: *const FortranFile) void {
    _ = self.woken.remove(f);
}

/// The files that INCLUDE lines or `#include`s of the workspace read
fn included(self: *Server, a: Allocator) !std.AutoHashMapUnmanaged(*const FortranFile, void) {
    var out: std.AutoHashMapUnmanaged(*const FortranFile, void) = .empty;
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.include_statements.items) |i| if (i.file) |x| try out.put(a, x, {});
    }
    return out;
}

/// After the workspace is linked: the summaries of files that others
/// include (which are kept in full) are parsed in full
pub fn wakeIncluded(self: *Server, a: Allocator) !void {
    const inc = try included(self, a);
    var todo: std.ArrayList(*FortranFile) = .empty;
    var it = inc.keyIterator();
    while (it.next()) |k| try todo.append(a, @constCast(k.*));
    try wake(self, a, todo.items);
}

/// Parses in full the summaries of the files whose text has one of `names`
/// (ignoring case), and those of `also`
fn wakeNamed(self: *Server, a: Allocator, names: []const []const u8, also: []const *FortranFile) !void {
    var todo: std.ArrayList(*FortranFile) = .empty;
    try todo.appendSlice(a, also);
    for (self.workspace.values()) |f| {
        if (!dormant(f)) continue;
        for (names) |n| if (n.len > 0 and std.ascii.findIgnoreCase(f.text, n) != null) {
            try todo.append(a, f);
            break;
        };
    }
    try wake(self, a, todo.items);
}

/// Before a request: parses in full the summaries it reads more of
pub fn beforeRequest(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
    const any = for (self.workspace.values()) |f| {
        if (dormant(f)) break true;
    } else false;
    if (!any) return;
    const Kind = enum { file, names, all };
    const kinds = std.StaticStringMap(Kind).initComptime(.{
        .{ "textDocument/references", .names },
        .{ "textDocument/rename", .names },
        .{ "codeLens/resolve", .names },
        .{ "callHierarchy/incomingCalls", .names },
        .{ "zfls/bindCReferences", .names },
        .{ "workspace/diagnostic", .all },
    });
    const kind = kinds.get(method) orelse .file;
    if (kind == .all) return wakeAll(self, a);
    // the file the request is about
    const uri = json.str(json.path(params, &.{ "textDocument", "uri" })) orelse
        json.str(json.path(params, &.{ "item", "uri" })) orelse
        json.str(json.path(params, &.{ "data", "uri" }));
    var own: ?*FortranFile = null;
    if (uri) |u| if (try self.fileFromUri(a, u)) |f| {
        own = f;
        try wake(self, a, &.{f});
    };
    if (kind != .names) return;
    if (std.mem.eql(u8, method, "zfls/bindCReferences")) {
        const cname = json.str(json.get(params, "name")) orelse return;
        return wakeForCName(self, a, cname);
    }
    if (std.mem.eql(u8, method, "callHierarchy/incomingCalls")) {
        const item = json.decode(lsp.CallHierarchyCallsParams, a, params) catch return;
        const callee = (try calls.procedureOf(self, a, item.item)) orelse return;
        return wakeForReferencesOf(self, a, callee, false);
    }
    var pos: lsp.PositionParams = undefined;
    if (std.mem.eql(u8, method, "codeLens/resolve")) {
        const lens = json.decode(lsp.CodeLens, a, params) catch return;
        const data = lens.data orelse return;
        pos = .{ .textDocument = .{ .uri = data.uri }, .position = lens.range.start };
    } else pos = json.decode(lsp.PositionParams, a, params) catch return;
    const rename = std.mem.eql(u8, method, "textDocument/rename");
    return wakeForPosition(self, a, pos, rename, !rename);
}

/// What `references.serveReferences` and `serveRename` search the
/// workspace for, from the name at `pos`
fn wakeForPosition(self: *Server, a: Allocator, pos: lsp.PositionParams, rename: bool, with_c: bool) !void {
    const path = try self.pathFromUri(a, pos.textDocument.uri);
    if (self.c_docs.get(path)) |doc| {
        const name = bindc.identifierAt(doc, pos) orelse return;
        return wakeForCName(self, a, name);
    }
    if (try definition.operatorAt(self, a, pos)) |_| return;
    if (try definition.assignmentAt(self, a, pos)) |_| return wakeAll(self, a);
    if (try definition.constructAt(self, a, pos)) |_| return;
    if (try @import("macros.zig").atPosition(self, a, pos)) |_| return;
    const d = (try definition.definitionAt(self, a, pos, false)) orelse return;
    if (d.obj.kind == .intrinsic) return;
    if (rename) if (try references.renamedImport(self, a, d.file, d.line, d.col, d.obj)) |ri| {
        const name = try a.dupe(u8, ri.alias);
        return wakeNamed(self, a, &.{ name, try a.dupe(u8, d.obj.name) }, &.{});
    };
    const obj = references.functionOfResult((try definition.callerTarget(self, a, d.file, d.line, d.col, d.obj)) orelse d.obj);
    return wakeForReferencesOf(self, a, obj, with_c);
}

/// The files `references.getAllReferences` reads for `obj` (and, `with_c`,
/// for the other procedures of its C name)
fn wakeForReferencesOf(self: *Server, a: Allocator, obj: *Obj, with_c: bool) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var also: std.ArrayList(*FortranFile) = .empty;
    try namesOf(self, a, obj, &names, &also);
    if (with_c) if (try bindc.cNameOf(a, obj)) |cname| {
        for (try bindc.proceduresOf(self, a, cname)) |p| try namesOf(self, a, p, &names, &also);
    };
    // copies: the objects are freed as the files are parsed again
    for (names.items) |*n| n.* = try a.dupe(u8, n.*);
    try wakeNamed(self, a, names.items, also.items);
}

fn wakeForCName(self: *Server, a: Allocator, cname: []const u8) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var also: std.ArrayList(*FortranFile) = .empty;
    for (try bindc.proceduresOf(self, a, cname)) |p| try namesOf(self, a, p, &names, &also);
    for (names.items) |*n| n.* = try a.dupe(u8, n.*);
    try wakeNamed(self, a, names.items, also.items);
}

/// The names whose places `references.getAllReferences` checks for `obj`,
/// or, when it searches only one file, that file
fn namesOf(self: *Server, a: Allocator, obj: *Obj, names: *std.ArrayList([]const u8), also: *std.ArrayList(*FortranFile)) !void {
    const rs = references.referenceScope(self, obj) orelse return;
    if (rs.restrict) |f| return also.append(a, f);
    const def_name = try std.ascii.allocLowerString(a, obj.name);
    try names.appendSlice(a, try references.useAliases(self, a, obj, def_name));
}
