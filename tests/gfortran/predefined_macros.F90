! The macros gfortran's preprocessor predefines, which zfls asks of the
! compiler check's gfortran (#541): the oracle gives zfls the gfortran it runs
module predefined_macros
  implicit none
#ifdef __GFORTRAN__
  integer :: gf_only
#else
  integer :: not_gfortran
#endif
#if defined(__GNUC__) && __GNUC__ >= 9
  integer :: gnuc9
#endif
#ifdef _WIN32
  integer :: win32_only
#endif
end module predefined_macros
