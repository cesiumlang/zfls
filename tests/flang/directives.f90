! Compiler directives and OpenMP and OpenACC lines, which LLVM Flang
! without -fopenmp or -fopenacc reads as comments: they declare nothing
module directives
  implicit none
contains
  subroutine s(a, n)
    !dir$ ignore_tkr a
    real :: a(*)
    integer, intent(in) :: n
    integer :: i
    !dir$ assume_aligned a:64
    !dir$ vector always
    do i = 1, n
      a(i) = a(i) * 2
    end do
    !dir$ unroll 4
    do i = 1, n
      a(i) = a(i) + 1
    end do
    !dir$ novector
    !dir$ loop count(100)
    do i = 1, n
      a(i) = a(i) - 1
    end do
  end subroutine
  subroutine acc(a, n)
    integer, intent(in) :: n
    real :: a(n)
    integer :: i
    !$acc routine seq
    !$acc parallel loop copy(a)
    do i = 1, n
      a(i) = a(i) + 1
    end do
    !$omp parallel do simd private(i)
    do i = 1, n
      a(i) = a(i) + 1
    end do
    !$omp end parallel do simd
    !$ print *, 'omp'
  end subroutine
end module directives
