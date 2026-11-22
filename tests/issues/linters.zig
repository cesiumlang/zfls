//! The linters' settings (#741): `fortitude`, `fortitude_path`,
//! `fortitude_args`, `fortitude_on_change`, `fortitude_change_delay` and
//! `codee_args`, with stand-ins for fortitude and Codee that log their
//! arguments and report one problem each.

const std = @import("std");
const h = @import("harness.zig");
const tools = @import("tools.zig");

const fortitude = tools.logging("fortitude", "[{\"code\":\"S001\",\"message\":\"said by the stand-in fortitude\",\"location\":{\"row\":2,\"column\":3},\"end_location\":{\"row\":2,\"column\":8}}]", false);
const codee = tools.logging("codee", "{\"Checks\":[{\"Check\":\"PWR001\",\"Location\":\"a.f90:2:3\",\"Title\":\"said by the stand-in codee\"}]}", false);

const a_f90 = h.File{ .name = "a.f90", .text = "program a\n  x = 1\nend program a\n" };
const b_f90 = h.File{ .name = "b.f90", .text = "program b\n  y = 1\nend program b\n" };

/// The tools' paths, relative to the root
const paths = "\"fortitude_path\": \"./" ++ fortitude.name ++ "\", \"codee_path\": \"./" ++ codee.name ++ "\"";

fn start(comptime options: []const u8) !*h.Workspace {
    const w = try h.Workspace.init(&.{ a_f90, b_f90, fortitude, codee }, .{ .init_options = "{" ++ paths ++ ", " ++ options ++ "}" });
    errdefer w.deinit();
    try tools.makeExecutable(w, &.{ fortitude, codee });
    return w;
}

test "fortitude lints an opened file with fortitude_path's fortitude, fortitude_args before the file (#741)" {
    const w = try start("\"fortitude\": true, \"fortitude_args\": [\"--line-length=99\"]");
    defer w.deinit();
    try w.open("a.f90", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "said by the stand-in fortitude", 60)) orelse return error.NotLinted;
    const got = try tools.runs(w, "fortitude", "a.f90");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try tools.expectIn(got[0], "check --output-format json --line-length=99 --stdin-filename ");
}

test "fortitude off: Codee lints, with codee_args, and fortitude does not (#741)" {
    const w = try start("\"fortitude\": false, \"codee\": true, \"codee_args\": [\"--target-arch\", \"x86_64\"]");
    defer w.deinit();
    try w.open("a.f90", "fortran");
    _ = (try w.waitForSent("textDocument/publishDiagnostics", "said by the stand-in codee", 60)) orelse return error.NotLinted;
    const got = try tools.runs(w, "codee", "a.f90");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try tools.expectIn(got[0], "checks --json --target-arch x86_64 ");
    // fortitude's run would have come first
    try std.testing.expectEqual(@as(usize, 0), (try tools.runs(w, "fortitude", "")).len);
}

/// fortitude's runs on a.f90 once it was opened and edited, and b.f90
/// opened after the edit was linted
fn runsAfterEdit(comptime options: []const u8) !usize {
    const w = try start("\"fortitude\": true, " ++ options);
    defer w.deinit();
    try w.open("a.f90", "fortran");
    _ = try tools.waitForRuns(w, "fortitude", "a.f90", 1, 60);
    _ = try w.request("textDocument/didChange", .{
        .textDocument = .{ .uri = try w.uri("a.f90"), .version = 2 },
        .contentChanges = &[_]struct { text: []const u8 }{.{ .text = "program a\n  x = 2\nend program a\n" }},
    });
    // b's run comes after a due run of the edit
    try w.open("b.f90", "fortran");
    if ((try tools.waitForRuns(w, "fortitude", "b.f90", 1, 60)).len == 0) return error.NotLinted;
    return (try tools.runs(w, "fortitude", "a.f90")).len;
}

test "fortitude_on_change lints the unsaved text of an edit (#741)" {
    try std.testing.expectEqual(@as(usize, 2), try runsAfterEdit("\"fortitude_on_change\": true, \"fortitude_change_delay\": 0"));
    try std.testing.expectEqual(@as(usize, 1), try runsAfterEdit("\"fortitude_on_change\": false, \"fortitude_change_delay\": 0"));
}

test "fortitude_change_delay holds the lint of an edit back (#741)" {
    try std.testing.expectEqual(@as(usize, 1), try runsAfterEdit("\"fortitude_on_change\": true, \"fortitude_change_delay\": 600000"));
}
