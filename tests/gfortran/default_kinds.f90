! oracle-gfortran-args: -fdefault-real-8 -fdefault-integer-8
! oracle-zfls-args: --compiler_args ["-fdefault-real-8","-fdefault-integer-8"]
! The default kinds of the command's options (#512, #655): gfortran's
! dump has (REAL 8), (INTEGER 8), (LOGICAL 8), (COMPLEX 8) for the types
! written without a kind, (REAL 16) for DOUBLE PRECISION, (REAL 4) for
! REAL(4)
module default_kinds
  implicit none
  real :: r
  integer :: i
  logical :: l
  complex :: z
  double precision :: d
  real(4) :: r4
contains
  subroutine s(x, n)
    real, intent(in) :: x
    integer, intent(out) :: n
    n = int(x)
  end subroutine s
end module default_kinds
