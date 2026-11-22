//! Argument checking with an explicit interface: the rank of an actual
//! argument against an assumed-shape or deferred-shape dummy argument, and
//! a scalar against an array, as sequence association allows them (#719).
//! Each case's verdict is that of gfortran 16.1, Flang 23.1.5 and ifx
//! 2026.2.0.

const h = @import("harness.zig");

test "sequence association and assumed shape: what stays silent (#719)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  type :: pt
        \\    real :: x
        \\    real :: arr(4)
        \\  end type
        \\contains
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_v0(v)
        \\    real, intent(in) :: v(0:)
        \\  end subroutine
        \\  subroutine takes_m(w)
        \\    real, intent(in) :: w(:,:)
        \\  end subroutine
        \\  subroutine takes_e(e)
        \\    real, intent(in) :: e(3)
        \\  end subroutine
        \\  subroutine takes_e2(e)
        \\    real, intent(in) :: e(1:2, 2)
        \\  end subroutine
        \\  subroutine takes_z(z)
        \\    real, intent(in) :: z(*)
        \\  end subroutine
        \\  subroutine takes_z2(z)
        \\    real, intent(in) :: z(2, *)
        \\  end subroutine
        \\  subroutine takes_r(r)
        \\    real, intent(in) :: r(..)
        \\  end subroutine
        \\  subroutine takes_c(c)
        \\    character(len=1), intent(in) :: c(4)
        \\  end subroutine
        \\  subroutine takes_cz(c)
        \\    character(len=*), intent(in) :: c(*)
        \\  end subroutine
        \\  subroutine takes_p(p)
        \\    real, pointer, intent(in) :: p(:)
        \\  end subroutine
        \\  subroutine takes_dv(d)
        \\    real, dimension(:), intent(in) :: d
        \\  end subroutine
        \\  elemental subroutine el(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine t(s, v, m, a3, str, strs, q, qs, pv)
        \\    real, intent(in) :: s, v(5), m(3, 3), a3(2, 2, 2)
        \\    character(len=8), intent(in) :: str, strs(3)
        \\    type(pt), intent(in) :: q, qs(3)
        \\    real, pointer, intent(in) :: pv(:)
        \\    integer :: idx(2)
        \\    idx = [1, 2]
        \\    call takes_v(v)
        \\    call takes_v(m(:, 1))
        \\    call takes_v(m(1, :))
        \\    call takes_v(m(idx, 2))
        \\    call takes_v(a3(1, :, 2))
        \\    call takes_v(v + 1.0)
        \\    call takes_v([1.0, 2.0])
        \\    call takes_v(q%arr)
        \\    call takes_v(qs%x)
        \\    call takes_v(qs(2)%arr)
        \\    call takes_v(pv)
        \\    call takes_v(sin(v))
        \\    call takes_v0(v)
        \\    call takes_m(m)
        \\    call takes_m(a3(:, :, 1))
        \\    call takes_m(m * 2.0)
        \\    call takes_dv(v)
        \\    call takes_e(v)
        \\    call takes_e(m)
        \\    call takes_e(v(2))
        \\    call takes_e(m(1, 2))
        \\    call takes_e(a3)
        \\    call takes_e2(m)
        \\    call takes_e2(v)
        \\    call takes_z(v)
        \\    call takes_z(m)
        \\    call takes_z(v(2))
        \\    call takes_z(a3(1, 1, 1))
        \\    call takes_z2(m)
        \\    call takes_z2(a3)
        \\    call takes_z2(m(1, 1))
        \\    call takes_r(s)
        \\    call takes_r(v)
        \\    call takes_r(m)
        \\    call takes_c(str)
        \\    call takes_c(str(2:5))
        \\    call takes_c(strs)
        \\    call takes_c(strs(2))
        \\    call takes_c(strs(2)(1:4))
        \\    call takes_c('abcd')
        \\    call takes_cz(str)
        \\    call takes_cz(strs)
        \\    call takes_cz(strs(1))
        \\    call takes_p(pv)
        \\    call el(s)
        \\    call el(v)
        \\    call el(m)
        \\    associate (b => m(:, 1), c => m, e => m(1, 1))
        \\      call takes_v(b)
        \\      call takes_m(c)
        \\      call takes_e(c)
        \\      call takes_z(b)
        \\    end associate
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // the three compilers accept it all
    try w.expectDiagnostics("t.f90", &.{});
}

test "a rank that differs from an assumed-shape dummy argument's, a scalar for an array (#719)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  type :: pt
        \\    real :: x
        \\    real :: arr(4)
        \\  end type
        \\contains
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_v0(v)
        \\    real, intent(in) :: v(0:)
        \\  end subroutine
        \\  subroutine takes_m(w)
        \\    real, intent(in) :: w(:,:)
        \\  end subroutine
        \\  subroutine takes_e(e)
        \\    real, intent(in) :: e(3)
        \\  end subroutine
        \\  subroutine takes_e2(e)
        \\    real, intent(in) :: e(1:2, 2)
        \\  end subroutine
        \\  subroutine takes_z(z)
        \\    real, intent(in) :: z(*)
        \\  end subroutine
        \\  subroutine takes_z2(z)
        \\    real, intent(in) :: z(2, *)
        \\  end subroutine
        \\  subroutine takes_r(r)
        \\    real, intent(in) :: r(..)
        \\  end subroutine
        \\  subroutine takes_c(c)
        \\    character(len=1), intent(in) :: c(4)
        \\  end subroutine
        \\  subroutine takes_cz(c)
        \\    character(len=*), intent(in) :: c(*)
        \\  end subroutine
        \\  subroutine takes_p(p)
        \\    real, pointer, intent(in) :: p(:)
        \\  end subroutine
        \\  subroutine takes_dv(d)
        \\    real, dimension(:), intent(in) :: d
        \\  end subroutine
        \\  elemental subroutine el(x)
        \\    real, intent(in) :: x
        \\  end subroutine
        \\  subroutine takes_cls(d)
        \\    class(pt), intent(in) :: d(3)
        \\  end subroutine
        \\  subroutine takes_any(d)
        \\    class(*), intent(in) :: d(3)
        \\  end subroutine
        \\  subroutine takes_tp(d)
        \\    type(pt), intent(in) :: d(3)
        \\  end subroutine
        \\  subroutine takes_i(d)
        \\    integer, intent(in) :: d(2)
        \\  end subroutine
        \\  subroutine takes_al(d)
        \\    real, allocatable, intent(in) :: d(:,:)
        \\  end subroutine
        \\  subroutine t(s, v, m, a3, str, strs, q, qs, pv, n, al1)
        \\    real, intent(in) :: s, v(5), m(3, 3), a3(2, 2, 2)
        \\    character(len=8), intent(in) :: str, strs(3)
        \\    type(pt), intent(in) :: q, qs(3)
        \\    real, pointer, intent(in) :: pv(:,:)
        \\    integer, intent(in) :: n
        \\    real, allocatable, intent(in) :: al1(:)
        \\    call takes_v(s)
        \\    call takes_v(m)
        \\    call takes_v(v(1))
        \\    call takes_v(m(1, 1))
        \\    call takes_v(a3)
        \\    call takes_v(a3(:, :, 1))
        \\    call takes_v(q%x)
        \\    call takes_v(qs(1)%x)
        \\    call takes_v(m * 2.0)
        \\    call takes_m(v)
        \\    call takes_m(s)
        \\    call takes_m(a3)
        \\    call takes_v0(m)
        \\    call takes_dv(m)
        \\    call takes_e(s)
        \\    call takes_z(s)
        \\    call takes_z2(s)
        \\    call takes_e(q%x)
        \\    call takes_i(n)
        \\    call takes_tp(q)
        \\    call takes_cls(q)
        \\    call takes_any(s)
        \\    call takes_p(pv)
        \\    call takes_al(al1)
        \\    call takes_cz(q%x)
        \\    associate (e => m(1, 1), b => m(:, 1))
        \\      call takes_e(e)
        \\      call takes_m(b)
        \\    end associate
        \\    call takes_v(str)
        \\    call takes_v(strs(1))
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // the three compilers report each of these lines ("Rank mismatch in
    // argument 'v' at (1) (rank-1 and rank-2)", "Scalar actual argument may
    // not be associated with assumed-shape dummy argument", "Whole scalar
    // actual argument may not be associated with a dummy argument 'e='
    // array", ifx #6634 and #8284), and line 90, a CLASS(*) array given a
    // scalar (#762)
    try w.expectDiagnostics("t.f90", &.{
        "69: Argument v of takes_v: an array expected, a scalar given",
        "70: Argument v of takes_v: rank 1 expected, rank 2 given",
        "71: Argument v of takes_v: an array expected, a scalar given",
        "72: Argument v of takes_v: an array expected, a scalar given",
        "73: Argument v of takes_v: rank 1 expected, rank 3 given",
        "74: Argument v of takes_v: rank 1 expected, rank 2 given",
        "75: Argument v of takes_v: an array expected, a scalar given",
        "76: Argument v of takes_v: an array expected, a scalar given",
        "77: Argument v of takes_v: rank 1 expected, rank 2 given",
        "78: Argument w of takes_m: rank 2 expected, rank 1 given",
        "79: Argument w of takes_m: an array expected, a scalar given",
        "80: Argument w of takes_m: rank 2 expected, rank 3 given",
        "81: Argument v of takes_v0: rank 1 expected, rank 2 given",
        "82: Argument d of takes_dv: rank 1 expected, rank 2 given",
        "83: Argument e of takes_e: an array expected, a scalar given",
        "84: Argument z of takes_z: an array expected, a scalar given",
        "85: Argument z of takes_z2: an array expected, a scalar given",
        "86: Argument e of takes_e: an array expected, a scalar given",
        "87: Argument d of takes_i: an array expected, a scalar given",
        "88: Argument d of takes_tp: an array expected, a scalar given",
        "89: Argument d of takes_cls: an array expected, a scalar given",
        "90: Argument d of takes_any: an array expected, a scalar given",
        "91: Argument p of takes_p: rank 1 expected, rank 2 given",
        "92: Argument d of takes_al: rank 2 expected, rank 1 given",
        "93: Argument c of takes_cz: character expected, real given",
        "95: Argument e of takes_e: an array expected, a scalar given",
        "96: Argument w of takes_m: rank 2 expected, rank 1 given",
        "98: Argument v of takes_v: real expected, character given",
        "99: Argument v of takes_v: real expected, character given",
    });
}

test "components, characters, interface blocks, internal and external procedures (#719)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  type :: pt
        \\    real :: x
        \\    real :: arr(4)
        \\  end type
        \\contains
        \\  subroutine takes_e(e)
        \\    real, intent(in) :: e(3)
        \\  end subroutine
        \\  subroutine takes_cls(d)
        \\    class(pt), intent(in) :: d(3)
        \\  end subroutine
        \\  subroutine takes_ch(c)
        \\    character(len=*), intent(in) :: c(:)
        \\  end subroutine
        \\  subroutine t(qs, vv, cs, str, ps)
        \\    type(pt), intent(in) :: qs(3)
        \\    real, intent(in) :: vv(:)
        \\    class(pt), intent(in) :: cs(:)
        \\    character(len=8), intent(in) :: str
        \\    type(pt), intent(in) :: ps(3)
        \\    call takes_e(qs(1)%x)
        \\    call takes_e(qs(1)%arr(2))
        \\    call takes_e(vv(1))
        \\    call takes_cls(cs(1))
        \\    call takes_cls(ps(1))
        \\    call takes_ch(str)
        \\    call takes_ch(str(1:2))
        \\  end subroutine
        \\end module
        \\subroutine ext(v)
        \\  real, intent(in) :: v(:)
        \\end subroutine
        \\subroutine ext_e(e)
        \\  real, intent(in) :: e(3)
        \\end subroutine
        \\subroutine caller(s, m)
        \\  real, intent(in) :: s, m(2, 2)
        \\  call ext(s)
        \\  call ext(m)
        \\  call ext_e(s)
        \\end subroutine
        \\subroutine caller2(s, m)
        \\  real, intent(in) :: s, m(2, 2)
        \\  interface
        \\    subroutine ext(v)
        \\      real, intent(in) :: v(:)
        \\    end subroutine
        \\  end interface
        \\  call ext(s)
        \\  call ext(m)
        \\  call ext(m(:, 1))
        \\end subroutine
        \\program main
        \\  implicit none
        \\  real :: s, m(2, 2)
        \\  s = 0
        \\  m = 0
        \\  call inner(m)
        \\  call inner(m(1, :))
        \\  call inner(s)
        \\contains
        \\  subroutine inner(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\end program
        \\
    }}, .{});
    defer w.deinit();
    // the three compilers report these lines, lines 25 and 26 among them (an
    // element of an assumed-shape array for an explicit-shape one, #762);
    // lines 40 to 42 call an external procedure without an
    // interface, which is not checked
    try w.expectDiagnostics("t.f90", &.{
        "23: Argument e of takes_e: an array expected, a scalar given",
        "25: Argument e of takes_e: an array expected, a scalar given",
        "26: Argument d of takes_cls: an array expected, a scalar given",
        "28: Argument c of takes_ch: an array expected, a scalar given",
        "29: Argument c of takes_ch: an array expected, a scalar given",
        "51: Argument v of ext: an array expected, a scalar given",
        "52: Argument v of ext: rank 1 expected, rank 2 given",
        "60: Argument v of inner: rank 1 expected, rank 2 given",
        "62: Argument v of inner: an array expected, a scalar given",
    });
}

test "assumed type and the other intrinsic types (#719)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  subroutine takes_t(b)
        \\    type(*), intent(in) :: b(*)
        \\  end subroutine
        \\  subroutine takes_ta(b)
        \\    type(*), intent(in) :: b(:)
        \\  end subroutine
        \\  subroutine takes_any(b)
        \\    class(*), intent(in) :: b(*)
        \\  end subroutine
        \\  subroutine takes_l(b)
        \\    logical, intent(in) :: b(2)
        \\  end subroutine
        \\  subroutine takes_cx(b)
        \\    complex, intent(in) :: b(:)
        \\  end subroutine
        \\  subroutine t(s, n, l, z)
        \\    real, intent(in) :: s
        \\    integer, intent(in) :: n
        \\    logical, intent(in) :: l
        \\    complex, intent(in) :: z
        \\    call takes_t(s)
        \\    call takes_ta(s)
        \\    call takes_any(n)
        \\    call takes_l(l)
        \\    call takes_cx(z)
        \\    call takes_t(1.0)
        \\    call takes_l(.true.)
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // the three compilers report these lines, line 26 (CLASS(*), #762) among
    // them; gfortran and Flang accept a scalar for a TYPE(*)
    // assumed-size array (lines 24 and 29), which ifx does not
    try w.expectDiagnostics("t.f90", &.{
        "25: Argument b of takes_ta: an array expected, a scalar given",
        "26: Argument b of takes_any: an array expected, a scalar given",
        "27: Argument b of takes_l: an array expected, a scalar given",
        "28: Argument b of takes_cx: an array expected, a scalar given",
        "30: Argument b of takes_l: an array expected, a scalar given",
    });
}

test "an associate name of a rank not known, an array COMMON gives its bounds: silent (#719)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "a.f90", .text =
        \\module m
        \\  implicit none
        \\contains
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_e(e)
        \\    real, intent(in) :: e(3)
        \\  end subroutine
        \\  function f(x) result(r)
        \\    real, intent(in) :: x(:)
        \\    real :: r(size(x))
        \\    r = x
        \\  end function
        \\  subroutine t(a, b)
        \\    real, intent(in) :: a(3), b(3, 3)
        \\    associate (y => f(a), z => matmul(b, a), q => a + f(a), p => [a, a], n => reshape(b, [9]))
        \\      call takes_v(y)
        \\      call takes_v(z)
        \\      call takes_v(q)
        \\      call takes_v(p)
        \\      call takes_v(n)
        \\      call takes_e(y)
        \\      call takes_e(z)
        \\      call takes_e(n)
        \\    end associate
        \\  end subroutine
        \\end module
        \\
        },
        .{ .name = "c.f90", .text =
        \\module mc
        \\  implicit none
        \\contains
        \\  subroutine takes_v(v)
        \\    real, intent(in) :: v(:)
        \\  end subroutine
        \\  subroutine takes_e(e)
        \\    real, intent(in) :: e(3)
        \\  end subroutine
        \\  subroutine t()
        \\    real :: w
        \\    common /blk/ w(4)
        \\    call takes_v(w)
        \\    call takes_e(w)
        \\  end subroutine
        \\end module mc
        \\subroutine u()
        \\  real :: w
        \\  common /blk/ w(4)
        \\  print *, w(1)
        \\end subroutine
        \\
        },
    }, .{});
    defer w.deinit();
    // the three compilers accept both files
    try w.expectDiagnostics("a.f90", &.{});
    try w.expectDiagnostics("c.f90", &.{});
    // the bounds of the COMMON statement of a module procedure followed by
    // another program unit (they were read from a reused line buffer)
    try w.expectHoverContains("c.f90", w.pos("c.f90", "w)", 0, 0), "REAL, DIMENSION(4) :: w");
}

test "elements of assumed-shape, pointer and polymorphic arrays, a scalar for CLASS(*) (#762)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module m
        \\  implicit none
        \\  type :: t
        \\    real :: x = 0
        \\  end type
        \\contains
        \\  subroutine takes_e(e)
        \\    real, intent(in) :: e(10)
        \\  end subroutine
        \\  subroutine takes_star(e)
        \\    real, intent(in) :: e(*)
        \\  end subroutine
        \\  subroutine takes_cls(a)
        \\    class(t), intent(in) :: a(*)
        \\  end subroutine
        \\  subroutine takes_tys(a)
        \\    type(t), intent(in) :: a(*)
        \\  end subroutine
        \\  subroutine takes_any(d)
        \\    class(*), intent(in) :: d(3)
        \\  end subroutine
        \\  subroutine takes_tstar(b)
        \\    type(*), intent(in) :: b(*)
        \\  end subroutine
        \\  subroutine s(vv, cv, n, cs, ts, pc)
        \\    real, intent(in) :: vv(:)
        \\    real, contiguous, intent(in) :: cv(:)
        \\    integer, intent(in) :: n
        \\    class(t), intent(in) :: cs(3)
        \\    type(t), intent(in) :: ts(3)
        \\    real, pointer, contiguous, intent(in) :: pc(:)
        \\    real, pointer :: pp(:)
        \\    real, allocatable :: al(:)
        \\    real, target :: ex(10)
        \\    allocate(al(10))
        \\    pp => ex
        \\    call takes_e(vv(1))
        \\    call takes_star(vv(1))
        \\    call takes_e(cv(1))
        \\    call takes_e(pp(1))
        \\    call takes_e(pc(1))
        \\    call takes_e(al(1))
        \\    call takes_e(ex(1))
        \\    call takes_cls(cs(1))
        \\    call takes_tys(ts(1))
        \\    call takes_any(n)
        \\    call takes_tstar(n)
        \\    call takes_any(ts(1))
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    // the errors gfortran 16.1, Flang 23.1.5 and ifx 2026.2.0 all report;
    // not the elements of CONTIGUOUS arrays (`cv(1)`, `pc(1)`), which Flang
    // takes, nor the scalar for TYPE(*), which gfortran and Flang take
    try w.expectDiagnostics("t.f90", &.{
        "37: Argument e of takes_e: an array expected, a scalar given",
        "38: Argument e of takes_star: an array expected, a scalar given",
        "40: Argument e of takes_e: an array expected, a scalar given",
        "44: Argument a of takes_cls: an array expected, a scalar given",
        "46: Argument d of takes_any: an array expected, a scalar given",
    });
}
