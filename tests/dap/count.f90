program count
  implicit none
  integer :: i, s
  real :: x
  s = 0
  do i = 1, 3
    s = s + i
  end do
  ! LFortran's PRINT statements have no line of their own (#470)
  x = 2.5 ! stop here
  print *, s, x
end program count
