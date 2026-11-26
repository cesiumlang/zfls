//! The names of iso_c_binding (#881): the ones of the three compilers (the
//! table is compared with them in src/data/_test/iso_c_binding.zig) are
//! known, so that a use of one is not reported and completion offers it.

const std = @import("std");
const h = @import("harness.zig");

test "iso_c_binding names of every compiler are no unknown names" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module m
        \\  use, intrinsic :: iso_c_binding, only: c_double_complex, c_float_complex, c_long_double_complex, c_float128, c_sizeof, c_uint8_t, c_float16
        \\  implicit none
        \\  complex(c_double_complex) :: z
        \\  complex(c_float_complex) :: y
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("a.f90");
    const items = try w.completion("a.f90", w.pos("a.f90", "complex(c_double", 0, "complex(c_".len));
    var found = false;
    for (items) |label| found = found or std.mem.eql(u8, label, "c_double_complex");
    try std.testing.expect(found);
}
