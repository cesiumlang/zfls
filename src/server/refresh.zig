//! What the client is told after the index changes under it (#980): to ask
//! again for the semantic tokens, inlay hints and code lenses of the
//! documents it shows, and the progress of indexing it did not ask for.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");

const Value = json.Value;
const srv = @import("../server.zig");
const Server = srv.Server;

/// After a change of other files than the one the client changed (a save
/// that relinked, files changed on disk, new settings): the views of the
/// open documents may show what is no longer so
pub fn views(self: *Server, a: Allocator) void {
    const ws = self.config.client.workspace;
    if (ws.semanticTokens.refreshSupport) self.sendRequest(a, "workspace/semanticTokens/refresh", .null) catch |e| self.logSendFailure(e);
    if (ws.inlayHint.refreshSupport) self.sendRequest(a, "workspace/inlayHint/refresh", .null) catch |e| self.logSendFailure(e);
    if (ws.codeLens.refreshSupport) self.sendRequest(a, "workspace/codeLens/refresh", .null) catch |e| self.logSendFailure(e);
}

/// A progress token of the server's own, for work no request of the
/// client's carries one for (indexing again under new settings); null
/// when the client shows no such progress
pub fn token(self: *Server, a: Allocator) ?Value {
    if (!self.config.client.window.workDoneProgress) return null;
    self.progress_tokens += 1;
    const t: Value = .{ .string = a.print("zfls-indexing-{d}", .{self.progress_tokens}) catch return null };
    const params = json.from(a, .{ .token = t }) catch return null;
    self.sendRequest(a, "window/workDoneProgress/create", params) catch |e| {
        self.logSendFailure(e);
        return null;
    };
    return t;
}
