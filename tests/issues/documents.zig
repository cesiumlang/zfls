//! Document synchronization: what the server knows of a document between
//! `didOpen` and `didClose`.

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");
const json = zfls.json;

/// `didOpen` of `name` with `text`, which need not be the file's
fn openWith(w: *h.Workspace, name: []const u8, text: []const u8) !void {
    const a = w.arena.allocator();
    _ = try w.server.dispatchPublic(a, "textDocument/didOpen", try json.from(a, .{ .textDocument = .{
        .uri = try w.uri(name),
        .languageId = "FortranFreeForm",
        .version = 1,
        .text = text,
    } }));
}

fn close(w: *h.Workspace, name: []const u8) !void {
    const a = w.arena.allocator();
    _ = try w.server.dispatchPublic(a, "textDocument/didClose", try json.from(a, .{ .textDocument = .{ .uri = try w.uri(name) } }));
}

fn has(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn hasSymbol(w: *h.Workspace, name: []const u8) !bool {
    return has(try w.workspaceSymbols(name), name);
}

/// The last diagnostics published of `name` (the notification's JSON text)
fn lastPublished(w: *h.Workspace, name: []const u8) ?[]const u8 {
    var i = w.sent.items.len;
    while (i > 0) {
        i -= 1;
        const msg = w.sent.items[i];
        if (std.mem.find(u8, msg, "publishDiagnostics") != null and std.mem.find(u8, msg, name) != null) return msg;
    }
    return null;
}

const there =
    \\module there
    \\  implicit none
    \\  integer :: thing
    \\end module there
    \\
;

test "hansec #123 a document opened with a text that is not its file's is served from that text" {
    const w = try h.Workspace.init(&.{.{ .name = "exists.f90", .text = there }}, .{});
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        // unsaved changes that the editor restored
        try openWith(w, "exists.f90",
            \\module there
            \\  implicit none
            \\  integer :: buffer_var
            \\contains
            \\  subroutine s()
            \\    nope = 1
            \\  end subroutine s
            \\end module there
            \\
        );
        const syms = try w.documentSymbols("exists.f90");
        if (!has(syms, "s")) break :blk h.unmet("the outline is the file's, not the text's: {any}", .{syms});
        const hov = (try w.hover("exists.f90", .{ .line = 2, .col = 15 })) orelse break :blk h.unmet("no hover on buffer_var", .{});
        if (std.mem.find(u8, hov, "buffer_var") == null) break :blk h.unmet("hover answers for the file's text: {s}", .{hov});
        const published = lastPublished(w, "exists.f90") orelse break :blk h.unmet("no diagnostics published", .{});
        if (std.mem.find(u8, published, "nope") == null) break :blk h.unmet("the diagnostics are not the text's: {s}", .{published});
        // closed without a save: the file's text again
        try close(w, "exists.f90");
        if (!try hasSymbol(w, "thing") or try hasSymbol(w, "buffer_var")) break :blk h.unmet("after didClose the index is not the file's", .{});
        break :blk {};
    };
    try h.checkIn(.hansec, 123, .fixed, outcome);
}

test "hansec #123 a document whose file does not exist yet is served from the text of didOpen" {
    const w = try h.Workspace.init(&.{.{ .name = "there.f90", .text = there }}, .{});
    defer w.deinit();
    const fresh =
        \\program fresh
        \\  use there
        \\  implicit none
        \\  integer :: mine
        \\  mine = thing + nope
        \\end program fresh
        \\
    ;
    const outcome: anyerror!void = blk: {
        try openWith(w, "new_unsaved.f90", fresh);
        const syms = try w.documentSymbols("new_unsaved.f90");
        if (!has(syms, "fresh")) break :blk h.unmet("the outline is empty until the first change: {any}", .{syms});
        const mine = (try w.hover("new_unsaved.f90", .{ .line = 4, .col = 3 })) orelse break :blk h.unmet("no hover on mine", .{});
        if (std.mem.find(u8, mine, "mine") == null) break :blk h.unmet("hover on mine: {s}", .{mine});
        const thing = (try w.hover("new_unsaved.f90", .{ .line = 4, .col = 10 })) orelse break :blk h.unmet("no hover on thing", .{});
        if (std.mem.find(u8, thing, "thing") == null) break :blk h.unmet("hover on thing: {s}", .{thing});
        const published = lastPublished(w, "new_unsaved.f90") orelse break :blk h.unmet("no diagnostics published", .{});
        if (std.mem.find(u8, published, "nope") == null) break :blk h.unmet("the diagnostics are not the text's: {s}", .{published});
        // closed without ever being saved: it leaves the workspace
        try close(w, "new_unsaved.f90");
        if (try hasSymbol(w, "fresh")) break :blk h.unmet("after didClose the program is still in the workspace", .{});
        const cleared = lastPublished(w, "new_unsaved.f90").?;
        if (std.mem.find(u8, cleared, "\"diagnostics\":[]") == null) break :blk h.unmet("its diagnostics stay after didClose: {s}", .{cleared});
        // and comes back when it is opened again with the same text
        try openWith(w, "new_unsaved.f90", fresh);
        if (!try hasSymbol(w, "fresh")) break :blk h.unmet("opened again, the program is not in the workspace", .{});
        break :blk {};
    };
    try h.checkIn(.hansec, 123, .fixed, outcome);
}

test "a document opened with its file's text is not parsed again" {
    const w = try h.Workspace.init(&.{.{ .name = "exists.f90", .text = there }}, .{});
    defer w.deinit();
    const file = w.server.workspace.get(try w.path("exists.f90")).?;
    const indexed = file.ast.?;
    try openWith(w, "exists.f90", there);
    try std.testing.expect(file.ast.? == indexed);
    // nor is a didOpen without a text, which reads the file
    try close(w, "exists.f90");
    const a = w.arena.allocator();
    _ = try w.server.dispatchPublic(a, "textDocument/didOpen", try json.from(a, .{ .textDocument = .{ .uri = try w.uri("exists.f90") } }));
    try std.testing.expect(file.ast.? == indexed);
    try std.testing.expect(try hasSymbol(w, "thing"));
}
