! The rank and attributes of associate names: of a section, an element, a
! vector subscript, an expression, an elemental call; TARGET for a POINTER,
! no ALLOCATABLE nor INTENT (#691)
program p
  implicit none
  type :: t_t
    real :: c
    real :: v(3)
  end type
  real :: b(10, 3), c(4)
  integer :: idx(2), i
  character(len=8) :: s
  type(t_t) :: ts(5)
  associate (sec => b(:, 1), vec => b(idx, 2), elem => b(1, 2), expr => c + 1.0, sub => s(2:4), whole => b, row => b(i, :))
    print *, sec, vec, elem, expr, sub, whole, row
  end associate
  associate (comp => ts%c, comp2 => ts(2)%v, ab => abs(b), m => max(1.0, c), cmp => c > 0.0, sz => size(b))
    print *, comp, comp2, ab, m, cmp, sz
  end associate
end program

subroutine attrs(d, v)
  implicit none
  real, intent(in) :: d(:)
  real, volatile :: v
  real, allocatable :: al(:)
  real, pointer :: pt(:)
  real, target :: tg(3)
  real, contiguous, pointer :: cp(:)
  associate (ad => d, aal => al, apt => pt, atg => tg, av => v, acp => cp)
    print *, ad, aal, apt, atg, av, acp
  end associate
end subroutine
