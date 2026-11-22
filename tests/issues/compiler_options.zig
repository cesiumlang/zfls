//! The compiler check's settings no other test sets (#741):
//! `compiler_no_save`, `compiler_fypp` and `compiler_fypp_args`, with
//! stand-ins for gfortran and fypp that log their arguments and fail.

const std = @import("std");
const h = @import("harness.zig");
const tools = @import("tools.zig");

const gfortran = tools.logging("gfortran", "a.f90:2:3: Error: said by the stand-in gfortran", true);
const fypp = tools.logging("fypp", "a.fypp:2: error: said by the stand-in fypp", true);

const a_f90 = h.File{ .name = "a.f90", .text = "program a\n  x = 1\nend program a\n" };
const b_f90 = h.File{ .name = "b.f90", .text = "program b\n  y = 1\nend program b\n" };
const a_fypp = h.File{ .name = "a.fypp", .text = "program a\n#:set n = 1\n  x = ${n}$\nend program a\n" };

fn start(comptime options: []const u8) !*h.Workspace {
    const w = try h.Workspace.init(&.{ a_f90, b_f90, a_fypp, gfortran, fypp }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\"" ++ options ++ "}" });
    errdefer w.deinit();
    try tools.makeExecutable(w, &.{ gfortran, fypp });
    return w;
}

/// The checks of a.f90 once it was opened and saved, and b.f90 opened
/// after the save was checked
fn checksAfterSave(comptime options: []const u8) !usize {
    const w = try start(options);
    defer w.deinit();
    try w.open("a.f90", "fortran");
    _ = try tools.waitForRuns(w, "gfortran", "a.f90", 1, 60);
    try w.save("a.f90");
    try w.open("b.f90", "fortran");
    if ((try tools.waitForRuns(w, "gfortran", "b.f90", 1, 60)).len == 0) return error.NotChecked;
    return (try tools.runs(w, "gfortran", "a.f90")).len;
}

test "compiler_no_save: saving a file does not check it again (#741)" {
    try std.testing.expectEqual(@as(usize, 2), try checksAfterSave(""));
    try std.testing.expectEqual(@as(usize, 1), try checksAfterSave(", \"compiler_no_save\": true"));
}

test "compiler_fypp runs fypp with compiler_fypp_args on a .fypp file, and reports its error (#741)" {
    const w = try start(", \"compiler_fypp\": \"./" ++ fypp.name ++ "\", \"compiler_fypp_args\": [\"-DFROM_ARGS=1\"]");
    defer w.deinit();
    try w.open("a.fypp", "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "said by the stand-in fypp", 60)) orelse return error.NoFyppDiagnostics;
    try std.testing.expect(std.mem.find(u8, sent, "\"source\":\"fypp\"") != null);
    const got = try tools.runs(w, "fypp", "a.fypp");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try tools.expectIn(got[0], "--line-numbering --line-marker-format=cpp -DFROM_ARGS=1 ");
}

test "without compiler_fypp a .fypp file is not checked (#741)" {
    const w = try start("");
    defer w.deinit();
    try w.open("a.fypp", "fortran");
    // b's check comes after one of a.fypp
    try w.open("b.f90", "fortran");
    if ((try tools.waitForRuns(w, "gfortran", "b.f90", 1, 60)).len == 0) return error.NotChecked;
    try std.testing.expectEqual(@as(usize, 0), (try tools.runs(w, "gfortran", "a.fypp")).len);
    try std.testing.expectEqual(@as(usize, 0), (try tools.runs(w, "fypp", "")).len);
}
