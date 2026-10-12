! Separate module procedures implemented in a submodule
module geometry
  implicit none
  type :: point
    real :: x = 0.0, y = 0.0
  end type point

  interface
    module function distance(a, b) result(d)
      type(point), intent(in) :: a, b
      real :: d
    end function distance

    module subroutine translate(p, dx, dy)
      type(point), intent(inout) :: p
      real, intent(in) :: dx, dy
    end subroutine translate
  end interface
end module geometry

submodule (geometry) geometry_impl
  implicit none
  real, parameter :: eps = 1.0e-6
contains
  module function distance(a, b) result(d)
    type(point), intent(in) :: a, b
    real :: d
    d = sqrt((a%x - b%x)**2 + (a%y - b%y)**2 + eps)
  end function distance

  module procedure translate
    p%x = p%x + dx
    p%y = p%y + dy
  end procedure translate
end submodule geometry_impl
