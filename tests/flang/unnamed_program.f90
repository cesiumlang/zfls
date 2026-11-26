! A main program without a PROGRAM statement, and an internal procedure
  implicit none
  integer :: counter
  counter = 0
  call bump()
contains
  subroutine bump()
    integer :: step
    step = 1
    counter = counter + step
  end subroutine bump
end
