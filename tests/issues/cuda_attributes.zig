//! CUDA Fortran's data attributes (DEVICE, PINNED, ...) among a
//! declaration's other attributes (#715).

const h = @import("harness.zig");

test "CUDA Fortran: the attributes after DEVICE or PINNED are kept" {
    const w = try h.Workspace.init(&.{.{ .name = "data.cuf", .text =
        \\module k
        \\  implicit none
        \\  real, device, allocatable :: dev_buf(:)
        \\  real, pinned, allocatable, target :: host_buf(:)
        \\contains
        \\  subroutine s()
        \\    print *, size(dev_buf), size(host_buf)
        \\  end subroutine s
        \\end module k
        \\
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("data.cuf", w.pos("data.cuf", "dev_buf),", 0, 0), "REAL, ALLOCATABLE, DIMENSION(:) :: dev_buf");
    try w.expectHoverContains("data.cuf", w.pos("data.cuf", "host_buf)", 0, 0), "REAL, ALLOCATABLE, TARGET, DIMENSION(:) :: host_buf");
}
