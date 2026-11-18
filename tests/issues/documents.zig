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

/// `didChange` of `name` to `text` (the whole document)
fn change(w: *h.Workspace, name: []const u8, text: []const u8) !void {
    const a = w.arena.allocator();
    _ = try w.server.dispatchPublic(a, "textDocument/didChange", try json.from(a, .{
        .textDocument = .{ .uri = try w.uri(name) },
        .contentChanges = &[_]struct { text: []const u8 }{.{ .text = text }},
    }));
}

/// How often the diagnostics of `name` were published
fn publications(w: *h.Workspace, name: []const u8) usize {
    var n: usize = 0;
    for (w.sent.items) |msg| {
        if (std.mem.find(u8, msg, "publishDiagnostics") != null and std.mem.find(u8, msg, name) != null) n += 1;
    }
    return n;
}

/// What the server's loop does when the delay of a change is over
fn pause(w: *h.Workspace) void {
    w.server.publishPendingDiagnostics(w.arena.allocator(), null);
}

fn undeclared(comptime name: []const u8) []const u8 {
    return "Name \\\"" ++ name ++ "\\\" is not declared";
}

const uses_j = "program p\n  implicit none\n  integer :: i\n  i = j + 1\nend program p\n";
const declares_j = "program p\n  implicit none\n  integer :: i, j\n  j = 1\n  i = j + 1\nend program p\n";
const uses_k = "program p\n  implicit none\n  integer :: i, j\n  j = 1\n  i = j + k\nend program p\n";

test "zfls's diagnostics follow the changes of a document, after a pause (#261)" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = uses_j }}, .{});
    defer w.deinit();
    try w.open("p.f90", "fortran");
    try std.testing.expectEqual(@as(usize, 1), publications(w, "p.f90"));
    try std.testing.expect(std.mem.find(u8, lastPublished(w, "p.f90").?, undeclared("j")) != null);
    try std.testing.expectEqual(@as(?i96, null), w.server.nextDiagnosticsTime());

    // the problem is fixed: nothing in the notification, an empty list after
    try change(w, "p.f90", declares_j);
    try std.testing.expectEqual(@as(usize, 1), publications(w, "p.f90"));
    try std.testing.expect(w.server.nextDiagnosticsTime() != null);
    pause(w);
    try std.testing.expectEqual(@as(usize, 2), publications(w, "p.f90"));
    try std.testing.expect(std.mem.find(u8, lastPublished(w, "p.f90").?, "\"diagnostics\":[]") != null);
    try std.testing.expectEqual(@as(?i96, null), w.server.nextDiagnosticsTime());

    // a new problem appears
    try change(w, "p.f90", uses_k);
    pause(w);
    try std.testing.expectEqual(@as(usize, 3), publications(w, "p.f90"));
    try std.testing.expect(std.mem.find(u8, lastPublished(w, "p.f90").?, undeclared("k")) != null);

    // nothing is due before the delay is over
    try change(w, "p.f90", declares_j);
    w.server.publishPendingDiagnostics(w.arena.allocator(), w.server.nextDiagnosticsTime().? - 1);
    try std.testing.expectEqual(@as(usize, 3), publications(w, "p.f90"));
    // a save publishes, and then nothing waits
    try w.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p.f90", .data = declares_j });
    try w.save("p.f90");
    try std.testing.expectEqual(@as(usize, 4), publications(w, "p.f90"));
    try std.testing.expectEqual(@as(?i96, null), w.server.nextDiagnosticsTime());
    pause(w);
    try std.testing.expectEqual(@as(usize, 4), publications(w, "p.f90"));
}

test "a burst of changes gives one publication, of the last text (#261)" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = uses_j }}, .{});
    defer w.deinit();
    try w.open("p.f90", "fortran");
    for (0..10) |i| try change(w, "p.f90", if (i == 9) uses_k else if (i % 2 == 0) declares_j else uses_j);
    try std.testing.expectEqual(@as(usize, 1), publications(w, "p.f90"));
    pause(w);
    try std.testing.expectEqual(@as(usize, 2), publications(w, "p.f90"));
    const last = lastPublished(w, "p.f90").?;
    try std.testing.expect(std.mem.find(u8, last, undeclared("k")) != null);
    try std.testing.expect(std.mem.find(u8, last, undeclared("j")) == null);
    // closed before the pause is over: nothing more of it
    try change(w, "p.f90", uses_j);
    try close(w, "p.f90");
    try std.testing.expectEqual(@as(?i96, null), w.server.nextDiagnosticsTime());
}

test "diagnostics_change_delay: 0 publishes with each change, a negative one only on open and save (#261)" {
    {
        const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = uses_j }}, .{ .settings = .{ .diagnostics_change_delay = 0 } });
        defer w.deinit();
        try w.open("p.f90", "fortran");
        try change(w, "p.f90", uses_k);
        try std.testing.expectEqual(@as(usize, 2), publications(w, "p.f90"));
        try std.testing.expect(std.mem.find(u8, lastPublished(w, "p.f90").?, undeclared("k")) != null);
    }
    {
        const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = uses_j }}, .{ .settings = .{ .diagnostics_change_delay = -1 } });
        defer w.deinit();
        try w.open("p.f90", "fortran");
        try change(w, "p.f90", uses_k);
        try std.testing.expectEqual(@as(?i96, null), w.server.nextDiagnosticsTime());
        try std.testing.expectEqual(@as(usize, 1), publications(w, "p.f90"));
    }
}

test "nothing of a change is published after shutdown (#261)" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = uses_j }}, .{});
    defer w.deinit();
    try w.open("p.f90", "fortran");
    try change(w, "p.f90", declares_j);
    try std.testing.expect(w.server.nextDiagnosticsTime() != null);
    const a = w.arena.allocator();
    _ = try w.server.dispatchPublic(a, "shutdown", .null);
    // what waited is dropped: the loop does not wake up for it
    try std.testing.expectEqual(@as(?i96, null), w.server.nextDiagnosticsTime());
    pause(w);
    try std.testing.expectEqual(@as(usize, 1), publications(w, "p.f90"));
    // and a change now does not wait either
    try change(w, "p.f90", uses_k);
    try std.testing.expectEqual(@as(?i96, null), w.server.nextDiagnosticsTime());
    pause(w);
    try std.testing.expectEqual(@as(usize, 1), publications(w, "p.f90"));
}
