//! Code lenses (#218): the number of references above modules, procedures
//! and derived types, counted on resolve, and Run and Debug above a
//! program for a client that has those commands.

const std = @import("std");
const h = @import("harness.zig");
const json = h.json;
const Value = json.Value;

const files = [_]h.File{
    .{ .name = "geometry.f90", .text =
    \\module geometry
    \\  implicit none
    \\  type :: point
    \\    real :: x, y
    \\  end type point
    \\  interface
    \\    subroutine external_one(n)
    \\      integer, intent(in) :: n
    \\    end subroutine external_one
    \\  end interface
    \\contains
    \\  subroutine move(p, dx)
    \\    type(point), intent(inout) :: p
    \\    real, intent(in) :: dx
    \\    p%x = p%x + dx
    \\  end subroutine move
    \\  real function norm(p)
    \\    type(point), intent(in) :: p
    \\    norm = sqrt(p%x**2 + p%y**2)
    \\  end function norm
    \\end module geometry
    \\
    },
    .{ .name = "main.f90", .text =
    \\program main
    \\  use geometry
    \\  implicit none
    \\  type(point) :: q
    \\  call move(q, 1.0)
    \\  call move(q, 2.0)
    \\  print *, norm(q)
    \\end program main
    \\
    },
};

const all_commands = [_][]const u8{ "zfls.showReferences", "zfls.runFile", "zfls.debugFile" };

fn lenses(w: *h.Workspace, a: std.mem.Allocator, name: []const u8) ![]Value {
    return json.items(try w.server.dispatchPublic(a, "textDocument/codeLens", try json.from(a, .{ .textDocument = .{ .uri = try w.uri(name) } })));
}

fn resolve(w: *h.Workspace, a: std.mem.Allocator, lens: Value) !Value {
    return w.server.dispatchPublic(a, "codeLens/resolve", try json.parse(a, try json.stringify(a, lens)));
}

fn lineOf(lens: Value) i64 {
    return json.int(json.path(lens, &.{ "range", "start", "line" })) orelse -1;
}

fn charOf(lens: Value) i64 {
    return json.int(json.path(lens, &.{ "range", "start", "character" })) orelse -1;
}

fn title(lens: Value) []const u8 {
    return json.str(json.path(lens, &.{ "command", "title" })) orelse "";
}

/// What textDocument/references gives at a lens, but for the lines of the
/// unit's own statement and end statement in its file
fn referenceCount(w: *h.Workspace, name: []const u8, lens: Value, end_line: i64) !usize {
    var n: usize = 0;
    const own = try w.uri(name);
    for (try w.references(name, .{ .line = lineOf(lens), .col = charOf(lens) })) |r| {
        if (std.mem.eql(u8, r.uri, own) and (r.line == lineOf(lens) or r.line == end_line)) continue;
        n += 1;
    }
    return n;
}

test "reference lenses above modules, procedures and types, counted on resolve as references counts (#218)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .client_commands = &all_commands });
    defer w.deinit();
    try std.testing.expectEqual(true, json.path(w.init_result, &.{ "capabilities", "codeLensProvider", "resolveProvider" }).?.bool);
    const got = try lenses(w, a, "geometry.f90");
    // module geometry, type point, move and norm: not the procedure of the
    // interface block. norm has no RESULT, so its result variable's
    // assignment is one of its references too (#228).
    const want = [_]struct { line: i64, char: i64, end: i64, count: usize }{
        .{ .line = 0, .char = 7, .end = 20, .count = 1 },
        .{ .line = 2, .char = 10, .end = 4, .count = 3 },
        .{ .line = 11, .char = 13, .end = 15, .count = 2 },
        .{ .line = 16, .char = 16, .end = 19, .count = 2 },
    };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |wl, lens| {
        try std.testing.expectEqual(wl.line, lineOf(lens));
        try std.testing.expectEqual(wl.char, charOf(lens));
        // unresolved: counted only when resolved
        try std.testing.expect(json.get(lens, "command") == null);
        const resolved = try resolve(w, a, lens);
        const count = try referenceCount(w, "geometry.f90", lens, wl.end);
        try std.testing.expectEqual(wl.count, count);
        const t = if (count == 1) "1 reference" else try a.print("{d} references", .{count});
        try std.testing.expectEqualStrings(t, title(resolved));
        try std.testing.expectEqualStrings("zfls.showReferences", json.str(json.path(resolved, &.{ "command", "command" })).?);
        const args = json.items(json.path(resolved, &.{ "command", "arguments" }));
        try std.testing.expectEqual(3, args.len);
        try std.testing.expectEqualStrings(try w.uri("geometry.f90"), json.str(args[0]).?);
        try std.testing.expectEqual(lineOf(lens), json.int(json.get(args[1], "line")).?);
        try std.testing.expectEqual(count, json.items(args[2]).len);
    }
}

test "Run and Debug above a program, for a client that has the commands (#218)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .client_commands = &all_commands });
    defer w.deinit();
    const got = try lenses(w, a, "main.f90");
    try std.testing.expectEqual(2, got.len);
    const names = [_][]const u8{ "Run", "Debug" };
    const commands = [_][]const u8{ "zfls.runFile", "zfls.debugFile" };
    for (got, names, commands) |lens, n, c| {
        try std.testing.expectEqual(0, lineOf(lens));
        try std.testing.expectEqual(8, charOf(lens));
        try std.testing.expectEqualStrings(n, title(lens));
        try std.testing.expectEqualStrings(c, json.str(json.path(lens, &.{ "command", "command" })).?);
        const args = json.items(json.path(lens, &.{ "command", "arguments" }));
        try std.testing.expectEqual(1, args.len);
        try std.testing.expectEqualStrings(try w.uri("main.f90"), json.str(args[0]).?);
    }
}

test "without the client's commands, reference lenses run the server's and a program has none (#218, #984)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const commands = json.items(json.path(w.init_result, &.{ "capabilities", "executeCommandProvider", "commands" }));
    try std.testing.expectEqual(1, commands.len);
    try std.testing.expectEqualStrings("zfls.server.showReferences", json.str(commands[0]).?);
    try std.testing.expectEqual(0, (try lenses(w, a, "main.f90")).len);
    const got = try lenses(w, a, "geometry.f90");
    try std.testing.expectEqual(4, got.len);
    const resolved = try resolve(w, a, got[2]);
    try std.testing.expectEqualStrings("2 references", title(resolved));
    try std.testing.expectEqualStrings("zfls.server.showReferences", json.str(json.path(resolved, &.{ "command", "command" })).?);
    try std.testing.expectEqual(3, json.items(json.path(resolved, &.{ "command", "arguments" })).len);
}

test "the server's lens command answers the references and shows the first (#984)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .show_document = true });
    defer w.deinit();
    const resolved = try resolve(w, a, (try lenses(w, a, "geometry.f90"))[2]);
    const command = json.get(resolved, "command").?;
    const answer = try w.server.dispatchPublic(a, "workspace/executeCommand", try json.parse(a, try json.stringify(a, command)));
    try std.testing.expectEqual(2, json.items(answer).len);
    const shown = try w.sentWith("window/showDocument");
    try std.testing.expectEqual(1, shown.len);
    // a client that has its own: no command of the server's
    const own = try h.Workspace.init(&files, .{ .client_commands = &all_commands });
    defer own.deinit();
    const provider = json.path(own.init_result, &.{ "capabilities", "executeCommandProvider" });
    try std.testing.expect(provider == null or provider.? == .null);
}

test "code_lens_no_references and code_lens_no_run turn each kind off (#218)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .client_commands = &all_commands, .settings = .{ .code_lens_no_references = true } });
    defer w.deinit();
    try std.testing.expectEqual(0, (try lenses(w, a, "geometry.f90")).len);
    try std.testing.expectEqual(2, (try lenses(w, a, "main.f90")).len);
    // and live, from the editor's settings
    try w.changeConfiguration("{\"code_lens_no_references\": false, \"code_lens_no_run\": true}");
    try std.testing.expectEqual(4, (try lenses(w, a, "geometry.f90")).len);
    try std.testing.expectEqual(0, (try lenses(w, a, "main.f90")).len);
}
