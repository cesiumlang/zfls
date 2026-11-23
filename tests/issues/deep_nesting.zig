//! Deeply nested code: answers nested past `std.json.Stringify`'s 256
//! levels are written whole (#779), and thousands of nested constructs are
//! indexed, on several threads, without overflowing a thread's stack
//! (#780). The answers go through the server's `handle`, which writes them
//! as a client reads them.

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");
const timing = @import("timing.zig");
const json = h.json;

/// `n` lines of `line_fmt` (with the line's number), then `tail`
fn repeated(a: std.mem.Allocator, n: usize, comptime line_fmt: []const u8, tail: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| try out.print(a, line_fmt, .{i});
    try out.appendSlice(a, tail);
    return out.items;
}

/// The text the server writes in answer to `method`, parsed
fn answer(w: *h.Workspace, a: std.mem.Allocator, id: i64, method: []const u8, params: anytype) !json.Value {
    w.server.handle(a, try json.from(a, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }));
    const mark = try a.print("\"id\":{d},", .{id});
    for (w.sent.items) |x| if (std.mem.find(u8, x, mark) != null) return json.parse(a, x);
    return error.NoAnswer;
}

test "document symbols of 600 nested procedures are answered whole (#779)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // half-typed code: procedures without END, each in the one before
    const text = try repeated(a, 600, "subroutine s{d}()\n", "");
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text = text }}, .{ .hierarchical_symbols = true });
    defer w.deinit();
    const v = try answer(w, a, 7901, "textDocument/documentSymbol", .{ .textDocument = .{ .uri = try w.uri("d.f90") } });
    var depth: usize = 0;
    var node: ?json.Value = json.items(json.get(v, "result"))[0];
    while (node) |n| : (depth += 1) {
        const children = json.items(json.get(n, "children"));
        node = if (children.len > 0) children[0] else null;
    }
    try std.testing.expectEqual(@as(usize, 600), depth);
}

test "the selection ranges of 900 nested DO loops are answered whole (#779)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.mem.concat(a, u8, &.{
        "program p\n  integer :: i\n",
        try repeated(a, 900, "do i = 1, {d}\n", ""),
        try repeated(a, 900, "end do ! {d}\n", "end program p\n"),
    });
    const w = try h.Workspace.init(&.{.{ .name = "d.f90", .text = text }}, .{});
    defer w.deinit();
    const v = try answer(w, a, 7902, "textDocument/selectionRange", .{
        .textDocument = .{ .uri = try w.uri("d.f90") },
        .positions = &[_]struct { line: i64, character: i64 }{.{ .line = 902, .character = 2 }},
    });
    var depth: usize = 0;
    var node: ?json.Value = json.items(json.get(v, "result"))[0];
    while (node) |n| : (depth += 1) node = json.get(n, "parent");
    // a range per loop at least
    try h.expect(depth > 900, "depth {d}", .{depth});
}

test "files of 3000 nested constructs are indexed on several threads (#780)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = try std.mem.concat(a, u8, &.{
        "program p\n  integer :: i\n",
        try repeated(a, 3000, "do i = 1, {d}\n", ""),
        try repeated(a, 3000, "end do ! {d}\n", "end program p\n"),
    });
    var files: std.ArrayList(h.File) = .empty;
    for (0..2) |i| try files.append(a, .{ .name = try a.print("d{d}.f90", .{i}), .text = deep });
    for (0..4) |i| try files.append(a, .{ .name = try a.print("s{d}.f90", .{i}), .text = try a.print("module s{d}\n  integer :: x{d}\nend module s{d}\n", .{ i, i, i }) });
    // past the recursion limit (skipped), and within a higher one (indexed)
    for ([_]i64{ 1000, 10000 }) |limit| {
        const w = try h.Workspace.init(files.items, .{ .settings = .{ .nthreads = 4, .recursion_limit = limit } });
        defer w.deinit();
        const syms = try w.workspaceSymbols("x3");
        try h.expect(syms.len == 1, "x3: {any}", .{syms});
    }
}

test "a file of 3000 nested loops beside a small one, indexed again and again (#802)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = try std.mem.concat(a, u8, &.{
        "program p\n  integer :: i\n",
        try repeated(a, 3000, "do i = 1, {d}\n", ""),
        try repeated(a, 3000, "end do ! {d}\n", "end program p\n"),
    });
    const files = [_]h.File{
        .{ .name = "a.f90", .text = "module a\n  integer :: x\nend module a\n" },
        .{ .name = "deep_do.f90", .text = deep },
    };
    // the crash of the audit's folder came and went with the threads' timing
    for (0..8) |_| {
        const w = try h.Workspace.init(&files, .{ .settings = .{ .nthreads = 2 } });
        defer w.deinit();
        const syms = try w.workspaceSymbols("x");
        try h.expect(syms.len == 1, "x: {any}", .{syms});
    }
}

fn nestedLoops(n: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.mem.concat(a, u8, &.{
        "program p\n  integer :: i\n",
        try repeated(a, n, "do i = 1, {d}\n", ""),
        try repeated(a, n, "end do ! {d}\n", "end program p\n"),
    });
    const w = try h.Workspace.init(&.{.{ .name = "l.f90", .text = text }}, .{});
    defer w.deinit();
    const found = try w.diagnostics("l.f90");
    try h.expect(found.len == 0, "{d} diagnostics", .{found.len});
}

test "6000 nested loops have their diagnostics in seconds (#837)" {
    // 31 seconds before (each `i` looked for through all the loops around it)
    try timing.expectLinear(nestedLoops, 750, 6000);
}

test "--debug_parser prints each of 1000 nested loops once (#838)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.mem.concat(a, u8, &.{
        "program p\n  integer :: i\n",
        try repeated(a, 1000, "do i = 1, {d}\n", ""),
        try repeated(a, 1000, "end do ! {d}\n", "end program p\n"),
    });
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
    defer w.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    _ = try zfls.debug.runTo(std.testing.allocator, std.testing.io, .{ .debug_parser = true, .debug_filepath = try w.path("t.f90"), .debug_rootpath = w.root }, .{ .a = std.testing.allocator, .out = &out });
    // each loop is listed once (it was in the tree of every loop around it
    // too: about 1.5 GB of output before, 5 MB now)
    const tree = out.items[std.mem.find(u8, out.items, "Object Tree").?..std.mem.find(u8, out.items, "Exportable Objects").?];
    try h.expect(std.mem.count(u8, tree, "::#do1000\n") == 1, "listed {d} times", .{std.mem.count(u8, tree, "::#do1000\n")});
    try h.expect(out.items.len < 40_000_000, "{d} bytes", .{out.items.len});
}

/// Gets the diagnostics of `n` unclosed procedures, each in the one before.
fn unclosed(n: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // half-typed code
    const text = try repeated(a, n, "subroutine s{d}()\n", "");
    const w = try h.Workspace.init(&.{.{ .name = "u.f90", .text = text }}, .{});
    defer w.deinit();
    const found = try w.diagnostics("u.f90");
    // each one is not closed, and that is all (#837)
    try h.expect(found.len == n, "{d} diagnostics", .{found.len});
}

test "6000 unclosed procedures have their diagnostics in seconds (#803, #841)" {
    // 33 seconds before for 3000 (#803), then 9 for 6000 (checkDefinitions
    // hashed each scope's whole path)
    try timing.expectLinear(unclosed, 750, 6000);
}

test "every unclosed procedure of a long run of them is reported (#869)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 2, 100, 499, 500, 501, 749, 750, 751, 1000, 1500 }) |n| {
        const w = try h.Workspace.init(&.{.{ .name = "u.f90", .text = try repeated(a, n, "subroutine s{d}()\n", "") }}, .{});
        defer w.deinit();
        const found = try w.diagnostics("u.f90");
        const seen = try a.alloc(bool, n);
        @memset(seen, false);
        for (found) |d| seen[@intCast(d.line)] = true;
        for (seen, 0..) |s, i| if (!s) std.debug.print("MISSING n={d} line={d}\n", .{ n, i });
        try h.expect(found.len == n, "{d} lines: {d} diagnostics", .{ n, found.len });
    }
}
