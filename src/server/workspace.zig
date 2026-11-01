//! Workspace start-up (initialize, configuration, indexing, the global name
//! tree) and document synchronization (didOpen/didChange/didSave/didClose,
//! watched files).
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("../json.zig");
const json5 = @import("../json5.zig");
const lsp = @import("../lsp.zig");
const patterns = @import("../patterns.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const objects = @import("../objects.zig");
const parser = @import("../parser.zig");
const intrinsics = @import("../intrinsics.zig");
const settings_mod = @import("../settings.zig");
const glob = @import("../glob.zig");
const project = @import("../project.zig");
const semantic = @import("../semantic.zig");

const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const definition = @import("definition.zig");
const references = @import("references.zig");
const diagnostics = @import("diagnostics.zig");
const compile = @import("compile.zig");
const bindc = @import("bindc.zig");

pub fn serveInitialize(self: *Server, a: Allocator, params: lsp.InitializeParams) !Value {
    const sa = self.arena.allocator();
    var root_in: []const u8 = "";
    if (params.rootUri) |s| if (s.len > 0) {
        root_in = s;
    };
    if (root_in.len == 0) if (params.rootPath) |s| {
        root_in = s;
    };
    self.root_path = try sa.dupe(u8, try self.pathFromUri(a, root_in));
    self.hierarchical_symbols = params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport;
    self.prepare_rename = params.capabilities.textDocument.rename.prepareSupport;
    try self.s.source_dirs.add(sa, self.root_path);

    try loadConfigFile(self, a);
    try loadProjectFiles(self, a);
    try diagnostics.checkDiagnosticSeverity(self, a);
    try compile.checkSetting(self, a);
    try resolveGlobsInPaths(self, a);
    try configLogger(self);
    try loadIntrinsics(self);
    try addSourceDirs(self, a);

    try workspaceInit(self, a, params.workDoneToken);
    self.log.info("zfls - Fortran Language Server {s} Initialized", .{@import("../version.zig").reported});

    if (self.s.notify_init) self.postMessage(a, "fortls initialization complete", C.Severity.info);
    return json.from(a, lsp.InitializeResult{ .capabilities = .{
        .completionProvider = .{ .resolveProvider = false, .triggerCharacters = &.{ "%", "." } },
        .textDocumentSync = self.sync_type,
        .signatureHelpProvider = if (self.s.use_signature_help) .{ .triggerCharacters = &.{ "(", "," } } else null,
        .codeActionProvider = if (self.s.enable_code_actions) true else null,
        .semanticTokensProvider = .{ .legend = semantic.legend },
        .renameProvider = if (self.prepare_rename) try json.from(a, .{ .prepareProvider = true }) else .{ .bool = true },
    } });
}

/// Problems with the user's configuration file are posted to the client;
/// only allocation failures are errors
pub fn loadConfigFile(self: *Server, a: Allocator) Allocator.Error!void {
    const candidates = [_][]const u8{ self.s.config, ".fortlsrc", ".fortls.json", ".fortls" };
    var config_path: ?[]const u8 = null;
    for (candidates) |f| {
        const p = try paths.join(a, &.{ self.root_path, f });
        if (paths.isFile(self.io, p)) {
            config_path = p;
            break;
        }
    }
    const cp = config_path orelse return;
    const sa = self.arena.allocator();
    const data = Io.Dir.cwd().readFileAlloc(self.io, cp, sa, .limited(1 << 26)) catch {
        self.postMessage(a, try std.fmt.allocPrint(a, "Configuration file '{s}' not found", .{self.s.config}), C.Severity.err);
        return;
    };
    var p: json5.Parser = .{ .a = sa, .src = data };
    const cfg = p.parseDocument() catch {
        const emsg = try settings_mod.json5ErrorMessage(a, data, p.err_pos);
        const msg = try std.fmt.allocPrint(a, "Error: \"{s}\" while reading \"{s}\" Configuration file", .{ emsg, self.s.config });
        self.postMessage(a, msg, C.Severity.err);
        return;
    };
    if (cfg != .object) {
        self.postMessage(a, try std.fmt.allocPrint(a, "Error: \"<string>:1 Unexpected value\" while reading \"{s}\" Configuration file", .{self.s.config}), C.Severity.err);
        return;
    }
    try settings_mod.applyConfig(sa, &self.s, cfg);
    self.sync_type = if (self.s.incremental_sync) 2 else 1;
    if (cfg.object.get("incl_suffixes") != null) {
        if (patterns.createSrcFileExtsStr(sa, self.s.incl_suffixes.slice())) |re| {
            self.src_ext_regex = re;
        } else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => self.postMessage(a, "Invalid 'incl_suffixes' in the configuration file; keeping the default source file extensions", C.Severity.warn),
        }
    }
    try self.syncPpDefsFromSettings();
}

/// Adds the include directories and preprocessor definitions of the
/// project's compile_commands.json and fpm.toml to the options' own
pub fn loadProjectFiles(self: *Server, a: Allocator) Allocator.Error!void {
    const sa = self.arena.allocator();
    const db = if (self.s.disable_compile_commands) null else try project.findCompileCommands(self.io, a, self.root_path, self.s.compile_commands);
    if (db) |p| {
        if (Io.Dir.cwd().readFileAlloc(self.io, p, a, .limited(1 << 28))) |text| {
            if (project.readCompileCommands(sa, text, paths.dirname(p))) |found| {
                try addProjectSettings(self, found);
                self.log.info("{s}: {d} include directories, {d} definitions", .{ p, found.include_dirs.items.len, found.defs.items.len });
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => self.postMessage(a, try std.fmt.allocPrint(a, "Could not read \"{s}\": not a compilation database", .{p}), C.Severity.warn),
            }
        } else |_| if (self.s.compile_commands != null) {
            self.postMessage(a, try std.fmt.allocPrint(a, "Compilation database \"{s}\" not found", .{p}), C.Severity.warn);
        }
    }
    const fpm = try paths.join(a, &.{ self.root_path, "fpm.toml" });
    if (Io.Dir.cwd().readFileAlloc(self.io, fpm, a, .limited(1 << 24))) |text| {
        try addProjectSettings(self, try project.readFpm(self.io, sa, self.root_path, text));
    } else |_| {}
}

pub fn addProjectSettings(self: *Server, found: project.Found) Allocator.Error!void {
    const sa = self.arena.allocator();
    for (found.include_dirs.items) |d| try self.s.include_dirs.add(sa, d);
    var added = false;
    for (found.defs.items) |d| {
        const known = for (self.s.pp_defs.items) |x| {
            if (std.mem.eql(u8, x.name, d.name)) break true;
        } else false;
        if (known) continue;
        try self.s.pp_defs.append(sa, .{ .name = d.name, .value = d.value });
        added = true;
    }
    if (added) try self.syncPpDefsFromSettings();
}

pub fn resolveGlobsInPaths(self: *Server, a: Allocator) !void {
    const sa = self.arena.allocator();
    var excl: settings_mod.StrList = .{};
    for (self.s.excl_paths.slice()) |p| {
        for (try glob.resolveGlobs(self.io, sa, p, self.root_path)) |r| try excl.add(sa, r);
    }
    self.s.excl_paths = excl;

    var src: settings_mod.StrList = .{};
    for (self.s.source_dirs.slice()) |p| {
        for (try glob.resolveGlobs(self.io, sa, p, self.root_path)) |r| {
            if (paths.isDir(self.io, r) and !self.s.excl_paths.contains(r)) try src.add(sa, r);
        }
    }
    self.s.source_dirs = src;

    var inc: settings_mod.StrList = .{};
    for (self.s.include_dirs.slice()) |p| {
        for (try glob.resolveGlobs(self.io, sa, p, self.root_path)) |r| {
            if (paths.isDir(self.io, r)) try inc.add(sa, r);
        }
    }
    self.s.include_dirs = inc;
    _ = a;
}

pub fn configLogger(self: *Server) !void {
    if (self.s.debug_log and self.root_path.len > 0) {
        const fname = try paths.join(self.arena.allocator(), &.{ self.root_path, "fortls_debug.log" });
        self.log.openFile(self.io, fname);
        try self.post_messages.append(self.gpa, .{ .severity = C.Severity.info, .message = "fortls debugging enabled" });
    }
}

pub fn loadIntrinsics(self: *Server) !void {
    const new = try intrinsics.load(self.gpa, self.s.lowercase_intrinsics);
    // Remove old intrinsic modules from the tree before freeing them
    for (self.intr.mods) |m| {
        if (self.obj_tree.get(m.fqsn)) |e| if (e.obj == m) {
            _ = self.obj_tree.orderedRemove(m.fqsn);
        };
    }
    self.intr.deinit();
    self.intr = new;
    // a workspace module of the same name keeps it
    for (self.intr.mods) |m| {
        const gop = try self.obj_tree.getOrPut(self.gpa, m.fqsn);
        if (gop.found_existing and gop.value_ptr.path != null) continue;
        gop.key_ptr.* = m.fqsn;
        gop.value_ptr.* = .{ .obj = m, .path = null };
    }
}

pub fn parseOptions(self: *const Server) parser.Options {
    return .{ .sort_keywords = self.s.sort_keywords };
}

pub fn addSourceDirs(self: *Server, a: Allocator) !void {
    if (self.s.source_dirs.len() != 1) return;
    if (!self.s.source_dirs.contains(self.root_path)) return;
    const sa = self.arena.allocator();
    var dirs: settings_mod.StrList = .{};
    for (try glob.walk(self.io, a, self.root_path)) |w| {
        var has = false;
        for (w.files) |f| if (self.src_ext_regex.search(f) != null) {
            has = true;
            break;
        };
        if (!has) continue;
        if (self.s.excl_paths.contains(w.dir)) continue;
        try dirs.add(sa, try sa.dupe(u8, try paths.realpath(self.io, a, w.dir)));
    }
    self.s.source_dirs = dirs;
    self.whole_root = true;
}

pub fn getSourceFiles(self: *Server, a: Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (self.s.source_dirs.slice()) |dir| {
        const entries = glob.listEntries(self.io, a, dir) catch continue;
        for (entries) |e| {
            if (!e.is_file) continue;
            const f = e.name;
            if (self.src_ext_regex.search(f) == null) continue;
            const p = try paths.join(a, &.{ dir, f });
            if (self.s.excl_paths.contains(p)) continue;
            var excluded = false;
            for (self.s.excl_suffixes.slice()) |ext| if (std.mem.endsWith(u8, f, ext)) {
                excluded = true;
            };
            if (excluded) continue;
            try out.append(a, p);
        }
    }
    return out.items;
}

pub fn ppSuffixes(self: *const Server) ?[]const []const u8 {
    if (self.s.pp_suffixes) |l| if (l.len() > 0) return l.slice();
    return null;
}

pub fn initWorker(job: *Server.InitJob) void {
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.files.len) return;
        job.results[i] = fileInit(job.server, job.files[i]);
    }
}

/// Port of `file_init`
pub fn fileInit(self: *Server, filepath: []const u8) Server.InitResult {
    const f = loadFile(self, filepath) catch |e| return .{ .err = e };
    return .{ .ok = f };
}

/// Create, read and parse a workspace file. The caller owns the result
/// (the file and its AST).
pub fn loadFile(self: *Server, filepath: []const u8) parser.FileError!*FortranFile {
    const f = try FortranFile.create(self.gpa, filepath, ppSuffixes(self));
    f.comment_markers = self.s.comment_markers.slice();
    errdefer f.destroy();
    _ = try f.loadFromDisk(self.io);
    const ast = f.parse(self.io, &self.pp_defs, self.s.include_dirs.slice(), parseOptions(self)) catch return error.ParseFailed;
    // Emulate Python's recursion limit (deeply nested scopes)
    if (maxScopeDepth(ast) > self.s.recursion_limit) {
        ast.destroy();
        return error.RecursionLimit;
    }
    f.ast = ast;
    return f;
}

pub fn maxScopeDepth(ast: *Ast) i64 {
    var max: i64 = 0;
    for (ast.scope_list.items) |s| {
        var d: i64 = 0;
        var p: ?*Obj = s;
        while (p) |o| : (p = o.parent) d += 1;
        max = @max(max, d);
    }
    return max;
}

/// Parse the workspace's files; with the `workDoneToken` of the
/// initialize request, report the progress (FL #417, MF #757)
pub fn workspaceInit(self: *Server, a: Allocator, progress: ?Value) !void {
    const files = try getSourceFiles(self, a);
    const results = try a.alloc(Server.InitResult, files.len);
    @memset(results, .none);
    var job: Server.InitJob = .{ .server = self, .files = files, .results = results };
    if (progress) |token| self.sendProgress(a, token, .{ .kind = "begin", .title = "Indexing", .message = try std.fmt.allocPrint(a, "{d} files", .{files.len}), .percentage = 0 });
    const nthreads: usize = @intCast(std.math.clamp(self.s.nthreads, 1, 64));
    var threads: std.ArrayList(std.Thread) = .empty;
    var t: usize = 1;
    while (t < @min(nthreads, files.len)) : (t += 1) {
        const th = std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, initWorker, .{&job}) catch break;
        try threads.append(a, th);
    }
    // this thread parses too, and is the one that reports
    var reported: usize = 0;
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= files.len) break;
        job.results[i] = fileInit(self, files[i]);
        const token = progress orelse continue;
        const pct = (i + 1) * 100 / files.len;
        if (pct >= reported + 5) {
            reported = pct;
            self.sendProgress(a, token, .{ .kind = "report", .message = try std.fmt.allocPrint(a, "{d}/{d} files", .{ i + 1, files.len }), .percentage = @intCast(pct) });
        }
    }
    for (threads.items) |th| th.join();
    defer if (progress) |token| self.sendProgress(a, token, .{ .kind = "end" });

    for (files, results) |path, res| {
        switch (res) {
            .none => {},
            .err => |e| self.postMessage(a, try std.fmt.allocPrint(a, "Initialization failed for file {s}: {s}", .{ path, parser.describeFileError(e) }), C.Severity.err),
            .ok => |f| {
                if (self.workspace.get(f.path)) |old| {
                    // Duplicate path (overlapping source dirs): keep the newest
                    try retireFileAst(self, old);
                    old.ast = f.ast;
                    f.ast = null;
                    f.destroy();
                    try addToTree(self, old);
                } else {
                    try self.workspace.put(self.gpa, f.path, f);
                    try addToTree(self, f);
                }
            },
        }
    }
    try fullRelink(self, a);
}

// Several files can define the same global name. Unlike fortls, where
// the last file parsed takes the name and re-parsing either file drops
// it for both, the tree keeps one owner per name chosen the same way
// whatever the order of events, so a long session agrees with a fresh
// start: any file over an intrinsic module, then the lowest path.

/// Whether a definition from `path` takes a name held by `held`.
pub fn treeOwnerBeats(path: ?[]const u8, held: ?[]const u8) bool {
    const p = path orelse return false;
    const h = held orelse return true;
    return std.mem.order(u8, p, h) == .lt;
}

pub fn addToTree(self: *Server, f: *FortranFile) !void {
    const ast = f.ast orelse return;
    var it = ast.global_dict.iterator();
    while (it.next()) |e| {
        const gop = try self.obj_tree.getOrPut(self.gpa, e.key_ptr.*);
        if (gop.found_existing and !treeOwnerBeats(f.path, gop.value_ptr.path)) continue;
        // the key is the owner's (it lives as long as the owner's AST)
        gop.key_ptr.* = e.key_ptr.*;
        gop.value_ptr.* = .{ .obj = e.value_ptr.*, .path = f.path };
    }
}

/// Drops the names `ast` owns, handing each to the next file (or
/// intrinsic module) that defines it.
pub fn removeFromTree(self: *Server, ast: *Ast) void {
    for (ast.global_dict.keys()) |key| {
        const held = self.obj_tree.getEntry(key) orelse continue;
        if (held.value_ptr.obj.file_ast != ast) continue;
        var best: ?struct { key: []const u8, entry: objects.TreeEntry } = null;
        for (self.workspace.values()) |f| {
            const other = f.ast orelse continue;
            if (other == ast) continue;
            const e = other.global_dict.getEntry(key) orelse continue;
            if (best == null or treeOwnerBeats(f.path, best.?.entry.path)) {
                best = .{ .key = e.key_ptr.*, .entry = .{ .obj = e.value_ptr.*, .path = f.path } };
            }
        }
        if (best == null) for (self.intr.mods) |m| {
            if (std.mem.eql(u8, m.fqsn, key)) best = .{ .key = m.fqsn, .entry = .{ .obj = m, .path = null } };
        };
        if (best) |b| {
            held.key_ptr.* = b.key;
            held.value_ptr.* = b.entry;
        } else _ = self.obj_tree.orderedRemove(key);
    }
}

pub fn retireFileAst(self: *Server, f: *FortranFile) !void {
    if (f.ast) |old| {
        try self.retired.append(self.gpa, old);
        removeFromTree(self, old);
    }
}

/// Re-resolve includes and links across the whole workspace, after
/// which no object references a retired AST, so those can be freed.
pub fn fullRelink(self: *Server, a: Allocator) !void {
    // Reset cross-file references so that nothing points into retired ASTs
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        ast.included_in = null;
        if (ast.inc_scope) |inc| {
            ast.none_scope = inc;
            for (inc.childList()) |c| c.parent = inc;
        }
        for (ast.include_statements.items) |inc| {
            inc.inc_obj = null;
            inc.file = null;
        }
        for (ast.variable_list.items) |v| {
            v.varData().type_obj = null;
            v.varData().link_obj = null;
        }
        for (ast.scope_list.items) |s| {
            if (s.kind.isSubroutine()) s.procData().link_obj = null;
            if (s.procDataOpt()) |p| if (p.linked_from_interface) s.resetInterfaceCopy();
            if (s.kind == .interface) s.ifaceData().mems.clearRetainingCapacity();
            if (s.kind == .type) {
                s.typeData().inherit_var = null;
                s.scopeData().in_children.clearRetainingCapacity();
                s.typeData().inherit_version = -1;
            }
            if (s.kind == .submodule) s.submodData().ancestor_obj = null;
            // Children of scopes in other files added through INCLUDE
            var k: usize = 0;
            while (k < s.childList().len) {
                if (s.childList()[k].file_ast != ast) {
                    _ = s.scopeData().children.orderedRemove(k);
                } else k += 1;
            }
        }
        if (ast.none_scope) |ns| {
            var k: usize = 0;
            while (k < ns.childList().len) {
                if (ns.childList()[k].file_ast != ast) {
                    _ = ns.scopeData().children.orderedRemove(k);
                } else k += 1;
            }
        }
    }
    for (self.workspace.values()) |f| {
        const ast = f.ast orelse continue;
        for (ast.include_statements.items) |inc| inc.scope_objs.clearRetainingCapacity();
    }
    for (self.workspace.values()) |f| {
        if (f.ast) |ast| try ast.resolveIncludes(&self.workspace, try definition.includeDirs(self, a), null, a);
    }
    self.link_version = @mod(self.link_version + 1, 1000);
    var tmp = std.heap.ArenaAllocator.init(self.gpa);
    defer tmp.deinit();
    for (self.workspace.values()) |f| {
        if (f.ast) |ast| {
            try ast.resolveLinks(self.env(tmp.allocator()), self.link_version);
            _ = tmp.reset(.retain_capacity);
        }
    }
    for (self.retired.items) |ast| ast.destroy();
    self.retired.clearRetainingCapacity();
}

pub fn serveOnChange(self: *Server, a: Allocator, params: lsp.DidChangeParams) !Value {
    const path = try self.pathFromUri(a, params.textDocument.uri);
    if (self.c_docs.get(path)) |doc| {
        for (params.contentChanges) |c| _ = doc.applyChange(toChange(c)) catch {};
        return .null;
    }
    const file = self.workspace.get(path) orelse {
        self.postMessage(a, try std.fmt.allocPrint(a, "Change request failed for unknown file '{s}'", .{path}), C.Severity.err);
        return .null;
    };
    const changes = params.contentChanges;
    var reparse_req = true;
    if (self.sync_type == 1) {
        if (changes.len > 0) {
            _ = file.applyChange(toChange(changes[0])) catch {
                self.postMessage(a, try std.fmt.allocPrint(a, "Change request failed for file '{s}': Could not apply change", .{path}), C.Severity.err);
                return .null;
            };
        }
    } else {
        reparse_req = false;
        for (changes) |c| {
            const flag = file.applyChange(toChange(c)) catch {
                self.postMessage(a, try std.fmt.allocPrint(a, "Change request failed for file '{s}': Could not apply change", .{path}), C.Severity.err);
                return .null;
            };
            reparse_req = reparse_req or flag;
        }
    }
    if (reparse_req) {
        _ = updateWorkspaceFile(self, path, false, false, true) catch |e| {
            self.postMessage(a, try std.fmt.allocPrint(a, "Change request failed for file '{s}': {s}", .{ path, parser.describeFileError(e) }), C.Severity.err);
            return .null;
        };
        for (self.workspace.values()) |f| if (f.ast) |ast| try ast.resolveIncludes(&self.workspace, try definition.includeDirs(self, a), path, a);
        if (file.ast) |ast| try ast.resolveIncludes(&self.workspace, try definition.includeDirs(self, a), null, a);
        // Periodically reclaim memory of replaced ASTs
        if (self.retired.items.len >= 16) try fullRelink(self, a);
    } else if (file.preproc) {
        const out = try file.preprocess(self.io, &self.pp_defs, &.{}, null);
        try self.mergePpDefs(&out.defs);
    }
    return .null;
}

pub fn toChange(c: lsp.ContentChange) parser.Change {
    const r = c.range orelse return .{ .text = c.text };
    return .{ .text = c.text, .range = .{
        .sl = @intCast(@max(r.start.line, 0)),
        .sc = @intCast(@max(r.start.character, 0)),
        .el = @intCast(@max(r.end.line, 0)),
        .ec = @intCast(@max(r.end.character, 0)),
    } };
}

pub fn serveOnSave(self: *Server, a: Allocator, params: lsp.TextDocumentParams, did_open: bool, did_close: bool) !Value {
    const uri = params.textDocument.uri;
    const filepath = try self.pathFromUri(a, uri);
    // a C document: opened as one (a `.h` may be Fortran's), and then known
    const c_doc = if (did_open) bindc.isCLanguage(params.textDocument.languageId) else self.c_docs.contains(filepath);
    if (c_doc) return cDocument(self, filepath, params.textDocument.text, did_close);
    if (did_open and !self.open_docs.contains(filepath)) {
        const key = try self.gpa.dupe(u8, filepath);
        errdefer self.gpa.free(key);
        try self.open_docs.put(self.gpa, key, {});
    }
    if (did_close) if (self.open_docs.fetchRemove(filepath)) |kv| self.gpa.free(kv.key);
    if (paths.isVirtualUri(filepath)) return serveVirtualDocument(self, a, uri, filepath, params.textDocument.text, did_open, did_close);
    if (did_close and !paths.isFile(self.io, filepath)) {
        if (self.workspace.get(filepath)) |f| if (f.ast) |ast| removeFromTree(self, ast);
        return .null;
    }
    const changed = updateWorkspaceFile(self, filepath, true, did_open, false) catch |e| {
        self.postMessage(a, try std.fmt.allocPrint(a, "Save request failed for file '{s}': {s}", .{ filepath, parser.describeFileError(e) }), C.Severity.err);
        return .null;
    };
    if (changed) try fullRelink(self, a);
    // the compiler checks the file as saved, on its own thread
    if (!did_close and !self.s.disable_diagnostics) compile.check(self, a, uri, filepath) catch |e| self.log.err("compiler diagnostics of {s}: {s}", .{ filepath, @errorName(e) });
    // a change can change the diagnostics of the files that use it
    if (changed and self.s.workspace_diagnostics) {
        diagnostics.publishWorkspace(self, a);
        return .null;
    }
    if (!self.s.disable_diagnostics) diagnostics.sendDiagnostics(self, a, uri);
    return .null;
}

/// A C document opened in zfls, by an editor that attaches it to C files
/// (bindc.zig): its text, for go to definition; it is not parsed. Its
/// declarations may have changed, so the C search is done again.
fn cDocument(self: *Server, path: []const u8, text: ?[]const u8, did_close: bool) !Value {
    bindc.deinitIndex(self);
    if (did_close) {
        if (self.c_docs.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
            kv.value.destroy();
        }
        return .null;
    }
    // didSave without its text: the one from didOpen and the changes
    const t = text orelse return .null;
    if (self.c_docs.get(path)) |doc| {
        _ = try doc.setText(t);
        return .null;
    }
    const doc = try FortranFile.create(self.gpa, path, null);
    errdefer doc.destroy();
    _ = try doc.setText(t);
    const key = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(key);
    try self.c_docs.put(self.gpa, key, doc);
    return .null;
}

/// Files created, changed or deleted outside the editor (a checkout, a
/// generator): the workspace follows them. Documents open in the editor
/// are left alone, their text being the editor's.
pub fn serveWatchedFiles(self: *Server, a: Allocator, params: lsp.DidChangeWatchedFilesParams) !Value {
    var changed = false;
    for (params.changes) |ev| {
        const path = try self.pathFromUri(a, ev.uri);
        // the C search again; a `.h` may be a Fortran include too, which
        // the rest follows
        if (bindc.isCFile(path)) bindc.deinitIndex(self);
        if (self.open_docs.contains(path) or paths.isVirtualUri(path)) continue;
        if (ev.type == 3) {
            const f = self.workspace.get(path) orelse continue;
            if (f.ast == null) continue;
            try retireFileAst(self, f);
            f.ast = null;
            // so that the same text, restored, is parsed again
            f.hash = null;
            changed = true;
            // its problems are gone with it
            if (self.s.workspace_diagnostics) self.sendNotification(a, "textDocument/publishDiagnostics", try json.from(a, lsp.PublishDiagnosticsParams{ .uri = ev.uri, .diagnostics = &.{} })) catch |e| self.logSendFailure(e);
            continue;
        }
        if (!isSourceFile(self, path)) continue;
        const updated = updateWorkspaceFile(self, path, true, false, false) catch |e| {
            self.log.err("{s} : {s}", .{ parser.describeFileError(e), path });
            continue;
        };
        changed = changed or updated;
    }
    if (changed) try fullRelink(self, a);
    if (changed and self.s.workspace_diagnostics) diagnostics.publishWorkspace(self, a);
    return .null;
}

/// Whether `path` is a file the workspace indexes: a Fortran file of a
/// source directory (any directory under the root, without
/// `source_dirs`) that no exclusion covers
pub fn isSourceFile(self: *const Server, path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (self.src_ext_regex.search(base) == null) return false;
    for (self.s.excl_suffixes.slice()) |ext| if (std.mem.endsWith(u8, base, ext)) return false;
    for (self.s.excl_paths.slice()) |ex| if (std.mem.startsWith(u8, path, ex)) return false;
    if (self.s.source_dirs.contains(paths.dirname(path))) return true;
    return self.whole_root and std.mem.startsWith(u8, path, self.root_path);
}

/// `didOpen`, `didSave` and `didClose` of a document that is not a file
/// (an untitled one): its text comes with `didOpen` and its changes,
/// and it leaves the workspace when it is closed
pub fn serveVirtualDocument(self: *Server, a: Allocator, uri: []const u8, path: []const u8, text: ?[]const u8, did_open: bool, did_close: bool) !Value {
    if (did_close) {
        if (self.workspace.get(path)) |f| if (f.ast) |ast| removeFromTree(self, ast);
        return .null;
    }
    if (did_open) {
        const file = self.workspace.get(path) orelse blk: {
            const nf = try FortranFile.create(self.gpa, path, ppSuffixes(self));
            nf.comment_markers = self.s.comment_markers.slice();
            errdefer nf.destroy();
            try self.workspace.put(self.gpa, nf.path, nf);
            break :blk nf;
        };
        _ = try file.setText(text orelse "");
        const changed = updateWorkspaceFile(self, path, false, true, false) catch |e| {
            self.postMessage(a, try std.fmt.allocPrint(a, "Open request failed for '{s}': {s}", .{ path, parser.describeFileError(e) }), C.Severity.err);
            return .null;
        };
        if (changed) try fullRelink(self, a);
    }
    if (!self.s.disable_diagnostics) diagnostics.sendDiagnostics(self, a, uri);
    return .null;
}

/// Read (if `read_file`) and parse a workspace file and link it into the
/// workspace; returns whether it changed. A file created here belongs to
/// the workspace once registered (until then it is destroyed on failure),
/// and a new AST belongs to its file once installed: the replaced one
/// goes to `retired`, which is freed after the next full relink.
pub fn updateWorkspaceFile(self: *Server, filepath: []const u8, read_file: bool, allow_empty: bool, update_links: bool) parser.FileError!bool {
    var file = self.workspace.get(filepath);
    var created: ?*FortranFile = null;
    errdefer if (created) |f| f.destroy();
    if (read_file) {
        if (file == null) {
            const nf = try FortranFile.create(self.gpa, filepath, ppSuffixes(self));
            nf.comment_markers = self.s.comment_markers.slice();
            created = nf;
            if (!paths.isFile(self.io, filepath)) {
                if (!allow_empty) return error.FileNotFound;
                nf.ast = try Ast.create(self.gpa, nf);
                errdefer nf.ast.?.destroy();
                try self.workspace.put(self.gpa, nf.path, nf);
                created = null;
                return false;
            }
            file = nf;
        }
        const changed = file.?.loadFromDisk(self.io) catch |e| {
            self.log.err("{s} : {s}", .{ parser.describeFileError(e), filepath });
            return e;
        };
        if (!changed) {
            if (created) |f| f.destroy();
            created = null;
            return false;
        }
    }
    const f = file orelse return error.FileNotFound;
    const ast_new = f.parse(self.io, &self.pp_defs, self.s.include_dirs.slice(), parseOptions(self)) catch {
        self.log.err("Error while parsing file {s}", .{filepath});
        return error.ParseFailed;
    };
    {
        // everything that can fail before the new AST is installed
        errdefer ast_new.destroy();
        try self.mergePpDefs(&f.pp_defs);
        if (!self.workspace.contains(f.path)) {
            try self.workspace.put(self.gpa, f.path, f);
            created = null;
        }
        if (f.ast) |old| try self.retired.append(self.gpa, old);
    }
    if (f.ast) |old| removeFromTree(self, old);
    f.ast = ast_new;
    try addToTree(self, f);
    if (update_links) {
        self.link_version = @mod(self.link_version + 1, 1000);
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        try ast_new.resolveLinks(self.env(tmp.allocator()), self.link_version);
    }
    return true;
}
