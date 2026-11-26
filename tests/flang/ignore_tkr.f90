! LLVM Flang's (and nvfortran's) !dir$ ignore_tkr (zfls #409): the
! directive names dummy arguments, which stay what their declarations make
! them, in a procedure, an interface body and a module file
module ignore_tkr
  implicit none
  interface
    subroutine ext_copy(buf, n)
      !dir$ ignore_tkr buf
      real :: buf(*)
      integer, intent(in) :: n
    end subroutine
  end interface
contains
  subroutine s(a)
    !dir$ ignore_tkr a
    real :: a(*)
  end subroutine
  subroutine t(b, c, d)
    !dir$ ignore_tkr (tkr) b, (k) c
    !DIR$ IGNORE_TKR (r) d
    real :: b
    integer :: c
    real :: d(*)
  end subroutine
end module ignore_tkr

program use_ignore_tkr
  use ignore_tkr
  implicit none
  integer :: i(4)
  double precision :: x(2, 2)
  real :: y(2, 2)
  call s(i)
  call s(x)
  call t(i, 1_8, y)
end program use_ignore_tkr
