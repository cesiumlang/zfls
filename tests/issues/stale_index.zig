//! What the index keeps of files that change outside the usual way: a
//! document opened before its file exists (#957), a closed untitled
//! document (#958), a deleted or created folder (#959).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const json = h.json;

const io = std.testing.io;
const main_text = "program p\n  use newmod\n  implicit none\n  print *, nval\nend program p\n";
const mod_text = "module newmod\n  implicit none\n  integer :: nval = 1\nend module newmod\n";

/// `uri` as VS Code writes a Windows one, with a lowercase drive letter
fn editorUri(w: *h.Workspace, name: []const u8) ![]const u8 {
    const u = try w.a().dupe(u8, try w.uri(name));
    if (builtin.target.os.tag == .windows) if (std.mem.findScalar(u8, u, ':')) |i| if (std.mem.findScalarPos(u8, u, i + 1, ':')) |d| {
        u[d - 1] = std.ascii.toLower(u[d - 1]);
    };
    return u;
}

test "a document opened before its file exists is indexed once when saved (#957)" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = main_text }}, .{});
    defer w.deinit();
    const uri = try editorUri(w, "newmod.f90");
    _ = try w.server.dispatchPublic(w.a(), "textDocument/didOpen", try json.from(w.a(), .{ .textDocument = .{ .uri = uri, .languageId = "fortran", .version = 1, .text = mod_text } }));
    try w.tmp.dir.writeFile(io, .{ .sub_path = "newmod.f90", .data = mod_text });
    _ = try w.server.dispatchPublic(w.a(), "textDocument/didSave", try json.from(w.a(), .{ .textDocument = .{ .uri = uri } }));
    _ = try w.server.dispatchPublic(w.a(), "workspace/didChangeWatchedFiles", try json.from(w.a(), .{
        .changes = &[_]struct { uri: []const u8, type: i64 }{.{ .uri = try w.uri("newmod.f90"), .type = 1 }},
    }));
    try std.testing.expectEqual(@as(usize, 1), (try w.workspaceSymbols("newmod")).len);
}

test "a closed untitled document leaves the index (#958)" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text = main_text }}, .{});
    defer w.deinit();
    const doc = .{ .uri = "untitled:Untitled-1", .languageId = "fortran", .version = 1, .text = mod_text };
    _ = try w.server.dispatchPublic(w.a(), "textDocument/didOpen", try json.from(w.a(), .{ .textDocument = doc }));
    try std.testing.expectEqual(@as(usize, 1), (try w.workspaceSymbols("newmod")).len);
    _ = try w.server.dispatchPublic(w.a(), "textDocument/didClose", try json.from(w.a(), .{ .textDocument = .{ .uri = doc.uri } }));
    try std.testing.expectEqual(@as(usize, 0), (try w.workspaceSymbols("newmod")).len);
    // and comes back when opened again
    _ = try w.server.dispatchPublic(w.a(), "textDocument/didOpen", try json.from(w.a(), .{ .textDocument = doc }));
    try std.testing.expectEqual(@as(usize, 1), (try w.workspaceSymbols("newmod")).len);
}

fn folderEvent(w: *h.Workspace, name: []const u8, kind: i64) !void {
    _ = try w.server.dispatchPublic(w.a(), "workspace/didChangeWatchedFiles", try json.from(w.a(), .{
        .changes = &[_]struct { uri: []const u8, type: i64 }{.{ .uri = try w.uri(name), .type = kind }},
    }));
}

test "a deleted folder's files leave the index, a created folder's join it (#959)" {
    const w = try h.Workspace.init(&.{ .{ .name = "p.f90", .text = main_text }, .{ .name = "lib/newmod.f90", .text = mod_text } }, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try w.workspaceSymbols("newmod")).len);
    try w.tmp.dir.rename("lib", w.tmp.dir, "moved", io);
    try folderEvent(w, "lib", 3);
    try std.testing.expectEqual(@as(usize, 0), (try w.workspaceSymbols("newmod")).len);
    try folderEvent(w, "moved", 1);
    try std.testing.expectEqual(@as(usize, 1), (try w.workspaceSymbols("newmod")).len);
}
