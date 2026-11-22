! Fortran 2018 and 2023 declarations that LLVM Flang reads: SIMPLE and
! NON_RECURSIVE (#727), TYPEOF and CLASSOF (#728), the RANK clause (#729)
module f2023
  implicit none
  integer, parameter :: two = 2
  type :: pt
    real :: x = 0
    integer :: n(3) = 0
  end type
contains
  simple function twice(x) result(y)
    real, intent(in) :: x
    real :: y
    y = 2*x
  end function
  non_recursive subroutine once(k)
    integer, intent(inout) :: k
    k = k + 1
  end subroutine
  simple elemental subroutine inc(k)
    integer, intent(inout) :: k
    k = k + 1
  end subroutine
  subroutine s(p, d, e)
    class(pt), intent(in) :: p
    real, rank(1), intent(in) :: d
    integer, rank(0) :: e
    classof(p), allocatable :: q
    typeof(p%x) :: y
    typeof(p) :: r
    typeof(p%n) :: m
    real, rank(2), allocatable :: a
    real, rank(1), pointer :: pp
    real, allocatable, rank(two) :: b
    real, rank(0) :: c
    allocate(q, source=p)
    y = q%x + d(1)
    r = p
    m = 1
    c = 0
    print *, y, r%x, m, e, c, size(a), associated(pp), size(b), twice(1.0)
  end subroutine
end module
