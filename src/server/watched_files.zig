//! Files created, changed or deleted outside the editor
//! (`workspace/didChangeWatchedFiles`), and files taken out of the index.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const paths = @import("../paths.zig");
const parser = @import("../parser.zig");
const glob = @import("../glob.zig");

const FortranFile = parser.FortranFile;
const Value = json.Value;

const srv = @import("../server.zig");
const Server = srv.Server;
const workspace = @import("workspace.zig");
const configuration = @import("configuration.zig");
const bindc = @import("bindc.zig");
const linking = @import("linking.zig");
const summary = @import("summary.zig");
const diagnostics = @import("diagnostics.zig");
const refresh = @import("refresh.zig");

const isSourceFile = workspace.isSourceFile;
const updateWorkspaceFile = workspace.updateWorkspaceFile;
const addNeededFiles = workspace.addNeededFiles;

/// Files created, changed or deleted outside the editor (a checkout, a
/// generator): the workspace follows them. Documents open in the editor
/// are left alone, their text being the editor's.
pub fn serveWatchedFiles(self: *Server, a: Allocator, params: lsp.DidChangeWatchedFilesParams) !Value {
    var changed = false;
    // a file the settings are read from, which are read again after
    var settings_file: ?configuration.Watched = null;
    for (params.changes) |ev| {
        const path = try self.pathFromUri(a, ev.uri);
        if (try configuration.watched(self, a, path)) |kind| {
            if (settings_file != .project) settings_file = kind;
            continue;
        }
        // the C search again; a `.h` may be a Fortran include too, which
        // the rest follows
        if (bindc.isCFile(path)) bindc.deinitIndex(self);
        if (self.open_docs.contains(path) or paths.isVirtualUri(path)) continue;
        if (ev.type == 3) {
            if (self.workspace.get(path)) |f| {
                changed = try forgetFile(self, a, f, ev.uri) or changed;
                continue;
            }
            // a folder: the files under it (#959)
            for (self.workspace.values()) |f| {
                if (!paths.isUnder(f.path, path) or self.open_docs.contains(f.path)) continue;
                changed = try forgetFile(self, a, f, try paths.pathToUri(a, f.path)) or changed;
            }
            continue;
        }
        // a folder made or moved here: the files in it (#959)
        if (ev.type == 1 and paths.isDir(self.io, path)) {
            for (try glob.walk(self.io, a, path)) |entry| for (entry.files) |name| {
                const p = try paths.join(a, &.{ entry.dir, name });
                if (!isSourceFile(self, p) or self.open_docs.contains(p)) continue;
                changed = (updateWorkspaceFile(self, p, true, false, false) catch false) or changed;
            };
            continue;
        }
        const included = if (self.workspace.get(path)) |f| f.included else false;
        if (!isSourceFile(self, path) and !included) continue;
        const updated = updateWorkspaceFile(self, path, true, false, false) catch |e| {
            self.log.err("{s} : {s}", .{ parser.describeFileError(e), path });
            continue;
        };
        changed = changed or updated;
    }
    if (try summary.sleepAll(self, a) or changed) {
        _ = try addNeededFiles(self, a, null);
        try linking.fullRelink(self, a);
        try summary.wakeIncluded(self, a);
        if (changed) refresh.views(self, a);
    }
    if (settings_file) |kind| {
        // which publishes the diagnostics again
        try configuration.reload(self, a, kind == .project);
        return .null;
    }
    if (changed and self.s.workspace_diagnostics) diagnostics.publishWorkspace(self, a);
    return .null;
}

/// Takes file `f` (`uri`), deleted or closed, out of the index: its AST is
/// retired and its problems cleared. Whether it had an AST, so that the
/// workspace must be relinked.
fn forgetFile(self: *Server, a: Allocator, f: *FortranFile, uri: []const u8) !bool {
    if (f.ast == null) return false;
    try linking.retireFileAst(self, f);
    f.ast = null;
    // so that the same text, restored, is parsed again
    f.hash = null;
    if (self.s.workspace_diagnostics) self.sendNotification(a, "textDocument/publishDiagnostics", try json.from(a, lsp.PublishDiagnosticsParams{ .uri = uri, .diagnostics = &.{} })) catch |e| self.logSendFailure(e);
    return true;
}
