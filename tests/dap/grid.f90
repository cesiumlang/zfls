! zfls dap with gdb (tests/dap_gdb.zig): arrays, derived types, polymorphic
! arguments (a scalar, an array), allocatables and pointers, module
! variables, and a bound exceeded (built with -fcheck=bounds; LLVM Flang,
! which has no such check, stops at the OPEN of a missing file after it).
! The test stops at the lines marked `stop here` (LFortran's, in work, a
! line before: tests/dap_lfortran.zig).
module grid
  implicit none
  type :: point
    real :: x = 1.5, y = -2.0
    integer :: id = 7
  end type
  type, extends(point) :: tagged
    character(len=8) :: tag = 'hello'
    real, allocatable :: w(:)
  end type
  type, extends(point) :: labeled
    integer :: label = 5
  end type
  integer :: ncells = 42
  integer, private :: secret = 99
  type(point) :: origin
  character(len=:), allocatable :: gname
contains
  subroutine work(a, b, s, p, t, ts)
    real, intent(inout) :: a(:)
    integer, intent(in) :: b(:,:)
    character(len=*), intent(in) :: s
    type(point), intent(in) :: p
    class(point), intent(in) :: t
    class(point), intent(in) :: ts(:)
    a(1) = a(1) + 5 ! LFortran stops here: its PRINT has no line
    print *, a, b(2,1), s, p%x, t%id, secret ! stop here: work
  end subroutine
end module

module counters
  implicit none
  integer :: hits = 3
end module

program main
  use grid
  use counters, only: nhits => hits
  implicit none
  real :: v(3) = [1., 2., 3.]
  real, allocatable :: big(:), none(:)
  integer :: m(2:3, -1:1)
  type(tagged) :: tg
  type(labeled) :: lb
  class(point), allocatable :: pts(:)
  integer, target :: goal = 5
  integer, pointer :: ip, nothing(:)
  integer :: k
  character(len=:), allocatable :: dl
  nullify(nothing)
  ip => goal
  do k = -1, 1
    m(:, k) = [10*k, 20*k]
  end do
  allocate(big(1000)); big = [(real(k), k=1,1000)]
  allocate(tg%w(2)); tg%w = 0.25
  allocate(pts(2), source=lb)
  origin%x = 9.0
  dl = 'deferred'
  gname = 'grid name'
  call work(v, m, 'abcdef', origin, tg, pts)
  print *, allocated(none), big(1), ip, nhits, dl, gname
  k = 4 ! stop here: main
  m(k, -1) = 0
  open(newunit=k, file='no/such/file', status='old')
end program
