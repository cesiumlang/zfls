//! zfls's own diagnostics after a change of a document's text. They are
//! published once the text has not changed for `diagnostics_change_delay`
//! milliseconds, so that a burst of edits costs one computation, of the
//! last text, and none of it inside a `didChange` notification. The
//! server's loop (__main__.zig) asks when the next ones are due (`next`)
//! and publishes them when it has no message to handle (`publishDue`).
//! Until then the results of the compiler and the linters for the document
//! are kept, not sent (compile.publishFrom): no publication has theirs of
//! the new text with zfls's of the old one.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const srv = @import("../server.zig");
const Server = srv.Server;
const compile = @import("compile.zig");
const diagnostics = @import("diagnostics.zig");

/// The text of `uri` changed: its diagnostics are published after the
/// delay, at once without one, and not before it is saved with a negative
/// one
pub fn schedule(self: *Server, a: Allocator, uri: []const u8) void {
    const delay = self.s.diagnostics_change_delay;
    // a client that pulls them asks when it wants them (pull.zig)
    if (delay < 0 or self.shut_down or self.pull_diagnostics) return;
    if (delay == 0) return diagnostics.sendDiagnostics(self, a, uri);
    const when = Io.Clock.awake.now(self.io).nanoseconds + @as(i96, delay) * std.time.ns_per_ms;
    put(self, uri, when) catch |e| self.log.err("diagnostics of {s}: {s}", .{ uri, @errorName(e) });
}

fn put(self: *Server, uri: []const u8, when: i96) !void {
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    const gop = try self.diag_pending.getOrPut(self.gpa, uri);
    if (!gop.found_existing) {
        gop.key_ptr.* = self.gpa.dupe(u8, uri) catch |e| {
            self.diag_pending.removeByPtr(gop.key_ptr);
            return e;
        };
    }
    gop.value_ptr.* = when;
}

/// Whether zfls's diagnostics of `uri` wait to be published (under
/// `diag_lock`)
pub fn waiting(self: *const Server, uri: []const u8) bool {
    return self.diag_pending.contains(uri);
}

/// zfls's diagnostics of `uri` wait no more, being published or dropped
/// (under `diag_lock`); whether they did
pub fn settled(self: *Server, uri: []const u8) bool {
    const kv = self.diag_pending.fetchRemove(uri) orelse return false;
    self.gpa.free(kv.key);
    return true;
}

/// The document was closed: nothing more is published of it
pub fn cancel(self: *Server, uri: []const u8) void {
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    _ = settled(self, uri);
}

/// When the first of the waiting diagnostics are due (the awake clock's
/// nanoseconds); null: none wait
pub fn next(self: *Server) ?i96 {
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    var first: ?i96 = null;
    var it = self.diag_pending.valueIterator();
    while (it.next()) |t| first = if (first) |f| @min(f, t.*) else t.*;
    return first;
}

/// Computes and publishes the diagnostics due at `now` (null: all that
/// wait), each of its document's text as it is now
pub fn publishDue(self: *Server, a: Allocator, now: ?i96) void {
    var due: std.ArrayList([]const u8) = .empty;
    {
        self.diag_lock.lockUncancelable(self.io);
        defer self.diag_lock.unlock(self.io);
        var it = self.diag_pending.iterator();
        while (it.next()) |e| {
            if (now) |t| if (e.value_ptr.* > t) continue;
            due.append(a, a.dupe(u8, e.key_ptr.*) catch continue) catch continue;
        }
    }
    for (due.items) |uri| {
        // turned off since the change
        if (self.s.disable_diagnostics) {
            cancel(self, uri);
            continue;
        }
        diagnostics.sendDiagnostics(self, a, uri);
        // not published (the document is gone): what was kept of it is
        compile.publishKept(self, a, uri);
    }
}

/// `shutdown`: the client is leaving. What waits is dropped, and nothing
/// more waits until `exit` (`schedule`), so that nothing is computed or
/// published of a change after the answer to `shutdown`.
pub fn shutdown(self: *Server) void {
    self.diag_lock.lockUncancelable(self.io);
    defer self.diag_lock.unlock(self.io);
    self.shut_down = true;
    var it = self.diag_pending.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.diag_pending.clearRetainingCapacity();
}

pub fn deinit(self: *Server) void {
    var it = self.diag_pending.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.diag_pending.deinit(self.gpa);
}

test "the first time due, and what is due at a time" {
    const Logger = @import("../logger.zig");
    const settings = @import("../settings.zig");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    @import("../paths.zig").init(io);
    var log = Logger.init(io);
    defer log.deinit();
    log.stderr_level = .off;
    const self = try Server.create(gpa, io, settings.Settings{}, &log);
    defer self.destroy();
    try std.testing.expectEqual(@as(?i96, null), next(self));
    try put(self, "file:///a.f90", 300);
    try put(self, "file:///b.f90", 200);
    // a further change of a document moves its time
    try put(self, "file:///b.f90", 500);
    try std.testing.expectEqual(@as(?i96, 300), next(self));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    publishDue(self, arena.allocator(), 250);
    try std.testing.expectEqual(@as(?i96, 300), next(self));
    // not a document of the workspace: nothing to compute, and it waits
    // no more
    publishDue(self, arena.allocator(), 300);
    try std.testing.expectEqual(@as(?i96, 500), next(self));
    cancel(self, "file:///b.f90");
    try std.testing.expectEqual(@as(?i96, null), next(self));
}

test "the compiler's result of a changed text is published with zfls's diagnostics of it, not before" {
    const Logger = @import("../logger.zig");
    const settings = @import("../settings.zig");
    const lsp = @import("../lsp.zig");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    @import("../patterns.zig").init();
    var log = Logger.init(io);
    defer log.deinit();
    log.stderr_level = .off;
    const self = try Server.create(gpa, io, settings.Settings{}, &log);
    defer self.destroy();
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
    const at: lsp.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } };
    const old: lsp.Diagnostic = .{ .range = at, .message = "zfls of the old text", .severity = 1 };
    const new: lsp.Diagnostic = .{ .range = at, .message = "zfls of the new text", .severity = 1 };
    const theirs: lsp.Diagnostic = .{ .range = at, .message = "compiler of the new text", .severity = 1 };
    try compile.publish(self, a, uri, &.{old});
    try std.testing.expectEqual(@as(usize, 1), Sent.list.items.len);
    // the text changes; the compiler's check of it ends before zfls's
    // diagnostics of it are due
    try put(self, uri, 300);
    try compile.publishFrom(self, a, .compiler, uri, &.{theirs});
    try std.testing.expectEqual(@as(usize, 1), Sent.list.items.len);
    try compile.publish(self, a, uri, &.{new});
    try std.testing.expectEqual(@as(usize, 2), Sent.list.items.len);
    const both = Sent.list.items[1];
    try std.testing.expect(std.mem.find(u8, both, "zfls of the new text") != null);
    try std.testing.expect(std.mem.find(u8, both, "compiler of the new text") != null);
    try std.testing.expect(std.mem.find(u8, both, "zfls of the old text") == null);
    try std.testing.expectEqual(@as(?i96, null), next(self));
    // nothing waits: a result is published as it comes
    try compile.publishFrom(self, a, .fortitude, uri, &.{});
    try std.testing.expectEqual(@as(usize, 3), Sent.list.items.len);
}
