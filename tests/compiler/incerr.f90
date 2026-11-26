program include_error
  implicit none
  integer :: k
  include 'bad.inc'
  k = 1
  print *, k
end program include_error
