//! Settings from the editor over LSP (#196): in the `initialize` request's
//! `initializationOptions` and in `workspace/didChangeConfiguration`, under
//! the config file's names, either as one object or in its `zfls` member.
//!
//! The settings come from, each over the previous: the command line, the
//! editor, the config file (`.fortlsrc`). The config file is the project's
//! and already takes over from the command line, which is how the VS Code
//! extension passes its settings; the editor's settings over LSP are the
//! same user settings, by another way.
//!
//! A change applies at once. One of the settings that decide what is
//! indexed (source directories, include directories, definitions, ...)
//! re-indexes the workspace, keeping the editor's text of the open
//! documents. One that turns on signature help, code actions or formatting
//! when the server did not announce them registers them with the client
//! where it allows that (`client/registerCapability`); others tell the user
//! to restart the server.
//!
//! The configuration file, fpm.toml and compile_commands.json are read
//! again when they change on disk: the server asks the client to watch
//! them (`workspace/didChangeWatchedFiles`) where it allows that. A change
//! of fpm.toml or compile_commands.json re-indexes the workspace.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const json5 = @import("../json5.zig");
const lsp = @import("../lsp.zig");
const patterns = @import("../patterns.zig");
const paths = @import("../paths.zig");
const C = @import("../constants.zig");
const settings_mod = @import("../settings.zig");

const Settings = settings_mod.Settings;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const workspace = @import("workspace.zig");
const diagnostics = @import("diagnostics.zig");
const pull = @import("pull.zig");
const compile = @import("compile.zig");
const format = @import("format.zig");
const bindc = @import("bindc.zig");
const cache = @import("cache.zig");
const clangd = @import("clangd.zig");
const project = @import("../project.zig");

pub const signature_triggers: []const []const u8 = &.{ "(", "," };

/// The providers that settings turn on and off
pub const Providers = struct {
    signature_help: bool = false,
    code_actions: bool = false,
    formatting: bool = false,
};

pub const State = struct {
    /// The command line's settings, with the root as source directory
    cli: Settings = .{},
    /// The settings in effect as configured, before the server's own
    /// additions (globs resolved, compile_commands.json, fpm.toml)
    configured: Settings = .{},
    /// The editor's settings and the config file's, as JSON objects owned
    /// by the server's arena
    editor: ?Value = null,
    file: ?Value = null,
    client: lsp.ClientCapabilities = .{},
    /// The providers the client knows of: announced in the `initialize`
    /// answer, or registered since
    announced: Providers = .{},
};

/// The settings read when the workspace is indexed: changing one
/// re-indexes it
const index_settings = [_][]const u8{
    "source_dirs",              "incl_suffixes",            "excl_suffixes",        "excl_paths",
    "comment_markers",          "d_lines",                  "sort_keywords",        "recursion_limit",
    "lowercase_intrinsics",     "pp_suffixes",              "include_dirs",         "pp_defs",
    "compile_commands",         "disable_compile_commands", "hover_plain_comments", "disable_openmp_conditional",
    "disable_intel_directives",
};

fn isIndexSetting(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    for (index_settings) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The settings object in `v`: its `zfls` member when that is an object
/// (a client that sends all its settings, by section), else `v` itself;
/// null when `v` is no object
pub fn section(v: ?Value) ?Value {
    const x = v orelse return null;
    if (x != .object) return null;
    if (json.get(x, "zfls")) |z| if (z == .object) return z;
    return x;
}

/// A copy of `v` in the server's arena, for the settings that point into it
fn keep(self: *Server, a: Allocator, v: Value) !Value {
    return json5.parse(self.arena.allocator(), try json.stringify(a, v)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // JSON that json.stringify wrote
    };
}

/// At `initialize`: the editor's settings, then the config file's, over the
/// command line's
pub fn load(self: *Server, a: Allocator, init_options: ?Value) !void {
    const sa = self.arena.allocator();
    self.config.cli = try settings_mod.clone(sa, self.s);
    if (section(init_options)) |v| {
        self.config.editor = try keep(self, a, v);
        try settings_mod.applyConfig(sa, &self.s, self.config.editor.?);
    }
    self.config.file = try workspace.readConfigFile(self, a);
    if (self.config.file) |f| try settings_mod.applyConfig(sa, &self.s, f);
    self.config.configured = try settings_mod.clone(sa, self.s);
    self.sync_type = if (self.s.incremental_sync) 2 else 1;
    // else the command line's, made when the server was created
    if (!settings_mod.sameValue(&self.config.cli, &self.s, "incl_suffixes")) try sourceSuffixes(self, a);
    try self.syncPpDefsFromSettings();
}

/// The pattern of source file names, of `incl_suffixes`
fn sourceSuffixes(self: *Server, a: Allocator) !void {
    if (patterns.createSrcFileExtsStr(self.arena.allocator(), self.s.incl_suffixes.slice())) |re| {
        self.src_ext_regex = re;
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => self.postMessage(a, "Invalid 'incl_suffixes'; keeping the source file extensions in use", C.Severity.warn),
    }
}

/// The providers the settings ask for
pub fn wanted(self: *const Server) Providers {
    return .{
        .signature_help = self.s.use_signature_help,
        .code_actions = self.s.enable_code_actions or self.s.fortitude,
        .formatting = format.enabled(self),
    };
}

/// Whether the client asks for a provider that the settings have turned
/// off since it was announced: it gets no answer
pub fn withdrawn(self: *const Server, comptime p: std.meta.FieldEnum(Providers)) bool {
    return @field(self.config.announced, @tagName(p)) and !@field(wanted(self), @tagName(p));
}

pub fn serveDidChange(self: *Server, a: Allocator, params: Value) !Value {
    const v = section(json.get(params, "settings")) orelse return .null;
    self.config.editor = try keep(self, a, v);
    try apply(self, a, try configured(self), false);
    return .null;
}

/// The settings as configured: the command line's, the editor's over them,
/// the config file's over those
fn configured(self: *Server) !Settings {
    const sa = self.arena.allocator();
    var next = try settings_mod.clone(sa, self.config.cli);
    if (self.config.editor) |e| try settings_mod.applyConfig(sa, &next, e);
    if (self.config.file) |f| try settings_mod.applyConfig(sa, &next, f);
    return next;
}

/// What a file the server watches is to it
pub const Watched = enum {
    /// the configuration file
    config,
    /// fpm.toml or compile_commands.json, read when indexing
    project,
};

/// Whether `path` is one of the files the settings are read from
pub fn watched(self: *const Server, a: Allocator, path: []const u8) !?Watched {
    for (workspace.configFileNames(self)) |name| {
        if (paths.eql(path, try paths.join(a, &.{ self.root_path, name }))) return .config;
    }
    if (paths.eql(path, try paths.join(a, &.{ self.root_path, "fpm.toml" }))) return .project;
    if (self.s.compile_commands) |cc| {
        if (cc.len == 0) return null;
        const p = if (std.Io.Dir.path.isAbsolute(cc)) cc else try paths.join(a, &.{ self.root_path, cc });
        if (paths.eql(path, p) or paths.eql(path, try paths.join(a, &.{ p, "compile_commands.json" }))) return .project;
        return null;
    }
    // where project.findCompileCommands looks
    if (paths.eql(path, try paths.join(a, &.{ self.root_path, "compile_commands.json" }))) return .project;
    for ([_][]const u8{ "build", "builddir" }) |sub| {
        if (paths.eql(path, try paths.join(a, &.{ self.root_path, sub, "compile_commands.json" }))) return .project;
    }
    return null;
}

/// After one of the `watched` files changed on disk: the settings read
/// again, and with fpm.toml or compile_commands.json, the workspace indexed
/// again
pub fn reload(self: *Server, a: Allocator, project_files: bool) !void {
    self.log.info("a configuration file changed: reading the settings again", .{});
    self.config.file = try workspace.readConfigFile(self, a);
    try apply(self, a, try configured(self), project_files);
}

/// At `initialized`: asks the client to watch the `watched` files, where it
/// allows that
pub fn watchConfigFiles(self: *Server, a: Allocator) void {
    if (!self.config.client.workspace.didChangeWatchedFiles.dynamicRegistration) return;
    var names: std.ArrayList([]const u8) = .empty;
    for (workspace.configFileNames(self) ++ [_][]const u8{ "fpm.toml", "compile_commands.json" }) |n| {
        const base = std.Io.Dir.path.basename(n);
        for (names.items) |x| {
            if (std.mem.eql(u8, x, base)) break;
        } else names.append(a, base) catch return;
    }
    const pattern = std.mem.concat(a, u8, &.{ "**/{", std.mem.join(a, ",", names.items) catch return, "}" }) catch return;
    const params = json.from(a, .{ .registrations = &[_]lsp.Registration{.{
        .id = "zfls-config-files",
        .method = "workspace/didChangeWatchedFiles",
        .registerOptions = json.from(a, .{ .watchers = &[_]struct { globPattern: []const u8 }{.{ .globPattern = pattern }} }) catch return,
    }} }) catch return;
    self.sendRequest(a, "client/registerCapability", params) catch |e| self.logSendFailure(e);
}

/// Puts the settings `next` (as configured) in effect; `force_reindex`:
/// index the workspace again whatever the settings
fn apply(self: *Server, a: Allocator, next: Settings, force_reindex: bool) !void {
    pull.changed(self);
    const prev = self.config.configured;
    self.config.configured = next;
    const same = struct {
        fn of(x: *const Settings, y: *const Settings, comptime name: []const u8) bool {
            return settings_mod.sameValue(x, y, name);
        }
    }.of;
    var reindex = force_reindex;
    inline for (index_settings) |name| if (!same(&prev, &next, name)) {
        reindex = true;
    };
    const was_published = !self.s.disable_diagnostics;
    const was_workspace = self.s.workspace_diagnostics;
    if (reindex) {
        try reindexWorkspace(self, a, next);
    } else {
        // the others are as indexed, with the server's additions
        inline for (@typeInfo(Settings).@"struct".field_names) |name| {
            if (comptime !isIndexSetting(name)) @field(self.s, name) = @field(next, name);
        }
        if (!same(&prev, &next, "bind_c_clangd") or !same(&prev, &next, "disable_bind_c_search")) {
            clangd.stop(self);
            bindc.deinitIndex(self);
            clangd.start(self, a);
        }
    }
    if (!same(&prev, &next, "debug_log") and self.s.debug_log) try workspace.configLogger(self);
    try workspace.logOptions(self, a);
    if (!same(&prev, &next, "diagnostic_severity")) try diagnostics.checkDiagnosticSeverity(self, a);
    if (!same(&prev, &next, "compiler_diagnostics") or !same(&prev, &next, "compiler_diagnostics_fixed")) try compile.checkSetting(self, a);
    if (!same(&prev, &next, "formatter") or !same(&prev, &next, "formatter_fixed")) try format.checkSetting(self, a);
    try announce(self, a);
    if (!same(&prev, &next, "code_lens_no_references") or !same(&prev, &next, "code_lens_no_run")) {
        if (self.config.client.workspace.codeLens.refreshSupport) self.sendRequest(a, "workspace/codeLens/refresh", .null) catch |e| self.logSendFailure(e);
    }
    try republish(self, a, was_published, was_workspace);
}

/// Indexes the workspace again under `next`, as `initialize` did, keeping
/// the editor's text of the open documents
fn reindexWorkspace(self: *Server, a: Allocator, next: Settings) !void {
    const sa = self.arena.allocator();
    const Doc = struct { path: []const u8, lines: []const []const u8 };
    var docs: std.ArrayList(Doc) = .empty;
    var it = self.open_docs.keyIterator();
    while (it.next()) |k| {
        const f = self.workspace.get(k.*) orelse continue;
        const lines = try a.alloc([]const u8, f.editLines().len);
        for (f.editLines(), lines) |l, *d| d.* = try a.dupe(u8, l);
        try docs.append(a, .{ .path = try a.dupe(u8, k.*), .lines = lines });
    }
    cache.wait(self);
    clangd.stop(self);
    bindc.deinitIndex(self);
    for (self.workspace.values()) |f| {
        if (f.ast) |ast| ast.destroy();
        f.destroy();
    }
    self.workspace.clearRetainingCapacity();
    self.obj_tree.clearRetainingCapacity();
    for (self.retired.items) |ast| ast.destroy();
    self.retired.clearRetainingCapacity();

    self.s = try settings_mod.clone(sa, next);
    self.whole_root = false;
    try sourceSuffixes(self, a);
    try self.syncPpDefsFromSettings();
    try workspace.loadProjectFiles(self, a);
    try workspace.resolveGlobsInPaths(self, a);
    try workspace.loadIntrinsics(self);
    try workspace.addSourceDirs(self, a);
    try workspace.workspaceInit(self, a, null);
    for (docs.items) |d| {
        // one outside the source directories, read as when it was opened
        if (!self.workspace.contains(d.path)) _ = workspace.updateWorkspaceFile(self, d.path, true, true, false) catch {};
        const f = self.workspace.get(d.path) orelse continue;
        try f.setContents(d.lines, true);
        _ = workspace.updateWorkspaceFile(self, d.path, false, false, false) catch |e| {
            self.log.err("re-indexing {s}: {s}", .{ d.path, @errorName(e) });
        };
    }
    if (docs.items.len > 0) {
        _ = try workspace.addIncludedFiles(self, a, null);
        try workspace.fullRelink(self, a);
    }
    clangd.start(self, a);
}

/// Registers the providers the settings now ask for that the client does
/// not know of, where it allows that
fn announce(self: *Server, a: Allocator) !void {
    const on = wanted(self);
    const known = self.config.announced;
    const td = self.config.client.textDocument;
    const selector = .{ .documentSelector = null };
    var regs: std.ArrayList(lsp.Registration) = .empty;
    var restart: std.ArrayList([]const u8) = .empty;
    if (on.signature_help and !known.signature_help) {
        if (td.signatureHelp.dynamicRegistration) {
            try regs.append(a, .{ .id = "zfls-signatureHelp", .method = "textDocument/signatureHelp", .registerOptions = try json.from(a, .{ .documentSelector = null, .triggerCharacters = signature_triggers }) });
            self.config.announced.signature_help = true;
        } else try restart.append(a, "use_signature_help");
    }
    if (on.code_actions and !known.code_actions) {
        if (td.codeAction.dynamicRegistration) {
            try regs.append(a, .{ .id = "zfls-codeAction", .method = "textDocument/codeAction", .registerOptions = try json.from(a, selector) });
            self.config.announced.code_actions = true;
        } else try restart.append(a, "enable_code_actions");
    }
    if (on.formatting and !known.formatting) {
        if (td.formatting.dynamicRegistration and td.rangeFormatting.dynamicRegistration) {
            try regs.append(a, .{ .id = "zfls-formatting", .method = "textDocument/formatting", .registerOptions = try json.from(a, selector) });
            try regs.append(a, .{ .id = "zfls-rangeFormatting", .method = "textDocument/rangeFormatting", .registerOptions = try json.from(a, selector) });
            self.config.announced.formatting = true;
        } else try restart.append(a, "formatter");
    }
    // the client pulls the workspace's diagnostics only if told so at
    // initialize
    if (self.pull_diagnostics and self.s.workspace_diagnostics and !self.pull_workspace) try restart.append(a, "workspace_diagnostics");
    if (regs.items.len > 0) self.sendRequest(a, "client/registerCapability", try json.from(a, .{ .registrations = regs.items })) catch |e| self.logSendFailure(e);
    if (restart.items.len > 0) {
        const names = try std.mem.join(a, ", ", restart.items);
        self.postMessage(a, try a.print("Restart zfls to apply {s}: the editor does not take features that a running server adds", .{names}), C.Severity.warn);
    }
}

/// The diagnostics again, under the new settings
fn republish(self: *Server, a: Allocator, was_published: bool, was_workspace: bool) !void {
    if (self.s.disable_diagnostics) {
        if (was_published) try clear(self, a, was_workspace, true);
        return;
    }
    // pulled again, by a client that pulls them
    if (self.pull_diagnostics) return pull.refresh(self, a);
    // those of the files that are no longer published
    if (was_workspace and !self.s.workspace_diagnostics) try clear(self, a, true, false);
    if (self.s.workspace_diagnostics) {
        diagnostics.publishWorkspace(self, a);
        return;
    }
    var it = self.open_docs.keyIterator();
    while (it.next()) |k| diagnostics.sendDiagnostics(self, a, try paths.pathToUri(a, k.*));
}

/// Publishes no diagnostics for the workspace's files (`all`) or for the
/// open documents (`open`)
fn clear(self: *Server, a: Allocator, all: bool, open: bool) !void {
    for (self.workspace.values()) |f| {
        const is_open = self.open_docs.contains(f.path);
        if (if (is_open) !open else !all) continue;
        const params = try json.from(a, lsp.PublishDiagnosticsParams{ .uri = try paths.pathToUri(a, f.path), .diagnostics = &.{} });
        self.sendNotification(a, "textDocument/publishDiagnostics", params) catch |e| self.logSendFailure(e);
    }
}
