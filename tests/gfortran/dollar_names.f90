! oracle-gfortran-args: -fdollar-ok
! $ in names after the first character (#508)
module dol
  implicit none
  integer :: n$count
contains
  subroutine a$b(x$y)
    real :: x$y
    x$y = 1
  end subroutine a$b
  integer function f$g()
    f$g = 2
  end function
end module
