! A generic interface that has the name of one of its specifics (zfls
! #469, #471), with a module procedure and with an interface body, and a
! generic that has the name of a derived type (its structure constructor)
module generic_specific
  implicit none
  type :: vec
    real :: x = 0
  end type
  interface vec
    module procedure make_vec
  end interface
  interface norm
    module procedure norm
    module procedure norm2d
  end interface
  interface ext_gen
    subroutine ext_gen(a)
      real, intent(in) :: a
    end subroutine
    subroutine ext_gen_int(i)
      integer, intent(in) :: i
    end subroutine
  end interface
contains
  type(vec) function make_vec(a, b)
    real, intent(in) :: a, b
    make_vec%x = a + b
  end function
  real function norm(v)
    type(vec), intent(in) :: v
    norm = abs(v%x)
  end function
  real function norm2d(x, y)
    real, intent(in) :: x, y
    norm2d = sqrt(x*x + y*y)
  end function
end module generic_specific
