! Preprocessed source: conditionals and object-like macros
#define USE_DOUBLE
#define VECTOR_SIZE 8

module kinds_pp
  implicit none
#ifdef USE_DOUBLE
  integer, parameter :: wp = kind(1.0d0)
#else
  integer, parameter :: wp = kind(1.0)
#endif
  real(wp) :: work(VECTOR_SIZE)
#if VECTOR_SIZE > 4
  logical, parameter :: large_vectors = .true.
#else
  logical, parameter :: large_vectors = .false.
#endif
contains
  function dot(a, b) result(s)
    real(wp), intent(in) :: a(VECTOR_SIZE), b(VECTOR_SIZE)
    real(wp) :: s
    s = sum(a * b)
  end function dot
end module kinds_pp
