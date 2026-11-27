//! The client asked to ask again for what it shows, after a change it did
//! not make in the document it shows (#980), and the progress of indexing
//! under new settings.

const std = @import("std");
const h = @import("harness.zig");

const files = [_]h.File{
    .{ .name = "m.f90", .text = "module m\n  implicit none\n  integer, parameter :: n = 3\nend module m\n" },
    .{ .name = "p.f90", .text = "program p\n  use m\n  implicit none\n  print *, n\nend program p\n" },
};

const refreshes = [_][]const u8{ "workspace/semanticTokens/refresh", "workspace/inlayHint/refresh", "workspace/codeLens/refresh" };

fn count(w: *h.Workspace, method: []const u8) !usize {
    return (try w.sentWith(method)).len;
}

test "a saved change of a module refreshes the views of the documents (#980)" {
    const w = try h.Workspace.init(&files, .{ .refresh_support = true });
    defer w.deinit();
    try w.open("p.f90", "fortran");
    for (refreshes) |r| try h.expect(try count(w, r) == 0, "{s} before any change", .{r});
    try w.replaceText("m.f90", "module m\n  implicit none\n  integer, parameter :: n = 4\nend module m\n");
    for (refreshes) |r| try h.expect(try count(w, r) == 1, "{d} of {s} after the save", .{ try count(w, r), r });
}

test "no refresh for a client that does not take it (#980)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("p.f90", "fortran");
    try w.replaceText("m.f90", "module m\n  implicit none\n  integer, parameter :: n = 4\nend module m\n");
    for (refreshes) |r| try h.expect(try count(w, r) == 0, "{s} sent", .{r});
    try w.changeConfiguration("{\"source_dirs\": [\".\"]}");
    try h.expect(try count(w, "window/workDoneProgress/create") == 0, "a progress token made", .{});
}

test "indexing again under new settings shows its progress (#980)" {
    const w = try h.Workspace.init(&files, .{ .refresh_support = true });
    defer w.deinit();
    try w.changeConfiguration("{\"source_dirs\": [\".\"]}");
    const made = try w.sentWith("window/workDoneProgress/create");
    try h.expect(made.len == 1, "{d} progress tokens made", .{made.len});
    try h.expect(std.mem.find(u8, made[0], "zfls-indexing-1") != null, "the token: {s}", .{made[0]});
    var begun = false;
    for (try w.sentWith("$/progress")) |m| begun = begun or (std.mem.find(u8, m, "zfls-indexing-1") != null and std.mem.find(u8, m, "\"begin\"") != null);
    try h.expect(begun, "no progress begun on the token", .{});
    for (refreshes) |r| try h.expect(try count(w, r) >= 1, "no {s} after indexing again", .{r});
}
