program count
  implicit none
  integer :: i, s
  real :: x
  s = 0
  do i = 1, 3
    s = s + i
  end do
  x = 2.5 ! stop here
  ! LFortran gives a PRINT no line of its own; zfls's CodeView build does (#470)
  print *, s, x ! and here
end program count
