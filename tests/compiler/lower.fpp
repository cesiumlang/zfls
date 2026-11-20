program lower
  implicit none
#ifdef ZFLS_DEFINED
  integer :: from_define
  from_define = 1
#else
  print *, not_defined_branch
#endif
  print *, from_define
  print *, undeclared_fpp
end program lower
