! lib.mod beside this file is gfortran 16.1's (MSYS2) module file of it,
! `gfortran -c lib.f90`, for tests/issues/gfortran_modules.zig (#544):
! regenerated from this file, not edited
module lib
  implicit none
  private
  public :: n, x, arr, pi, label, pt, scale, f, s, gen, cnt
  integer, parameter :: n = 3
  real(8) :: x
  real, allocatable :: arr(:,:)
  real, parameter :: pi = 3.14159
  character(len=10) :: label
  type pt
    real :: a = 1.0
    integer :: b(3)
  contains
    procedure :: norm
  end type
  type(pt) :: scale
  integer :: cnt(n)
  interface gen
    module procedure f, g
  end interface
contains
  real function f(y)
    real, intent(in) :: y
    f = y
  end function
  real function g(i)
    integer, intent(in) :: i
    g = i
  end function
  subroutine s(a, b)
    real, intent(inout) :: a(:)
    integer, optional, intent(out) :: b
  end subroutine
  real function norm(self)
    class(pt), intent(in) :: self
    norm = self%a
  end function
end module
