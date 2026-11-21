//! Intel's intrinsic procedures (#505; the ifx audit, #489): the names ifx
//! takes in `intrinsic :: NAME` that zfls's table did not have, besides
//! those gfortran shares (#537).

const h = @import("harness.zig");

test "Intel's intrinsics: INT_PTR_KIND, IZEXT, INUM ... QNUM, ILEN, NARGS, ISHA, ISHC, ISHL, IXOR, the B, J, K and Q specific names" {
    // ifx: exit 0
    const w = try h.Workspace.init(&.{.{ .name = "i.f90", .text =
        \\program intel_intrinsics
        \\  implicit none
        \\  integer(1) :: b
        \\  integer(2) :: h
        \\  integer(8) :: k8
        \\  integer :: i, j
        \\  logical :: l
        \\  real :: x
        \\  real(8) :: d
        \\  real(16) :: q
        \\  complex(16) :: cq
        \\  character(len=8) :: buf
        \\  b = 3
        \\  h = 4
        \\  i = 5
        \\  j = 2
        \\  k8 = int_ptr_kind()
        \\  i = izext(h) + jzext(h) + int(kzext(h)) + zext(h)
        \\  i = inum('12') + jnum('3') + int(knum('4'))
        \\  x = rnum('1.5')
        \\  d = dnum('2.5')
        \\  q = qnum('3.5')
        \\  i = ilen(i) + nargs() + numarg()
        \\  i = isha(i, 1) + ishc(i, 1) + ishl(i, 1) + ixor(i, j)
        \\  l = bbtest(b, 1_1)
        \\  b = biand(b, b) + babs(b)
        \\  h = imax0(h, h) + iiabs(h)
        \\  q = qsqrt(q) + qsind(q) + qext(x) + qfloat(i)
        \\  d = dcosd(d) + dsind(d) + dtand(d) + datan2d(d, d) + dbleq(q)
        \\  q = cqabs(cq)
        \\  i = ibchng(i, 1) + cachesize(1) + fp_class(x)
        \\  l = eof(5)
        \\  x = ranf()
        \\  call date(buf)
        \\  call randu(h, h, x)
        \\  print *, b, h, k8, i, l, x, d, q, buf
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("i.f90");
    try w.expectHoverContains("i.f90", w.pos("i.f90", "int_ptr_kind", 0, 0), "address");
    try w.expectHoverContains("i.f90", w.pos("i.f90", "izext", 0, 0), "zeros");
    try w.expectHoverContains("i.f90", w.pos("i.f90", "qsqrt", 0, 0), "a specific name of SQRT");
    try w.expectHoverContains("i.f90", w.pos("i.f90", "bbtest", 0, 0), "a specific name of BTEST");
}
