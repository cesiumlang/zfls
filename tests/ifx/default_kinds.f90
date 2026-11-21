! oracle-ifx-args: /real-size:64 /integer-size:64
! oracle-zfls-args: --compiler_args ["/real-size:64","/integer-size:64"]
! The default kinds of the command's options (#512, #655): ifx's listing
! has R(8), I(8), L(8) and C(16) for the types written without a kind,
! R(8) for DOUBLE PRECISION, R(4) for REAL(4)
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
