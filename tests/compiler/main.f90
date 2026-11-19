program main
  use shapes
  implicit none
  type(square) :: s
  real :: a
  s%side = 2.0
  a = s%area()
  a = a + undeclared_main
  a = a + also_undeclared
  print *, a
end program main
