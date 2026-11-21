! Intel's intrinsic procedures (#505), which are no variables of the
! program: ifx 2026.2.0 takes each
program intel_intrinsics
  implicit none
  integer(2) :: h
  integer(8) :: k8
  integer :: i, j
  real :: x
  real(8) :: d
  real(16) :: q
  h = 4
  i = 5
  j = 2
  x = 1.5
  d = 2.5d0
  k8 = int_ptr_kind()
  i = izext(h) + jzext(h) + int(kzext(h))
  i = inum('12') + jnum('3')
  x = rnum('1.5')
  d = dnum('2.5')
  q = qnum('3.5') + qext(x) + qfloat(i)
  i = ilen(i) + nargs()
  i = isha(i, 1) + ishc(i, 1) + ishl(i, 1) + ixor(i, j)
  d = dcosd(d) + dsind(d) + dtand(d)
  print *, h, k8, i, j, x, d, q
end program intel_intrinsics
