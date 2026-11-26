! Fortran 2018 and 2023 declarations that LLVM Flang reads: SIMPLE and
! NON_RECURSIVE (#727), TYPEOF and CLASSOF (#728), the RANK clause (#729);
! NOTIFY (#732) and conditional expressions (#733)
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

  ! NOTIFY WAIT and NOTIFY= (#732), conditional expressions (#733)
  subroutine notified(flag, x, z)
    use iso_fortran_env, only: notify_type
    logical, intent(in) :: flag
    real, intent(in) :: x
    real(8), intent(in) :: z(3)
    type(notify_type), save :: nt[*]
    real, save :: b(10)[*]
    if (this_image() == 1) then
      b(1)[2, notify=nt] = (flag ? x : 2*x)
    else
      notify wait (nt, until_count=1)
    end if
    associate (c => (flag ? x : 1.0), w => (flag ? z : 2*z))
      print *, c, w
    end associate
  end subroutine
end module
