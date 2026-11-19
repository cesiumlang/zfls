//! The compiler check (`compiler_diagnostics`) reads lines as long as zfls
//! does: fixed form up to `fixed_line_length`, free form without a limit,
//! unless `compiler_args` sets one (#256). With gfortran; skipped where it
//! is not on the PATH.

const std = @import("std");
const h = @import("harness.zig");

// line 5 is 80 columns long; `unused` makes gfortran -Wall always say
// something, so that its diagnostics are known to have come
const fixed = h.File{ .name = "w.f", .text =
    \\      program p
    \\      implicit none
    \\      integer :: abc, longname, unused
    \\      abc = 1
    \\      longname = abc + abc + abc + abc + abc + abc + abc + abc + abc + abc + abc
    \\      print *, longname
    \\      end
    \\
};

/// A free-form file whose line 5 is 12016 columns long: past gfortran's
/// limit, 132 columns before GCC 16 and 10000 since
fn freeFile(a: std.mem.Allocator) !h.File {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "program p\n  implicit none\n  integer :: abc, longname, unused\n  abc = 1\n  longname = abc");
    for (0..2000) |_| try text.appendSlice(a, " + abc");
    try text.appendSlice(a, "\n  print *, longname\nend program p\n");
    return .{ .name = "long.f90", .text = text.items };
}

/// gfortran's diagnostics of `file` opened with `options`, null when
/// gfortran is not on the PATH
fn gfortranDiagnostics(file: h.File, comptime options: []const u8) !?[]const u8 {
    const w = try h.Workspace.init(&.{file}, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\"" ++ options ++ "}" });
    defer w.deinit();
    try w.open(file.name, "fortran");
    var waited: usize = 0;
    while (waited < 600) : (waited += 1) {
        if (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"gfortran\"", 0)) |sent| return try std.testing.allocator.dupe(u8, sent);
        if (try w.waitForSent("window/showMessage", "was not found", 0) != null) return null;
        std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.NoCompilerDiagnostics;
}

fn expectTruncated(file: h.File, comptime options: []const u8, want: bool) !void {
    const sent = (try gfortranDiagnostics(file, options)) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(sent);
    std.testing.expectEqual(want, std.mem.find(u8, sent, "Line truncated") != null) catch |e| {
        std.debug.print("\n{s}\n", .{sent});
        return e;
    };
}

test "fixed form: the compiler reads lines up to fixed_line_length (#256)" {
    try expectTruncated(fixed, ", \"fixed_line_length\": 132", false);
    try expectTruncated(fixed, ", \"fixed_line_length\": 72", true);
    try expectTruncated(fixed, "", true);
}

test "free form: no line length limit from the compiler by default (#256)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectTruncated(try freeFile(arena.allocator()), "", false);
}

test "a line length in compiler_args wins (#256)" {
    try expectTruncated(fixed, ", \"fixed_line_length\": 72, \"compiler_args\": [\"-Wall\", \"-ffixed-line-length-none\"]", false);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectTruncated(try freeFile(arena.allocator()), ", \"compiler_args\": [\"-Wall\", \"-ffree-line-length-132\"]", true);
}
