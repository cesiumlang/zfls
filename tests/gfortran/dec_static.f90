! oracle-gfortran-args: -fdec-static
! DEC's AUTOMATIC and STATIC, as statements and as attributes (#503)
module dec_static
  implicit none
contains
  subroutine autos(n)
    integer n
    real, automatic :: work(10)
    integer, static :: calls = 0
    automatic :: tmp
    static saved
    real tmp, saved
    calls = calls + 1
    work = n
    tmp = work(1)
    saved = tmp
  end subroutine autos
end module dec_static
