! oracle-gfortran-args: -fcray-pointer
! Cray pointers (#692): each pointer an integer of address size, its pointee
! a variable that may take its bounds from the POINTER statement
subroutine cray(n)
  implicit none
  integer :: n
  real :: pointee(10)
  integer :: ival
  pointer (ptr, pointee), (iptr, ival)
  pointer (p3, arr3(n, 2))
  real :: arr3
  real, target :: t(10)
  ptr = loc(t)
  iptr = loc(n)
  p3 = loc(t)
  print *, pointee(2), ival, arr3(1, 1)
end subroutine cray

subroutine cray_implicit()
  pointer (q, w(5)), (q2, k)
  q = 0
  q2 = 0
  print *, w(1), k
end subroutine cray_implicit
