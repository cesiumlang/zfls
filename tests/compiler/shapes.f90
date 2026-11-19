module shapes
  implicit none
  type :: square
    real :: side
  contains
    procedure :: area
  end type square
contains
  real function area(self)
    class(square), intent(in) :: self
    area = self%side**2
  end function area
end module shapes
