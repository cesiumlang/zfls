//! The compiler check (`compiler_diagnostics`) with LFortran: the modules a
//! file uses compiled so that their .mod files exist (#177). With a real
//! LFortran; skipped where it is not on the PATH.

const std = @import("std");
const h = @import("harness.zig");

const module = h.File{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  type :: t
    \\    integer :: x
    \\  contains
    \\    procedure :: get
    \\  end type
    \\contains
    \\  integer function get(self)
    \\    class(t), intent(in) :: self
    \\    get = self%x
    \\  end function
    \\end module m
    \\
};

const user = h.File{ .name = "use.f90", .text =
    \\program p
    \\  use m
    \\  implicit none
    \\  type(t) :: v
    \\  integer :: k
    \\  v%x = 1
    \\  k = v%get()
    \\  k = abc + 1
    \\end program p
    \\
};

/// The first diagnostics LFortran gives `name` in a workspace of `files`
/// opened with `options`, null when LFortran is not on the PATH
fn lfortranDiagnostics(files: []const h.File, name: []const u8, comptime options: []const u8) !?[]const u8 {
    const w = try h.Workspace.init(files, .{ .init_options = "{\"compiler_diagnostics\": \"lfortran\"" ++ options ++ "}" });
    defer w.deinit();
    try w.open(name, "fortran");
    var waited: usize = 0;
    while (waited < 600) : (waited += 1) {
        if (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"lfortran\"", 0)) |sent| return try std.testing.allocator.dupe(u8, sent);
        if (try w.waitForSent("window/showMessage", "was not found", 0) != null) return null;
        std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.NoCompilerDiagnostics;
}

fn expectIn(sent: []const u8, needle: []const u8, want: bool) !void {
    std.testing.expectEqual(want, std.mem.find(u8, sent, needle) != null) catch |e| {
        std.debug.print("\n{s} {s} in:\n{s}\n", .{ needle, if (want) "missing" else "unexpected", sent });
        return e;
    };
}

test "LFortran: the modules a file uses are compiled, so that their .mod files exist (#177)" {
    const sent = (try lfortranDiagnostics(&.{ module, user }, "use.f90", "")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(sent);
    try expectIn(sent, "modfile was not found", false);
    // the type-bound procedure is known: only the undeclared variable
    try expectIn(sent, "Variable 'abc' is not declared", true);
}
