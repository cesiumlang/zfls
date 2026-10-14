//! Fortran language server (port of `fortls.langserver`)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const json = @import("json.zig");
const helpers = @import("helpers.zig");
const patterns = @import("patterns.zig");
const regex = @import("regex.zig");
const paths = @import("paths.zig");
const C = @import("constants.zig");
const objects = @import("objects.zig");
const parser = @import("parser.zig");
const pp = @import("preprocessor.zig");
const intrinsics = @import("intrinsics.zig");
const settings_mod = @import("settings.zig");
const glob = @import("glob.zig");
const Logger = @import("logger.zig");

const Settings = settings_mod.Settings;
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = parser.FortranFile;
const Value = json.Value;

fn R() *const patterns.Patterns {
    return patterns.get();
}

pub const RpcError = error{ MethodNotFound, InvalidParams, InternalError };

/// Destination for outgoing JSON-RPC messages
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    sendFn: ?*const fn (ctx: ?*anyopaque, body: []const u8) void = null,

    pub fn send(self: Sink, body: []const u8) void {
        if (self.sendFn) |f| f(self.ctx, body);
    }
};

const PostMessage = struct { severity: i32, message: []const u8 };

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    s: Settings,
    /// Owns settings strings and other long-lived server data
    arena: std.heap.ArenaAllocator,
    root_path: []const u8 = "",
    workspace: std.array_hash_map.String(*FortranFile) = .empty,
    obj_tree: objects.ObjTree = .empty,
    link_version: i64 = 0,
    sync_type: i32 = 1,
    post_messages: std.ArrayList(PostMessage) = .empty,
    src_ext_regex: regex.Regex,
    intr: intrinsics.Intrinsics,
    /// ASTs replaced by re-parses, freed after the next full relink
    retired: std.ArrayList(*Ast) = .empty,
    pp_defs: pp.Defs = .empty,
    pp_defs_arena: std.heap.ArenaAllocator,
    running: bool = true,
    sink: Sink = .{},
    next_id: i64 = 1,
    log: *Logger,

    pub fn create(gpa: Allocator, io: Io, s: Settings, log: *Logger) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .s = s,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .src_ext_regex = undefined,
            .intr = undefined,
            .pp_defs_arena = std.heap.ArenaAllocator.init(gpa),
            .log = log,
        };
        self.sync_type = if (self.s.incremental_sync) 2 else 1;
        self.src_ext_regex = try patterns.createSrcFileExtsStr(self.arena.allocator(), self.s.incl_suffixes.slice());
        helpers.sort_keywords = true;
        self.intr = try intrinsics.load(gpa, false);
        helpers.sort_keywords = self.s.sort_keywords;
        try self.syncPpDefsFromSettings();
        return self;
    }

    pub fn destroy(self: *Server) void {
        for (self.workspace.values()) |f| {
            if (f.ast) |ast| ast.destroy();
            f.destroy();
        }
        self.workspace.deinit(self.gpa);
        self.obj_tree.deinit(self.gpa);
        for (self.retired.items) |ast| ast.destroy();
        self.retired.deinit(self.gpa);
        self.post_messages.deinit(self.gpa);
        self.intr.deinit();
        self.pp_defs_arena.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    fn syncPpDefsFromSettings(self: *Server) !void {
        _ = self.pp_defs_arena.reset(.free_all);
        self.pp_defs = .empty;
        const a = self.pp_defs_arena.allocator();
        for (self.s.pp_defs.items) |d| {
            try self.pp_defs.put(a, try a.dupe(u8, d.name), .{ .value = try a.dupe(u8, d.value) });
        }
    }

    /// `self.pp_defs = {**self.pp_defs, **file_obj.pp_defs}`
    fn mergePpDefs(self: *Server, defs: *const pp.Defs) !void {
        const a = self.pp_defs_arena.allocator();
        var it = defs.iterator();
        while (it.next()) |e| {
            const existing = self.pp_defs.get(e.key_ptr.*);
            const same = existing != null and str.eql(existing.?.value, e.value_ptr.value) and
                ((existing.?.args == null) == (e.value_ptr.args == null)) and
                (existing.?.args == null or str.eql(existing.?.args.?, e.value_ptr.args.?));
            if (same) continue;
            const key = if (self.pp_defs.getKey(e.key_ptr.*)) |k| k else try a.dupe(u8, e.key_ptr.*);
            try self.pp_defs.put(a, key, .{
                .args = try str.dupeOpt(a, e.value_ptr.args),
                .value = try a.dupe(u8, e.value_ptr.value),
            });
        }
    }

    fn env(self: *Server, tmp: Allocator) objects.Env {
        return .{ .tree = &self.obj_tree, .tmp = tmp };
    }

    // ----------------------------------------------------------------------
    // Messaging

    fn sendJson(self: *Server, a: Allocator, body: Value) !void {
        const text = try json.stringify(a, body);
        self.sink.send(text);
        if (self.log.enabled(.debug)) {
            var pretty: std.ArrayList(u8) = .empty;
            try json.writePretty(&pretty, a, body, 0);
            self.log.debug("SEND {s}", .{pretty.items});
        }
    }

    pub fn sendNotification(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .method = method, .params = params }));
    }

    fn writeResponse(self: *Server, a: Allocator, id: Value, result: Value) !void {
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .result = result }));
    }

    fn writeError(self: *Server, a: Allocator, id: Value, code: i64, message: []const u8, data: ?Value) !void {
        var e = json.newObject();
        try json.put(a, &e, "code", json.integer(code));
        try json.put(a, &e, "message", json.string(message));
        if (data) |d| try json.put(a, &e, "data", d);
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = e }));
    }

    pub fn postMessage(self: *Server, a: Allocator, msg: []const u8, severity: i32) void {
        self.sendNotification(a, "window/showMessage", json.from(a, .{ .type = severity, .message = msg }) catch return) catch {};
        switch (severity) {
            1 => self.log.err("{s}", .{msg}),
            2 => self.log.warn("{s}", .{msg}),
            3 => self.log.info("{s}", .{msg}),
            else => {},
        }
    }

    // ----------------------------------------------------------------------
    // Dispatch

    /// Handle one decoded JSON-RPC message
    pub fn handle(self: *Server, a: Allocator, request: Value) void {
        const method = (request.get("method") orelse json.null_value).asStr() orelse "";
        const id = request.get("id");
        self.log.debug("REQUEST {s} {s}", .{ if (id) |i| (json.stringify(a, i) catch "?") else "None", method });
        const params = request.get("params") orelse json.null_value;
        const result = self.dispatch(a, method, params);
        if (id == null) {
            if (result) |_| {} else |e| self.log.err("error handling request: {s} ({s})", .{ method, @errorName(e) });
            return;
        }
        if (result) |res| {
            self.writeResponse(a, id.?, res) catch {};
        } else |e| switch (e) {
            error.MethodNotFound => self.writeError(a, id.?, -32601, str.print(a, "method {s} not found", .{method}) catch "method not found", null) catch {},
            else => {
                self.log.warn("error handling request {s}: {s}", .{ method, @errorName(e) });
                const data = json.from(a, .{ .traceback = @errorName(e) }) catch json.null_value;
                self.writeError(a, id.?, -32603, @errorName(e), data) catch {};
            },
        }
    }

    /// Invoke a handler directly (used by the debug CLI)
    pub fn dispatchPublic(self: *Server, a: Allocator, method: []const u8, params: Value) !Value {
        return self.dispatch(a, method, params);
    }

    fn dispatch(self: *Server, a: Allocator, method: []const u8, params: Value) !Value {
        const eql = str.eql;
        if (eql(method, "initialize")) return self.serveInitialize(a, params);
        if (eql(method, "textDocument/documentSymbol")) return self.serveDocumentSymbols(a, params);
        if (eql(method, "textDocument/completion")) return self.serveAutocomplete(a, params);
        if (eql(method, "textDocument/signatureHelp")) return self.serveSignature(a, params);
        if (eql(method, "textDocument/definition")) return self.serveDefinition(a, params);
        if (eql(method, "textDocument/references")) return self.serveReferences(a, params);
        if (eql(method, "textDocument/documentHighlight")) return self.serveReferences(a, params);
        if (eql(method, "textDocument/hover")) return self.serveHover(a, params);
        if (eql(method, "textDocument/implementation")) return self.serveImplementation(a, params);
        if (eql(method, "textDocument/rename")) return self.serveRename(a, params);
        if (eql(method, "textDocument/didOpen")) return self.serveOnSave(a, params, true, false);
        if (eql(method, "textDocument/didSave")) return self.serveOnSave(a, params, false, false);
        if (eql(method, "textDocument/didClose")) return self.serveOnSave(a, params, false, true);
        if (eql(method, "textDocument/didChange")) return self.serveOnChange(a, params);
        if (eql(method, "textDocument/codeAction")) return self.serveCodeActions(a, params);
        if (eql(method, "workspace/symbol")) return self.serveWorkspaceSymbol(a, params);
        if (eql(method, "initialized") or eql(method, "workspace/didChangeWatchedFiles") or
            eql(method, "workspace/didChangeConfiguration") or eql(method, "$/cancelRequest") or
            eql(method, "$/setTrace") or eql(method, "shutdown")) return .null;
        if (eql(method, "exit")) {
            self.serveExit();
            return .null;
        }
        return error.MethodNotFound;
    }

    /// Flush messages queued during a request (`run()` loop tail)
    pub fn flushPostMessages(self: *Server, a: Allocator) void {
        const msgs = self.post_messages.toOwnedSlice(self.gpa) catch return;
        defer self.gpa.free(msgs);
        for (msgs) |m| self.postMessage(a, m.message, m.severity);
    }

    fn serveExit(self: *Server) void {
        self.running = false;
    }

    // ----------------------------------------------------------------------
    // Helpers

    fn uriOf(params: Value) []const u8 {
        return (params.path(&.{ "textDocument", "uri" }) orelse json.null_value).asStr() orelse "";
    }

    fn posOf(params: Value) struct { line: i64, char: i64 } {
        const line = (params.path(&.{ "position", "line" }) orelse json.null_value).asInt() orelse 0;
        const char = (params.path(&.{ "position", "character" }) orelse json.null_value).asInt() orelse 0;
        return .{ .line = line, .char = char };
    }

    fn pathFromUri(self: *Server, a: Allocator, uri: []const u8) ![]const u8 {
        return paths.pathFromUri(self.io, a, uri);
    }

    fn fileFromUri(self: *Server, a: Allocator, uri: []const u8) !?*FortranFile {
        const path = try self.pathFromUri(a, uri);
        return self.workspace.get(path);
    }

    /// LSP character offset (UTF-16) -> byte offset on a file line
    fn toByteCol(file: *const FortranFile, line: i64, char: i64) usize {
        if (char < 0) return 0;
        const text = file.getLine(line, false) orelse return @intCast(char);
        return str.utf16ToByte(text, @intCast(char));
    }

    /// Byte offset on a file line -> LSP character offset
    fn toLspCol(file: ?*const FortranFile, line: i64, col: i64) i64 {
        if (col <= 0) return col;
        const f = file orelse return col;
        const text = f.getLine(line, false) orelse return col;
        return @intCast(str.byteToUtf16(text, @intCast(col)));
    }

    /// `range_json` with optional end values falling back to the start
    fn rangeJson(a: Allocator, file: ?*const FortranFile, sln: i64, sch: i64, eln_in: ?i64, ech_in: ?i64) !Value {
        const eln = if (eln_in) |e| (if (e != 0) e else sln) else sln;
        const ech = if (ech_in) |e| (if (e != 0) e else sch) else sch;
        return json.from(a, .{
            .start = .{ .line = sln, .character = toLspCol(file, sln, sch) },
            .end = .{ .line = eln, .character = toLspCol(file, eln, ech) },
        });
    }

    fn uriJson(a: Allocator, uri: []const u8, file: ?*const FortranFile, sln: i64, sch: i64, eln: ?i64, ech: ?i64) !Value {
        var v = json.newObject();
        try json.put(a, &v, "uri", json.string(uri));
        try json.put(a, &v, "range", try rangeJson(a, file, sln, sch, eln, ech));
        return v;
    }

    fn fileForPath(self: *Server, path: ?[]const u8) ?*FortranFile {
        const p = path orelse return null;
        return self.workspace.get(p);
    }

    fn builtDiagJson(self: *Server, a: Allocator, file: *const FortranFile, d: objects.BuiltDiag) !Value {
        var v = json.newObject();
        if (d.cols_are_codepoints) {
            const eln = if (d.eln) |e| (if (e != 0) e else d.sln) else d.sln;
            const ech = if (d.ech) |e| (if (e != 0) e else d.sch) else d.sch;
            try json.put(a, &v, "range", try json.from(a, .{
                .start = .{ .line = d.sln, .character = d.sch },
                .end = .{ .line = eln, .character = ech },
            }));
        } else {
            try json.put(a, &v, "range", try rangeJson(a, file, d.sln, d.sch, d.eln, d.ech));
        }
        try json.put(a, &v, "message", json.string(d.message));
        try json.put(a, &v, "severity", json.integer(d.severity));
        if (d.related) |rel| {
            const rel_path = rel.path orelse "None";
            const uri = try paths.pathToUri(a, rel_path);
            var loc = try uriJson(a, uri, self.fileForPath(rel.path), rel.line, 0, null, null);
            _ = &loc;
            var info = json.newObject();
            try json.put(a, &info, "location", loc);
            try json.put(a, &info, "message", json.string(rel.message));
            var arr = json.newArray();
            try json.append(a, &arr, info);
            try json.put(a, &v, "relatedInformation", arr);
        }
        return v;
    }

    // ----------------------------------------------------------------------
    // initialize

    fn serveInitialize(self: *Server, a: Allocator, params: Value) !Value {
        const sa = self.arena.allocator();
        var root_in: []const u8 = "";
        if (params.get("rootUri")) |v| if (v.asStr()) |s| if (s.len > 0) {
            root_in = s;
        };
        if (root_in.len == 0) if (params.get("rootPath")) |v| if (v.asStr()) |s| {
            root_in = s;
        };
        self.root_path = try sa.dupe(u8, try self.pathFromUri(a, root_in));
        try self.s.source_dirs.add(sa, self.root_path);

        self.loadConfigFile(a);
        try self.resolveGlobsInPaths(a);
        self.configLogger();
        try self.loadIntrinsics();
        try self.addSourceDirs(a);

        try self.workspaceInit(a);
        self.log.info("zfls - Fortran Language Server {s} Initialized", .{@import("version.zig").reported});

        var caps = json.newObject();
        try json.put(a, &caps, "completionProvider", try json.from(a, .{
            .resolveProvider = false,
            .triggerCharacters = &[_][]const u8{"%"},
        }));
        try json.put(a, &caps, "definitionProvider", .{ .bool = true });
        try json.put(a, &caps, "documentSymbolProvider", .{ .bool = true });
        try json.put(a, &caps, "documentHighlightProvider", .{ .bool = true });
        try json.put(a, &caps, "referencesProvider", .{ .bool = true });
        try json.put(a, &caps, "hoverProvider", .{ .bool = true });
        try json.put(a, &caps, "implementationProvider", .{ .bool = true });
        try json.put(a, &caps, "renameProvider", .{ .bool = true });
        try json.put(a, &caps, "workspaceSymbolProvider", .{ .bool = true });
        try json.put(a, &caps, "textDocumentSync", json.integer(self.sync_type));
        if (self.s.use_signature_help) {
            try json.put(a, &caps, "signatureHelpProvider", try json.from(a, .{
                .triggerCharacters = &[_][]const u8{ "(", "," },
            }));
        }
        if (self.s.enable_code_actions) try json.put(a, &caps, "codeActionProvider", .{ .bool = true });
        if (self.s.notify_init) self.postMessage(a, "fortls initialization complete", C.Severity.info);
        var res = json.newObject();
        try json.put(a, &res, "capabilities", caps);
        return res;
    }

    fn loadConfigFile(self: *Server, a: Allocator) void {
        const candidates = [_][]const u8{ self.s.config, ".fortlsrc", ".fortls.json", ".fortls" };
        var config_path: ?[]const u8 = null;
        for (candidates) |f| {
            const p = paths.join(a, &.{ self.root_path, f }) catch continue;
            if (paths.isFile(self.io, p)) {
                config_path = p;
                break;
            }
        }
        const cp = config_path orelse return;
        const sa = self.arena.allocator();
        const data = Io.Dir.cwd().readFileAlloc(self.io, cp, sa, .limited(1 << 26)) catch {
            self.postMessage(a, str.print(a, "Configuration file '{s}' not found", .{self.s.config}) catch return, C.Severity.err);
            return;
        };
        var p: json.Parser = .{ .a = sa, .src = data };
        const cfg = p.parseDocument() catch {
            const emsg = settings_mod.json5ErrorMessage(a, data, p.err_pos) catch "error";
            const msg = str.print(a, "Error: \"{s}\" while reading \"{s}\" Configuration file", .{ emsg, self.s.config }) catch return;
            self.postMessage(a, msg, C.Severity.err);
            return;
        };
        if (cfg != .object) {
            self.postMessage(a, str.print(a, "Error: \"<string>:1 Unexpected value\" while reading \"{s}\" Configuration file", .{self.s.config}) catch return, C.Severity.err);
            return;
        }
        settings_mod.applyConfig(sa, &self.s, cfg) catch return;
        self.sync_type = if (self.s.incremental_sync) 2 else 1;
        if (cfg.get("incl_suffixes") != null) {
            if (patterns.createSrcFileExtsStr(sa, self.s.incl_suffixes.slice())) |re| {
                self.src_ext_regex = re;
            } else |_| {}
        }
        self.syncPpDefsFromSettings() catch {};
    }

    fn resolveGlobsInPaths(self: *Server, a: Allocator) !void {
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

    fn configLogger(self: *Server) void {
        if (self.s.debug_log and self.root_path.len > 0) {
            const fname = paths.join(self.arena.allocator(), &.{ self.root_path, "fortls_debug.log" }) catch return;
            self.log.openFile(self.io, fname);
            self.post_messages.append(self.gpa, .{ .severity = C.Severity.info, .message = "fortls debugging enabled" }) catch {};
        }
    }

    fn loadIntrinsics(self: *Server) !void {
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
        helpers.sort_keywords = self.s.sort_keywords;
    }

    fn addSourceDirs(self: *Server, a: Allocator) !void {
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
    }

    fn getSourceFiles(self: *Server, a: Allocator) ![][]const u8 {
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
                for (self.s.excl_suffixes.slice()) |ext| if (str.endsWith(f, ext)) {
                    excluded = true;
                };
                if (excluded) continue;
                try out.append(a, p);
            }
        }
        return out.items;
    }

    fn ppSuffixes(self: *const Server) ?[]const []const u8 {
        if (self.s.pp_suffixes) |l| if (l.len() > 0) return l.slice();
        return null;
    }

    const InitJob = struct {
        server: *Server,
        files: []const []const u8,
        results: []InitResult,
        next: std.atomic.Value(usize) = .init(0),
    };

    const InitResult = union(enum) {
        none,
        ok: *FortranFile,
        err: []const u8,
    };

    fn initWorker(job: *InitJob) void {
        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.files.len) return;
            job.results[i] = job.server.fileInit(job.files[i]);
        }
    }

    /// Port of `file_init`
    fn fileInit(self: *Server, filepath: []const u8) InitResult {
        const f = FortranFile.create(self.gpa, filepath, self.ppSuffixes()) catch return .{ .err = "Error during parsing" };
        const lr = f.loadFromDisk(self.io);
        if (lr.err) |e| {
            f.destroy();
            return .{ .err = e };
        }
        const ast = f.parse(self.io, &self.pp_defs, self.s.include_dirs.slice()) catch {
            f.destroy();
            return .{ .err = "Error during parsing" };
        };
        f.ast = ast;
        // Emulate Python's recursion limit (deeply nested scopes)
        if (maxScopeDepth(ast) > self.s.recursion_limit) {
            ast.destroy();
            f.destroy();
            return .{ .err = "An exception has occured while initialising the workspace.\nException(<class 'RecursionError'>): maximum recursion depth exceeded" };
        }
        return .{ .ok = f };
    }

    fn maxScopeDepth(ast: *Ast) i64 {
        var max: i64 = 0;
        for (ast.scope_list.items) |s| {
            var d: i64 = 0;
            var p: ?*Obj = s;
            while (p) |o| : (p = o.parent) d += 1;
            max = @max(max, d);
        }
        return max;
    }

    fn workspaceInit(self: *Server, a: Allocator) !void {
        const files = try self.getSourceFiles(a);
        const results = try a.alloc(InitResult, files.len);
        @memset(results, .none);
        var job: InitJob = .{ .server = self, .files = files, .results = results };
        const nthreads: usize = @intCast(std.math.clamp(self.s.nthreads, 1, 64));
        var threads: std.ArrayList(std.Thread) = .empty;
        var t: usize = 1;
        while (t < @min(nthreads, files.len)) : (t += 1) {
            const th = std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, initWorker, .{&job}) catch break;
            try threads.append(a, th);
        }
        initWorker(&job);
        for (threads.items) |th| th.join();

        for (files, results) |path, res| {
            switch (res) {
                .none => {},
                .err => |e| self.postMessage(a, try str.print(a, "Initialization failed for file {s}: {s}", .{ path, e }), C.Severity.err),
                .ok => |f| {
                    if (self.workspace.get(f.path)) |old| {
                        // Duplicate path (overlapping source dirs): keep the newest
                        try self.retireFileAst(old);
                        old.ast = f.ast;
                        f.ast = null;
                        f.destroy();
                        try self.addToTree(old);
                    } else {
                        try self.workspace.put(self.gpa, f.path, f);
                        try self.addToTree(f);
                    }
                },
            }
        }
        try self.fullRelink(a);
    }

    // Several files can define the same global name. Unlike fortls, where
    // the last file parsed takes the name and re-parsing either file drops
    // it for both, the tree keeps one owner per name chosen the same way
    // whatever the order of events, so a long session agrees with a fresh
    // start: any file over an intrinsic module, then the lowest path.

    /// Whether a definition from `path` takes a name held by `held`.
    fn treeOwnerBeats(path: ?[]const u8, held: ?[]const u8) bool {
        const p = path orelse return false;
        const h = held orelse return true;
        return std.mem.order(u8, p, h) == .lt;
    }

    fn addToTree(self: *Server, f: *FortranFile) !void {
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
    fn removeFromTree(self: *Server, ast: *Ast) void {
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

    fn retireFileAst(self: *Server, f: *FortranFile) !void {
        if (f.ast) |old| {
            self.removeFromTree(old);
            try self.retired.append(self.gpa, old);
        }
    }

    /// Re-resolve includes and links across the whole workspace, after
    /// which no object references a retired AST, so those can be freed.
    fn fullRelink(self: *Server, a: Allocator) !void {
        // Reset cross-file references so that nothing points into retired ASTs
        for (self.workspace.values()) |f| {
            const ast = f.ast orelse continue;
            if (ast.inc_scope) |inc| {
                ast.none_scope = inc;
                for (inc.children.items) |c| c.parent = inc;
            }
            for (ast.include_statements.items) |inc| {
                inc.inc_obj = null;
                inc.file = null;
            }
            for (ast.variable_list.items) |v| {
                v.type_obj = null;
                v.link_obj = null;
            }
            for (ast.scope_list.items) |s| {
                if (s.kind.isSubroutine()) s.link_obj = null;
                if (s.linked_from_interface) s.resetInterfaceCopy();
                if (s.kind == .interface) s.mems.clearRetainingCapacity();
                if (s.kind == .type) {
                    s.inherit_var = null;
                    s.in_children.clearRetainingCapacity();
                    s.inherit_version = -1;
                }
                if (s.kind == .submodule) s.ancestor_obj = null;
                // Children of scopes in other files added through INCLUDE
                var k: usize = 0;
                while (k < s.children.items.len) {
                    if (s.children.items[k].file_ast != ast) {
                        _ = s.children.orderedRemove(k);
                    } else k += 1;
                }
            }
            if (ast.none_scope) |ns| {
                var k: usize = 0;
                while (k < ns.children.items.len) {
                    if (ns.children.items[k].file_ast != ast) {
                        _ = ns.children.orderedRemove(k);
                    } else k += 1;
                }
            }
        }
        for (self.workspace.values()) |f| {
            const ast = f.ast orelse continue;
            for (ast.include_statements.items) |inc| inc.scope_objs.clearRetainingCapacity();
        }
        for (self.workspace.values()) |f| {
            if (f.ast) |ast| try ast.resolveIncludes(&self.workspace, null, a);
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

    // ----------------------------------------------------------------------
    // Workspace symbols / document symbols

    fn serveWorkspaceSymbol(self: *Server, a: Allocator, params: Value) !Value {
        const query = try str.lower(a, (params.get("query") orelse json.null_value).asStr() orelse "");
        const Item = struct { name: []const u8, v: Value };
        var items: std.ArrayList(Item) = .empty;
        for (try objects.findInWorkspace(self.env(a), query, false, false)) |cand| {
            const kind: i64 = switch (cand.getType(false)) {
                1 => 2,
                2 => 6,
                3 => 12,
                4 => 5,
                5 => 11,
                6 => 13,
                7 => 6,
                else => 1,
            };
            var v = json.newObject();
            try json.put(a, &v, "name", json.string(cand.name));
            try json.put(a, &v, "kind", json.integer(kind));
            try json.put(a, &v, "location", try json.from(a, .{
                .uri = try paths.pathToUri(a, cand.file_ast.path orelse "None"),
                .range = .{
                    .start = .{ .line = cand.sline - 1, .character = 0 },
                    .end = .{ .line = cand.eline - 1, .character = 0 },
                },
            }));
            if (std.mem.indexOf(u8, cand.fqsn, "::")) |i| if (i > 0) {
                try json.put(a, &v, "containerName", json.string(cand.fqsn[0..i]));
            };
            try items.append(a, .{ .name = cand.name, .v = v });
        }
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, x: Item, y: Item) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        var arr = json.newArray();
        for (items.items) |it| try json.append(a, &arr, it.v);
        return arr;
    }

    fn symbolJson(a: Allocator, name: []const u8, kind: i64, uri: []const u8, sln: i64, eln: ?i64, container: ?[]const u8) !Value {
        var v = json.newObject();
        try json.put(a, &v, "name", json.string(name));
        try json.put(a, &v, "kind", json.integer(kind));
        var loc = json.newObject();
        try json.put(a, &loc, "uri", json.string(uri));
        try json.put(a, &loc, "range", try rangeJson(a, null, sln, 0, eln, 0));
        try json.put(a, &v, "location", loc);
        if (container) |c| if (c.len > 0) try json.put(a, &v, "containerName", json.string(c));
        return v;
    }

    fn serveDocumentSymbols(self: *Server, a: Allocator, params: Value) !Value {
        const uri = uriOf(params);
        const file = (try self.fileFromUri(a, uri)) orelse return json.newArray();
        const ast = file.ast orelse return json.newArray();
        var out = json.newArray();
        for (try ast.getScopes(a, null)) |scope| {
            if (scope.name.len == 0 or str.startsWith(scope.name, "#") or scope.getType(false) == C.SELECT_TYPE_ID) continue;
            const tree = try str.split(a, scope.fqsn, "::");
            var scope_type: i64 = undefined;
            if (tree.len > 2) {
                if (str.startsWith(tree[1], "#gen_int")) scope_type = 11 else continue;
            } else {
                scope_type = mapDocSymbolType(scope.getType(false), false);
            }
            const container: ?[]const u8 = if (std.mem.indexOf(u8, scope.fqsn, "::")) |i| (if (i > 0) tree[0] else null) else null;
            try json.append(a, &out, try symbolJson(a, scope.name, scope_type, uri, scope.sline - 1, scope.eline - 1, container));
            if (scope.getType(false) == C.CLASS_TYPE_ID and !self.s.symbol_skip_mem) {
                for (scope.children.items) |child| {
                    try json.append(a, &out, try symbolJson(a, child.name, mapDocSymbolType(child.getType(false), true), uri, child.sline - 1, null, scope.name));
                }
            }
        }
        return out;
    }

    fn mapDocSymbolType(t: i32, in_class: bool) i64 {
        return switch (t) {
            1, 8 => 2,
            2, 3 => if (in_class) 6 else 12,
            4 => 5,
            5 => 11,
            6 => 13,
            7 => 6,
            else => 1,
        };
    }

    // ----------------------------------------------------------------------
    // Completion

    const TypeMask = [16]bool;

    fn setTypeMask(def: bool) TypeMask {
        var m: TypeMask = undefined;
        for (&m, 0..) |*x, i| x.* = if (i < 8) def else true;
        return m;
    }

    fn maskGet(m: *const TypeMask, t: i32) bool {
        // Python negative indexing for BASE_TYPE_ID (-1)
        const idx: i64 = if (t < 0) 16 + t else t;
        if (idx < 0 or idx >= 16) return false;
        return m[@intCast(idx)];
    }

    fn childCandidates(a: Allocator, scope: *Obj, only_list: ?*const objects.StrSet, filter_public: bool, req_abstract: bool, out: *std.ArrayList(*Obj)) !void {
        const nonly = if (only_list) |o| o.len() else 0;
        for (try scope.getChildren(a, filter_public)) |child| {
            if (req_abstract) {
                if (child.isAbstract()) try childCandidates(a, child, only_list, filter_public, false, out);
            } else {
                if (child.isExternalInt()) {
                    try childCandidates(a, child, only_list, filter_public, false, out);
                } else {
                    if (nonly > 0) {
                        const lname = try str.lower(a, child.name);
                        if (!only_list.?.contains(lname)) continue;
                    }
                    try out.append(a, child);
                }
            }
        }
    }

    const Candidates = struct { objs: []*Obj, renames: []?[]const u8 };

    fn getCandidates(self: *Server, a: Allocator, scope_list: []const *Obj, var_prefix: []const u8, inc_globals: bool, public_only: bool, abstract_only: bool, no_use: bool) !Candidates {
        var var_list: std.ArrayList(*Obj) = .empty;
        var use_dict = std.array_hash_map.String(*objects.UseStmt).empty;
        // global names resolve to the requesting file's own definitions first
        const own: ?*objects.Ast = if (scope_list.len > 0) scope_list[0].file_ast else null;
        for (scope_list) |scope| {
            try childCandidates(a, scope, null, public_only, abstract_only, &var_list);
            if (!no_use) try objects.getUseTree(self.env(a), scope, &use_dict, null, null, &.{});
        }
        var rename_list: std.ArrayList(?[]const u8) = .empty;
        try rename_list.appendNTimes(a, null, var_list.items.len);
        var import_var_list: std.ArrayList(*Obj) = .empty;
        var it = use_dict.iterator();
        while (it.next()) |e| {
            const use_mod = e.key_ptr.*;
            const use_info = e.value_ptr.*;
            if (!use_info.is_import) {
                const scope = (if (own) |ast| self.env(a).global(ast, use_mod) else if (self.obj_tree.get(use_mod)) |t| t.obj else null) orelse continue;
                var only: objects.StrSet = .{};
                for (try use_info.rename(a)) |o| try only.add(a, o);
                var tmp: std.ArrayList(*Obj) = .empty;
                try childCandidates(a, scope, &only, true, abstract_only, &tmp);
                if (use_info.rename_map.count() > 0) {
                    for (tmp.items) |obj| {
                        try var_list.append(a, obj);
                        var rev: ?[]const u8 = null;
                        const lname = try str.lower(a, obj.name);
                        // reversed rename map (last key wins for duplicate values)
                        for (use_info.rename_map.keys.items, use_info.rename_map.values.items) |k, v| {
                            if (str.eql(v, lname)) rev = k;
                        }
                        try rename_list.append(a, rev);
                    }
                } else {
                    try var_list.appendSlice(a, tmp.items);
                    try rename_list.appendNTimes(a, null, tmp.items.len);
                }
            } else {
                const scope = use_info.scope orelse continue;
                try childCandidates(a, scope, &use_info.only_list, true, abstract_only, &import_var_list);
            }
        }
        if (inc_globals) {
            var tree_it = self.obj_tree.iterator();
            while (tree_it.next()) |e| {
                const mine = if (own) |ast| ast.global_dict.get(e.key_ptr.*) else null;
                try var_list.append(a, mine orelse e.value_ptr.obj);
                try rename_list.append(a, null);
            }
            for (self.intr.funs) |f| {
                try var_list.append(a, f);
                try rename_list.append(a, null);
            }
        }
        if (import_var_list.items.len > 0) {
            var_list = import_var_list;
            rename_list = .empty;
            try rename_list.appendNTimes(a, null, var_list.items.len);
        }
        if (var_prefix.len == 0) return .{ .objs = var_list.items, .renames = rename_list.items };
        var out_objs: std.ArrayList(*Obj) = .empty;
        var out_renames: std.ArrayList(?[]const u8) = .empty;
        for (var_list.items, rename_list.items) |v, rn| {
            const name = rn orelse v.name;
            if (str.startsWith(try str.lower(a, name), var_prefix)) {
                try out_objs.append(a, v);
                try out_renames.append(a, rn);
            }
        }
        return .{ .objs = out_objs.items, .renames = out_renames.items };
    }

    fn mapCompletionKind(t: i32) i64 {
        return switch (t) {
            1 => 9,
            2 => 3,
            4 => 7,
            6 => 6,
            else => t,
        };
    }

    fn buildComp(self: *Server, a: Allocator, candidate: *Obj, name_only: bool, name_replace: ?[]const u8, is_interface: bool, is_member: bool) !Value {
        var v = json.newObject();
        var call_sig: ?[]const u8 = null;
        try json.put(a, &v, "label", json.string(candidate.name));
        if (!name_only) {
            if (name_replace) |nr| try json.put(a, &v, "label", json.string(nr));
            const sn = try candidate.getSnippet(a, name_replace, -1);
            call_sig = sn.call;
            var snippet = sn.snippet;
            if (self.s.autocomplete_no_snippets) snippet = call_sig;
            if (snippet) |s0| {
                var s = s0;
                if (self.s.use_signature_help and !is_interface) {
                    if (std.mem.indexOfScalar(u8, s, '(')) |arg_open| if (arg_open > 0) {
                        s = s[0..arg_open];
                    };
                }
                try json.put(a, &v, "insertText", json.string(s));
                try json.put(a, &v, "insertTextFormat", json.integer(2));
            }
        }
        var kind = mapCompletionKind(candidate.getType(false));
        if (is_member and kind == 3) kind = 2;
        try json.put(a, &v, "kind", json.integer(kind));
        var detail = try candidate.getDesc(a);
        if (call_sig) |cs| detail = try str.print(a, "{s} {s}", .{ detail, cs });
        try json.put(a, &v, "detail", json.string(detail));
        const hover_msg = try candidate.getHoverMd(a, true, -1);
        if (hover_msg.len > 0) {
            const value = try str.replaceFirst(a, hover_msg, "```{langid}", try str.print(a, "```{s}", .{self.s.hover_language}));
            try json.put(a, &v, "documentation", try json.from(a, .{ .kind = "markdown", .value = value }));
        }
        return v;
    }

    fn serveAutocomplete(self: *Server, a: Allocator, params: Value) !Value {
        const uri = uriOf(params);
        const file = (try self.fileFromUri(a, uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        const pos = posOf(params);
        const ac_line = pos.line;
        const ac_char = toByteCol(file, ac_line, pos.char);
        const cl = try file.getCodeLine(a, ac_line, false, true, false, true);
        const line_prefix = (try helpers.getLinePrefix(a, cl.pre, cl.curr, ac_char, true)) orelse return .null;
        const var_stack = try helpers.getVarStack(a, line_prefix);
        const is_member = var_stack.len > 1;
        var var_prefix = str.strip(var_stack[var_stack.len - 1]);

        var item_list = json.newArray();
        var name_only = self.s.autocomplete_name_only;
        var public_only = false;
        var include_globals = true;
        const lc = try parser.getLineContext(a, line_prefix);
        if (lc.ctx == .skip or (var_prefix.len == 0 and !is_member)) return .null;
        if (self.s.autocomplete_no_prefix) var_prefix = "";

        var scope_list: []const *Obj = &.{};
        if (is_member) {
            const curr_scope = ast.getInnerScope(ac_line + 1);
            const type_scope = (try objects.climbTypeTree(self.env(a), var_stack, curr_scope)) orelse return .null;
            include_globals = false;
            const one = try a.alloc(*Obj, 1);
            one[0] = type_scope;
            scope_list = one;
        } else {
            scope_list = try ast.getScopes(a, ac_line + 1);
        }
        var req_callable = false;
        var abstract_only = false;
        var no_use = false;
        var type_mask = setTypeMask(false);
        type_mask[C.MODULE_TYPE_ID] = true;
        type_mask[C.CLASS_TYPE_ID] = true;
        switch (lc.ctx) {
            .mod_only => {
                for (self.obj_tree.values()) |e| {
                    const cand = e.obj;
                    if (cand.getType(false) == C.MODULE_TYPE_ID and str.startsWith(try str.lower(a, cand.name), var_prefix)) {
                        try json.append(a, &item_list, try self.buildComp(a, cand, true, null, false, false));
                    }
                }
                return item_list;
            },
            .mod_mems => {
                name_only = true;
                const mod_name = try str.lower(a, lc.info orelse "");
                const mod = self.env(a).global(ast, mod_name) orelse return .null;
                const one = try a.alloc(*Obj, 1);
                one[0] = mod;
                scope_list = one;
                public_only = true;
                include_globals = false;
                type_mask[C.CLASS_TYPE_ID] = false;
            },
            .pro_link => {
                type_mask = setTypeMask(true);
                type_mask[C.SUBROUTINE_TYPE_ID] = false;
                type_mask[C.FUNCTION_TYPE_ID] = false;
                name_only = true;
                include_globals = false;
                no_use = true;
            },
            .call => req_callable = true,
            .type_only => {
                type_mask = setTypeMask(true);
                type_mask[C.CLASS_TYPE_ID] = false;
            },
            .import => {
                name_only = true;
                type_mask = setTypeMask(true);
                type_mask[C.CLASS_TYPE_ID] = false;
                type_mask[C.VAR_TYPE_ID] = false;
            },
            .vis => {
                include_globals = false;
                name_only = true;
                type_mask = setTypeMask(true);
                type_mask[C.CLASS_TYPE_ID] = false;
                type_mask[C.VAR_TYPE_ID] = false;
                type_mask[C.SUBROUTINE_TYPE_ID] = false;
                type_mask[C.FUNCTION_TYPE_ID] = false;
            },
            .int_only => {
                abstract_only = true;
                include_globals = false;
                name_only = true;
                type_mask = setTypeMask(true);
                type_mask[C.SUBROUTINE_TYPE_ID] = false;
                type_mask[C.FUNCTION_TYPE_ID] = false;
            },
            .var_only => {
                name_only = true;
                type_mask[C.SUBROUTINE_TYPE_ID] = true;
                type_mask[C.FUNCTION_TYPE_ID] = true;
            },
            .var_key => {
                var key_context: i32 = 0;
                if (scope_list.len > 0) {
                    const enc = scope_list[scope_list.len - 1].getType(false);
                    if (enc == C.MODULE_TYPE_ID) {
                        key_context = 1;
                    } else if (enc == C.SUBROUTINE_TYPE_ID or enc == C.FUNCTION_TYPE_ID) {
                        key_context = 2;
                    } else if (enc == C.CLASS_TYPE_ID) {
                        key_context = 3;
                    }
                }
                for (try self.intr.keywordsFor(a, key_context)) |cand| {
                    if (str.startsWith(try str.lower(a, cand.name), var_prefix)) {
                        try json.append(a, &item_list, try self.buildComp(a, cand, self.s.autocomplete_name_only, null, false, false));
                    }
                }
                return item_list;
            },
            .first => {
                for (try self.intr.keywordsFor(a, 0)) |cand| {
                    if (str.startsWith(try str.lower(a, cand.name), var_prefix)) {
                        try json.append(a, &item_list, try self.buildComp(a, cand, self.s.autocomplete_name_only, null, false, false));
                    }
                }
            },
            else => {},
        }
        const cands = try self.getCandidates(a, scope_list, var_prefix, include_globals, public_only, abstract_only, no_use);
        for (cands.objs, cands.renames) |cand, rename| {
            const ctype = cand.getType(false);
            if (maskGet(&type_mask, ctype)) continue;
            if (req_callable and !cand.isCallable()) continue;
            var name_replace = rename;
            if (ctype == C.INTERFACE_TYPE_ID and lc.ctx != .mod_mems) {
                var seen: std.ArrayList([]const u8) = .empty;
                if (name_replace == null) name_replace = cand.name;
                for (cand.mems.items) |member| {
                    const text = (try member.getSnippet(a, name_replace, -1)).call orelse "None";
                    var dup = false;
                    for (seen.items) |s| if (str.eql(s, text)) {
                        dup = true;
                    };
                    if (dup) continue;
                    try seen.append(a, text);
                    try json.append(a, &item_list, try self.buildComp(a, member, self.s.autocomplete_name_only, name_replace, true, is_member));
                }
                continue;
            }
            try json.append(a, &item_list, try self.buildComp(a, cand, name_only, name_replace, false, false));
        }
        return item_list;
    }

    // ----------------------------------------------------------------------
    // Definition lookup

    /// A temporary variable allocated in `a` (not owned by any AST)
    fn tempVariable(a: Allocator, file_ast: *Ast, line: i64, name: []const u8, desc: []const u8, keywords: []const u8) !*Obj {
        const o = try a.create(Obj);
        o.* = .{
            .kind = .variable,
            .name = name,
            .file_ast = file_ast,
            .sline = line,
            .eline = line,
            .desc = desc,
            .fqsn = try str.lower(a, name),
        };
        try o.keywords.appendSlice(a, keywords);
        if (file_ast.enc_scope_name) |enc| o.fqsn = try str.concat(a, &.{ try str.lower(a, enc), "::", try str.lower(a, name) });
        o.callable = R().CLASS_VAR.match(desc) != null;
        if (o.hasKeyword(C.KW.public)) o.vis = 1;
        if (o.hasKeyword(C.KW.private)) o.vis = -1;
        if (o.hasKeyword(C.KW.parameter)) o.is_const = true;
        return o;
    }

    /// `get_definition` with `def_char` as a byte offset on the line
    pub fn getDefinition(self: *Server, a: Allocator, def_file: *FortranFile, def_line: i64, def_char: usize, hover_req: bool) !?*Obj {
        const ast = def_file.ast orelse return null;
        const cl = try def_file.getCodeLine(a, def_line, false, true, false, true);
        const curr_line = cl.curr orelse return null;
        const line_prefix = (try helpers.getLinePrefix(a, cl.pre, curr_line, def_char, false)) orelse return null;
        const var_stack = try helpers.getVarStack(a, line_prefix);
        const is_member = var_stack.len > 1;
        const def_name = helpers.expandName(curr_line, def_char);
        if (def_name.len == 0) return null;
        // Search in Preprocessor defined variables
        if (def_file.pp_defs.get(def_name)) |d| {
            var arg_str: []const u8 = "";
            if (d.args) |args| {
                var parts: std.ArrayList([]const u8) = .empty;
                for (try str.split(a, args, ",")) |p| try parts.append(a, str.strip(p));
                arg_str = try str.print(a, "({s})", .{try str.join(a, ", ", parts.items)});
            }
            const desc = try str.print(a, "#define {s}{s} {s}", .{ def_name, arg_str, d.value });
            return try tempVariable(a, ast, def_line + 1, def_name, desc, &.{});
        }
        var curr_scope = ast.getInnerScope(def_line + 1);
        if (is_member) {
            curr_scope = (try objects.climbTypeTree(self.env(a), var_stack, curr_scope)) orelse return null;
        }
        var var_obj: ?*Obj = null;
        if (curr_scope) |cs0| {
            var cs = cs0;
            if (cs.getType(false) == C.CLASS_TYPE_ID and !is_member) {
                const lp = str.lstrip(line_prefix);
                if ((str.startsWith(lp, "procedure") and str.count(line_prefix, "=>") > 0) or R().TYPE_DEF_CTX.match(line_prefix) != null) {
                    if (cs.parent) |p| cs = p;
                }
            }
            var_obj = try objects.findInScope(self.env(a), cs, def_name, .{ .var_line_number = def_line + 1 });
            curr_scope = cs;
        }
        if (var_obj) |v| return v;
        if (is_member) return null;
        const key = try str.lower(a, def_name);
        // the file's own global definition before another file's of the
        // same name (fortls gets this from parsing the open file last)
        if (ast.global_dict.get(key)) |o| return o;
        if (self.obj_tree.get(key)) |e| return e.obj;
        for (self.intr.funs) |f| if (std.ascii.eqlIgnoreCase(f.name, key)) return f;
        if (hover_req) if (curr_scope) |cs| {
            var var_type: ?[]const u8 = null;
            if (R().NUMBER.match(def_name) != null) {
                if (std.mem.indexOfAny(u8, def_name, ".ed") != null) {
                    var_type = C.FORTRAN_LITERAL ++ "REAL";
                } else {
                    var_type = C.FORTRAN_LITERAL ++ "INTEGER";
                }
            } else if (R().LOGICAL.match(def_name) != null) {
                var_type = C.FORTRAN_LITERAL ++ "LOGICAL";
            } else if (R().SQ_STRING.match(def_name) != null or R().DQ_STRING.match(def_name) != null) {
                var_type = C.FORTRAN_LITERAL ++ "STRING";
            }
            if (var_type) |vt| return try tempVariable(a, cs.file_ast, def_line + 1, def_name, vt, cs.keywords.items);
        };
        return null;
    }

    fn definitionAt(self: *Server, a: Allocator, params: Value, hover_req: bool) !?struct { file: *FortranFile, obj: *Obj, line: i64, col: usize } {
        const uri = uriOf(params);
        const file = (try self.fileFromUri(a, uri)) orelse return null;
        const pos = posOf(params);
        const col = toByteCol(file, pos.line, pos.char);
        const obj = (try self.getDefinition(a, file, pos.line, col, hover_req)) orelse return null;
        return .{ .file = file, .obj = obj, .line = pos.line, .col = col };
    }

    fn createRefLink(self: *Server, a: Allocator, obj: *Obj) !Value {
        _ = self;
        const obj_file = obj.file_ast.file.?;
        const res = try obj_file.findWordInCodeLine(a, obj.sline - 1, obj.name, true, false, false);
        var schar = res.range.start;
        var echar = res.range.end;
        if (schar < 0) {
            schar = 0;
            echar = 0;
        }
        return uriJson(a, try paths.pathToUri(a, obj_file.path), obj_file, res.line, schar, res.line, echar);
    }

    fn serveDefinition(self: *Server, a: Allocator, params: Value) !Value {
        const d = (try self.definitionAt(a, params, false)) orelse return .null;
        if (d.obj.file_ast.file != null) return self.createRefLink(a, d.obj);
        return .null;
    }

    fn serveHover(self: *Server, a: Allocator, params: Value) !Value {
        const d = (try self.definitionAt(a, params, true)) orelse return .null;
        const var_obj = d.obj;
        const lang_fence = try str.print(a, "```{s}", .{self.s.hover_language});
        var hover_array: std.ArrayList([]const u8) = .empty;
        const vt = var_obj.getType(false);
        if (vt == C.SUBROUTINE_TYPE_ID or vt == C.FUNCTION_TYPE_ID or vt == C.MODULE_TYPE_ID or vt == C.CLASS_TYPE_ID) {
            try hover_array.append(a, try str.replaceFirst(a, try var_obj.getHoverMd(a, true, -1), "```{langid}", lang_fence));
        } else if (vt == C.INTERFACE_TYPE_ID) {
            for (var_obj.mems.items) |member| {
                const h = try member.getHover(a, true, -1);
                if (h.msg != null) try hover_array.append(a, try self.createHover(a, h.msg, h.docs));
            }
        } else if (vt == C.VAR_TYPE_ID) {
            if (!str.startsWith(var_obj.desc, C.FORTRAN_LITERAL)) {
                try hover_array.append(a, try str.replaceFirst(a, try var_obj.getHoverMd(a, true, -1), "```{langid}", lang_fence));
            } else if (str.endsWith(var_obj.desc, "REAL")) {
                try hover_array.append(a, try self.createHover(a, "REAL", null));
            } else if (str.endsWith(var_obj.desc, "INTEGER")) {
                try hover_array.append(a, try self.createHover(a, "INTEGER", null));
            } else if (str.endsWith(var_obj.desc, "LOGICAL")) {
                try hover_array.append(a, try self.createHover(a, "LOGICAL", null));
            } else if (str.endsWith(var_obj.desc, "STRING")) {
                const n = str.codepointLen(var_obj.name);
                try hover_array.append(a, try self.createHover(a, try str.print(a, "CHARACTER(LEN={d})", .{@as(i64, @intCast(n)) - 2}), null));
            }
        }
        if (hover_array.items.len == 0) return .null;
        return json.from(a, .{ .contents = .{ .kind = "markdown", .value = try str.join(a, "\n", hover_array.items) } });
    }

    /// `fortran_md(...).format(langid=...)`
    fn createHover(self: *Server, a: Allocator, msg: ?[]const u8, docs: ?[]const u8) ![]const u8 {
        const md = try helpers.fortranMd(a, msg, docs);
        return pyFormatLangid(a, md, self.s.hover_language);
    }

    fn serveImplementation(self: *Server, a: Allocator, params: Value) !Value {
        const d = (try self.definitionAt(a, params, false)) orelse return .null;
        const var_obj = d.obj;
        if (var_obj.kind == .intrinsic) return .null;
        const parent = var_obj.parent orelse return .null;
        if (parent.getType(false) == C.CLASS_TYPE_ID) {
            if (var_obj.link_obj) |impl| if (impl.file_ast.file != null) return self.createRefLink(a, impl);
        } else if (parent.getType(false) == C.INTERFACE_TYPE_ID) {
            if (var_obj.link_obj) |impl| return self.createRefLink(a, impl);
        }
        return .null;
    }

    // ----------------------------------------------------------------------
    // Signature help

    fn serveSignature(self: *Server, a: Allocator, params: Value) !Value {
        const uri = uriOf(params);
        const file = (try self.fileFromUri(a, uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        const pos = posOf(params);
        const sig_line = pos.line;
        const sig_char = toByteCol(file, sig_line, pos.char);
        const cl = try file.getCodeLine(a, sig_line, false, true, false, true);
        const curr_line = cl.curr orelse return .null;
        const line_prefix = (try helpers.getLinePrefix(a, cl.pre, curr_line, sig_char, true)) orelse return .null;
        if (R().SCOPE_DEF.match(curr_line) != null or R().END.match(curr_line) != null) return .null;
        // get_sub_name
        const pl = try helpers.getParenLevel(a, line_prefix);
        if (pl.sections[0].start <= 1) return .null;
        const arg_string = str.slice(line_prefix, pl.sections[0].start, pl.sections[pl.sections.len - 1].end);
        const pl2 = try helpers.getParenLevel(a, str.slice(line_prefix, 0, pl.sections[0].start - 1));
        const sub_name_raw = str.strip(pl2.str);
        const arg_strings = try str.split(a, arg_string, ",");
        const sub_end = pl2.sections[pl2.sections.len - 1].start;

        const var_stack = try helpers.getVarStack(a, sub_name_raw);
        const is_member = var_stack.len > 1;
        var curr_scope = ast.getInnerScope(sig_line + 1);
        if (is_member) curr_scope = try objects.climbTypeTree(self.env(a), var_stack, curr_scope);
        const sub_name = var_stack[var_stack.len - 1];
        var var_obj: ?*Obj = null;
        if (curr_scope) |cs| var_obj = try objects.findInScope(self.env(a), cs, sub_name, .{});
        if (var_obj == null) {
            const key = try str.lower(a, sub_name);
            if (ast.global_dict.get(key)) |o| {
                var_obj = o;
            } else if (self.obj_tree.get(key)) |e| {
                var_obj = e.obj;
            } else {
                for (self.intr.funs) |f| if (std.ascii.eqlIgnoreCase(f.name, key)) {
                    var_obj = f;
                    break;
                };
            }
        }
        if (var_obj == null and R().INT_STMNT.match(str.slice(line_prefix, 0, sub_end)) != null) {
            const key = try str.lower(a, sub_name);
            for (try self.intr.keywordsFor(a, 0)) |cand| if (std.ascii.eqlIgnoreCase(cand.name, key)) {
                var_obj = cand;
                break;
            };
        }
        const vo = var_obj orelse return .null;
        const sig = try vo.getSignature(a, -1);
        const label = sig.label orelse return .null;
        const lang_fence = try str.print(a, "```{s}", .{self.s.hover_language});
        var params_json = json.newArray();
        for (sig.params) |p| {
            var pv = json.newObject();
            try json.put(a, &pv, "label", json.string(p.label));
            if (p.doc_md) |md| {
                try json.put(a, &pv, "documentation", try json.from(a, .{
                    .kind = "markdown",
                    .value = try str.replaceFirst(a, md, "```{langid}", lang_fence),
                }));
            }
            try json.append(a, &params_json, pv);
        }
        // Find current parameter by index or by last arg with optional name
        var param_num: i64 = @as(i64, @intCast(arg_strings.len)) - 1;
        var opt_num = checkOptional(arg_strings[arg_strings.len - 1], sig.params);
        if (opt_num == null) {
            if (arg_strings.len > 1) {
                opt_num = checkOptional(arg_strings[arg_strings.len - 2], sig.params);
                if (opt_num) |o| param_num = o + 1;
            }
        } else param_num = opt_num.?;
        var signature = json.newObject();
        try json.put(a, &signature, "label", json.string(label));
        try json.put(a, &signature, "parameters", params_json);
        if (sig.doc) |doc| {
            try json.put(a, &signature, "documentation", try json.from(a, .{
                .kind = "markdown",
                .value = try pyFormatLangid(a, doc, self.s.hover_language),
            }));
        }
        var sigs = json.newArray();
        try json.append(a, &sigs, signature);
        var res = json.newObject();
        try json.put(a, &res, "signatures", sigs);
        try json.put(a, &res, "activeParameter", json.integer(param_num));
        return res;
    }

    fn checkOptional(arg: []const u8, params: []const Obj.ArgSig) ?i64 {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
        const opt_arg = str.strip(arg[0..eq]);
        for (params, 0..) |p, i| {
            const lbl = str.beforeFirst(p.label, "=");
            if (std.ascii.eqlIgnoreCase(lbl, opt_arg)) return @intCast(i);
        }
        return null;
    }

    // ----------------------------------------------------------------------
    // References / rename

    const Ref = struct { line: i64, start: i64, end: i64 };
    const FileRefs = struct { path: []const u8, file: *FortranFile, refs: std.ArrayList(Ref) };

    fn hasLinkAttr(o: *const Obj) bool {
        return switch (o.kind) {
            .variable, .method, .subroutine, .function => true,
            else => false,
        };
    }

    fn getAllReferences(self: *Server, a: Allocator, def_obj: *Obj, type_mem: bool, restrict: ?*FortranFile) ![]FileRefs {
        const def_name = try str.lower(a, def_obj.name);
        const def_fqsn = def_obj.fqsn;
        var name_re = regex.Regex.compile(a, try str.print(a, "(?:\\W|^)({s})(?:\\W|$)", .{def_name}), regex.I) catch return &.{};
        defer name_re.deinit();
        var files: std.ArrayList(*FortranFile) = .empty;
        if (restrict) |f| try files.append(a, f) else try files.appendSlice(a, self.workspace.values());
        var override_cache: std.ArrayList([]const u8) = .empty;
        var out: std.ArrayList(FileRefs) = .empty;
        for (files.items) |file| {
            var file_refs: std.ArrayList(Ref) = .empty;
            const filename = file.path;
            for (file.lines.items, 0..) |raw_line, i_usize| {
                const i: i64 = @intCast(i_usize);
                if (raw_line.len == 0) continue;
                const line = file.stripComment(raw_line);
                if (line.len == 0 or line[0] == '#') continue;
                var it = name_re.iterator(line);
                while (it.next()) |m| {
                    const var_def = (try self.getDefinition(a, file, i, m.start(1) + 1, false)) orelse continue;
                    if (var_def.kind == .intrinsic) continue;
                    var ref_match = false;
                    var in_cache = false;
                    for (override_cache.items) |c| if (str.eql(c, var_def.fqsn)) {
                        in_cache = true;
                    };
                    if (str.eql(def_fqsn, var_def.fqsn) or in_cache) {
                        ref_match = true;
                    } else if (var_def.parent != null and var_def.parent.?.getType(false) == C.CLASS_TYPE_ID) {
                        if (type_mem) {
                            for (try var_def.parent.?.getOverridden(a, def_name)) |inherit_def| {
                                if (str.eql(def_fqsn, inherit_def.fqsn)) {
                                    ref_match = true;
                                    try override_cache.append(a, var_def.fqsn);
                                    break;
                                }
                            }
                        }
                        if (!hasLinkAttr(var_def)) {
                            ref_match = false;
                        } else if (var_def.sline - 1 == i and var_def.file_ast.path != null and
                            str.eql(var_def.file_ast.path.?, filename) and str.count(line, "=>") == 0 and
                            var_def.link_obj == def_obj)
                        {
                            try override_cache.append(a, var_def.fqsn);
                            ref_match = true;
                        }
                    } else if (def_obj.kind.isVariable() and def_obj.getType(true) == C.METH_TYPE_ID) {
                        if (def_obj.link_obj) |l| if (l.parent) |lp| if (var_def.parent) |vp| {
                            if (str.eql(lp.fqsn, vp.fqsn)) {
                                ref_match = true;
                                try override_cache.append(a, var_def.fqsn);
                            }
                        };
                    }
                    if (ref_match) try file_refs.append(a, .{ .line = i, .start = @intCast(m.start(1)), .end = @intCast(m.end(1)) });
                }
            }
            if (file_refs.items.len > 0) try out.append(a, .{ .path = filename, .file = file, .refs = file_refs });
        }
        return out.items;
    }

    fn referenceScope(self: *Server, def_obj: *Obj) ?struct { type_mem: bool, restrict: ?*FortranFile } {
        _ = self;
        var type_mem = false;
        var restrict: ?*FortranFile = null;
        if (str.count(def_obj.fqsn, ":") > 2) {
            const parent = def_obj.parent orelse return null;
            if (parent.getType(false) == C.CLASS_TYPE_ID) {
                type_mem = true;
            } else {
                restrict = def_obj.file_ast.file orelse return null;
            }
        }
        return .{ .type_mem = type_mem, .restrict = restrict };
    }

    fn serveReferences(self: *Server, a: Allocator, params: Value) !Value {
        const d = (try self.definitionAt(a, params, false)) orelse return .null;
        if (d.obj.kind == .intrinsic) return error.IntrinsicHasNoFQSN;
        const rs = self.referenceScope(d.obj) orelse return .null;
        const all = try self.getAllReferences(a, d.obj, rs.type_mem, rs.restrict);
        var out = json.newArray();
        for (all) |fr| {
            const uri = try paths.pathToUri(a, fr.path);
            for (fr.refs.items) |r| try json.append(a, &out, try uriJson(a, uri, fr.file, r.line, r.start, r.line, r.end));
        }
        return out;
    }

    fn serveRename(self: *Server, a: Allocator, params: Value) !Value {
        const d = (try self.definitionAt(a, params, false)) orelse return .null;
        if (d.obj.kind == .intrinsic) {
            self.postMessage(a, "Rename failed: Cannot rename intrinsics", C.Severity.warn);
            return .null;
        }
        const rs = self.referenceScope(d.obj) orelse return .null;
        const all = try self.getAllReferences(a, d.obj, rs.type_mem, rs.restrict);
        if (all.len == 0) {
            self.postMessage(a, "Rename failed: No usages found to rename", C.Severity.warn);
            return .null;
        }
        const new_name = (params.get("newName") orelse json.null_value).asStr() orelse "";
        var changes = json.newObject();
        for (all) |fr| {
            const uri = try paths.pathToUri(a, fr.path);
            var edits = json.newArray();
            for (fr.refs.items) |r| {
                var e = json.newObject();
                try json.put(a, &e, "range", try rangeJson(a, fr.file, r.line, r.start, r.line, r.end));
                try json.put(a, &e, "newText", json.string(new_name));
                try json.append(a, &edits, e);
            }
            try json.put(a, &changes, uri, edits);
        }
        var res = json.newObject();
        try json.put(a, &res, "changes", changes);
        return res;
    }

    // ----------------------------------------------------------------------
    // Code actions

    fn serveCodeActions(self: *Server, a: Allocator, params: Value) !Value {
        const uri = uriOf(params);
        const file = (try self.fileFromUri(a, uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        const sline = (params.path(&.{ "range", "start", "line" }) orelse json.null_value).asInt() orelse 0;
        const eline = (params.path(&.{ "range", "end", "line" }) orelse json.null_value).asInt() orelse 0;
        const curr_scope = ast.getInnerScope(sline) orelse return .null;
        const actions = (try curr_scope.getActions(a, sline, eline)) orelse return .null;
        var out = json.newArray();
        for (actions) |act| {
            var edits = json.newArray();
            const edit_file = self.fileForPath(act.uri_path);
            for (act.edits) |e| {
                var ev = json.newObject();
                try json.put(a, &ev, "range", try rangeJson(a, edit_file, e.sline, e.schar, e.eline, e.echar));
                try json.put(a, &ev, "newText", json.string(e.new_text));
                try json.append(a, &edits, ev);
            }
            var changes = json.newObject();
            try json.put(a, &changes, try paths.pathToUri(a, act.uri_path), edits);
            var diags = json.newArray();
            for (act.diagnostics) |dg| try json.append(a, &diags, try self.builtDiagJson(a, file, try dg.build(a, file)));
            var av = json.newObject();
            try json.put(a, &av, "title", json.string(act.title));
            try json.put(a, &av, "kind", json.string(act.kind));
            var edit = json.newObject();
            try json.put(a, &edit, "changes", changes);
            try json.put(a, &av, "edit", edit);
            try json.put(a, &av, "diagnostics", diags);
            try json.append(a, &out, av);
        }
        return out;
    }

    // ----------------------------------------------------------------------
    // Diagnostics

    pub fn getDiagnostics(self: *Server, a: Allocator, uri: []const u8) !?Value {
        const file = (try self.fileFromUri(a, uri)) orelse return null;
        const diags = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
        var arr = json.newArray();
        for (diags) |d| try json.append(a, &arr, try self.builtDiagJson(a, file, d));
        return arr;
    }

    fn sendDiagnostics(self: *Server, a: Allocator, uri: []const u8) void {
        const res = self.getDiagnostics(a, uri) catch |e| {
            self.writeError(a, json.integer(-1), -32603, @errorName(e), json.from(a, .{ .traceback = @errorName(e) }) catch null) catch {};
            return;
        };
        if (res) |diags| {
            self.sendNotification(a, "textDocument/publishDiagnostics", json.from(a, .{ .uri = uri, .diagnostics = diags }) catch return) catch {};
        }
    }

    // ----------------------------------------------------------------------
    // Document synchronization

    fn serveOnChange(self: *Server, a: Allocator, params: Value) !Value {
        const uri = uriOf(params);
        const path = try self.pathFromUri(a, uri);
        const file = self.workspace.get(path) orelse {
            self.postMessage(a, try str.print(a, "Change request failed for unknown file '{s}'", .{path}), C.Severity.err);
            return .null;
        };
        const changes = (params.get("contentChanges") orelse json.null_value).items();
        var reparse_req = true;
        if (self.sync_type == 1) {
            if (changes.len > 0) _ = file.applyChange(try toChange(changes[0])) catch {};
        } else {
            reparse_req = false;
            for (changes) |c| {
                const flag = file.applyChange(try toChange(c)) catch {
                    self.postMessage(a, try str.print(a, "Change request failed for file '{s}': Could not apply change", .{path}), C.Severity.err);
                    return .null;
                };
                reparse_req = reparse_req or flag;
            }
        }
        if (reparse_req) {
            const res = self.updateWorkspaceFile(a, path, false, false, true);
            if (res.err) |e| {
                self.postMessage(a, try str.print(a, "Change request failed for file '{s}': {s}", .{ path, e }), C.Severity.err);
                return .null;
            }
            for (self.workspace.values()) |f| if (f.ast) |ast| try ast.resolveIncludes(&self.workspace, path, a);
            if (file.ast) |ast| try ast.resolveIncludes(&self.workspace, null, a);
            // Periodically reclaim memory of replaced ASTs
            if (self.retired.items.len >= 16) try self.fullRelink(a);
        } else if (file.preproc) {
            const out = try file.preprocess(self.io, &self.pp_defs, &.{});
            try self.mergePpDefs(&out.defs);
        }
        return .null;
    }

    fn toChange(v: Value) !parser.Change {
        const text = (v.get("text") orelse json.null_value).asStr() orelse "";
        const r = v.get("range") orelse return .{ .text = text };
        if (r == .null) return .{ .text = text };
        const sl = (r.path(&.{ "start", "line" }) orelse return error.InvalidParams).asInt() orelse 0;
        const sc = (r.path(&.{ "start", "character" }) orelse return error.InvalidParams).asInt() orelse 0;
        const el = (r.path(&.{ "end", "line" }) orelse return error.InvalidParams).asInt() orelse 0;
        const ec = (r.path(&.{ "end", "character" }) orelse return error.InvalidParams).asInt() orelse 0;
        return .{ .text = text, .range = .{
            .sl = @intCast(@max(sl, 0)),
            .sc = @intCast(@max(sc, 0)),
            .el = @intCast(@max(el, 0)),
            .ec = @intCast(@max(ec, 0)),
        } };
    }

    pub fn serveOnSave(self: *Server, a: Allocator, params: Value, did_open: bool, did_close: bool) !Value {
        const uri = uriOf(params);
        const filepath = try self.pathFromUri(a, uri);
        if (did_close and !paths.isFile(self.io, filepath)) {
            if (self.workspace.get(filepath)) |f| if (f.ast) |ast| self.removeFromTree(ast);
            return .null;
        }
        const res = self.updateWorkspaceFile(a, filepath, true, did_open, false);
        if (res.err) |e| {
            self.postMessage(a, try str.print(a, "Save request failed for file '{s}': {s}", .{ filepath, e }), C.Severity.err);
            return .null;
        }
        if (res.changed) try self.fullRelink(a);
        if (!self.s.disable_diagnostics) self.sendDiagnostics(a, uri);
        return .null;
    }

    const UpdateResult = struct { changed: bool, err: ?[]const u8 };

    fn updateWorkspaceFile(self: *Server, a: Allocator, filepath: []const u8, read_file: bool, allow_empty: bool, update_links: bool) UpdateResult {
        var file = self.workspace.get(filepath);
        var created = false;
        if (read_file) {
            if (file == null) {
                const nf = FortranFile.create(self.gpa, filepath, self.ppSuffixes()) catch return .{ .changed = false, .err = "Error during parsing" };
                if (!paths.isFile(self.io, filepath)) {
                    if (allow_empty) {
                        nf.ast = Ast.create(self.gpa, nf) catch {
                            nf.destroy();
                            return .{ .changed = false, .err = "Error during parsing" };
                        };
                        self.workspace.put(self.gpa, nf.path, nf) catch {};
                        return .{ .changed = false, .err = null };
                    }
                    nf.destroy();
                    return .{ .changed = false, .err = "File does not exist" };
                }
                file = nf;
                created = true;
            }
            const lr = file.?.loadFromDisk(self.io);
            if (lr.err) |e| {
                self.log.err("{s} : {s}", .{ e, filepath });
                if (created) file.?.destroy();
                return .{ .changed = false, .err = e };
            }
            if (!lr.changed) {
                if (created) file.?.destroy();
                return .{ .changed = false, .err = null };
            }
        }
        const f = file orelse return .{ .changed = false, .err = "File does not exist" };
        const ast_new = f.parse(self.io, &self.pp_defs, self.s.include_dirs.slice()) catch {
            self.log.err("Error while parsing file {s}", .{filepath});
            if (created) f.destroy();
            return .{ .changed = false, .err = "Error during parsing" };
        };
        self.mergePpDefs(&f.pp_defs) catch {};
        self.retireFileAst(f) catch {};
        f.ast = ast_new;
        if (!self.workspace.contains(f.path)) self.workspace.put(self.gpa, f.path, f) catch {};
        self.addToTree(f) catch {};
        if (update_links) {
            self.link_version = @mod(self.link_version + 1, 1000);
            var tmp = std.heap.ArenaAllocator.init(self.gpa);
            defer tmp.deinit();
            ast_new.resolveLinks(self.env(tmp.allocator()), self.link_version) catch {};
        }
        _ = a;
        return .{ .changed = true, .err = null };
    }
};

/// Python `str.format(langid=...)` applied to a markdown string: replaces
/// `{langid}` and un-escapes doubled braces.
pub fn pyFormatLangid(a: Allocator, s: []const u8, langid: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (str.startsWith(s[i..], "{langid}")) {
            try out.appendSlice(a, langid);
            i += "{langid}".len;
        } else if (str.startsWith(s[i..], "{{")) {
            try out.append(a, '{');
            i += 2;
        } else if (str.startsWith(s[i..], "}}")) {
            try out.append(a, '}');
            i += 2;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}
