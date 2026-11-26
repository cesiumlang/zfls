! ASSOCIATE selectors: a component's element, a section of components, a
! function's result (#721)
module m_assoc
  implicit none
  type :: inner
    real :: c(4) = 0
  end type
  type :: outer
    type(inner) :: b(3)
  end type
contains
  subroutine takes_real(v)
    real, intent(in) :: v
    print *, v
  end subroutine
  function mk() result(r)
    type(inner) :: r
    r%c = 1
  end function
  type(inner) function mk2()
    mk2%c = 2
  end function
  subroutine s(a)
    type(outer), intent(inout) :: a
    associate (y => a%b(2)%c(1), z => mk(), f => a%b(:)%c(1), u => mk2())
      call takes_real(y)
      call takes_real(a%b(2)%c(1))
      print *, z%c, f, u%c
    end associate
  end subroutine
end module
