//! Fortran language server (port of `fortls.langserver`)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const str = @import("str.zig");
const json = @import("json.zig");
const json5 = @import("json5.zig");
const lsp = @import("lsp.zig");
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
const outline = @import("outline.zig");
const semantic = @import("semantic.zig");
const suppress = @import("suppress.zig");

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

/// Ownership:
/// - `workspace` owns its files and each file's `ast` (freed in `destroy`). An
///   AST replaced by a re-parse moves to `retired` and is freed after the next
///   `fullRelink`, once nothing points into it any more.
/// - `obj_tree`, the intrinsic lookups and the candidate lists own only their
///   own slots: the objects belong to the ASTs (or to `intr`).
/// - `arena` owns the settings strings and other data that lives as long as
///   the server; `pp_defs_arena` owns the preprocessor definitions.
/// - Every request gets its own arena (`a`, reset per message): whatever only
///   the reply needs is allocated there.
/// - Errors: allocation failures and the file errors of `parser.FileError`
///   propagate to the request, which answers with an error response (or posts a
///   message for notifications). Sending to the client is best effort: a
///   failure can only be logged.
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
    /// The client takes `DocumentSymbol` trees, not fortls's flat list
    hierarchical_symbols: bool = false,
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
        errdefer self.arena.deinit();
        errdefer self.pp_defs_arena.deinit();
        self.sync_type = if (self.s.incremental_sync) 2 else 1;
        self.src_ext_regex = try patterns.createSrcFileExtsStr(self.arena.allocator(), self.s.incl_suffixes.slice());
        self.intr = try intrinsics.load(gpa, false);
        errdefer self.intr.deinit();
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
            const same = existing != null and std.mem.eql(u8, existing.?.value, e.value_ptr.value) and
                ((existing.?.args == null) == (e.value_ptr.args == null)) and
                (existing.?.args == null or std.mem.eql(u8, existing.?.args.?, e.value_ptr.args.?));
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
        if (self.log.enabled(.debug)) self.log.debug("SEND {s}", .{try json.pretty(a, body)});
    }

    pub fn sendNotification(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .method = method, .params = params }));
    }

    fn writeResponse(self: *Server, a: Allocator, id: Value, result: Value) !void {
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .result = result }));
    }

    fn writeError(self: *Server, a: Allocator, id: Value, code: i64, message: []const u8, data: ?lsp.ErrorData) !void {
        const err: lsp.ResponseError = .{ .code = code, .message = message, .data = data };
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = err }));
    }

    fn logSendFailure(self: *Server, e: anyerror) void {
        self.log.err("could not send a message to the client: {s}", .{@errorName(e)});
    }

    pub fn postMessage(self: *Server, a: Allocator, msg: []const u8, severity: i32) void {
        self.sendNotification(a, "window/showMessage", json.from(a, lsp.ShowMessageParams{ .type = severity, .message = msg }) catch return) catch |e| self.logSendFailure(e);
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
        const method = json.str(json.get(request, "method")) orelse "";
        const id = json.get(request, "id");
        self.log.debug("REQUEST {s} {s}", .{ if (id) |i| (json.stringify(a, i) catch "?") else "None", method });
        const params = json.get(request, "params") orelse .null;
        const result = self.dispatch(a, method, params);
        if (id == null) {
            if (result) |_| {} else |e| self.log.err("error handling request: {s} ({s})", .{ method, @errorName(e) });
            return;
        }
        if (result) |res| {
            self.writeResponse(a, id.?, res) catch |e| self.logSendFailure(e);
        } else |e| switch (e) {
            error.InvalidParams => self.writeError(a, id.?, -32602, "invalid params", null) catch |e2| self.logSendFailure(e2),
            error.MethodNotFound => self.writeError(a, id.?, -32601, std.fmt.allocPrint(a, "method {s} not found", .{method}) catch "method not found", null) catch |e2| self.logSendFailure(e2),
            else => {
                self.log.warn("error handling request {s}: {s}", .{ method, @errorName(e) });
                self.writeError(a, id.?, -32603, @errorName(e), .{ .traceback = @errorName(e) }) catch |e2| self.logSendFailure(e2);
            },
        }
    }

    /// Invoke a handler directly (used by the debug CLI)
    pub fn dispatchPublic(self: *Server, a: Allocator, method: []const u8, params: Value) !Value {
        return self.dispatch(a, method, params);
    }

    /// The requests and notifications the server answers
    const Method = enum {
        initialize,
        document_symbol,
        folding_range,
        semantic_tokens,
        completion,
        signature_help,
        definition,
        references,
        document_highlight,
        hover,
        implementation,
        rename,
        did_open,
        did_save,
        did_close,
        did_change,
        code_action,
        workspace_symbol,
        /// accepted and ignored
        ignored,
        exit,
    };

    const methods = std.StaticStringMap(Method).initComptime(.{
        .{ "initialize", .initialize },
        .{ "textDocument/documentSymbol", .document_symbol },
        .{ "textDocument/foldingRange", .folding_range },
        .{ "textDocument/semanticTokens/full", .semantic_tokens },
        .{ "textDocument/completion", .completion },
        .{ "textDocument/signatureHelp", .signature_help },
        .{ "textDocument/definition", .definition },
        .{ "textDocument/references", .references },
        .{ "textDocument/documentHighlight", .document_highlight },
        .{ "textDocument/hover", .hover },
        .{ "textDocument/implementation", .implementation },
        .{ "textDocument/rename", .rename },
        .{ "textDocument/didOpen", .did_open },
        .{ "textDocument/didSave", .did_save },
        .{ "textDocument/didClose", .did_close },
        .{ "textDocument/didChange", .did_change },
        .{ "textDocument/codeAction", .code_action },
        .{ "workspace/symbol", .workspace_symbol },
        .{ "initialized", .ignored },
        .{ "workspace/didChangeWatchedFiles", .ignored },
        .{ "workspace/didChangeConfiguration", .ignored },
        .{ "$/cancelRequest", .ignored },
        .{ "$/setTrace", .ignored },
        .{ "shutdown", .ignored },
        .{ "exit", .exit },
    });

    fn dispatch(self: *Server, a: Allocator, method: []const u8, params: Value) !Value {
        return switch (methods.get(method) orelse return error.MethodNotFound) {
            .initialize => self.serveInitialize(a, try json.decode(lsp.InitializeParams, a, params)),
            .document_symbol => self.serveDocumentSymbols(a, try json.decode(lsp.TextDocumentParams, a, params)),
            .folding_range => self.serveFoldingRanges(a, try json.decode(lsp.TextDocumentParams, a, params)),
            .semantic_tokens => self.serveSemanticTokens(a, try json.decode(lsp.TextDocumentParams, a, params)),
            .completion => self.serveAutocomplete(a, try json.decode(lsp.PositionParams, a, params)),
            .signature_help => self.serveSignature(a, try json.decode(lsp.PositionParams, a, params)),
            .definition => self.serveDefinition(a, try json.decode(lsp.PositionParams, a, params)),
            .references, .document_highlight => self.serveReferences(a, try json.decode(lsp.PositionParams, a, params)),
            .hover => self.serveHover(a, try json.decode(lsp.PositionParams, a, params)),
            .implementation => self.serveImplementation(a, try json.decode(lsp.PositionParams, a, params)),
            .rename => self.serveRename(a, try json.decode(lsp.RenameParams, a, params)),
            .did_open => self.serveOnSave(a, try json.decode(lsp.TextDocumentParams, a, params), true, false),
            .did_save => self.serveOnSave(a, try json.decode(lsp.TextDocumentParams, a, params), false, false),
            .did_close => self.serveOnSave(a, try json.decode(lsp.TextDocumentParams, a, params), false, true),
            .did_change => self.serveOnChange(a, try json.decode(lsp.DidChangeParams, a, params)),
            .code_action => self.serveCodeActions(a, try json.decode(lsp.CodeActionParams, a, params)),
            .workspace_symbol => self.serveWorkspaceSymbol(a, try json.decode(lsp.WorkspaceSymbolParams, a, params)),
            .ignored => .null,
            .exit => blk: {
                self.serveExit();
                break :blk .null;
            },
        };
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

    fn pathFromUri(self: *Server, a: Allocator, uri: []const u8) ![]const u8 {
        return paths.pathFromUri(self.io, a, uri);
    }

    fn fileFromUri(self: *Server, a: Allocator, uri: []const u8) !?*FortranFile {
        const path = try self.pathFromUri(a, uri);
        return self.workspace.get(path);
    }

    /// LSP character offset (UTF-16) -> byte offset on a file line
    fn toByteCol(file: *const FortranFile, line: usize, char: usize) usize {
        const text = file.getLine(line, false) orelse return char;
        return str.utf16ToByte(text, char);
    }

    /// Byte offset on a file line -> LSP character offset
    fn toLspCol(file: ?*const FortranFile, line: usize, col: usize) usize {
        if (col == 0) return 0;
        const f = file orelse return col;
        const text = f.getLine(line, false) orelse return col;
        return str.byteToUtf16(text, col);
    }

    /// `range_json` with optional end values falling back to the start
    fn rangeOf(file: ?*const FortranFile, sln: usize, sch: usize, eln_in: ?usize, ech_in: ?usize) lsp.Range {
        const eln = if (eln_in) |e| (if (e != 0) e else sln) else sln;
        const ech = if (ech_in) |e| (if (e != 0) e else sch) else sch;
        return .{
            .start = .{ .line = sln, .character = toLspCol(file, sln, sch) },
            .end = .{ .line = eln, .character = toLspCol(file, eln, ech) },
        };
    }

    fn locationOf(uri: []const u8, file: ?*const FortranFile, sln: usize, sch: usize, eln: ?usize, ech: ?usize) lsp.Location {
        return .{ .uri = uri, .range = rangeOf(file, sln, sch, eln, ech) };
    }

    fn fileForPath(self: *Server, path: ?[]const u8) ?*FortranFile {
        const p = path orelse return null;
        return self.workspace.get(p);
    }

    fn diagnosticOf(self: *Server, a: Allocator, file: *const FortranFile, d: objects.BuiltDiag) !lsp.Diagnostic {
        const range: lsp.Range = if (d.cols_are_codepoints) blk: {
            const eln = if (d.eln) |e| (if (e != 0) e else d.sln) else d.sln;
            const ech = if (d.ech) |e| (if (e != 0) e else d.sch) else d.sch;
            break :blk .{
                .start = .{ .line = d.sln, .character = d.sch },
                .end = .{ .line = eln, .character = ech },
            };
        } else rangeOf(file, d.sln, d.sch, d.eln, d.ech);
        var related: ?[]const lsp.DiagnosticRelatedInformation = null;
        if (d.related) |rel| {
            const uri = try paths.pathToUri(a, rel.path orelse "None");
            const info = try a.alloc(lsp.DiagnosticRelatedInformation, 1);
            info[0] = .{ .location = locationOf(uri, self.fileForPath(rel.path), rel.line, 0, null, null), .message = rel.message };
            related = info;
        }
        return .{
            .range = range,
            .message = d.message,
            .severity = d.severity,
            .relatedInformation = related,
            .code = d.code.name(),
            .source = "zfls",
        };
    }

    // ----------------------------------------------------------------------
    // initialize

    fn serveInitialize(self: *Server, a: Allocator, params: lsp.InitializeParams) !Value {
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
        try self.s.source_dirs.add(sa, self.root_path);

        try self.loadConfigFile(a);
        try self.checkDiagnosticSeverity(a);
        try self.resolveGlobsInPaths(a);
        try self.configLogger();
        try self.loadIntrinsics();
        try self.addSourceDirs(a);

        try self.workspaceInit(a);
        self.log.info("zfls - Fortran Language Server {s} Initialized", .{@import("version.zig").reported});

        if (self.s.notify_init) self.postMessage(a, "fortls initialization complete", C.Severity.info);
        return json.from(a, lsp.InitializeResult{ .capabilities = .{
            .completionProvider = .{ .resolveProvider = false, .triggerCharacters = &.{"%"} },
            .textDocumentSync = self.sync_type,
            .signatureHelpProvider = if (self.s.use_signature_help) .{ .triggerCharacters = &.{ "(", "," } } else null,
            .codeActionProvider = if (self.s.enable_code_actions) true else null,
            .semanticTokensProvider = .{ .legend = semantic.legend },
        } });
    }

    /// Problems with the user's configuration file are posted to the client;
    /// only allocation failures are errors
    fn loadConfigFile(self: *Server, a: Allocator) Allocator.Error!void {
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

    fn configLogger(self: *Server) !void {
        if (self.s.debug_log and self.root_path.len > 0) {
            const fname = try paths.join(self.arena.allocator(), &.{ self.root_path, "fortls_debug.log" });
            self.log.openFile(self.io, fname);
            try self.post_messages.append(self.gpa, .{ .severity = C.Severity.info, .message = "fortls debugging enabled" });
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
    }

    fn parseOptions(self: *const Server) parser.Options {
        return .{ .sort_keywords = self.s.sort_keywords };
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
                for (self.s.excl_suffixes.slice()) |ext| if (std.mem.endsWith(u8, f, ext)) {
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
        /// The file with its AST; the caller owns both
        ok: *FortranFile,
        err: parser.FileError,
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
        const f = self.loadFile(filepath) catch |e| return .{ .err = e };
        return .{ .ok = f };
    }

    /// Create, read and parse a workspace file. The caller owns the result
    /// (the file and its AST).
    fn loadFile(self: *Server, filepath: []const u8) parser.FileError!*FortranFile {
        const f = try FortranFile.create(self.gpa, filepath, self.ppSuffixes());
        errdefer f.destroy();
        _ = try f.loadFromDisk(self.io);
        const ast = f.parse(self.io, &self.pp_defs, self.s.include_dirs.slice(), self.parseOptions()) catch return error.ParseFailed;
        // Emulate Python's recursion limit (deeply nested scopes)
        if (maxScopeDepth(ast) > self.s.recursion_limit) {
            ast.destroy();
            return error.RecursionLimit;
        }
        f.ast = ast;
        return f;
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
                .err => |e| self.postMessage(a, try std.fmt.allocPrint(a, "Initialization failed for file {s}: {s}", .{ path, parser.describeFileError(e) }), C.Severity.err),
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
            try self.retired.append(self.gpa, old);
            self.removeFromTree(old);
        }
    }

    /// Re-resolve includes and links across the whole workspace, after
    /// which no object references a retired AST, so those can be freed.
    fn fullRelink(self: *Server, a: Allocator) !void {
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
            if (f.ast) |ast| try ast.resolveIncludes(&self.workspace, try self.includeDirs(a), null, a);
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

    fn serveWorkspaceSymbol(self: *Server, a: Allocator, params: lsp.WorkspaceSymbolParams) !Value {
        var items: std.ArrayList(lsp.SymbolInformation) = .empty;
        for (try objects.findInWorkspace(self.env(a), params.query, false, false)) |cand| {
            const kind: i64 = switch (cand.getType(false)) {
                .module => 2,
                .subroutine => 6,
                .function => 12,
                .class => 5,
                .interface => 11,
                .variable => 13,
                .method => 6,
                else => 1,
            };
            const container: ?[]const u8 = if (std.mem.indexOf(u8, cand.fqsn, "::")) |i| (if (i > 0) cand.fqsn[0..i] else null) else null;
            try items.append(a, .{
                .name = cand.name,
                .kind = kind,
                .location = .{
                    .uri = try paths.pathToUri(a, cand.file_ast.path orelse "None"),
                    .range = .{
                        .start = .{ .line = cand.sline -| 1, .character = 0 },
                        .end = .{ .line = cand.eline -| 1, .character = 0 },
                    },
                },
                .containerName = container,
            });
        }
        std.mem.sort(lsp.SymbolInformation, items.items, {}, struct {
            fn lt(_: void, x: lsp.SymbolInformation, y: lsp.SymbolInformation) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        return json.from(a, items.items);
    }

    fn symbolOf(name: []const u8, kind: i64, uri: []const u8, sln: usize, eln: ?usize, container: ?[]const u8) lsp.SymbolInformation {
        return .{
            .name = name,
            .kind = kind,
            .location = locationOf(uri, null, sln, 0, eln, 0),
            .containerName = if (container) |c| (if (c.len > 0) c else null) else null,
        };
    }

    fn serveDocumentSymbols(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
        const uri = params.textDocument.uri;
        const file = (try self.fileFromUri(a, uri)) orelse return .{ .array = .init(a) };
        const ast = file.ast orelse return .{ .array = .init(a) };
        if (self.hierarchical_symbols) return json.from(a, try outline.documentSymbols(a, file, ast, self.s.symbol_skip_mem));
        var out: std.ArrayList(lsp.SymbolInformation) = .empty;
        for (try ast.getScopes(a, null)) |scope| {
            if (scope.name.len == 0 or std.mem.startsWith(u8, scope.name, "#") or scope.getType(false) == C.TypeId.select) continue;
            const tree = try str.split(a, scope.fqsn, "::");
            var scope_type: i64 = undefined;
            if (tree.len > 2) {
                if (std.mem.startsWith(u8, tree[1], "#gen_int")) scope_type = 11 else continue;
            } else {
                scope_type = outline.flatKind(scope.getType(false), false);
            }
            const container: ?[]const u8 = if (std.mem.indexOf(u8, scope.fqsn, "::")) |i| (if (i > 0) tree[0] else null) else null;
            try out.append(a, symbolOf(scope.name, scope_type, uri, scope.sline -| 1, scope.eline -| 1, container));
            if (scope.getType(false) == C.TypeId.class and !self.s.symbol_skip_mem) {
                for (scope.childList()) |child| {
                    try out.append(a, symbolOf(child.name, outline.flatKind(child.getType(false), true), uri, child.sline -| 1, null, scope.name));
                }
            }
        }
        return json.from(a, out.items);
    }

    fn serveSemanticTokens(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
        const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        return json.from(a, lsp.SemanticTokens{ .data = try semantic.tokens(a, self.env(a), file, ast) });
    }

    fn serveFoldingRanges(self: *Server, a: Allocator, params: lsp.TextDocumentParams) !Value {
        const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        return json.from(a, try outline.foldingRanges(a, file, ast));
    }

    // ----------------------------------------------------------------------
    // Completion

    /// The types of objects that completion leaves out
    const TypeMask = std.EnumSet(C.TypeId);

    /// The inner scopes and the base type are always left out; `def` is
    /// whether the types of named objects are
    fn setTypeMask(def: bool) TypeMask {
        var m = TypeMask.initMany(&.{ .base, .submodule, .block, .select, .do_, .where, .if_, .assoc, .enum_ });
        if (def) m.setUnion(TypeMask.initMany(&.{ .module, .subroutine, .function, .class, .interface, .variable, .method }));
        return m;
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
                        var buf: [256]u8 = undefined;
                        const lname = if (child.name.len <= buf.len)
                            std.ascii.lowerString(&buf, child.name)
                        else
                            try std.ascii.allocLowerString(a, child.name);
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
                        // reversed rename map (last key wins for duplicate values);
                        // the values are lowercase
                        for (use_info.rename_map.keys.items, use_info.rename_map.values.items) |k, v| {
                            if (std.ascii.eqlIgnoreCase(v, obj.name)) rev = k;
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
            if (std.ascii.startsWithIgnoreCase(name, var_prefix)) {
                try out_objs.append(a, v);
                try out_renames.append(a, rn);
            }
        }
        return .{ .objs = out_objs.items, .renames = out_renames.items };
    }

    /// The LSP completion item kind; the ids of the types that have no kind of
    /// their own are used as they are, as fortls does
    fn mapCompletionKind(t: C.TypeId) i64 {
        return switch (t) {
            .module => 9,
            .subroutine => 3,
            .class => 7,
            .variable => 6,
            else => @intFromEnum(t),
        };
    }

    fn buildComp(self: *Server, a: Allocator, candidate: *Obj, name_only: bool, name_replace: ?[]const u8, is_interface: bool, is_member: bool) !lsp.CompletionItem {
        var call_sig: ?[]const u8 = null;
        var label = candidate.name;
        var insert_text: ?[]const u8 = null;
        if (!name_only) {
            if (name_replace) |nr| label = nr;
            const sn = try candidate.getSnippet(a, name_replace, null);
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
                insert_text = s;
            }
        }
        var kind = mapCompletionKind(candidate.getType(false));
        if (is_member and kind == 3) kind = 2;
        var detail = try candidate.getDesc(a);
        if (call_sig) |cs| detail = try std.fmt.allocPrint(a, "{s} {s}", .{ detail, cs });
        var documentation: ?lsp.MarkupContent = null;
        const hover_msg = try candidate.getHoverMd(a, true, null);
        if (hover_msg.len > 0) {
            documentation = .{ .value = try str.replaceFirst(a, hover_msg, "```{langid}", try std.fmt.allocPrint(a, "```{s}", .{self.s.hover_language})) };
        }
        return .{
            .label = label,
            .insertText = insert_text,
            .insertTextFormat = if (insert_text != null) lsp.snippet_format else null,
            .kind = kind,
            .detail = detail,
            .documentation = documentation,
        };
    }

    fn serveAutocomplete(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
        const uri = params.textDocument.uri;
        const file = (try self.fileFromUri(a, uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        const ac_line = params.position.line;
        const ac_char = toByteCol(file, ac_line, params.position.character);
        const cl = try file.getCodeLine(a, ac_line, false, true, false, true);
        const line_prefix = (try helpers.getLinePrefix(a, cl.pre, cl.curr, ac_char, true)) orelse return .null;
        const var_stack = try helpers.getVarStack(a, line_prefix);
        const is_member = var_stack.len > 1;
        var var_prefix = str.strip(var_stack[var_stack.len - 1]);

        var item_list: std.ArrayList(lsp.CompletionItem) = .empty;
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
        type_mask.insert(.module);
        type_mask.insert(.class);
        switch (lc.ctx) {
            .mod_only => {
                for (self.obj_tree.values()) |e| {
                    const cand = e.obj;
                    if (cand.getType(false) == C.TypeId.module and std.ascii.startsWithIgnoreCase(cand.name, var_prefix)) {
                        try item_list.append(a, try self.buildComp(a, cand, true, null, false, false));
                    }
                }
                return json.from(a, item_list.items);
            },
            .mod_mems => {
                name_only = true;
                const mod_name = try std.ascii.allocLowerString(a, lc.info orelse "");
                const mod = self.env(a).global(ast, mod_name) orelse return .null;
                const one = try a.alloc(*Obj, 1);
                one[0] = mod;
                scope_list = one;
                public_only = true;
                include_globals = false;
                type_mask.remove(.class);
            },
            .pro_link => {
                type_mask = setTypeMask(true);
                type_mask.remove(.subroutine);
                type_mask.remove(.function);
                name_only = true;
                include_globals = false;
                no_use = true;
            },
            .call => req_callable = true,
            .type_only => {
                type_mask = setTypeMask(true);
                type_mask.remove(.class);
            },
            .import => {
                name_only = true;
                type_mask = setTypeMask(true);
                type_mask.remove(.class);
                type_mask.remove(.variable);
            },
            .vis => {
                include_globals = false;
                name_only = true;
                type_mask = setTypeMask(true);
                type_mask.remove(.class);
                type_mask.remove(.variable);
                type_mask.remove(.subroutine);
                type_mask.remove(.function);
            },
            .int_only => {
                abstract_only = true;
                include_globals = false;
                name_only = true;
                type_mask = setTypeMask(true);
                type_mask.remove(.subroutine);
                type_mask.remove(.function);
            },
            .var_only => {
                name_only = true;
                type_mask.insert(.subroutine);
                type_mask.insert(.function);
            },
            .var_key => {
                var key_context: i32 = 0;
                if (scope_list.len > 0) {
                    const enc = scope_list[scope_list.len - 1].getType(false);
                    if (enc == C.TypeId.module) {
                        key_context = 1;
                    } else if (enc == C.TypeId.subroutine or enc == C.TypeId.function) {
                        key_context = 2;
                    } else if (enc == C.TypeId.class) {
                        key_context = 3;
                    }
                }
                for (try self.intr.keywordsFor(a, key_context)) |cand| {
                    if (std.ascii.startsWithIgnoreCase(cand.name, var_prefix)) {
                        try item_list.append(a, try self.buildComp(a, cand, self.s.autocomplete_name_only, null, false, false));
                    }
                }
                return json.from(a, item_list.items);
            },
            .first => {
                for (try self.intr.keywordsFor(a, 0)) |cand| {
                    if (std.ascii.startsWithIgnoreCase(cand.name, var_prefix)) {
                        try item_list.append(a, try self.buildComp(a, cand, self.s.autocomplete_name_only, null, false, false));
                    }
                }
            },
            else => {},
        }
        const cands = try self.getCandidates(a, scope_list, var_prefix, include_globals, public_only, abstract_only, no_use);
        for (cands.objs, cands.renames) |cand, rename| {
            const ctype = cand.getType(false);
            if (type_mask.contains(ctype)) continue;
            if (req_callable and !cand.isCallable()) continue;
            var name_replace = rename;
            if (ctype == C.TypeId.interface and lc.ctx != .mod_mems) {
                var seen: std.ArrayList([]const u8) = .empty;
                if (name_replace == null) name_replace = cand.name;
                for (cand.memList()) |member| {
                    const text = (try member.getSnippet(a, name_replace, null)).call orelse "None";
                    var dup = false;
                    for (seen.items) |s| if (std.mem.eql(u8, s, text)) {
                        dup = true;
                    };
                    if (dup) continue;
                    try seen.append(a, text);
                    try item_list.append(a, try self.buildComp(a, member, self.s.autocomplete_name_only, name_replace, true, is_member));
                }
                continue;
            }
            try item_list.append(a, try self.buildComp(a, cand, name_only, name_replace, false, false));
        }
        return json.from(a, item_list.items);
    }

    // ----------------------------------------------------------------------
    // Definition lookup

    /// A temporary variable allocated in `a` (not owned by any AST)
    fn tempVariable(a: Allocator, file_ast: *Ast, line: usize, name: []const u8, desc: []const u8, keywords: []const C.Kw) !*Obj {
        const o = try a.create(Obj);
        o.* = .{
            .kind = .variable,
            .name = name,
            .file_ast = file_ast,
            .sline = line,
            .eline = line,
            .fqsn = try std.ascii.allocLowerString(a, name),
            .data = .{ .variable = .{ .desc = desc } },
        };
        try o.keywords.appendSlice(a, keywords);
        if (file_ast.enc_scope_name) |enc| o.fqsn = try std.mem.concat(a, u8, &.{ try std.ascii.allocLowerString(a, enc), "::", try std.ascii.allocLowerString(a, name) });
        o.varData().callable = R().CLASS_VAR.match(desc) != null;
        if (o.hasKeyword(C.KW.public)) o.vis = .public;
        if (o.hasKeyword(C.KW.private)) o.vis = .private;
        if (o.hasKeyword(C.KW.parameter)) o.varData().is_const = true;
        return o;
    }

    /// `get_definition` with `def_char` as a byte offset on the line
    pub fn getDefinition(self: *Server, a: Allocator, def_file: *FortranFile, def_line: usize, def_char: usize, hover_req: bool) !?*Obj {
        const ast = def_file.ast orelse return null;
        const cl = try def_file.getCodeLine(a, def_line, false, true, false, true);
        const curr_line = cl.curr orelse return null;
        const line_prefix = (try helpers.getLinePrefix(a, cl.pre, curr_line, def_char, false)) orelse return null;
        const var_stack = try helpers.getVarStack(a, line_prefix);
        const is_member = var_stack.len > 1;
        const def_name = helpers.expandName(curr_line, def_char);
        if (def_name.len == 0) return null;
        // On a USE statement, both names of a rename are the module's entity
        if (try self.useRenameTarget(a, ast, curr_line, def_char, def_name)) |o| return o;
        // Search in Preprocessor defined variables
        if (def_file.pp_defs.get(def_name)) |d| {
            var arg_str: []const u8 = "";
            if (d.args) |args| {
                var parts: std.ArrayList([]const u8) = .empty;
                for (try str.split(a, args, ",")) |p| try parts.append(a, str.strip(p));
                arg_str = try std.fmt.allocPrint(a, "({s})", .{try std.mem.join(a, ", ", parts.items)});
            }
            const desc = try std.fmt.allocPrint(a, "#define {s}{s} {s}", .{ def_name, arg_str, d.value });
            return try tempVariable(a, ast, def_line + 1, def_name, desc, &.{});
        }
        var curr_scope = ast.getInnerScope(def_line + 1);
        if (is_member) {
            curr_scope = (try objects.climbTypeTree(self.env(a), var_stack, curr_scope)) orelse return null;
        }
        var var_obj: ?*Obj = null;
        if (curr_scope) |cs0| {
            var cs = cs0;
            if (cs.getType(false) == C.TypeId.class and !is_member) {
                const lp = str.lstrip(line_prefix);
                if ((std.mem.startsWith(u8, lp, "procedure") and std.mem.count(u8, line_prefix, "=>") > 0) or R().TYPE_DEF_CTX.match(line_prefix) != null) {
                    if (cs.parent) |p| cs = p;
                }
            }
            var_obj = try objects.findInScope(self.env(a), cs, def_name, .{ .var_line_number = def_line + 1 });
            curr_scope = cs;
        }
        if (var_obj) |v| return v;
        if (is_member) return null;
        const key = try std.ascii.allocLowerString(a, def_name);
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

    fn definitionAt(self: *Server, a: Allocator, params: lsp.PositionParams, hover_req: bool) !?struct { file: *FortranFile, obj: *Obj, line: usize, col: usize } {
        const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
        const pos = params.position;
        const col = toByteCol(file, pos.line, pos.character);
        const obj = (try self.getDefinition(a, file, pos.line, col, hover_req)) orelse return null;
        return .{ .file = file, .obj = obj, .line = pos.line, .col = col };
    }

    fn createRefLink(self: *Server, a: Allocator, obj: *Obj) !Value {
        _ = self;
        const obj_file = obj.file_ast.file.?;
        const res = try obj_file.findWordInCodeLine(a, obj.sline -| 1, obj.name, true, false, false);
        const found = res.range.start >= 0;
        const schar: usize = if (found) @intCast(res.range.start) else 0;
        const echar: usize = if (found) @intCast(res.range.end) else 0;
        return json.from(a, locationOf(try paths.pathToUri(a, obj_file.path), obj_file, res.line, schar, res.line, echar));
    }

    /// The module entity that the name at `col` stands for when it is one of
    /// the two names of a rename on a USE statement, `use m, local => original`
    /// (hansec #137): the original name is not visible under that name in the
    /// using scope, and a variable there may even have it.
    fn useRenameTarget(self: *Server, a: Allocator, ast: *Ast, line: []const u8, col: usize, name: []const u8) !?*Obj {
        const m = R().USE.match(line) orelse return null;
        if (col < m.end(0)) return null;
        var start = @min(col, line.len);
        while (start > 0 and regex.isWordChar(line[start - 1])) start -= 1;
        const before = str.rstrip(line[0..start]);
        var end = start;
        while (end < line.len and regex.isWordChar(line[end])) end += 1;
        const after = str.lstrip(line[end..]);
        const lower = try std.ascii.allocLowerString(a, name);
        const original = if (std.mem.endsWith(u8, before, "=>"))
            lower
        else if (std.mem.startsWith(u8, after, "=>")) blk: {
            const rest = str.lstrip(after[2..]);
            var n: usize = 0;
            while (n < rest.len and regex.isWordChar(rest[n])) n += 1;
            if (n == 0) return null;
            break :blk try std.ascii.allocLowerString(a, rest[0..n]);
        } else return null;
        const e = self.env(a);
        const mod = e.global(ast, try std.ascii.allocLowerString(a, m.group(2).?)) orelse return null;
        return objects.findInScope(e, mod, original, .{});
    }

    /// The include directories as absolute paths (relative ones are relative
    /// to the workspace root)
    fn includeDirs(self: *Server, a: Allocator) ![]const []const u8 {
        var dirs: std.ArrayList([]const u8) = .empty;
        for (self.s.include_dirs.slice()) |d| try dirs.append(a, if (std.fs.path.isAbsolute(d)) d else try paths.join(a, &.{ self.root_path, d }));
        return dirs.items;
    }

    /// The file that the `#include` directive (or, with `statement`, the
    /// INCLUDE statement) under the cursor names, searched in the directory
    /// of the including file and in the include directories (upstream #498,
    /// #301)
    fn includeDirectiveTarget(self: *Server, a: Allocator, params: lsp.PositionParams, statement: bool) !?[]const u8 {
        const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return null;
        const text = file.getLine(params.position.line, false) orelse return null;
        const re = if (statement) &R().INCLUDE else &R().INCLUDE_DIRECTIVE;
        const m = re.match(text) orelse return null;
        const col = toByteCol(file, params.position.line, params.position.character);
        if (col < m.start(1) or col > m.end(1)) return null;
        const name = m.group(1).?;
        var dirs: std.ArrayList([]const u8) = .empty;
        try dirs.append(a, paths.dirname(file.path));
        try dirs.appendSlice(a, try self.includeDirs(a));
        for (dirs.items) |dir| {
            const candidate = try paths.abspath(a, try paths.join(a, &.{ dir, name }));
            if (paths.isFile(self.io, candidate)) return candidate;
        }
        return null;
    }

    fn serveDefinition(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
        const start: lsp.Position = .{ .line = 0, .character = 0 };
        if (try self.includeDirectiveTarget(a, params, false)) |target| {
            return json.from(a, lsp.Location{ .uri = try paths.pathToUri(a, target), .range = .{ .start = start, .end = start } });
        }
        if (try self.definitionAt(a, params, false)) |d| {
            if (d.obj.file_ast.file != null) return self.createRefLink(a, d.obj);
            return .null;
        }
        // an INCLUDE statement is its own definition when its file is in the
        // workspace; open one that is not
        if (try self.includeDirectiveTarget(a, params, true)) |target| {
            return json.from(a, lsp.Location{ .uri = try paths.pathToUri(a, target), .range = .{ .start = start, .end = start } });
        }
        return .null;
    }

    /// The subroutine or function that an EXTERNAL declaration stands for: the
    /// global procedure of that name, if there is one (upstream #483, #23)
    fn externalTarget(self: *Server, a: Allocator, ast: *Ast, v: *const Obj) !?*Obj {
        if (v.kind != .variable or !v.varDataConst().is_external) return null;
        const key = try std.ascii.allocLowerString(a, v.name);
        const cand = ast.global_dict.get(key) orelse (if (self.obj_tree.get(key)) |e| e.obj else return null);
        return switch (cand.kind) {
            .subroutine, .function => cand,
            else => null,
        };
    }

    /// The global function that a variable of the same name stands for when it
    /// is called: `real fff` in the caller and then `fff(1.2, 3.3)` declares
    /// the type of the function, not a variable (upstream #118)
    fn calledFunction(self: *Server, a: Allocator, ast: *Ast, d: anytype) !?*Obj {
        const v = d.obj;
        if (v.kind != .variable or v.varData().is_const or v.hasKeyword(C.KW.dimension) or v.keyword_info.dimension != null) return null;
        if (v.parent) |p| if (p.getType(false) == C.TypeId.class) return null;
        const text = d.file.getLine(d.line, false) orelse return null;
        var end = d.col;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
        if (!std.mem.startsWith(u8, str.lstrip(text[end..]), "(")) return null;
        const key = try std.ascii.allocLowerString(a, v.name);
        const cand = ast.global_dict.get(key) orelse (if (self.obj_tree.get(key)) |e| e.obj else return null);
        return if (cand.kind == .function) cand else null;
    }

    fn serveHover(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
        const d = (try self.definitionAt(a, params, true)) orelse return .null;
        const ast = d.file.ast.?;
        const var_obj = (try self.externalTarget(a, ast, d.obj)) orelse (try self.calledFunction(a, ast, d)) orelse d.obj;
        const lang_fence = try std.fmt.allocPrint(a, "```{s}", .{self.s.hover_language});
        var hover_array: std.ArrayList([]const u8) = .empty;
        const vt = var_obj.getType(false);
        if (vt == C.TypeId.subroutine or vt == C.TypeId.function or vt == C.TypeId.module or vt == C.TypeId.class) {
            try hover_array.append(a, try str.replaceFirst(a, try var_obj.getHoverMd(a, true, null), "```{langid}", lang_fence));
        } else if (vt == C.TypeId.interface) {
            for (var_obj.memList()) |member| {
                const h = try member.getHover(a, true, null);
                if (h.msg != null) try hover_array.append(a, try self.createHover(a, h.msg, h.docs));
            }
        } else if (vt == C.TypeId.variable) {
            if (!std.mem.startsWith(u8, var_obj.descOf(), C.FORTRAN_LITERAL)) {
                try hover_array.append(a, try str.replaceFirst(a, try var_obj.getHoverMd(a, true, null), "```{langid}", lang_fence));
            } else if (std.mem.endsWith(u8, var_obj.descOf(), "REAL")) {
                try hover_array.append(a, try self.createHover(a, "REAL", null));
            } else if (std.mem.endsWith(u8, var_obj.descOf(), "INTEGER")) {
                try hover_array.append(a, try self.createHover(a, "INTEGER", null));
            } else if (std.mem.endsWith(u8, var_obj.descOf(), "LOGICAL")) {
                try hover_array.append(a, try self.createHover(a, "LOGICAL", null));
            } else if (std.mem.endsWith(u8, var_obj.descOf(), "STRING")) {
                const n = str.codepointLen(var_obj.name);
                try hover_array.append(a, try self.createHover(a, try std.fmt.allocPrint(a, "CHARACTER(LEN={d})", .{@as(i64, @intCast(n)) - 2}), null));
            }
        }
        if (hover_array.items.len == 0) return .null;
        return json.from(a, lsp.Hover{ .contents = .{ .value = try std.mem.join(a, "\n", hover_array.items) } });
    }

    /// `fortran_md(...).format(langid=...)`
    fn createHover(self: *Server, a: Allocator, msg: ?[]const u8, docs: ?[]const u8) ![]const u8 {
        const md = try helpers.fortranMd(a, msg, docs);
        return pyFormatLangid(a, md, self.s.hover_language);
    }

    fn serveImplementation(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
        const d = (try self.definitionAt(a, params, false)) orelse return .null;
        const var_obj = d.obj;
        if (var_obj.kind == .intrinsic) return .null;
        if (try self.externalTarget(a, d.file.ast.?, var_obj)) |target| {
            if (target.file_ast.file != null) return self.createRefLink(a, target);
            return .null;
        }
        const parent = var_obj.parent orelse return .null;
        if (parent.getType(false) == C.TypeId.class) {
            if (var_obj.linkObj()) |impl| if (impl.file_ast.file != null) return self.createRefLink(a, impl);
        } else if (parent.getType(false) == C.TypeId.interface) {
            if (var_obj.linkObj()) |impl| return self.createRefLink(a, impl);
        }
        return .null;
    }

    // ----------------------------------------------------------------------
    // Signature help

    fn serveSignature(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
        const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        const sig_line = params.position.line;
        const sig_char = toByteCol(file, sig_line, params.position.character);
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
        const arg_strings = try helpers.splitArgs(a, arg_string);
        const sub_end = pl2.sections[pl2.sections.len - 1].start;

        const var_stack = try helpers.getVarStack(a, sub_name_raw);
        const is_member = var_stack.len > 1;
        var curr_scope = ast.getInnerScope(sig_line + 1);
        if (is_member) curr_scope = try objects.climbTypeTree(self.env(a), var_stack, curr_scope);
        const sub_name = var_stack[var_stack.len - 1];
        var var_obj: ?*Obj = null;
        if (curr_scope) |cs| var_obj = try objects.findInScope(self.env(a), cs, sub_name, .{});
        if (var_obj == null) {
            const key = try std.ascii.allocLowerString(a, sub_name);
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
            const key = try std.ascii.allocLowerString(a, sub_name);
            for (try self.intr.keywordsFor(a, 0)) |cand| if (std.ascii.eqlIgnoreCase(cand.name, key)) {
                var_obj = cand;
                break;
            };
        }
        const vo = var_obj orelse return .null;
        const sig = try vo.getSignature(a, null);
        const label = sig.label orelse return .null;
        const lang_fence = try std.fmt.allocPrint(a, "```{s}", .{self.s.hover_language});
        const parameters = try a.alloc(lsp.ParameterInformation, sig.params.len);
        for (sig.params, parameters) |p, *pv| {
            pv.* = .{ .label = p.label };
            if (p.doc_md) |md| pv.documentation = .{ .value = try str.replaceFirst(a, md, "```{langid}", lang_fence) };
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
        var signature: lsp.SignatureInformation = .{ .label = label, .parameters = parameters };
        if (sig.doc) |doc| signature.documentation = .{ .value = try pyFormatLangid(a, doc, self.s.hover_language) };
        return json.from(a, lsp.SignatureHelp{ .signatures = &.{signature}, .activeParameter = param_num });
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

    const Ref = struct { line: usize, start: usize, end: usize };
    const FileRefs = struct { path: []const u8, file: *FortranFile, refs: std.ArrayList(Ref) };

    fn hasLinkAttr(o: *const Obj) bool {
        return switch (o.kind) {
            .variable, .method, .subroutine, .function => true,
            else => false,
        };
    }

    /// Whether `v` is the result variable of function `fun`: without a RESULT
    /// clause it is named like the function, and renaming the function renames
    /// it (upstream #322)
    fn isImplicitResult(fun: *const Obj, v: *const Obj) bool {
        return fun.kind == .function and v.kind == .variable and v.parent == fun and std.ascii.eqlIgnoreCase(v.name, fun.name);
    }

    /// Whether `x` and `y` are the interface and the implementation of the
    /// same separate module procedure, in either order (hansec #168)
    fn isSeparateProcedurePair(x: *const Obj, y: *const Obj) bool {
        return isSeparateInterfaceOf(x, y) or isSeparateInterfaceOf(y, x);
    }

    fn isSeparateInterfaceOf(iface: *const Obj, impl: *const Obj) bool {
        const p = iface.parent orelse return false;
        return p.kind == .interface and iface.isModScope() and iface.linkObj() == impl;
    }

    /// Whether the name at `col` is the original name of a renamed import of
    /// `def_obj`, as in `use m, only: local => NAME` where `m` defines it. The
    /// original name is not visible under that name in the importing scope,
    /// so the definition lookup cannot find it (upstream #52).
    fn isRenamedOriginal(line: []const u8, col: usize, def_obj: *const Obj) bool {
        const parent = def_obj.parent orelse return false;
        if (parent.kind != .module) return false;
        if (!std.mem.endsWith(u8, str.rstrip(line[0..col]), "=>")) return false;
        const t = str.lstrip(line);
        if (!std.ascii.startsWithIgnoreCase(t, "use")) return false;
        var rest = str.lstrip(t[3..]);
        if (std.mem.startsWith(u8, rest, "::")) rest = str.lstrip(rest[2..]);
        var n: usize = 0;
        while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) n += 1;
        return std.ascii.eqlIgnoreCase(rest[0..n], parent.name);
    }

    /// A name that a USE statement renamed (`local => original`) and the
    /// scope of that statement
    const RenamedImport = struct { alias: []const u8, scope: *Obj, use_line: usize };

    /// The renamed import that the word at (`line`, `col`) is the local name
    /// of, if it is one (upstream #52)
    fn renamedImport(a: Allocator, file: *FortranFile, line: usize, col: usize, target: *const Obj) !?RenamedImport {
        const text = file.getLine(line, false) orelse return null;
        var it = helpers.words(text);
        const word = while (it.next()) |m| {
            if (m.start <= col and col <= m.end) break m.str;
        } else return null;
        if (std.ascii.eqlIgnoreCase(word, target.name)) return null;
        const lower = try std.ascii.allocLowerString(a, word);
        var scope = (file.ast orelse return null).getInnerScope(line + 1) orelse return null;
        while (true) {
            for (scope.scopeData().use.items) |u| {
                if (!u.is_import and u.rename_map.get(lower) != null) return .{ .alias = lower, .scope = scope, .use_line = u.line_number };
            }
            scope = scope.parent orelse return null;
        }
    }

    /// The uses of a renamed import: of its local name, in the scope of the
    /// USE statement and the statement itself, not of the original name
    fn aliasReferences(self: *Server, a: Allocator, file: *FortranFile, def_obj: *Obj, ri: RenamedImport) ![]FileRefs {
        var name_re = regex.Regex.compile(a, try std.fmt.allocPrint(a, "(?:\\W|^)({s})(?:\\W|$)", .{ri.alias}), regex.I) catch return &.{};
        defer name_re.deinit();
        var refs: std.ArrayList(Ref) = .empty;
        const first = ri.scope.sline -| 1;
        const last = @min(ri.scope.eline -| 1, file.lines.items.len -| 1);
        for (file.lines.items[first .. last + 1], first..) |raw_line, i| {
            const line = file.stripComment(raw_line);
            if (line.len == 0 or line[0] == '#') continue;
            if (std.ascii.findIgnoreCase(line, ri.alias) == null) continue;
            var it = name_re.iterator(line);
            while (it.next()) |m| {
                if (i == ri.use_line -| 1) {
                    // in the USE statement only the local name, before the arrow
                    const after = str.lstrip(line[m.end(1)..]);
                    if (!std.mem.startsWith(u8, after, "=>")) continue;
                } else {
                    const var_def = (try self.getDefinition(a, file, i, m.start(1) + 1, false)) orelse continue;
                    if (!std.mem.eql(u8, def_obj.fqsn, var_def.fqsn)) continue;
                }
                try refs.append(a, .{ .line = i, .start = m.start(1), .end = m.end(1) });
            }
        }
        if (refs.items.len == 0) return &.{};
        const out = try a.alloc(FileRefs, 1);
        out[0] = .{ .path = file.path, .file = file, .refs = refs };
        return out;
    }

    /// The references to `def_obj`. A rename also takes what only it must change:
    /// the result variable of a function and the original name in a renamed
    /// import; "find references" leaves them out, as fortls does.
    fn getAllReferences(self: *Server, a: Allocator, def_obj: *Obj, type_mem: bool, restrict: ?*FortranFile, for_rename: bool) ![]FileRefs {
        const def_name = try std.ascii.allocLowerString(a, def_obj.name);
        const def_fqsn = def_obj.fqsn;
        var name_re = regex.Regex.compile(a, try std.fmt.allocPrint(a, "(?:\\W|^)({s})(?:\\W|$)", .{def_name}), regex.I) catch return &.{};
        defer name_re.deinit();
        var files: std.ArrayList(*FortranFile) = .empty;
        if (restrict) |f| try files.append(a, f) else try files.appendSlice(a, self.workspace.values());
        var override_cache: std.ArrayList([]const u8) = .empty;
        var out: std.ArrayList(FileRefs) = .empty;
        for (files.items) |file| {
            var file_refs: std.ArrayList(Ref) = .empty;
            const filename = file.path;
            for (file.lines.items, 0..) |raw_line, i| {
                if (raw_line.len == 0) continue;
                const line = file.stripComment(raw_line);
                if (line.len == 0 or line[0] == '#') continue;
                if (std.ascii.findIgnoreCase(line, def_name) == null) continue;
                var it = name_re.iterator(line);
                while (it.next()) |m| {
                    if (for_rename and isRenamedOriginal(line, m.start(1), def_obj)) {
                        try file_refs.append(a, .{ .line = i, .start = m.start(1), .end = m.end(1) });
                        continue;
                    }
                    const var_def = (try self.getDefinition(a, file, i, m.start(1) + 1, false)) orelse continue;
                    if (var_def.kind == .intrinsic) continue;
                    var ref_match = false;
                    var in_cache = false;
                    for (override_cache.items) |c| if (std.mem.eql(u8, c, var_def.fqsn)) {
                        in_cache = true;
                    };
                    if (std.mem.eql(u8, def_fqsn, var_def.fqsn) or in_cache or (for_rename and isImplicitResult(def_obj, var_def)) or
                        isSeparateProcedurePair(def_obj, var_def))
                    {
                        ref_match = true;
                    } else if (var_def.parent != null and var_def.parent.?.getType(false) == C.TypeId.class) {
                        if (type_mem) {
                            for (try var_def.parent.?.getOverridden(a, def_name)) |inherit_def| {
                                if (std.mem.eql(u8, def_fqsn, inherit_def.fqsn)) {
                                    ref_match = true;
                                    try override_cache.append(a, var_def.fqsn);
                                    break;
                                }
                            }
                        }
                        if (!hasLinkAttr(var_def)) {
                            ref_match = false;
                        } else if (var_def.sline -| 1 == i and var_def.file_ast.path != null and
                            std.mem.eql(u8, var_def.file_ast.path.?, filename) and std.mem.count(u8, line, "=>") == 0 and
                            var_def.linkObj() == def_obj)
                        {
                            try override_cache.append(a, var_def.fqsn);
                            ref_match = true;
                        }
                    } else if (def_obj.kind.isVariable() and def_obj.getType(true) == C.TypeId.method) {
                        if (def_obj.linkObj()) |l| if (l.parent) |lp| if (var_def.parent) |vp| {
                            if (std.mem.eql(u8, lp.fqsn, vp.fqsn)) {
                                ref_match = true;
                                try override_cache.append(a, var_def.fqsn);
                            }
                        };
                    }
                    if (ref_match) try file_refs.append(a, .{ .line = i, .start = m.start(1), .end = m.end(1) });
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
        if (std.mem.count(u8, def_obj.fqsn, ":") > 2) {
            const parent = def_obj.parent orelse return null;
            // the implementation of a separate module procedure may be in
            // another file (hansec #168)
            if (parent.kind == .interface and def_obj.isModScope() and def_obj.linkObj() != null) return .{ .type_mem = false, .restrict = null };
            if (parent.getType(false) == C.TypeId.class) {
                type_mem = true;
            } else {
                restrict = def_obj.file_ast.file orelse return null;
            }
        }
        return .{ .type_mem = type_mem, .restrict = restrict };
    }

    fn serveReferences(self: *Server, a: Allocator, params: lsp.PositionParams) !Value {
        const d = (try self.definitionAt(a, params, false)) orelse return .null;
        if (d.obj.kind == .intrinsic) return error.IntrinsicHasNoFQSN;
        const rs = self.referenceScope(d.obj) orelse return .null;
        const all = try self.getAllReferences(a, d.obj, rs.type_mem, rs.restrict, false);
        var out: std.ArrayList(lsp.Location) = .empty;
        for (all) |fr| {
            const uri = try paths.pathToUri(a, fr.path);
            for (fr.refs.items) |r| try out.append(a, locationOf(uri, fr.file, r.line, r.start, r.line, r.end));
        }
        return json.from(a, out.items);
    }

    fn serveRename(self: *Server, a: Allocator, params: lsp.RenameParams) !Value {
        const d = (try self.definitionAt(a, .{ .textDocument = params.textDocument, .position = params.position }, false)) orelse return .null;
        if (d.obj.kind == .intrinsic) {
            self.postMessage(a, "Rename failed: Cannot rename intrinsics", C.Severity.warn);
            return .null;
        }
        const all = if (try renamedImport(a, d.file, d.line, d.col, d.obj)) |ri|
            try self.aliasReferences(a, d.file, d.obj, ri)
        else blk: {
            const rs = self.referenceScope(d.obj) orelse return .null;
            break :blk try self.getAllReferences(a, d.obj, rs.type_mem, rs.restrict, true);
        };
        if (all.len == 0) {
            self.postMessage(a, "Rename failed: No usages found to rename", C.Severity.warn);
            return .null;
        }
        const files = try a.alloc(lsp.Changes.File, all.len);
        for (all, files) |fr, *f| {
            const edits = try a.alloc(lsp.TextEdit, fr.refs.items.len);
            for (fr.refs.items, edits) |r, *e| {
                e.* = .{ .range = rangeOf(fr.file, r.line, r.start, r.line, r.end), .newText = params.newName };
            }
            f.* = .{ .uri = try paths.pathToUri(a, fr.path), .edits = edits };
        }
        return json.from(a, lsp.WorkspaceEdit{ .changes = .{ .files = files } });
    }

    // ----------------------------------------------------------------------
    // Code actions

    fn serveCodeActions(self: *Server, a: Allocator, params: lsp.CodeActionParams) !Value {
        const file = (try self.fileFromUri(a, params.textDocument.uri)) orelse return .null;
        const ast = file.ast orelse return .null;
        const sline = params.range.start.line;
        const eline = params.range.end.line;
        const curr_scope = ast.getInnerScope(sline) orelse return .null;
        const actions = (try curr_scope.getActions(a, sline, eline)) orelse return .null;
        const out = try a.alloc(lsp.CodeAction, actions.len);
        for (actions, out) |act, *av| {
            const edit_file = self.fileForPath(act.uri_path);
            const edits = try a.alloc(lsp.TextEdit, act.edits.len);
            for (act.edits, edits) |e, *ev| {
                ev.* = .{ .range = rangeOf(edit_file, e.sline, e.schar, e.eline, e.echar), .newText = e.new_text };
            }
            const files = try a.alloc(lsp.Changes.File, 1);
            files[0] = .{ .uri = try paths.pathToUri(a, act.uri_path), .edits = edits };
            const diags = try a.alloc(lsp.Diagnostic, act.diagnostics.len);
            for (act.diagnostics, diags) |dg, *dv| dv.* = try self.diagnosticOf(a, file, try dg.build(a, file));
            av.* = .{ .title = act.title, .kind = act.kind, .edit = .{ .changes = .{ .files = files } }, .diagnostics = diags };
        }
        return json.from(a, out);
    }

    // ----------------------------------------------------------------------
    // Diagnostics

    fn diagnosticsOf(self: *Server, a: Allocator, uri: []const u8) !?[]const lsp.Diagnostic {
        const file = (try self.fileFromUri(a, uri)) orelse return null;
        const diags = try file.checkFile(self.env(a), self.s.max_line_length, self.s.max_comment_line_length);
        const hidden = try suppress.of(a, file);
        var out: std.ArrayList(lsp.Diagnostic) = .empty;
        for (diags) |d| {
            if (hidden.hides(d.code, d.sln)) continue;
            if (d.code == .module_not_found) if (d.subject) |m| if (self.isExternalModule(m)) continue;
            var dd = d;
            dd.severity = self.severityOf(d.code) orelse d.severity;
            if (dd.severity == 0) continue;
            try out.append(a, try self.diagnosticOf(a, file, dd));
        }
        return out.items;
    }

    /// LSP severities by the names `diagnostic_severity` uses; `off` is 0
    const severity_names = std.StaticStringMap(i32).initComptime(.{
        .{ "off", 0 },
        .{ "error", C.Severity.err },
        .{ "warning", C.Severity.warn },
        .{ "information", C.Severity.info },
        .{ "hint", C.Severity.hint },
    });

    /// The severity `diagnostic_severity` gives the diagnostics of `code`
    /// (0: hidden), if it names it
    fn severityOf(self: *const Server, code: C.DiagCode) ?i32 {
        for (self.s.diagnostic_severity.items) |l| if (std.mem.eql(u8, l.code, code.name())) {
            return severity_names.get(l.level);
        };
        return null;
    }

    /// Whether `external_modules` names module `name`
    fn isExternalModule(self: *const Server, name: []const u8) bool {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) return false;
        const lower = std.ascii.lowerString(&buf, name);
        for (self.s.external_modules.slice()) |pat| {
            var pbuf: [256]u8 = undefined;
            if (pat.len > pbuf.len) continue;
            if (glob.fnmatch(std.ascii.lowerString(&pbuf, pat), lower)) return true;
        }
        return false;
    }

    /// Warns about the codes and severities of `diagnostic_severity` that
    /// zfls does not know
    fn checkDiagnosticSeverity(self: *Server, a: Allocator) !void {
        for (self.s.diagnostic_severity.items) |l| {
            if (C.DiagCode.fromName(l.code) == null) {
                self.postMessage(a, try std.fmt.allocPrint(a, "diagnostic_severity: unknown diagnostic code \"{s}\"", .{l.code}), C.Severity.warn);
            } else if (severity_names.get(l.level) == null) {
                self.postMessage(a, try std.fmt.allocPrint(a, "diagnostic_severity: \"{s}\" for \"{s}\" is not off, error, warning, information or hint", .{ l.level, l.code }), C.Severity.warn);
            }
        }
    }

    /// The diagnostics of a file as a JSON array (used by the debug CLI)
    pub fn getDiagnostics(self: *Server, a: Allocator, uri: []const u8) !?Value {
        const diags = (try self.diagnosticsOf(a, uri)) orelse return null;
        return try json.from(a, diags);
    }

    fn sendDiagnostics(self: *Server, a: Allocator, uri: []const u8) void {
        const res = self.diagnosticsOf(a, uri) catch |e| {
            self.writeError(a, .{ .integer = -1 }, -32603, @errorName(e), .{ .traceback = @errorName(e) }) catch |e2| self.logSendFailure(e2);
            return;
        };
        if (res) |diags| {
            self.sendNotification(a, "textDocument/publishDiagnostics", json.from(a, lsp.PublishDiagnosticsParams{ .uri = uri, .diagnostics = diags }) catch return) catch |e| self.logSendFailure(e);
        }
    }

    // ----------------------------------------------------------------------
    // Document synchronization

    fn serveOnChange(self: *Server, a: Allocator, params: lsp.DidChangeParams) !Value {
        const path = try self.pathFromUri(a, params.textDocument.uri);
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
            _ = self.updateWorkspaceFile(path, false, false, true) catch |e| {
                self.postMessage(a, try std.fmt.allocPrint(a, "Change request failed for file '{s}': {s}", .{ path, parser.describeFileError(e) }), C.Severity.err);
                return .null;
            };
            for (self.workspace.values()) |f| if (f.ast) |ast| try ast.resolveIncludes(&self.workspace, try self.includeDirs(a), path, a);
            if (file.ast) |ast| try ast.resolveIncludes(&self.workspace, try self.includeDirs(a), null, a);
            // Periodically reclaim memory of replaced ASTs
            if (self.retired.items.len >= 16) try self.fullRelink(a);
        } else if (file.preproc) {
            const out = try file.preprocess(self.io, &self.pp_defs, &.{}, null);
            try self.mergePpDefs(&out.defs);
        }
        return .null;
    }

    fn toChange(c: lsp.ContentChange) parser.Change {
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
        if (did_close and !paths.isFile(self.io, filepath)) {
            if (self.workspace.get(filepath)) |f| if (f.ast) |ast| self.removeFromTree(ast);
            return .null;
        }
        const changed = self.updateWorkspaceFile(filepath, true, did_open, false) catch |e| {
            self.postMessage(a, try std.fmt.allocPrint(a, "Save request failed for file '{s}': {s}", .{ filepath, parser.describeFileError(e) }), C.Severity.err);
            return .null;
        };
        if (changed) try self.fullRelink(a);
        if (!self.s.disable_diagnostics) self.sendDiagnostics(a, uri);
        return .null;
    }

    /// Read (if `read_file`) and parse a workspace file and link it into the
    /// workspace; returns whether it changed. A file created here belongs to
    /// the workspace once registered (until then it is destroyed on failure),
    /// and a new AST belongs to its file once installed: the replaced one
    /// goes to `retired`, which is freed after the next full relink.
    fn updateWorkspaceFile(self: *Server, filepath: []const u8, read_file: bool, allow_empty: bool, update_links: bool) parser.FileError!bool {
        var file = self.workspace.get(filepath);
        var created: ?*FortranFile = null;
        errdefer if (created) |f| f.destroy();
        if (read_file) {
            if (file == null) {
                const nf = try FortranFile.create(self.gpa, filepath, self.ppSuffixes());
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
        const ast_new = f.parse(self.io, &self.pp_defs, self.s.include_dirs.slice(), self.parseOptions()) catch {
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
        if (f.ast) |old| self.removeFromTree(old);
        f.ast = ast_new;
        try self.addToTree(f);
        if (update_links) {
            self.link_version = @mod(self.link_version + 1, 1000);
            var tmp = std.heap.ArenaAllocator.init(self.gpa);
            defer tmp.deinit();
            try ast_new.resolveLinks(self.env(tmp.allocator()), self.link_version);
        }
        return true;
    }
};

/// Python `str.format(langid=...)` applied to a markdown string: replaces
/// `{langid}` and un-escapes doubled braces.
pub fn pyFormatLangid(a: Allocator, s: []const u8, langid: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "{langid}")) {
            try out.appendSlice(a, langid);
            i += "{langid}".len;
        } else if (std.mem.startsWith(u8, s[i..], "{{")) {
            try out.append(a, '{');
            i += 2;
        } else if (std.mem.startsWith(u8, s[i..], "}}")) {
            try out.append(a, '}');
            i += 2;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}
