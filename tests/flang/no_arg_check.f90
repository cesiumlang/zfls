! NO_ARG_CHECK of gfortran (!GCC$) and Intel (!DIR$, !DEC$) (zfls #425):
! directives LLVM Flang accepts or ignores, which declare no names
module no_arg_check
  implicit none
contains
  subroutine raw(buf, n)
    !GCC$ ATTRIBUTES NO_ARG_CHECK :: buf
    integer :: buf(*)
    integer, intent(in) :: n
  end subroutine
  subroutine raw2(buf)
    !DIR$ ATTRIBUTES NO_ARG_CHECK :: buf
    real :: buf(*)
  end subroutine
  subroutine raw3(buf)
    !DEC$ ATTRIBUTES REFERENCE, NO_ARG_CHECK :: buf
    real :: buf(*)
  end subroutine
end module no_arg_check
