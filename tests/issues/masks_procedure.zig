//! A dummy argument that shadows a procedure of the host is reported as
//! masking a procedure, not a variable (#846). gfortran and Flang accept it.

const std = @import("std");
const h = @import("harness.zig");

fn maskMessage(w: *h.Workspace) !?[]const u8 {
    for (try w.diagnostics("t.f90")) |d| if (std.mem.find(u8, d.message, "masks") != null) return d.message;
    return null;
}

test "a dummy argument named like a host function masks a procedure (#846)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\contains
        \\  function t0(value) result(r)
        \\    integer :: value, r
        \\    r = value
        \\  end function
        \\  subroutine s0(t0, value)
        \\    integer :: t0, value
        \\    t0 = value
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    const msg = (try maskMessage(w)) orelse return h.unmet("no masking diagnostic", .{});
    try h.expect(std.mem.eql(u8, msg, "Variable \"t0\" masks procedure in parent scope"), "{s}", .{msg});
}

test "a dummy argument named like a host variable still masks a variable (#846)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  integer :: x
        \\contains
        \\  subroutine s0(x)
        \\    integer :: x
        \\    x = 1
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    const msg = (try maskMessage(w)) orelse return h.unmet("no masking diagnostic", .{});
    try h.expect(std.mem.eql(u8, msg, "Variable \"x\" masks variable in parent scope"), "{s}", .{msg});
}
