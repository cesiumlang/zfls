! oracle-gfortran-args: -fcray-pointer
! BYTE, old-style initial values without `::` and Cray pointers, which
! gfortran accepts (the last with -fcray-pointer) (#503)
subroutine dec_declarations
  implicit none
  byte flags
  integer initd /5/, arr2(3) /1, 2, 3/
  real*8 :: r8
  double complex dc
  real :: target_arr(10), pointee(10)
  integer :: n
  pointer (ptr, pointee), (iptr, n)
  integer, target :: m
  ptr = loc(target_arr)
  iptr = loc(m)
  flags = 1
  r8 = initd + arr2(1)
  dc = (1d0, 2d0)
  print *, flags, r8, dc, pointee(2), n
end subroutine dec_declarations
