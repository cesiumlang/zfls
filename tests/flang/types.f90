! Derived types and other declarations of Fortran 2003-2018, as LLVM Flang
! declares them: type-bound procedures (deferred, final, generic, operator
! and assignment bindings), BIND(C) and SEQUENCE types, an ENUM, coarrays,
! assumed-type and assumed-rank dummies, SELECT RANK
module types
  use iso_c_binding, only: c_int
  implicit none
  private
  public :: shape_t, square_t, c_point, seq_t
  enum, bind(c)
    enumerator :: red = 1, green, blue = 5
  end enum
  type, abstract :: shape_t
    integer :: id = 0
  contains
    procedure(area_if), deferred :: area
    procedure :: add_shapes
    generic :: operator(+) => add_shapes
    procedure :: assign_shape
    generic :: assignment(=) => assign_shape
  end type
  abstract interface
    real function area_if(self)
      import :: shape_t
      class(shape_t), intent(in) :: self
    end function
  end interface
  type, extends(shape_t) :: square_t
    real, private :: side = 1
  contains
    procedure :: area => square_area
    final :: square_final
  end type
  type, bind(c) :: c_point
    integer(c_int) :: x, y
  end type
  type :: seq_t
    sequence
    integer :: a
    real :: b
  end type
  integer :: counter[*]
  real, allocatable :: field(:)[:]
contains
  integer function add_shapes(a, b)
    class(shape_t), intent(in) :: a, b
    add_shapes = a%id + b%id
  end function
  subroutine assign_shape(a, b)
    class(shape_t), intent(inout) :: a
    integer, intent(in) :: b
    a%id = b
  end subroutine
  real function square_area(self)
    class(square_t), intent(in) :: self
    square_area = self%side**2
  end function
  subroutine square_final(self)
    type(square_t), intent(inout) :: self
    self%id = -1
  end subroutine
  subroutine anything(x, r)
    type(*), intent(in) :: x(*)
    real, intent(in) :: r(..)
    class(*), allocatable :: boxed
    select rank (r)
    rank (0)
      boxed = r
    rank (1)
      boxed = size(r)
    end select
  end subroutine
end module types
