//! The compiler check (`compiler_diagnostics`) runs a file with the
//! arguments of its command in compile_commands.json, so that it sees the
//! project's dialect options (#277). With gfortran; skipped where it is not
//! on the PATH.

const std = @import("std");
const h = @import("harness.zig");

/// A file whose `x` has no type with `-fimplicit-none`; `unused` makes
/// gfortran -Wall always say something, so that its diagnostics are known
/// to have come
fn implicitFile(name: []const u8) h.File {
    return .{ .name = name, .text =
    \\program p
    \\  integer :: unused
    \\  x = 1.0
    \\  print *, x
    \\end program p
    \\
    };
}

const database = h.File{ .name = "compile_commands.json", .text =
    \\[{"directory": ".", "file": "a.f90",
    \\  "arguments": ["gfortran", "-fimplicit-none", "-Wall", "-Jmod", "-c", "a.f90", "-o", "a.o", "-MD", "-MF", "a.d"]}]
    \\
};

/// Whether gfortran's diagnostics of `name` say that `x` has no implicit
/// type, null when gfortran is not on the PATH
fn untyped(files: []const h.File, name: []const u8, comptime options: []const u8) !?bool {
    const w = try h.Workspace.init(files, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\"" ++ options ++ "}" });
    defer w.deinit();
    try w.open(name, "fortran");
    var waited: usize = 0;
    while (waited < 600) : (waited += 1) {
        if (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"gfortran\"", 0)) |sent| return std.mem.find(u8, sent, "IMPLICIT type") != null;
        if (try w.waitForSent("window/showMessage", "was not found", 0) != null) return null;
        std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.NoCompilerDiagnostics;
}

fn expectUntyped(files: []const h.File, name: []const u8, comptime options: []const u8, want: bool) !void {
    const got = (try untyped(files, name, options)) orelse return error.SkipZigTest;
    try std.testing.expectEqual(want, got);
}

test "a file is checked with the arguments of its command in compile_commands.json (#277)" {
    try expectUntyped(&.{ implicitFile("a.f90"), database }, "a.f90", "", true);
    // without the database, gfortran's defaults
    try expectUntyped(&.{implicitFile("a.f90")}, "a.f90", "", false);
}

test "compiler_args and compiler_no_compile_commands leave the command out (#277)" {
    try expectUntyped(&.{ implicitFile("a.f90"), database }, "a.f90", ", \"compiler_args\": [\"-Wall\"]", false);
    try expectUntyped(&.{ implicitFile("a.f90"), database }, "a.f90", ", \"compiler_no_compile_commands\": true", false);
}

test "a file without a command takes that of another file in its directory (#277)" {
    try expectUntyped(&.{ implicitFile("a.f90"), implicitFile("new.f90"), database }, "new.f90", "", true);
}
