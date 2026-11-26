//! The conditions of `#if` that the compiler's preprocessor rejects (#658):
//! Intel's fpp has no `/=`, gfortran's cpp none of Fortran's operators;
//! LLVM Flang's takes both, as zfls does without a compiler.

const std = @import("std");
const sysinfo = @import("builtin");
const h = @import("harness.zig");

const is_windows = sysinfo.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in compiler that predefines nothing and reports nothing
fn standIn(comptime name: []const u8) h.File {
    return if (is_windows)
        .{ .name = name ++ ".cmd", .text = "@echo off\r\nexit /b 0\r\n" }
    else
        .{ .name = name ++ ".sh", .text = "#!/bin/sh\nexit 0\n" };
}

/// `p.F90` with condition `cond`, checked with compiler `compiler` (null:
/// none): whether the branch is taken, and the line and message of the
/// diagnostic about the condition
fn check(comptime compiler: ?[]const u8, comptime cond: []const u8) !struct { taken: bool, line: i64, message: []const u8 } {
    const text = "program p\n#if " ++ cond ++ "\n  integer :: taken\n#else\n  integer :: not_taken\n#endif\nend program p\n";
    const exe = comptime standIn(compiler orelse "none");
    const opts = comptime if (compiler) |c| "{\"compiler_diagnostics\": \"" ++ c ++ "\", \"compiler_path\": \"" ++ exe.name ++ "\"}" else "{}";
    const w = try h.Workspace.init(&.{ .{ .name = "p.F90", .text = text }, exe }, .{ .init_options = opts });
    defer w.deinit();
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, exe.name, .executable_file, .{});
    try w.open("p.F90", "fortran");
    const taken = (try w.hover("p.F90", w.pos("p.F90", "taken", 0, 0))) != null;
    const not_taken = (try w.hover("p.F90", w.pos("p.F90", "not_taken", 0, 0))) != null;
    try h.expect(taken != not_taken, "taken: {}, not_taken: {}", .{ taken, not_taken });
    for (try w.diagnostics("p.F90")) |d| if (std.mem.eql(u8, d.code, "preprocessor-condition")) {
        try h.expect(d.severity == 1, "severity {d}", .{d.severity});
        return .{ .taken = taken, .line = d.line, .message = try std.testing.allocator.dupe(u8, d.message) };
    };
    return .{ .taken = taken, .line = -1, .message = "" };
}

test "ifx: #if with /= is fpp's parse error, its branch taken (#658)" {
    // ifx 2026.2.0 /fpp: `p.F90(2): #error: #if: parse error.`, then the
    // first branch, also for `1 /= 1`
    const r = try check("ifx", "1 /= 1");
    defer std.testing.allocator.free(r.message);
    try h.expect(r.taken, "the #if branch is not taken", .{});
    try h.expect(r.line == 1, "diagnostic on line {d}", .{r.line});
    try std.testing.expectEqualStrings("#if: parse error.", r.message);
    // `.NE.` it takes
    const ne = try check("ifx", "1 .NE. 1");
    try h.expect(!ne.taken and ne.line == -1, "1 .NE. 1: taken {}, diagnostic on line {d}", .{ ne.taken, ne.line });
}

test "gfortran: #if with Fortran's operators is cpp's error, its branch not taken (#658)" {
    // gfortran 16.1 -cpp: `Error: token '/=' is not valid in preprocessor
    // expressions`, then the #else branch; `token '.'` for `.NE.`
    const r = try check("gfortran", "1 /= 2");
    defer std.testing.allocator.free(r.message);
    try h.expect(!r.taken, "the #if branch is taken", .{});
    try h.expect(r.line == 1, "diagnostic on line {d}", .{r.line});
    try std.testing.expectEqualStrings("token '/=' is not valid in preprocessor expressions", r.message);
    const ne = try check("gfortran", "1 .NE. 2");
    defer std.testing.allocator.free(ne.message);
    try h.expect(!ne.taken, "1 .NE. 2: the #if branch is taken", .{});
    try std.testing.expectEqualStrings("token '.' is not valid in preprocessor expressions", ne.message);
}

test "Flang and no compiler: #if takes /= (#658)" {
    // flang 23.1.5 -E: the first branch for `1 /= 2`, the second for `1 /= 1`
    for ([_]bool{ false, true }) |flang| {
        const r = if (flang) try check("flang", "1 /= 2") else try check(null, "1 /= 2");
        try h.expect(r.taken and r.line == -1, "flang {}: taken {}, diagnostic on line {d}", .{ flang, r.taken, r.line });
        const f = if (flang) try check("flang", "1 /= 1") else try check(null, "1 /= 1");
        try h.expect(!f.taken, "flang {}: 1 /= 1 taken", .{flang});
    }
}
