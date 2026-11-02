! zfls dap with gdb (tests/dap_gdb.zig): arrays, derived types, a
! polymorphic argument, allocatables and pointers, module variables, and a
! bound exceeded (built with -fcheck=bounds). The test stops at the lines
! marked `stop here`.
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
  integer :: ncells = 42
  integer, private :: secret = 99
  type(point) :: origin
contains
  subroutine work(a, b, s, p, t)
    real, intent(inout) :: a(:)
    integer, intent(in) :: b(:,:)
    character(len=*), intent(in) :: s
    type(point), intent(in) :: p
    class(point), intent(in) :: t
    a(1) = a(1) + 5
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
  integer, target :: goal = 5
  integer, pointer :: ip, nothing(:)
  integer :: k
  nullify(nothing)
  ip => goal
  do k = -1, 1
    m(:, k) = [10*k, 20*k]
  end do
  allocate(big(1000)); big = [(real(k), k=1,1000)]
  allocate(tg%w(2)); tg%w = 0.25
  origin%x = 9.0
  call work(v, m, 'abcdef', origin, tg)
  print *, allocated(none), big(1), ip, nhits
  k = 1001 ! stop here: main
  big(k) = 1.0
end program
