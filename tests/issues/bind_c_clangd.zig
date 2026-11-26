//! `bind_c_clangd` with a real clangd (#739): go to definition of a
//! `BIND(C)` procedure whose C function a macro makes, which zfls's own
//! search of the C files cannot see, gives clangd's place of it. Skipped
//! where clangd is not on the PATH.

const std = @import("std");
const h = @import("harness.zig");
const tools = @import("tools.zig");

const csource = h.File{ .name = "made.c", .text =
    \\#define ADDER(name) int name(int a, int b) { return a + b; }
    \\ADDER(c_made)
    \\
};
const iface = h.File{ .name = "iface.f90", .text =
    \\module iface
    \\  use iso_c_binding
    \\  interface
    \\    integer(c_int) function c_made(a, b) bind(C, name="c_made")
    \\      import :: c_int
    \\      integer(c_int), value :: a, b
    \\    end function c_made
    \\  end interface
    \\contains
    \\  subroutine call_it()
    \\    print *, c_made(1, 2)
    \\  end subroutine call_it
    \\end module iface
    \\
};

/// Whether go to definition of the call gives a place in made.c, asked
/// until clangd has read the file, for at most `timeout_s` seconds
fn findsC(w: *h.Workspace, timeout_s: i64) !bool {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (std.Io.Clock.awake.now(io).nanoseconds - start < timeout_s * std.time.ns_per_s) {
        for (try w.definitions("iface.f90", w.pos("iface.f90", "c_made(1", 0, 1))) |d| {
            if (std.mem.endsWith(u8, d.uri, "made.c") and d.line == 1) return true;
        }
        io.sleep(.fromSeconds(1), .awake) catch {};
    }
    return false;
}

/// Tries of a clangd that never answers (one that did not start, or stalled
/// on a loaded runner), each with a clangd of its own
const attempts = 3;

test "bind_c_clangd: clangd finds the C function a macro makes (#739)" {
    try tools.need("clangd");
    // zfls's search alone does not
    {
        const w = try h.Workspace.init(&.{ csource, iface }, .{});
        defer w.deinit();
        try std.testing.expect(!try findsC(w, 1));
    }
    for (0..attempts) |_| {
        const w = try h.Workspace.init(&.{ csource, iface }, .{ .init_options = "{\"bind_c_clangd\": \"clangd\"}" });
        defer w.deinit();
        if (try findsC(w, 45)) return;
    }
    return error.TestUnexpectedResult;
}
