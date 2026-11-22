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
/// until clangd has read the file, at most `timeout_s` seconds
fn findsC(w: *h.Workspace, timeout_s: u32) !bool {
    var waited: u32 = 0;
    while (waited < timeout_s) : (waited += 1) {
        for (try w.definitions("iface.f90", w.pos("iface.f90", "c_made(1", 0, 1))) |d| {
            if (std.mem.endsWith(u8, d.uri, "made.c")) return d.line == 1;
        }
        std.testing.io.sleep(.fromSeconds(1), .awake) catch {};
    }
    return false;
}

test "bind_c_clangd: clangd finds the C function a macro makes (#739)" {
    try tools.need("clangd");
    // zfls's search alone does not
    {
        const w = try h.Workspace.init(&.{ csource, iface }, .{});
        defer w.deinit();
        try std.testing.expect(!try findsC(w, 1));
    }
    const w = try h.Workspace.init(&.{ csource, iface }, .{ .init_options = "{\"bind_c_clangd\": \"clangd\"}" });
    defer w.deinit();
    try std.testing.expect(try findsC(w, 90));
}
