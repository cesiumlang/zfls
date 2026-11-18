//! Pull diagnostics, for a client that asks for them
//! (`textDocument/diagnostic`, `workspace/diagnostic`): it asks when it
//! shows a document, so that none are computed for texts the user has
//! typed past. zfls's own diagnostics are then never published; those of
//! the compiler and the linters, which come later from their threads,
//! still are (compile.publishFrom), alone.
//!
//! A report's `resultId` is a hash of its diagnostics. A request with the
//! last id gets an `unchanged` report, without computing anything when
//! nothing in the workspace changed since (`generation`, counted at each
//! parse, relink, change and setting).
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");

const Value = json.Value;

const Server = @import("../server.zig").Server;
const diagnostics = @import("diagnostics.zig");

/// The last report of a file: its id, and the generation it was computed in
pub const Result = struct { generation: u64, id: u64 };

/// Whether the client pulls diagnostics
pub fn wanted(caps: lsp.ClientCapabilities) bool {
    return caps.textDocument.diagnostic != null;
}

/// Something that diagnostics depend on changed
pub fn changed(self: *Server) void {
    self.diag_generation +%= 1;
}

/// The client's diagnostics are out of date (the settings changed): it is
/// asked to pull them again, where it takes that
pub fn refresh(self: *Server, a: Allocator) void {
    if (self.config.client.workspace.diagnostics.refreshSupport) self.sendRequest(a, "workspace/diagnostic/refresh", .null) catch |e| self.logSendFailure(e);
}

pub const Report = struct {
    kind: []const u8,
    resultId: []const u8,
    items: ?[]const lsp.Diagnostic = null,
};

pub const WorkspaceReport = struct {
    kind: []const u8,
    resultId: []const u8,
    uri: []const u8,
    /// always null: the versions of documents are not kept
    version: ?i64,
    items: ?[]const lsp.Diagnostic = null,
};

/// The report of `uri` (the file `path`) to a client whose last one has
/// `previous`
fn report(self: *Server, a: Allocator, uri: []const u8, path: []const u8, previous: ?[]const u8) !Report {
    const prev: ?u64 = if (previous) |p| std.fmt.parseInt(u64, p, 16) catch null else null;
    if (prev) |id| if (self.pull_results.get(path)) |last| {
        if (last.id == id and last.generation == self.diag_generation) return .{ .kind = "unchanged", .resultId = previous.? };
    };
    const items: []const lsp.Diagnostic = if (self.s.disable_diagnostics) &.{} else (try diagnostics.diagnosticsOf(self, a, uri)) orelse &.{};
    const id = std.hash.Wyhash.hash(0, try json.stringify(a, try json.from(a, items)));
    try remember(self, path, .{ .generation = self.diag_generation, .id = id });
    const result_id = try a.print("{x}", .{id});
    if (prev == id) return .{ .kind = "unchanged", .resultId = result_id };
    return .{ .kind = "full", .resultId = result_id, .items = items };
}

fn remember(self: *Server, path: []const u8, r: Result) !void {
    const gop = try self.pull_results.getOrPut(self.gpa, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = self.gpa.dupe(u8, path) catch |e| {
            self.pull_results.removeByPtr(gop.key_ptr);
            return e;
        };
    }
    gop.value_ptr.* = r;
}

/// `textDocument/diagnostic`: zfls's diagnostics of the document
pub fn serveDocument(self: *Server, a: Allocator, params: lsp.DocumentDiagnosticParams) !Value {
    const uri = params.textDocument.uri;
    return json.from(a, try report(self, a, uri, try self.pathFromUri(a, uri), params.previousResultId));
}

/// `workspace/diagnostic` (`workspace_diagnostics`): those of every file of
/// the workspace, as published to a client that does not pull them
pub fn serveWorkspace(self: *Server, a: Allocator, params: lsp.WorkspaceDiagnosticParams) !Value {
    var out: std.ArrayList(WorkspaceReport) = .empty;
    if (self.s.workspace_diagnostics and !self.s.disable_diagnostics) {
        // the client's ids by path: its URIs need not be spelled as zfls's
        var previous: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (params.previousResultIds) |p| try previous.put(a, try self.pathFromUri(a, p.uri), p.value);
        for (self.workspace.values()) |f| {
            if (!diagnostics.publishedInWorkspace(self, f)) continue;
            const uri = try paths.pathToUri(a, f.path);
            const r = try report(self, a, uri, f.path, previous.get(f.path));
            try out.append(a, .{ .kind = r.kind, .resultId = r.resultId, .uri = uri, .version = null, .items = r.items });
        }
    }
    return json.from(a, .{ .items = out.items });
}

pub fn deinit(self: *Server) void {
    var it = self.pull_results.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.pull_results.deinit(self.gpa);
}

test "to a pulling client, a change keeps nothing waiting and the compiler's diagnostics are published alone at once" {
    const Logger = @import("../logger.zig");
    const settings = @import("../settings.zig");
    const compile = @import("compile.zig");
    const pending = @import("pending.zig");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    var log = Logger.init(io);
    defer log.deinit();
    log.stderr_level = .off;
    const self = try Server.create(gpa, io, settings.Settings{}, &log);
    defer self.destroy();
    self.pull_diagnostics = true;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Sent = struct {
        var list: std.ArrayList([]const u8) = .empty;
        var alloc: Allocator = undefined;
        fn send(_: ?*anyopaque, body: []const u8) void {
            list.append(alloc, alloc.dupe(u8, body) catch return) catch return;
        }
    };
    Sent.list = .empty;
    Sent.alloc = a;
    self.sink = .{ .sendFn = Sent.send };
    const uri = "file:///a.f90";
    pending.schedule(self, a, uri);
    try std.testing.expectEqual(@as(?i96, null), pending.next(self));
    diagnostics.sendDiagnostics(self, a, uri);
    try std.testing.expectEqual(@as(usize, 0), Sent.list.items.len);
    const at: lsp.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } };
    try compile.publishFrom(self, a, .compiler, uri, &.{.{ .range = at, .message = "compiler's", .severity = 1 }});
    try std.testing.expectEqual(@as(usize, 1), Sent.list.items.len);
    try std.testing.expect(std.mem.find(u8, Sent.list.items[0], "compiler's") != null);
}
