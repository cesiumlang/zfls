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
const constructs = @import("constructs.zig");
const arguments = @import("arguments.zig");
const autouse = @import("autouse.zig");
const selection = @import("selection.zig");
const fuzzy = @import("fuzzy.zig");
const project = @import("project.zig");
const semantic = @import("semantic.zig");
const suppress = @import("suppress.zig");
const workspace = @import("server/workspace.zig");
const symbols = @import("server/symbols.zig");
const completion = @import("server/completion.zig");
const definition = @import("server/definition.zig");
const signature = @import("server/signature.zig");
const references = @import("server/references.zig");
const diagnostics = @import("server/diagnostics.zig");
const hints = @import("server/hints.zig");
const calls = @import("server/calls.zig");

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
    /// the client asks whether a position can be renamed first
    prepare_rename: bool = false,
    /// The paths of the documents open in the editor, whose text is the
    /// editor's (keys owned by `gpa`)
    open_docs: std.StringHashMapUnmanaged(void) = .empty,
    /// Every directory under the root is a source directory (no
    /// `source_dirs` option), so new ones are too
    whole_root: bool = false,
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
        var open_it = self.open_docs.keyIterator();
        while (open_it.next()) |k| self.gpa.free(k.*);
        self.open_docs.deinit(self.gpa);
        self.post_messages.deinit(self.gpa);
        self.intr.deinit();
        self.pp_defs_arena.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn syncPpDefsFromSettings(self: *Server) !void {
        _ = self.pp_defs_arena.reset(.free_all);
        self.pp_defs = .empty;
        const a = self.pp_defs_arena.allocator();
        for (self.s.pp_defs.items) |d| {
            try self.pp_defs.put(a, try a.dupe(u8, d.name), .{ .value = try a.dupe(u8, d.value) });
        }
    }

    /// `self.pp_defs = {**self.pp_defs, **file_obj.pp_defs}`
    pub fn mergePpDefs(self: *Server, defs: *const pp.Defs) !void {
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

    pub fn env(self: *Server, tmp: Allocator) objects.Env {
        return .{ .tree = &self.obj_tree, .tmp = tmp };
    }

    // ----------------------------------------------------------------------
    // Messaging

    fn sendJson(self: *Server, a: Allocator, body: Value) !void {
        const text = try json.stringify(a, body);
        self.sink.send(text);
        if (self.log.enabled(.debug)) self.log.debug("SEND {s}", .{try json.pretty(a, body)});
    }

    pub fn sendProgress(self: *Server, a: Allocator, token: Value, value: lsp.WorkDoneProgress) void {
        const params = json.from(a, .{ .token = token, .value = value }) catch return;
        self.sendNotification(a, "$/progress", params) catch |e| self.logSendFailure(e);
    }

    /// Answer request `id`, cancelled before it was handled
    pub fn cancelled(self: *Server, a: Allocator, id: Value) void {
        self.writeError(a, id, -32800, "request cancelled", null) catch |e| self.logSendFailure(e);
    }

    pub fn sendNotification(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .method = method, .params = params }));
    }

    fn writeResponse(self: *Server, a: Allocator, id: Value, result: Value) !void {
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .result = result }));
    }

    pub fn writeError(self: *Server, a: Allocator, id: Value, code: i64, message: []const u8, data: ?lsp.ErrorData) !void {
        const err: lsp.ResponseError = .{ .code = code, .message = message, .data = data };
        try self.sendJson(a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = err }));
    }

    pub fn logSendFailure(self: *Server, e: anyerror) void {
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
        prepare_rename,
        selection_range,
        document_link,
        on_type_formatting,
        inlay_hint,
        prepare_call_hierarchy,
        incoming_calls,
        outgoing_calls,
        prepare_type_hierarchy,
        supertypes,
        subtypes,
        did_open,
        did_save,
        did_close,
        did_change,
        code_action,
        workspace_symbol,
        watched_files,
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
        .{ "textDocument/prepareRename", .prepare_rename },
        .{ "textDocument/selectionRange", .selection_range },
        .{ "textDocument/documentLink", .document_link },
        .{ "textDocument/onTypeFormatting", .on_type_formatting },
        .{ "textDocument/inlayHint", .inlay_hint },
        .{ "textDocument/prepareCallHierarchy", .prepare_call_hierarchy },
        .{ "callHierarchy/incomingCalls", .incoming_calls },
        .{ "callHierarchy/outgoingCalls", .outgoing_calls },
        .{ "textDocument/prepareTypeHierarchy", .prepare_type_hierarchy },
        .{ "typeHierarchy/supertypes", .supertypes },
        .{ "typeHierarchy/subtypes", .subtypes },
        .{ "textDocument/didOpen", .did_open },
        .{ "textDocument/didSave", .did_save },
        .{ "textDocument/didClose", .did_close },
        .{ "textDocument/didChange", .did_change },
        .{ "textDocument/codeAction", .code_action },
        .{ "workspace/symbol", .workspace_symbol },
        .{ "initialized", .ignored },
        .{ "workspace/didChangeWatchedFiles", .watched_files },
        .{ "workspace/didChangeConfiguration", .ignored },
        .{ "$/cancelRequest", .ignored },
        .{ "$/setTrace", .ignored },
        .{ "shutdown", .ignored },
        .{ "exit", .exit },
    });

    fn dispatch(self: *Server, a: Allocator, method: []const u8, params: Value) !Value {
        return switch (methods.get(method) orelse return error.MethodNotFound) {
            .initialize => workspace.serveInitialize(self, a, try json.decode(lsp.InitializeParams, a, params)),
            .document_symbol => symbols.serveDocumentSymbols(self, a, try json.decode(lsp.TextDocumentParams, a, params)),
            .folding_range => symbols.serveFoldingRanges(self, a, try json.decode(lsp.TextDocumentParams, a, params)),
            .semantic_tokens => symbols.serveSemanticTokens(self, a, try json.decode(lsp.TextDocumentParams, a, params)),
            .completion => completion.serveAutocomplete(self, a, try json.decode(lsp.PositionParams, a, params)),
            .signature_help => signature.serveSignature(self, a, try json.decode(lsp.PositionParams, a, params)),
            .definition => definition.serveDefinition(self, a, try json.decode(lsp.PositionParams, a, params)),
            .references, .document_highlight => references.serveReferences(self, a, try json.decode(lsp.PositionParams, a, params)),
            .hover => definition.serveHover(self, a, try json.decode(lsp.PositionParams, a, params)),
            .implementation => definition.serveImplementation(self, a, try json.decode(lsp.PositionParams, a, params)),
            .rename => references.serveRename(self, a, try json.decode(lsp.RenameParams, a, params)),
            .prepare_rename => references.servePrepareRename(self, a, try json.decode(lsp.PositionParams, a, params)),
            .selection_range => definition.serveSelectionRanges(self, a, try json.decode(lsp.SelectionRangeParams, a, params)),
            .document_link => definition.serveDocumentLinks(self, a, try json.decode(lsp.TextDocumentParams, a, params)),
            .on_type_formatting => symbols.serveOnTypeFormatting(self, a, try json.decode(lsp.OnTypeFormattingParams, a, params)),
            .inlay_hint => hints.serveInlayHints(self, a, try json.decode(lsp.InlayHintParams, a, params)),
            .prepare_call_hierarchy => calls.servePrepare(self, a, try json.decode(lsp.PositionParams, a, params)),
            .incoming_calls => calls.serveIncoming(self, a, try json.decode(lsp.CallHierarchyCallsParams, a, params)),
            .outgoing_calls => calls.serveOutgoing(self, a, try json.decode(lsp.CallHierarchyCallsParams, a, params)),
            .prepare_type_hierarchy => calls.servePrepareTypes(self, a, try json.decode(lsp.PositionParams, a, params)),
            .supertypes => calls.serveSupertypes(self, a, try json.decode(lsp.CallHierarchyCallsParams, a, params)),
            .subtypes => calls.serveSubtypes(self, a, try json.decode(lsp.CallHierarchyCallsParams, a, params)),
            .did_open => workspace.serveOnSave(self, a, try json.decode(lsp.TextDocumentParams, a, params), true, false),
            .did_save => workspace.serveOnSave(self, a, try json.decode(lsp.TextDocumentParams, a, params), false, false),
            .did_close => workspace.serveOnSave(self, a, try json.decode(lsp.TextDocumentParams, a, params), false, true),
            .did_change => workspace.serveOnChange(self, a, try json.decode(lsp.DidChangeParams, a, params)),
            .code_action => diagnostics.serveCodeActions(self, a, try json.decode(lsp.CodeActionParams, a, params)),
            .workspace_symbol => symbols.serveWorkspaceSymbol(self, a, try json.decode(lsp.WorkspaceSymbolParams, a, params)),
            .watched_files => workspace.serveWatchedFiles(self, a, try json.decode(lsp.DidChangeWatchedFilesParams, a, params)),
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

    /// `fixed_line_length` when it limits fixed-form lines
    pub fn fixedLimit(self: *const Server) ?usize {
        return if (self.s.fixed_line_length > 0) @intCast(self.s.fixed_line_length) else null;
    }

    // Requests other files make directly (the handlers are in server/)

    pub fn getDiagnostics(self: *Server, a: Allocator, uri: []const u8) !?Value {
        return diagnostics.getDiagnostics(self, a, uri);
    }

    pub fn serveOnSave(self: *Server, a: Allocator, params: lsp.TextDocumentParams, did_open: bool, did_close: bool) !Value {
        return workspace.serveOnSave(self, a, params, did_open, did_close);
    }

    // ----------------------------------------------------------------------
    // Helpers

    pub fn pathFromUri(self: *Server, a: Allocator, uri: []const u8) ![]const u8 {
        return paths.pathFromUri(self.io, a, uri);
    }

    pub fn fileFromUri(self: *Server, a: Allocator, uri: []const u8) !?*FortranFile {
        const path = try self.pathFromUri(a, uri);
        return self.workspace.get(path);
    }

    /// LSP character offset (UTF-16) -> byte offset on a file line
    pub fn toByteCol(file: *const FortranFile, line: usize, char: usize) usize {
        const text = file.getLine(line, false) orelse return char;
        return str.utf16ToByte(text, char);
    }

    /// Byte offset on a file line -> LSP character offset
    pub fn toLspCol(file: ?*const FortranFile, line: usize, col: usize) usize {
        if (col == 0) return 0;
        const f = file orelse return col;
        const text = f.getLine(line, false) orelse return col;
        return str.byteToUtf16(text, col);
    }

    /// `range_json` with optional end values falling back to the start
    pub fn rangeOf(file: ?*const FortranFile, sln: usize, sch: usize, eln_in: ?usize, ech_in: ?usize) lsp.Range {
        const eln = if (eln_in) |e| (if (e != 0) e else sln) else sln;
        const ech = if (ech_in) |e| (if (e != 0) e else sch) else sch;
        return .{
            .start = .{ .line = sln, .character = toLspCol(file, sln, sch) },
            .end = .{ .line = eln, .character = toLspCol(file, eln, ech) },
        };
    }

    pub fn locationOf(uri: []const u8, file: ?*const FortranFile, sln: usize, sch: usize, eln: ?usize, ech: ?usize) lsp.Location {
        return .{ .uri = uri, .range = rangeOf(file, sln, sch, eln, ech) };
    }

    pub fn fileForPath(self: *Server, path: ?[]const u8) ?*FortranFile {
        const p = path orelse return null;
        return self.workspace.get(p);
    }

    pub fn diagnosticOf(self: *Server, a: Allocator, file: *const FortranFile, d: objects.BuiltDiag) !lsp.Diagnostic {
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
            .tags = if (d.code == .unused_name) &.{1} else null,
        };
    }

    // ----------------------------------------------------------------------
    // Types the request handlers in server/ share

    /// Workspace indexing: the files, a result per file and the next file
    /// to take, shared by the threads that parse
    pub const InitJob = struct {
        server: *Server,
        files: []const []const u8,
        results: []InitResult,
        next: std.atomic.Value(usize) = .init(0),
    };

    pub const InitResult = union(enum) {
        none,
        /// The file with its AST; the caller owns both
        ok: *FortranFile,
        err: parser.FileError,
    };

    /// The types of objects that completion leaves out
    pub const TypeMask = std.EnumSet(C.TypeId);

    pub const Candidates = struct { objs: []*Obj, renames: []?[]const u8 };

    pub const Ref = struct { line: usize, start: usize, end: usize };
    pub const FileRefs = struct { path: []const u8, file: *FortranFile, refs: std.ArrayList(Ref) };

    /// A name that a USE statement renamed (`local => original`) and the
    /// scope of that statement
    pub const RenamedImport = struct { alias: []const u8, scope: *Obj, use_line: usize };

    /// LSP severities by the names `diagnostic_severity` uses; `off` is 0
    pub const severity_names = std.StaticStringMap(i32).initComptime(.{
        .{ "off", 0 },
        .{ "error", C.Severity.err },
        .{ "warning", C.Severity.warn },
        .{ "information", C.Severity.info },
        .{ "hint", C.Severity.hint },
    });
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
