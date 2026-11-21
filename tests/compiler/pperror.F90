program pperror
  implicit none
#ifdef ZFLS_DEFINED
#error zfls error directive
#endif
  print *, 1
end program pperror
