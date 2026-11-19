program defines
  implicit none
#ifdef ZFLS_DEFINED
  integer :: from_define
  from_define = 1
#endif
  print *, from_define
  print *, undeclared_defines
end program defines
