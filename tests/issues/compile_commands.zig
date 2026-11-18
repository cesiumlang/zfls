//! The compiler check (`compiler_diagnostics`) runs a file with the
//! arguments of its command in compile_commands.json, so that it sees the
//! project's dialect options (#277). With gfortran; skipped where it is not
//! on the PATH.

const std = @import("std");
const h = @import("harness.zig");

/// A free-form file whose line 5 is 12016 columns long, past gfortran's
/// default limit (132 columns before GCC 16, 10000 since); `unused` makes
/// gfortran -Wall always say something, so that its diagnostics are known
/// to have come
fn longFile(a: std.mem.Allocator, name: []const u8) !h.File {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "program p\n  implicit none\n  integer :: abc, longname, unused\n  abc = 1\n  longname = abc");
    for (0..2000) |_| try text.appendSlice(a, " + abc");
    try text.appendSlice(a, "\n  print *, longname\nend program p\n");
    return .{ .name = name, .text = text.items };
}

const database = h.File{ .name = "compile_commands.json", .text =
    \\[{"directory": ".", "file": "long.f90",
    \\  "arguments": ["gfortran", "-ffree-line-length-none", "-Wall", "-Jmod", "-c", "long.f90", "-o", "long.o"]}]
    \\
};

/// Whether gfortran's diagnostics of `name` say `Line truncated`, null when
/// gfortran is not on the PATH
fn truncated(files: []const h.File, name: []const u8, comptime options: []const u8) !?bool {
    const w = try h.Workspace.init(files, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\"" ++ options ++ "}" });
    defer w.deinit();
    try w.open(name, "fortran");
    var waited: usize = 0;
    while (waited < 600) : (waited += 1) {
        if (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"gfortran\"", 0)) |sent| return std.mem.find(u8, sent, "Line truncated") != null;
        if (try w.waitForSent("window/showMessage", "was not found", 0) != null) return null;
        std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.NoCompilerDiagnostics;
}

fn expectTruncated(files: []const h.File, name: []const u8, comptime options: []const u8, want: bool) !void {
    const got = (try truncated(files, name, options)) orelse return error.SkipZigTest;
    try std.testing.expectEqual(want, got);
}

test "a file is checked with the arguments of its command in compile_commands.json (#277)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = try longFile(arena.allocator(), "long.f90");
    try expectTruncated(&.{ long, database }, "long.f90", "", false);
    // without the database, gfortran's own limit
    try expectTruncated(&.{long}, "long.f90", "", true);
}

test "compiler_args and compiler_no_compile_commands leave the command out (#277)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = try longFile(arena.allocator(), "long.f90");
    try expectTruncated(&.{ long, database }, "long.f90", ", \"compiler_args\": [\"-Wall\"]", true);
    try expectTruncated(&.{ long, database }, "long.f90", ", \"compiler_no_compile_commands\": true", true);
}

test "a file without a command takes that of another file in its directory (#277)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectTruncated(&.{ try longFile(a, "long.f90"), try longFile(a, "new.f90"), database }, "new.f90", "", false);
}
