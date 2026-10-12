! Modules, derived types, type-bound procedures and interfaces
module shapes
  implicit none
  private
  public :: shape, circle, rectangle, area_of, n_sides, pi, describe

  real, parameter :: pi = 3.14159265
  integer, parameter :: n_sides(3) = [0, 4, 3]
  character(len=*), parameter :: unit_name = "m"

  type, abstract :: shape
    character(len=16) :: label = "shape"
  contains
    procedure(area_iface), deferred :: area
    procedure :: describe
  end type shape

  abstract interface
    real function area_iface(self)
      import :: shape
      class(shape), intent(in) :: self
    end function area_iface
  end interface

  type, extends(shape) :: circle
    real :: radius = 1.0
  contains
    procedure :: area => circle_area
  end type circle

  type, extends(shape) :: rectangle
    real :: width = 1.0, height = 1.0
  contains
    procedure :: area => rectangle_area
  end type rectangle

  interface area_of
    module procedure circle_area, rectangle_area
  end interface area_of

contains

  real function circle_area(self)
    class(circle), intent(in) :: self
    circle_area = pi * self%radius**2
  end function circle_area

  function rectangle_area(self) result(a)
    class(rectangle), intent(in) :: self
    real :: a
    a = self%width * self%height
  end function rectangle_area

  subroutine describe(self, verbose)
    class(shape), intent(in) :: self
    logical, intent(in), optional :: verbose
    character(len=64) :: line
    integer :: i
    line = trim(self%label) // " in " // unit_name
    if (present(verbose)) then
      if (verbose) then
        do i = 1, 2
          print *, trim(line), i
        end do
      end if
    end if
  end subroutine describe

end module shapes

module registry
  use shapes, only: shape, circle, my_pi => pi
  implicit none
  integer, allocatable :: counts(:)
  real, pointer :: scale => null()
  class(shape), allocatable :: current
contains
  pure integer function twice(k)
    integer, intent(in) :: k
    twice = 2 * k
  end function twice

  recursive subroutine count_down(k)
    integer, intent(in) :: k
    if (k > 0) call count_down(k - 1)
  end subroutine count_down

  elemental real function scaled(x) result(y)
    real, intent(in) :: x
    y = my_pi * x
  end function scaled
end module registry

program main_shapes
  use shapes
  use registry, only: twice, count_down
  implicit none
  type(circle) :: c
  type(rectangle) :: r
  real :: total
  integer :: k
  c%radius = 2.0
  r%width = 3.0
  total = c%area() + r%area()
  k = twice(3)
  call count_down(k)
  call c%describe(.true.)
  print *, total, area_of(c), n_sides
end program main_shapes
