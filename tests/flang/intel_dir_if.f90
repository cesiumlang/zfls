! Intel's conditional compilation (!DIR$ IF, !DIR$ ELSE, !DIR$ ENDIF):
! LLVM Flang ignores these directives (with a warning) and so declares the
! names of every branch; zfls evaluates them as ifx does
module intel_dir_if
  implicit none
!DIR$ IF DEFINED(ZFLS_NOT_DEFINED)
  integer :: only_if_defined
!DIR$ ELSE
  integer :: only_else
!DIR$ ENDIF
  integer :: always
end module intel_dir_if
