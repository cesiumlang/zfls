//! `initialize` refused, and what follows (#368): the client's requests
//! are answered with ServerNotInitialized, not with empty results of a
//! server that indexed nothing; a `capabilities` that is not an object is
//! read as none rather than refused. The messages go through the server's
//! `handle`, as a client's do. And the server's name and version in the
//! result (#743).

const std = @import("std");
const h = @import("harness.zig");
const json = h.json;
const Value = json.Value;

const files = [_]h.File{.{ .name = "m.f90", .text = "module m\n  integer :: found_me\nend module m\n" }};

/// Sends a message as a client does: its answer, when it has an `id`
fn send(w: *h.Workspace, a: std.mem.Allocator, id: ?i64, method: []const u8, params: anytype) !?Value {
    const msg = if (id) |i|
        try json.from(a, .{ .jsonrpc = "2.0", .id = i, .method = method, .params = params })
    else
        try json.from(a, .{ .jsonrpc = "2.0", .method = method, .params = params });
    w.server.handle(a, msg);
    const n = id orelse return null;
    const mark = try a.print("\"id\":{d},", .{n});
    for (w.sent.items) |x| if (std.mem.find(u8, x, mark) != null) {
        const v = try json.parse(a, x);
        if (json.get(v, "method") == null) return v;
    };
    return error.NoAnswer;
}

fn errorCode(v: Value) ?i64 {
    return json.int(json.path(v, &.{ "error", "code" }));
}

test "after a refused initialize: ServerNotInitialized (#368)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .uninitialized = true });
    defer w.deinit();
    // invalid params: a number for the root's URI
    const refused = (try send(w, a, 101, "initialize", .{ .rootUri = 5, .capabilities = .{} })).?;
    try std.testing.expectEqual(@as(?i64, -32602), errorCode(refused));
    _ = try send(w, a, null, "initialized", .{});
    const symbols = (try send(w, a, 102, "workspace/symbol", .{ .query = "" })).?;
    try std.testing.expectEqual(@as(?i64, -32002), errorCode(symbols));
    try std.testing.expect(json.get(symbols, "result") == null);
    // the client may still end the server
    const shutdown = (try send(w, a, 103, "shutdown", .{})).?;
    try std.testing.expectEqual(@as(?i64, null), errorCode(shutdown));
}

test "capabilities that is not an object: none, and the server initialized (#368)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .uninitialized = true });
    defer w.deinit();
    // as Zig's std.json writes an empty `.{}`: an array
    const init = (try send(w, a, 201, "initialize", .{ .rootUri = try w.uri(""), .capabilities = [_]u8{} })).?;
    try std.testing.expect(json.get(init, "error") == null);
    try std.testing.expect(json.path(init, &.{ "result", "capabilities" }) != null);
    _ = try send(w, a, null, "initialized", .{});
    const symbols = (try send(w, a, 202, "workspace/symbol", .{ .query = "found" })).?;
    try std.testing.expect(json.get(symbols, "error") == null);
    var names: usize = 0;
    for (json.items(json.get(symbols, "result"))) |s| {
        if (std.mem.eql(u8, json.str(json.get(s, "name")) orelse "", "found_me")) names += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), names);
}

test "the initialize result names the server and its version (#743)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expectEqualStrings("zfls", json.str(json.path(w.init_result, &.{ "serverInfo", "name" })) orelse "");
    const version = json.str(json.path(w.init_result, &.{ "serverInfo", "version" })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(h.zfls.version_info.reported, version);
    try std.testing.expect(version.len > 0);
}
