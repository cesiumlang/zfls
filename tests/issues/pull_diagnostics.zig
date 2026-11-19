//! Pull diagnostics (#223): a client that asks for diagnostics
//! (`textDocument/diagnostic`, `workspace/diagnostic`) gets zfls's in the
//! answers, and none published.

const std = @import("std");
const h = @import("harness.zig");
const json = h.json;
const Value = json.Value;

const files = [_]h.File{
    .{ .name = "shapes.f90", .text =
    \\module shapes_v1
    \\  implicit none
    \\contains
    \\  subroutine draw()
    \\  end subroutine draw
    \\end module shapes_v1
    \\
    },
    .{ .name = "main.f90", .text =
    \\program main
    \\  use shapes_v2
    \\  implicit none
    \\  integer :: unused_one
    \\  call draw()
    \\  total = 1
    \\end program main
    \\
    },
};

const published = "textDocument/publishDiagnostics";

fn open(w: *h.Workspace, name: []const u8) !void {
    try w.open(name, "fortran");
}

/// `textDocument/diagnostic` of a file, after the report `previous`
fn pull(w: *h.Workspace, a: std.mem.Allocator, name: []const u8, previous: ?[]const u8) !Value {
    return w.server.dispatchPublic(a, "textDocument/diagnostic", try json.from(a, .{
        .textDocument = .{ .uri = try w.uri(name) },
        .previousResultId = previous,
    }));
}

fn kind(report: Value) []const u8 {
    return json.str(json.get(report, "kind")) orelse "";
}

fn resultId(report: Value) []const u8 {
    return json.str(json.get(report, "resultId")) orelse "";
}

/// Whether a message of `items` contains `text`
fn mentions(items: []const Value, text: []const u8) bool {
    for (items) |d| if (std.mem.find(u8, json.str(json.get(d, "message")) orelse "", text) != null) return true;
    return false;
}

/// The diagnostics last published of a file, as JSON
fn lastPublished(w: *h.Workspace, a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const uri = try w.uri(name);
    const sent = try w.sentWith(published);
    var i = sent.len;
    while (i > 0) {
        i -= 1;
        const msg = try json.parse(a, sent[i]);
        if (std.mem.eql(u8, json.str(json.path(msg, &.{ "params", "uri" })) orelse "", uri)) {
            return json.stringify(a, json.path(msg, &.{ "params", "diagnostics" }).?);
        }
    }
    return error.NothingPublished;
}

test "a client that pulls diagnostics is told so at initialize, workspace diagnostics as the setting says (#223)" {
    {
        const w = try h.Workspace.init(&files, .{});
        defer w.deinit();
        try std.testing.expect(json.path(w.init_result, &.{ "capabilities", "diagnosticProvider" }) == null);
    }
    inline for (.{ false, true }) |whole| {
        const w = try h.Workspace.init(&files, .{ .pull_diagnostics = true, .settings = .{ .workspace_diagnostics = whole } });
        defer w.deinit();
        const p = json.path(w.init_result, &.{ "capabilities", "diagnosticProvider" }) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(true, json.get(p, "interFileDependencies").?.bool);
        try std.testing.expectEqual(whole, json.get(p, "workspaceDiagnostics").?.bool);
    }
}

test "the pulled report is what is published to a client that does not pull, which is not published (#223)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pushed = try h.Workspace.init(&files, .{});
    defer pushed.deinit();
    try open(pushed, "main.f90");
    const want = try lastPublished(pushed, a, "main.f90");
    // module not found, an undeclared name, an unused one
    try std.testing.expect((try json.parse(a, want)).array.items.len >= 2);

    const w = try h.Workspace.init(&files, .{ .pull_diagnostics = true });
    defer w.deinit();
    try open(w, "main.f90");
    try w.save("main.f90");
    // a change too, which would publish them after the delay
    try w.replaceText("main.f90", w.text("main.f90"));
    w.server.publishPendingDiagnostics(a, null);
    const report = try pull(w, a, "main.f90", null);
    try std.testing.expectEqualStrings("full", kind(report));
    try std.testing.expectEqualStrings(want, try json.stringify(a, json.get(report, "items").?));
    try std.testing.expectEqual(0, (try w.sentWith(published)).len);
}

test "a report is unchanged until what the file depends on changes (#223)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try h.Workspace.init(&files, .{ .pull_diagnostics = true });
    defer w.deinit();
    try open(w, "main.f90");
    const first = try pull(w, a, "main.f90", null);
    const id = resultId(first);
    const again = try pull(w, a, "main.f90", id);
    try std.testing.expectEqualStrings("unchanged", kind(again));
    try std.testing.expectEqualStrings(id, resultId(again));
    try std.testing.expect(json.get(again, "items") == null);
    // an edit of another file that changes nothing of main.f90's
    try w.replaceText("shapes.f90", try std.mem.concat(a, u8, &.{ "! shapes\n", w.text("shapes.f90") }));
    try std.testing.expectEqualStrings("unchanged", kind(try pull(w, a, "main.f90", id)));
    // the module main.f90 uses appears
    const renamed = try std.mem.replaceOwned(u8, a, w.text("shapes.f90"), "shapes_v1", "shapes_v2");
    try w.replaceText("shapes.f90", renamed);
    const after = try pull(w, a, "main.f90", id);
    try std.testing.expectEqualStrings("full", kind(after));
    try std.testing.expect(!std.mem.eql(u8, id, resultId(after)));
    const before_items = json.items(json.get(first, "items"));
    const after_items = json.items(json.get(after, "items"));
    try std.testing.expect(mentions(before_items, "shapes_v2"));
    try std.testing.expect(!mentions(after_items, "shapes_v2"));
    // and its names are checked now that it is known
    try std.testing.expect(mentions(after_items, "\"total\""));
}

test "workspace/diagnostic reports every file with workspace_diagnostics, unchanged ones by their id (#223)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try h.Workspace.init(&files, .{ .pull_diagnostics = true });
        defer w.deinit();
        const r = try w.server.dispatchPublic(a, "workspace/diagnostic", try json.from(a, .{ .previousResultIds = &[_]struct { uri: []const u8, value: []const u8 }{} }));
        try std.testing.expectEqual(0, json.items(json.get(r, "items")).len);
    }
    const w = try h.Workspace.init(&files, .{ .pull_diagnostics = true, .settings = .{ .workspace_diagnostics = true } });
    defer w.deinit();
    const Prev = struct { uri: []const u8, value: []const u8 };
    const r = try w.server.dispatchPublic(a, "workspace/diagnostic", try json.from(a, .{ .previousResultIds = &[_]Prev{} }));
    const items = json.items(json.get(r, "items"));
    try std.testing.expectEqual(2, items.len);
    var prev: std.ArrayList(Prev) = .empty;
    for (items) |it| {
        try std.testing.expectEqualStrings("full", kind(it));
        try std.testing.expect(json.get(it, "version").? == .null);
        try prev.append(a, .{ .uri = json.str(json.get(it, "uri")).?, .value = resultId(it) });
    }
    const r2 = try w.server.dispatchPublic(a, "workspace/diagnostic", try json.from(a, .{ .previousResultIds = prev.items }));
    for (json.items(json.get(r2, "items"))) |it| try std.testing.expectEqualStrings("unchanged", kind(it));
    try std.testing.expectEqual(0, (try w.sentWith(published)).len);
}

test "a change of the settings asks a pulling client to pull again (#223)" {
    const w = try h.Workspace.init(&files, .{ .pull_diagnostics = true });
    defer w.deinit();
    try open(w, "main.f90");
    try w.changeConfiguration("{\"max_line_length\": 10}");
    try std.testing.expectEqual(1, (try w.sentWith("workspace/diagnostic/refresh")).len);
    try std.testing.expectEqual(0, (try w.sentWith(published)).len);
}
