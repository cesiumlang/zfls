//! `initialize` and what comes before it: a client's `capabilities` that
//! is not an object is read as none (the root and the options are still
//! good), and until an `initialize` has succeeded, the client's requests are
//! answered with ServerNotInitialized and its notifications dropped, as
//! the protocol says for those before `initialize` (#368). A failed
//! `initialize` used to leave a server that answered every request with
//! empty results, having indexed nothing.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const lsp = @import("../lsp.zig");
const Value = json.Value;
const workspace = @import("workspace.zig");

const Server = @import("../server.zig").Server;

pub const State = enum { none, done, failed };

/// `initialize`: its answer, and the state of the server after it
pub fn initialize(self: *Server, a: Allocator, params: Value) !Value {
    const result = serve(self, a, params) catch |e| {
        self.init_state = .failed;
        self.log.err("initialize failed ({s}): the requests that follow are answered with ServerNotInitialized", .{@errorName(e)});
        return e;
    };
    self.init_state = .done;
    return result;
}

fn serve(self: *Server, a: Allocator, params: Value) !Value {
    return workspace.serveInitialize(self, a, try json.decode(lsp.InitializeParams, a, try lenient(a, params)));
}

/// `params` with a `capabilities` that is not an object left out
fn lenient(a: Allocator, params: Value) !Value {
    if (params != .object) return params;
    const caps = params.object.get("capabilities") orelse return params;
    if (caps == .object) return params;
    var o = try params.object.clone(a);
    _ = o.orderedRemove("capabilities");
    return .{ .object = o };
}

/// Whether the message `method` waits for a successful `initialize`:
/// all but `initialize` itself, `shutdown` and `exit`
pub fn waits(self: *const Server, method: []const u8) bool {
    if (self.init_state == .done) return false;
    for ([_][]const u8{ "initialize", "shutdown", "exit" }) |m| if (std.mem.eql(u8, m, method)) return false;
    return true;
}

test "a capabilities that is not an object is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try lenient(a, try json.parse(a, "{\"rootPath\": \"/w\", \"capabilities\": []}"));
    try std.testing.expectEqualStrings("{\"rootPath\":\"/w\"}", try json.stringify(a, got));
    const kept = try lenient(a, try json.parse(a, "{\"capabilities\": {\"x\": 1}}"));
    try std.testing.expectEqualStrings("{\"capabilities\":{\"x\":1}}", try json.stringify(a, kept));
    const p = try json.decode(lsp.InitializeParams, a, try lenient(a, try json.parse(a, "{\"rootUri\": \"file:///w\", \"capabilities\": 3}")));
    try std.testing.expectEqualStrings("file:///w", p.rootUri.?);
}
