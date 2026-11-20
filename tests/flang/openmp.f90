! OpenMP, as LLVM Flang reads it with -fopenmp: !$ lines are code, as
! zfls reads them by default (disable_openmp_conditional); the directives
! declare nothing
! oracle-flang-args: -fopenmp
module openmp_m
  implicit none
  integer :: counter
  !$omp threadprivate(counter)
  !$ integer :: omp_only
contains
  subroutine work(a, n)
    integer, intent(in) :: n
    real, intent(inout) :: a(n)
    integer :: i
    real :: total
    !$omp declare simd(work)
    total = 0
    !$omp parallel do reduction(+:total) private(i)
    do i = 1, n
      total = total + a(i)
    end do
    !$omp end parallel do
    !$ omp_only = 1
    !$omp parallel
    block
      integer :: inside_block
      inside_block = 1
    end block
    !$omp end parallel
  end subroutine
end module openmp_m
