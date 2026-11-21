! Fortran's operators in #if, which Intel's fpp and Flang's preprocessor
! take, and __LINE__ and __FILE__ (#507)
#define N 10
module preprocessor_fortran_ops
  implicit none
#if defined(N) .and. N .gt. 5 .and. .not. defined(OLD)
  integer :: fortran_ops
#else
  integer :: no_fortran_ops
#endif
#if N .ne. 10 .or. N .lt. 0
  integer :: not_ten
#endif
  integer :: lines(__LINE__)
  character(len=*), parameter :: here = __FILE__
end module preprocessor_fortran_ops
